// Windows download queue controls: pause on waiting items and 'Download next'
// (dl-6), Pause / Resume all and live speed (dl-5), throttled progress saves
// (dl-7), Recycle Bin deletes (dl-2) and taskbar / notification signals
// (dl-11). The manager's Windows paths need a real Windows host.
import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:watch_app/core/desktop/desktop_native.dart';
import 'package:watch_app/core/desktop/desktop_recycle_bin.dart';
import 'package:watch_app/core/download/desktop_download_signals.dart';
import 'package:watch_app/core/download/download_live_stats.dart';
import 'package:watch_app/core/download/download_manager.dart';
import 'package:watch_app/core/download/download_prefs.dart';
import 'package:watch_app/core/download/download_record.dart';
import 'package:watch_app/core/download/download_recycle.dart';
import 'package:watch_app/core/hive/safe_box.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/repository/catalogue_repository.dart';

/// Keeps application-support writes inside the disposable fixture.
class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

/// Native tasks stay pending until the test emits their platform status.
class _NativeDownloads implements FileDownloader {
  final events = StreamController<TaskUpdate>.broadcast();
  final tasks = <Task>[];
  final paused = <DownloadTask>[];
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
  Future<bool> pause(DownloadTask task) async {
    paused.add(task);
    return true;
  }

  @override
  Future<bool> resume(DownloadTask task) async => true;

  @override
  Future<bool> cancelTaskWithId(String taskId) async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #configureNotification) return this;
    if (invocation.memberName == #addTaskQueue) return null;
    return super.noSuchMethod(invocation);
  }
}

/// Resolves every episode to one direct file on the fixture host.
class _Catalogue implements CatalogueRepository {
  @override
  Future<List<VideoSource>> sources(
    String episodeUrl, {
    String? sourceId,
    bool fast = false,
  }) async => [
    VideoSource(url: '$episodeUrl.mp4', container: SourceContainer.mp4),
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Answers range probes with a plain single-connection file.
class _PlainHost implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, _, _) async =>
      ResponseBody.fromString('', 200, headers: {
        'content-length': ['1000'],
      });
  @override
  void close({bool force = false}) {}
}

