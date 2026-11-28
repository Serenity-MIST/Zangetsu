import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:background_downloader/background_downloader.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:watch_app/core/download/download_manager.dart';
import 'package:watch_app/core/download/download_prefs.dart';
import 'package:watch_app/core/download/download_record.dart';
import 'package:watch_app/core/hive/safe_box.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/repository/catalogue_repository.dart';

/// Keeps every application-support write inside the disposable fixture.
class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

/// Native (direct-file) tasks stay pending until the test sends a status.
class _NativeDownloads implements FileDownloader {
  final events = StreamController<TaskUpdate>.broadcast();
  final tasks = <Task>[];
  @override
  Future<List<Task>> allTasks({
    String group = 'default',
    bool includeTasksWaitingToRetry = true,
    bool allGroups = false,
  }) async => const [];
  @override
  Stream<TaskUpdate> get updates => events.stream;
  @override
  Future<bool> enqueue(Task task) async {
    tasks.add(task);
    return true;
  }

  @override
  Future<bool> cancelTaskWithId(String taskId) async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #configureNotification) return this;
    if (invocation.memberName == #addTaskQueue) return null;
    return super.noSuchMethod(invocation);
  }
}

/// Answers a re-resolve with the streams the test set.
class _Catalogue implements CatalogueRepository {
  final streams = <String, List<VideoSource>>{};
  @override
  Future<List<VideoSource>> sources(
    String episodeUrl, {
    String? sourceId,
    bool fast = false,
  }) async => streams[episodeUrl] ?? const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A real HLS server on 127.0.0.1; one per mirror.
class _LoopbackHls {
  _LoopbackHls._(this._server);
  final HttpServer _server;
  static const int segments = 20;
  final requests = <int>[];
  int playlistRequests = 0;
  bool Function(int i)? drop;
  int? Function(int i)? status;
  Future<void> Function(int i)? hold;

  static Future<_LoopbackHls> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final host = _LoopbackHls._(server);
    server.listen(host._handle);
    return host;
  }

  String get url => 'http://127.0.0.1:${_server.port}/E1/index.m3u8';

  static Uint8List segment(int i) =>
      Uint8List.fromList(List<int>.generate(300, (k) => (i * 7 + k) % 251));

