import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/desktop/desktop_prefs.dart';
import 'package:watch_app/core/desktop/desktop_shortcut_catalog.dart';
import 'package:watch_app/core/desktop/desktop_shortcuts.dart';
import 'package:watch_app/features/backup/auto_backup_settings_panel.dart';
import 'package:watch_app/features/downloads/desktop_download_settings_dialog.dart';
import 'package:watch_app/features/settings/keyboard_shortcuts_screen.dart';

// Reviewer tests for the desktop-settings group: the Keyboard shortcuts
// page (Reset all, help overlay), the automatic backup panel and the two
// download dialog toggles all read and write DesktopPrefs as intended.
void main() {
  late Directory dir;

  // Big surface so long lists and dialogs fit without scrolling.
  Future<void> pumpApp(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: home));
    await tester.pumpAndSettle();
  }

  // The shortcut pages run without a Hive box: remaps stay in memory and
  // saving is skipped. A real box write started from a tap inside the
  // widget tester's fake clock never finishes, which made tearDown's
  // Hive.close hang until the 10-minute test timeout.
  group('keyboard shortcuts page', () {
    setUp(() {
      // UI is gated on the Windows target platform, not the host OS.
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      DesktopShortcuts.debugReset();
      registerDefaultDesktopShortcuts();
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      DesktopShortcuts.debugReset();
    });

    testWidgets('Reset all asks first, then restores remapped keys', (
      tester,
    ) async {
      await DesktopShortcuts.setOverride('player.mute', const [
        SingleActivator(LogicalKeyboardKey.keyQ),
      ]);
      await pumpApp(tester, const KeyboardShortcutsScreen());
      // The list is lazy and Mute sits far down, so filter to bring it in.
      await tester.enterText(find.byType(TextField), 'mute');
      await tester.pumpAndSettle();
      // The row subtitle is the action's description plus this note.
      expect(find.textContaining('Changed from default'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Reset all').first);
      await tester.pumpAndSettle();
      expect(find.text('Reset all shortcuts?'), findsOneWidget);
      // Confirm button in the dialog (the app bar button is the first one).
      await tester.tap(find.text('Reset all').last);
      await tester.pumpAndSettle();

      expect(DesktopShortcuts.isOverridden('player.mute'), isFalse);
      expect(find.textContaining('Changed from default'), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('search filters the shortcut list', (tester) async {
      await pumpApp(tester, const KeyboardShortcutsScreen());
      await tester.enterText(find.byType(TextField), 'subtitles earlier');
      await tester.pumpAndSettle();
      expect(find.text('Subtitles earlier'), findsOneWidget);
      expect(find.text('Next episode'), findsNothing);
      await tester.enterText(find.byType(TextField), 'zzzz');
      await tester.pumpAndSettle();
      expect(find.text('No shortcuts match'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('help overlay lists the scope first, Esc closes, Customise '
        'opens the page', (tester) async {
      await pumpApp(
        tester,
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showKeyboardShortcutsHelp(
                context,
                scope: DesktopShortcutScope.player,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('keyboard-shortcuts-help')), findsOne);
      // Player heading comes before the app-wide one.
      final player = tester.getTopLeft(find.text('Player')).dy;
      final app = tester.getTopLeft(find.text('Everywhere')).dy;
      expect(player, lessThan(app));

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('keyboard-shortcuts-help')),
        findsNothing,
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Customise'));
      await tester.pumpAndSettle();
      expect(find.byType(KeyboardShortcutsScreen), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });

    // After Tab moves focus to the buttons, clicking the capture box must
    // give it the keyboard back so the next key is recorded.
    testWidgets('capture box takes keys again after a click', (tester) async {
      await pumpApp(
        tester,
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showShortcutCaptureDialog(
                context,
                DesktopShortcuts.spec('player.mute')!,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('shortcut-capture-box')));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(DesktopShortcuts.describeAll('player.mute'), 'Q');
      debugDefaultTargetPlatformOverride = null;
    });
  });

  // Lets Hive writes started from taps finish. The box is in memory (see
  // setUp below), so a write needs no real file I/O and settling the
  // tester's fake clock completes it.
  Future<void> settleWrites(WidgetTester tester) => tester.pumpAndSettle();

  // Settings that must reach the DesktopPrefs box.
  group('saved settings', () {
    setUp(() async {
      // UI is gated on the Windows target platform, not the host OS.
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      dir = await Directory.systemTemp.createTemp('desktop_settings_extras');
      Hive.init(dir.path);
      // An in-memory box: a file-backed write started from a tap inside the
      // widget tester's fake clock never finishes, which hung tearDown's
      // Hive.close. DesktopPrefs.init reuses this already-open box.
      await Hive.openBox<dynamic>(DesktopPrefs.boxName, bytes: Uint8List(0));
      DesktopShortcuts.debugReset();
      await DesktopPrefs.init();
    });

    tearDown(() async {
      debugDefaultTargetPlatformOverride = null;
      debugPickAutoBackupFolder = null;
      DesktopShortcuts.debugReset();
      // Memory boxes cannot be deleted from disk; closing drops them, and
      // the temp folder below goes with them.
      await Hive.close();
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    testWidgets('auto backup: turning on asks for a folder; cancel keeps it '
        'off', (tester) async {
      String? next;
      debugPickAutoBackupFolder = () async => next;
      await pumpApp(
        tester,
        const Scaffold(
          body: SingleChildScrollView(child: AutoBackupSettingsPanel()),
        ),
      );

      // Cancelled picker: stays off.
      await tester.tap(find.byType(Switch));
      await settleWrites(tester);
      expect(DesktopPrefs.autoBackupEnabled, isFalse);

      // Picked folder: saved and switched on.
      next = dir.path;
      await tester.tap(find.byType(Switch));
      await settleWrites(tester);
      expect(DesktopPrefs.autoBackupFolder, dir.path);
      expect(DesktopPrefs.autoBackupEnabled, isTrue);
      expect(find.text('Open folder'), findsOneWidget);

      // Keep picker stores the chosen count.
      await tester.tap(find.text('Keep'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Last 10 backups').last);
      await settleWrites(tester);
      expect(DesktopPrefs.autoBackupKeep, 10);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('download dialog toggles write DesktopPrefs', (tester) async {
      await pumpApp(
        tester,
        Scaffold(
          body: DesktopDownloadSettingsDialog(
            parallel: 2,
            connections: 4,
            onParallelChanged: (_) {},
            onParallelCommit: (_) {},
            onConnectionsChanged: (_) {},
            onConnectionsCommit: (_) {},
          ),
        ),
      );
      expect(DesktopPrefs.downloadNotifications, isTrue);
      expect(DesktopPrefs.taskbarProgress, isTrue);
      await tester.tap(
        find.byKey(const ValueKey('desktop-download-notifications')),
      );
      await settleWrites(tester);
      await tester.tap(find.byKey(const ValueKey('desktop-taskbar-progress')));
      await settleWrites(tester);
      expect(DesktopPrefs.downloadNotifications, isFalse);
      expect(DesktopPrefs.taskbarProgress, isFalse);
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
