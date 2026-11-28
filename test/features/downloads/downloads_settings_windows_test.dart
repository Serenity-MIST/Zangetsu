// Windows Downloads page: "Download settings" opens a centered desktop
// dialog (never the phone bottom sheet), both sliders persist, Parallel
// downloads is applied to the running manager live, and the dialog fits
// 1280x720 and 1920x1080 without overflow.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/download/chapter_download.dart';
import 'package:watch_app/core/download/chapter_download_store.dart';
import 'package:watch_app/core/download/chapter_downloader.dart';
import 'package:watch_app/core/download/download_manager.dart';
import 'package:watch_app/core/download/download_prefs.dart';
import 'package:watch_app/core/download/download_record.dart';
import 'package:watch_app/core/playback/resume_store.dart';
import 'package:watch_app/features/downloads/desktop_download_settings_dialog.dart';
import 'package:watch_app/features/downloads/downloads_screen.dart';

/// Empty library; records the live parallel limit the dialog applies.
class _Manager extends ChangeNotifier implements DownloadManager {
  int? parallel;

  @override
  List<DownloadRecord> get all => const [];

  @override
  Map<String, List<DownloadRecord>> get byShow => const {};

  // The Windows library embeds the queue panel (dl-5), which reads this.
  @override
  List<DownloadRecord> get queueItems => const [];

  @override
  Future<void> pruneMissing() async {}

  @override
  Future<void> recoverLocalFiles() async {}

  @override
  void setParallel(int n) => parallel = n;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ChapterDownloader extends ChangeNotifier implements ChapterDownloader {
  @override
  Map<String, ChapterDownload> get inFlight => const {};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory directory;
  late _Manager manager;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('dl_settings_win_');
    Hive.init(directory.path);
    await Hive.openBox(DownloadPrefs.boxName);
    await Hive.openBox<Map>(ChapterDownloadStore.boxName);
    await Hive.openBox<Map>(ResumeStore.boxName);
    manager = _Manager();
    GetIt.instance
      ..registerSingleton<AppMode>(const AppMode(isTv: false))
      ..registerSingleton<DownloadManager>(manager)
      ..registerSingleton<DownloadPrefs>(DownloadPrefs())
      ..registerSingleton<ChapterDownloadStore>(ChapterDownloadStore())
      ..registerSingleton<ChapterDownloader>(_ChapterDownloader())
      ..registerSingleton<ResumeStore>(ResumeStore());
  });

  tearDown(() async {
    await GetIt.instance.reset();
    await Hive.close();
    await directory.delete(recursive: true);
  });

  /// [realAsync] opens the dialog from the real event loop, so the Hive
  /// write made when it closes can finish (a fake-time write never does).
  Future<void> open(
    WidgetTester tester,
    Size size, {
    bool realAsync = false,
  }) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(home: DownloadsScreen(showBack: false)),
    );
    await tester.pump(const Duration(milliseconds: 500));
    if (realAsync) {
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('Download settings'));
      });
    } else {
      await tester.tap(find.byTooltip('Download settings'));
    }
    await tester.pumpAndSettle();
  }

  for (final size in const [Size(1280, 720), Size(1920, 1080)]) {
    testWidgets('desktop dialog, not a bottom sheet, at ${size.width}', (
      tester,
    ) async {
      await open(tester, size);
      expect(find.byType(DesktopDownloadSettingsDialog), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(Slider), findsNWidgets(2));
      // Bounded and centred rather than stretched across the window.
      // The Dialog widget spans the window; its Material is the visible card.
      final box = tester.getRect(
        find
            .descendant(
              of: find.byKey(const ValueKey('desktop-download-settings')),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(
        box.width,
        lessThanOrEqualTo(DesktopDownloadSettingsDialog.maxWidth),
      );
      expect(box.center.dx, closeTo(size.width / 2, 1));
      // Defaults are shown.
      expect(find.text('3'), findsWidgets);
      expect(find.text('4'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(DesktopDownloadSettingsDialog), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('sliders persist and Parallel applies live', (tester) async {
    await open(tester, const Size(1280, 720));
    final prefs = GetIt.instance<DownloadPrefs>();
    final parallel = find.descendant(
      of: find.byKey(const ValueKey('desktop-parallel-downloads')),
      matching: find.byType(Slider),
    );
    final connections = find.descendant(
      of: find.byKey(const ValueKey('desktop-connections-per-download')),
      matching: find.byType(Slider),
    );
    // Drag Parallel to the far right (10) and Connections to the far left (1).
    await tester.runAsync(() async {
      await tester.drag(parallel, const Offset(600, 0));
      await tester.drag(connections, const Offset(-600, 0));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(manager.parallel, DownloadPrefs.parallelMax);
    expect(prefs.parallelDownloads, DownloadPrefs.parallelMax);
    expect(prefs.connectionsPerDownload, DownloadPrefs.connectionsMin);
    // The badges show the new values while the dialog is still open.
    expect(find.text('10'), findsWidgets);

    // Closing keeps them; reopening shows the saved values.
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Download settings'));
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(parallel).value, 10);
    expect(tester.widget<Slider>(connections).value, 1);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('keyboard changes are saved when the dialog closes', (
    tester,
  ) async {
    await open(tester, const Size(1280, 720), realAsync: true);
    final prefs = GetIt.instance<DownloadPrefs>();
    final connections = find.descendant(
      of: find.byKey(const ValueKey('desktop-connections-per-download')),
      matching: find.byType(Slider),
    );
    final slider = tester.widget<Slider>(connections);
    // Simulate a keyboard step that only reports onChanged.
    slider.onChanged!(6);
    await tester.pump();
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    // Give the Hive write real time to land, then flush its callbacks.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();
    expect(prefs.connectionsPerDownload, 6);
    debugDefaultTargetPlatformOverride = null;
  });
}
