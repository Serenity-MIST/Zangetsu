// Windows Backup page restore flow: the saved-backups list (acct-10), the
// restore preview with per-part checkboxes (acct-4), the automatic safety
// copy + 'Undo restore' (acct-4), and 'Restart now' (acct-12).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/backup/auto_backup_runner.dart';
import 'package:watch_app/core/backup/backup_payload.dart';
import 'package:watch_app/core/backup/backup_service.dart';
import 'package:watch_app/core/desktop/desktop_prefs.dart';
import 'package:watch_app/core/desktop/desktop_reveal.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/supabase/supabase_service.dart';
import 'package:watch_app/core/ui/desktop_settings_surface.dart';
import 'package:watch_app/features/auth/auth_cubit.dart';
import 'package:watch_app/features/backup/auto_backup_settings_panel.dart';
import 'package:watch_app/features/backup/backup_screen.dart';

/// Records restores; a restore overwrites one setting like the real one.
class _FakeBackupService implements BackupService {
  Set<BackupBundle>? restored;

  @override
  Future<void> authorize() async {}

  @override
  Future<RestoreReport> restore(
    Map<String, dynamic> payload,
    Set<BackupBundle> bundles, {
    String? password,
  }) async {
    restored = {...bundles};
    await Hive.box('playback_prefs').put('speed', 2.0);
    await Hive.box('playback_prefs').put('added', true);
    return RestoreReport(restored: bundles, failures: const []);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// Alternates real time (so file and Hive IO completes) with frames (so the
/// page reacts), a few rounds: each IO step can start the next one.
Future<void> settleIo(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();
  }
}

void main() {
  late Directory hiveDir;
  late Directory folder;
  late _FakeBackupService service;
  var restarts = 0;

  setUp(() async {
    hiveDir = Directory.systemTemp.createTempSync('backup_restore_hive_');
    folder = Directory.systemTemp.createTempSync('backup_restore_out_');
    Hive.init(hiveDir.path);
    await Hive.openBox<dynamic>(DesktopPrefs.boxName);
    await Hive.openBox('playback_prefs');
    await Hive.box('playback_prefs').put('speed', 1.0);
    await DesktopPrefs.setAutoBackupFolder(folder.path);
    // One automatic backup with library + settings parts in the folder.
    File(
      '${folder.path}${Platform.pathSeparator}'
      'zangetsu-auto-20261117-080000.json',
    ).writeAsStringSync(
      jsonEncode({
        'app': 'zangetsu',
        'version': 1,
        'createdAt': '2026-11-17T08:00:00.000Z',
        'bundles': {
          'library': {
            'myList': [{}, {}, {}],
          },
          'settings': {'playback_prefs': {}},
        },
      }),
    );
    service = _FakeBackupService();
    restarts = 0;
    BackupScreen.debugRestartApp = () async => restarts++;
    AutoBackupRunner.debugBuildPayload = () async => {
      'app': 'zangetsu',
      'version': 1,
      'bundles': <String, dynamic>{},
    };
    sl
      ..registerSingleton<AppMode>(const AppMode(isTv: false))
      ..registerSingleton<BackupService>(service);
  });

  tearDown(() async {
    sl.reset();
    BackupScreen.debugRestartApp = null;
    AutoBackupRunner.debugReset();
    debugRevealOverride = null;
    await Hive.deleteFromDisk();
    for (final d in [hiveDir, folder]) {
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
  });

  Future<void> pump(WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = AuthCubit(SupabaseService());
    addTearDown(auth.close);
    await tester.pumpWidget(
      MaterialApp(
        home: DesktopSettingsScope(
          child: BlocProvider<AuthCubit>.value(
            value: auth,
            child: const BackupScreen(),
          ),
        ),
      ),
    );
    // The folder listing is real file IO, which only completes outside the
    // fake-async test zone: ask the page to reload its list from there.
    await tester.runAsync(() async {
      AutoBackupRunner.revision.value++;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await settleIo(tester);
  }

  /// Taps [finder] and lets real IO (file reads/writes) run.
  Future<void> tapIo(WidgetTester tester, Finder finder) async {
    await tester.runAsync(() async {
      await tester.tap(finder);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await settleIo(tester);
    await tester.pumpAndSettle();
  }

  testWidgets('lists saved backups and embeds the automatic backup settings', (
    tester,
  ) async {
    await pump(tester);
    expect(find.byType(AutoBackupSettingsPanel), findsOneWidget);
    expect(find.text('Saved backups'), findsOneWidget);
    expect(find.text('2026-11-17 08:00'), findsOneWidget);
    expect(find.textContaining('Automatic backup ·'), findsOneWidget);

    String? revealed;
    debugRevealOverride = (path, {required select}) async => revealed = path;
    await tapIo(
      tester,
      find.descendant(
        of: find.byKey(
          const ValueKey('saved-backup-zangetsu-auto-20261117-080000.json'),
        ),
        matching: find.text('Show in folder'),
      ),
    );
    expect(revealed, endsWith('zangetsu-auto-20261117-080000.json'));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('preview -> restore ticked parts -> undo -> restart', (
    tester,
  ) async {
    await pump(tester);
    await tapIo(
      tester,
      find.descendant(
        of: find.byKey(
          const ValueKey('saved-backup-zangetsu-auto-20261117-080000.json'),
        ),
        matching: find.text('Restore'),
      ),
    );

    // Preview: date, counts, sources absent, settings warning.
    expect(find.text('Restore this backup?'), findsOneWidget);
    expect(find.textContaining('made 2026-11-17'), findsOneWidget);
    expect(find.text('3 list items'), findsOneWidget);
    expect(find.text('Not in this backup'), findsOneWidget);
    expect(find.textContaining('settings will be replaced'), findsOneWidget);

    // Leave the library out; only settings are restored.
    await tester.tap(find.byKey(const ValueKey('restore-preview-library')));
    await tester.pump();
    await tapIo(tester, find.byKey(const ValueKey('restore-preview-confirm')));
    expect(service.restored, {BackupBundle.settings});

    // The safety copy was written next to the automatic backups.
    final safety = folder.listSync().where(
      (e) => e.path.contains('zangetsu-before-restore-'),
    );
    expect(safety, hasLength(1));
    expect(find.text('Restore complete'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('restore-result-safety-path')),
      findsOneWidget,
    );
    expect(Hive.box('playback_prefs').get('speed'), 2.0);

    // Undo puts the settings back exactly.
    await tapIo(tester, find.byKey(const ValueKey('restore-result-undo')));
    expect(Hive.box('playback_prefs').get('speed'), 1.0);
    expect(Hive.box('playback_prefs').containsKey('added'), isFalse);
    expect(
      find.byKey(const ValueKey('restore-undone-snackbar')),
      findsOneWidget,
    );

    // The snackbar offers a restart too.
    await tester.tap(find.text('Restart now'));
    await tester.pump();
    expect(restarts, 1);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Restart now in the result dialog relaunches the app', (
    tester,
  ) async {
    await pump(tester);
    await tapIo(
      tester,
      find.descendant(
        of: find.byKey(
          const ValueKey('saved-backup-zangetsu-auto-20261117-080000.json'),
        ),
        matching: find.text('Restore'),
      ),
    );
    await tapIo(tester, find.byKey(const ValueKey('restore-preview-confirm')));
    expect(service.restored, {BackupBundle.library, BackupBundle.settings});
    // The restore flow was started inside real time, so its continuation
    // after the dialog closes runs there too.
    await tapIo(tester, find.byKey(const ValueKey('restore-result-restart')));
    expect(restarts, 1);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('cancelling the preview restores nothing', (tester) async {
    await pump(tester);
    await tapIo(
      tester,
      find.descendant(
        of: find.byKey(
          const ValueKey('saved-backup-zangetsu-auto-20261117-080000.json'),
        ),
        matching: find.text('Restore'),
      ),
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(service.restored, isNull);
    expect(find.text('Restore this backup?'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });
}
