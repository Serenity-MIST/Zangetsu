// Windows Storage page: shows the real poster-cache size from the app-owned
// AppData\Temp folder, clearing it frees the space and updates the number
// at once, and "Open app data folder" opens the real folder.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/cache/media_cache.dart';
import 'package:watch_app/core/desktop/desktop_reveal.dart';
import 'package:watch_app/core/desktop/desktop_storage.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/provider/provider_downloader.dart';
import 'package:watch_app/core/ui/desktop_settings_surface.dart';
import 'package:watch_app/features/settings/settings_screen.dart';
import 'package:watch_app/l10n/app_localizations.dart';

class _ProviderDownloader implements ProviderDownloader {
  var cleared = false;

  @override
  Future<void> clear() async => cleared = true;

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  late Directory root;
  late _ProviderDownloader provider;

  setUp(() {
    root = Directory.systemTemp.createTempSync('storage_win_');
    DesktopStorage.root = root.path;
    // On Windows path_provider's temp dir is routed to AppData\Temp.
    TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => p.join(root.path, 'AppData', 'Temp'),
        );
    MediaCache.debugIsWindows = true;
    provider = _ProviderDownloader();
    sl
      ..registerSingleton<AppMode>(const AppMode(isTv: false))
      ..registerSingleton<ProviderDownloader>(provider);
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    debugRevealOverride = null;
    MediaCache.debugIsWindows = null;
    DesktopStorage.root = null;
    await sl.reset();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> pump(WidgetTester tester, Size size) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // The size measurement starts on first build and is real file IO, so
    // the first build runs on the real event loop.
    await tester.runAsync(() async {
      await tester.pumpWidget(
        const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DesktopSettingsScope(child: StorageSettingsScreen()),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
  }

  for (final size in const [Size(1280, 720), Size(1920, 1080)]) {
    testWidgets('cache size, clear and app data folder at ${size.width}', (
      tester,
    ) async {
      final posters = Directory(
        p.join(root.path, 'AppData', 'Temp', 'libCachedImageData'),
      )..createSync(recursive: true);
      File(p.join(posters.path, 'a.jpg')).writeAsBytesSync(
        List.filled(3 * 1024 * 1024, 1),
      );
      await pump(tester, size);
      // set-6 dashboard row: '<size> · <description>'.
      expect(find.textContaining('3.0 MB · Cover images'), findsOneWidget);
      expect(find.text(root.path), findsOneWidget);

      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('storage-clear-posters')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('0 B · Cover images'), findsOneWidget);
      expect(find.textContaining('3.0 MB freed'), findsOneWidget);
      expect(posters.listSync(), isEmpty);

      String? opened;
      debugRevealOverride = (path, {required select}) async => opened = path;
      // The set-6 dashboard is taller: scroll the row into view first.
      await tester.ensureVisible(find.text('Open app data folder'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('Open app data folder'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      expect(opened, root.path);
      expect(tester.takeException(), isNull);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('Clearing source scripts asks first, then clears', (tester) async {
    await pump(tester, const Size(1280, 720));
    // set-6: the dashboard row asks before wiping the source scripts.
    await tester.tap(find.text('Source scripts'));
    await tester.pumpAndSettle();
    expect(find.text('Clear source scripts?'), findsOneWidget);
    expect(provider.cleared, isFalse);
    await tester.runAsync(() async {
      await tester.sendKeyEvent(LogicalKeyboardKey.enter); // Enter confirms
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(provider.cleared, isTrue);
    debugDefaultTargetPlatformOverride = null;
  });
}
