// Windows Downloads rescans (dl-13): regaining focus rescans the disk at most
// once a minute, while the Refresh button and F5 rescan straight away.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:watch_app/features/downloads/downloads_screen.dart';

/// Empty library that counts disk rescans.
class _Manager extends ChangeNotifier implements DownloadManager {
  int scans = 0;

  @override
  List<DownloadRecord> get all => const [];

  @override
  Map<String, List<DownloadRecord>> get byShow => const {};

  // The embedded queue panel reads this.
  @override
  List<DownloadRecord> get queueItems => const [];

  @override
  Future<void> recoverLocalFiles() async => scans++;

  @override
  Future<void> pruneMissing() async {}

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
    directory = await Directory.systemTemp.createTemp('dl_refresh_win_');
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

  /// Opens the Windows Downloads page; the first rescan runs on open.
  Future<void> open(WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(home: DownloadsScreen(showBack: false)),
    );
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('focus rescans once a minute; Refresh and F5 rescan now', (
    tester,
  ) async {
    await open(tester);
    expect(manager.scans, 1);

    // Alt-Tab back right away: no second scan.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(manager.scans, 1);

    // The Refresh button ignores the focus timer.
    await tester.tap(find.byKey(const ValueKey('downloads-refresh')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(manager.scans, 2);

    // So does F5 (the library holds keyboard focus).
    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    await tester.pump(const Duration(milliseconds: 100));
    expect(manager.scans, 3);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}