  static List<int> whole() => [
    for (var i = 0; i < segments; i++) ...segment(i),
  ];

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    if (path.endsWith('.m3u8')) {
      playlistRequests++;
      request.response.write(
        [
          '#EXTM3U',
          '#EXT-X-TARGETDURATION:1',
          for (var i = 0; i < segments; i++) ...['#EXTINF:1.0,', 's$i.ts'],
          '#EXT-X-ENDLIST',
        ].join('\n'),
      );
      await request.response.close();
      return;
    }
    final name = path.split('/').last;
    final i = int.parse(name.substring(1, name.length - 3));
    requests.add(i);
    await hold?.call(i);
    if (drop?.call(i) == true) {
      final socket = await request.response.detachSocket(writeHeaders: false);
      socket.destroy();
      return;
    }
    final code = status?.call(i);
    if (code != null) {
      request.response.statusCode = code;
      await request.response.close();
      return;
    }
    request.response.add(segment(i));
    await request.response.close();
  }

  Future<void> close() => _server.close(force: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // These tests talk to their own server on 127.0.0.1: use the real client.
  HttpOverrides.global = null;
  late Directory root;
  late PathProviderPlatform originalPaths;
  late _NativeDownloads native;
  late _Catalogue catalogue;
  late _LoopbackHls alpha;
  late _LoopbackHls beta;
  late Dio dio;
  late DownloadManager manager;
  const episode = Episode(id: 'E1', title: 'E1', url: 'https://fixture.test/E1');

  DownloadManager makeManager() =>
      DownloadManager(catalogue, DownloadPrefs(), null, dio, native)
        ..hlsRetryDelays = const [Duration(milliseconds: 10)]
        ..hlsNetworkPatience = const Duration(milliseconds: 250)
        ..waitForNetwork = (() async {})
        ..networkOffline = (() => false)
        // Long, so only the reconnect hook can bring a waiting row back.
        ..networkRetryDelay = const Duration(hours: 1)
        ..setup();

  setUp(() async {
    root = await Directory.systemTemp.createTemp('manager-review-');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    hiveBoxDir = root.path;
    Hive.init(root.path);
    await DownloadPrefs.init();
    await DownloadPrefs().setLocation(root.path, root.path);
    await DownloadPrefs().setParallelDownloads(1);
    await DownloadPrefs().setConnectionsPerDownload(1);
    await DownloadManager.init();
    native = _NativeDownloads();
    catalogue = _Catalogue();
    alpha = await _LoopbackHls.start();
    beta = await _LoopbackHls.start();
    dio = Dio();
    manager = makeManager();
  });

  tearDown(() async {
    manager.dispose();
    await native.events.close();
    dio.close(force: true);
    await alpha.close();
    await beta.close();
    PathProviderPlatform.instance = originalPaths;
    await Hive.close();
    hiveBoxDir = null;
    for (var i = 0; i < 20; i++) {
      try {
        await root.delete(recursive: true);
        break;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  VideoSource hls(_LoopbackHls host, String label) =>
      VideoSource(url: host.url, label: label, container: SourceContainer.hls);

  Future<void> enqueue(VideoSource source, [List<VideoSource> others = const []]) {
    catalogue.streams[episode.url] = [source, ...others];
    return manager.enqueueSource(
      sourceId: 'fixture',
      showId: 'show',
      showTitle: 'Fixture',
      showUrl: 'https://fixture.test/show',
      category: 'sub',
      episode: episode,
      source: source,
      fallbacks: others,
      qualityLabel: 'best',
      nowMs: 1,
    );
  }

  Future<DownloadRecord> waitFor(
    bool Function(DownloadRecord r) test, {
    DownloadManager? on,
  }) async {
    final end = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(end)) {
      final all = (on ?? manager).all;
      if (all.isNotEmpty && test(all.single)) return all.single;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    throw TimeoutException('record never reached the state: ${(on ?? manager).all}');
  }

  Future<List<File>> leftovers(String suffix) async {
    final videos = Directory('${root.path}/Videos');
    if (!await videos.exists()) return const [];
    return videos
        .list(recursive: true)
        .where((e) => e is File && e.path.endsWith(suffix))
        .cast<File>()
        .toList();
  }

  test('a network wait goes back to the mirror the progress came from', () async {
    // Alpha serves a playlist but none of its segments: a real failure.
    alpha.status = (i) => 404;
    var down = true;
    beta.drop = (i) => i >= 8 && down;
    await enqueue(hls(alpha, 'Alpha'), [hls(beta, 'Beta')]);

    final waiting = await waitFor(
      (r) => r.status == DownloadStatus.queued && r.retryAt != null,
    );
    expect(waiting.error, 'Waiting for the network to come back');
    final saved = await leftovers('.ts.part.json');
    expect(saved, hasLength(1));
    final data = jsonDecode(await saved.single.readAsString());
    expect(data['next'], 8);
    expect(data['source'], 'beta|');

    down = false;
    alpha.requests.clear();
    final alphaPlaylists = alpha.playlistRequests;
    beta.requests.clear();
    await manager.wakeNetworkWaiters();
    final done = await waitFor((r) => r.status == DownloadStatus.done);

    // Straight back to Beta at segment 8; Alpha was not tried again first.
    expect(alpha.playlistRequests, alphaPlaylists);
    expect(alpha.requests, isEmpty);
    expect(beta.requests.first, 8);
    expect(await File(done.filePath!).readAsBytes(), _LoopbackHls.whole());
  });

  test('links that expire now and then do not end a download that moves', () async {
    // Every few segments the link "expires" once (403), five times in all:
    // more than the three refreshes allowed in a row, but with progress
    // between each one.
    final refused = <int>{};
    alpha.status = (i) => i % 3 == 2 && i < 16 && refused.add(i) ? 403 : null;
    await enqueue(hls(alpha, 'Alpha'));
    final done = await waitFor(
      (r) => r.status == DownloadStatus.done || r.status == DownloadStatus.failed,
    );
    expect(done.status, DownloadStatus.done);
    expect(refused, hasLength(5));
    expect(await File(done.filePath!).readAsBytes(), _LoopbackHls.whole());
  });

  test('an HLS download the app closed on carries on after start-up', () async {
    final reached = Completer<void>();
    final release = Completer<void>();
    alpha.hold = (i) async {
      if (i != 10) return;
      if (!reached.isCompleted) reached.complete();
      await release.future;
    };
    await enqueue(hls(alpha, 'Alpha'));
    await reached.future.timeout(const Duration(seconds: 10));
    // Wait until a progress file is on disk, then "close the app".
    for (var i = 0; i < 100 && (await leftovers('.ts.part.json')).isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final key = manager.all.single.storageKey;
    manager.dispose();
    release.complete();
    alpha.hold = null;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    alpha.requests.clear();

    // Next start: no Resume click needed.
    manager = makeManager();
    final done = await waitFor((r) => r.status == DownloadStatus.done);
    expect(done.storageKey, key);
    expect(alpha.requests.first, greaterThan(0));
    expect(await File(done.filePath!).readAsBytes(), _LoopbackHls.whole());
  });

  test('Retry with a new key removes the old partial left without progress', () async {
    var broken = true;
    alpha.status = (i) => i == 5 && broken ? 404 : null;
    await enqueue(hls(alpha, 'Alpha'));
    final failed = await waitFor((r) => r.status == DownloadStatus.failed);
    // A crash before the first save: the partial has no progress file.
    for (final file in await leftovers('.ts.part.json')) {
      await file.delete();
    }
    final orphan = await leftovers('.ts.part');
    expect(orphan, hasLength(1));

    broken = false;
    await manager.retry(failed);
    final done = await waitFor((r) => r.status == DownloadStatus.done);
    expect(done.storageKey, isNot(failed.storageKey));
    expect(await orphan.single.exists(), isFalse);
    expect(await leftovers('.ts.part'), isEmpty);
  });

  test('a direct file that finishes removes an HLS partial left behind', () async {
    alpha.status = (i) => i == 6 ? 404 : null;
    await enqueue(hls(alpha, 'Alpha'), [
      const VideoSource(
        url: 'https://fixture.test/E1.mp4',
        label: 'Direct',
        container: SourceContainer.mp4,
      ),
    ]);
    for (var i = 0; i < 250 && native.tasks.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(native.tasks, hasLength(1));
    expect(await leftovers('.ts.part'), hasLength(1));

    final task = native.tasks.single as DownloadTask;
    final media = File(await task.filePath());
    await media.parent.create(recursive: true);
    await media.writeAsBytes(List<int>.filled(600000, 1));
    native.events.add(TaskProgressUpdate(task, .99, 600000));
    native.events.add(TaskStatusUpdate(task, TaskStatus.complete));
    await waitFor((r) => r.status == DownloadStatus.done);
    expect(await leftovers('.ts.part'), isEmpty);
    expect(await leftovers('.ts.part.json'), isEmpty);
  });
}
