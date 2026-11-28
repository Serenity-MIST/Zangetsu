import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/ui/desktop_settings_surface.dart';
import 'package:watch_app/core/ui/subtitle_language_picker.dart';
import 'package:watch_app/features/player/player_screen.dart'
    show openSubtitleStyleSheet;
import 'package:watch_app/features/settings/player_controls_screen.dart';
import 'package:watch_app/features/settings/settings_screen.dart';
import 'package:watch_app/l10n/app_localizations.dart';

/// Windows Playback settings as the desktop settings workspace shows them:
/// each row must use PC wording and its picker must write the pref the PC
/// player reads.
/// Runs [body] as the Windows build; the variant restores the target
/// platform before the end-of-test invariant check.
void winTest(String name, WidgetTesterCallback body) => testWidgets(
  name,
  body,
  variant: TargetPlatformVariant.only(TargetPlatform.windows),
);

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('pb_win_');
    Hive.init(tmp.path);
    // In-memory box: writes complete inside the fake-async test zone.
    await Hive.openBox(PlaybackPrefs.boxName, bytes: Uint8List(0));
    GetIt.instance
      ..registerSingleton<AppMode>(AppMode(isTv: false))
      ..registerSingleton<PlaybackPrefs>(PlaybackPrefs());
  });

  tearDown(() async {
    await GetIt.instance.reset();
    await Hive.close();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  PlaybackPrefs prefs() => GetIt.instance<PlaybackPrefs>();

  Future<void> pump(WidgetTester tester, Widget child) async {
    // Shader / cache / font folders resolve through path_provider.
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tmp.path,
    );
    await tester.binding.setSurfaceSize(const Size(1100, 2600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: DesktopSettingsScope(child: child),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapRow(WidgetTester tester, String title) async {
    final row = find.text(title);
    await tester.scrollUntilVisible(
      row,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(row);
    await tester.pumpAndSettle();
  }

  /// Rebuilds what awaited a pref write (Hive completes inside the test zone).
  Future<void> settle(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 80));
    await tester.pumpAndSettle();
  }

  // Windows always opens the player on the watch page, so neither the phone
  // orientation row nor a "Player opens in" row is shown, whatever is saved.
  winTest('no orientation or Player opens in row on Windows', (tester) async {
    for (final saved in ['landscape', 'portrait', 'system']) {
      await prefs().setPlayerOrientation(saved);
      await pump(tester, const PlaybackSettingsScreen());
      expect(find.text('Orientation lock'), findsNothing, reason: saved);
      expect(find.text('Player opens in'), findsNothing, reason: saved);
      expect(find.text('Full window'), findsNothing, reason: saved);
      expect(find.text('Match window shape'), findsNothing, reason: saved);
    }
  });

  winTest('decoder and close confirmation use PC wording', (
    tester,
  ) async {
    await pump(tester, const PlaybackSettingsScreen());
    expect(find.text('Hardware, D3D11 copy (recommended)'), findsOneWidget);
    expect(find.text('Hardware+ (recommended)'), findsNothing);
    await tapRow(tester, 'Video decoder');
    await tester.tap(find.text('Software, CPU (most compatible)'));
    await settle(tester);
    expect(prefs().videoDecoder, 'sw');
    expect(prefs().hwdecValue, 'no');

    expect(find.text('Press Esc or Back twice to close'), findsOneWidget);
    await tapRow(tester, 'Close confirmation');
    await tester.tap(find.text('Close at once'));
    await settle(tester);
    expect(prefs().closeConfirmation, 'direct');
    expect(find.text('Close at once'), findsOneWidget);
  });

  winTest('MegaSkip duration is a graphite row whose slider saves', (
    tester,
  ) async {
    await prefs().setMegaSkip(true);
    await pump(tester, const PlaybackSettingsScreen());
    final row = find.byKey(const ValueKey('megaskip-duration-desktop'));
    await tester.scrollUntilVisible(
      row,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.descendant(of: row, matching: find.byType(Slider)),
      findsOneWidget,
    );
    expect(find.byType(GraphiteSettingsControl), findsWidgets);
    final slider = find.byKey(const ValueKey('megaskip-duration-slider'));
    // Drag to the far left: the minimum jump.
    await tester.drag(slider, const Offset(-600, 0));
    await settle(tester);
    expect(prefs().megaSkipSeconds, PlaybackPrefs.megaSkipMin);
  });

  testWidgets('phone keeps the orientation lock wording', (tester) async {
    await pump(tester, const PlaybackSettingsScreen());
    expect(find.text('Orientation lock'), findsOneWidget);
    expect(find.text('Player opens in'), findsNothing);
    expect(find.text('Hardware+ (recommended)'), findsOneWidget);
  });

  winTest('subtitle style opens a desktop dialog on Windows', (
    tester,
  ) async {
    await pump(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => openSubtitleStyleSheet(context, null, () {}),
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('subtitle-style-desktop-dialog')),
      findsOneWidget,
    );
    expect(find.byType(BottomSheet), findsNothing);
    // The size slider still writes the pref the player applies.
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('subtitle-style-desktop-dialog')),
      findsNothing,
    );
  });

  winTest('subtitle language is a searchable desktop dialog', (
    tester,
  ) async {
    String? picked = 'unset';
    await pump(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async =>
              picked = await showSubtitleLanguagePicker(context, ''),
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('subtitle-language-desktop-dialog')),
      findsOneWidget,
    );
    expect(find.byType(BottomSheet), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('subtitle-language-filter')),
      'japan',
    );
    await tester.pumpAndSettle();
    expect(find.text('Japanese'), findsOneWidget);
    expect(find.text('English'), findsNothing);
    expect(find.text('Auto'), findsOneWidget); // pinned
    await tester.tap(find.text('Japanese'));
    await tester.pumpAndSettle();
    expect(picked, 'ja');
  });

  winTest('controls editor hides Cast and PiP on Windows', (tester) async {
    await pump(tester, const PlayerControlsScreen());
    expect(find.text('Cast'), findsNothing);
    expect(find.text('Picture-in-picture'), findsNothing);
    expect(find.byIcon(Icons.cast), findsNothing);
    // Default top bar is Playback stats only: Cast no longer takes a slot.
    expect(find.text('Top bar \u00b7 1/5'), findsOneWidget);
    expect(find.text('Fullscreen'), findsWidgets);
  });

  testWidgets('controls editor on phone still offers Cast', (tester) async {
    await pump(tester, const PlayerControlsScreen());
    expect(find.text('Cast'), findsOneWidget);
    expect(find.text('Top bar \u00b7 2/5'), findsOneWidget);
  });
}
