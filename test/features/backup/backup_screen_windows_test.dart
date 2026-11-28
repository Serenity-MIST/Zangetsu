// Windows desktop behaviour of Backup & restore: graphite checkbox rows,
// "Save to a file" through the Save-as dialog with the real path reported and
// a working "Show in folder" action. Phone/TV paths are covered elsewhere.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/backup/backup_file.dart';
import 'package:watch_app/core/backup/backup_payload.dart';
import 'package:watch_app/core/backup/backup_service.dart';
import 'package:watch_app/core/desktop/desktop_reveal.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/supabase/supabase_service.dart';
import 'package:watch_app/core/ui/desktop_settings_surface.dart';
import 'package:watch_app/features/auth/auth_cubit.dart';
import 'package:watch_app/features/backup/backup_screen.dart';

/// Records which bundles were exported; no Hive or network needed.
class _FakeBackupService implements BackupService {
  Set<BackupBundle>? built;

  @override
  Future<void> authorize() async {}

  @override
  Future<Map<String, dynamic>> buildProtected(
    Set<BackupBundle> bundles, {
    String? password,
    bool forFile = false,
  }) async {
    built = {...bundles};
    return {'app': 'zangetsu', 'bundles': {}};
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  late Directory dir;
  late _FakeBackupService service;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('backup_win_');
    TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => dir.path,
        );
    service = _FakeBackupService();
    sl
      ..registerSingleton<AppMode>(const AppMode(isTv: false))
      ..registerSingleton<BackupService>(service);
  });

  tearDown(() {
    sl.reset();
    BackupFile.debugSaveDialog = null;
    debugRevealOverride = null;
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<void> pump(WidgetTester tester, Size size) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = size;
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
    await tester.pump();
  }

  for (final size in const [Size(1280, 720), Size(1920, 1080)]) {
    testWidgets('graphite checkbox rows toggle at ${size.width}', (
      tester,
    ) async {
      await pump(tester, size);
      // No phone CheckboxListTile inside the graphite panel.
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(find.byType(GraphiteSettingsControl), findsWidgets);
      final library = find.byKey(const ValueKey('backup-bundle-library'));
      expect(tester.widget<Checkbox>(library).value, isTrue);
      // Clicking the row (not just the box) toggles it.
      await tester.tap(find.text('Library'));
      await tester.pump();
      expect(tester.widget<Checkbox>(library).value, isFalse);
      await tester.tap(library);
      await tester.pump();
      expect(tester.widget<Checkbox>(library).value, isTrue);
      expect(
        find.text('Choose where to save a backup file on this PC'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('Save to a file writes where the user chose and reveals it', (
    tester,
  ) async {
    await pump(tester, const Size(1280, 720));
    // Leave out Sources so no add-on password prompt is involved.
    await tester.tap(find.byKey(const ValueKey('backup-bundle-sources')));
    await tester.pump();

    final target = File('${dir.path}${Platform.pathSeparator}chosen.json');
    String? suggested;
    BackupFile.debugSaveDialog = (name, Uint8List bytes) async {
      suggested = name;
      await target.writeAsBytes(bytes);
      return target.path;
    };
    String? revealed;
    bool? selected;
    debugRevealOverride = (path, {required select}) async {
      revealed = path;
      selected = select;
    };

    await tester.runAsync(() async {
      await tester.tap(find.text('Save to a file'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    // Let the snackbar finish sliding in before its action is tapped.
    await tester.pumpAndSettle();

    expect(suggested, matches(RegExp(r'^zangetsu-backup-\d{8}-\d{4}\.json$')));
    expect(service.built, {BackupBundle.library, BackupBundle.settings});
    expect(target.existsSync(), isTrue);
    expect(find.text('Backup saved to ${target.path}'), findsOneWidget);
    // The phone "Downloads › Zangetsu" claim never appears on Windows.
    expect(find.textContaining('Downloads ›'), findsNothing);

    await tester.runAsync(() async {
      await tester.tap(find.text('Show in folder'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    expect(revealed, target.path);
    expect(selected, isTrue);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('cancelling the Save-as dialog shows nothing', (tester) async {
    await pump(tester, const Size(1280, 720));
    await tester.tap(find.byKey(const ValueKey('backup-bundle-sources')));
    await tester.pump();
    BackupFile.debugSaveDialog = (_, _) async => null;
    await tester.runAsync(() async {
      await tester.tap(find.text('Save to a file'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(find.byType(SnackBar), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a write failure is reported, not silently swallowed', (
    tester,
  ) async {
    await pump(tester, const Size(1280, 720));
    await tester.tap(find.byKey(const ValueKey('backup-bundle-sources')));
    await tester.pump();
    BackupFile.debugSaveDialog = (_, _) async =>
        throw const FileSystemException('denied');
    await tester.runAsync(() async {
      await tester.tap(find.text('Save to a file'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(find.textContaining("Couldn't save the backup file"), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}
