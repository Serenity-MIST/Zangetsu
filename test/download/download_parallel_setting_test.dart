import 'dart:async';
import 'dart:io';

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

// Checks the Windows "Parallel downloads" slider end to end: the saved value
// is read when the app starts, moving it up starts waiting episodes right
// away, moving it down never stops a running one, and direct files and HLS
// share the same limit. No network: the native downloader is a fake and HLS
// requests are held in memory.

/// Keeps every app-support write inside the throwaway test folder.
class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

/// Native file tasks stay "running" until the test sends their status.
class _NativeDownloads implements FileDownloader {
  final events = StreamController<TaskUpdate>.broadcast();
  final tasks = <Task>[];
  final canceled = <String>[];
  // desktopConfig items DownloadManager.setup passed to configure().
  final configs = <Object?>[];
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
  Future<bool> cancelTaskWithId(String taskId) async {
    canceled.add(taskId);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #configureNotification) return this;
    if (invocation.memberName == #addTaskQueue) return null;
    if (invocation.memberName == #configure) {
      configs.add(invocation.namedArguments[#desktopConfig]);
      return Future.value(const <(String, String)>[]);
    }
    return super.noSuchMethod(invocation);
  }
}

/// Holds every HLS playlist request open, so an HLS episode keeps its slot.
class _HeldHls implements HttpClientAdapter {
  final started = <String>[];
  final release = Completer<void>();
  @override
  Future<ResponseBody> fetch(RequestOptions options, _, _) async {
    started.add(options.uri.path);
    await release.future;
    return ResponseBody.fromString('', 404);
  }

  @override
  void close({bool force = false}) {}
}

/// Hands each episode one direct file, like a provider would.
class _Catalogue implements CatalogueRepository {
  @override
  Future<List<VideoSource>> sources(
    String episodeUrl, {
    String? sourceId,
    bool fast = false,
  }) async => [
    VideoSource(
      url: '$episodeUrl.mp4',
      container: SourceContainer.mp4,
      quality: '1080p',
    ),
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform originalPaths;
  late _NativeDownloads native;
  late _HeldHls hls;
  late DownloadManager manager;

  Future<void> openStores() async {
    hiveBoxDir = root.path;
    Hive.init(root.path);
    await DownloadPrefs.init();
    await DownloadManager.init();
  }

  DownloadManager newManager() => DownloadManager(
    _Catalogue(),
    DownloadPrefs(),
    null,
    Dio()..httpClientAdapter = hls,
    native,
  )..setup();

  setUp(() async {
    root = await Directory.systemTemp.createTemp('parallel-setting-');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    await openStores();
    await DownloadPrefs().setLocation(root.path, root.path);
    await DownloadPrefs().setParallelDownloads(1);
    await DownloadPrefs().setConnectionsPerDownload(1);
    native = _NativeDownloads();
    hls = _HeldHls();
    manager = newManager();
  });

  tearDown(() async {
    manager.dispose();
    if (!hls.release.isCompleted) hls.release.complete();
    await native.events.close();
    PathProviderPlatform.instance = originalPaths;
    await Hive.close();
    hiveBoxDir = null;
    await root.delete(recursive: true);
  });

  /// Starts one episode the way the "pick a server" flow does. The returned
  /// future only completes once the episode got a slot, so callers do not
  /// await it while it is meant to be waiting.
  Future<void> enqueue(String id, {bool hlsSource = false}) =>
      manager.enqueueSource(
        sourceId: 'fixture',
        showId: 'show',
        showTitle: 'Fixture',
        showUrl: 'https://fixture.test/show',
        category: 'sub',
        episode: Episode(id: id, title: id, url: 'https://fixture.test/$id'),
        source: VideoSource(
          url: 'https://fixture.test/$id.${hlsSource ? 'm3u8' : 'mp4'}',
          container: hlsSource ? SourceContainer.hls : SourceContainer.mp4,
        ),
        qualityLabel: 'best',
        nowMs: 1,
      );

  /// Lets queued async work (slot hand-outs, enqueue calls) run to rest.
  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> waitFor(bool Function() ready) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!ready()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('timed out waiting for the download queue');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  String statusOf(String episodeId) =>
      manager.all.singleWhere((r) => r.episodeId == episodeId).status.name;

  test('the engine is told to run every episode and every connection at '
      'once, so split files never wait behind their own parents', () async {
    // 10 episodes x (1 parent + 8 connections): the library's own 10 would
    // let 10 split parents take every place and stall their connections.
    expect(native.configs, [
      (
        Config.holdingQueue,
        (DownloadManager.desktopEngineTaskLimit, null, null),
      ),
    ]);
    expect(
      DownloadManager.desktopEngineTaskLimit,
      DownloadPrefs.parallelMax * (DownloadPrefs.connectionsMax + 1),
    );
  }, skip: !Platform.isWindows);

  test('the saved value is read again when the app starts', () async {
    await DownloadPrefs().setParallelDownloads(2);
    manager.dispose();
    await Hive.close();
    await openStores();
    expect(DownloadPrefs().parallelDownloads, 2);

    manager = newManager();
    for (final id in ['a', 'b', 'c']) {
      unawaited(enqueue(id));
    }
    await waitFor(() => native.tasks.length == 2);
    await settle();
    expect(native.tasks, hasLength(2));
    expect(statusOf('c'), DownloadStatus.queued.name);
  }, skip: !Platform.isWindows);

  test('raising it starts the waiting direct files right away', () async {
    for (final id in ['a', 'b', 'c', 'd']) {
      unawaited(enqueue(id));
    }
    await waitFor(() => native.tasks.length == 1);
    await settle();
    expect(native.tasks, hasLength(1));

    // Nothing finishes: only the new limit lets the others in.
    manager.setParallel(3);
    await waitFor(() => native.tasks.length == 3);
    await settle();
    expect(native.tasks, hasLength(3));
    expect(statusOf('d'), DownloadStatus.queued.name);
  }, skip: !Platform.isWindows);

  test('raising it also moves a whole season batch along', () async {
    // The batch resolves one episode at a time and waits for a slot before
    // resolving the next, so the rest follow as soon as the limit rises.
    unawaited(
      manager.enqueueEpisodes(
        sourceId: 'fixture',
        showId: 'show',
        showTitle: 'Fixture',
        showUrl: 'https://fixture.test/show',
        category: 'sub',
        quality: 'best',
        episodes: [
          for (var i = 1; i <= 5; i++)
            Episode(
              id: 'e$i',
              title: 'Episode $i',
              url: 'https://fixture.test/e$i',
              number: i.toDouble(),
            ),
        ],
        nowMs: 1,
      ),
    );
    await waitFor(() => native.tasks.length == 1);
    await settle();
    expect(native.tasks, hasLength(1));

    manager.setParallel(4);
    await waitFor(() => native.tasks.length == 4);
    await settle();
    expect(native.tasks, hasLength(4));
    expect(statusOf('e5'), isNot(DownloadStatus.downloading.name));
  }, skip: !Platform.isWindows);

  test('lowering it never stops running ones and holds new starts', () async {
    manager.setParallel(3);
    for (final id in ['a', 'b', 'c', 'd']) {
      unawaited(enqueue(id));
    }
    await waitFor(() => native.tasks.length == 3);

    manager.setParallel(1);
    await settle();
    expect(native.canceled, isEmpty, reason: 'running files keep going');
    expect(native.tasks, hasLength(3));

    // Two of three running files stop: still at or above the new limit of 1.
    for (final task in native.tasks.take(2).toList()) {
      native.events.add(TaskStatusUpdate(task, TaskStatus.paused));
    }
    await settle();
    expect(native.tasks, hasLength(3), reason: '1 still running = limit 1');

    // The last one stops: now there is room for exactly one.
    native.events.add(TaskStatusUpdate(native.tasks[2], TaskStatus.paused));
    await waitFor(() => native.tasks.length == 4);
    expect(native.tasks.last.taskId, contains('d'));
  }, skip: !Platform.isWindows);

  test('HLS and direct files share the same limit', () async {
    manager.setParallel(2);
    unawaited(enqueue('stream', hlsSource: true));
    unawaited(enqueue('file1'));
    unawaited(enqueue('file2'));
    await waitFor(() => hls.started.isNotEmpty && native.tasks.isNotEmpty);
    await settle();
    // One HLS episode is running (it may ask for its playlist more than once).
    expect(hls.started.toSet(), {'/stream.m3u8'});
    expect(native.tasks, hasLength(1), reason: 'HLS holds the second slot');

    manager.setParallel(3);
    await waitFor(() => native.tasks.length == 2);
  }, skip: !Platform.isWindows);

  test('out-of-range values are kept inside 1 to 10', () async {
    await DownloadPrefs().setParallelDownloads(0);
    expect(DownloadPrefs().parallelDownloads, DownloadPrefs.parallelMin);
    await DownloadPrefs().setParallelDownloads(99);
    expect(DownloadPrefs().parallelDownloads, DownloadPrefs.parallelMax);

    manager.setParallel(0); // treated as 1
    unawaited(enqueue('a'));
    unawaited(enqueue('b'));
    await waitFor(() => native.tasks.length == 1);
    await settle();
    expect(native.tasks, hasLength(1));
  }, skip: !Platform.isWindows);
}
