import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/profiles/profile_pin_store.dart';
import 'package:watch_app/core/profiles/viewer_profile.dart';
import 'package:watch_app/features/profiles/profile_pin_dialog.dart';

class _MemoryStorage implements PinSecretStorage {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

/// Fast stand-in for PBKDF2 so widget tests do not depend on a background
/// isolate. The real derivation is covered by the store tests.
Future<Uint8List> _fastDerive(String pin, Uint8List salt, int rounds) async =>
    Uint8List.fromList(sha256.convert([...salt, ...utf8.encode(pin)]).bytes);

const _profile = ViewerProfile(id: 'kid', name: 'Mira');

void main() {
  late ProfilePinStore store;
  bool? result;

  Future<void> host(
    WidgetTester tester,
    Future<bool> Function(BuildContext) open,
  ) async {
    result = null;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: TextButton(
                onPressed: () async => result = await open(context),
                child: const Text('open'),
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  /// Types a PIN and lets the dialog finish handling it.
  Future<void> type(WidgetTester tester, String pin) async {
    await tester.enterText(find.byType(TextField), pin);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Sets the PIN without awaiting it: a plain await inside a widget test sits
  /// in the fake-time zone and never wakes up. Pumping flushes the store's
  /// microtasks instead.
  ///
  /// The store is also built here, inside the test body, not in setUp: a store
  /// created in setUp's real-time zone leaves its internal queue on the wrong
  /// event loop and stalls under the widget test's fake-time zone. (The app
  /// itself runs in a single zone, so this is only a test concern.)
  Future<void> seedPin(WidgetTester tester) async {
    store = ProfilePinStore(
      storage: _MemoryStorage(),
      owner: () => 'local',
      iterations: 1000,
      derive: _fastDerive,
    );
    unawaited(store.setPin('kid', '4821'));
    await tester.pump();
  }

  testWidgets('a wrong PIN shakes, explains, clears and stays open', (
    tester,
  ) async {
    await seedPin(tester);
    await host(
      tester,
      (c) => showProfilePinPrompt(c, profile: _profile, store: store),
    );
    expect(find.text('Enter PIN'), findsOneWidget);
    expect(find.text('for Mira'), findsOneWidget);

    await type(tester, '0000');
    expect(find.text('Incorrect PIN. 4 attempts left.'), findsOneWidget);
    expect(find.text('Enter PIN'), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, isEmpty);
    expect(result, isNull);
  });

  testWidgets('the right PIN closes the dialog with true', (tester) async {
    await seedPin(tester);
    await host(
      tester,
      (c) => showProfilePinPrompt(c, profile: _profile, store: store),
    );
    await type(tester, '4821');
    await tester.pumpAndSettle();
    expect(find.text('Enter PIN'), findsNothing);
    expect(result, isTrue);
  });

  testWidgets('Cancel returns false and leaves the profile locked', (
    tester,
  ) async {
    await seedPin(tester);
    await host(
      tester,
      (c) => showProfilePinPrompt(c, profile: _profile, store: store),
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
    expect(store.isLocked('kid'), isTrue);
  });

  testWidgets('five wrong PINs lock input and show a countdown', (
    tester,
  ) async {
    await seedPin(tester);
    await host(
      tester,
      (c) => showProfilePinPrompt(c, profile: _profile, store: store),
    );
    for (var i = 0; i < 5; i++) {
      await type(tester, '0000');
    }
    expect(find.textContaining('Too many attempts.'), findsOneWidget);
    expect(find.textContaining('Try again in 5:00'), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.enabled, isFalse);

    // The countdown ticks down by itself.
    await tester.pump(const Duration(seconds: 2));
    expect(find.textContaining('Try again in 4:58'), findsOneWidget);
    // Let the timer finish so the test leaves nothing pending.
    await tester.pump(const Duration(minutes: 5));
    expect(field.enabled, isFalse); // old widget snapshot; re-read below
    expect(
      tester.widget<TextField>(find.byType(TextField)).enabled,
      isTrue,
    );
  });

  testWidgets('setting a PIN asks twice and rejects a mismatch', (
    tester,
  ) async {
    final fresh = ProfilePinStore(
      storage: _MemoryStorage(),
      owner: () => 'local',
      iterations: 1000,
      derive: _fastDerive,
    );
    await host(
      tester,
      (c) => showSetProfilePin(c, profile: _profile, store: fresh),
    );
    expect(find.text('Choose a PIN'), findsOneWidget);

    await type(tester, '1111');
    expect(find.text('Confirm your PIN'), findsOneWidget);

    await type(tester, '2222');
    expect(find.text("PINs didn't match. Try again."), findsOneWidget);
    expect(find.text('Choose a PIN'), findsOneWidget);
    expect(fresh.isLocked('kid'), isFalse);

    await type(tester, '3333');
    await type(tester, '3333');
    await tester.pumpAndSettle();
    expect(result, isTrue);
    expect(fresh.isLocked('kid'), isTrue);
  });

  testWidgets('changing a PIN asks for the current one first', (tester) async {
    await seedPin(tester);
    await host(
      tester,
      (c) => showSetProfilePin(c, profile: _profile, store: store),
    );
    expect(find.text('Enter current PIN'), findsOneWidget);
    await type(tester, '4821');
    await tester.pumpAndSettle();
    expect(find.text('Choose a PIN'), findsOneWidget);
    // Still locked with the old PIN until the new one is confirmed.
    expect(store.isLocked('kid'), isTrue);
  });

  testWidgets('removing a PIN needs the right PIN', (tester) async {
    await seedPin(tester);
    await host(
      tester,
      (c) => showRemoveProfilePin(c, profile: _profile, store: store),
    );
    await type(tester, '0000');
    expect(store.isLocked('kid'), isTrue);
    await type(tester, '4821');
    await tester.pumpAndSettle();
    expect(result, isTrue);
    expect(store.isLocked('kid'), isFalse);
  });

  test('describePinCheck wording', () {
    expect(
      describePinCheck(const PinCheck(PinResult.wrong, attemptsLeft: 1)).message,
      'Incorrect PIN. 1 attempt left.',
    );
    expect(describePinCheck(const PinCheck(PinResult.ok)).ok, isTrue);
  });
}
