import 'package:flutter/services.dart';
import 'package:watch_app/core/download/desktop_download_retry.dart';
import 'package:watch_app/core/download/desktop_download_recovery.dart';
import 'package:watch_app/core/desktop/desktop_storage.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:watch_app/core/download/download_manager.dart';
import 'package:watch_app/core/download/desktop_file_audio.dart';
import 'package:watch_app/core/download/download_prefs.dart';
import 'package:watch_app/core/download/download_record.dart';
import 'package:watch_app/core/download/download_server_preference.dart';
import 'package:watch_app/core/hive/safe_box.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/repository/catalogue_repository.dart';
import 'package:watch_app/core/zmode/metadata_repository.dart';

/// Keeps every application-support write inside the disposable fixture.
class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

/// Native tasks remain pending until the test emits their platform status.
class _NativeDownloads implements FileDownloader {
  final events = StreamController<TaskUpdate>.broadcast();
  final tasks = <Task>[];
  final resumed = <DownloadTask>[];
  List<Task> restored = const [];
  bool accepts = true;
  void Function(Task)? onEnqueue;
  Future<bool> Function(String)? onCancel;
  @override
  Future<List<Task>> allTasks({
    String group = 'default',
    bool includeTasksWaitingToRetry = true,
    bool allGroups = false,
  }) async => restored;
  @override
  Stream<TaskUpdate> get updates => events.stream;
  @override
  Future<bool> enqueue(Task task) async {
    tasks.add(task);
    onEnqueue?.call(task);
    return accepts;
  }

  @override
  Future<bool> resume(DownloadTask task) async {
    resumed.add(task);
    return true;
  }

  @override
  Future<bool> cancelTaskWithId(String taskId) async =>
      await onCancel?.call(taskId) ?? true;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #configureNotification) return this;
    if (invocation.memberName == #addTaskQueue) return null;
    return super.noSuchMethod(invocation);
  }
}

/// Holds file finalization to verify the queue lease spans media processing.
class _FileAudio extends DesktopFileAudio {
  final started = Completer<String?>();
  final finish = Completer<String?>();
  bool Function()? isCanceled;
  @override
  Future<String?> finalize(
    String path,
    String? language,
    bool Function() canceled,
  ) async {
    isCanceled = canceled;
    started.complete(language);
    return finish.future;
  }
}

/// Gives a rapid resume its own worker invocation after first-pass cleanup.
class _TwoPassAudio extends _FileAudio {
  final secondStarted = Completer<void>();
  final secondFinish = Completer<String?>();
  @override
  Future<String?> finalize(
    String path,
    String? language,
    bool Function() canceled,
  ) {
    if (!started.isCompleted) return super.finalize(path, language, canceled);
    secondStarted.complete();
    return secondFinish.future;
  }
}

/// A cleanup fault must not escape the asynchronous native status callback.
class _ThrowAudio extends _FileAudio {
  @override
  Future<String?> finalize(
    String path,
    String? language,
    bool Function() canceled,
  ) async {
    started.complete(language);
    throw StateError('private https://fixture.test/video?token=SECRET');
  }
}

