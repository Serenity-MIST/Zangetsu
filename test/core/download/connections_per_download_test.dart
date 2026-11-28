// ignore_for_file: implementation_imports
import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart' show Config;
import 'package:background_downloader/src/desktop/desktop_downloader.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/download/chapter_download_store.dart';
import 'package:watch_app/core/download/chapter_downloader.dart';
import 'package:watch_app/core/download/direct_file_connections.dart';
import 'package:watch_app/core/download/download_manager.dart';
import 'package:watch_app/core/download/download_prefs.dart';
import 'package:watch_app/core/download/hls_downloader.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/page_content.dart';
import 'package:watch_app/core/repository/source_repository.dart';

/// The "Connections per download" setting, followed from the saved value to
/// each downloader that reads it. No real network: every request is answered
/// by an in-memory host that holds requests open so the live count can be read.

/// Answers HEAD and the one-byte range probe like a host that splits files.
class _RangeHost implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, _, _) async {
    if (options.method == 'HEAD') {
      return ResponseBody.fromString(
        '',
        200,
        headers: {
          'content-length': ['8000'],
          'accept-ranges': ['bytes'],
        },
      );
    }
    return ResponseBody.fromBytes(
      [1],
      206,
      headers: {
        'content-length': ['1'],
        'content-range': ['bytes 0-0/8000'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Holds every media request (HLS segment or chapter page) until released,
/// counting how many are open at the same moment.
class _HeldHost implements HttpClientAdapter {
  int active = 0;
  int started = 0;
  int peak = 0;
  Completer<void> gate = Completer<void>();
  Completer<void>? _reached;
  int _waitFor = 0;

  /// Completes when [n] requests are open together.
  Future<void> reach(int n) {
    if (active >= n) return Future.value();
    _waitFor = n;
    return (_reached = Completer<void>()).future;
  }

  @override
  Future<ResponseBody> fetch(RequestOptions options, _, _) async {
    if (options.path.endsWith('.m3u8')) {
      return ResponseBody.fromString(
        [
          '#EXTM3U',
          '#EXT-X-TARGETDURATION:1',
          for (var i = 0; i < 40; i++) ...[
            '#EXTINF:1,',
            'https://fixture.test/$i.ts',
          ],
          '#EXT-X-ENDLIST',
        ].join('\n'),
        200,
      );
    }
    active++;
    started++;
    if (active > peak) peak = active;
    final r = _reached;
    if (r != null && active >= _waitFor && !r.isCompleted) r.complete();
    await gate.future;
    active--;
    return ResponseBody.fromBytes(List.filled(188, 0x47), 200);
  }

  @override
  void close({bool force = false}) {}
}

/// A source with one chapter of [count] pages on the fixture host.
class _PagesRepository implements SourceRepository {
  _PagesRepository(this.count);
  final int count;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  Future<bool> ensureSourceLoaded(String sourceId) async => true;
  @override
  Future<List<PageImage>> pages(String chapterUrl, {String? sourceId}) async =>
      [
        for (var i = 0; i < count; i++)
          PageImage(url: 'https://fixture.test/p$i.jpg'),
      ];
}

/// Tells the test when a canceled chapter has finished its own cleanup.
class _Store extends ChapterDownloadStore {
  final removed = Completer<void>();
  @override
  Future<void> remove(String id) async {
    await super.remove(id);
    if (!removed.isCompleted) removed.complete();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('connections-per-download-');
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => dir.path,
        );
    Hive.init(dir.path);
    await Hive.openBox(DownloadPrefs.boxName);
  });

  tearDown(() async {
    if (sl.isRegistered<DownloadPrefs>()) sl.unregister<DownloadPrefs>();
    await Hive.close();
    for (var i = 0; i < 5; i++) {
      try {
        await dir.delete(recursive: true);
        break;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
  });

  test(
    'saved value: default 4, kept between 1 and 8, survives a restart',
    () async {
      final prefs = DownloadPrefs();
      expect(prefs.connectionsPerDownload, 4);
      await prefs.setConnectionsPerDownload(8);
      expect(prefs.connectionsPerDownload, 8);
      await prefs.setConnectionsPerDownload(99);
      expect(Hive.box(DownloadPrefs.boxName).get('connections'), 8);
      await prefs.setConnectionsPerDownload(0);
      expect(prefs.connectionsPerDownload, 1);
      // A value written by some older build outside the range is still clamped.
      await Hive.box(DownloadPrefs.boxName).put('connections', 50);
      expect(prefs.connectionsPerDownload, 8);
      await prefs.setConnectionsPerDownload(6);
      await Hive.close();
      Hive.init(dir.path);
      await Hive.openBox(DownloadPrefs.boxName);
      expect(DownloadPrefs().connectionsPerDownload, 6);
    },
  );

  test(
    'direct file: a splittable host gets the chosen count, never above 8',
    () async {
      final client = Dio()..httpClientAdapter = _RangeHost();
      const url = 'https://fixture.test/video.mp4';
      expect(await directFileConnections(client, url, {}, 8), 8);
      expect(await directFileConnections(client, url, {}, 3), 3);
      expect(await directFileConnections(client, url, {}, 99), 8);
    },
  );

  test('direct file: the engine limit the app sets leaves room for every '
      'connection of every parallel episode', () async {
    // A split file holds one engine place for itself plus one per chunk. The
    // engine's built-in 10 left 3 files x 8 chunks only 7 chunks in all, so
    // DownloadManager raises it to parallelMax x (connectionsMax + 1).
    final engine = DesktopDownloader();
    expect(engine.maxConcurrent, 10, reason: 'library default');
    expect(DownloadManager.desktopEngineTaskLimit, 90);
    expect(
      DownloadManager.desktopEngineTaskLimit,
      greaterThanOrEqualTo(
        DownloadPrefs.parallelMax * (DownloadPrefs.connectionsMax + 1),
      ),
    );
    try {
      await engine.configureItem((
        Config.holdingQueue,
        (DownloadManager.desktopEngineTaskLimit, null, null),
      ));
      expect(engine.maxConcurrent, DownloadManager.desktopEngineTaskLimit);
      expect(engine.maxConcurrentByHost, DesktopDownloader.unlimited);
    } finally {
      // The engine is a process-wide singleton: put the default back.
      await engine.configureItem((Config.holdingQueue, (null, null, null)));
    }
  });

  test(
    'HLS: the count is read when the episode starts, a running one keeps it',
    () async {
      final prefs = DownloadPrefs();
      await prefs.setConnectionsPerDownload(3);
      final host = _HeldHost();
      final client = Dio()..httpClientAdapter = host;
      try {
        // Same as the manager: the setting is read once, as the call starts.
        final transfer = HlsDownloader(client).download(
          url: 'https://fixture.test/index.m3u8',
          headers: const {},
          outputPath: '${dir.path}/a.ts',
          preferredQuality: 'best',
          connections: prefs.connectionsPerDownload,
          onProgress: (_) {},
          canceled: () => false,
        );
        await host.reach(3).timeout(const Duration(seconds: 5));
        await prefs.setConnectionsPerDownload(8);
        host.gate.complete();
        expect(await transfer, isNull);
        expect(host.peak, 3);

        // The next episode picks up the new value.
        final next = _HeldHost();
        client.httpClientAdapter = next;
        final second = HlsDownloader(client).download(
          url: 'https://fixture.test/index.m3u8',
          headers: const {},
          outputPath: '${dir.path}/b.ts',
          preferredQuality: 'best',
          connections: prefs.connectionsPerDownload,
          onProgress: (_) {},
          canceled: () => false,
        );
        await next.reach(8).timeout(const Duration(seconds: 5));
        next.gate.complete();
        expect(await second, isNull);
        expect(next.peak, 8);
      } finally {
        client.close(force: true);
      }
    },
  );

  test(
    'chapter: pages fetched at once follow the setting, a running chapter keeps its count',
    () async {
      final prefs = DownloadPrefs();
      await prefs.setLocation(dir.path, 'Fixture');
      await prefs.setConnectionsPerDownload(8);
      sl.registerSingleton<DownloadPrefs>(prefs);
      await ChapterDownloadStore.init();
      final host = _HeldHost();
      final store = _Store();
      final downloader = ChapterDownloader(
        _PagesRepository(40),
        store,
        dio: Dio()..httpClientAdapter = host,
      );
      try {
        await downloader.enqueue(
          chapter: const Episode(
            id: 'c1',
            title: 'Chapter 1',
            url: 'https://x/c1',
            number: 1,
          ),
          sourceId: 'src',
          showId: 'show',
          showTitle: 'Show',
          mode: ContentMode.manga,
        );
        await host.reach(8).timeout(const Duration(seconds: 5));
        expect(host.active, 8);
        // Lowered mid-chapter: the eight page workers already running stay.
        await prefs.setConnectionsPerDownload(2);
        final first = host.gate;
        host.gate = Completer<void>();
        first.complete();
        // Let the released pages finish so only the next wave is counted.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await host.reach(8).timeout(const Duration(seconds: 5));
        expect(host.active, 8);
        expect(host.started, 16);
        expect(host.peak, 8);
      } finally {
        await downloader.cancelAll();
        if (!host.gate.isCompleted) host.gate.complete();
        // Wait for the canceled chapter to finish cleaning up before the store
        // is closed under it.
        await store.removed.future.timeout(const Duration(seconds: 5));
        downloader.dispose();
        await Hive.deleteBoxFromDisk(ChapterDownloadStore.boxName);
      }
    },
  );
}
