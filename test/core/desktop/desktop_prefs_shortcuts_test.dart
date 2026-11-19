import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/desktop/desktop_prefs.dart';
import 'package:watch_app/core/desktop/desktop_shortcut_catalog.dart';
import 'package:watch_app/core/desktop/desktop_shortcuts.dart';
import 'package:watch_app/features/settings/keyboard_shortcuts_screen.dart';

// Covers the desktop-settings foundation: DesktopPrefs defaults and storage,
// and DesktopShortcuts remaps, conflicts, labels and persistence.
void main() {
  group('DesktopPrefs without a box (tests / phone)', () {
    test('every getter returns its default', () {
      expect(Hive.isBoxOpen(DesktopPrefs.boxName), isFalse);
      expect(DesktopPrefs.closeBehaviour, DesktopCloseBehaviour.ask);
      expect(DesktopPrefs.startPage, DesktopStartPage.home);
      expect(DesktopPrefs.lastPage, isNull);
      expect(DesktopPrefs.sidebarExpanded, isFalse);
      expect(DesktopPrefs.lastSettingsSection, isNull);
      expect(DesktopPrefs.downloadNotifications, isTrue);
      expect(DesktopPrefs.taskbarProgress, isTrue);
      expect(DesktopPrefs.newEpisodeAlerts, isTrue);
      expect(DesktopPrefs.autoBackupEnabled, isFalse);
      expect(DesktopPrefs.autoBackupFolder, isNull);
      expect(DesktopPrefs.autoBackupFrequency, AutoBackupFrequency.weekly);
      expect(DesktopPrefs.autoBackupKeep, 5);
      expect(DesktopPrefs.autoBackupLastRun, isNull);
      expect(DesktopPrefs.autoLockIdleMinutes, 0);
      expect(DesktopPrefs.lockWhenWindowsLocks, isFalse);
      expect(DesktopPrefs.discordOnlyWhileWatching, isFalse);
    });

    test('setters are harmless no-ops and listenable never throws', () async {
      await DesktopPrefs.setCloseBehaviour(DesktopCloseBehaviour.quit);
      expect(DesktopPrefs.closeBehaviour, DesktopCloseBehaviour.ask);
      void listener() {}
      DesktopPrefs.changes.addListener(listener);
      DesktopPrefs.changes.removeListener(listener);
    });
  });

  group('DesktopPrefs with a box', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('desktop_prefs_test');
      Hive.init(dir.path);
      DesktopShortcuts.debugReset();
      await DesktopPrefs.init();
    });

    tearDown(() async {
      await Hive.deleteFromDisk();
      await Hive.close();
      DesktopShortcuts.debugReset();
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    test('values round-trip and close behaviour is stored by name', () async {
      await DesktopPrefs.setCloseBehaviour(
        DesktopCloseBehaviour.trayWhileDownloading,
      );
      await DesktopPrefs.setStartPage(DesktopStartPage.lastUsed);
      await DesktopPrefs.setAutoBackupKeep(10);
      await DesktopPrefs.setAutoBackupFolder('C:/Backups');
      final when = DateTime(2026, 1, 2, 3, 4);
      await DesktopPrefs.setAutoBackupLastRun(when);
      await DesktopPrefs.setAutoLockIdleMinutes(15);

      // The native close guard reads this raw string key.
      expect(
        Hive.box<dynamic>(DesktopPrefs.boxName).get('close_behaviour'),
        'trayWhileDownloading',
      );
      expect(DesktopPrefs.startPage, DesktopStartPage.lastUsed);
      expect(DesktopPrefs.autoBackupKeep, 10);
      expect(DesktopPrefs.autoBackupFolder, 'C:/Backups');
      expect(DesktopPrefs.autoBackupLastRun, when);
      expect(DesktopPrefs.autoLockIdleMinutes, 15);

      await DesktopPrefs.setAutoBackupFolder(null);
      expect(DesktopPrefs.autoBackupFolder, isNull);
    });

    test('an unknown stored enum name falls back to the default', () async {
      await Hive.box<dynamic>(DesktopPrefs.boxName)
          .put('close_behaviour', 'bogus');
      expect(DesktopPrefs.closeBehaviour, DesktopCloseBehaviour.ask);
    });

    test('init registers the catalogue and remaps persist', () async {
      expect(DesktopShortcuts.spec('player.playPause'), isNotNull);
      await DesktopShortcuts.setOverride('player.mute', const [
        SingleActivator(LogicalKeyboardKey.keyU, control: true),
      ]);
      // Simulate a restart: forget in-memory state, reload from the box.
      DesktopShortcuts.debugReset();
      registerDefaultDesktopShortcuts();
      DesktopShortcuts.loadOverrides();
      final keys = DesktopShortcuts.activatorsFor('player.mute');
      expect(keys, hasLength(1));
      expect(DesktopShortcuts.describe(keys.single), 'Ctrl+U');
    });
  });

  group('DesktopShortcuts', () {
    setUp(() {
      DesktopShortcuts.debugReset();
      registerDefaultDesktopShortcuts();
    });
    tearDown(DesktopShortcuts.debugReset);

    test('register is idempotent by id', () {
      final count = DesktopShortcuts.all.length;
      registerDefaultDesktopShortcuts();
      expect(DesktopShortcuts.all.length, count);
    });

    test('catalogue holds the agreed ids', () {
      for (final id in [
        'app.search',
        'app.section9',
        'app.mode4',
        'app.lockProfile',
        'app.contextMenu',
        'home.open',
        'show.tab4',
        'player.jumpPercent',
        'player.help',
        'reader.shiftSpread',
        'downloads.open',
        'lists.today',
        'settings.previousSection',
      ]) {
        expect(DesktopShortcuts.spec(id), isNotNull, reason: id);
      }
      expect(DesktopShortcuts.spec('player.mute')!.remappable, isTrue);
      expect(DesktopShortcuts.spec('player.exit')!.remappable, isFalse);
      expect(DesktopShortcuts.spec('player.jumpPercent')!.remappable, isFalse);
      expect(DesktopShortcuts.spec('app.search')!.remappable, isFalse);
    });

    test('describe gives familiar labels', () {
      expect(
        DesktopShortcuts.describe(
          const SingleActivator(
            LogicalKeyboardKey.keyF,
            control: true,
            shift: true,
          ),
        ),
        'Ctrl+Shift+F',
      );
      expect(
        DesktopShortcuts.describe(
          const SingleActivator(LogicalKeyboardKey.space),
        ),
        'Space',
      );
      expect(
        DesktopShortcuts.describe(
          const SingleActivator(LogicalKeyboardKey.slash, shift: true),
        ),
        '?',
      );
      expect(DesktopShortcuts.describeAll('player.jumpPercent'), '0-9');
      expect(DesktopShortcuts.describeAll('player.playPause'), 'Space / K');
    });

    test('override replaces defaults; clear and resetAll restore', () async {
      const ctrlU = SingleActivator(LogicalKeyboardKey.keyU, control: true);
      await DesktopShortcuts.setOverride('player.mute', const [ctrlU]);
      expect(DesktopShortcuts.isOverridden('player.mute'), isTrue);
      expect(DesktopShortcuts.describeAll('player.mute'), 'Ctrl+U');

      await DesktopShortcuts.clearOverride('player.mute');
      expect(DesktopShortcuts.describeAll('player.mute'), 'M');

      await DesktopShortcuts.setOverride('player.mute', const [ctrlU]);
      await DesktopShortcuts.resetAll();
      expect(DesktopShortcuts.describeAll('player.mute'), 'M');
    });

    test('overrides on fixed actions are ignored', () async {
      await DesktopShortcuts.setOverride('player.exit', const [
        SingleActivator(LogicalKeyboardKey.keyQ),
      ]);
      expect(DesktopShortcuts.describeAll('player.exit'), 'Esc');
    });

    test('conflictWith finds same-scope and app-scope clashes only', () {
      // K is play/pause in the player.
      expect(
        DesktopShortcuts.conflictWith(
          'player.mute',
          const SingleActivator(LogicalKeyboardKey.keyK),
        ),
        'player.playPause',
      );
      // Ctrl+L locks the profile everywhere.
      expect(
        DesktopShortcuts.conflictWith(
          'player.mute',
          const SingleActivator(LogicalKeyboardKey.keyL, control: true),
        ),
        'app.lockProfile',
      );
      // A reader-only key (O) does not clash with the player.
      expect(
        DesktopShortcuts.conflictWith(
          'player.mute',
          const SingleActivator(LogicalKeyboardKey.keyO),
        ),
        isNull,
      );
      // An action never conflicts with itself.
      expect(
        DesktopShortcuts.conflictWith(
          'player.mute',
          const SingleActivator(LogicalKeyboardKey.keyM),
        ),
        isNull,
      );
    });

    test('remapped keys are what conflicts are checked against', () async {
      await DesktopShortcuts.setOverride('player.skip', const [
        SingleActivator(LogicalKeyboardKey.keyX),
      ]);
      expect(
        DesktopShortcuts.conflictWith(
          'player.mute',
          const SingleActivator(LogicalKeyboardKey.keyX),
        ),
        'player.skip',
      );
      expect(
        DesktopShortcuts.conflictWith(
          'player.mute',
          const SingleActivator(LogicalKeyboardKey.keyS),
        ),
        isNull,
      );
    });

    testWidgets('bindings and matches follow remaps', (tester) async {
      var muted = 0;
      var matched = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: CallbackShortcuts(
            bindings: DesktopShortcuts.bindings({'player.mute': () => muted++}),
            child: Focus(
              autofocus: true,
              onKeyEvent: (_, event) {
                if (DesktopShortcuts.matches('player.mute', event)) matched++;
                return KeyEventResult.ignored;
              },
              child: const SizedBox(),
            ),
          ),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      expect(muted, 1);
      expect(matched, 1);

      await DesktopShortcuts.setOverride('player.mute', const [
        SingleActivator(LogicalKeyboardKey.keyU),
      ]);
      // Rebuild the bindings map as a feature would on `changes`.
      await tester.pumpWidget(
        MaterialApp(
          home: CallbackShortcuts(
            bindings: DesktopShortcuts.bindings({'player.mute': () => muted++}),
            child: const Focus(autofocus: true, child: SizedBox()),
          ),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      expect(muted, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyU);
      expect(muted, 2);
    });

    testWidgets('capture dialog warns about a conflict and saves', (
      tester,
    ) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox();
            },
          ),
        ),
      );
      final result = showShortcutCaptureDialog(
        ctx,
        DesktopShortcuts.spec('player.mute')!,
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.pump();
      expect(find.byKey(const ValueKey('shortcut-conflict')), findsOneWidget);
      expect(find.textContaining('Play / pause'), findsOneWidget);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(await result, isTrue);
      expect(DesktopShortcuts.describeAll('player.mute'), 'K');
    });
  });
}