/// Lets the async update / enqueue chains settle.
Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform originalPaths;
  late _NativeDownloads native;
  late DownloadManager manager;
  var now = 1000000;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('queue-controls-');
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
    now = 1000000;
    manager = DownloadManager(
      _Catalogue(),
      DownloadPrefs(),
      null,
      Dio()..httpClientAdapter = _PlainHost(),
      native,
    )
      ..progressClock = (() => now)
      ..setup();
  });

  tearDown(() async {
    manager.dispose();
    await native.events.close();
    PathProviderPlatform.instance = originalPaths;
    await Hive.close();
    hiveBoxDir = null;
    await root.delete(recursive: true);
  });

  /// Starts one episode through the public API; returns once its record
  /// exists (a waiting item's enqueue future only ends when it gets a slot).
  Future<DownloadRecord> enqueue(String id) async {
    unawaited(
      manager.enqueueSource(
        sourceId: 'fixture',
        showId: 'show',
        showTitle: 'Fixture',
        showUrl: 'https://fixture.test/show',
        category: 'sub',
        episode: Episode(id: id, title: id, url: 'https://fixture.test/$id'),
        source: VideoSource(
          url: 'https://fixture.test/$id.mp4',
          container: SourceContainer.mp4,
        ),
        qualityLabel: 'best',
        nowMs: now++,
      ),
    );
    for (var i = 0; i < 200; i++) {
      final match = manager.all.where((r) => r.episodeId == id);
      if (match.isNotEmpty) {
        await settle();
        return manager.all.singleWhere((r) => r.episodeId == id);
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    throw StateError('record $id never appeared');
  }

  DownloadRecord byEpisode(String id) =>
      manager.all.singleWhere((r) => r.episodeId == id);

  DownloadTask taskFor(String episode) => native.tasks
      .whereType<DownloadTask>()
      .lastWhere((t) => t.taskId == byEpisode(episode).id);

  test('a waiting item can be paused and resumed (dl-6)', () async {
    await enqueue('first');
    final second = await enqueue('second');
    expect(native.tasks, hasLength(1));
    expect(byEpisode('second').status, DownloadStatus.queued);

    await manager.pause(second);
    expect(byEpisode('second').status, DownloadStatus.paused);

    // Freeing the slot must not start the paused item.
    await manager.delete(byEpisode('first'));
    await settle();
    expect(native.tasks, hasLength(1));
    expect(byEpisode('second').status, DownloadStatus.paused);

    unawaited(manager.resume(byEpisode('second')));
    await settle();
    expect(native.tasks.last.taskId, second.id);
  }, skip: !Platform.isWindows);

  test("'Download next' moves an item to the front of the queue (dl-6)",
      () async {
    await enqueue('running');
    await enqueue('b');
    final c = await enqueue('c');
    expect(manager.canMoveToFront(c), isTrue);
    await manager.moveToFront(c);
    // The panel lists the promoted item before the older waiting one.
    final order = manager.queueItems.map((r) => r.episodeId).toList();
    expect(order.indexOf('c'), lessThan(order.indexOf('b')));
    expect(manager.canMoveToFront(byEpisode('c')), isFalse);

    await manager.delete(byEpisode('running'));
    await settle();
    expect(native.tasks.last.taskId, c.id);
  }, skip: !Platform.isWindows);

  test('Pause all / Resume all / Retry failed (dl-5)', () async {
    await enqueue('one');
    await enqueue('two');
    final paused = await manager.pauseAll();
    expect(paused, 2);
    // The waiting one is paused at once; the running one asked native.
    expect(byEpisode('two').status, DownloadStatus.paused);
    expect(native.paused, hasLength(1));
    native.events.add(TaskStatusUpdate(taskFor('one'), TaskStatus.paused));
    await settle();
    expect(manager.activeCount, 0);

    expect(await manager.resumeAll(), 2);
    await settle();
    expect(manager.activeCount, greaterThan(0));

    expect(await manager.retryFailed(), 0);
  }, skip: !Platform.isWindows);

  test('progress stays in memory between saves and reports speed (dl-5/7)',
      () async {
    await enqueue('tick');
    final task = taskFor('tick');
    final id = byEpisode('tick').id;
    final box = Hive.box<Map>(DownloadManager.boxName);
    var notifications = 0;
    manager.addListener(() => notifications++);

    // First tick changes the status: saved and announced at once.
    native.events.add(TaskProgressUpdate(task, .1, 1000000, 2.5,
        const Duration(seconds: 40)));
    await settle();
    expect(box.get(id)!['progress'], .1);
    expect(manager.speedOf(id), 2500000);
    expect(manager.timeLeftOf(id), const Duration(seconds: 40));
    final afterStatus = notifications;

    // A quick second tick: memory and the per-record listenable only.
    final listenable = manager.progressListenable(id);
    now += 100;
    native.events.add(TaskProgressUpdate(task, .2, 1000000, 2.5,
        const Duration(seconds: 30)));
    await settle();
    expect(byEpisode('tick').progress, .2);
    expect(listenable.value, .2);
    expect(box.get(id)!['progress'], .1);
    expect(notifications, afterStatus);

    // Past the save interval the progress reaches Hive.
    now += DownloadManager.progressSaveIntervalMs;
    native.events.add(TaskProgressUpdate(task, .3, 1000000));
    await settle();
    expect(box.get(id)!['progress'], .3);
    expect(notifications, greaterThan(afterStatus));
  }, skip: !Platform.isWindows);

  group('Recycle Bin (dl-2)', () {
    final recycled = <String>[];
    setUp(() {
      recycled.clear();
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      debugAllowRecycleInTests = true;
      // Fake shell: remember the path and remove the file like a move would.
      debugRecycleOverride = (path) async {
        recycled.add(path);
        await File(path).delete();
        return true;
      };
    });
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      debugAllowRecycleInTests = false;
      debugRecycleOverride = null;
    });

    test('a finished episode goes to the Recycle Bin', () async {
      final base = await enqueue('saved');
      final media = File('${root.path}/saved.mp4');
      await media.writeAsBytes([1, 2, 3]);
      final done = base.copyWith(
        status: DownloadStatus.done,
        progress: 1,
        filePath: () => media.path,
      );
      await Hive.box<Map>(DownloadManager.boxName).put(done.id, done.toMap());
      manager.dispose();
      manager = DownloadManager(
        _Catalogue(),
        DownloadPrefs(),
        null,
        Dio()..httpClientAdapter = _PlainHost(),
        native,
      )..setup();
      await manager.delete(manager.all.single);
      expect(recycled, [media.path]);
      expect(manager.all, isEmpty);
    }, skip: !Platform.isWindows);

    test('an unfinished download is deleted for good', () async {
      final base = await enqueue('partial');
      final media = File('${root.path}/partial.mp4');
      await media.writeAsBytes([1]);
      final failed = base.copyWith(
        status: DownloadStatus.failed,
        filePath: () => media.path,
      );
      await Hive.box<Map>(DownloadManager.boxName)
          .put(failed.id, failed.toMap());
      manager.dispose();
      manager = DownloadManager(
        _Catalogue(),
        DownloadPrefs(),
        null,
        Dio()..httpClientAdapter = _PlainHost(),
        native,
      )..setup();
      await manager.delete(manager.all.single);
      expect(recycled, isEmpty);
      expect(await media.exists(), isFalse);
    }, skip: !Platform.isWindows);
  });

  test('taskbar follows the batch and a failure notifies (dl-11)', () async {
    final signals = DesktopDownloadSignals.forTesting();
    final bar = <(DesktopTaskbarState, double)>[];
    final notes = <(String, String)>[];
    signals.setTaskbar = (state, fraction) async {
      bar.add((state, fraction));
    };
    signals.notify = (title, body) async {
      notes.add((title, body));
    };
    signals.taskbarEnabled = () => true;
    signals.notificationsEnabled = () => true;
    signals.attachVideos(manager);
    addTearDown(signals.debugReset);

    await enqueue('bar');
    final task = taskFor('bar');
    native.events.add(TaskProgressUpdate(task, .5, 1000));
    await settle();
    expect(bar.last, (DesktopTaskbarState.normal, .5));

    native.events.add(TaskStatusUpdate(task, TaskStatus.failed,
        TaskException('boom')));
    await settle();
    expect(byEpisode('bar').status, DownloadStatus.failed);
    expect(bar.last.$1, DesktopTaskbarState.error);
    expect(notes, hasLength(1));
    expect(notes.single.$1, 'Download failed');
    expect(notes.single.$2, contains('Fixture'));
  }, skip: !Platform.isWindows);

  test('batch message wording', () {
    expect(
      DesktopDownloadSignals.batchMessage(finished: ['A'], failed: []),
      ('Download finished', 'A is ready'),
    );
    expect(
      DesktopDownloadSignals.batchMessage(finished: ['A', 'B'], failed: []),
      ('Downloads finished', '2 downloads are ready'),
    );
    expect(
      DesktopDownloadSignals.batchMessage(finished: ['A'], failed: ['B', 'C']),
      ('Downloads failed', '2 downloads failed, 1 finished'),
    );
  });

  test('rate estimator turns progress samples into time left', () {
    final estimator = ProgressRateEstimator();
    expect(estimator.add(0, 0).timeLeft, isNull);
    final stats = estimator.add(.1, 1000, bytesTotal: 1000);
    // 10% per second: 9 s left, 100 bytes/s.
    expect(stats.timeLeft, const Duration(seconds: 9));
    expect(stats.bytesPerSecond, closeTo(100, .001));
    expect(formatTransferRate(2500000), '2.5 MB/s');
    expect(formatTimeLeft(const Duration(minutes: 65)), '1 h 5 min left');
  });
}
