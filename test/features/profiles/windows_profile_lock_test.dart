import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/profiles/profile_lock_remote.dart';
import 'package:watch_app/core/profiles/profile_lock_store.dart';
import 'package:watch_app/core/profiles/profile_pin_store.dart';
import 'package:watch_app/core/profiles/viewer_profile.dart';
import 'package:watch_app/features/profiles/profile_lock_gate.dart';
import 'package:watch_app/features/profiles/profile_unlock.dart';

class _MemoryStorage implements PinSecretStorage {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

/// Fast stand-in for PBKDF2 so widget tests do not need a background isolate.
Future<Uint8List> _fastDerive(String pin, Uint8List salt, int rounds) async =>
    Uint8List.fromList(sha256.convert([...salt, ...utf8.encode(pin)]).bytes);

/// Synced account lock fake: records prompts, PIN checks and enrolments.
class _Locks extends ProfileLockStore {
  bool locked = false;
  Object? verifyError;
  Object? setError;
  final verified = <String>[];
  final enrolled = <String>[];
  @override
  Future<bool> isLocked(String profileId) async => locked;
  @override
  Future<bool> get canUseBiometrics async => true;
  @override
  Future<bool> canUnlockWithBiometrics(String profileId) async => true;
  @override
  Future<bool> verify(String profileId, String pin, {String? localPin}) async {
    verified.add(pin);
    final error = verifyError;
    if (error != null) throw error;
    if (pin != '1234') return false;
    markUnlocked(profileId);
    return true;
  }

  @override
  Future<bool> setPin(String profileId, String pin, {String? currentPin}) async {
    final error = setError;
    if (error != null) throw error;
    enrolled.add(pin);
    locked = true;
    return true;
  }
}

const _profile = ViewerProfile(id: 'kid', name: 'Mira');

/// Every flow here is the Windows desktop presentation.
final _windows = TargetPlatformVariant.only(TargetPlatform.windows);

void main() {
  late _Locks locks;
  late ProfilePinStore pins;
  bool? result;

  setUp(() async {
    await sl.reset();
    locks = _Locks();
    sl.registerSingleton<ProfileLockStore>(locks);
  });

  tearDown(() async {
    await sl.reset();
  });

  /// Builds the old PC-only PIN store inside the test body (fake-time zone),
  /// optionally with an old PIN already set.
  Future<void> legacyPins(WidgetTester tester, {String? pin}) async {
    pins = ProfilePinStore(
      storage: _MemoryStorage(),
      owner: () => 'local',
      iterations: 1000,
      derive: _fastDerive,
    );
    sl.registerSingleton<ProfilePinStore>(pins);
    if (pin != null) {
      unawaited(pins.setPin(_profile.id, pin));
      await tester.pump();
    }
  }

  Future<void> open(WidgetTester tester) async {
    result = null;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async =>
                  result = await ensureProfileAccess(context, _profile),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> submit(WidgetTester tester, String pin) async {
    await tester.enterText(find.byType(TextField).first, pin);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }

  testWidgets('synced lock unlocks in one desktop dialog with Enter', (
    tester,
  ) async {
    await legacyPins(tester);
    locks.locked = true;
    await open(tester);
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
    // Windows Hello cannot do the fingerprint-only check: no option shown.
    expect(find.byIcon(Icons.fingerprint_rounded), findsNothing);
    await submit(tester, '1234');
    expect(result, isTrue);
    expect(locks.verified, ['1234']);
    expect(find.byType(Dialog), findsNothing);
  }, variant: _windows);

  testWidgets('Esc cancels the unlock dialog', (tester) async {
    locks.locked = true;
    await open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(result, isFalse);
  }, variant: _windows);

  testWidgets('never verified on this PC says to connect once', (
    tester,
  ) async {
    locks
      ..locked = true
      ..verifyError = const ProfileLockException('offline_pin_unavailable');
    await open(tester);
    await submit(tester, '1234');
    expect(find.text(kConnectOnceToUnlockOnThisPc), findsOneWidget);
    expect(result, isNull);
  }, variant: _windows);

  testWidgets('old PC PIN is verified, moved to the synced lock, deleted', (
    tester,
  ) async {
    await legacyPins(tester, pin: '4821');
    await open(tester);
    // The old PC dialog, alone: no synced prompt on top of it.
    expect(find.text('Enter PIN'), findsOneWidget);
    expect(find.text('Unlock profile'), findsNothing);
    await tester.enterText(find.byType(TextField), '4821');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(result, isTrue);
    expect(locks.enrolled, ['4821']);
    expect(locks.verified, isEmpty);
    expect(pins.isLocked(_profile.id), isFalse);
    var hasPin = true;
    unawaited(pins.hasPin(_profile.id).then((v) => hasPin = v));
    await tester.pump();
    expect(hasPin, isFalse);
  }, variant: _windows);

  testWidgets('offline, the old PC PIN still opens the profile and stays', (
    tester,
  ) async {
    await legacyPins(tester, pin: '4821');
    locks.setError = const ProfileLockException('online_required');
    await open(tester);
    await tester.enterText(find.byType(TextField), '4821');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(result, isTrue);
    expect(locks.enrolled, isEmpty);
    expect(pins.isLocked(_profile.id), isTrue);
  }, variant: _windows);

  testWidgets('a wrong old PC PIN does not open or move anything', (
    tester,
  ) async {
    await legacyPins(tester, pin: '4821');
    await open(tester);
    await tester.enterText(find.byType(TextField), '0000');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('Incorrect PIN'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
    expect(locks.enrolled, isEmpty);
    expect(pins.isLocked(_profile.id), isTrue);
  }, variant: _windows);

  testWidgets('a synced lock wins over an old PC PIN: one prompt only', (
    tester,
  ) async {
    await legacyPins(tester, pin: '4821');
    locks.locked = true;
    await open(tester);
    expect(find.text('Enter PIN'), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
    await submit(tester, '1234');
    expect(result, isTrue);
    expect(locks.verified, ['1234']);
    // The synced lock now covers the profile, so the old PIN is retired.
    expect(pins.isLocked(_profile.id), isFalse);
  }, variant: _windows);
}
