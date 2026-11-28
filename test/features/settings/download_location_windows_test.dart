// Windows Download location page: always desktop-styled (also when pushed
// from the Downloads dock tab), shows the real folder, Reset returns to the
// real default at once and hides itself, Choose/Open work, and nothing
// overflows at 1280x720 or 1920x1080.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/desktop/desktop_reveal.dart';
import 'package:watch_app/core/desktop/desktop_storage.dart';
import 'package:watch_app/core/download/download_manager.dart';
import 'package:watch_app/core/download/download_prefs.dart';
import 'package:watch_app/core/ui/desktop_settings_surface.dart';
import 'package:watch_app/features/settings/download_location_screen.dart';

class _DownloadManager extends Fake implements DownloadManager {
  @override
  Future<List<({String path, String label, bool removable})>>
  listDownloadVolumes() async => const [];
}

void main() {
  late Directory dir;
  late String fallback;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('dl_loc_win_');
    Hive.init(dir.path);
    await Hive.openBox(DownloadPrefs.boxName);
    fallback = '${dir.path}\\Downloads\\Zangetsu';
    DesktopStorage.downloadsRoot = fallback;
    GetIt.instance
      ..registerSingleton<DownloadPrefs>(DownloadPrefs())
      ..registerSingleton<DownloadManager>(_DownloadManager());
  });

  tearDown(() async {
    DesktopStorage.downloadsRoot = null;
    DownloadPrefs.debugPickDirectory = null;
    debugRevealOverride = null;
    await GetIt.instance.reset();
    await Hive.deleteFromDisk();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  Future<void> pump(WidgetTester tester, Size size) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // Pushed with a plain route, outside the settings workspace — like the
    // Downloads dock tab does.
    await tester.pumpWidget(const MaterialApp(home: DownloadLocationScreen()));
    await tester.pump();
  }

  for (final size in const [Size(1280, 720), Size(1920, 1080)]) {
    testWidgets('desktop styling and default folder at ${size.width}', (
      tester,
    ) async {
      if (!Platform.isWindows) return;
      // Hive writes need real async; fake test time never completes them.
      await tester.runAsync(
        () => GetIt.instance<DownloadPrefs>().setLocation(fallback, fallback),
      );
      await pump(tester, size);
      expect(find.byType(GraphiteSettingsPanel), findsWidgets);
      expect(find.text(fallback), findsOneWidget);
      expect(find.text('Default folder'), findsOneWidget);
      // Already at the default: no dead Reset row, no phone-only rows.
      expect(
        find.byKey(const ValueKey('download-location-reset')),
        findsNothing,
      );
      expect(find.text('Keep downloads private'), findsNothing);
      expect(find.text('Available drives'), findsNothing);
      // Opened outside Settings: the shared settings column, centred in
      // the window.
      final card = tester.getRect(
        find
            .descendant(
              of: find.byType(GraphiteSettingsPanel).first,
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      expect(card.width, kDesktopSettingsContentMaxWidth);
      expect(card.left, (size.width - kDesktopSettingsContentMaxWidth) / 2);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('Reset returns to the real default immediately', (tester) async {
    if (!Platform.isWindows) return;
    final prefs = GetIt.instance<DownloadPrefs>();
    await tester.runAsync(() => prefs.setLocation(r'D:\Anime', r'D:\Anime'));
    await pump(tester, const Size(1280, 720));
    expect(find.text(r'D:\Anime'), findsOneWidget);
    final reset = find.byKey(const ValueKey('download-location-reset'));
    expect(reset, findsOneWidget);
    // The row tells the user where Reset goes.
    expect(find.text(fallback), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(reset);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();

    expect(prefs.locationUri, fallback);
    expect(reset, findsNothing);
    expect(find.text('Default folder'), findsOneWidget);
    expect(find.text('New downloads will save to $fallback'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Choose folder saves a writable pick and refuses a bad one', (
    tester,
  ) async {
    if (!Platform.isWindows) return;
    final prefs = GetIt.instance<DownloadPrefs>();
    await tester.runAsync(() => prefs.setLocation(fallback, fallback));
    await pump(tester, const Size(1280, 720));
    final chosen = '${dir.path}\\Picked';
    DownloadPrefs.debugPickDirectory = () async => chosen;
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('download-location-choose')));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(prefs.locationUri, chosen);
    expect(find.text(chosen), findsWidgets);
    expect(
      find.byKey(const ValueKey('download-location-reset')),
      findsOneWidget,
    );

    final blocker = File('${dir.path}\\blocker')..writeAsStringSync('x');
    DownloadPrefs.debugPickDirectory = () async => '${blocker.path}\\sub';
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('download-location-choose')));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(prefs.locationUri, chosen);
    expect(find.textContaining("Zangetsu can't save files in"), findsOneWidget);
    // Let the replaced snackbar's real-zone completion run while mounted.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Open in File Explorer opens the current folder', (tester) async {
    if (!Platform.isWindows) return;
    final folder = Directory('${dir.path}\\Existing')..createSync();
    await tester.runAsync(
      () =>
          GetIt.instance<DownloadPrefs>().setLocation(folder.path, folder.path),
    );
    String? opened;
    bool? selected;
    debugRevealOverride = (path, {required select}) async {
      opened = path;
      selected = select;
    };
    await pump(tester, const Size(1280, 720));
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('download-location-open')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(opened, folder.path);
    expect(selected, isFalse);

    // A folder that doesn't exist yet is explained, not opened.
    opened = null;
    await tester.runAsync(
      () => GetIt.instance<DownloadPrefs>().setLocation(
        '${dir.path}\\Missing',
        '${dir.path}\\Missing',
      ),
    );
    await tester.pumpWidget(const MaterialApp(home: DownloadLocationScreen()));
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('download-location-open')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(opened, isNull);
    expect(find.textContaining("doesn't exist yet"), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}