/// Holds the HLS playlist request so no network or media fixture is needed.
class _HeldPlaylist implements HttpClientAdapter {
  final started = Completer<void>();
  final finish = Completer<void>();
  String? response;
  @override
  Future<ResponseBody> fetch(RequestOptions options, _, _) async {
    if (!started.isCompleted) started.complete();
    await finish.future;
    return ResponseBody.fromString(
      response != null && options.uri.path.endsWith('/video.m3u8')
          ? '#EXTM3U\n#EXTINF:1,\nvideo.ts\n#EXT-X-ENDLIST\n'
          : response ?? '',
      response == null ? 404 : 200,
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Delays the chosen subtitle response to a precise completion-commit boundary.
class _SubtitleHost implements HttpClientAdapter {
  final started = Completer<void>();
  final release = Completer<void>();
  final requested = <String>[];
  @override
  Future<ResponseBody> fetch(RequestOptions options, _, _) async {
    requested.add(options.uri.path);
    if (!started.isCompleted) started.complete();
    await release.future;
    return ResponseBody.fromString(
      'WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nEnglish\n',
      200,
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Minimal TS transport fixtures verify destination isolation, not playback.
class _NamedHls extends _SubtitleHost {
  @override
  Future<ResponseBody> fetch(RequestOptions options, _, _) async {
    if (options.uri.path.endsWith('.m3u8')) {
      final name = options.uri.path.endsWith('one.m3u8') ? 'one' : 'two';
      return ResponseBody.fromString(
        '#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\n$name.ts\n#EXT-X-ENDLIST\n',
        200,
      );
    }
    return ResponseBody.fromBytes(
      List<int>.filled(options.uri.path.endsWith('one.ts') ? 188 : 376, 0x47),
      200,
    );
  }
}

/// Old and new subtitle generations finish in deliberately reversed order.
class _GenerationSubtitleHost implements HttpClientAdapter {
  final oldStarted = Completer<void>();
  final releaseOld = Completer<void>();
  @override
  Future<ResponseBody> fetch(RequestOptions options, _, _) async {
    final old = options.uri.path.endsWith('/old.vtt');
    if (old) {
      oldStarted.complete();
      await releaseOld.future;
    }
    return ResponseBody.fromString(
      'WEBVTT\n\n00:00:00.000 --> 00:00:01.000\n${old ? 'Old' : 'New'} English\n',
      200,
    );
  }

  @override
  void close({bool force = false}) {}
}

/// A test delivers deadlines explicitly, including a canceled late callback.
class _RetryTimer implements Timer {
  _RetryTimer(this.action);
  final void Function() action;
  bool active = true;
  @override bool get isActive => active;
  @override int get tick => 0;
  @override void cancel() { active = false; }
  void fire({bool force = false}) {
    if (!active && !force) return;
    active = false;
    action();
  }
}

/// Supplies independently resolved episode streams for batch integration checks.
class _Catalogue implements CatalogueRepository {
  final streams = <String, List<VideoSource>>{};
  final requested = <String>[];
  void Function(String)? onSources;
  @override
  Future<List<VideoSource>> sources(
    String episodeUrl, {
    String? sourceId,
    bool fast = false,
  }) async {
    onSources?.call(episodeUrl);
    requested.add(episodeUrl);
    return streams[episodeUrl] ?? const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Optional subtitle failures must not poison an unrelated video host.
class _LimitedSubtitleHost implements HttpClientAdapter {
  final requested = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(RequestOptions options, _, _) async {
    requested.add(options);
    return ResponseBody.fromString('<html>private subtitle error</html>', 429,
        headers: {'retry-after': ['120']});
  }
  @override
  void close({bool force = false}) {}
}

/// A held playlist response exposes the FIFO ordering around a server cooldown.
class _RateLimitedPlaylist implements HttpClientAdapter {
  final started = Completer<void>();
  final release = Completer<void>();
  final requested = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(RequestOptions options, _, _) async {
    requested.add(options);
    if (!started.isCompleted) started.complete();
    await release.future;
    return ResponseBody.fromString('<html>429 Too Many Requests</html>', 429,
        headers: {'retry-after': ['120']});
  }
  @override
  void close({bool force = false}) {}
}

/// Advertises and honors one-byte ranges for native task selection checks.
class _RangeHost implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, _, _) async =>
      options.method == 'HEAD'
      ? ResponseBody.fromString(
          '',
          200,
          headers: {
            'content-length': ['8000'],
            'accept-ranges': ['bytes'],
          },
        )
      : ResponseBody.fromBytes(
          [1],
          206,
          headers: {
            'content-length': ['1'],
            'content-range': ['bytes 0-0/8000'],
          },
        );
  @override
  void close({bool force = false}) {}
}

/// Limits one capability probe while leaving ordinary range behavior available.
class _LimitedRangeHost extends _RangeHost {
  _LimitedRangeHost(this.method);
  final String method;
  final requested = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(RequestOptions options, stream, cancel) async {
    requested.add(options);
    if (options.method == method) {
      return ResponseBody.fromString('<html>private429</html>', 429,
          headers: {'retry-after': ['120']});
    }
    return super.fetch(options, stream, cancel);
  }
}

/// Records the explicit saved cut supplied by the manager, without browsing state.
class _MetadataCatalogue implements MetadataRepository {
  String? requestedCut;
  @override
  Future<List<VideoSource>> sources(
    String url, {
    String? sourceId,
    bool fast = false,
    String? category,
  }) async {
    requestedCut = category;
    return const [
      VideoSource(url: 'https://fixture.test/sub.mp4', kind: AudioKind.sub),
      VideoSource(url: 'https://fixture.test/dub.mp4', kind: AudioKind.dub),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform originalPaths;
  late _NativeDownloads native;
  late _HeldPlaylist playlist;
  late DownloadManager manager;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('manager-slots-');
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
    playlist = _HeldPlaylist();
    final dio = Dio()..httpClientAdapter = playlist;
    manager = DownloadManager(_Catalogue(), DownloadPrefs(), null, dio, native)
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

  /// Enqueues a distinct episode through the same public API used by the UI.
  Future<void> enqueue(
    String id,
    SourceContainer container, {
    String host = 'fixture.test',
  }) => manager.enqueueSource(
    sourceId: 'fixture',
    showId: 'show',
    showTitle: 'Fixture',
    showUrl: 'https://fixture.test/show',
    category: 'sub',
    episode: Episode(id: id, title: id, url: 'https://fixture.test/$id'),
    source: VideoSource(
      url:
          'https://$host/$id.${container == SourceContainer.hls ? 'm3u8' : 'mp4'}',
      container: container,
    ),
    qualityLabel: 'best',
    nowMs: 1,
  );

  /// Wait for permission/path checks and record creation, not a guessed delay.
  Future<void> waitForRecord(String id) async {
    if (manager.all.any((r) => r.episodeId == id)) return;
    final ready = Completer<void>();
    void check() {
      if (manager.all.any((r) => r.episodeId == id) && !ready.isCompleted) {
        ready.complete();
      }
    }

    manager.addListener(check);
    try {
      check();
      await ready.future.timeout(const Duration(seconds: 5));
    } finally {
      manager.removeListener(check);
    }
  }

  test(
    'missing HLS audio engine reports reason and frees next transfer',
    () async {
      playlist.response =
          '#EXTM3U\n'
          '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="English",LANGUAGE="en",URI="en.m3u8"\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO="audio"\nvideo.m3u8\n';
      await enqueue('audio-engine', SourceContainer.hls);
      await playlist.started.future.timeout(const Duration(seconds: 5));
      final queued = enqueue('after-audio', SourceContainer.mp4);
      await waitForRecord('after-audio');
      expect(native.tasks, isEmpty);
      playlist.finish.complete();
      await queued.timeout(const Duration(seconds: 5));
      final record = manager.all.singleWhere(
        (r) => r.episodeId == 'audio-engine',
      );
      expect(record.status, DownloadStatus.failed);
      expect(
        record.error,
        'This stream requires the bundled audio merge engine',
      );
      expect(
        Hive.box<Map>(DownloadManager.boxName).get(record.id)!['error'],
        record.error,
      );
      expect(native.tasks, hasLength(1));
    },
    skip: !Platform.isWindows,
  );

  for (final failure in <String?>[
    null,
    'The selected audio language (en) is unavailable in this file',
  ]) {
    test(
      'direct audio finalization holds capacity; failure=$failure',
      () async {
        manager.dispose();
        final fileAudio = _FileAudio();
        manager = DownloadManager(
          _Catalogue(),
          DownloadPrefs(),
          null,
          Dio()..httpClientAdapter = playlist,
          native,
          fileAudio,
        )..setup();
        await manager.enqueueSource(
          sourceId: 'fixture',
          showId: 'show',
          showTitle: 'Fixture',
          showUrl: 'https://fixture.test/show',
          category: 'dub',
          episode: const Episode(
            id: 'english',
            title: 'English',
            url: 'https://fixture.test/english',
          ),
          source: const VideoSource(
            url: 'https://fixture.test/en.mp4',
            container: SourceContainer.mp4,
            kind: AudioKind.dub,
            audioLang: 'en',
          ),
          qualityLabel: 'best',
          nowMs: 1,
        );
        final task = native.tasks.single as DownloadTask;
        final media = File(await task.filePath());
        await media.parent.create(recursive: true);
        await media.writeAsBytes(List<int>.filled(600000, 1));
        native.events.add(TaskProgressUpdate(task, .99, 600000));
        native.events.add(TaskStatusUpdate(task, TaskStatus.complete));
        expect(
          await fileAudio.started.future.timeout(const Duration(seconds: 5)),
          'en',
        );
        expect(manager.all.single.status, DownloadStatus.finalizing);
        final queued = enqueue('after-finalize', SourceContainer.mp4);
        await waitForRecord('after-finalize');
        expect(native.tasks, hasLength(1));
        native.events.add(TaskStatusUpdate(task, TaskStatus.paused));
        native.events.add(TaskProgressUpdate(task, .5, 999));
        await Future<void>.delayed(Duration.zero);
        expect(native.tasks, hasLength(1));
        expect(
          manager.all.singleWhere((r) => r.episodeId == 'english').status,
          DownloadStatus.finalizing,
        );
        if (failure == null) {
          await media.writeAsBytes(List<int>.filled(300000, 1));
        }
        fileAudio.finish.complete(failure);
        await queued.timeout(const Duration(seconds: 5));
        expect(native.tasks, hasLength(2));
        final done = manager.all.singleWhere((r) => r.episodeId == 'english');
        expect(
          done.status,
          failure == null ? DownloadStatus.done : DownloadStatus.failed,
        );
        expect(done.filePath, media.path);
        expect(done.error, failure);
        if (failure == null) expect(done.bytesTotal, 300000);
        expect(await media.exists(), isTrue);
      },
      skip: !Platform.isWindows,
    );
  }

  // Exercises the same public enqueue/status route as native completion while
  // holding the media worker, so lifecycle transitions are deterministic.
  Future<DownloadTask> beginFinalization(
    _FileAudio audio, {
    Future<void> Function(DownloadRecord)? writeCheckpoint,
    bool waitForWorker = true,
  }) async {
    manager.dispose();
    manager = DownloadManager(
      _Catalogue(),
      DownloadPrefs(),
      null,
      Dio()..httpClientAdapter = playlist,
      native,
      audio,
      writeCheckpoint,
    )..setup();
    await manager.enqueueSource(
      sourceId: 'fixture',
      showId: 'show',
      showTitle: 'Fixture',
      showUrl: 'https://fixture.test/show',
      category: 'dub',
      episode: const Episode(
        id: 'lifecycle',
        title: 'English',
        url: 'https://fixture.test/lifecycle',
      ),
      source: const VideoSource(
        url: 'https://fixture.test/en.mp4',
        container: SourceContainer.mp4,
        kind: AudioKind.dub,
        audioLang: 'en',
      ),
      qualityLabel: 'best',
      nowMs: 1,
    );
    final task = native.tasks.single as DownloadTask;
    final file = File(await task.filePath());
    await file.parent.create(recursive: true);
    await file.writeAsBytes(List<int>.filled(600000, 1));
    native.events.add(TaskStatusUpdate(task, TaskStatus.complete));
    if (waitForWorker) {
      await audio.started.future.timeout(const Duration(seconds: 5));
    }
    return task;
  }

  test(
    'pause during audio processing preserves media and releases after cleanup',
    () async {
      final audio = _FileAudio();
      final task = await beginFinalization(audio);
      final queued = enqueue('after-audio-pause', SourceContainer.mp4);
      await waitForRecord('after-audio-pause');
      await manager.pause(
        manager.all.singleWhere((r) => r.episodeId == 'lifecycle'),
      );
      expect(audio.isCanceled!(), isTrue);
      expect(native.tasks, hasLength(1));
      audio.finish.complete('canceled');
      await queued.timeout(const Duration(seconds: 5));
      final paused = manager.all.singleWhere((r) => r.episodeId == 'lifecycle');
      expect(paused.status, DownloadStatus.paused);
      expect(paused.pendingAudioFinalization, isTrue);
      expect(paused.error, isNull);
      expect(await File(await task.filePath()).exists(), isTrue);
      expect(native.tasks, hasLength(2));
    },
    skip: !Platform.isWindows,
  );

  test(
    'rapid pause then resume waits for old worker and needs no second click',
    () async {
      final audio = _TwoPassAudio();
      final task = await beginFinalization(audio);
      await manager.pause(
        manager.all.singleWhere((r) => r.episodeId == 'lifecycle'),
      );
      await manager.resume(
        manager.all.singleWhere((r) => r.episodeId == 'lifecycle'),
      );
      expect(audio.secondStarted.isCompleted, isFalse);
      final completed = Completer<void>();
      manager.addListener(() {
        if (manager.all.any(
              (r) =>
                  r.episodeId == 'lifecycle' && r.status == DownloadStatus.done,
            ) &&
            !completed.isCompleted) {
          completed.complete();
        }
      });
      audio.finish.complete('canceled');
      await audio.secondStarted.future.timeout(const Duration(seconds: 5));
      expect(native.tasks, hasLength(1));
      audio.secondFinish.complete(null);
      await completed.future.timeout(const Duration(seconds: 5));
      expect(await File(await task.filePath()).exists(), isTrue);
      expect(manager.all.single.pendingAudioFinalization, isFalse);
    },
    skip: !Platform.isWindows,
  );

  test(
    'audio worker exception is safe, recoverable and releases queue',
    () async {
      final task = await beginFinalization(_ThrowAudio());
      await enqueue('after-worker-error', SourceContainer.mp4);
      final failed = manager.all.singleWhere((r) => r.episodeId == 'lifecycle');
      expect(failed.status, DownloadStatus.failed);
      expect(
        failed.error,
        'Audio processing could not finish. Resume or retry this download.',
      );
      expect(failed.error, isNot(contains('SECRET')));
      expect(failed.pendingAudioFinalization, isTrue);
      expect(await File(await task.filePath()).exists(), isTrue);
      expect(native.tasks, hasLength(2));
    },
    skip: !Platform.isWindows,
  );

  test('cancel then immediate retry waits for former audio cleanup', () async {
    final audio = _FileAudio();
    await beginFinalization(audio);
    await manager.cancel(manager.all.single);
    final retried = manager.retry(manager.all.single);
    await Future<void>.delayed(Duration.zero);
    expect(manager.all.single.status, DownloadStatus.canceled);
    expect(audio.isCanceled!(), isTrue);
    audio.finish.complete('canceled');
    await retried.timeout(const Duration(seconds: 5));
    expect(manager.all.single.status, DownloadStatus.unsupported);
    expect(manager.all.single.pendingAudioFinalization, isFalse);
    expect(manager.all.single.filePath, isNull);
  }, skip: !Platform.isWindows);

  test('delete then same-ID enqueue waits for former audio cleanup', () async {
    final audio = _FileAudio();
    await beginFinalization(audio);
    await manager.delete(manager.all.single);
    final recreated = enqueue('lifecycle', SourceContainer.mp4);
    await Future<void>.delayed(Duration.zero);
    expect(manager.all, isEmpty);
    audio.finish.complete('canceled');
    await recreated.timeout(const Duration(seconds: 5));
    expect(native.tasks, hasLength(2));
    expect(manager.all.single.status, DownloadStatus.queued);
    expect(manager.all.single.pendingAudioFinalization, isFalse);
    expect(manager.all.single.filePath, isNull);
  }, skip: !Platform.isWindows);

  test('delete then bulk recreation waits for former audio cleanup', () async {
    final audio = _FileAudio();
    await beginFinalization(audio);
    await manager.delete(manager.all.single);
    final recreated = manager.enqueueEpisodes(
      sourceId: 'fixture',
      showId: 'show',
      showTitle: 'Fixture',
      showUrl: '/show',
      category: 'sub',
      quality: 'best',
      nowMs: 2,
      episodes: const [
        Episode(id: 'lifecycle', title: 'Episode', url: '/episode'),
      ],
    );
    await Future<void>.delayed(Duration.zero);
    expect(manager.all, isEmpty);
    expect(audio.isCanceled!(), isTrue);
    audio.finish.complete('canceled');
    await recreated.timeout(const Duration(seconds: 5));
    expect(manager.all.single.status, DownloadStatus.unsupported);
    expect(manager.all.single.pendingAudioFinalization, isFalse);
    expect(manager.all.single.filePath, isNull);
  }, skip: !Platform.isWindows);

  test(
    'failed checkpoint write never mutates media or strands queue',
    () async {
      final audio = _FileAudio();
      var writes = 0;
      final task = await beginFinalization(
        audio,
        waitForWorker: false,
        writeCheckpoint: (record) async {
          writes++;
          expect(record.pendingAudioFinalization, isTrue);
          expect(record.filePath, isNotNull);
          throw const FileSystemException('private disk failure');
        },
      );
      await enqueue('after-storage-error', SourceContainer.mp4);
      final failed = manager.all.singleWhere((r) => r.episodeId == 'lifecycle');
      expect(writes, 1);
      expect(audio.started.isCompleted, isFalse);
      expect(failed.status, DownloadStatus.failed);
      expect(
        failed.error,
        'Could not save download recovery data. Check storage and resume.',
      );
      expect(failed.pendingAudioFinalization, isTrue);
      expect(await File(await task.filePath()).length(), 600000);
      expect(native.tasks, hasLength(2));
      expect(
        Hive.box<Map>(DownloadManager.boxName).get(failed.id)!['status'],
        isNot('finalizing'),
      );
    },
    skip: !Platform.isWindows,
  );

  test('cancel during audio finalization never publishes done', () async {
    final audio = _FileAudio();
    final task = await beginFinalization(audio);
    final queued = enqueue('after-cancel', SourceContainer.mp4);
    await waitForRecord('after-cancel');
    await manager.cancel(
      manager.all.singleWhere((r) => r.episodeId == 'lifecycle'),
    );
    expect(audio.isCanceled!(), isTrue);
    audio.finish.complete('canceled');
    await queued.timeout(const Duration(seconds: 5));
    final record = manager.all.singleWhere((r) => r.episodeId == 'lifecycle');
    expect(record.status, DownloadStatus.canceled);
    expect(record.filePath, isNull);
    expect(await File(await task.filePath()).exists(), isFalse);
    expect(native.tasks, hasLength(2));
  }, skip: !Platform.isWindows);

  test(
    'disposed finalizer restores rename gap and preserves recovered state',
    () async {
      final audio = _FileAudio();
      final task = await beginFinalization(audio);
      manager.dispose();
      expect(audio.isCanceled!(), isTrue);
      // Durable state left by interruption after the original rename.
      final media = File(await task.filePath());
      final scratch = await media.parent.createTemp('.zangetsu-file-audio-');
      await File('${scratch.path}/selected.mp4').writeAsBytes([42]);
      await File('${scratch.path}/publish.json').writeAsString(
        jsonEncode({
          'version': 1,
          'target': media.uri.pathSegments.last,
          'backup': 'original.mp4',
          'sha256': sha256.convert([42]).toString(),
        }),
        flush: true,
      );
      await media.rename('${scratch.path}/original.mp4');
      expect(await media.exists(), isFalse);

      final resumedAudio = _FileAudio();
      manager = DownloadManager(
        _Catalogue(),
        DownloadPrefs(),
        null,
        Dio()..httpClientAdapter = playlist,
        native,
        resumedAudio,
      )..setup();
      await enqueue('after-restart', SourceContainer.mp4);
      final recovered = manager.all.singleWhere(
        (r) => r.episodeId == 'lifecycle',
      );
      expect(recovered.status, DownloadStatus.paused);
      expect(recovered.pendingAudioFinalization, isTrue);
      expect(await scratch.exists(), isFalse);
      expect(await media.length(), 600000);
      audio.finish.complete('canceled');
      await Future<void>.delayed(Duration.zero);
      expect(await File(await task.filePath()).exists(), isTrue);
      expect(
        Hive.box<Map>(DownloadManager.boxName).get(recovered.id)!['status'],
        'paused',
      );
      expect(
        manager.all.singleWhere((r) => r.episodeId == 'lifecycle').status,
        DownloadStatus.paused,
      );
      final waiting = manager.resume(recovered);
      await Future<void>.delayed(Duration.zero);
      await manager.pause(
        manager.all.singleWhere((r) => r.episodeId == 'lifecycle'),
      );
      await waiting.timeout(const Duration(seconds: 5));
      expect(resumedAudio.started.isCompleted, isFalse);
      expect(native.tasks, hasLength(2));
      expect(
        manager.all.singleWhere((r) => r.episodeId == 'lifecycle').status,
        DownloadStatus.paused,
      );
      final resumed = manager.resume(recovered);
      expect(native.tasks, hasLength(2));
      // A different active transfer owns the single slot until paused.
      expect(resumedAudio.started.isCompleted, isFalse);
      native.events.add(TaskStatusUpdate(native.tasks.last, TaskStatus.paused));
      expect(
        await resumedAudio.started.future.timeout(const Duration(seconds: 5)),
        'en',
      );
      expect(native.tasks, hasLength(2));
      resumedAudio.finish.complete(null);
      await resumed.timeout(const Duration(seconds: 5));
      final done = manager.all.singleWhere((r) => r.episodeId == 'lifecycle');
      expect(done.status, DownloadStatus.done);
      expect(done.pendingAudioFinalization, isFalse);
      expect(
        DownloadRecord.fromMap(
          Hive.box<Map>(DownloadManager.boxName).get(done.id)!,
        ).pendingAudioFinalization,
        isFalse,
      );
    },
    skip: !Platform.isWindows,
  );

  test('old records do not infer local finalization from a file path', () {
    final legacy = DownloadRecord.fromMap({'id': 'old', 'filePath': 'old.mp4'});
    expect(legacy.pendingAudioFinalization, isFalse);
    expect(legacy.retainedMediaPaths, isEmpty);
    final pending = legacy.copyWith(pendingAudioFinalization: true);
    expect(
      DownloadRecord.fromMap(pending.toMap()).pendingAudioFinalization,
      isTrue,
    );
    expect(
      pending.copyWith(status: DownloadStatus.finalizing).isActive,
      isTrue,
    );
  });

  test('missing checkpointed media fails without a new transfer', () async {
    await enqueue('missing-local', SourceContainer.mp4);
    final initial = manager.all.single;
    final missing = initial.copyWith(
      status: DownloadStatus.paused,
      pendingAudioFinalization: true,
      filePath: () => '${root.path}/missing.mp4',
    );
    await Hive.box<Map>(
      DownloadManager.boxName,
    ).put(missing.id, missing.toMap());
    manager.dispose();
    manager = DownloadManager(
      _Catalogue(),
      DownloadPrefs(),
      null,
      Dio()..httpClientAdapter = playlist,
      native,
    )..setup();
    await manager.resume(missing);
    final failed = manager.all.single;
    expect(failed.status, DownloadStatus.failed);
    expect(failed.error, contains('file is missing'));
    expect(native.tasks, hasLength(1));
  }, skip: !Platform.isWindows);

  for (final shared in [false, true]) {
    test('retry retains media until success, shared=$shared', () async {
      await enqueue('retained', SourceContainer.mp4);
      final base = manager.all.single;
      final good = File('${root.path}/previous-good.mp4');
      final raw = File('${root.path}/failed-audio.mp4');
      final older = File('${root.path}/earlier-retry.mp4');
      for (final file in [good, raw, older]) {
        await file.writeAsBytes([1, 2, 3]);
      }
      final failed = base.copyWith(
        status: DownloadStatus.failed,
        pendingAudioFinalization: true,
        filePath: () => raw.path,
        supersededPath: () => good.path,
        retainedMediaPaths: [older.path],
      );
      await Hive.box<Map>(
        DownloadManager.boxName,
      ).put(failed.id, failed.toMap());
      if (shared) {
        final map = {
          ...base.toMap(),
          'id': 'other-owner',
          'status': 'done',
          'filePath': older.path,
        };
        await Hive.box<Map>(DownloadManager.boxName).put('other-owner', map);
      }
      manager.dispose();
      final catalogue = _Catalogue();
      manager = DownloadManager(
        catalogue,
        DownloadPrefs(),
        null,
        Dio()..httpClientAdapter = playlist,
        native,
      )..setup();
      await manager.retry(failed);
      final unavailable = manager.all.singleWhere((r) => r.id == failed.id);
      expect(unavailable.status, DownloadStatus.unsupported);
      expect(
        unavailable.retainedMediaPaths,
        containsAll([older.path, raw.path]),
      );
      for (final file in [good, raw, older]) {
        expect(await file.exists(), isTrue);
      }
      expect(
        DownloadRecord.fromMap(unavailable.toMap()).retainedMediaPaths,
        containsAll([older.path, raw.path]),
      );
      catalogue.streams[base.episodeUrl] = const [
        VideoSource(
          url: 'https://fixture.test/replacement.mkv',
          container: SourceContainer.mp4,
        ),
      ];
      await manager.retry(unavailable);
      final task = native.tasks.last as DownloadTask;
      final replacement = File(await task.filePath());
      await replacement.parent.create(recursive: true);
      await replacement.writeAsBytes(List<int>.filled(600000, 1));
      final done = Completer<void>();
      manager.addListener(() {
        if (manager.all.any(
              (r) => r.id == failed.id && r.status == DownloadStatus.done,
            ) &&
            !done.isCompleted) {
          done.complete();
        }
      });
      native.events.add(TaskStatusUpdate(task, TaskStatus.complete));
      await done.future.timeout(const Duration(seconds: 5));
      expect(await replacement.exists(), isTrue);
      expect(await good.exists(), isFalse);
      expect(await raw.exists(), isFalse);
      expect(await older.exists(), shared);
      final completed = manager.all.singleWhere((r) => r.id == failed.id);
      expect(completed.retainedMediaPaths, shared ? [older.path] : isEmpty);
      expect(completed.supersededPath, isNull);
      native.events.add(TaskProgressUpdate(task, .25, 42));
      native.events.add(TaskStatusUpdate(task, TaskStatus.paused));
      await Future<void>.delayed(Duration.zero);
      expect(
        manager.all.singleWhere((r) => r.id == failed.id).status,
        DownloadStatus.done,
      );
    }, skip: !Platform.isWindows);
  }

  test(
    'delete removes retained failed media using current saved ownership',
    () async {
      await enqueue('delete-retained', SourceContainer.mp4);
      final base = manager.all.single;
      final old = File('${root.path}/delete-old.mp4');
      final raw = File('${root.path}/delete-raw.mp4');
      await old.writeAsBytes([1]);
      await raw.writeAsBytes([2]);
      final saved = base.copyWith(
        status: DownloadStatus.failed,
        filePath: () => raw.path,
        retainedMediaPaths: [old.path],
      );
      await Hive.box<Map>(DownloadManager.boxName).put(saved.id, saved.toMap());
      manager.dispose();
      manager = DownloadManager(
        _Catalogue(),
        DownloadPrefs(),
        null,
        Dio()..httpClientAdapter = playlist,
        native,
      )..setup();
      // Simulates a menu snapshot that predates the latest finalized-file path.
      await manager.delete(base);
      expect(await raw.exists(), isFalse);
      expect(await old.exists(), isFalse);
      expect(manager.all, isEmpty);
    },
    skip: !Platform.isWindows,
  );

  test(
    'late callbacks from old native mirror do not release new attempt',
    () async {
      await manager.enqueueSource(
        sourceId: 'fixture',
        showId: 'show',
        showTitle: 'Fixture',
        showUrl: '/show',
        category: 'sub',
        episode: const Episode(id: 'mirror', title: 'Mirror', url: '/mirror'),
        source: const VideoSource(
          url: 'https://fixture.test/first.mp4',
          container: SourceContainer.mp4,
        ),
        fallbacks: const [
          VideoSource(
            url: 'https://fixture.test/second.mp4',
            container: SourceContainer.mp4,
          ),
        ],
        qualityLabel: 'best',
        nowMs: 1,
      );
      final old = native.tasks.single;
      final replacementReady = Completer<void>();
      native.onEnqueue = (_) {
        if (native.tasks.length == 2 && !replacementReady.isCompleted) {
          replacementReady.complete();
        }
      };
      native.events.add(TaskStatusUpdate(old, TaskStatus.failed));
      await replacementReady.future.timeout(const Duration(seconds: 5));
      final current = native.tasks.last;
      final queued = enqueue('after-mirror', SourceContainer.mp4);
      await waitForRecord('after-mirror');
      native.events.add(TaskProgressUpdate(old, .91, 123));
      native.events.add(TaskStatusUpdate(old, TaskStatus.paused));
      await Future<void>.delayed(Duration.zero);
      expect(native.tasks, hasLength(2));
      final record = manager.all.singleWhere((r) => r.episodeId == 'mirror');
      expect(record.status, DownloadStatus.queued);
      expect(record.progress, 0);
      native.events.add(TaskStatusUpdate(current, TaskStatus.paused));
      await queued.timeout(const Duration(seconds: 5));
      expect(native.tasks, hasLength(3));
    },
    skip: !Platform.isWindows,
  );

  test(
    'same URL retry rejects serialized callbacks from previous attempt',
    () async {
      manager.dispose();
      final catalogue = _Catalogue();
      catalogue.streams['https://fixture.test/same'] = const [
        VideoSource(
          url: 'https://fixture.test/same.mp4',
          container: SourceContainer.mp4,
        ),
      ];
      manager = DownloadManager(
        catalogue,
        DownloadPrefs(),
        null,
        Dio()..httpClientAdapter = playlist,
        native,
      )..setup();
      await enqueue('same', SourceContainer.mp4);
      final old = native.tasks.single;
      final failed = Completer<void>();
      manager.addListener(() {
        if (manager.all.any(
              (r) => r.episodeId == 'same' && r.status == DownloadStatus.failed,
            ) &&
            !failed.isCompleted) {
          failed.complete();
        }
      });
      native.events.add(TaskStatusUpdate(old, TaskStatus.failed));
      await failed.future.timeout(const Duration(seconds: 5));
      await manager.retry(manager.all.single);
      final current = native.tasks.last;
      expect(current.url, old.url);
      expect(current.filename, isNot(old.filename));
      expect(current.taskId, old.taskId);
      expect(current.metaData, isNot(old.metaData));
      final restored = Task.createFromJson(current.toJson());
      expect(restored.metaData, current.metaData);
      final queued = enqueue('after-same', SourceContainer.mp4);
      await waitForRecord('after-same');
      final stale = Task.createFromJson(old.toJson());
      native.events.add(TaskProgressUpdate(stale, .99, 123));
      native.events.add(TaskStatusUpdate(stale, TaskStatus.complete));
      native.events.add(TaskStatusUpdate(stale, TaskStatus.paused));
      await Future<void>.delayed(Duration.zero);
      expect(native.tasks, hasLength(2));
      expect(manager.all.singleWhere((r) => r.episodeId == 'same').progress, 0);
      native.events.add(TaskStatusUpdate(restored, TaskStatus.paused));
      await queued.timeout(const Duration(seconds: 5));
      expect(native.tasks, hasLength(3));
    },
    skip: !Platform.isWindows,
  );

  test('old native callbacks cannot release an HLS fallback slot', () async {
    await manager.enqueueSource(
      sourceId: 'fixture',
      showId: 'show',
      showTitle: 'Fixture',
      showUrl: '/show',
      category: 'sub',
      episode: const Episode(
        id: 'native-hls',
        title: 'Fallback',
        url: '/native-hls',
      ),
      source: const VideoSource(
        url: 'https://fixture.test/file.mp4',
        container: SourceContainer.mp4,
      ),
      fallbacks: const [
        VideoSource(
          url: 'https://fixture.test/fallback.m3u8',
          container: SourceContainer.hls,
        ),
      ],
      qualityLabel: 'best',
      nowMs: 1,
    );
    final old = native.tasks.single;
    native.events.add(TaskStatusUpdate(old, TaskStatus.failed));
    await playlist.started.future.timeout(const Duration(seconds: 5));
    final queued = enqueue('after-hls', SourceContainer.mp4);
    await waitForRecord('after-hls');
    native.events.add(TaskProgressUpdate(old, .9, 100));
    native.events.add(TaskStatusUpdate(old, TaskStatus.paused));
    await Future<void>.delayed(Duration.zero);
    expect(native.tasks, hasLength(1));
    expect(
      manager.all.singleWhere((r) => r.episodeId == 'native-hls').progress,
      0,
    );
    playlist.finish.complete();
    await queued.timeout(const Duration(seconds: 5));
    expect(native.tasks, hasLength(2));
  }, skip: !Platform.isWindows);

  for (final failCommit in [false, true]) {
    test(
      'completion commit precedes cleanup; write failure=$failCommit',
      () async {
        await enqueue('commit', SourceContainer.mp4);
        final base = manager.all.single;
        final old = File('${root.path}/retired-before-commit.mp4');
        await old.writeAsBytes([1, 2, 3]);
        final saved = base.copyWith(retainedMediaPaths: [old.path]);
        await Hive.box<Map>(
          DownloadManager.boxName,
        ).put(saved.id, saved.toMap());
        final task = native.tasks.single as DownloadTask;
        native.restored = [task];
        manager.dispose();
        final writeStarted = Completer<void>();
        final releaseWrite = Completer<void>();
        var writes = 0;
        manager = DownloadManager(
          _Catalogue(),
          DownloadPrefs(),
          null,
          Dio()..httpClientAdapter = playlist,
          native,
          null,
          null,
          (record) async {
            writes++;
            if (!writeStarted.isCompleted) {
              writeStarted.complete();
              await releaseWrite.future;
            }
            if (failCommit) {
              throw const FileSystemException('private commit fault');
            }
            await Hive.box<Map>(
              DownloadManager.boxName,
            ).put(record.id, record.toMap());
          },
        )..setup();
        final media = File(await task.filePath());
        await media.parent.create(recursive: true);
        await media.writeAsBytes(List<int>.filled(600000, 1));
        native.events.add(TaskStatusUpdate(task, TaskStatus.complete));
        await writeStarted.future.timeout(const Duration(seconds: 5));
        expect(await old.exists(), isTrue);
        expect(await media.exists(), isTrue);
        expect(manager.all.single.status, isNot(DownloadStatus.done));
        final queued = enqueue('after-commit', SourceContainer.mp4);
        await waitForRecord('after-commit');
        expect(native.tasks, hasLength(1));
        releaseWrite.complete();
        await queued.timeout(const Duration(seconds: 5));
        final completed = manager.all.singleWhere((r) => r.id == base.id);
        expect(
          completed.status,
          failCommit ? DownloadStatus.failed : DownloadStatus.done,
        );
        expect(await old.exists(), failCommit);
        expect(await media.exists(), isTrue);
        if (failCommit) {
          expect(writes, 1);
          expect(completed.error, contains('library could not be updated'));
          expect(completed.error, isNot(contains('private')));
          expect(
            Hive.box<Map>(DownloadManager.boxName).get(base.id)!['status'],
            isNot('done'),
          );
        } else {
          expect(writes, 2);
          expect(completed.retainedMediaPaths, isEmpty);
          expect(
            Hive.box<Map>(DownloadManager.boxName).get(base.id)!['status'],
            'done',
          );
        }
      },
      skip: !Platform.isWindows,
    );
  }

  for (final heldWrite in [1, 2]) {
    for (final action in ['cancel', 'delete']) {
      test('$action wins over completion write $heldWrite', () async {
        await enqueue('commit-intent', SourceContainer.mp4);
        final base = manager.all.single;
        final old = File('${root.path}/intent-retired.mp4');
        await old.writeAsBytes([1]);
        await Hive.box<Map>(
          DownloadManager.boxName,
        ).put(base.id, base.copyWith(retainedMediaPaths: [old.path]).toMap());
        final task = native.tasks.single as DownloadTask;
        native.restored = [task];
        manager.dispose();
        final started = Completer<void>();
        final release = Completer<void>();
        var writes = 0;
        manager = DownloadManager(
          _Catalogue(),
          DownloadPrefs(),
          null,
          Dio()..httpClientAdapter = playlist,
          native,
          null,
          null,
          (record) async {
            if (++writes == heldWrite) {
              started.complete();
              await release.future;
            }
            await Hive.box<Map>(
              DownloadManager.boxName,
            ).put(record.id, record.toMap());
          },
        )..setup();
        final media = File(await task.filePath());
        await media.parent.create(recursive: true);
        await media.writeAsBytes(List<int>.filled(600000, 1));
        native.events.add(TaskStatusUpdate(task, TaskStatus.complete));
        await started.future.timeout(const Duration(seconds: 5));
        final current = manager.all.single;
        if (action == 'delete') {
          await manager.delete(current);
        } else {
          await manager.cancel(current);
        }
        final queued = enqueue('after-intent', SourceContainer.mp4);
        await waitForRecord('after-intent');
        release.complete();
        await queued.timeout(const Duration(seconds: 5));
        final stored = Hive.box<Map>(DownloadManager.boxName).get(base.id);
        if (action == 'delete') {
          expect(stored, isNull);
          expect(manager.all.any((r) => r.id == base.id), isFalse);
          expect(await media.exists(), isFalse);
        } else {
          expect(stored!['status'], 'canceled');
          expect(
            manager.all.singleWhere((r) => r.id == base.id).status,
            DownloadStatus.canceled,
          );
        }
      }, skip: !Platform.isWindows);
    }
  }

  // Exercise the actual per-ID public enqueue barrier while a disk commit is
  // delayed, rather than calling the private committer with an impossible state.
  for (final heldWrite in [1, 2]) {
    for (final action in ['cancel', 'delete']) {
      test(
        'fresh same-ID enqueue after $action survives completion write $heldWrite',
        () async {
          await enqueue('generation-commit', SourceContainer.mp4);
          final base = manager.all.single;
          final old = File('${root.path}/generation-retired.mp4');
          await old.writeAsBytes([1]);
          await Hive.box<Map>(
            DownloadManager.boxName,
          ).put(base.id, base.copyWith(retainedMediaPaths: [old.path]).toMap());
          final task = native.tasks.single as DownloadTask;
          native.restored = [task];
          manager.dispose();
          final started = Completer<void>();
          final release = Completer<void>();
          var writes = 0;
          manager = DownloadManager(
            _Catalogue(),
            DownloadPrefs(),
            null,
            Dio()..httpClientAdapter = playlist,
            native,
            null,
            null,
            (record) async {
              if (++writes == heldWrite) {
                started.complete();
                await release.future;
              }
              await Hive.box<Map>(
                DownloadManager.boxName,
              ).put(record.id, record.toMap());
            },
          )..setup();
          final media = File(await task.filePath());
          await media.parent.create(recursive: true);
          await media.writeAsBytes(List<int>.filled(600000, 1));
          native.events.add(TaskStatusUpdate(task, TaskStatus.complete));
          await started.future.timeout(const Duration(seconds: 5));
          if (action == 'delete') {
            await manager.delete(manager.all.single);
          } else {
            await manager.cancel(manager.all.single);
          }
          final replacement = enqueue('generation-commit', SourceContainer.mp4);
          await Future<void>.delayed(Duration.zero);
          expect(native.tasks, hasLength(1));
          release.complete();
          await replacement.timeout(const Duration(seconds: 5));
          final current = manager.all.single;
          expect(current.storageKey, isNot(base.storageKey));
          expect(current.status, isNot(DownloadStatus.done));
          expect(current.filePath, isNull);
          expect(native.tasks, hasLength(2));
          expect(await native.tasks.last.filePath(), isNot(media.path));
          final stored = DownloadRecord.fromMap(
            Hive.box<Map>(DownloadManager.boxName).get(base.id)!,
          );
          expect(stored.storageKey, current.storageKey);
          expect(stored.status, current.status);
          expect(stored.filePath, isNull);
        },
        skip: !Platform.isWindows,
      );
    }
  }

  for (final heldWrite in [1, 2]) {
    test(
      'subtitle arriving during completion write $heldWrite stays durable',
      () async {
        await enqueue('subtitle-race', SourceContainer.mp4);
        final base = manager.all.single;
        final old = File('${root.path}/subtitle-retired.mp4');
        await old.writeAsBytes([1]);
        await Hive.box<Map>(DownloadManager.boxName).put(
          base.id,
          base
              .copyWith(
                status: DownloadStatus.failed,
                retainedMediaPaths: [old.path],
              )
              .toMap(),
        );
        manager.dispose();
        final host = _SubtitleHost();
        final commitStarted = Completer<void>();
        final releaseCommit = Completer<void>();
        var writes = 0;
        manager = DownloadManager(
          _Catalogue(),
          DownloadPrefs(),
          null,
          Dio()..httpClientAdapter = host,
          native,
          null,
          null,
          (record) async {
            if (++writes == heldWrite) {
              commitStarted.complete();
              await releaseCommit.future;
            }
            await Hive.box<Map>(
              DownloadManager.boxName,
            ).put(record.id, record.toMap());
          },
        )..setup();
        await manager.enqueueSource(
          sourceId: 'fixture',
          showId: 'show',
          showTitle: 'Fixture',
          showUrl: '/show',
          category: 'sub',
          episode: const Episode(
            id: 'subtitle-race',
            title: 'Episode',
            url: '/episode',
          ),
          source: const VideoSource(
            url: 'https://fixture.test/video.mp4',
            container: SourceContainer.mp4,
            subtitles: [
              Subtitle(url: 'https://fixture.test/en.vtt', lang: 'en'),
              Subtitle(url: 'https://fixture.test/ja.vtt', lang: 'ja'),
            ],
          ),
          qualityLabel: 'best',
          nowMs: 2,
        );
        await host.started.future.timeout(const Duration(seconds: 5));
        final task = native.tasks.last as DownloadTask;
        final media = File(await task.filePath());
        await media.parent.create(recursive: true);
        await media.writeAsBytes(List<int>.filled(600000, 1));
        native.events.add(TaskStatusUpdate(task, TaskStatus.complete));
        await commitStarted.future.timeout(const Duration(seconds: 5));
        final subtitleSaved = Completer<void>();
        manager.addListener(() {
          if (manager.all.any(
                (r) => r.id == base.id && r.subtitles.isNotEmpty,
              ) &&
              !subtitleSaved.isCompleted) {
            subtitleSaved.complete();
          }
        });
        host.release.complete();
        await subtitleSaved.future.timeout(const Duration(seconds: 5));
        final queued = enqueue('after-subtitle', SourceContainer.mp4);
        await waitForRecord('after-subtitle');
        releaseCommit.complete();
        await queued.timeout(const Duration(seconds: 5));
        final completed = manager.all.singleWhere((r) => r.id == base.id);
        expect(completed.status, DownloadStatus.done);
        expect(completed.subtitles, hasLength(1));
        expect(completed.subtitles.single.lang, 'en');
        expect(
          await File(completed.subtitles.single.path).readAsString(),
          contains('English'),
        );
        final stored = DownloadRecord.fromMap(
          Hive.box<Map>(DownloadManager.boxName).get(base.id)!,
        );
        expect(stored.subtitles, hasLength(1));
        expect(host.requested, ['/en.vtt']);
      },
      skip: !Platform.isWindows,
    );
  }

  test(
    'retired subtitle worker cannot recreate a deleted library record',
    () async {
      manager.dispose();
      final host = _SubtitleHost();
      manager = DownloadManager(
        _Catalogue(),
        DownloadPrefs(),
        null,
        Dio()..httpClientAdapter = host,
        native,
      )..setup();
      await manager.enqueueSource(
        sourceId: 'fixture',
        showId: 'show',
        showTitle: 'Fixture',
        showUrl: '/show',
        category: 'sub',
        episode: const Episode(
          id: 'retired-sub',
          title: 'Episode',
          url: '/episode',
        ),
        source: const VideoSource(
          url: 'https://fixture.test/video.mp4',
          container: SourceContainer.mp4,
          subtitles: [Subtitle(url: 'https://fixture.test/en.vtt', lang: 'en')],
        ),
        qualityLabel: 'best',
        nowMs: 1,
      );
      await host.started.future.timeout(const Duration(seconds: 5));
      final id = manager.all.single.id;
      final retired = manager;
      retired.dispose();
      manager = DownloadManager(
        _Catalogue(),
        DownloadPrefs(),
        null,
        Dio()..httpClientAdapter = playlist,
        native,
      )..setup();
      await manager.delete(manager.all.single);
      expect(Hive.box<Map>(DownloadManager.boxName).get(id), isNull);
      host.release.complete();
      await retired.subtitleWorkCompleted.timeout(const Duration(seconds: 5));
      expect(Hive.box<Map>(DownloadManager.boxName).get(id), isNull);
      expect(manager.all, isEmpty);
      final folder = Directory('${root.path}/Videos/Fixture/Subtitles');
      expect(
        await folder.list().where((file) => file.path.endsWith('.vtt')).isEmpty,
        isTrue,
      );
    },
    skip: !Platform.isWindows,
  );

  // Seeds actual Hive records and awaits real startup cleanup, not a timer.
  Future<DownloadRecord> restartCleanup(
    File media,
    List<String> retired, {
    bool shared = false,
    bool activeShared = false,
  }) async {
    final record = DownloadRecord.fromMap({
      'id': 'cleanup',
      'status': 'done',
      'filePath': media.path,
      'bytesTotal': 4,
      'retainedMediaPaths': retired,
    });
    await Hive.box<Map>(DownloadManager.boxName).put(record.id, record.toMap());
    if (shared || activeShared) {
      await Hive.box<Map>(DownloadManager.boxName).put('other-owner', {
        ...record.toMap(),
        'id': 'other-owner',
        'filePath': retired.first,
        'bytesTotal': 0,
        'retainedMediaPaths': <String>[],
      });
    }
    if (activeShared) {
      final destination = File(retired.first);
      native.restored = [
        DownloadTask(
          taskId: 'other-owner',
          url: 'https://fixture.test/active.mp4',
          filename: destination.uri.pathSegments.last,
          directory: destination.parent.path,
          baseDirectory: BaseDirectory.root,
        ),
      ];
    }
    manager.dispose();
    manager = DownloadManager(
      _Catalogue(),
      DownloadPrefs(),
      null,
      Dio()..httpClientAdapter = playlist,
      native,
    )..setup();
    await manager.retiredCleanupCompleted.timeout(const Duration(seconds: 5));
    return manager.all.singleWhere((r) => r.id == record.id);
  }

  test(
    'restart retires old copy only behind intact committed replacement',
    () async {
      final media = File('${root.path}/verified.mp4');
      final old = File('${root.path}/retired.mp4');
      await media.writeAsBytes([1, 2, 3, 4]);
      await old.writeAsBytes([5]);
      final done = await restartCleanup(media, [old.path]);
      expect(await media.readAsBytes(), [1, 2, 3, 4]);
      expect(await old.exists(), isFalse);
      expect(done.retainedMediaPaths, isEmpty);
      expect(
        Hive.box<Map>(
          DownloadManager.boxName,
        ).get(done.id)!['retainedMediaPaths'],
        isEmpty,
      );
      manager.dispose();
      manager = DownloadManager(
        _Catalogue(),
        DownloadPrefs(),
        null,
        Dio()..httpClientAdapter = playlist,
        native,
      )..setup();
      await manager.retiredCleanupCompleted.timeout(const Duration(seconds: 5));
      expect(await media.readAsBytes(), [1, 2, 3, 4]);
    },
    skip: !Platform.isWindows,
  );

  for (final kind in ['missing', 'empty', 'wrong-size']) {
    test('restart preserves prior copy when replacement is $kind', () async {
      final media = File('${root.path}/invalid.mp4');
      final old = File('${root.path}/good-old.mp4');
      if (kind != 'missing') {
        await media.writeAsBytes(kind == 'empty' ? [] : [1]);
      }
      await old.writeAsBytes([5, 6]);
      final done = await restartCleanup(media, [old.path]);
      expect(await old.readAsBytes(), [5, 6]);
      expect(done.retainedMediaPaths, [old.path]);
    }, skip: !Platform.isWindows);
  }

  test('restart preserves an older file owned by another entry', () async {
    final media = File('${root.path}/verified.mp4');
    final old = File('${root.path}/shared.mp4');
    await media.writeAsBytes([1, 2, 3, 4]);
    await old.writeAsBytes([5]);
    final done = await restartCleanup(media, [old.path], shared: true);
    expect(await old.exists(), isTrue);
    expect(done.retainedMediaPaths, [old.path]);
  }, skip: !Platform.isWindows);

  test(
    'restart preserves a file currently owned by another native transfer',
    () async {
      final media = File('${root.path}/verified.mp4');
      final active = File('${root.path}/active-target.mp4');
      await media.writeAsBytes([1, 2, 3, 4]);
      await active.writeAsBytes([5]);
      final done = await restartCleanup(media, [
        active.path,
      ], activeShared: true);
      expect(await active.exists(), isTrue);
      expect(done.retainedMediaPaths, [active.path]);
    },
    skip: !Platform.isWindows,
  );

  test('equivalent Windows spelling never deletes replacement', () async {
    final media = File('${root.path}/verified.mp4');
    await media.writeAsBytes([1, 2, 3, 4]);
    final alias = media.path.replaceAll('/', r'\').toUpperCase();
    final done = await restartCleanup(media, [alias]);
    expect(await media.readAsBytes(), [1, 2, 3, 4]);
    expect(done.retainedMediaPaths, isEmpty);
  }, skip: !Platform.isWindows);

  test(
    'missing retired file on available storage clears stale pointer',
    () async {
      final media = File('${root.path}/verified.mp4');
      await media.writeAsBytes([1, 2, 3, 4]);
      final done = await restartCleanup(media, ['${root.path}/gone.mp4']);
      expect(done.retainedMediaPaths, isEmpty);
    },
    skip: !Platform.isWindows,
  );

  test(
    'unmounted drive retains retired metadata without writes to that volume',
    () async {
      String? absent;
      for (var letter = 65; letter <= 90; letter++) {
        final drive = '${String.fromCharCode(letter)}:/';
        if (!await Directory(drive).exists()) {
          absent = drive;
          break;
        }
      }
      if (absent == null) {
        markTestSkipped('No absent drive available for read-only volume check');
        return;
      }
      final media = File('${root.path}/verified.mp4');
      await media.writeAsBytes([1, 2, 3, 4]);
      final retired = '${absent}Zangetsu/retired.mp4';
      final done = await restartCleanup(media, [retired]);
      expect(done.retainedMediaPaths, [retired]);
      expect(await media.readAsBytes(), [1, 2, 3, 4]);
    },
    skip: !Platform.isWindows,
  );

  for (final numbers in <(double?, double?)>[
    (null, null),
    (1, 1),
    (12, 12.5),
  ]) {
    test('distinct episode destinations for numbers $numbers', () async {
      manager.setParallel(2);
      for (var index = 0; index < 2; index++) {
        await manager.enqueueSource(
          sourceId: 'fixture',
          showId: 'show',
          showTitle: 'Fixture',
          showUrl: '/show',
          category: 'sub',
          episode: Episode(
            id: 'season-$index',
            title: 'Episode',
            url: '/episode/$index',
            number: index == 0 ? numbers.$1 : numbers.$2,
            season: numbers.$1 == 1 && numbers.$2 == 1 ? index + 1 : 1,
          ),
          source: VideoSource(
            url: 'https://fixture.test/$index.mp4',
            container: SourceContainer.mp4,
          ),
          qualityLabel: 'best',
          nowMs: index,
        );
      }
      expect(native.tasks, hasLength(2));
      final first = await (native.tasks.first as DownloadTask).filePath();
      final second = await (native.tasks.last as DownloadTask).filePath();
      expect(first, isNot(second));
      for (final record in manager.all) {
        final restored = DownloadRecord.fromMap(record.toMap());
        expect(restored.season, record.season);
        expect(restored.storageKey, record.storageKey);
        expect(restored.storageKey, isNotEmpty);
      }
    }, skip: !Platform.isWindows);
  }

  test(
    'HLS episodes without numbers write distinct intact destination files',
    () async {
      manager.dispose();
      manager = DownloadManager(
        _Catalogue(),
        DownloadPrefs(),
        null,
        Dio()..httpClientAdapter = _NamedHls(),
        native,
      )..setup();
      manager.setParallel(2);
      final done = Completer<void>();
      manager.addListener(() {
        if (manager.all.length == 2 &&
            manager.all.every((r) => r.status == DownloadStatus.done) &&
            !done.isCompleted) {
          done.complete();
        }
      });
      for (final name in ['one', 'two']) {
        await manager.enqueueSource(
          sourceId: 'fixture',
          showId: 'show',
          showTitle: 'Fixture',
          showUrl: '/show',
          category: 'sub',
          episode: Episode(id: name, title: name, url: '/$name'),
          source: VideoSource(
            url: 'https://fixture.test/$name.m3u8',
            container: SourceContainer.hls,
          ),
          qualityLabel: 'best',
          nowMs: 1,
        );
      }
      await done.future.timeout(const Duration(seconds: 5));
      final first = manager.all.singleWhere((r) => r.episodeId == 'one');
      final second = manager.all.singleWhere((r) => r.episodeId == 'two');
      expect(first.filePath, isNot(second.filePath));
      expect(await File(first.filePath!).length(), 188);
      expect(await File(second.filePath!).length(), 376);
      await manager.subtitleWorkCompleted;
    },
    skip: !Platform.isWindows,
  );

  test(
    'subtitle sidecars without episode numbers use isolated file names',
    () async {
      manager.dispose();
      final host = _SubtitleHost()..release.complete();
      manager = DownloadManager(
        _Catalogue(),
        DownloadPrefs(),
        null,
        Dio()..httpClientAdapter = host,
        native,
      )..setup();
      manager.setParallel(2);
      for (final name in ['one', 'two']) {
        await manager.enqueueSource(
          sourceId: 'fixture',
          showId: 'show',
          showTitle: 'Fixture',
          showUrl: '/show',
          category: 'sub',
          episode: Episode(id: name, title: name, url: '/$name'),
          source: VideoSource(
            url: 'https://fixture.test/$name.mp4',
            container: SourceContainer.mp4,
            subtitles: [
              Subtitle(url: 'https://fixture.test/$name.vtt', lang: 'en'),
            ],
          ),
          qualityLabel: 'best',
          nowMs: 1,
        );
      }
      await manager.subtitleWorkCompleted.timeout(const Duration(seconds: 5));
      final paths = manager.all.map((r) => r.subtitles.single.path).toList();
      expect(paths.toSet(), hasLength(2));
      for (final path in paths) {
        expect(await File(path).readAsString(), contains('English'));
      }
    },
    skip: !Platform.isWindows,
  );

  test(
    'legacy native resume keeps saved original filename and media path',
    () async {
      final folder = Directory('${root.path}/legacy');
      await folder.create();
      final original = File('${folder.path}/original-download.mp4');
      await original.writeAsBytes([1, 2, 3]);
      final record = DownloadRecord.fromMap({
        'id': 'fixture_show_legacy',
        'status': 'paused',
        'filePath': original.path,
      });
      await Hive.box<Map>(
        DownloadManager.boxName,
      ).put(record.id, record.toMap());
      final task = DownloadTask(
        taskId: record.id,
        url: 'https://fixture.test/old.mp4',
        filename: 'original-download.mp4',
        directory: folder.path,
        baseDirectory: BaseDirectory.root,
        allowPause: true,
      );
      native.restored = [task];
      manager.dispose();
      manager = DownloadManager(
        _Catalogue(),
        DownloadPrefs(),
        null,
        Dio()..httpClientAdapter = playlist,
        native,
      )..setup();
      await DownloadPrefs().setLocation(
        '${root.path}/legacy-new-default',
        'New default',
      );
      await manager.resume(record);
      expect(native.resumed.single.filename, 'original-download.mp4');
      expect(
        await FileSystemEntity.identical(
          await native.resumed.single.filePath(),
          original.path,
        ),
        isTrue,
      );
      expect(await original.readAsBytes(), [1, 2, 3]);
      expect(manager.all.single.storageKey, isEmpty);
      expect(manager.all.single.downloadRoot, isNull);
    },
    skip: !Platform.isWindows,
  );

  test(
    'queued video and subtitles keep accepted folder after default changes',
    () async {
      manager.dispose();
      manager = DownloadManager(
        _Catalogue(),
        DownloadPrefs(),
        null,
        Dio()..httpClientAdapter = (_SubtitleHost()..release.complete()),
        native,
      )..setup();
      await enqueue('folder-blocker', SourceContainer.mp4);
      final pending = manager.enqueueSource(
        sourceId: 'fixture',
        showId: 'show',
        showTitle: 'Fixture',
        showUrl: '/show',
        category: 'sub',
        episode: const Episode(id: 'folder-held', title: 'Held', url: '/held'),
        source: const VideoSource(
          url: 'https://fixture.test/held.mp4',
          container: SourceContainer.mp4,
          subtitles: [Subtitle(url: 'https://fixture.test/en.vtt', lang: 'en')],
        ),
        qualityLabel: 'best',
        nowMs: 1,
      );
      await waitForRecord('folder-held');
      final changed = '${root.path}/changed-default';
      await DownloadPrefs().setLocation(changed, changed);
      await manager.cancel(
        manager.all.singleWhere((r) => r.episodeId == 'folder-blocker'),
      );
      await pending.timeout(const Duration(seconds: 5));
      await manager.subtitleWorkCompleted.timeout(const Duration(seconds: 5));
      final current = manager.all.singleWhere(
        (r) => r.episodeId == 'folder-held',
      );
      final stored = DownloadRecord.fromMap(
        Hive.box<Map>(DownloadManager.boxName).get(current.id)!,
      );
      expect(current.downloadRoot, root.path);
      expect(stored.downloadRoot, root.path);
      expect(
        stored.copyWith(status: DownloadStatus.paused).downloadRoot,
        root.path,
      );
      final nativePath = await native.tasks.last.filePath();
      expect(
        nativePath.replaceAll('\\', '/'),
        startsWith('${root.path.replaceAll('\\', '/')}/Videos/Fixture/'),
      );
      expect(
        current.subtitles.single.path.replaceAll('\\', '/'),
        startsWith(
          '${root.path.replaceAll('\\', '/')}/Videos/Fixture/Subtitles/',
        ),
      );
      expect(await File(current.subtitles.single.path).exists(), isTrue);
      await manager.cancel(current);
      await enqueue('folder-future', SourceContainer.mp4);
      expect(
        (await native.tasks.last.filePath()).replaceAll('\\', '/'),
        startsWith('${changed.replaceAll('\\', '/')}/Videos/Fixture/'),
      );
    },
    skip: !Platform.isWindows,
  );

  test('queued HLS keeps accepted folder when default changes', () async {
    manager.dispose();
    manager = DownloadManager(
      _Catalogue(),
      DownloadPrefs(),
      null,
      Dio()..httpClientAdapter = _NamedHls(),
      native,
    )..setup();
    await enqueue('hls-folder-blocker', SourceContainer.mp4);
    final done = Completer<void>();
    manager.addListener(() {
      if (manager.all.any(
            (record) =>
                record.episodeId == 'hls-folder' &&
                record.status == DownloadStatus.done,
          ) &&
          !done.isCompleted) {
        done.complete();
      }
    });
    final pending = manager.enqueueSource(
      sourceId: 'fixture',
      showId: 'show',
      showTitle: 'Fixture',
      showUrl: '/show',
      category: 'sub',
      episode: const Episode(
        id: 'hls-folder',
        title: 'HLS',
        url: '/hls-folder',
      ),
      source: const VideoSource(
        url: 'https://fixture.test/one.m3u8',
        container: SourceContainer.hls,
      ),
      qualityLabel: 'best',
      nowMs: 1,
    );
    await waitForRecord('hls-folder');
    await DownloadPrefs().setLocation(
      '${root.path}/hls-new-default',
      'New default',
    );
    await manager.cancel(
      manager.all.singleWhere((r) => r.episodeId == 'hls-folder-blocker'),
    );
    await pending.timeout(const Duration(seconds: 5));
    await done.future.timeout(const Duration(seconds: 5));
    await manager.subtitleWorkCompleted;
    final current = manager.all.singleWhere((r) => r.episodeId == 'hls-folder');
    expect(current.downloadRoot, root.path);
    expect(
      current.filePath!.replaceAll('\\', '/'),
      startsWith('${root.path.replaceAll('\\', '/')}/Videos/Fixture/'),
    );
    expect(await File(current.filePath!).length(), 188);
  }, skip: !Platform.isWindows);

  test('queued folder survives Hive reopen and source re-resolution', () async {
    await enqueue('restart-folder-blocker', SourceContainer.mp4);
    final pending = enqueue('restart-folder', SourceContainer.mp4);
    await waitForRecord('restart-folder');
    final saved = manager.all.singleWhere(
      (r) => r.episodeId == 'restart-folder',
    );
    final oldManager = manager;
    oldManager.dispose();
    await pending.timeout(const Duration(seconds: 5));
    await oldManager.subtitleWorkCompleted;
    await Hive.close();
    Hive.init(root.path);
    await DownloadPrefs.init();
    await DownloadManager.init();
    final changed = '${root.path}/restart-new-default';
    await DownloadPrefs().setLocation(changed, changed);
    final catalogue = _Catalogue();
    catalogue.streams[saved.episodeUrl] = const [
      VideoSource(
        url: 'https://fixture.test/re-resolved.mp4',
        container: SourceContainer.mp4,
        subtitles: [Subtitle(url: 'https://fixture.test/en.vtt', lang: 'en')],
      ),
    ];
    manager = DownloadManager(
      catalogue,
      DownloadPrefs(),
      null,
      Dio()..httpClientAdapter = (_SubtitleHost()..release.complete()),
      native,
    )..setup();
    await manager.retiredCleanupCompleted.timeout(const Duration(seconds: 5));
    final reopened = manager.all.singleWhere((r) => r.id == saved.id);
    expect(reopened.status, DownloadStatus.paused);
    expect(reopened.downloadRoot, root.path);
    await manager.resume(reopened).timeout(const Duration(seconds: 5));
    await manager.subtitleWorkCompleted;
    final current = manager.all.singleWhere((r) => r.id == saved.id);
    expect(catalogue.requested, [saved.episodeUrl]);
    expect(current.storageKey, saved.storageKey);
    expect(
      (await native.tasks.last.filePath()).replaceAll('\\', '/'),
      startsWith('${root.path.replaceAll('\\', '/')}/Videos/Fixture/'),
    );
    expect(
      current.subtitles.single.path.replaceAll('\\', '/'),
      startsWith(
        '${root.path.replaceAll('\\', '/')}/Videos/Fixture/Subtitles/',
      ),
    );
    expect(await File(current.subtitles.single.path).exists(), isTrue);
  }, skip: !Platform.isWindows);

  // Raw identity and tuple boundaries must survive filesystem-safe task IDs.
  for (final boundary in [false, true]) {
    test(
      'distinct download tuples survive sanitized ID collision boundary=$boundary',
      () async {
        await DownloadPrefs().setParallelDownloads(2);
        Future<void> start(String show, String episode) =>
            manager.enqueueSource(
              sourceId: 'fixture',
              showId: show,
              showTitle: 'Fixture',
              showUrl: '/show',
              category: 'sub',
              episode: Episode(id: episode, title: episode, url: '/$episode'),
              source: const VideoSource(
                url: 'https://fixture.test/media.mp4',
                container: SourceContainer.mp4,
              ),
              qualityLabel: 'best',
              nowMs: 1,
            );
        final firstShow = boundary ? 'show_a' : 'show';
        final firstEpisode = boundary ? 'b' : 'a/b';
        final secondEpisode = boundary ? 'a_b' : 'a?b';
        await start(firstShow, firstEpisode);
        final first = manager.recordFor('fixture', firstShow, firstEpisode)!;
        expect(manager.recordFor('fixture', 'show', secondEpisode), isNull);
        await start('show', secondEpisode).timeout(const Duration(seconds: 5));
        expect(manager.all, hasLength(2));
        final second = manager.recordFor('fixture', 'show', secondEpisode)!;
        expect(second.id, isNot(first.id));
        expect(native.tasks, hasLength(2));
        expect(native.tasks.map((task) => task.taskId).toSet(), hasLength(2));
        manager.dispose();
        native.restored = native.tasks.toList();
        manager = DownloadManager(
          _Catalogue(),
          DownloadPrefs(),
          null,
          Dio()..httpClientAdapter = playlist,
          native,
        )..setup();
        expect(
          manager.recordFor('fixture', firstShow, firstEpisode)!.id,
          first.id,
        );
        expect(
          manager.recordFor('fixture', 'show', secondEpisode)!.id,
          second.id,
        );
      },
      skip: !Platform.isWindows,
    );
  }

  test('legacy colliding record keeps its saved file and identity', () async {
    final file = File('${root.path}/legacy-identity.mp4');
    await file.writeAsBytes([1, 2, 3, 4]);
    final legacy = DownloadRecord.fromMap({
      'id': 'fixture_show_a_b',
      'sourceId': 'fixture',
      'showId': 'show',
      'episodeId': 'a/b',
      'status': 'done',
      'filePath': file.path,
      'bytesTotal': 4,
    });
    await Hive.box<Map>(DownloadManager.boxName).put(legacy.id, legacy.toMap());
    manager.dispose();
    manager = DownloadManager(
      _Catalogue(),
      DownloadPrefs(),
      null,
      Dio()..httpClientAdapter = playlist,
      native,
    )..setup();
    expect(manager.recordFor('fixture', 'show', 'a/b')!.id, legacy.id);
    expect(manager.recordFor('fixture', 'show', 'a?b'), isNull);
    await enqueue('a?b', SourceContainer.mp4);
    expect(manager.all, hasLength(2));
    expect(manager.recordFor('fixture', 'show', 'a?b')!.id, isNot(legacy.id));
    final preserved = manager.recordFor('fixture', 'show', 'a/b')!;
    expect(preserved.id, legacy.id);
    expect(preserved.filePath, file.path);
    expect(await file.readAsBytes(), [1, 2, 3, 4]);
    expect(
      Hive.box<Map>(DownloadManager.boxName).get(legacy.id)!['filePath'],
      file.path,
    );
  }, skip: !Platform.isWindows);

  test(
    'old same-ID subtitle response cannot replace fresh-generation subtitles',
    () async {
      manager.dispose();
      final host = _GenerationSubtitleHost();
      manager = DownloadManager(
        _Catalogue(),
        DownloadPrefs(),
        null,
        Dio()..httpClientAdapter = host,
        native,
      )..setup();
      Future<void> start(String name) => manager.enqueueSource(
        sourceId: 'fixture',
        showId: 'show',
        showTitle: 'Fixture',
        showUrl: '/show',
        category: 'sub',
        episode: const Episode(
          id: 'generation',
          title: 'Episode',
          url: '/generation',
        ),
        source: VideoSource(
          url: 'https://fixture.test/$name.mp4',
          container: SourceContainer.mp4,
          subtitles: [
            Subtitle(url: 'https://fixture.test/$name.vtt', lang: 'en'),
          ],
        ),
        qualityLabel: 'best',
        nowMs: 1,
      );
      await start('old');
      await host.oldStarted.future.timeout(const Duration(seconds: 5));
      final oldKey = manager.all.single.storageKey;
      await manager.cancel(manager.all.single);
      final saved = Completer<void>();
      manager.addListener(() {
        if (manager.all.any(
              (r) => r.storageKey != oldKey && r.subtitles.isNotEmpty,
            ) &&
            !saved.isCompleted)
          saved.complete();
      });
      await start('new');
      await saved.future.timeout(const Duration(seconds: 5));
      final newKey = manager.all.single.storageKey;
      final newPath = manager.all.single.subtitles.single.path;
      host.releaseOld.complete();
      await manager.subtitleWorkCompleted.timeout(const Duration(seconds: 5));
      final current = manager.all.single;
      expect(current.storageKey, newKey);
      expect(current.subtitles.single.path, newPath);
      expect(
        await File(current.subtitles.single.path).readAsString(),
        contains('New English'),
      );
      final stored = DownloadRecord.fromMap(
        Hive.box<Map>(DownloadManager.boxName).get(current.id)!,
      );
      expect(stored.storageKey, newKey);
      expect(stored.subtitles.single.path, newPath);
      final folder = Directory('${root.path}/Videos/Fixture/Subtitles');
      expect(
        await folder.list().where((file) => file.path.endsWith('.vtt')).length,
        1,
      );
    },
    skip: !Platform.isWindows,
  );

  test(
    'interrupted saved transfer becomes paused without losing progress',
    () async {
      await enqueue('old', SourceContainer.mp4);
      final record = manager.all.single.copyWith(
        status: DownloadStatus.downloading,
        progress: .42,
      );
      await Hive.box<Map>(
        DownloadManager.boxName,
      ).put(record.id, record.toMap());
      manager.dispose();
      manager = DownloadManager(
        _Catalogue(),
        DownloadPrefs(),
        null,
        Dio(),
        native,
      )..setup();
      await enqueue('new', SourceContainer.mp4);
      final recovered = manager.all.singleWhere((r) => r.episodeId == 'old');
      expect(recovered.status, DownloadStatus.paused);
      expect(recovered.progress, .42);
      expect(
        Hive.box<Map>(DownloadManager.boxName).get(record.id)!['status'],
        'paused',
      );
    },
    skip: !Platform.isWindows,
  );

  test('surviving native task owns startup capacity before new jobs', () async {
    await enqueue('old', SourceContainer.mp4);
    final legacy = Task.createFromJson({
      ...native.tasks.single.toJson(),
      'metaData': '',
    });
    native.restored = [legacy];
    manager.dispose();
    manager = DownloadManager(
      _Catalogue(),
      DownloadPrefs(),
      null,
      Dio(),
      native,
    )..setup();
    final queued = enqueue('new', SourceContainer.mp4);
    await waitForRecord('new');
    await Future<void>.delayed(Duration.zero);
    expect(native.tasks, hasLength(1));
    native.events.add(TaskStatusUpdate(legacy, TaskStatus.paused));
    await queued.timeout(const Duration(seconds: 5));
    expect(native.tasks, hasLength(2));
  }, skip: !Platform.isWindows);

  test(
    'failed native enqueue releases capacity for the next episode',
    () async {
      native.accepts = false;
      await enqueue('failed', SourceContainer.mp4);
      expect(manager.all.single.status, DownloadStatus.failed);
      native.accepts = true;
      await enqueue(
        'next',
        SourceContainer.mp4,
      ).timeout(const Duration(seconds: 5));
      expect(native.tasks, hasLength(2));
    },
    skip: !Platform.isWindows,
  );

  test(
    'canceled pending episode cannot start when active work finishes',
    () async {
      await enqueue('first', SourceContainer.mp4);
      final pending = enqueue('canceled', SourceContainer.mp4);
      await waitForRecord('canceled');
      await Future<void>.delayed(Duration.zero);
      await manager.cancel(
        manager.all.singleWhere((r) => r.episodeId == 'canceled'),
      );
      await pending.timeout(const Duration(seconds: 5));
      native.events.add(
        TaskStatusUpdate(native.tasks.first, TaskStatus.paused),
      );
      await enqueue(
        'last',
        SourceContainer.mp4,
      ).timeout(const Duration(seconds: 5));
      expect(native.tasks, hasLength(2));
      expect(native.tasks.last.url, contains('/last.'));
      expect(
        manager.all.singleWhere((r) => r.episodeId == 'canceled').status,
        DownloadStatus.canceled,
      );
    },
    skip: !Platform.isWindows,
  );

  test(
    'configured chunks reach native task and failure retries same URL once',
    () async {
      manager.dispose();
      await DownloadPrefs().setConnectionsPerDownload(8);
      manager = DownloadManager(
        _Catalogue(),
        DownloadPrefs(),
        null,
        Dio()..httpClientAdapter = _RangeHost(),
        native,
      )..setup();
      await enqueue('file', SourceContainer.mp4);
      expect(native.tasks.single, isA<ParallelDownloadTask>());
      expect((native.tasks.single as ParallelDownloadTask).chunks, 8);
      final fallback = Completer<Task>();
      native.onEnqueue = fallback.complete;
      native.events.add(
        TaskStatusUpdate(native.tasks.single, TaskStatus.failed),
      );
      final single = await fallback.future.timeout(const Duration(seconds: 5));
      expect(single, isNot(isA<ParallelDownloadTask>()));
      expect(single.url, native.tasks.first.url);
      expect(single.taskId, native.tasks.first.taskId);
      expect(single.filename, native.tasks.first.filename);
      expect(single.metaData, isNot(native.tasks.first.metaData));
      expect(Task.createFromJson(single.toJson()).metaData, single.metaData);
      native.onEnqueue = null;
    },
    skip: !Platform.isWindows,
  );

  for (final typedException in [true, false]) {
    test('HTTP429 waits durably without chunk fallback typed=$typedException', () async {
      manager.dispose();
      await DownloadPrefs().setConnectionsPerDownload(8);
      manager = DownloadManager(_Catalogue(), DownloadPrefs(), null,
          Dio()..httpClientAdapter = _RangeHost(), native)..setup();
      await enqueue('limited', SourceContainer.mp4);
      final failed = Completer<void>();
      void check() {
        if (manager.all.any((r) => r.episodeId == 'limited' && r.status == DownloadStatus.queued && r.retryAt != null) && !failed.isCompleted) {
          failed.complete();
        }
      }
      manager.addListener(check);
      try {
        native.events.add(TaskStatusUpdate(native.tasks.single, TaskStatus.failed,
            typedException ? TaskHttpException('<html>429 Too Many Requests</html>', 429) : null,
            null, {'retry-after': '120'}, typedException ? null : 429));
        await failed.future.timeout(const Duration(seconds: 5));
        expect(native.tasks, hasLength(1));
        expect(manager.all.single.error, contains('(429)'));
        expect(manager.all.single.error, isNot(contains('<html>')));
        final deadline = DownloadPrefs().hostCooldownUntil(Uri.parse(native.tasks.single.url));
        expect(deadline, isNotNull);
        expect(deadline!.difference(DateTime.now()).inSeconds, inInclusiveRange(115, 120));
        await manager.resume(manager.all.single);
        expect(native.resumed, isEmpty);
        await enqueue('limited-next', SourceContainer.mp4);
        expect(native.tasks, hasLength(1));
        expect(manager.all.firstWhere((r) => r.episodeId == 'limited-next').error,
            contains('Waiting to retry'));
        await enqueue('unrelated', SourceContainer.mp4, host: 'other.test');
        expect(native.tasks, hasLength(2));
        expect(Uri.parse(native.tasks.last.url).host, 'other.test');


      } finally {
        manager.removeListener(check);
      }
    }, skip: !Platform.isWindows);
  }

  for (final action in ['retry', 'pause-resume', 'restart', 'paused-restart', 'cancel', 'delete', 'replace', 'extended-host', 'repeat']) {
    test('persisted429 $action respects deadline, generation and English server preference', () async {
      manager.dispose();
      var now = DateTime.utc(2026, 10, 28);
      var timers = <_RetryTimer>[];
      DesktopDownloadRetry scheduler() => DesktopDownloadRetry(now: () => now,
          timerFactory: (_, action) { final t = _RetryTimer(action); timers.add(t); return t; });
      final catalogue = _Catalogue();
      const episode = Episode(id: 'english-wait', title: 'English', url: 'https://fixture.test/episode');
      catalogue.streams[episode.url] = const [
        VideoSource(url: 'https://fixture.test/jp.mp4', label: 'B', quality: '1080p', kind: AudioKind.sub, audioLang: 'ja'),
        VideoSource(url: 'https://fixture.test/fresh.mp4?token=new', label: 'B', quality: '720p', kind: AudioKind.dub, audioLang: 'en'),
      ];
      DownloadManager create() => DownloadManager(catalogue, DownloadPrefs(), null,
          Dio(), native, null, null, null, null, scheduler())..setup();
      manager = create();
      await manager.enqueueSource(sourceId: 'fixture', showId: 'show', showTitle: 'Fixture',
          showUrl: '/show', category: 'dub', episode: episode,
          source: const VideoSource(url: 'https://fixture.test/expired.mp4?token=old', label: 'B',
              kind: AudioKind.dub, audioLang: 'en', container: SourceContainer.mp4),
          qualityLabel: '720p', nowMs: 1);
      final waiting = Completer<void>();
      void check() {
        if (manager.all.any((r) => r.retryAt != null) && !waiting.isCompleted) waiting.complete();
      }
      manager.addListener(check);
      native.events.add(TaskStatusUpdate(native.tasks.single, TaskStatus.failed,
          TaskHttpException('limited', 429), null, {'retry-after': '120'}, 429));
      await waiting.future.timeout(const Duration(seconds: 5));
      manager.removeListener(check);
      final saved = manager.all.single;
      expect(saved.status, DownloadStatus.queued);
      expect(saved.retryAt, now.add(const Duration(seconds: 120)).millisecondsSinceEpoch);
      expect(saved.autoResumePending, isTrue);
      expect(catalogue.requested, isEmpty);
      final oldTimer = timers.single;
      if (action == 'extended-host') {
        await DownloadPrefs().rememberHostCooldown(Uri.parse('https://fixture.test/'), '240', now: now);
      }
      if (action == 'pause-resume' || action == 'paused-restart') await manager.pause(saved);
      if (action == 'cancel' || action == 'replace') await manager.cancel(saved);
      if (action == 'delete') await manager.delete(saved);
      if (action == 'restart' || action == 'paused-restart') {
        manager.dispose();
        await Hive.box<Map>(DownloadManager.boxName).close();
        await DownloadManager.init();
        timers = [];
        manager = create();
        await manager.retiredCleanupCompleted.timeout(const Duration(seconds: 5));
        expect(manager.all.single.retryAt, saved.retryAt);
        expect(timers, hasLength(action == 'paused-restart' ? 0 : 1));
      }
      if (action == 'replace') {
        await manager.enqueueSource(sourceId: 'fixture', showId: 'show', showTitle: 'Fixture',
          showUrl: '/show', category: 'dub', episode: episode,
          source: const VideoSource(url: 'https://other.test/replacement.mp4', kind: AudioKind.dub,
              audioLang: 'en', container: SourceContainer.mp4), qualityLabel: '720p', nowMs: 2);
      }
      now = now.add(const Duration(seconds: 121));
      if (const ['cancel', 'delete', 'replace', 'pause-resume', 'paused-restart'].contains(action)) {
        oldTimer.fire(force: true);
        await manager.automaticRetryWorkCompleted;
        expect(catalogue.requested, isEmpty);
      }
      if (action == 'cancel') {
        expect(manager.all.single.status, DownloadStatus.canceled); return;
      }
      if (action == 'delete') { expect(manager.all, isEmpty); return; }
      if (action == 'replace') {
        expect(manager.all.single.storageKey, isNot(saved.storageKey));
        expect(native.tasks.last.url, 'https://other.test/replacement.mp4'); return;
      }
      if (action == 'pause-resume' || action == 'paused-restart') {
        expect(manager.all.single.status, DownloadStatus.paused);
        await manager.resume(manager.all.single);
      }
      timers.last.fire();
      await manager.automaticRetryWorkCompleted.timeout(const Duration(seconds: 5));
      if (action == 'extended-host') {
        expect(catalogue.requested, isEmpty);
        expect(manager.all.single.retryAt, DateTime.utc(2026, 10, 28).add(const Duration(seconds: 240)).millisecondsSinceEpoch);
        now = DateTime.utc(2026, 10, 28).add(const Duration(seconds: 241));
        timers.last.fire();
        await manager.automaticRetryWorkCompleted.timeout(const Duration(seconds: 5));
      }
      expect(native.tasks, hasLength(2));
      expect(native.tasks.last.url, 'https://fixture.test/fresh.mp4?token=new');
      expect(catalogue.requested, [episode.url]);
      expect(manager.all.single.storageKey, saved.storageKey);
      expect(manager.all.single.retryAt, isNull);
      expect(manager.all.single.serverPreference!.audioLanguage, 'en');
      expect(manager.all.single.category, 'dub');
      if (action == 'repeat') {
        final again = Completer<void>();
        void repeated() {
          if (manager.all.single.retryCount == 2 && manager.all.single.retryAt != null && !again.isCompleted) again.complete();
        }
        manager.addListener(repeated);
        native.events.add(TaskStatusUpdate(native.tasks.last, TaskStatus.failed,
            TaskHttpException('limited again', 429), null, {'retry-after': '0'}, 429));
        await again.future.timeout(const Duration(seconds: 5));
        manager.removeListener(repeated);
        expect(manager.all.single.retryAt, now.add(const Duration(seconds: 60)).millisecondsSinceEpoch);
        expect(native.tasks, hasLength(2));
        expect(catalogue.requested, hasLength(1));
      }
    }, skip: !Platform.isWindows);
  }

  test('all49 batch selections persist before resolving and restart without duplicating active job', () async {
    manager.dispose();
    final catalogue = _Catalogue();
    final episodes = [for (var n = 8; n <= 56; n++)
      Episode(id: 'ep$n', title: 'Episode$n', number: n.toDouble(), season: 1, url: 'https://fixture.test/ep$n')];
    for (final ep in episodes) {
      catalogue.streams[ep.url] = [VideoSource(url: 'https://fixture.test/${ep.id}.mp4', container: SourceContainer.mp4)];
    }
    catalogue.onSources = (_) {
      expect(Hive.box<Map>(DownloadManager.boxName).length, 49);
      expect(Hive.box<Map>(DownloadManager.boxName).values.every((m) => m['autoResumePending'] == true), isTrue);
    };
    var timers = <_RetryTimer>[];
    DesktopDownloadRetry scheduler() => DesktopDownloadRetry(timerFactory: (_, action) {
      final t = _RetryTimer(action); timers.add(t); return t;
    });
    DownloadManager create() => DownloadManager(catalogue, DownloadPrefs(), null,
        Dio(), native, null, null, null, null, scheduler())..setup();
    manager = create();
    final first = Completer<void>();
    native.onEnqueue = (_) { if (!first.isCompleted) first.complete(); };
    final batch = manager.enqueueEpisodes(sourceId: 'fixture', showId: 'show', showTitle: 'Fixture',
        showUrl: '/show', category: 'sub', quality: '720p', episodes: episodes, nowMs: 1);
    await first.future.timeout(const Duration(seconds: 5));
    final active = native.tasks.single;
    manager.dispose();
    await batch.timeout(const Duration(seconds: 5));
    expect(Hive.box<Map>(DownloadManager.boxName).length, 49);
    await Hive.box<Map>(DownloadManager.boxName).close();
    await DownloadManager.init();
    native.restored = [active];
    native.onEnqueue = null;
    timers = [];
    final before = catalogue.requested.length;
    manager = create();
    await manager.retiredCleanupCompleted.timeout(const Duration(seconds: 5));
    expect(manager.all, hasLength(49));
    final numbers = manager.all.map((r) => r.episodeNumber!.toInt()).toList()..sort();
    expect(numbers, [for (var n = 8; n <= 56; n++) n]);
    expect(timers, hasLength(48));
    expect(native.tasks, hasLength(1));
    expect(catalogue.requested, hasLength(before));
  }, skip: !Platform.isWindows);

  test('same-ID enqueue waits until Windows deletion releases old files', () async {
    await enqueue('delete-replace', SourceContainer.mp4);
    final old = manager.all.single;
    final entered = Completer<void>();
    final release = Completer<bool>();
    native.onCancel = (_) {
      if (!entered.isCompleted) entered.complete();
      return release.future;
    };
    final deletion = manager.delete(old);
    await entered.future.timeout(const Duration(seconds: 5));
    var replaced = false;
    final replacement = enqueue('delete-replace', SourceContainer.mp4).then((_) => replaced = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(replaced, isFalse);
    expect(manager.all.single.status, DownloadStatus.canceled);
    expect(native.tasks, hasLength(1));
    release.complete(true);
    await deletion.timeout(const Duration(seconds: 5));
    await replacement.timeout(const Duration(seconds: 5));
    expect(manager.all.single.storageKey, isNot(old.storageKey));
    expect(manager.all.single.status, DownloadStatus.queued);
    expect(native.tasks, hasLength(2));
    expect(Hive.box<Map>(DownloadManager.boxName).containsKey(old.id), isTrue);
  }, skip: !Platform.isWindows);

  test('stale confirmed deletion cannot remove a newer Windows generation', () async {
    await enqueue('stale-delete', SourceContainer.mp4);
    final old = manager.all.single;
    await manager.cancel(old);
    await enqueue('stale-delete', SourceContainer.mp4);
    final fresh = manager.all.single;
    expect(fresh.storageKey, isNot(old.storageKey));
    await manager.deleteAll([old]);
    expect(manager.all.single.storageKey, fresh.storageKey);
    expect(manager.all.single.status, DownloadStatus.queued);
    expect(Hive.box<Map>(DownloadManager.boxName).containsKey(fresh.id), isTrue);
  }, skip: !Platform.isWindows);

  test('direct and batch video enqueue persist episode artwork', () async {
    await manager.enqueueSource(sourceId: 'fixture', showId: 'show', showTitle: 'Fixture',
      cover: 'https://fixture.test/cover', coverHeaders: const {'Referer': 'https://fixture.test'},
      showUrl: '/show', category: 'sub', episode: const Episode(id: 'art', title: 'Episode',
        url: '/art', thumbnail: 'https://fixture.test/episode'),
      source: const VideoSource(url: 'https://fixture.test/art.mp4', container: SourceContainer.mp4),
      qualityLabel: 'best', nowMs: 1);
    expect(manager.all.single.episodeThumbnail, 'https://fixture.test/episode');
    final direct = manager.all.single;
    expect(DownloadRecord.fromMap(Hive.box<Map>(DownloadManager.boxName).get(direct.id)!).episodeThumbnail,
      'https://fixture.test/episode');
    await manager.cancel(direct);
    await manager.enqueueEpisodes(sourceId: 'fixture', showId: 'show', showTitle: 'Fixture',
      showUrl: '/show', category: 'sub', quality: 'best', nowMs: 2,
      episodes: const [Episode(id: 'batch-art', title: 'Episode', url: '/batch-art',
        thumbnail: 'https://fixture.test/batch-episode')]);
    expect(manager.all.singleWhere((r) => r.episodeId == 'batch-art').episodeThumbnail,
      'https://fixture.test/batch-episode');
  }, skip: !Platform.isWindows);

  test('startup restores app-named local files from legacy root and persists across restart', () async {
    manager.dispose();
    final previous = DesktopStorage.previousRoot;
    final legacy = Directory('${root.path}/older');
    final dir = Directory('${legacy.path}/Videos/The_Four_of_Us');
    await dir.create(recursive: true);
    const name = 'The_Four_of_Us_S1E10_best_30251cdca76184b5769de3203112c7d2.ts';
    final file = File('${dir.path}/$name');
    await file.writeAsBytes([1, 2, 3]);
    await DownloadPrefs().setLocation('${root.path}/newer', '${root.path}/newer');
    DesktopStorage.previousRoot = legacy.path;
    var probes = 0;
    final recovery = DesktopDownloadRecovery(probe: (_) async { probes++; return true; });
    try {
      manager = DownloadManager(_Catalogue(), DownloadPrefs(), null, Dio(), native,
          null, null, null, recovery)..setup();
      await manager.retiredCleanupCompleted.timeout(const Duration(seconds: 5));
      expect(manager.all, hasLength(1));
      final record = manager.all.single;
      expect(record.recoveredFromDisk, isTrue);
      expect(record.sourceId, 'local-files');
      expect(record.category, 'unknown');
      expect(record.episodeNumber, 10);
      expect(record.status, DownloadStatus.done);
      expect(await manager.filePresent(record), isTrue);
      await Future.wait([manager.recoverLocalFiles(), manager.recoverLocalFiles()]);
      expect(manager.all, hasLength(1));
      expect(probes, 1);
      manager.dispose();
      await Hive.box<Map>(DownloadManager.boxName).close();
      await DownloadManager.init();
      manager = DownloadManager(_Catalogue(), DownloadPrefs(), null, Dio(), native,
          null, null, null, recovery)..setup();
      await manager.retiredCleanupCompleted.timeout(const Duration(seconds: 5));
      expect(manager.all.single.id, record.id);
      expect(manager.all.single.recoveredFromDisk, isTrue);
      expect(probes, 1);
      expect(await file.readAsBytes(), [1, 2, 3]);
    } finally { DesktopStorage.previousRoot = previous; }
  }, skip: !Platform.isWindows);

  test('completed same cut skips, opposite cut remains independently downloadable', () async {
    manager.dispose();
    final file = File('${root.path}/existing.mp4');
    await file.writeAsBytes([1, 2, 3]);
    final record = DownloadRecord.fromMap({
      'id': 'fixture_show_existing', 'sourceId': 'fixture', 'showId': 'show',
      'showTitle': 'Fixture', 'episodeId': 'existing', 'episodeUrl': '/existing',
      'category': 'sub', 'status': 'done', 'filePath': file.path,
      'episodeNumber': 12, 'season': 1,
    });
    await Hive.box<Map>(DownloadManager.boxName).put(record.id, record.toMap());
    manager = DownloadManager(_Catalogue(), DownloadPrefs(), null, Dio(), native)..setup();
    await manager.retiredCleanupCompleted.timeout(const Duration(seconds: 5));
    const episode = Episode(id: 'existing', title: 'Episode 12', url: '/existing', number: 12, season: 1);
    await manager.enqueueEpisodes(sourceId: 'fixture', showId: 'show', showTitle: 'Fixture',
      showUrl: '/show', category: 'sub', quality: 'best', episodes: [episode], nowMs: 2);
    expect(manager.all, hasLength(1));
    expect(manager.all.single.status, DownloadStatus.done);
    expect(native.tasks, isEmpty);
    expect(await manager.finishedForEpisode(sourceId: 'fixture', showId: 'show',
      episodeId: 'existing', category: 'dub', season: 1), isNull);
    expect(await manager.finishedForEpisode(sourceId: 'fixture', showId: 'show',
      episodeId: 'existing', category: 'sub', season: 2), isNull);
    await manager.enqueueEpisodes(sourceId: 'fixture', showId: 'show', showTitle: 'Fixture',
      showUrl: '/show', category: 'dub', quality: 'best', episodes: [episode], nowMs: 3);
    expect(manager.all, hasLength(2));
    expect(manager.recordFor('fixture', 'show', 'existing', category: 'sub')!.id, record.id);
    expect(manager.recordFor('fixture', 'show', 'existing', category: 'dub')!.id, isNot(record.id));
    expect(await file.readAsBytes(), [1, 2, 3]);
  }, skip: !Platform.isWindows);

  test('disk reconciliation cannot overwrite cancellation during a file check', () async {
    manager.dispose();
    final record = DownloadRecord.fromMap({
      'id': 'stale-disk-check', 'status': 'done',
      'filePath': 'content://fixture/saved', 'bytesTotal': 3,
    });
    await Hive.box<Map>(DownloadManager.boxName).put(record.id, record.toMap());
    manager = DownloadManager(_Catalogue(), DownloadPrefs(), null, Dio(), native)..setup();
    await manager.retiredCleanupCompleted.timeout(const Duration(seconds: 5));
    final checking = Completer<void>();
    final release = Completer<bool>();
    const channel = MethodChannel('com.spyou.watch_app/device');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'documentExists') {
        if (!checking.isCompleted) checking.complete();
        return release.future;
      }
      return null;
    });
    try {
      final scan = manager.pruneMissing();
      await checking.future.timeout(const Duration(seconds: 5));
      await manager.cancel(manager.all.single);
      release.complete(false);
      await scan.timeout(const Duration(seconds: 5));
      expect(manager.all.single.status, DownloadStatus.canceled);
      expect(Hive.box<Map>(DownloadManager.boxName).get(record.id)!['status'], 'canceled');
    } finally {
      if (!release.isCompleted) release.complete(true);
      messenger.setMockMethodCallHandler(channel, null);
    }
  }, skip: !Platform.isWindows);

  test('missing Windows files retain index and recover when the same path returns', () async {
    manager.dispose();
    final file = File('${root.path}/saved.ts');
    await file.writeAsBytes([1, 2, 3]);
    final record = DownloadRecord.fromMap({
      'id': 'missing-preserved', 'showTitle': 'Fixture', 'sourceId': 'fixture',
      'status': 'done', 'filePath': file.path, 'bytesTotal': 3,
      'episodeNumber': 10, 'season': 1,
    });
    await Hive.box<Map>(DownloadManager.boxName).put(record.id, record.toMap());
    manager = DownloadManager(_Catalogue(), DownloadPrefs(), null, Dio(), native)..setup();
    await manager.retiredCleanupCompleted.timeout(const Duration(seconds: 5));
    await file.delete();
    await manager.pruneMissing();
    expect(manager.all.single.id, record.id);
    expect(manager.all.single.status, DownloadStatus.failed);
    expect(manager.all.single.filePath, record.filePath);
    expect(manager.all.single.error, missingSavedDownloadMessage);
    expect(Hive.box<Map>(DownloadManager.boxName).containsKey(record.id), isTrue);
    await file.writeAsBytes([1, 2, 3, 4]);
    await manager.pruneMissing();
    expect(manager.all.single.status, DownloadStatus.done);
    expect(manager.all.single.bytesTotal, 4);
    expect(manager.all.single.error, isNull);
  }, skip: !Platform.isWindows);

  test('retired local recovery cannot publish after manager disposal', () async {
    manager.dispose();
    final dir = Directory('${root.path}/Videos/The_Four_of_Us');
    await dir.create(recursive: true);
    final file = File('${dir.path}/The_Four_of_Us_S1E10_best_30251cdca76184b5769de3203112c7d2.ts');
    await file.writeAsBytes([1]);
    final started = Completer<void>();
    final release = Completer<void>();
    final recovery = DesktopDownloadRecovery(probe: (_) async {
      if (!started.isCompleted) started.complete();
      await release.future;
      return true;
    });
    manager = DownloadManager(_Catalogue(), DownloadPrefs(), null, Dio(), native,
        null, null, null, recovery)..setup();
    await started.future.timeout(const Duration(seconds: 5));
    final retired = manager;
    retired.dispose();
    manager = DownloadManager(_Catalogue(), DownloadPrefs(), null, Dio(), native,
        null, null, null, DesktopDownloadRecovery(probe: (_) async => false))..setup();
    release.complete();
    await retired.retiredCleanupCompleted.timeout(const Duration(seconds: 5));
    await manager.retiredCleanupCompleted.timeout(const Duration(seconds: 5));
    expect(Hive.box<Map>(DownloadManager.boxName).isEmpty, isTrue);
    expect(manager.all, isEmpty);
    expect(await file.readAsBytes(), [1]);
  }, skip: !Platform.isWindows);

  for (final action in ['cancel', 'recreate', 'recreate-cancel', 'recreate-delete', 'recreate-twice', 'dispose-delete']) {
    test('retired HLS429 cannot publish after $action', () async {
      manager.dispose();
      final host = _RateLimitedPlaylist();
      manager = DownloadManager(_Catalogue(), DownloadPrefs(), null,
          Dio()..httpClientAdapter = host, native)..setup();
      await enqueue('retired-hls', SourceContainer.hls, host: 'old.test');
      await host.started.future.timeout(const Duration(seconds: 5));
      final retired = manager;
      final original = manager.all.single;
      if (action == 'dispose-delete') {
        retired.dispose();
        manager = DownloadManager(_Catalogue(), DownloadPrefs(), null,
            Dio()..httpClientAdapter = playlist, native)..setup();
        await manager.delete(manager.all.single);
      } else {
        await manager.cancel(original);
        if (action.startsWith('recreate')) {
          await enqueue('retired-hls', SourceContainer.mp4, host: 'new.test');
          if (action == 'recreate-cancel' || action == 'recreate-twice') {
            await manager.cancel(manager.all.single);
          }
          if (action == 'recreate-twice') {
            await enqueue('retired-hls', SourceContainer.mp4, host: 'new.test');
          }
          if (action == 'recreate-delete') await manager.delete(manager.all.single);
        }
      }
      final replacement = manager.all.isEmpty ? null : manager.all.single;
      host.release.complete();
      await retired.foregroundHlsWorkCompleted.timeout(const Duration(seconds: 5));
      await retired.subtitleWorkCompleted.timeout(const Duration(seconds: 5));
      final saved = Hive.box<Map>(DownloadManager.boxName).get(original.id);
      if (action.endsWith('delete')) {
        expect(saved, isNull);
        expect(manager.all, isEmpty);
      } else {
        expect(manager.all.single.storageKey, replacement!.storageKey);
        expect(manager.all.single.status, replacement.status);
        expect(saved!['storageKey'], replacement.storageKey);
        expect(saved['status'], replacement.status.name);
        if (action == 'recreate' || action == 'recreate-twice') {
          expect(replacement.storageKey, isNot(original.storageKey));
          expect(native.tasks, hasLength(1));
          expect(Uri.parse(native.tasks.single.url).host, 'new.test');
        } else {
          expect(native.tasks, isEmpty);
        }
      }
    }, skip: !Platform.isWindows);
  }

  for (final accepts429 in [false, true]) {
    test('subtitle429 is optional, retained and never saved; accepts=$accepts429', () async {
      manager.dispose();
      await DownloadPrefs().setParallelDownloads(2);
      final host = _LimitedSubtitleHost();
      final client = Dio()..httpClientAdapter = host;
      if (accepts429) client.options.validateStatus = (_) => true;
      manager = DownloadManager(_Catalogue(), DownloadPrefs(), null, client, native)..setup();
      Future<void> withSubtitles(String id) => manager.enqueueSource(
        sourceId: 'fixture', showId: 'show', showTitle: 'Fixture',
        showUrl: '/show', category: 'sub',
        episode: Episode(id: id, title: id, url: '/$id'),
        source: VideoSource(url: 'https://video.test/$id.mp4', container: SourceContainer.mp4,
          headers: const {'Referer': 'fixture'},
          subtitles: [Subtitle(url: 'https://subtitles.test/$id.vtt?token=private', lang: 'en')]),
        qualityLabel: 'best', nowMs: 1,
      );
      await withSubtitles('first-sidecar');
      await manager.subtitleWorkCompleted.timeout(const Duration(seconds: 5));
      expect(host.requested, hasLength(1));
      expect(host.requested.single.headers['Referer'], 'fixture');
      expect(DownloadPrefs().hostCooldownUntil(Uri.parse('https://subtitles.test/')), isNotNull);
      expect(DownloadPrefs().hostCooldownUntil(Uri.parse('https://video.test/')), isNull);
      await withSubtitles('second-sidecar');
      await manager.subtitleWorkCompleted.timeout(const Duration(seconds: 5));
      expect(host.requested, hasLength(1));
      expect(native.tasks, hasLength(2));
      expect(manager.all.every((r) => r.subtitles.isEmpty), isTrue);
      final folder = Directory('${root.path}/Videos/Fixture/Subtitles');
      expect(await folder.list().where((f) => f.path.endsWith('.vtt')).isEmpty, isTrue);
      client.close(force: true);
    }, skip: !Platform.isWindows);
  }

  for (final method in ['HEAD', 'GET']) {
    test('native enqueue stops after $method probe429', () async {
      manager.dispose();
      await DownloadPrefs().setConnectionsPerDownload(8);
      final host = _LimitedRangeHost(method);
      manager = DownloadManager(_Catalogue(), DownloadPrefs(), null,
          Dio()..httpClientAdapter = host, native)..setup();
      await enqueue('probe429', SourceContainer.mp4);
      expect(native.tasks, isEmpty);
      expect(host.requested, hasLength(method == 'HEAD' ? 1 : 2));
      expect(manager.all.single.status, DownloadStatus.queued);
      expect(manager.all.single.error, contains('(429)'));
      expect(manager.all.single.error, isNot(contains('private')));
      expect(DownloadPrefs().hostCooldownUntil(Uri.parse('https://fixture.test/')), isNotNull);
      final count = host.requested.length;
      await enqueue('after-probe429', SourceContainer.mp4);
      expect(host.requested, hasLength(count));
      expect(native.tasks, isEmpty);
    }, skip: !Platform.isWindows);
  }

  test('HLS429 persists before FIFO release and avoids alternate mirrors', () async {
    manager.dispose();
    final host = _RateLimitedPlaylist();
    manager = DownloadManager(_Catalogue(), DownloadPrefs(), null,
        Dio()..httpClientAdapter = host, native)..setup();
    await manager.enqueueSource(
      sourceId: 'fixture', showId: 'show', showTitle: 'Fixture',
      showUrl: 'https://fixture.test/show', category: 'sub',
      episode: const Episode(id: 'hls-limited', title: 'HLS', url: 'https://fixture.test/episode'),
      source: const VideoSource(url: 'https://fixture.test/master.m3u8', container: SourceContainer.hls),
      fallbacks: const [VideoSource(url: 'https://other.test/fallback.m3u8', container: SourceContainer.hls)],
      qualityLabel: 'best', nowMs: 1,
    );
    await host.started.future.timeout(const Duration(seconds: 5));
    final waiting = enqueue('after-hls429', SourceContainer.mp4);
    await waitForRecord('after-hls429');
    host.release.complete();
    await waiting.timeout(const Duration(seconds: 5));
    final limited = manager.all.firstWhere((r) => r.episodeId == 'hls-limited');
    expect(limited.status, DownloadStatus.queued);
    expect(limited.error, contains('(429)'));
    expect(limited.error, isNot(contains('<html>')));
    expect(host.requested.every((r) => r.uri.host == 'fixture.test'), isTrue);
    expect(DownloadPrefs().hostCooldownUntil(Uri.parse('https://fixture.test/')), isNotNull);
    expect(native.tasks, isEmpty);
    expect(manager.all.firstWhere((r) => r.episodeId == 'after-hls429').error, contains('Waiting to retry'));
  }, skip: !Platform.isWindows);

  test('waiting native job respects429 before reusing the released slot', () async {
    await enqueue('first', SourceContainer.mp4);
    final waiting = enqueue('waiting', SourceContainer.mp4);
    await waitForRecord('waiting');
    native.events.add(TaskStatusUpdate(native.tasks.single, TaskStatus.failed,
        TaskHttpException('Too Many Requests', 429), null, {'retry-after': '120'}, 429));
    await waiting.timeout(const Duration(seconds: 5));
    expect(native.tasks, hasLength(1));
    final blocked = manager.all.firstWhere((r) => r.episodeId == 'waiting');
    expect(blocked.status, DownloadStatus.queued);
    expect(blocked.error, contains('Waiting to retry'));
    await enqueue('other-host', SourceContainer.mp4, host: 'other.test');
    expect(native.tasks, hasLength(2));
  }, skip: !Platform.isWindows);

  test(
    'batch resolves each episode fresh and retains selected server',
    () async {
      manager.dispose();
      await DownloadPrefs().setParallelDownloads(2);
      final catalogue = _Catalogue();
      const episode1 = Episode(
        id: 'ep1',
        title: 'Episode1',
        url: 'https://fixture.test/ep1',
      );
      const episode2 = Episode(
        id: 'ep2',
        title: 'Episode2',
        url: 'https://fixture.test/ep2',
      );
      catalogue.streams[episode1.url] = const [
        VideoSource(
          url: 'https://a.test/ep1.mp4',
          label: 'A',
          quality: '1080p',
        ),
        VideoSource(
          url: 'https://b.test/ep1.mp4?fresh=1',
          label: 'B',
          quality: '720p',
          headers: {'Referer': 'https://fixture.test/ep1'},
        ),
      ];
      catalogue.streams[episode2.url] = const [
        VideoSource(
          url: 'https://new-b.test/ep2.mp4?fresh=2',
          label: 'B',
          quality: '720p',
          headers: {'Referer': 'https://fixture.test/ep2'},
        ),
        VideoSource(
          url: 'https://a.test/ep2.mp4',
          label: 'A',
          quality: '1080p',
        ),
      ];
      manager = DownloadManager(catalogue, DownloadPrefs(), null, Dio(), native)
        ..setup();
      await manager
          .enqueueEpisodes(
            sourceId: 'source',
            showId: 'show',
            showTitle: 'Fixture',
            showUrl: 'https://fixture.test/show',
            category: 'sub',
            quality: '720p',
            episodes: const [episode1, episode2],
            nowMs: 1,
            serverPreference: DownloadServerPreference.fromSource(
              const VideoSource(
                url: 'https://b.test/preview?token=obsolete',
                label: 'B',
              ),
            ),
          )
          .timeout(const Duration(seconds: 5));
      expect(catalogue.requested, [episode1.url, episode2.url]);
      expect(native.tasks.map((t) => t.url), [
        'https://b.test/ep1.mp4?fresh=1',
        'https://new-b.test/ep2.mp4?fresh=2',
      ]);
      expect(native.tasks.map((t) => t.headers['Referer']), [
        episode1.url,
        episode2.url,
      ]);
      expect(native.tasks.map((t) => t.taskId).toSet(), hasLength(2));
      for (final record in manager.all) {
        final saved = DownloadRecord.fromMap(
          Hive.box<Map>(DownloadManager.boxName).get(record.id)!,
        );
        expect(saved.serverPreference!.label, 'B');
        expect(
          saved.serverPreference!.toMap().toString(),
          isNot(contains('obsolete')),
        );
      }
    },
    skip: !Platform.isWindows,
  );

  test(
    'batch manager explicitly resolves persisted dub and queues only dub',
    () async {
      manager.dispose();
      final catalogue = _MetadataCatalogue();
      manager = DownloadManager(catalogue, DownloadPrefs(), null, Dio(), native)
        ..setup();
      await manager
          .enqueueEpisodes(
            sourceId: 'zm',
            showId: 'show',
            showTitle: 'Fixture',
            showUrl: 'zm://anime/mal:1',
            category: 'dub',
            quality: 'best',
            episodes: const [
              Episode(id: '1', title: 'Episode1', url: 'zm://anime/mal:1/ep/1'),
            ],
            nowMs: 1,
          )
          .timeout(const Duration(seconds: 5));
      expect(catalogue.requestedCut, 'dub');
      expect(native.tasks.single.url, 'https://fixture.test/dub.mp4');
      expect(manager.all.single.category, 'dub');
    },
    skip: !Platform.isWindows,
  );

  test(
    'direct dub selection rejects a known sub-only source before enqueue',
    () async {
      await manager.enqueueSource(
        sourceId: 'source',
        showId: 'show',
        showTitle: 'Fixture',
        showUrl: 'https://fixture.test/show',
        category: 'dub',
        episode: const Episode(
          id: '1',
          title: 'Episode1',
          url: 'https://fixture.test/ep1',
        ),
        source: const VideoSource(
          url: 'https://fixture.test/sub.mp4',
          kind: AudioKind.sub,
        ),
        qualityLabel: 'best',
        nowMs: 1,
      );
      expect(native.tasks, isEmpty);
      expect(manager.all.single.status, DownloadStatus.unsupported);
      expect(manager.all.single.error, contains('dub'));
    },
    skip: !Platform.isWindows,
  );

  test(
    'English batch choice outranks server affinity and higher Japanese quality',
    () async {
      manager.dispose();
      final catalogue = _Catalogue();
      catalogue.streams['https://fixture.test/ep1'] = const [
        VideoSource(
          url: 'https://b.test/jp.mp4',
          label: 'B',
          audioLang: 'ja',
          kind: AudioKind.dub,
          quality: '1080p',
        ),
        VideoSource(
          url: 'https://c.test/en.mp4',
          label: 'C',
          audioLang: 'eng',
          kind: AudioKind.dub,
          quality: '720p',
        ),
      ];
      manager = DownloadManager(catalogue, DownloadPrefs(), null, Dio(), native)
        ..setup();
      await manager.enqueueEpisodes(
        sourceId: 'source',
        showId: 'show',
        showTitle: 'Fixture',
        showUrl: 'https://fixture.test/show',
        category: 'dub',
        quality: 'best',
        episodes: const [
          Episode(id: '1', title: 'Episode1', url: 'https://fixture.test/ep1'),
        ],
        serverPreference: const DownloadServerPreference(
          label: 'B',
          host: 'b.test',
          audioLanguage: 'en',
        ),
        nowMs: 1,
      );
      expect(native.tasks.single.url, 'https://c.test/en.mp4');
      expect(manager.all.single.serverPreference!.audioLanguage, 'en');
    },
    skip: !Platform.isWindows,
  );

  test('failed English stream does not retry Japanese mirror', () async {
    await manager.enqueueSource(
      sourceId: 'source',
      showId: 'show',
      showTitle: 'Fixture',
      showUrl: 'https://fixture.test/show',
      category: 'dub',
      episode: const Episode(
        id: '1',
        title: 'Episode1',
        url: 'https://fixture.test/ep1',
      ),
      source: const VideoSource(
        url: 'https://fixture.test/en.mp4',
        audioLang: 'en',
        kind: AudioKind.dub,
      ),
      fallbacks: const [
        VideoSource(
          url: 'https://fixture.test/jp.mp4',
          audioLang: 'ja',
          kind: AudioKind.dub,
        ),
      ],
      qualityLabel: 'best',
      nowMs: 1,
    );
    final failed = Completer<void>();
    manager.addListener(() {
      if (manager.all.single.status == DownloadStatus.failed &&
          !failed.isCompleted)
        failed.complete();
    });
    native.events.add(TaskStatusUpdate(native.tasks.single, TaskStatus.failed));
    await failed.future.timeout(const Duration(seconds: 5));
    expect(native.tasks, hasLength(1));
    expect(manager.all.single.serverPreference!.audioLanguage, 'en');
  }, skip: !Platform.isWindows);

  test('native transfer holds the shared slot before HLS starts', () async {
    await enqueue('file', SourceContainer.mp4);
    expect(native.tasks, hasLength(1));
    final queued = enqueue('playlist', SourceContainer.hls);
    await waitForRecord('playlist');
    await Future<void>.delayed(Duration.zero);
    expect(playlist.started.isCompleted, isFalse);
    native.events.add(TaskStatusUpdate(native.tasks.single, TaskStatus.paused));
    await queued;
    await playlist.started.future.timeout(const Duration(seconds: 5));
    final finished = Completer<void>();
    manager.addListener(() {
      if (manager.all.any(
            (r) => r.episodeId == 'playlist' && r.error != null,
          ) &&
          !finished.isCompleted) {
        finished.complete();
      }
    });
    playlist.finish.complete();
    await finished.future.timeout(const Duration(seconds: 5));
  }, skip: !Platform.isWindows);

  test(
    'HLS holds native file until its failed transfer releases capacity',
    () async {
      await enqueue('playlist', SourceContainer.hls);
      await playlist.started.future.timeout(const Duration(seconds: 5));
      final queued = enqueue('file', SourceContainer.mp4);
      await waitForRecord('file');
      await Future<void>.delayed(Duration.zero);
      expect(native.tasks, isEmpty);
      playlist.finish.complete();
      await queued.timeout(const Duration(seconds: 5));
      expect(native.tasks, hasLength(1));
    },
    skip: !Platform.isWindows,
  );

  test(
    'raising the limit admits a native job while HLS remains active',
    () async {
      await enqueue('playlist', SourceContainer.hls);
      await playlist.started.future.timeout(const Duration(seconds: 5));
      final queued = enqueue('file', SourceContainer.mp4);
      await waitForRecord('file');
      await Future<void>.delayed(Duration.zero);
      expect(native.tasks, isEmpty);
      manager.setParallel(2);
      await queued.timeout(const Duration(seconds: 5));
      expect(native.tasks, hasLength(1));
      expect(playlist.finish.isCompleted, isFalse);
      final finished = Completer<void>();
      manager.addListener(() {
        if (manager.all.any(
              (r) => r.episodeId == 'playlist' && r.error != null,
            ) &&
            !finished.isCompleted) {
          finished.complete();
        }
      });
      playlist.finish.complete();
      await finished.future.timeout(const Duration(seconds: 5));
    },
    skip: !Platform.isWindows,
  );
}
