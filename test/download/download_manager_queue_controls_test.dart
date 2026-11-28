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
import 'package:path/path.dart' as p;
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

  /// Ids whose partial bytes the native downloader still holds.
  final resumable = <String>{};
  @override
  Future<bool> taskCanResume(Task task) async =>
      resumable.contains(task.taskId);

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

    // A re-download that failed still owns the older, complete episode; the
    // same goes for a finished file that was away or lacks its audio choice.
    test('a whole file of a failed entry goes to the Recycle Bin', () async {
      final base = await enqueue('kept');
      for (final (name, change) in <(String, Map<String, Object?>)>[
        ('superseded', {'status': 'unsupported', 'supersededPath': 'x'}),
        ('retained', {'status': 'failed', 'retainedMediaPaths': ['x']}),
        ('away', {
          'status': 'failed',
          'error': missingSavedDownloadMessage,
          'filePath': 'x',
        }),
        ('audio', {
          'status': 'failed',
          'pendingAudioFinalization': true,
          'filePath': 'x',
        }),
      ]) {
        recycled.clear();
        final media = File('${root.path}/$name.mp4');
        await media.writeAsBytes([1, 2, 3]);
        Object? own(Object? value) => value == 'x' ? media.path : value;
        await Hive.box<Map>(DownloadManager.boxName).put(base.id, {
          ...base.toMap(),
          for (final e in change.entries)
            e.key: e.value is List
                ? [for (final v in e.value! as List) own(v)]
                : own(e.value),
        });
        manager.dispose();
        manager = DownloadManager(
          _Catalogue(),
          DownloadPrefs(),
          null,
          Dio()..httpClientAdapter = _PlainHost(),
          native,
        )..setup();
        await manager.retiredCleanupCompleted;
        await manager.delete(manager.all.single);
        expect(recycled, [media.path], reason: name);
        expect(manager.all, isEmpty, reason: name);
      }
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

  group('dead downloads remove themselves at start-up', () {
    /// Restarts the manager over [records] and waits for the clean-up.
    Future<void> restart(List<DownloadRecord> records) async {
      final box = Hive.box<Map>(DownloadManager.boxName);
      await box.clear();
      for (final r in records) {
        await box.put(r.id, r.toMap());
      }
      manager.dispose();
      manager = DownloadManager(
        _Catalogue(),
        DownloadPrefs(),
        null,
        Dio()..httpClientAdapter = _PlainHost(),
        native,
      )..setup();
      await manager.retiredCleanupCompleted;
      await settle();
    }

    DownloadRecord rec(
      String id,
      DownloadStatus status, {
      String? error,
      Map<String, Object?> more = const {},
    }) => DownloadRecord.fromMap({
      'id': id,
      'sourceId': 'zm',
      'showId': 'frieren',
      'showTitle': 'Frieren',
      'showUrl': '/frieren',
      'episodeId': id,
      'episodeUrl': '/$id',
      'episodeTitle': id,
      'storageKey': 'key-$id',
      'downloadRoot': root.path,
      'category': 'dub',
      'quality': 'best',
      'status': status.name,
      'error': error,
      'createdAt': 1,
      ...more,
    });

    Set<String> ids() => manager.all.map((r) => r.id).toSet();

    test('unsupported and empty failed entries go, for good', () async {
      // A subtitle saved for the dead episode goes with it.
      final sub = File('${root.path}/dead.vtt');
      await sub.writeAsString('WEBVTT');
      await restart([
        rec('e8', DownloadStatus.unsupported,
            error: 'No downloadable stream for the selected dub audio'),
        rec('e10', DownloadStatus.failed, error: 'Resolve failed', more: {
          'subtitles': [
            {'lang': 'en', 'path': sub.path},
          ],
        }),
        rec('e9', DownloadStatus.paused),
      ]);
      expect(ids(), {'e9'});
      expect(Hive.box<Map>(DownloadManager.boxName).keys, ['e9']);
      expect(await sub.exists(), isFalse);
      expect(manager.queueItems.map((r) => r.id), ['e9']);
    });

    test('anything with a file, partial data or a future stays', () async {
      final media = File('${root.path}/media.mp4');
      await media.writeAsBytes([1, 2, 3]);
      native.resumable.add('bytes');
      await restart([
        rec('file', DownloadStatus.failed, more: {'filePath': media.path}),
        rec('older-copy', DownloadStatus.unsupported, more: {
          'retainedMediaPaths': [media.path],
        }),
        rec('replaced', DownloadStatus.failed,
            more: {'supersededPath': media.path}),
        rec('bytes', DownloadStatus.failed, more: {'progress': .4}),
        rec('audio', DownloadStatus.failed, more: {
          'pendingAudioFinalization': true,
          'filePath': '${root.path}/audio.mp4',
        }),
        rec('away', DownloadStatus.failed, error: missingSavedDownloadMessage,
            more: {'filePath': '${root.path}/away.mp4', 'progress': 1.0}),
        rec('disk', DownloadStatus.failed, more: {'recoveredFromDisk': true}),
        rec('torrent', DownloadStatus.failed,
            more: {'isTorrent': true, 'progress': .2}),
        rec('unplugged', DownloadStatus.failed, more: {
          'retainedMediaPaths': [r'Q:\no-such-drive\x.mp4'],
        }),
        rec('done', DownloadStatus.done, more: {'filePath': media.path}),
      ]);
      expect(ids(), {
        'file', 'older-copy', 'replaced', 'bytes', 'audio', 'away', 'disk',
        'torrent', 'unplugged', 'done',
      });
    });

    test('a partial file in the show folder keeps the entry', () async {
      // Let the manager name the file itself: a HLS / DASH transfer writes it
      // as the native one does, in Videos/<show>.
      await enqueue('partial');
      final path = await taskFor('partial').filePath();
      final base = byEpisode('partial');
      await File(path).parent.create(recursive: true);
      await File('$path.part').writeAsBytes([1, 2, 3]);
      final failed = base.copyWith(
        status: DownloadStatus.failed,
        error: () => 'The download engine could not finish',
      );
      await restart([failed]);
      expect(ids(), {failed.id});
      // Once the bytes are gone, only a subtitle beside it, it goes too.
      await File('$path.part').delete();
      await File(p.setExtension(path, '.vtt')).writeAsString('WEBVTT');
      await restart([failed]);
      expect(ids(), isEmpty);
    });

    test('leftover bytes keep a failed entry, not an unsupported one',
        () async {
      native.resumable.addAll(['failed', 'unsupported']);
      await restart([
        rec('failed', DownloadStatus.failed, more: {'progress': .4}),
        rec('unsupported', DownloadStatus.unsupported, more: {'progress': .4}),
      ]);
      expect(ids(), {'failed'});
    });

    test('an interrupted audio swap keeps the entry after a retry', () async {
      final show = await Directory('${root.path}/swap').create();
      final scratch = await Directory(
        '${show.path}/.zangetsu-file-audio-ab',
      ).create();
      await File('${scratch.path}/original.mp4').writeAsBytes([1, 2, 3]);
      final journal = File('${scratch.path}/publish.json');
      await journal.writeAsString('{}');
      final failed = rec('swap', DownloadStatus.failed, more: {
        'retainedMediaPaths': ['${show.path}/video.mp4'],
      });
      await restart([failed]);
      expect(ids(), {'swap'});
      // Without a journal nothing was moved away: the entry can go.
      await journal.delete();
      await restart([failed]);
      expect(ids(), isEmpty);
    });

    test('the last link from found files to their show page stays, hidden',
        () async {
      final media = File('${root.path}/found.mp4');
      await media.writeAsBytes([1, 2, 3]);
      final found = rec('found', DownloadStatus.done, more: {
        'sourceId': 'local-files',
        'showId': 'local:1',
        'showTitle': 'frieren',
        'recoveredFromDisk': true,
        'filePath': media.path,
      });
      final older = rec('e8', DownloadStatus.unsupported);
      final newer = rec('e10', DownloadStatus.failed, more: {'createdAt': 9});
      await restart([newer, older, found]);
      // One of the two is enough, and it is neither listed nor retried.
      expect(ids(), {'found', 'e10'});
      expect(manager.queueItems, isEmpty);
      expect(await manager.retryFailed(), 0);
      // Downloading that episode again lists it like any other.
      unawaited(manager.retry(byEpisode('e10')));
      await settle();
      expect(manager.queueItems.single.id, 'e10');
      // A real download of the show holds the link: both dead ones go.
      await restart([
        newer, older, found,
        rec('e1', DownloadStatus.done, more: {'filePath': media.path}),
      ]);
      expect(ids(), {'found', 'e1'});
      // Nothing found on disk: no reason to keep any.
      await restart([newer, older]);
      expect(ids(), isEmpty);
    });

    test('an unplugged drive never turns a finished download into a failure',
        () async {
      await restart([
        rec('usb', DownloadStatus.done,
            more: {'filePath': r'Q:\no-such-drive\x\y.mp4', 'progress': 1.0}),
      ]);
      await manager.pruneMissing();
      expect(byEpisode('usb').status, DownloadStatus.done);
    });

    test('the episode can be downloaded again', () async {
      await restart([rec('e8', DownloadStatus.unsupported)]);
      expect(ids(), isEmpty);
      await manager.enqueueEpisodes(
        sourceId: 'zm',
        showId: 'frieren',
        showTitle: 'Frieren',
        showUrl: '/frieren',
        category: 'dub',
        quality: 'best',
        episodes: const [
          Episode(id: 'e8', title: 'e8', url: 'https://fixture.test/e8'),
        ],
        nowMs: 5,
      );
      expect(byEpisode('e8').status, DownloadStatus.queued);
      expect(native.tasks, hasLength(1));
    });
  }, skip: !Platform.isWindows);

  test('a failed or unsupported record never blocks a new download', () async {
    final base = await enqueue('again');
    // An older copy on disk keeps the entry past the start-up clean-up.
    final kept = File('${root.path}/kept.mp4');
    await kept.writeAsBytes([1, 2, 3]);
    for (final status in [DownloadStatus.failed, DownloadStatus.unsupported]) {
      await Hive.box<Map>(DownloadManager.boxName).put(
        base.id,
        base
            .copyWith(
              status: status,
              progress: .5,
              retainedMediaPaths: [kept.path],
            )
            .toMap(),
      );
      manager.dispose();
      manager = DownloadManager(
        _Catalogue(),
        DownloadPrefs(),
        null,
        Dio()..httpClientAdapter = _PlainHost(),
        native,
      )..setup();
      await manager.retiredCleanupCompleted;
      expect(byEpisode('again').status, status);
      expect(manager.queueItems.single.status, status);
      expect(
        await manager.finishedForEpisode(
          sourceId: 'fixture',
          showId: 'show',
          episodeId: 'again',
          category: 'sub',
        ),
        isNull,
      );
      native.tasks.clear();
      await enqueue('again');
      for (var i = 0; i < 100 && native.tasks.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(native.tasks, hasLength(1));
      expect(byEpisode('again').isActive, isTrue);
    }
  }, skip: !Platform.isWindows);

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
