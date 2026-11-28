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

/// Answers a re-resolve with the same stream the job started from.
class _Catalogue implements CatalogueRepository {
  final streams = <String, List<VideoSource>>{};
  int lookups = 0;
  @override
  Future<List<VideoSource>> sources(
    String episodeUrl, {
    String? sourceId,
    bool fast = false,
  }) async {
    lookups++;
    return streams[episodeUrl] ?? const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A real HLS server on 127.0.0.1 whose segments can be cut off (no answer,
/// like the Wi-Fi extender restarting), refused, or held.
class _LoopbackHls {
  _LoopbackHls._(this._server);
  final HttpServer _server;
  static const int segments = 20;
  final requests = <int>[];
  bool Function(int i)? drop;
  int? Function(int i)? status;

  /// Called when segment `i` is asked for; the answer waits for it.
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
  // The test binding answers every real HTTP request with 400; these tests
  // talk to their own server on 127.0.0.1, so use the real client.
  HttpOverrides.global = null;
  late Directory root;
  late PathProviderPlatform originalPaths;
  late _NativeDownloads native;
  late _Catalogue catalogue;
  late _LoopbackHls host;
  late Dio dio;
  late DownloadManager manager;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('manager-network-');
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
    host = await _LoopbackHls.start();
    dio = Dio();
    manager = DownloadManager(catalogue, DownloadPrefs(), null, dio, native)
      ..hlsRetryDelays = const [Duration(milliseconds: 10)]
      ..hlsNetworkPatience = const Duration(milliseconds: 250)
      ..waitForNetwork = (() async {})
      ..networkOffline = (() => false)
      // Long, so only the reconnect hook can bring a waiting row back.
      ..networkRetryDelay = const Duration(hours: 1)
      ..setup();
  });

  tearDown(() async {
    manager.dispose();
    await native.events.close();
    dio.close(force: true);
    await host.close();
    PathProviderPlatform.instance = originalPaths;
    await Hive.close();
    hiveBoxDir = null;
    // A worker may still be closing its file for a moment after dispose.
    for (var i = 0; i < 20; i++) {
      try {
        await root.delete(recursive: true);
        break;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  VideoSource hls() => VideoSource(url: host.url, container: SourceContainer.hls);

  Future<void> enqueue(VideoSource source) {
    const episode = Episode(id: 'E1', title: 'E1', url: 'https://fixture.test/E1');
    catalogue.streams[episode.url] = [source];
    return manager.enqueueSource(
      sourceId: 'fixture',
      showId: 'show',
      showTitle: 'Fixture',
      showUrl: 'https://fixture.test/show',
      category: 'sub',
      episode: episode,
      source: source,
      qualityLabel: 'best',
      nowMs: 1,
    );
  }

  /// Waits for the single record to reach a state, never a guessed delay.
  Future<DownloadRecord> waitFor(bool Function(DownloadRecord r) test) async {
    final end = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(end)) {
      final all = manager.all;
      if (all.isNotEmpty && test(all.single)) return all.single;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    throw TimeoutException('record never reached the state: ${manager.all}');
  }

  Future<List<File>> checkpoints() async {
    final videos = Directory('${root.path}/Videos');
    if (!await videos.exists()) return const [];
    return videos
        .list(recursive: true)
        .where((e) => e is File && e.path.endsWith('.ts.part.json'))
        .cast<File>()
        .toList();
  }

  test('a network give-up waits on the same file and resumes on reconnect', () async {
    var down = true;
    host.drop = (i) => i >= 8 && down;
    await enqueue(hls());
    final started = await waitFor((r) => r.status == DownloadStatus.downloading);

    final waiting = await waitFor(
      (r) => r.status == DownloadStatus.queued && r.retryAt != null,
    );
    // No next mirror and no failure: it waits, with the same storage key.
    expect(waiting.error, 'Waiting for the network to come back');
    expect(waiting.storageKey, started.storageKey);
    expect(waiting.autoResumePending, isTrue);
    expect(waiting.retryHost, isNull);
    expect(waiting.progress, greaterThan(0));
    final saved = await checkpoints();
    expect(saved, hasLength(1));
    expect(jsonDecode(await saved.single.readAsString())['next'], 8);

    down = false;
    host.requests.clear();
    await manager.wakeNetworkWaiters();
    final done = await waitFor((r) => r.status == DownloadStatus.done);

    expect(done.storageKey, started.storageKey);
    // It carried on from segment 8; nothing before it was fetched again.
    expect(host.requests.first, 8);
    expect(host.requests.every((i) => i >= 8), isTrue);
    expect(await File(done.filePath!).readAsBytes(), _LoopbackHls.whole());
    expect(await checkpoints(), isEmpty);
  });

  test('pause keeps the partial and Resume carries on from it', () async {
    final reached = Completer<void>();
    final release = Completer<void>();
    host.hold = (i) async {
      if (i != 10) return;
      if (!reached.isCompleted) reached.complete();
      await release.future;
    };
    await enqueue(hls());
    await reached.future.timeout(const Duration(seconds: 10));
    await manager.pause(manager.all.single);
    release.complete();
    final paused = await waitFor((r) => r.status == DownloadStatus.paused);

    // Give the stopped worker its moment to save the final position.
    var next = -1;
    for (var i = 0; i < 100 && next < 0; i++) {
      final saved = await checkpoints();
      if (saved.isNotEmpty) {
        // On Windows the worker may hold the file open (or be halfway through
        // writing it) at this instant; that is not a result, so poll again.
        try {
          final data = jsonDecode(await saved.single.readAsString());
          if (data['next'] >= 10) next = data['next'] as int;
        } on FileSystemException {
          // Still locked by the writer.
        } on FormatException {
          // Read a half-written file.
        }
      }
      if (next < 0) await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(next, greaterThanOrEqualTo(10));

    host
      ..hold = null
      ..requests.clear();
    await manager.resume(paused);
    final done = await waitFor((r) => r.status == DownloadStatus.done);

    expect(done.storageKey, paused.storageKey);
    expect(host.requests.first, next);
    expect(await File(done.filePath!).readAsBytes(), _LoopbackHls.whole());
  });

  test('Retry keeps the storage key and carries on when progress is saved', () async {
    var broken = true;
    host.status = (i) => i == 5 && broken ? 404 : null;
    await enqueue(hls());
    final failed = await waitFor((r) => r.status == DownloadStatus.failed);
    expect(await checkpoints(), hasLength(1));

    broken = false;
    host.requests.clear();
    await manager.retry(failed);
    final done = await waitFor((r) => r.status == DownloadStatus.done);

    expect(done.storageKey, failed.storageKey);
    expect(host.requests.first, 5);
    expect(await File(done.filePath!).readAsBytes(), _LoopbackHls.whole());
  });

  test('Retry with nothing saved still starts over with a new key', () async {
    host.status = (i) => 404;
    await enqueue(hls());
    final failed = await waitFor((r) => r.status == DownloadStatus.failed);
    // Failed on the first segment: nothing saved, no partial left behind.
    expect(await checkpoints(), isEmpty);
    host.status = null;
    await manager.retry(failed);
    final done = await waitFor((r) => r.status == DownloadStatus.done);
    expect(done.storageKey, isNot(failed.storageKey));
  });

  test('while offline a failure waits instead of burning the mirrors', () async {
    manager.networkOffline = () => true;
    host.status = (i) => i == 3 ? 404 : null;
    await enqueue(hls());
    final waiting = await waitFor(
      (r) => r.status == DownloadStatus.queued && r.retryAt != null,
    );
    expect(waiting.error, 'Waiting for the network to come back');
    expect(manager.all.single.status, isNot(DownloadStatus.failed));
  });

  test('cancel removes a paused partial and its progress file', () async {
    final reached = Completer<void>();
    final release = Completer<void>();
    host.hold = (i) async {
      if (i != 6) return;
      if (!reached.isCompleted) reached.complete();
      await release.future;
    };
    await enqueue(hls());
    await reached.future.timeout(const Duration(seconds: 10));
    await manager.pause(manager.all.single);
    release.complete();
    final paused = await waitFor((r) => r.status == DownloadStatus.paused);
    for (var i = 0; i < 100 && (await checkpoints()).isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(await checkpoints(), hasLength(1));

    await manager.cancel(paused);
    for (var i = 0; i < 100 && (await checkpoints()).isNotEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(await checkpoints(), isEmpty);
    final leftovers = await Directory('${root.path}/Videos')
        .list(recursive: true)
        .where((e) => e is File && e.path.contains('.ts.part'))
        .toList();
    expect(leftovers, isEmpty);
  });

  test('a direct file that loses its connection waits, no fallback', () async {
    await enqueue(
      const VideoSource(
        url: 'https://fixture.test/E1.mp4',
        container: SourceContainer.mp4,
      ),
    );
    final task = native.tasks.single as DownloadTask;
    expect(task.retries, 10);
    final key = manager.all.single.storageKey;
    native.events.add(
      TaskStatusUpdate(
        task,
        TaskStatus.failed,
        TaskConnectionException('connection lost'),
      ),
    );
    final waiting = await waitFor(
      (r) => r.status == DownloadStatus.queued && r.retryAt != null,
    );
    expect(waiting.storageKey, key);
    expect(waiting.error, 'Waiting for the network to come back');
    // Neither the one-connection fallback nor another mirror was started.
    expect(native.tasks, hasLength(1));

    await manager.wakeNetworkWaiters();
    for (var i = 0; i < 100 && native.tasks.length < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(native.tasks, hasLength(2));
    expect(manager.all.single.storageKey, key);
  });
}
