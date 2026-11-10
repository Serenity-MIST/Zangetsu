import 'desktop_download_thumbnails.dart';
import '../platform/app_paths.dart';
import 'desktop_download_retry.dart';
import 'desktop_download_recovery.dart';
import '../desktop/desktop_storage.dart';
import 'download_failure.dart';
import 'package:crypto/crypto.dart';
import 'dart:math';
import 'package:path/path.dart' as p;
import 'file_audio_transaction.dart';
import 'desktop_file_audio.dart';
import 'desktop_audio_mux.dart';
import 'download_server_preference.dart';
import 'transfer_slots.dart';
import 'direct_file_connections.dart';
import 'subtitle_selection.dart';
import '../playback/playback_prefs.dart';
import 'dart:async';
import 'package:watch_app/core/hive/safe_box.dart';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../logging/app_logger.dart';
import '../models/episode.dart';
import '../models/video_source.dart';
import '../platform/apple_tv.dart';
import '../repository/catalogue_repository.dart';
import '../torrent/torrent_download_service.dart';
import '../torrent/torrent_prefs.dart';
import '../zmode/metadata_repository.dart';
import '../zmode/zmode_ids.dart';
import 'download_prefs.dart';
import 'hls_downloader.dart';
import 'hls_download_journal.dart';
import 'download_record.dart';
import 'download_service.dart';
import 'external_subtitle_export.dart';
import 'video_destination.dart';

/// Owns offline downloads. Direct-file (MP4/MKV) sources go through
/// background_downloader (true background); HLS (m3u8) sources go through the
/// in-app [HlsDownloader] (segment fetch + decrypt + concat, foreground). Both
/// finish in the public Downloads folder. Records persist in the Hive
/// `downloads` box so the library survives restarts. A [ChangeNotifier] so the
/// UI can rebuild live. See docs/downloads-feature.md.
class DownloadManager extends ChangeNotifier {
  /// Optional transports support isolated offline integration checks; normal
  /// callers use the shared native downloader and standard HTTP timeouts.
  DownloadManager(
    this._repo, [
    DownloadPrefs? downloadPrefs,
    TorrentDownloadService? torrentSvc,
    Dio? downloadClient,
    FileDownloader? fileDownloader,
    DesktopFileAudio? fileAudio,
    Future<void> Function(DownloadRecord)? writeAudioCheckpoint,
    Future<void> Function(DownloadRecord)? writeCompletedRecord,
    DesktopDownloadRecovery? localRecovery,
    DesktopDownloadRetry? retryScheduler,
  ]) : _downloadPrefs = downloadPrefs ?? DownloadPrefs(),
       _torrentSvc = torrentSvc ?? TorrentDownloadService(),
       _dl = fileDownloader,
       _fileAudio = fileAudio ?? DesktopFileAudio(),
       _writeAudioCheckpoint = writeAudioCheckpoint,
       _writeCompletedRecord = writeCompletedRecord,
       _localRecovery = localRecovery ?? DesktopDownloadRecovery(),
       _retryScheduler = retryScheduler ?? DesktopDownloadRetry(),
       _dio =
           downloadClient ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 20),
               receiveTimeout: const Duration(seconds: 30),
             ),
           );

  /// The ROUTER, not the source repository.
  ///
  /// It dispatches on the url, so a `zm://` episode reaches the metadata
  /// catalogue, which resolves the matched source itself. Asking
  /// [SourceRepository] directly threw `Provider not loaded: zm` for every
  /// metadata title — caught below and shown as "Resolve failed", so no Z Mode
  /// title could be downloaded at all. Same mistake [SubscriptionChecker] had.
  final CatalogueRepository _repo;
  final DownloadPrefs _downloadPrefs;
  final DesktopDownloadRecovery _localRecovery;
  final DesktopDownloadRetry _retryScheduler;
  Future<void> _automaticRetryWork = Future.value();
  final Map<String, String> _restoredPendingRetries = {};
  Future<void>? _localRecoveryWork;
  final DesktopFileAudio _fileAudio;
  final Future<void> Function(DownloadRecord)? _writeAudioCheckpoint;
  final Future<void> Function(DownloadRecord)? _writeCompletedRecord;
  final Set<String> _finalizingFiles = {};
  final Set<Future<void>> _subtitleWork = {};
  final Set<Future<void>> _foregroundHlsWork = {};
  final Map<String, ({String storageKey, Future<void> done})> _foregroundHlsAttempts = {};
  final Map<String, String> _deferredHlsReplacements = {};
  final Map<String, Completer<void>> _finalizationDone = {};
  // A new attempt must not reuse an ID while deletion still owns its files.
  final Map<String, Completer<void>> _deletionDone = {};
  final Set<String> _pendingAudioResumes = {};
  final TorrentDownloadService _torrentSvc;

  /// Latest torrent-download progress per id (peers/speed for the UI), kept
  /// out of [DownloadRecord] so it isn't persisted every tick.
  final Map<String, TorrentDownloadProgress> torrentProgress = {};

  static const String boxName = 'downloads';
  static const String _sharedDir = 'Zangetsu';

  /// Never replace an explicitly requested cut with a known different cut.
  /// Fully unlabelled lists may contain multi-audio files; keep those intact,
  /// without treating this cut filter as proof of a file's audio language.
  static List<VideoSource> sourcesForDownloadCategory(
    List<VideoSource> sources,
    String category,
  ) {
    final wanted = switch (category) {
      'sub' => AudioKind.sub,
      'dub' => AudioKind.dub,
      _ => AudioKind.unknown,
    };
    if (wanted == AudioKind.unknown) return sources;

    final hasKnownCut = sources.any(
      (source) => source.kind != AudioKind.unknown,
    );
    if (!hasKnownCut) return sources;

    return sources.where((source) => source.kind == wanted).toList();
  }

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await openBoxSafely<Map>(boxName);
    }
  }

  Box<Map> get _box => Hive.box<Map>(boxName);
  FileDownloader? _dl;
  FileDownloader get _fileDownloader => _dl ??= FileDownloader();
  // Throttles direct-file (MP4) downloads to the "Parallel downloads" setting.
  // background_downloader runs enqueued tasks concurrently, so without this the
  // limit was silently HLS-only. The queue holds extras until a slot frees.
  final MemoryTaskQueue _mp4Queue = MemoryTaskQueue();
  TransferSlots? _desktopTransferSlots;
  TransferSlots get _desktopSlots =>
      _desktopTransferSlots ??= TransferSlots(_downloadPrefs.parallelDownloads);

  // Small HTTP client for fetching subtitle sidecar files (they're tiny, so a
  // direct GET in the UI isolate beats threading them through the downloaders).
  final Dio _dio;

  /// In-memory cache of records, keyed by id (mirrors the Hive box).
  final Map<String, DownloadRecord> _records = {};
  final Set<String> _publishingExternalSubtitles = {};
  // Live DownloadTask objects for in-session control (pause/resume/move).
  final Map<String, DownloadTask> _tasks = {};
  final Set<String> _singleConnectionIds = {};
  // Remaining fallback mirrors per record (CloudStream-style try-next): when a
  // download fails or saves a web page, we advance to the next candidate.
  final Map<String, List<VideoSource>> _candidates = {};
  StreamSubscription<TaskUpdate>? _sub;
  Future<void>? _desktopRecovery;
  Future<void> _retiredCleanup = Future.value();
  Object? _desktopRecoveryError;
  bool _disposed = false;

  /// Wire notifications + the update streams. Call once at app start.
  void setup() {
    for (final raw in _box.values) {
      final r = DownloadRecord.fromMap(raw);
      _records[r.id] = r;
      if (r.autoResumePending && r.status != DownloadStatus.paused) {
        _restoredPendingRetries[r.id] = r.storageKey;
      }
    }
    // background_downloader persists to Application Support, which tvOS cannot
    // create — constructing FileDownloader there logs errors and can stall boot.
    if (isAppleTv) {
      _listenTorrentDownloads();
      return;
    }
    final dl = _fileDownloader;
    dl.configureNotification(
      running: const TaskNotification('Downloading', '{filename}'),
      complete: const TaskNotification('Downloaded', '{filename}'),
      error: const TaskNotification('Download failed', '{filename}'),
      progressBar: true,
    );
    _sub = dl.updates.listen(_onUpdate);
    if (Platform.isWindows) {
      _desktopRecovery = _recoverDesktopTransfers();
      _retiredCleanup = _desktopRecovery!.then((_) async {
        if (_desktopRecoveryError == null) {
          await _cleanupRetiredCompletedFiles();
          await recoverLocalFiles();
          // Only boot-restored intent is rearmed here. Jobs accepted while
          // startup cleanup runs already belong to their original batch loop.
          for (final entry in _restoredPendingRetries.entries.toList()) {
            final record = _records[entry.key];
            if (record != null && record.storageKey == entry.value) {
              _armPendingRetry(record);
            }
          }
          _restoredPendingRetries.clear();
        }
      });
      unawaited(_retiredCleanup);
    }
    // Route MP4 downloads through the concurrency-limited queue.
    _mp4Queue.maxConcurrent = _downloadPrefs.parallelDownloads;
    dl.addTaskQueue(_mp4Queue);
    // A task the queue couldn't enqueue at all (rare) → same fallback as a
    // failed start: try the next mirror, else mark failed.
    _mp4Queue.enqueueErrors.listen((task) async {
      if (Platform.isWindows) _desktopSlots.release(task.taskId);
      final rec = _records[task.taskId];
      if (rec == null || rec.status == DownloadStatus.canceled) return;
      AppLogger.instance.log(
        "[download] MP4 couldn't enqueue — ${rec.showTitle} · "
        '${rec.episodeTitle} [${rec.quality}]',
        level: 'E',
      );
      if (await _tryNext(rec)) return;
      _put(
        rec.copyWith(
          status: DownloadStatus.failed,
          error: () => "Couldn't start download",
        ),
      );
      notifyListeners();
    });
    _listenBackgroundService();
    _listenTorrentDownloads();
    unawaited(_publishPreviouslyDownloadedSubtitles());
    unawaited(_recoverBackgroundHlsJobs());
  }

  /// Desktop workers live in this process. Reconcile their real inventory
  /// before admitting new work; saved labels alone are not running transfers.
  Future<void> _recoverDesktopTransfers() async {
    try {
      final tasks = await _fileDownloader.allTasks(allGroups: true);
      if (_disposed) return;
      final byId = {for (final task in tasks) task.taskId: task};
      for (final rec in _records.values.toList()) {
        if (_disposed) return;
        if (rec.isTorrent) continue;
        final task = byId[rec.id];
        if (task is DownloadTask) _tasks[rec.id] = task;
        final interrupted = const {
          DownloadStatus.queued,
          DownloadStatus.resolving,
          DownloadStatus.downloading,
          DownloadStatus.finalizing,
        }.contains(rec.status);
        if (!interrupted) continue;
        if (rec.status == DownloadStatus.finalizing && rec.filePath != null) {
          final recovery = await FileAudioTransaction.recover(rec.filePath!);
          if (_disposed) return;
          if (recovery != null) {
            await _storeRestoredState(
              rec.copyWith(
                status: DownloadStatus.failed,
                error: () => recovery,
              ),
            );
            continue;
          }
        }
        if (rec.autoResumePending && rec.retryAt != null && rec.status == DownloadStatus.queued) {
          _tasks.remove(rec.id);
          if (task != null) await _fileDownloader.cancelTaskWithId(rec.id);
          continue;
        }
        if (task != null) {
          _desktopSlots.adopt(rec.id);
        } else if (rec.autoResumePending) {
          await _storeRestoredState(rec.copyWith(status: DownloadStatus.queued));
        } else {
          // Preserve partial bytes and metadata. Resume resolves a fresh URL
          // rather than leaving a dead process's job permanently downloading.
          await _storeRestoredState(rec.copyWith(status: DownloadStatus.paused));
        }
      }
      if (!_disposed) notifyListeners();
    } catch (error) {
      // Fail closed: an unknown native inventory cannot safely admit more work.
      _desktopRecoveryError = error;
    }
  }

  /// Startup completion includes durable state/compaction, not just labels.
  /// Newer user pause/cancel/recreate intent wins during recovery awaits.
  Future<void> _storeRestoredState(DownloadRecord record) async {
    if (!_ownsDownloadGeneration(record) ||
        _records[record.id]?.status == DownloadStatus.paused) return;
    _records[record.id] = record;
    await _box.put(record.id, record.toMap());
  }

  /// Snapshot barrier for background restart cleanup without blocking Home.
  @visibleForTesting
  Future<void> get retiredCleanupCompleted => _retiredCleanup;

  /// Retire only files backed by an intact saved replacement. Keep metadata
  /// for unavailable volumes so an unplugged drive is never mistaken for a
  /// successful deletion. One record is processed at a time.
  Future<void> _cleanupRetiredCompletedFiles() async {
    for (final saved in _records.values.toList()) {
      if (_disposed) return;
      if (saved.status != DownloadStatus.done ||
          saved.retainedMediaPaths.isEmpty ||
          saved.filePath == null ||
          isUriPath(saved.filePath!)) {
        continue;
      }
      if (_finalizationDone.containsKey(saved.id)) continue;
      final finished = Completer<void>();
      _finalizationDone[saved.id] = finished;
      try {
        if (!await _replacementIntact(saved)) continue;
        for (final previous in saved.retainedMediaPaths) {
          if (_disposed || !await _replacementIntact(saved)) break;
          if (!isUriPath(previous) &&
              !_sameMediaPath(previous, saved.filePath!)) {
            await _deleteUnreferencedMedia(previous, saved.id);
          }
        }
        if (_disposed || !await _replacementIntact(saved)) continue;
        final remaining = <String>[];
        for (final previous in saved.retainedMediaPaths) {
          if (_sameMediaPath(previous, saved.filePath!)) continue;
          if (isUriPath(previous) ||
              await File(previous).exists() ||
              !await _storageAccessible(previous)) {
            remaining.add(previous);
          }
        }
        if (remaining.length != saved.retainedMediaPaths.length) {
          await _commitCompletedRecord(
            saved.copyWith(retainedMediaPaths: remaining),
          );
        }
      } catch (_) {
        // The current download remains valid; retained pointers allow another
        // attempt after storage/permissions recover on a subsequent launch.
      } finally {
        _finalizationDone.remove(saved.id);
        finished.complete();
      }
    }
    if (!_disposed) notifyListeners();
  }

  /// Validate current ownership and saved size before removing any older copy.
  Future<bool> _replacementIntact(DownloadRecord saved) async {
    final current = _records[saved.id];
    if (_disposed ||
        current?.status != DownloadStatus.done ||
        current?.filePath != saved.filePath) {
      return false;
    }
    try {
      final file = File(saved.filePath!);
      if (!await file.exists()) return false;
      final size = await file.length();
      return size > 0 && (saved.bytesTotal <= 0 || size == saved.bytesTotal);
    } catch (_) {
      return false;
    }
  }

  /// A missing file is definitive only when an ancestor on its volume exists.
  static Future<bool> _storageAccessible(String path) async {
    var directory = File(path).absolute.parent;
    try {
      while (true) {
        if (await directory.exists()) return true;
        final parent = directory.parent;
        if (parent.path == directory.path) return false;
        directory = parent;
      }
    } catch (_) {
      return false;
    }
  }

  /// Windows spelling/case differences do not create a second media file.
  static bool _sameMediaPath(String first, String second) {
    if (!Platform.isWindows || isUriPath(first) || isUriPath(second)) {
      return first == second;
    }
    return p.windows.normalize(p.windows.absolute(first)).toLowerCase() ==
        p.windows.normalize(p.windows.absolute(second)).toLowerCase();
  }

  /// New jobs and resume share the startup inventory barrier.
  Future<void> _awaitDesktopRecovery() async {
    await _desktopRecovery;
    if (_desktopRecoveryError != null) {
      throw StateError(
        'Could not inspect existing downloads. Restart the app before starting more.',
      );
    }
  }

  /// Existing completed downloads predate public subtitle copies. Publish them
  /// once in the background too, so users can open those videos directly from
  /// a file browser without having to download the episode again. The publisher
  /// checks each video's actual path, so private videos remain private even if
  /// the setting changes later.
  Future<void> _publishPreviouslyDownloadedSubtitles() async {
    if (!Platform.isAndroid) return;
    for (final rec in _records.values.toList()) {
      if (rec.status == DownloadStatus.done &&
          rec.filePath != null &&
          rec.subtitles.any((s) => s.publicPath == null)) {
        await _publishExternalSubtitles(rec);
      }
    }
  }

  /// Apply a new "Parallel downloads" limit live to BOTH paths — the MP4 queue
  /// here and the HLS service — so a change takes effect on the current batch.
  /// Raising it starts queued episodes right away; lowering it only stops new
  /// ones spawning (running downloads are never interrupted).
  void setParallel(int n) {
    final v = n.clamp(DownloadPrefs.parallelMin, DownloadPrefs.parallelMax);
    _mp4Queue.maxConcurrent = v;
    if (Platform.isWindows) _desktopSlots.limit = v;
    // The queue only re-checks on add/finish, not when maxConcurrent changes —
    // so nudge it, otherwise raising the limit wouldn't start queued downloads
    // until the current one ended.
    _mp4Queue.advanceQueue();
    if (!isAppleTv) {
      try {
        DownloadService.instance.invoke('setParallel', {'n': v});
      } catch (_) {}
    }
  }

  /// Apply progress/done/failed events the foreground-service isolate sends for
  /// HLS downloads (live, while the UI is alive).
  void _listenBackgroundService() {
    // tvOS (and any host without the plugin) — touching FlutterBackgroundService
    // throws as soon as the platform instance is read.
    if (isAppleTv) return;
    try {
      final svc = DownloadService.instance;
      svc.on('progress').listen((d) {
        final id = d?['id'] as String?;
        if (id == null) return;
        final rec = _records[id];
        if (rec == null || rec.status == DownloadStatus.canceled) return;
        final p = (d?['progress'] as num?)?.toDouble() ?? rec.progress;
        _put(rec.copyWith(status: DownloadStatus.downloading, progress: p));
        notifyListeners();
      });
      svc.on('done').listen((d) async {
        final id = d?['id'] as String?;
        if (id == null) return;
        final rec = _records[id];
        if (rec == null || rec.status == DownloadStatus.canceled) return;
        _candidates.remove(id);
        var path = d?['filePath'] as String?;
        // The isolate handed back the local .ts temp; remux it to a real .mp4
        // (Android) and move it into shared storage / the user's SAF folder here.
        if (path != null && d?['needsFinalize'] == true) {
          // Say so. Joining, remuxing and moving rewrite the whole file, and
          // the progress bar only ever measured the fetch — so it has been
          // sitting at 100% through all of it, looking hung.
          _put(rec.copyWith(status: DownloadStatus.finalizing));
          notifyListeners();
          final finalized = await _finalizeHls(
            path,
            customUri: d?['customUri'] as String?,
            subDir: d?['sharedSubDir'] as String?,
          );
          if (finalized != null) path = finalized;
        }
        await _markDone(rec, path);
        notifyListeners();
      });
      svc.on('failed').listen((d) async {
        final id = d?['id'] as String?;
        if (id == null) return;
        final rec = _records[id];
        if (rec == null || d?['canceled'] == true) return;
        final err = d?['error'] as String? ?? 'Download failed';
        AppLogger.instance.log(
          '[download] HLS failed — ${rec.showTitle} · ${rec.episodeTitle} '
          '[${rec.quality}]: $err',
          level: 'E',
        );
        if (await _tryNext(rec)) return; // fell back to another mirror
        _put(rec.copyWith(status: DownloadStatus.failed, error: () => err));
        notifyListeners();
      });
    } catch (_) {
      // Plugin absent — HLS background path unavailable on this platform.
    }
  }

  /// Apply progress events from the native torrent download engine onto records
  /// (peers/speed are cached in [torrentProgress] for the UI).
  void _listenTorrentDownloads() {
    // Android-only Method/EventChannel — tvOS has no torrent engine.
    if (isAppleTv) return;
    _torrentSvc.events().listen((p) async {
      final rec = _records[p.id];
      if (rec == null || rec.status == DownloadStatus.canceled) return;
      torrentProgress[p.id] = p;
      switch (p.status) {
        case 'done':
          _candidates.remove(p.id);
          await _markDone(rec, p.filePath);
        case 'failed':
          _put(
            rec.copyWith(
              status: DownloadStatus.failed,
              error: () => p.error ?? 'Torrent download failed',
            ),
          );
        case 'paused':
          _put(rec.copyWith(status: DownloadStatus.paused));
        default: // queued | downloading | copying — keep it "downloading"
          _put(
            rec.copyWith(
              status: DownloadStatus.downloading,
              progress: p.progress,
            ),
          );
      }
      notifyListeners();
    });
  }

  /// Read completion markers written by the service while the app was killed,
  /// apply them to records, then delete them.
  Future<void> _reconcileServiceResults() async {
    try {
      final dir = await DownloadService.resultsDir();
      if (!await dir.exists()) return;
      for (final entity in dir.listSync()) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        try {
          final m = jsonDecode(await entity.readAsString()) as Map;
          final id = m['id'] as String?;
          final rec = id == null ? null : _records[id];
          if (rec != null &&
              rec.status != DownloadStatus.done &&
              rec.status != DownloadStatus.canceled) {
            final status = m['status'] as String?;
            if (status == 'done') {
              _candidates.remove(id);
              var path = m['filePath'] as String?;
              // App was killed before the live finalize ran — remux + move now.
              if (path != null && m['needsFinalize'] == true) {
                _put(rec.copyWith(status: DownloadStatus.finalizing));
                notifyListeners();
                final finalized = await _finalizeHls(
                  path,
                  customUri: m['customUri'] as String?,
                  subDir: m['sharedSubDir'] as String?,
                );
                if (finalized != null) path = finalized;
              }
              await _markDone(rec, path);
            } else if (status == 'failed') {
              final err = m['error'] as String? ?? 'Download failed';
              AppLogger.instance.log(
                '[download] HLS failed (finished offline) — '
                '${rec.showTitle} · ${rec.episodeTitle}: $err',
                level: 'E',
              );
              _put(
                rec.copyWith(status: DownloadStatus.failed, error: () => err),
              );
            }
          }
        } catch (_) {}
        try {
          await entity.delete();
        } catch (_) {}
      }
      notifyListeners();
    } catch (_) {}
  }

  /// Reconcile completed work first, then ask the foreground service to resume
  /// any HLS jobs whose isolate was stopped with the app process.
  Future<void> _recoverBackgroundHlsJobs() async {
    await _reconcileServiceResults();
    try {
      final journal = await DownloadService.jobJournal();
      var hasPendingJobs = false;
      for (final job in await journal.pending()) {
        final id = job['id'] as String?;
        final rec = id == null ? null : _records[id];
        if (rec == null ||
            rec.isTorrent ||
            rec.status == DownloadStatus.done ||
            rec.status == DownloadStatus.failed ||
            rec.status == DownloadStatus.canceled ||
            rec.status == DownloadStatus.unsupported) {
          if (id != null) await journal.remove(id);
          continue;
        }
        hasPendingJobs = true;
      }
      if (!hasPendingJobs) return;

      final service = DownloadService.instance;
      if (await service.isRunning()) {
        service.invoke('sync');
      } else {
        await service.startService();
      }
    } catch (e) {
      AppLogger.instance.log(
        '[download] could not resume background HLS jobs: $e',
        level: 'W',
      );
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _retryScheduler.dispose();
    _pendingAudioResumes.clear();
    _sub?.cancel();
    _desktopTransferSlots?.close();
    super.dispose();
  }

  // ── Reads ────────────────────────────────────────────────────────────────

  List<DownloadRecord> get all =>
      _records.values.toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  /// Records grouped by show, newest show first.
  Map<String, List<DownloadRecord>> get byShow {
    final out = <String, List<DownloadRecord>>{};
    for (final r in all) {
      (out[r.showId] ??= []).add(r);
    }
    return out;
  }

  DownloadRecord? recordFor(String sourceId, String showId, String episodeId, {String? category}) =>
      _records[_idFor(sourceId, showId, episodeId, category: category)];

  /// Finished download for this episode, even when today's title page differs
  /// from the one it was saved from (source page then, metadata page now —
  /// the keys embed the opening page). Exact keys first; then the source
  /// episode URL (identical URL = identical file); then MAL id + episode
  /// number. Title-only matching is deliberately absent: remakes share
  /// titles, and playing the wrong file is worse than streaming.
  Future<DownloadRecord?> finishedForEpisode({
    required String sourceId,
    required String showId,
    required String episodeId,
    String? episodeUrl,
    int? malId,
    double? episodeNumber,
    String? category,
    int? season,
  }) async {
    final exact = recordFor(sourceId, showId, episodeId, category: category);
    bool eligible(DownloadRecord r) => !Platform.isWindows ||
        ((category == null || r.category == category) && (season == null || r.season == season));
    if (exact != null && eligible(exact) && await filePresent(exact)) return exact;
    final candidates = <DownloadRecord>[];
    for (final r in _records.values) {
      if (r.status != DownloadStatus.done || !eligible(r)) continue;
      if (episodeUrl != null &&
          episodeUrl.isNotEmpty &&
          r.episodeUrl == episodeUrl) {
        candidates.insert(0, r);
        continue;
      }
      if (malId != null &&
          r.malId == malId &&
          episodeNumber != null &&
          r.episodeNumber == episodeNumber) {
        candidates.add(r);
      }
    }
    for (final r in candidates) {
      if (await filePresent(r)) return r;
    }
    return null;
  }

  /// Join concurrent startup/Downloads refresh requests; existing media and
  /// app data never move. Missing metadata is recreated as explicit local files.
  Future<void> recoverLocalFiles() {
    if (!Platform.isWindows || _disposed) return Future.value();
    return _localRecoveryWork ??= _recoverLocalFiles().whenComplete(() {
      _localRecoveryWork = null;
    });
  }

  Future<void>? _thumbnailWork;

  /// Backfill one saved video at a time without blocking startup or transfers.
  /// A deleted/replaced record always wins over work that finishes later.
  Future<void> _backfillRecoveredThumbnails() async {
    final cache=await writableAppSubdir('download-thumbnails');
    final extractor=DesktopDownloadThumbnails();
    for (final snapshot in _records.values.toList()) {
      if (_disposed) return;
      if (!snapshot.recoveredFromDisk || snapshot.status!=DownloadStatus.done ||
          snapshot.filePath==null) continue;
      final existing=Uri.tryParse(snapshot.episodeThumbnail ?? '');
      if (existing?.scheme=='file' && await File.fromUri(existing!).exists()) continue;
      if (snapshot.episodeThumbnail?.isNotEmpty==true && existing?.scheme!='file') continue;
      final artwork=await extractor.ensure(snapshot.filePath!,cache);
      if (_disposed) return;
      final current=_records[snapshot.id];
      if (artwork==null || current==null || current.filePath!=snapshot.filePath ||
          current.storageKey!=snapshot.storageKey || current.status!=DownloadStatus.done) continue;
      final updated=current.copyWith(episodeThumbnail:artwork);
      await _box.put(updated.id,updated.toMap());
      if (_disposed || !identical(_records[updated.id],current)) continue;
      _records[updated.id]=updated; notifyListeners();
    }
  }

  /// Publish recovered entries durably before notifying the Windows library.
  Future<void> _recoverLocalFiles() async {
    try {
      final found = await _localRecovery.discover(
        roots: [
          if (_downloadPrefs.locationUri != null) _downloadPrefs.locationUri!,
          if (DesktopStorage.downloadsRoot != null) DesktopStorage.downloadsRoot!,
          if (DesktopStorage.previousRoot != null) DesktopStorage.previousRoot!,
        ],
        known: _records.values.toList(), canceled: () => _disposed,
      );
      for (final record in found) {
        if (_disposed) return;
        if (_records.containsKey(record.id)) continue;
        // Another transfer may have claimed this path while FFprobe was active.
        if (_records.values.any((r) => r.filePath != null &&
            _sameMediaPath(r.filePath!, record.filePath!))) continue;
        await _box.put(record.id, record.toMap());
        if (_disposed) return;
        _records[record.id] = record;
      }
      if (!_disposed && found.isNotEmpty) notifyListeners();
      if (!_disposed && _thumbnailWork==null) {
        _thumbnailWork=_backfillRecoveredThumbnails().catchError((Object _) {
          // Artwork is optional; a later library refresh can retry safely.
        }).whenComplete(()=>_thumbnailWork=null);
        unawaited(_thumbnailWork);
      }
    } catch (_) {
      // Recovery failure leaves existing records/files intact and can be retried.
      AppLogger.instance.log('[download] Local media recovery could not finish', level: 'W');
    }
  }

  /// True when a finished record's file is still on disk and playable.
  /// Same leniency as [pruneMissing]: a content:// URI that can't be checked
  /// counts as present, so a transient SAF failure never reads as deleted.
  /// Read-only: never prunes, moves, or rewrites anything.
  Future<bool> filePresent(DownloadRecord rec) async {
    if (rec.status != DownloadStatus.done) return false;
    final fp = rec.filePath;
    if (fp == null || fp.isEmpty) return false;
    try {
      if (isUriPath(fp)) return await _documentExists(fp);
      return await File(fp).exists();
    } catch (_) {
      return false;
    }
  }

  // ── Enqueue ───────────────────────────────────────────────────────────────

  /// Persist a [DownloadStatus.queued] record for each episode, then resolve +
  /// enqueue them in the background. Safe to not await.
  Future<void> enqueueEpisodes({
    required String sourceId,
    required String showId,
    required String showTitle,
    String? cover,
    Map<String, String>? coverHeaders,
    required String showUrl,
    required String category,
    required String quality,
    required List<Episode> episodes,
    DownloadServerPreference? serverPreference,
    required int nowMs,
    int? malId,
  }) async {
    if (!await _downloadPrefs.ensureDesktopFolder()) return;
    // Best-effort notification permission so the progress notification shows.
    try {
      await Permission.notification.request();
    } catch (_) {}

    final pending = <DownloadRecord>[];
    for (final ep in episodes) {
      final id = _idFor(sourceId, showId, ep.id, category: category);
      if (_records[id]?.isActive == true) continue;
      if (Platform.isWindows && !await _waitForFinalization(id)) return;
      final existing = _records[id];
      // Skip ones already done or in flight.
      if (existing?.isActive == true) continue;
      if (existing?.status == DownloadStatus.done) {
        final present = !Platform.isWindows || await filePresent(existing!);
        if (_disposed) return;
        // A file stat must not revive a user-canceled/replaced generation.
        if (!identical(_records[id], existing) || present) continue;
      }
      final rec = DownloadRecord(
        id: id,
        sourceId: sourceId,
        showId: showId,
        showTitle: showTitle,
        cover: cover,
        coverHeaders: coverHeaders,
        showUrl: showUrl,
        episodeId: ep.id,
        episodeUrl: ep.url,
        episodeNumber: ep.number,
        episodeThumbnail: ep.thumbnail,
        season: ep.season,
        storageKey: Platform.isWindows ? _randomNonce() : '',
        downloadRoot: Platform.isWindows ? _downloadPrefs.locationUri : null,
        episodeTitle: ep.title,
        category: category,
        quality: quality,
        serverPreference: serverPreference,
        retainedMediaPaths: {
          ...?existing?.retainedMediaPaths,
          if (existing?.filePath != null) existing!.filePath!,
          if (existing?.supersededPath != null) existing!.supersededPath!,
        }.toList(),
        malId: malId,
        autoResumePending: Platform.isWindows,
        createdAt: nowMs,
      );
      _put(rec);
      pending.add(rec);
    }
    if (Platform.isWindows) {
      await _box.putAll({for (final record in pending) record.id: record.toMap()});
    }
    if (_disposed) return;
    notifyListeners();

    for (final rec in pending) {
      if (Platform.isWindows && (!_ownsDownloadGeneration(rec) ||
          _records[rec.id]?.status == DownloadStatus.paused)) continue;
      await _resolveAndEnqueue(rec);
    }
  }

  /// Enqueue a single episode against an ALREADY-CHOSEN source (the CloudStream
  /// "pick a server" flow) — no re-resolution, so the exact url + headers the
  /// player would stream are what we download.
  Future<void> enqueueSource({
    required String sourceId,
    required String showId,
    required String showTitle,
    String? cover,
    Map<String, String>? coverHeaders,
    required String showUrl,
    required String category,
    required Episode episode,
    required VideoSource source,
    required String qualityLabel,
    required int nowMs,
    int? malId,
    List<VideoSource> fallbacks = const [],
  }) async {
    if (!await _downloadPrefs.ensureDesktopFolder()) return;
    try {
      await Permission.notification.request();
    } catch (_) {}
    // Carry the outgoing file on the new record so it survives a restart —
    // in memory it was lost if the app died mid re-download, stranding the old
    // file for good. A previous supersededPath wins if this record never got a
    // file of its own (a re-download that failed, then was retried).
    if (_records[_idFor(sourceId, showId, episode.id, category: category)]?.isActive == true) {
      return;
    }
    if (Platform.isWindows &&
        !await _waitForFinalization(_idFor(sourceId, showId, episode.id, category: category))) {
      return;
    }
    final replacing = _records[_idFor(sourceId, showId, episode.id, category: category)];
    // Repeated bulk/server clicks must not replace an already-owned transfer.
    if (replacing?.isActive == true) return;
    final outgoing = (replacing?.filePath?.isNotEmpty ?? false)
        ? replacing!.filePath
        : replacing?.supersededPath;
    final rec = DownloadRecord(
      id: _idFor(sourceId, showId, episode.id, category: category),
      sourceId: sourceId,
      showId: showId,
      showTitle: showTitle,
      cover: cover,
      coverHeaders: coverHeaders,
      showUrl: showUrl,
      episodeId: episode.id,
      episodeUrl: episode.url,
      episodeNumber: episode.number,
      episodeThumbnail: episode.thumbnail,
      season: episode.season,
      storageKey: Platform.isWindows ? _randomNonce() : '',
      downloadRoot: Platform.isWindows ? _downloadPrefs.locationUri : null,
      episodeTitle: episode.title,
      category: category,
      quality: qualityLabel,
      serverPreference: DownloadServerPreference.fromSource(source),
      malId: malId,
      supersededPath: outgoing,
      retainedMediaPaths: {
        ...?replacing?.retainedMediaPaths,
        if (replacing?.supersededPath != null &&
            replacing!.supersededPath != outgoing)
          replacing.supersededPath!,
      }.toList(),
      createdAt: nowMs,
    );
    _put(rec);
    notifyListeners();
    // The user's chosen source first, then the other mirrors as fallback (so a
    // dead mirror auto-advances instead of just failing).
    final eligible = rec.serverPreference!.prioritize(
      sourcesForDownloadCategory([
        source,
        ...fallbacks.where((s) => s.url != source.url),
      ], category),
    );
    if (eligible.isEmpty) {
      _put(
        rec.copyWith(
          status: DownloadStatus.unsupported,
          error: () =>
              'The selected $category audio is unavailable from this source',
        ),
      );
      notifyListeners();
      return;
    }
    _candidates[rec.id] = eligible;
    await _enqueueTaskFor(rec, eligible.first);
  }

  /// Resolve saved jobs independently of whatever cut the detail page last used.
  /// The concrete metadata API accepts the cut without widening every catalogue
  /// implementation; ordinary source episode URLs already identify their cut.
  Future<List<VideoSource>> _sourcesForSavedCategory(DownloadRecord rec) {
    final metadata = _repo is MetadataRepository
        ? _repo
        : ZmodeIds.isZ(rec.episodeUrl) &&
              GetIt.I.isRegistered<MetadataRepository>()
        ? GetIt.I<MetadataRepository>()
        : null;
    return metadata != null
        ? metadata.sources(
            rec.episodeUrl,
            sourceId: rec.sourceId,
            category: rec.category,
          )
        : _repo.sources(rec.episodeUrl, sourceId: rec.sourceId);
  }

  /// Audio language is a constraint; server and quality only rank eligible links.
  List<VideoSource> _rankedForRecord(
    DownloadRecord rec,
    List<VideoSource> sources,
  ) {
    final byQuality = _ranked(sources, rec.quality, category: rec.category);
    return rec.serverPreference?.prioritize(byQuality) ?? byQuality;
  }

  /// Source resolution must not revive a paused, replaced or disposed Windows job.
  bool _resolutionRetired(DownloadRecord rec) => Platform.isWindows
      ? !_ownsDownloadGeneration(rec) || _records[rec.id]?.status == DownloadStatus.paused
      : _isCanceled(rec.id);

  /// Resolve a source for [rec] (batch path) then enqueue it, keeping the rest
  /// as fallback mirrors.
  Future<void> _resolveAndEnqueue(DownloadRecord rec) async {
    _put(rec.copyWith(status: DownloadStatus.resolving));
    notifyListeners();
    try {
      final sources = await _sourcesForSavedCategory(rec);
      if (_resolutionRetired(rec)) return; // canceled while resolving
      final ranked = _rankedForRecord(rec, sources);
      if (ranked.isEmpty) {
        // Everything this source offers is a manifest. Another source may
        // serve real files — that is worth trying before saying no.
        if (await _tryAnotherSource(rec) || _resolutionRetired(rec)) return;
        AppLogger.instance.log(
          '[download] no downloadable source — ${rec.showTitle} · '
          '${rec.episodeTitle} (${sources.length} source(s), all DASH/unusable)',
          level: 'E',
        );
        _put(
          rec.copyWith(
            status: DownloadStatus.unsupported,
            error: () =>
                'No downloadable stream for the selected ${rec.category} audio',
          ),
        );
        notifyListeners();
        return;
      }
      _candidates[rec.id] = ranked;
      await _enqueueTaskFor(rec, ranked.first);
    } catch (e) {
      if (_resolutionRetired(rec)) return;
      if (Platform.isWindows && e is DioException && e.response?.statusCode == 429) {
        final response = e.response!;
        await _rememberDownloadHostCooldown(response.realUri, response.headers.value('retry-after'));
        await _queueHostRetry(rec, response.realUri, received429: true);
        return;
      }
      AppLogger.instance.log(
        'download resolve failed (${rec.showTitle}): $e',
        level: 'E',
      );
      _put(
        rec.copyWith(
          status: DownloadStatus.failed,
          error: () => 'Resolve failed',
        ),
      );
      notifyListeners();
    }
  }

  /// Advance [rec] to its next fallback mirror. Returns true if one was
  /// enqueued or the record was canceled, false when mirrors are exhausted.
  Future<bool> _tryNext(DownloadRecord rec) async {
    if (_isCanceled(rec.id)) return true;
    final cands = _candidates[rec.id];
    if (cands != null && cands.length > 1) {
      cands.removeAt(0); // drop the one that just failed
      if (cands.isNotEmpty) {
        _put(rec.copyWith(status: DownloadStatus.resolving, progress: 0));
        notifyListeners();
        await _enqueueTaskFor(rec, cands.first);
        return true;
      }
    }
    // Mirrors exhausted. They all came from ONE source, so a source that is
    // undownloadable is undownloadable on every server it offers — AnimePahe
    // serves DASH from all of them. Ask the catalogue for another source
    // before giving up.
    final found = await _tryAnotherSource(rec);
    return found || _isCanceled(rec.id);
  }

  /// Records currently mid-sweep, so a record can't start a second one for
  /// itself while the first is still running.
  final Set<String> _sweeping = {};

  /// Find a source that can actually produce a file, in ONE sweep.
  ///
  /// Auto Resolve already walks every candidate in priority order; this hands
  /// it the extra condition downloading needs, so it keeps going past a source
  /// whose streams are all manifests instead of settling on it. One sweep, not
  /// one sweep per rejected source — that was quadratic and froze the app.
  Future<bool> _tryAnotherSource(DownloadRecord rec) async {
    if (!ZmodeIds.isZ(rec.episodeUrl))
      return false; // only the catalogue sweeps
    if (!GetIt.I.isRegistered<MetadataRepository>()) return false;
    if (_sweeping.contains(rec.id))
      return false; // already looking for this one
    _sweeping.add(rec.id);
    try {
      final next = await GetIt.I<MetadataRepository>().sourcesWhere(
        rec.episodeUrl,
        (streams) => _rankedForRecord(rec, streams).isNotEmpty,
        category: rec.category,
      );
      if (_isCanceled(rec.id)) return true;
      final byQuality = _ranked(
        next.streams,
        rec.quality,
        category: rec.category,
      );
      final ranked = rec.serverPreference?.prioritize(byQuality) ?? byQuality;
      if (ranked.isEmpty) return false;
      AppLogger.instance.log(
        '[download] ${rec.showTitle} · ${rec.episodeTitle}: swept past the '
        'undownloadable sources to ${next.sourceId}',
      );
      _candidates[rec.id] = ranked;
      _put(rec.copyWith(status: DownloadStatus.resolving, progress: 0));
      notifyListeners();
      await _enqueueTaskFor(rec, ranked.first);
      return true;
    } catch (e) {
      if (_isCanceled(rec.id)) return true;
      AppLogger.instance.log(
        'download: no downloadable source for ${rec.showTitle}: $e',
        level: 'E',
      );
      return false;
    } finally {
      _sweeping.remove(rec.id);
    }
  }

  /// Start [rec] from a concrete [source] — HLS via the in-app segment
  /// downloader, everything else via background_downloader.
  /// Desktop HLS and direct-file transfers share one capacity pool. Mobile
  /// retains its background-service queues and torrents their own scheduler.
  /// Snapshot barrier for source re-resolution already dispatched by timers.
  @visibleForTesting
  Future<void> get automaticRetryWorkCompleted => _automaticRetryWork;

  /// Save pending intent before arming any retry; never persist signed URLs.
  Future<bool> _queueHostRetry(DownloadRecord snapshot, Uri uri,
      {required bool received429}) async {
    if (!_ownsDownloadGeneration(snapshot)) return false;
    final current = _records[snapshot.id]!;
    if (uri.host.isEmpty || !const ['http', 'https'].contains(uri.scheme)) return false;
    final now = _retryScheduler.now();
    final count = current.retryCount + (received429 ? 1 : 0);
    var deadline = _downloadPrefs.hostCooldownUntil(uri, now: now);
    if (received429) {
      final exponent = (count - 1).clamp(0, 7).toInt();
      final fallback = now.add(Duration(seconds: min(3600, 30 * (1 << exponent))));
      if (deadline == null || deadline.isBefore(fallback)) deadline = fallback;
      // Extend the host deadline only for a real429, never for a queued follower.
      await _rememberDownloadHostCooldown(uri,
          ((deadline.difference(now).inMilliseconds + 999) ~/ 1000).toString());
    }
    deadline ??= current.retryAt == null
        ? now.add(const Duration(seconds: 30))
        : DateTime.fromMillisecondsSinceEpoch(current.retryAt!, isUtc: true);
    if (!_ownsDownloadGeneration(snapshot) ||
        _records[snapshot.id]?.status == DownloadStatus.paused) return false;
    final waiting = _records[snapshot.id]!.copyWith(
      status: DownloadStatus.queued, retryAt: () => deadline!.millisecondsSinceEpoch,
      retryHost: () => uri.host.toLowerCase(), retryCount: count,
      autoResumePending: true,
      error: () => 'Source is rate limiting downloads (429). Waiting to retry.',
    );
    _tasks.remove(waiting.id);
    _records[waiting.id] = waiting;
    try {
      await _box.put(waiting.id, waiting.toMap());
    } catch (_) {
      if (_ownsDownloadGeneration(waiting)) {
        _records[waiting.id] = waiting.copyWith(status: DownloadStatus.failed,
            error: () => 'Could not save the delayed download. Check storage and retry.');
        notifyListeners();
      }
      return false;
    }
    if (!_ownsDownloadGeneration(waiting) ||
        _records[waiting.id]?.status != DownloadStatus.queued) return false;
    _armPendingRetry(_records[waiting.id]!);
    notifyListeners();
    return true;
  }

  /// Keep pending jobs dormant until both their saved and shared host wait ends.
  void _armPendingRetry(DownloadRecord record) {
    if (_disposed || !record.autoResumePending || record.status != DownloadStatus.queued) return;
    if (_tasks.containsKey(record.id) ||
        (record.retryAt == null && _desktopSlots.contains(record.id))) return;
    var deadline = record.retryAt == null ? _retryScheduler.now()
        : DateTime.fromMillisecondsSinceEpoch(record.retryAt!, isUtc: true);
    if (record.retryHost != null && record.retryHost!.isNotEmpty) {
      final host = _downloadPrefs.hostCooldownUntil(
          Uri(scheme: 'https', host: record.retryHost), now: _retryScheduler.now());
      if (host != null && host.isAfter(deadline)) deadline = host;
    }
    _retryScheduler.schedule(record.id, record.storageKey, deadline, () {
      // Fresh source resolution is serialized, like the original batch loop;
      // dozens of expired timers must not burst at a provider simultaneously.
      _automaticRetryWork = _automaticRetryWork.then((_) async {
        final current = _records[record.id];
        if (!_ownsDownloadGeneration(record) || current?.status != DownloadStatus.queued) return;
        final host = current!.retryHost == null ? null : _downloadPrefs.hostCooldownUntil(
            Uri(scheme: 'https', host: current.retryHost), now: _retryScheduler.now());
        if (host != null) {
          await _queueHostRetry(current,
              Uri(scheme: 'https', host: current.retryHost), received429: false);
          return;
        }
        final ready = current.copyWith(retryAt: () => null, retryHost: () => null,
            error: () => null);
        _put(ready);
        await _resolveAndEnqueue(ready);
      }).catchError((Object _) {
        if (!_ownsDownloadGeneration(record)) return;
        _put(_records[record.id]!.copyWith(status: DownloadStatus.failed,
            error: () => 'The pending download could not resume. Retry later.'));
        notifyListeners();
      });
    });
  }

  /// Keep Windows transfers off a rate-limited host without occupying a slot.
  /// Pending jobs hold no lease; pause/cancel invalidates their timer.
  Future<bool> _hostCooldownBlocks(DownloadRecord rec, String url) async {
    final uri = Uri.tryParse(url);
    final deadline = uri == null ? null :
        _downloadPrefs.hostCooldownUntil(uri, now: _retryScheduler.now());
    if (deadline == null) return false;
    await _queueHostRetry(rec, uri!, received429: false);
    return true;
  }

  Future<void> _enqueueTaskFor(DownloadRecord rec, VideoSource source) async {
    if (_disposed) return;
    if (!Platform.isWindows || isTorrentSource(source)) {
      return _enqueueTaskNow(rec, source);
    }
    await _awaitDesktopRecovery();
    // Recovery can settle after route/service replacement disposed this owner.
    if (_disposed || _isCanceled(rec.id)) return;
    if (_desktopSlots.contains(rec.id)) {
      final retiring = _foregroundHlsAttempts[rec.id];
      if (retiring != null && retiring.storageKey != rec.storageKey &&
          _deferredHlsReplacements[rec.id] != rec.storageKey) {
        _deferredHlsReplacements[rec.id] = rec.storageKey;
        final work = _enqueueAfterHlsRetirement(rec, source, retiring.done);
        _foregroundHlsWork.add(work);
        unawaited(work.whenComplete(() => _foregroundHlsWork.remove(work)));
      }
      return;
    }
    if (await _hostCooldownBlocks(rec, source.url)) return;
    _tasks.remove(rec.id);
    _put(rec.copyWith(status: DownloadStatus.queued));
    notifyListeners();
    final lease = await _desktopSlots.acquire(rec.id);
    if (lease == null) return;
    if (_disposed || _isCanceled(rec.id)) {
      lease.release();
      return;
    }
    // A preceding transfer may have received429 while this job waited in FIFO.
    if (await _hostCooldownBlocks(rec, source.url)) {
      lease.release();
      return;
    }
    if (_isHls(source)) {
      _scheduleSubtitles(rec, source);
      // Scheduling returns now, allowing a bulk operation to queue its other
      // episodes. The lease lasts until the actual HLS transfer finishes.
      final work = _startHlsDownload(
          rec,
          source,
          lease: lease,
        ).whenComplete(lease.release).catchError((Object error) {
          // Cleanup/storage failures must finish this detached operation too.
          if (!_ownsDownloadGeneration(rec)) return;
          _put(
            rec.copyWith(
              status: DownloadStatus.failed,
              error: () => 'Download could not finish: $error',
            ),
          );
          notifyListeners();
        });
      _foregroundHlsAttempts[rec.id] = (storageKey: rec.storageKey, done: work);
      _foregroundHlsWork.add(work);
      unawaited(work.whenComplete(() {
        _foregroundHlsWork.remove(work);
        if (identical(_foregroundHlsAttempts[rec.id]?.done, work)) {
          _foregroundHlsAttempts.remove(rec.id);
        }
      }));
      return;
    }
    try {
      await _enqueueTaskNow(rec, source);
      // The platform status callback releases the direct-file lease.
    } catch (_) {
      lease.release();
      rethrow;
    }
  }

  /// A replacement keeps its place without stealing a retiring HLS lease.
  /// Recheck generation after the old worker settles so cancel/delete/dispose
  /// cannot restart a job and repeated same-ID retries cannot duplicate it.
  Future<void> _enqueueAfterHlsRetirement(DownloadRecord rec,
      VideoSource source, Future<void> retired) async {
    try {
      await retired;
      if (!_ownsDownloadGeneration(rec) ||
          _deferredHlsReplacements[rec.id] != rec.storageKey) return;
      await _enqueueTaskFor(rec, source);
    } catch (_) {
      if (!_ownsDownloadGeneration(rec)) return;
      _put(rec.copyWith(status: DownloadStatus.failed,
          error: () => 'The replacement download could not start. Retry later.'));
      notifyListeners();
    } finally {
      if (_deferredHlsReplacements[rec.id] == rec.storageKey) {
        _deferredHlsReplacements.remove(rec.id);
      }
    }
  }

  Future<void> _enqueueTaskNow(DownloadRecord rec, VideoSource source) async {
    if (_isCanceled(rec.id)) return; // don't (re)start a canceled download
    // Save any soft subtitles this source advertises, in parallel with the
    // video (they're tiny and best-effort — never block or fail the download).
    _scheduleSubtitles(rec, source);
    if (_isHls(source)) {
      await _startHlsDownload(rec, source);
      return;
    }
    if (isTorrentSource(source)) {
      await _startTorrentDownload(rec, source);
      return;
    }
    final filename = '${_mediaFileStem(rec)}${_ext(source.url)}';
    final displayName =
        '${rec.showTitle} · E${rec.episodeNumber?.toInt() ?? ''}';
    final headers = source.headers ?? const <String, String>{};
    // Flaky file hosts (4khdhub's HubCloud/gamerxyt CDN) drop the connection
    // mid-transfer. retries + allowPause let background_downloader RESUME from
    // the partial (the host supports range — mpv can seek it) on each drop
    // instead of restarting from 0. waitingToRetry / negative retry-progress
    // are already handled in _onUpdate, so this only adds resilience.
    // A picked SAF folder (content://) streams straight into that tree. A
    // detected drive (a plain volume path) or the default both download to
    // app-docs first — _finish then moves a drive download onto the volume.
    // A picked SAF folder (content://) streams straight into that tree, which
    // would put the file in public storage. keepPrivate overrides that: stream
    // to app-docs like the default, and never move it out.
    final safUri =
        videoDestination(
              keepPrivate: _downloadPrefs.keepPrivate,
              locationUri: _downloadPrefs.locationUri,
            ) ==
            VideoDestination.safTree
        ? _downloadPrefs.locationUri
        : null;
    final attempt = Platform.isWindows ? _nativeAttemptToken() : '';
    DownloadTask task = safUri != null
        // Custom SAF folder: stream straight into the user's picked directory
        // (the file ends up as a content:// URI — see _finish). No post-move.
        ? UriDownloadTask(
            taskId: rec.id,
            metaData: attempt,
            url: source.url,
            filename: filename,
            headers: headers,
            directoryUri: Uri.parse(safUri),
            updates: Updates.statusAndProgress,
            retries: 5,
            allowPause: true,
            displayName: displayName,
          )
        : DownloadTask(
            taskId: rec.id,
            metaData: attempt,
            url: source.url,
            filename: filename,
            headers: headers,
            directory: Platform.isWindows
                ? _windowsVideoDirectory(rec)
                : '$_sharedDir/${_safe(rec.showTitle)}',
            baseDirectory: Platform.isWindows
                ? BaseDirectory.root
                : BaseDirectory.applicationDocuments,
            updates: Updates.statusAndProgress,
            retries: 5,
            allowPause: true,
            displayName: displayName,
          );
    if (Platform.isWindows && !_singleConnectionIds.contains(rec.id)) {
      Uri? probeLimitedHost;
      final connections = await directFileConnections(
        _dio,
        source.url,
        headers,
        _downloadPrefs.connectionsPerDownload,
        onRateLimited: (uri, retryAfter) async {
          probeLimitedHost = uri;
          await _rememberDownloadHostCooldown(uri, retryAfter);
        },
      );
      if (_isCanceled(rec.id) || _disposed) {
        _desktopSlots.release(rec.id);
        return;
      }
      if (connections == 0) {
        await _queueHostRetry(rec, probeLimitedHost ?? Uri.parse(source.url), received429: true);
        _desktopSlots.release(rec.id);
        return;
      }
      // Another worker can discover a shared host limit while the probe waits.
      if (await _hostCooldownBlocks(rec, source.url)) {
        _desktopSlots.release(rec.id);
        return;
      }
      if (connections > 1) {
        task = ParallelDownloadTask(
          taskId: task.taskId,
          metaData: task.metaData,
          creationTime: task.creationTime,
          url: task.url,
          filename: task.filename,
          headers: task.headers,
          directory: task.directory,
          baseDirectory: task.baseDirectory,
          updates: task.updates,
          retries: task.retries,
          allowPause: task.allowPause,
          displayName: task.displayName,
          chunks: connections,
        );
      }
    }
    _tasks[rec.id] = task;
    // Mark it waiting ("Queued"); the queue enqueues it when a parallel slot is
    // free (→ enqueued/running in _onUpdate). Start failures come back via
    // _mp4Queue.enqueueErrors + _onUpdate's failed case.
    _put(rec.copyWith(status: DownloadStatus.queued, progress: 0));
    notifyListeners();
    if (Platform.isWindows) {
      // The shared desktop lease already limits HLS and native files together;
      // a second MP4-only queue would introduce unrelated capacity accounting.
      if (!await _fileDownloader.enqueue(task)) {
        _desktopSlots.release(rec.id);
        if (await _tryNext(rec) || _isCanceled(rec.id)) return;
        _put(
          rec.copyWith(
            status: DownloadStatus.failed,
            error: () => "Couldn't start download",
          ),
        );
        notifyListeners();
      }
    } else {
      _mp4Queue.add(task);
    }
  }

  /// Share server cooldowns across Windows probes, HLS and subtitle requests.
  Future<void> _rememberDownloadHostCooldown(Uri uri, String? retryAfter) async {
    try {
      await _downloadPrefs.rememberHostCooldown(uri, retryAfter, now: _retryScheduler.now());
    } catch (_) {
      // Storage failures must not hide429 or strand active transfer capacity.
      AppLogger.instance.log('[download] Could not save host cooldown', level: 'E');
    }
  }

  /// Windows HLS requests share persisted host limits with direct-file jobs.
  HlsDownloader _desktopHlsDownloader({HlsAudioMux? muxAudio}) => HlsDownloader(
    _dio,
    muxAudio: muxAudio,
    isHostCoolingDown: (uri) => _downloadPrefs.hostCooldownUntil(uri, now: _retryScheduler.now()) != null,
    onRateLimited: _rememberDownloadHostCooldown,
  );

  /// Hand an HLS source to the foreground-service isolate so it downloads in
  /// true background. We resolve the path here (UI isolate owns path_provider),
  /// start the service, and dispatch the job; progress/done/failed come back via
  /// [_listenBackgroundService].
  Future<void> _startHlsDownload(
    DownloadRecord rec,
    VideoSource source, {
    TransferLease? lease,
  }) async {
    if (Platform.isWindows && !_ownsDownloadGeneration(rec)) {
      lease?.release();
      return;
    }
    _put(rec.copyWith(status: DownloadStatus.downloading, progress: 0));
    notifyListeners();
    HlsDownloadJournal? journal;
    HlsDownloader? desktopHls;
    String? audioFailure;
    try {
      final docs = Platform.isWindows
          ? await getApplicationSupportDirectory()
          : await getApplicationDocumentsDirectory();
      final safeShow = _safe(rec.showTitle);
      final dir = Directory('${docs.path}/$_sharedDir/$safeShow');
      await dir.create(recursive: true);
      // Download the concatenated TS to a local temp with an honest .ts name;
      // the main isolate finalizes it (remux → real .mp4 on Android, else keep
      // the .ts) once the service reports done — see _finalizeHls.
      final outputPath = '${dir.path}/${_mediaFileStem(rec)}.ts';

      if (Platform.isWindows) {
        final folder = Directory(_windowsVideoDirectory(rec));
        await folder.create(recursive: true);
        final destination = '${folder.path}/${outputPath.split('/').last}';
        if (!_ownsDownloadGeneration(rec)) return;
        var lastProgressUpdate = 0;
        final audioMux = DesktopAudioMux();
        desktopHls = _desktopHlsDownloader(
            muxAudio: audioMux.available ? audioMux.merge : null);
        final failure = await desktopHls.download(
              url: source.url,
              headers: source.headers ?? {},
              outputPath: destination,
              preferredQuality: rec.quality,
              connections: _downloadPrefs.connectionsPerDownload,
              preferredAudioLanguage: rec.serverPreference?.audioLanguage,
              canceled: () => !_ownsDownloadGeneration(rec),
              onProgress: (progress) {
                if (!_ownsDownloadGeneration(rec)) return;
                final now = DateTime.now().millisecondsSinceEpoch;
                if (progress < 1 && now - lastProgressUpdate < 250) return;
                lastProgressUpdate = now;
                _put(
                  rec.copyWith(
                    status: DownloadStatus.downloading,
                    progress: progress,
                  ),
                );
                notifyListeners();
              },
            );
        if (!_ownsDownloadGeneration(rec)) return;
        if (failure != null) {
          // Preserve only fixed audio diagnostics. Transport exceptions may
          // contain signed URLs, so unexpected failures retain generic text.
          const safeAudioErrors = {
            'This stream requires the bundled audio merge engine',
            'The bundled audio merge engine is unavailable',
            'Audio merge timed out',
            'The selected audio could not be merged with this video',
            'The audio merge engine could not finish',
            'The selected audio could not be saved',
          };
          if (safeAudioErrors.contains(failure) ||
              RegExp(
                r'^The selected audio language \([a-z]{2,3}\) is unavailable in this stream$',
              ).hasMatch(failure)) {
            audioFailure = failure;
          }
          throw StateError(failure);
        }
        await _markDone(rec, destination);
        notifyListeners();
        return;
      }

      // Background HLS isolate needs flutter_background_service (Android/iOS only).
      if (isAppleTv) {
        throw UnsupportedError(
          'Background HLS downloads are not available on Apple TV',
        );
      }

      final job = <String, dynamic>{
        'id': rec.id,
        'url': source.url,
        'headers': source.headers ?? const <String, String>{},
        'outputPath': outputPath,
        'quality': rec.quality,
        'label': 'E${rec.episodeNumber?.toInt() ?? ''}',
        'showTitle': rec.showTitle,
        'sharedSubDir': '$_sharedDir/$safeShow',
        // Custom SAF folder (if any): the isolate can't SAF-write, so it hands
        // the local temp back and the main isolate moves it into this tree.
        'customUri': _downloadPrefs.locationUri,
        // How many episodes run at once + segment connections per download.
        'parallel': _downloadPrefs.parallelDownloads,
        'connections': _downloadPrefs.connectionsPerDownload,
      };
      journal = await DownloadService.jobJournal();
      await journal.save(job);
      if (_isCanceled(rec.id)) {
        await journal.remove(rec.id);
        return;
      }

      final service = DownloadService.instance;
      if (!await service.isRunning()) await service.startService();
      service.invoke('download', job);
    } catch (_) {
      await journal?.remove(rec.id);
      if (_isCanceled(rec.id) ||
          (Platform.isWindows && !_ownsDownloadGeneration(rec))) {
        lease?.release();
        return;
      }
      final rateLimited = desktopHls?.rateLimited == true;
      if (rateLimited) {
        await _queueHostRetry(rec,
            desktopHls?.rateLimitedUri ?? Uri.parse(source.url),
            received429: desktopHls?.receivedRateLimitResponse == true);
        lease?.release();
        return;
      }
      if (!rateLimited) {
        lease?.release();
        if (await _tryNext(rec)) return;
      }
      _put(
        rec.copyWith(
          status: DownloadStatus.failed,
          error: () => rateLimited
              ? downloadFailureMessage(null, statusCode: 429)
              : audioFailure ?? "Couldn't start download",
        ),
      );
      notifyListeners();
      // A rate-limited predecessor must publish its final state before FIFO
      // admits another episode; the persistent host deadline is already saved.
      lease?.release();
    }
  }

  /// Native TS→MP4 remux channel (Android only). See MainActivity + TsRemuxer.
  static const MethodChannel _downloadChannel = MethodChannel(
    'zangetsu/download',
  );

  /// Remux the concatenated-TS file at [input] into a real MP4 at [output] via
  /// the native MediaMuxer (stream-copy). Returns true on success; false on
  /// non-Android and on any native failure, so callers fall back to a `.ts`.
  Future<bool> _remuxToMp4(String input, String output) async {
    if (!Platform.isAndroid) return false;
    try {
      final ok = await _downloadChannel
          .invokeMethod<bool>('remuxTsToMp4', {
            'input': input,
            'output': output,
          })
          // MediaMuxer can sit forever on a stream it cannot parse, and a
          // native call that never returns is not an error — nothing throws,
          // the await simply never completes and the download is stuck at
          // 100% until the app is force-stopped. Falling back to the .ts
          // costs seeking; hanging costs the download.
          .timeout(_remuxTimeout, onTimeout: () => false);
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Long enough for a slow phone to stream-copy a 1080p episode, short
  /// enough that a wedged muxer doesn't hold the download all day.
  static const Duration _remuxTimeout = Duration(minutes: 5);

  /// Storage volumes downloads can target WITHOUT the SAF picker (internal +
  /// any USB/SSD/SD drive), for the TV location picker. Each is a plain
  /// app-specific external path stored as the download location. Android only;
  /// empty elsewhere.
  Future<List<({String path, String label, bool removable})>>
  listDownloadVolumes() async {
    if (!Platform.isAndroid) return const [];
    try {
      final raw = await _downloadChannel.invokeMethod<List<dynamic>>(
        'listDownloadVolumes',
      );
      if (raw == null) return const [];
      return raw.map((e) {
        final m = (e as Map).cast<String, dynamic>();
        return (
          path: m['path'] as String,
          label: (m['label'] as String?) ?? 'Storage',
          removable: (m['removable'] as bool?) ?? false,
        );
      }).toList();
    } catch (_) {
      return const [];
    }
  }

  /// Finalizes an HLS download the isolate left as a local `.ts` temp: on Android
  /// remux it into a real, seekable `.mp4` (falling back to the `.ts` if the
  /// remux can't handle the stream); iOS keeps the `.ts` (no MediaMuxer, and mpv
  /// plays a correctly-named `.ts` fine — the frame-skipping was purely the old
  /// `.mp4` mislabel). Then move the result into the custom SAF folder or public
  /// Downloads. Returns the final stored path (or the local one on move failure).
  Future<String?> _finalizeHls(
    String tsPath, {
    String? customUri,
    String? subDir,
  }) async {
    final dir = subDir ?? _sharedDir;
    // A detected drive is a plain volume path (not a content:// SAF tree) — an
    // app-specific external dir we can write to with plain File I/O. Remux the
    // .ts into a real .mp4 STRAIGHT onto the volume, avoiding a big post-move.
    final dest = videoDestination(
      // keepPrivate is read live from the singleton; `customUri` stays the
      // enqueue-time snapshot it has always been, so a mid-flight folder
      // change behaves exactly as before.
      keepPrivate: _downloadPrefs.keepPrivate,
      locationUri: customUri,
    );
    final isVolume = dest == VideoDestination.detectedVolume;
    if (isVolume && Platform.isAndroid) {
      try {
        final destDir = Directory('$customUri/$dir');
        await destDir.create(recursive: true);
        final mp4 =
            '${destDir.path}/${_withExt(tsPath.split('/').last, 'mp4')}';
        if (await _remuxToMp4(tsPath, mp4)) {
          try {
            await File(tsPath).delete();
          } catch (_) {}
          return mp4;
        }
        // Remux couldn't handle the stream → keep the .ts, on the volume.
        return await _moveToVolume(tsPath, customUri!, dir) ?? tsPath;
      } catch (_) {
        return tsPath; // volume write failed → keep the local temp
      }
    }
    if (isVolume) {
      // iOS (no MediaMuxer): just move the .ts onto the chosen location.
      return await _moveToVolume(tsPath, customUri!, dir) ?? tsPath;
    }

    // ── Picked SAF folder / default public Downloads (unchanged) ──
    var publish = tsPath; // already an honest .ts
    if (Platform.isAndroid) {
      final mp4 = _withExt(tsPath, 'mp4');
      final remuxed = mp4 != tsPath && await _remuxToMp4(tsPath, mp4);
      debugPrint(
        '[dl] HLS finalize: ${remuxed ? 'remuxed to mp4' : 'kept .ts'}',
      );
      if (remuxed) {
        publish = mp4;
        try {
          await File(tsPath).delete();
        } catch (_) {}
      }
      // Remux failed on an odd stream → keep the honestly-labelled .ts.
    }
    if (dest == VideoDestination.safTree) {
      final moved = await _moveIntoTree(
        publish,
        customUri!,
        publish.split('/').last,
      );
      return moved ?? publish;
    }
    if (dest != VideoDestination.publicDownloads) {
      // privateStorage: the remuxed file is already in app-documents.
      return publish;
    }
    try {
      final moved = await _fileDownloader.moveFileToSharedStorage(
        publish,
        SharedStorage.downloads,
        directory: dir,
      );
      return moved ?? publish;
    } catch (_) {
      return publish;
    }
  }

  /// Move a finished local file onto a detected drive (a plain app-specific
  /// external volume path — USB/SSD/SD). Cross-filesystem, so copy+delete
  /// (rename fails across mounts). Returns the new path, or null on failure so
  /// the caller keeps the local copy.
  Future<String?> _moveToVolume(
    String localPath,
    String volumeBase,
    String subDir,
  ) async {
    try {
      final dir = Directory('$volumeBase/$subDir');
      await dir.create(recursive: true);
      final dest = '${dir.path}/${localPath.split('/').last}';
      await File(localPath).copy(dest);
      try {
        await File(localPath).delete();
      } catch (_) {}
      return dest;
    } catch (_) {
      return null;
    }
  }

  /// [path] with its extension swapped to [ext] (e.g. `foo.ts` → `foo.mp4`).
  String _withExt(String path, String ext) {
    final slash = path.lastIndexOf('/');
    final dot = path.lastIndexOf('.');
    final base = dot > slash ? path.substring(0, dot) : path;
    return '$base.$ext';
  }

  /// Save this download's subtitles beside it, from both places they come in:
  /// the sidecar files a [source] advertises, and — for HLS — the subtitle
  /// renditions named in the master playlist.
  ///
  /// The second is why a downloaded episode could come back with none. An HLS
  /// stream carries its subtitles as their own rendition, nothing read the
  /// master's `#EXT-X-MEDIA:TYPE=SUBTITLES` lines, and the remux to MP4 cannot
  /// carry a subtitle track anyway — MediaMuxer refuses the format and
  /// [TsRemuxer] logs it as unsupported. Pulled out as a sidecar they survive.
  ///
  /// Best-effort: stored in private app storage, idempotent (skips if already
  /// saved), and any failure just leaves the download without sidecar subs.
  /// Snapshot barrier for service ownership handover and deterministic shutdown
  /// checks. Subtitle work stays independent of the video transfer queue.
  @visibleForTesting
  Future<void> get subtitleWorkCompleted => Future.wait(_subtitleWork.toList());

  /// Snapshot barrier for foreground worker handover; no timers or new work.
  @visibleForTesting
  Future<void> get foregroundHlsWorkCompleted =>
      Future.wait(_foregroundHlsWork.toList());

  /// Retain background jobs until settled instead of losing their lifecycle.
  void _scheduleSubtitles(DownloadRecord rec, VideoSource source) {
    if (_disposed) return;
    final work = _fetchSubtitles(rec, source).catchError((Object _) {});
    _subtitleWork.add(work);
    unawaited(work.whenComplete(() => _subtitleWork.remove(work)));
  }

  /// Stable IDs are reused on retry. Only the current media generation may
  /// publish HLS results or subtitles, including after awaited I/O or disposal.
  bool _ownsDownloadGeneration(DownloadRecord snapshot) {
    if (_disposed) return false;
    final current = _records[snapshot.id];
    return current != null &&
        current.status != DownloadStatus.canceled &&
        current.sourceId == snapshot.sourceId &&
        current.showId == snapshot.showId &&
        current.episodeId == snapshot.episodeId &&
        current.storageKey == snapshot.storageKey;
  }

  Future<void> _fetchSubtitles(DownloadRecord rec, VideoSource source) async {
    if (!_ownsDownloadGeneration(rec)) return;
    final configured = GetIt.I.isRegistered<PlaybackPrefs>()
        ? GetIt.I<PlaybackPrefs>().subtitlePreference
        : '';
    final language = configured.isEmpty
        ? PlatformDispatcher.instance.locale.languageCode
        : configured;
    if (language == 'off') return;
    final fromHls = _isHls(source);
    if (source.subtitles.isEmpty && !fromHls) return;
    final live = _records[rec.id];
    if (live == null || live.status == DownloadStatus.canceled) return;
    if (live.subtitles.isNotEmpty)
      return; // already saved (e.g. a retry mirror)
    final saved = <OfflineSubtitle>[];
    try {
      final docs = Platform.isWindows
          ? await getApplicationSupportDirectory()
          : await getApplicationDocumentsDirectory();
      if (!_ownsDownloadGeneration(rec)) return;
      final safeShow = _safe(rec.showTitle);
      final dir = Platform.isWindows
          ? Directory('${_windowsVideoDirectory(rec)}/Subtitles')
          : Directory('${docs.path}/$_sharedDir/$safeShow/subs');
      await dir.create(recursive: true);
      if (!_ownsDownloadGeneration(rec)) return;
      final subtitleStem = Platform.isWindows
          ? _mediaFileStem(rec)
          : '${safeShow}_E${rec.episodeNumber?.toInt() ?? ''}';
      var idx = 0;
      for (final sub in downloadSubtitleSelection(
        source.subtitles,
        language,
        language: (sub) => sub.lang,
        label: (sub) => sub.label ?? '',
      )) {
        if (!_ownsDownloadGeneration(rec)) return;
        if (Platform.isWindows) {
          final uri = Uri.tryParse(sub.url);
          if (uri == null || _downloadPrefs.hostCooldownUntil(uri, now: _retryScheduler.now()) != null) continue;
        }
        idx++;
        try {
          final path =
              '${dir.path}/${subtitleStem}_${_safe(sub.lang)}_$idx'
              '${_subExt(sub.url, sub.format)}';
          final resp = await _dio.get<List<int>>(
            sub.url,
            options: Options(
              responseType: ResponseType.bytes,
              headers: source.headers,
            ),
          );
          // Disposal or a fresh same-ID attempt retires this response.
          if (!_ownsDownloadGeneration(rec)) return;
          if (Platform.isWindows && resp.statusCode == 429) {
            await _rememberDownloadHostCooldown(resp.realUri, resp.headers.value('retry-after'));
            continue;
          }
          // A custom provider validator may accept error status codes; those
          // bodies are never a completed Windows subtitle file.
          if (Platform.isWindows && resp.statusCode != 200 && resp.statusCode != 206) continue;
          final bytes = resp.data;
          if (bytes == null || bytes.isEmpty) continue;
          await File(path).writeAsBytes(bytes, flush: true);
          saved.add(
            OfflineSubtitle(
              lang: sub.lang,
              label: sub.label,
              path: path,
              isDefault: sub.isDefault,
            ),
          );
        } on DioException catch (error) {
          final response = error.response;
          if (Platform.isWindows && response?.statusCode == 429) {
            await _rememberDownloadHostCooldown(response!.realUri,
                response.headers.value('retry-after'));
          }
          // Subtitles remain optional; a separate video host is unaffected.
        } catch (_) {
          /* skip this track */
        }
      }
      // HLS renditions, merged into one .vtt each. After the sidecars so an
      // explicitly advertised track wins when a stream offers both.
      if (fromHls && saved.isEmpty) {
        final seen = saved.map((s) => '${s.lang}|${s.label}').toSet();
        final subtitleDownloader = Platform.isWindows
            ? _desktopHlsDownloader()
            : HlsDownloader(_dio);
        final tracks = await subtitleDownloader.fetchSubtitleTracks(
          source.url,
          source.headers ?? const {},
          preferredLanguage: language,
          canceled: () => !_ownsDownloadGeneration(rec),
        );
        for (final t in tracks) {
          if (!_ownsDownloadGeneration(rec)) return;
          if (!seen.add('${t.lang}|${t.label}')) continue;
          idx++;
          try {
            final path = '${dir.path}/${subtitleStem}_$idx.vtt';
            await File(path).writeAsString(t.vtt, flush: true);
            saved.add(
              OfflineSubtitle(
                lang: t.lang,
                label: t.label,
                path: path,
                isDefault: t.isDefault,
              ),
            );
          } catch (_) {
            /* skip this track */
          }
        }
      }
      if (saved.isEmpty) return;
      // Re-read: the download may have been canceled/deleted while we fetched.
      if (!_ownsDownloadGeneration(rec)) return;
      final cur = _records[rec.id];
      if (cur == null) return;
      final updated = cur.copyWith(subtitles: saved);
      _put(updated);
      notifyListeners();
      if (updated.status == DownloadStatus.done) {
        await _publishExternalSubtitles(updated);
      }
    } catch (_) {
      /* no subtitles offline — non-fatal */
    } finally {
      // A disk write can finish after cancellation. Clean only this retired
      // attempt's unreferenced sidecars, never another manager's library.
      if (!_disposed && !_ownsDownloadGeneration(rec)) {
        for (final subtitle in saved) {
          if (_records.values.any(
            (record) => record.subtitles.any(
              (current) => _sameMediaPath(current.path, subtitle.path),
            ),
          ))
            continue;
          try {
            await File(subtitle.path).delete();
          } catch (_) {}
        }
      }
    }
  }

  /// Publish a public copy of saved subtitles so file-browser-launched players
  /// can discover them beside videos in Downloads. The private originals remain
  /// the app's playback/handoff source. WebVTT is converted only for the public
  /// copy because MX Player's local subtitle scanner expects common sidecar
  /// formats such as SRT.
  Future<void> _publishExternalSubtitles(DownloadRecord rec) async {
    if (_disposed || !Platform.isAndroid || isAppleTv) return;
    final current = _records[rec.id] ?? rec;
    if (current.status != DownloadStatus.done ||
        current.filePath == null ||
        !_publishingExternalSubtitles.add(current.id)) {
      return;
    }
    final processedPaths = current.subtitles.map((s) => s.path).toSet();

    Directory? stagingDir;
    try {
      final videoPath = current.filePath!;
      final privateStorage = await getApplicationDocumentsDirectory();
      final destination = externalSubtitleDestination(
        videoPath: videoPath,
        privateStorageRoot: privateStorage.path,
        locationUri: _downloadPrefs.locationUri,
      );
      if (destination == ExternalSubtitleDestination.privateStorage) {
        return;
      }
      final safTreeUri =
          externalSubtitleTreeUri(videoPath) ??
          (_downloadPrefs.locationUri?.startsWith('content://') == true
              ? _downloadPrefs.locationUri
              : null);
      if (destination == ExternalSubtitleDestination.safTree &&
          safTreeUri == null) {
        return;
      }
      final directory = '$_sharedDir/${_safe(current.showTitle)}';
      final temp = await getTemporaryDirectory();
      stagingDir = Directory(
        '${temp.path}/external_subtitles/${_safe(current.id)}',
      );
      await stagingDir.create(recursive: true);

      final duplicateLangs = <String, int>{};
      for (final subtitle in current.subtitles) {
        final safeLang = subtitle.lang.trim().replaceAll(
          RegExp(r'[^A-Za-z0-9_-]'),
          '_',
        );
        duplicateLangs[safeLang] = (duplicateLangs[safeLang] ?? 0) + 1;
      }
      final seenLangs = <String, int>{};

      for (final subtitle in current.subtitles) {
        if (subtitle.publicPath != null &&
            await _publicSubtitleExists(subtitle.publicPath!)) {
          continue;
        }
        final source = File(subtitle.path);
        if (!await source.exists()) continue;

        final safeLang = subtitle.lang.trim().replaceAll(
          RegExp(r'[^A-Za-z0-9_-]'),
          '_',
        );
        final index = (seenLangs[safeLang] ?? 0) + 1;
        seenLangs[safeLang] = index;
        final ext = publicSubtitleExtension(subtitle.path);
        var filename = externalSubtitleFileName(
          videoPath: videoPath,
          language: subtitle.lang,
          extension: ext,
        );
        if ((duplicateLangs[safeLang] ?? 0) > 1) {
          final dot = filename.lastIndexOf('.');
          filename =
              '${filename.substring(0, dot)}_$index${filename.substring(dot)}';
        }

        final staged = File('${stagingDir.path}/$filename');
        final sourceBytes = await source.readAsBytes();
        if (subtitle.path.toLowerCase().endsWith('.vtt')) {
          final converted = webVttToSrt(
            utf8.decode(sourceBytes, allowMalformed: true),
          );
          if (converted.isEmpty) continue;
          await staged.writeAsString(converted, flush: true);
        } else {
          await staged.writeAsBytes(sourceBytes, flush: true);
        }

        String? publicPath;
        if (destination == ExternalSubtitleDestination.besideVideo) {
          final target = File('${File(videoPath).parent.path}/$filename');
          try {
            if (await target.exists()) await target.delete();
            publicPath = (await staged.copy(target.path)).path;
          } catch (_) {}
        } else if (destination == ExternalSubtitleDestination.safTree) {
          publicPath = await _moveIntoTree(
            staged.path,
            safTreeUri!,
            filename,
            mimeType: _subtitleMimeType(ext),
          );
        } else {
          // Android assigns an indexed name when a MediaStore item with the
          // same name already exists. Remove it first so re-downloads keep one
          // predictable filename next to the episode.
          String? existing;
          try {
            existing = await _fileDownloader.pathInSharedStorage(
              staged.path,
              SharedStorage.downloads,
              directory: directory,
            );
          } catch (_) {}
          if (existing != null) {
            try {
              await _fileDownloader.uri.deleteFile(Uri.parse(existing));
            } catch (_) {}
          }

          publicPath = await _fileDownloader.moveFileToSharedStorage(
            staged.path,
            SharedStorage.downloads,
            directory: directory,
            mimeType: _subtitleMimeType(ext),
          );
        }
        if (publicPath == null) continue;

        // The record could have been deleted while MediaStore was writing.
        final latest = _records[current.id];
        if (latest == null || latest.status == DownloadStatus.canceled) {
          await _deleteMediaFile(publicPath);
          return;
        }
        final subtitles = latest.subtitles
            .map(
              (item) => item.path == subtitle.path
                  ? item.copyWith(publicPath: publicPath)
                  : item,
            )
            .toList();
        if (_disposed) return;
        _put(latest.copyWith(subtitles: subtitles));
        notifyListeners();
      }
    } catch (e) {
      AppLogger.instance.log(
        '[download] could not publish subtitle sidecar: $e',
        level: 'W',
      );
    } finally {
      if (stagingDir != null) {
        try {
          if (await stagingDir.exists()) {
            await stagingDir.delete(recursive: true);
          }
        } catch (_) {}
      }
      _publishingExternalSubtitles.remove(rec.id);
    }

    // A subtitle fetch can finish while this publisher is waiting on storage.
    // It will see the in-flight guard and return, so pick up tracks added after
    // the snapshot without retrying a failed publication forever.
    final latest = _records[rec.id];
    if (latest != null &&
        latest.status == DownloadStatus.done &&
        latest.subtitles.any((s) => !processedPaths.contains(s.path))) {
      await _publishExternalSubtitles(latest);
    }
  }

  Future<bool> _publicSubtitleExists(String path) async {
    try {
      if (isUriPath(path)) return await _documentExists(path);
      return await File(path).exists();
    } catch (_) {
      return false;
    }
  }

  String _subtitleMimeType(String extension) => switch (extension) {
    '.srt' => 'application/x-subrip',
    '.vtt' => 'text/vtt',
    '.ass' || '.ssa' => 'text/x-ssa',
    _ => 'application/octet-stream',
  };

  // ── Controls ───────────────────────────────────────────────────────────────

  Future<void> pause(DownloadRecord rec) async {
    final current = _records[rec.id];
    if (Platform.isWindows && current?.autoResumePending == true &&
        const {DownloadStatus.queued, DownloadStatus.resolving}.contains(current?.status) &&
        !_tasks.containsKey(rec.id)) {
      _retryScheduler.cancel(rec.id);
      _desktopTransferSlots?.cancelPending(rec.id);
      _put(current!.copyWith(status: DownloadStatus.paused));
      notifyListeners();
      return;
    }
    if (Platform.isWindows && current?.pendingAudioFinalization == true) {
      // Stop a local worker rather than asking a completed HTTP task to pause.
      // Active workers release their lease after cleanup; queued ones leave FIFO.
      _pendingAudioResumes.remove(rec.id);
      _desktopTransferSlots?.cancelPending(rec.id);
      _put(current!.copyWith(status: DownloadStatus.paused));
      notifyListeners();
      return;
    }
    if (rec.isTorrent) {
      try {
        await _torrentSvc.pause(rec.id);
      } catch (_) {}
      _put(rec.copyWith(status: DownloadStatus.paused));
      notifyListeners();
      return;
    }
    final t = _tasks[rec.id];
    if (t != null) await _fileDownloader.pause(t);
  }

  Future<void> resume(DownloadRecord rec) async {
    if (Platform.isWindows && !rec.isTorrent) await _awaitDesktopRecovery();
    if (Platform.isWindows && !_ownsDownloadGeneration(rec)) return;
    if (Platform.isWindows && _records[rec.id]?.retryAt != null) {
      final waiting = _records[rec.id]!.copyWith(status: DownloadStatus.queued);
      await _box.put(waiting.id, waiting.toMap());
      if (!_ownsDownloadGeneration(waiting)) return;
      _records[waiting.id] = waiting;
      _armPendingRetry(waiting);
      notifyListeners();
      return;
    }
    if (rec.isTorrent) {
      try {
        await _torrentSvc.resume(rec.id);
      } catch (_) {}
      _put(rec.copyWith(status: DownloadStatus.downloading));
      notifyListeners();
      return;
    }
    if (Platform.isWindows && rec.pendingAudioFinalization) {
      await _resumeLocalAudio(rec);
      return;
    }
    final t = _tasks[rec.id];
    if (t != null) {
      if (Platform.isWindows && await _hostCooldownBlocks(rec, t.url)) return;
      final lease = Platform.isWindows
          ? await _desktopSlots.acquire(rec.id)
          : null;
      if (Platform.isWindows && lease == null) return;
      if (_isCanceled(rec.id)) {
        lease?.release();
        return;
      }
      if (Platform.isWindows && await _hostCooldownBlocks(rec, t.url)) {
        lease?.release();
        return;
      }
      try {
        final started = await _fileDownloader.resume(t);
        if (!started) lease?.release();
      } catch (_) {
        lease?.release();
        rethrow;
      }
    } else {
      // Task object lost (e.g. after restart) — re-resolve and enqueue.
      await _resolveAndEnqueue(rec.copyWith(status: DownloadStatus.queued));
    }
  }

  /// Resume only an explicitly checkpointed, complete local file. This shares
  /// transfer capacity and must not resolve providers or reuse expired URLs.
  Future<void> _resumeLocalAudio(DownloadRecord rec) async {
    if (_records[rec.id]?.pendingAudioFinalization != true) return;
    if (_finalizingFiles.contains(rec.id)) {
      // Remember a rapid resume while the paused worker is still cleaning up.
      if (_records[rec.id]?.status == DownloadStatus.paused) {
        _pendingAudioResumes.add(rec.id);
      }
      return;
    }
    if (_desktopSlots.contains(rec.id) || _isCanceled(rec.id) || _disposed) {
      return;
    }
    _put(rec.copyWith(status: DownloadStatus.queued, error: () => null));
    notifyListeners();
    final lease = await _desktopSlots.acquire(rec.id);
    if (lease == null) return;
    final finished = Completer<void>();
    _finalizationDone[rec.id] = finished;
    _finalizingFiles.add(rec.id);
    try {
      if (_disposed || _isCanceled(rec.id)) return;
      final path = rec.filePath;
      final recovery = path == null
          ? null
          : await FileAudioTransaction.recover(path);
      if (_disposed || _isCanceled(rec.id)) return;
      if (recovery != null || path == null || !await File(path).exists()) {
        _put(
          rec.copyWith(
            status: DownloadStatus.failed,
            error: () =>
                recovery ??
                'The downloaded file is missing. Retry to download it again.',
          ),
        );
        return;
      }
      if (await _selectLocalAudio(rec, path)) await _markDone(rec, path);
    } finally {
      _finalizingFiles.remove(rec.id);
      lease.release();
      _finalizationDone.remove(rec.id);
      finished.complete();
      _restartRequestedAudio(rec.id);
      if (!_disposed) notifyListeners();
    }
  }

  /// A stable episode ID may be reused only after its former media operation
  /// has stopped touching files and released its lease. Cancellation remains
  /// visible while callers wait, so a replacement cannot revive the old worker.
  Future<bool> _waitForFinalization(String id) async {
    while (!_disposed) {
      final deleting = _deletionDone[id];
      if (deleting != null) { await deleting.future; continue; }
      final finished = _finalizationDone[id];
      if (finished != null) { await finished.future; continue; }
      return true;
    }
    return false;
  }

  /// Start one remembered resume only after the former worker released its
  /// lease. A later Pause, Cancel, disposal or deletion revokes this request.
  void _restartRequestedAudio(String id) {
    if (!_pendingAudioResumes.remove(id) || _disposed) return;
    final rec = _records[id];
    if (rec?.status != DownloadStatus.paused ||
        !rec!.pendingAudioFinalization) {
      return;
    }
    unawaited(_resumeLocalAudio(rec));
  }

  /// Re-download a failed record from scratch: forget any stale mirror list,
  /// clear the error, and resolve a fresh source. No-op for done/active
  /// downloads and for torrents (those are re-added from the detail screen).
  Future<void> retry(DownloadRecord rec) async {
    if (_records[rec.id]?.isActive == true) return;
    if (Platform.isWindows && !await _waitForFinalization(rec.id)) return;
    final current = _records[rec.id];
    if (current == null) return;
    rec = current;
    if (rec.isTorrent || rec.status == DownloadStatus.done || rec.isActive) {
      return;
    }
    _candidates.remove(rec.id); // resolve fresh mirrors
    await _resolveAndEnqueue(
      rec.copyWith(
        status: DownloadStatus.queued,
        storageKey: Platform.isWindows ? _randomNonce() : rec.storageKey,
        downloadRoot: Platform.isWindows
            ? _downloadPrefs.locationUri
            : rec.downloadRoot,
        error: () => null,
        pendingAudioFinalization: false,
        filePath: () => null,
        retainedMediaPaths: {
          ...rec.retainedMediaPaths,
          if (rec.filePath != null) rec.filePath!,
        }.toList(),
      ),
    );
  }

  Future<void> cancel(DownloadRecord rec) async {
    _retryScheduler.cancel(rec.id);
    final nativeLease =
        _tasks.containsKey(rec.id) && !_finalizingFiles.contains(rec.id)
        ? _desktopTransferSlots?.activeLease(rec.id)
        : null;
    _candidates.remove(rec.id); // user stopped it — don't auto-advance mirrors
    // Mark canceled FIRST so any in-flight resolve/update sees it and bails
    // (otherwise a resolve finishing after cancel would re-enqueue, leaving the
    // tile stuck "loading" despite saying canceled).
    _put(rec.copyWith(status: DownloadStatus.canceled, progress: 0));
    notifyListeners();
    if (rec.isTorrent) {
      try {
        await _torrentSvc.cancel(rec.id);
      } catch (_) {}
      torrentProgress.remove(rec.id);
      nativeLease?.release();
      _tasks.remove(rec.id);
      return;
    }
    _desktopTransferSlots?.cancelPending(rec.id);
    _mp4Queue.removeTasksWithIds([rec.id]); // drop it if still waiting in line
    try {
      await _fileDownloader.cancelTaskWithId(
        rec.id,
      ); // direct-file task (if enqueued/running)
    } catch (_) {}
    if (!isAppleTv) {
      try {
        await (await DownloadService.jobJournal()).remove(rec.id);
      } catch (_) {}
      try {
        DownloadService.instance.invoke('cancel', {
          'id': rec.id,
        }); // HLS job (if any)
      } catch (_) {}
    }
    nativeLease?.release();
    _tasks.remove(rec.id);
  }

  bool _isCanceled(String id) =>
      _records[id]?.status == DownloadStatus.canceled ||
      !_records.containsKey(id); // deleted

  /// Cancel (if active) and forget the record + delete the saved file.
  Future<void> delete(DownloadRecord rec) async {
    if (!Platform.isWindows) return _deleteRecord(rec);
    if (_disposed) return;
    final retiring = _deletionDone[rec.id];
    if (retiring != null) { await retiring.future; return; }
    final current = _records[rec.id];
    // Confirmation may outlive a retry/new download with the same stable ID.
    if (current == null || current.storageKey != rec.storageKey) return;
    final finished = Completer<void>();
    _deletionDone[rec.id] = finished;
    try {
      await _deleteRecord(current);
    } finally {
      _deletionDone.remove(rec.id);
      finished.complete();
    }
  }

  /// Executes one deletion while its Windows ID barrier prevents replacement.
  Future<void> _deleteRecord(DownloadRecord rec) async {
    _retryScheduler.cancel(rec.id);
    final nativeLease =
        _tasks.containsKey(rec.id) && !_finalizingFiles.contains(rec.id)
        ? _desktopTransferSlots?.activeLease(rec.id)
        : null;
    _candidates.remove(rec.id);
    _desktopTransferSlots?.cancelPending(rec.id);
    final current = _records[rec.id];
    if (current != null && current.status != DownloadStatus.canceled) {
      // Stop late callbacks/resolvers before cleanup awaits give them a chance
      // to persist progress or completion over the delete operation.
      _put(current.copyWith(status: DownloadStatus.canceled, progress: 0));
      notifyListeners();
    }
    if (rec.isTorrent) {
      try {
        await _torrentSvc.cancel(rec.id);
      } catch (_) {}
      torrentProgress.remove(rec.id);
    }
    try {
      await _fileDownloader.cancelTaskWithId(rec.id);
    } catch (_) {}
    if (!isAppleTv) {
      try {
        await (await DownloadService.jobJournal()).remove(rec.id);
      } catch (_) {}
      try {
        DownloadService.instance.invoke('cancel', {
          'id': rec.id,
        }); // stop HLS job
      } catch (_) {}
    }
    nativeLease?.release();
    _tasks.remove(rec.id);
    // Remove any saved subtitle sidecar files too.
    for (final s in rec.subtitles) {
      try {
        final f = File(s.path);
        if (await f.exists()) await f.delete();
      } catch (_) {}
      if (s.publicPath != null) await _deleteMediaFile(s.publicPath);
    }
    // Delete the actual media file on disk. Two cases:
    //  • SAF custom folder → a content:// URI, removed via UriUtils.
    //  • Default download (public Download/Zangetsu) → a plain file path the
    //    app owns. Previously ONLY the content:// case was handled, so default
    //    downloads left the file on disk (the "still in the folder" bug). Delete
    //    it directly; if scoped storage blocks the raw delete, fall back to the
    //    plugin's native (MediaStore-aware) delete. Then drop the empty show dir.
    for (final path in {
      rec.filePath,
      current?.filePath,
      rec.supersededPath,
      current?.supersededPath,
      ...rec.retainedMediaPaths,
      ...?current?.retainedMediaPaths,
    }.whereType<String>()) {
      await _deleteUnreferencedMedia(path, rec.id);
    }
    _records.remove(rec.id);
    await _box.delete(rec.id);
    notifyListeners();
  }

  /// Delete every download in [recs] — a whole show group in one go. Cancels
  /// active ones, removes the records + files. Best-effort per item (one
  /// failure never blocks the rest); snapshots first since [delete] mutates the
  /// record map as it goes.
  Future<void> deleteAll(Iterable<DownloadRecord> recs) async {
    for (final r in recs.toList()) {
      try {
        await delete(r);
      } catch (_) {}
    }
    notifyListeners();
  }

  static const MethodChannel _deviceChannel = MethodChannel(
    'com.spyou.watch_app/device',
  );

  /// Does a SAF `content://` download still exist? Checked natively via
  /// DocumentFile (Dart can't stat a content:// URI). Returns true on any
  /// uncertainty so a valid download is never wrongly pruned.
  Future<bool> _documentExists(String uri) async {
    try {
      final r = await _deviceChannel.invokeMethod<bool>('documentExists', {
        'uri': uri,
      });
      return r ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Byte size of a SAF content:// document (-1 if unknown), via native
  /// DocumentFile — Dart can't stat a content:// URI.
  Future<int> _documentSize(String uri) async {
    try {
      final r = await _deviceChannel.invokeMethod<int>('documentSize', {
        'uri': uri,
      });
      return r ?? -1;
    } catch (_) {
      return -1;
    }
  }

  /// Move a finished local file into a user-picked SAF tree (via native
  /// DocumentFile — works without a foreground activity). Returns the new
  /// content:// URI, or null on failure so the caller keeps the local path.
  Future<String?> _moveIntoTree(
    String localPath,
    String treeUri,
    String filename, {
    String mimeType = 'video/mp4',
  }) async {
    try {
      return await _deviceChannel.invokeMethod<String>('moveIntoTree', {
        'localPath': localPath,
        'treeUri': treeUri,
        'filename': filename,
        'mimeType': mimeType,
      });
    } catch (_) {
      return null;
    }
  }

  /// Reconcile the list with disk: drop `done` records whose file was removed
  /// OUTSIDE the app (a file manager), so the UI can't show phantom downloads.
  /// Handles BOTH default downloads (plain file path — a cheap `exists` syscall)
  /// and custom-folder SAF downloads (content:// — via native DocumentFile).
  /// Skips in-flight records; emits a single [notifyListeners] if anything went.
  // ponytail: deliberately reads ONLY rec.filePath — never DownloadPrefs, and
  // never moves a file. That is what makes flipping keepPrivate safe for a user
  // with 20 finished public downloads: their records still stat true and
  // survive untouched. Do NOT "improve" this by consulting keepPrivate here to
  // migrate them. Relocating existing files needs per-file copy, progress,
  // failure rollback and record rewriting; it is a separate feature, and the
  // toggle says "applies to new downloads" for exactly this reason.
  Future<void> pruneMissing() async {
    if (_disposed) return;
    final gone = <DownloadRecord>[];
    // Downloads that finished before the size was recorded on completion. They
    // sat at "0 B" forever and dragged the storage total down with them, so
    // measure them here — this already stats every file, so it costs nothing
    // extra. Collected and applied after the loop rather than written inline,
    // to avoid mutating the map being iterated.
    final measured = <DownloadRecord>[];
    // A file check yields to user actions: never mutate an entry replaced since
    // this snapshot, even when its stable ID and storage generation match.
    final snapshot = _records.values.toList();
    for (final rec in snapshot) {
      if (_disposed) return;
      final missing = Platform.isWindows && rec.status == DownloadStatus.failed &&
          rec.error == missingSavedDownloadMessage;
      if (rec.status != DownloadStatus.done && !missing) continue;
      final fp = rec.filePath;
      if (fp == null || fp.isEmpty) continue;
      try {
        if (isUriPath(fp)) {
          if (!await _documentExists(fp)) gone.add(rec);
          continue;
        }
        final f = File(fp);
        if (await f.exists()) {
          if (missing) {
            measured.add(rec.copyWith(status: DownloadStatus.done,
                bytesTotal: await sizeOf(fp) ?? rec.bytesTotal, error: () => null));
          } else if (rec.bytesTotal <= 0) {
            final len = await sizeOf(fp);
            if (len != null) measured.add(rec.copyWith(bytesTotal: len));
          }
          continue; // file present → keep
        }
        // Storage is "available" if ANY ancestor dir still exists (walk up), so
        // a missing file means it was deleted — not that the volume is unmounted.
        var storageOk = false;
        var d = f.parent;
        for (var i = 0; i < 8; i++) {
          if (await d.exists()) {
            storageOk = true;
            break;
          }
          final up = d.parent;
          if (up.path == d.path) break;
          d = up;
        }
        if (storageOk) gone.add(rec);
      } catch (_) {}
    }
    if (measured.isNotEmpty) {
      for (final rec in measured) {
        final original = snapshot.firstWhere((r) => r.id == rec.id);
        if (_disposed) return;
        if (!identical(_records[rec.id], original)) continue;
        _put(rec);
      }
      notifyListeners();
    }
    if (gone.isEmpty) return;
    for (final original in gone) {
      if (_disposed) return;
      final id = original.id;
      if (!identical(_records[id], original)) continue;
      if (Platform.isWindows) {
        final current = original;
        // Keep identity, original path and progress across updates/offline drives.
        // Reappearing files can be recognized instead of losing the only index.
        final missing = current.copyWith(status: DownloadStatus.failed,
            error: () => missingSavedDownloadMessage);
        // Publish before awaiting storage so a later user action wins in both
        // memory and ordered Hive writes; never overwrite it after the await.
        _records[id] = missing;
        await _box.put(id, missing.toMap());
        if (_disposed) return;
        continue;
      }
      _records.remove(id);
      _candidates.remove(id);
      _tasks.remove(id);
      await _box.delete(id);
    }
    notifyListeners();
  }

  // ── Update stream ──────────────────────────────────────────────────────────

  /// Task equality compares stable IDs only, so callbacks need an attempt tag.
  /// Legacy restored tasks without our tag retain their serialized identity.
  static bool _sameNativeAttempt(Task active, Task incoming) {
    if (active.metaData.startsWith('zangetsu-attempt:')) {
      return active.metaData == incoming.metaData;
    }
    return active.url == incoming.url &&
        active.filename == incoming.filename &&
        active.directory == incoming.directory &&
        active.taskType == incoming.taskType &&
        active.creationTime.millisecondsSinceEpoch ==
            incoming.creationTime.millisecondsSinceEpoch;
  }

  /// Random, non-secret nonce survives native queue/retry serialization.
  static String _nativeAttemptToken() => 'zangetsu-attempt:${_randomNonce()}';

  /// Independent non-secret identifiers for file generations/native attempts.
  static String _randomNonce() {
    final random = Random.secure();
    return base64Url.encode(List<int>.generate(18, (_) => random.nextInt(256)));
  }

  Future<void> _onUpdate(TaskUpdate update) async {
    final id = update.task.taskId;
    if (Platform.isWindows) {
      // Restored native inventory defines ownership before callbacks are read.
      try {
        await _awaitDesktopRecovery();
      } catch (_) {
        return;
      }
      if (_disposed) return;
      final active = _tasks[id];
      if (active == null || !_sameNativeAttempt(active, update.task)) return;
      // HTTP callbacks no longer own media processing or published files.
      if (_finalizingFiles.contains(id) ||
          _records[id]?.status == DownloadStatus.done) {
        return;
      }
    }

    // Capture the attempt's lease before any cooldown persistence await. An
    // old callback must never release a new same-ID replacement's capacity.
    final terminalLease = Platform.isWindows ? _desktopTransferSlots?.activeLease(id) : null;
    if (Platform.isWindows &&
        update is TaskStatusUpdate &&
        const {
          TaskStatus.failed,
          TaskStatus.notFound,
          TaskStatus.canceled,
          TaskStatus.paused,
        }.contains(update.status)) {
      // Publish the host deadline before releasing capacity to a waiting job.
      // The downloader normalizes response-header names to lowercase.
      if (update.status == TaskStatus.failed || update.status == TaskStatus.notFound) {
        final exception = update.exception;
        final code = update.responseStatusCode ??
            (exception is TaskHttpException ? exception.httpResponseCode : null);
        if (isDownloadRateLimit(exception?.description, statusCode: code)) {
          final uri = Uri.tryParse(update.task.url);
          if (uri != null) {
            try {
              await _rememberDownloadHostCooldown(uri, update.responseHeaders?['retry-after']);
              final waiting = _records[id];
              if (waiting != null) {
                await _queueHostRetry(waiting, uri, received429: true);
              }
              terminalLease?.release();
              return;
            } catch (_) {
              // A storage failure must not strand the transfer lease or hide429.
              AppLogger.instance.log('[download] Could not save host cooldown', level: 'E');
            }
          }
        }
      }
      terminalLease?.release();
    }
    final rec = _records[id];
    if (rec == null) {
      if (update is TaskStatusUpdate && update.status == TaskStatus.complete) {
        _desktopSlots.release(id);
      }
      return;
    }
    // Ignore late updates for a download the user canceled/deleted, so a
    // trailing progress/running event can't flip it back to "downloading".
    if (rec.status == DownloadStatus.canceled) {
      _desktopSlots.release(id);
      return;
    }
    if (_finalizingFiles.contains(id)) return;

    if (update is TaskProgressUpdate) {
      if (update.progress >= 0) {
        _put(
          rec.copyWith(
            status: DownloadStatus.downloading,
            progress: update.progress,
            bytesTotal: update.expectedFileSize > 0
                ? update.expectedFileSize
                : null,
          ),
        );
        notifyListeners();
      }
      return;
    }

    if (update is TaskStatusUpdate) {
      switch (update.status) {
        case TaskStatus.enqueued:
          _put(rec.copyWith(status: DownloadStatus.queued));
        case TaskStatus.running:
          _put(rec.copyWith(status: DownloadStatus.downloading));
        case TaskStatus.paused:
          _put(rec.copyWith(status: DownloadStatus.paused));
        case TaskStatus.complete:
          final lease = _desktopSlots.activeLease(id);
          final finished = Completer<void>();
          _finalizationDone[id] = finished;
          _finalizingFiles.add(id);
          try {
            await _finish(rec, update.task as DownloadTask, update.mimeType);
          } finally {
            _finalizingFiles.remove(id);
            lease?.release();
            _finalizationDone.remove(id);
            finished.complete();
            _restartRequestedAudio(id);
          }
        case TaskStatus.canceled:
          _put(rec.copyWith(status: DownloadStatus.canceled));
        case TaskStatus.notFound:
        case TaskStatus.failed:
          final exception = update.exception;
          final httpCode = update.responseStatusCode ??
              (exception is TaskHttpException ? exception.httpResponseCode : null);
          final rateLimited = isDownloadRateLimit(
              exception?.description, statusCode: httpCode);
          final failureMessage = downloadFailureMessage(
              exception?.description, statusCode: httpCode);
          if (!rateLimited && Platform.isWindows &&
              update.task is ParallelDownloadTask &&
              _singleConnectionIds.add(rec.id)) {
            // A host can change range behavior after probing. Retry this same
            // selected stream once without chunks before trying other mirrors.
            await _enqueueTaskFor(
              rec,
              VideoSource(
                url: update.task.url,
                headers: update.task.headers,
                container: SourceContainer.mp4,
              ),
            );
            return;
          }
          AppLogger.instance.log(
            '[download] MP4 ${update.status.name} — ${rec.showTitle} · '
            '${rec.episodeTitle} [${rec.quality}]: '
            '${failureMessage}',
            level: 'E',
          );
          if (!rateLimited && await _tryNext(rec)) return; // avoid retry storms
          _put(
            rec.copyWith(
              status: DownloadStatus.failed,
              error: () => failureMessage,
            ),
          );
        case TaskStatus.waitingToRetry:
          _put(rec.copyWith(status: DownloadStatus.downloading));
      }
      // Finalization can finish after the UI has replaced this manager.
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _finish(
    DownloadRecord rec,
    DownloadTask task,
    String? mimeType,
  ) async {
    String? path;

    if (task is UriDownloadTask) {
      // Custom-folder download: the file streamed straight into the user's
      // picked SAF folder, so it's already published as a content:// URI.
      path = task.fileUri?.toString();
      if (path == null) {
        _desktopSlots.release(rec.id);
        if (await _tryNext(rec)) return;
        _put(
          rec.copyWith(
            status: DownloadStatus.failed,
            error: () => "Couldn't save to the chosen folder",
          ),
        );
        notifyListeners();
        return;
      }
      // Same content-guard as the default path, but via a native size check
      // (Dart can't stat content://). A tiny file is a stub, NOT a video — e.g.
      // MovieBox streams DASH and hands back a ~95 KB `.mpd` manifest. Bin it and
      // try the next mirror; only reject on a CONFIDENT small size (>0), so an
      // unknown size (-1) never discards a real download.
      final size = await _documentSize(path);
      if (size > 0 && size < 524288) {
        try {
          await _fileDownloader.uri.deleteFile(Uri.parse(path));
        } catch (_) {}
        _desktopSlots.release(rec.id);
        if (await _tryNext(rec)) return;
        _put(
          rec.copyWith(
            status: DownloadStatus.failed,
            error: () =>
                "This source can't be downloaded (stream-only / DASH) — "
                'try a different server',
          ),
        );
        notifyListeners();
        return;
      }
    } else {
      // Content guard: if the server handed back a web/landing page instead of
      // a video (the 4khdhub HubCloud/gamerxyt case), don't keep it.
      final mt = (mimeType ?? '').toLowerCase();
      final looksHtml = mt.contains('html') || mt.startsWith('text/');
      int size = 0;
      try {
        final f = File(await task.filePath());
        if (await f.exists()) size = await f.length();
        if (looksHtml || (size > 0 && size < 524288)) {
          // <512KB or HTML → not a real video file; bin it and try the next
          // mirror before giving up.
          if (await f.exists()) await f.delete();
          _desktopSlots.release(rec.id);
          if (await _tryNext(rec)) return;
          _put(
            rec.copyWith(
              status: DownloadStatus.failed,
              error: () =>
                  'That server returned a web page, not a video — '
                  'try a different server',
            ),
          );
          return;
        }
      } catch (_) {}

      final subDir = '$_sharedDir/${_safe(rec.showTitle)}';
      final dest = videoDestination(
        keepPrivate: _downloadPrefs.keepPrivate,
        locationUri: _downloadPrefs.locationUri,
      );
      if (Platform.isWindows) {
        path = await task.filePath();
      } else if (dest == VideoDestination.detectedVolume) {
        // Detected drive (USB/SSD/SD): move the file onto that volume.
        path = await _moveToVolume(
          await task.filePath(),
          _downloadPrefs.locationUri!,
          subDir,
        );
      } else if (dest == VideoDestination.publicDownloads) {
        try {
          path = await _fileDownloader.moveToSharedStorage(
            task,
            SharedStorage.downloads,
            directory: subDir,
          );
        } catch (_) {}
      }
      // privateStorage: the temp already lives in app-documents, so there is
      // nothing to move and `path` stays null. safTree is unreachable here — a
      // content:// location makes _enqueueTaskFor build a UriDownloadTask, and
      // that case returns earlier in this method. Either way the fallback below
      // adopts the private path, which is also the move-failure fallback.
      path ??= await task.filePath();
    }

    if (Platform.isWindows &&
        rec.serverPreference?.audioLanguage != null &&
        !await _selectLocalAudio(rec, path)) {
      return;
    }

    _candidates.remove(rec.id); // success — no more fallbacks needed
    await _markDone(rec, path);
  }

  /// Finish a complete local file without changing its download identity.
  Future<bool> _selectLocalAudio(DownloadRecord rec, String path) async {
    final language = rec.serverPreference?.audioLanguage;
    if (language == null || language.isEmpty) {
      _put(
        rec.copyWith(
          status: DownloadStatus.failed,
          error: () =>
              'Saved audio selection is unavailable. Retry to download again.',
        ),
      );
      notifyListeners();
      return false;
    }
    // A complete HTTP transfer is not complete media: select the actual
    // spoken track before publishing success, holding the shared queue lease.
    final checkpoint = rec.copyWith(
      status: DownloadStatus.finalizing,
      progress: 1,
      filePath: () => path,
      pendingAudioFinalization: true,
    );
    _records[rec.id] = checkpoint;
    // This write is awaited exactly once. A failed disk write must not start
    // mutation or be followed by an unhandled fire-and-forget retry.
    try {
      if (_writeAudioCheckpoint != null) {
        await _writeAudioCheckpoint(checkpoint);
      } else {
        await _box.put(rec.id, checkpoint.toMap());
      }
    } catch (_) {
      if (!_disposed && _records[rec.id]?.status == DownloadStatus.finalizing) {
        // Storage is unavailable, so this error is deliberately memory-only.
        _records[rec.id] = checkpoint.copyWith(
          status: DownloadStatus.failed,
          error: () =>
              'Could not save download recovery data. Check storage and resume.',
        );
        notifyListeners();
      }
      return false;
    }
    if (_disposed) return false;
    notifyListeners();
    String? failure;
    try {
      failure = await _fileAudio.finalize(
        path,
        language,
        () =>
            _disposed ||
            _isCanceled(rec.id) ||
            _records[rec.id]?.status == DownloadStatus.paused,
      );
    } catch (_) {
      // Cleanup/decoder failures must not escape an async native callback.
      // Raw diagnostics may include private file paths or signed URLs.
      failure =
          'Audio processing could not finish. Resume or retry this download.';
    }
    // A replacement manager recovers the persisted job. The old instance
    // must neither publish success nor delete recoverable media on disposal.
    if (_disposed) return false;
    if (_isCanceled(rec.id)) {
      await _deleteMediaFile(path);
      final current = _records[rec.id];
      if (current?.status == DownloadStatus.canceled) {
        _put(
          current!.copyWith(
            filePath: () => null,
            pendingAudioFinalization: false,
          ),
        );
      }
      return false;
    }
    // Pausing is resumable and keeps the complete local file and its marker.
    if (_records[rec.id]?.status == DownloadStatus.paused) return false;
    if (failure != null) {
      _put(
        rec.copyWith(
          status: DownloadStatus.failed,
          error: () => failure,
          filePath: () => path,
          pendingAudioFinalization: true,
        ),
      );
      notifyListeners();
      return false;
    }
    return true;
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  /// Retry cleanup must not erase a file still owned by another library entry.
  Future<void> _deleteUnreferencedMedia(String? path, String ownerId) async {
    if (path == null || path.isEmpty) return;
    if (_records.values.any(
      (record) =>
          record.id != ownerId &&
          ((record.filePath != null &&
                  _sameMediaPath(record.filePath!, path)) ||
              (record.supersededPath != null &&
                  _sameMediaPath(record.supersededPath!, path)) ||
              record.retainedMediaPaths.any(
                (saved) => _sameMediaPath(saved, path),
              )),
    )) {
      return;
    }
    // An active native transfer owns its destination even before the final
    // filePath has been published on its library record.
    for (final task in _tasks.values.toList()) {
      if (task.taskId == ownerId) continue;
      try {
        if (_sameMediaPath(await task.filePath(), path)) return;
      } catch (_) {
        return; // Unknown transport destination: keep the recoverable copy.
      }
    }
    await _deleteMediaFile(path);
  }

  /// Delete a downloaded media file. Two cases:
  ///  • SAF custom folder → a content:// URI, removed via UriUtils.
  ///  • Default download (public Download/Zangetsu) → a plain file path the
  ///    app owns. Previously ONLY the content:// case was handled, so default
  ///    downloads left the file on disk (the "still in the folder" bug). Delete
  ///    it directly; if scoped storage blocks the raw delete, fall back to the
  ///    plugin's native (MediaStore-aware) delete. Then drop the empty show dir.
  Future<void> _deleteMediaFile(String? fp) async {
    if (fp == null || fp.isEmpty) return;
    try {
      if (isUriPath(fp)) {
        await _fileDownloader.uri.deleteFile(Uri.parse(fp));
      } else {
        final f = File(fp);
        try {
          if (await f.exists()) await f.delete();
        } catch (_) {}
        if (await f.exists()) {
          try {
            await _fileDownloader.uri.deleteFile(f.uri);
          } catch (_) {}
        }
        try {
          final dir = f.parent;
          if (await dir.exists() && await dir.list().isEmpty) {
            await dir.delete();
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Size of a finished download, or null to leave what's already recorded.
  ///
  /// Only the background_downloader path reports a size (via
  /// `expectedFileSize`), so HLS — which is fetched in-app and remuxed — always
  /// finished at 0 and the storage total under-counted every anime source.
  /// A content:// URI can't be stat'd, so those keep whatever they had.
  @visibleForTesting
  static Future<int?> sizeOf(String? path) async {
    if (path == null || path.isEmpty || isUriPath(path)) return null;
    try {
      final f = File(path);
      if (!await f.exists()) return null;
      final len = await f.length();
      return len > 0 ? len : null;
    } catch (_) {
      return null;
    }
  }

  /// Finish a download: record its real size, then clear out the file a
  /// previous download of the same episode left behind.
  ///
  /// The record id is source+show+episode with no quality or mirror in it, so
  /// re-downloading an episode at another quality overwrites the record and
  /// used to strand the old file — invisible to the app and a few hundred MB
  /// each. Deleted only once the replacement is safely on disk, so a failed
  /// re-download doesn't cost the copy that already worked.
  Future<void> _markDone(DownloadRecord rec, String? path) async {
    // A retired Windows worker cannot attach its file to a replacement attempt.
    // Preserve its file on handover; the new manager owns recovery/cleanup.
    if (Platform.isWindows &&
        (_disposed ||
            (_records[rec.id] != null &&
                _records[rec.id]!.storageKey != rec.storageKey))) return;
    var latest = _records[rec.id];
    if (latest == null || latest.status == DownloadStatus.canceled) {
      await _deleteMediaFile(path);
      return;
    }
    // Remuxing may remove unwanted audio tracks, so HTTP Content-Length is
    // not the saved file size. Keep native accounting only for unreadable URIs.
    final bytesTotal = await sizeOf(path);
    if (Platform.isWindows &&
        (_disposed ||
            (_records[rec.id] != null &&
                _records[rec.id]!.storageKey != rec.storageKey))) return;
    latest = _records[rec.id];
    if (latest == null || latest.status == DownloadStatus.canceled) {
      await _deleteMediaFile(path);
      return;
    }
    final retained = {
      ...rec.retainedMediaPaths,
      ...latest.retainedMediaPaths,
      if (rec.supersededPath != null) rec.supersededPath!,
      if (latest.supersededPath != null) latest.supersededPath!,
    };
    var done = latest.copyWith(
      status: DownloadStatus.done,
      pendingAudioFinalization: false,
      retryAt: () => null, retryHost: () => null, retryCount: 0,
      autoResumePending: false,
      error: () => null,
      progress: 1,
      filePath: () => path,
      bytesTotal: bytesTotal,
      supersededPath: () => null,
      retainedMediaPaths: retained
          .where((previous) => previous != path)
          .toList(),
    );
    // Commit the new library path before removing any recoverable old media.
    // Retired paths remain in the committed record across a cleanup interruption.
    try {
      final committed = await _commitCompletedRecord(done);
      if (committed == null) {
        if (!_disposed && _isCanceled(rec.id)) await _deleteMediaFile(path);
        return;
      }
      done = committed;
    } catch (_) {
      if (!_disposed &&
          _records[rec.id]?.status != DownloadStatus.canceled &&
          _records.containsKey(rec.id)) {
        _records[rec.id] = (_records[rec.id] ?? latest).copyWith(
          status: DownloadStatus.failed,
          filePath: () => path,
          retainedMediaPaths: done.retainedMediaPaths,
          error: () =>
              'The file was saved, but the download library could not be updated. Check storage and retry.',
        );
      }
      return;
    }
    if (_disposed) return;
    final current = _records[rec.id];
    if (current == null || current.status == DownloadStatus.canceled) {
      // The awaited save may have crossed a user cancellation/deletion.
      // Reassert that newer intent after the older completion write.
      try {
        if (current == null) {
          await _box.delete(rec.id);
        } else {
          await _box.put(rec.id, current.toMap());
        }
      } catch (_) {}
      await _deleteMediaFile(path);
      return;
    }
    await _publishExternalSubtitles(done);
    for (final previous in retained) {
      if (previous != path) await _deleteUnreferencedMedia(previous, rec.id);
    }
    // Keep paths whose deletion failed or which another record still owns.
    final remaining = <String>[];
    for (final previous in done.retainedMediaPaths) {
      if (isUriPath(previous) || await File(previous).exists()) {
        remaining.add(previous);
      }
    }
    if (remaining.length != done.retainedMediaPaths.length) {
      final cleaned = done.copyWith(retainedMediaPaths: remaining);
      try {
        await _commitCompletedRecord(cleaned);
      } catch (_) {
        // The verified media/library entry remains valid. Stale retired paths
        // stay recoverable rather than becoming an unhandled background error.
      }
    }
  }

  /// Subtitle downloads finish independently of video. Reconcile their latest
  /// metadata across each awaited save before publishing a completion snapshot.
  /// Newer cancel/delete/pause intent wins every retry of the critical save.
  Future<DownloadRecord?> _commitCompletedRecord(DownloadRecord desired) async {
    while (!_disposed) {
      final before = _records[desired.id];
      if (before == null ||
          before.status == DownloadStatus.canceled ||
          before.status == DownloadStatus.paused) {
        return null;
      }
      desired = desired.copyWith(subtitles: before.subtitles);
      await _persistCompletedRecord(desired);
      if (_disposed) return null;
      final after = _records[desired.id];
      if (after == null ||
          after.status == DownloadStatus.canceled ||
          after.status == DownloadStatus.paused) {
        if (after == null) {
          await _box.delete(desired.id);
        } else {
          await _box.put(desired.id, after.toMap());
        }
        return null;
      }
      if (!listEquals(after.subtitles, desired.subtitles)) continue;
      _records[desired.id] = desired;
      return desired;
    }
    return null;
  }

  /// Critical completion saves are awaited; ordinary progress remains batched.
  Future<void> _persistCompletedRecord(DownloadRecord rec) =>
      _writeCompletedRecord?.call(rec) ?? _box.put(rec.id, rec.toMap());

  void _put(DownloadRecord rec) {
    _records[rec.id] = rec;
    _box.put(rec.id, rec.toMap());
  }

  /// All files of a Windows job share its captured root. Legacy native tasks
  /// and completed files already encode an authoritative destination; preserve
  /// it when they predate downloadRoot instead of following today's default.
  String _windowsVideoDirectory(DownloadRecord rec) {
    if (rec.downloadRoot?.isNotEmpty == true) {
      return p.join(rec.downloadRoot!, 'Videos', _safe(rec.showTitle));
    }
    final task = _tasks[rec.id];
    if (task != null && task.baseDirectory == BaseDirectory.root) {
      return task.directory;
    }
    final saved = rec.filePath;
    if (saved != null && saved.isNotEmpty && !isUriPath(saved)) {
      return p.dirname(saved);
    }
    return p.join(_downloadPrefs.locationUri!, 'Videos', _safe(rec.showTitle));
  }

  /// Windows IDs encode the complete tuple without punctuation or boundary
  /// loss. Keep exact legacy records under their original IDs so native resume,
  /// saved paths and offline progress need no migration. Other platforms retain
  /// their existing identity format.
  String _idFor(String sourceId, String showId, String episodeId, {String? category}) {
    final legacy = _safe('${sourceId}_${showId}_$episodeId');
    if (!Platform.isWindows) return legacy;
    String key(List<String> tuple) => 'download_${sha256.convert(utf8.encode(jsonEncode(tuple)))}';
    final primary = key([sourceId, showId, episodeId]);
    final cut = category == null ? null : key([sourceId, showId, episodeId, category]);
    // Preserve exact old keys, native task identities and progress. New cuts
    // receive separate identities even when metadata URLs/episode IDs coincide.
    for (final id in [if (cut != null) cut, legacy, primary]) {
      final saved = _records[id];
      if (saved != null && saved.sourceId == sourceId && saved.showId == showId &&
          saved.episodeId == episodeId && (category == null || saved.category == category)) return id;
    }
    if (category != null) return cut!;
    // Compatibility for callers without cut intent; new playback/UI callers
    // pass it explicitly so this fallback cannot silently substitute audio.
    for (final saved in _records.values.toList().reversed) {
      if (saved.sourceId == sourceId && saved.showId == showId && saved.episodeId == episodeId) return saved.id;
    }
    return primary;
  }

  static String _safe(String s) =>
      s.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');

  /// A readable Windows name plus stable identity for this saved generation.
  /// Preserve old mobile naming and stored paths; native resume uses its saved
  /// task filename. Fractional/missing episode numbers never define identity.
  static String _mediaFileStem(DownloadRecord rec) {
    if (!Platform.isWindows) {
      return '${_safe(rec.showTitle)}_E${rec.episodeNumber?.toInt() ?? ''}_${_safe(rec.quality)}';
    }
    final number = rec.episodeNumber;
    final label = number == null || !number.isFinite
        ? ''
        : number == number.truncateToDouble()
        ? number.toInt().toString()
        : number.toString();
    final season = rec.season == null ? '' : 'S${rec.season}';
    final key = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              rec.sourceId,
              rec.showId,
              rec.episodeId,
              rec.storageKey,
            ]),
          ),
        )
        .toString()
        .substring(0, 32);
    return '${_safe(rec.showTitle)}_${season}E${_safe(label)}_${_safe(rec.quality)}_$key';
  }

  /// File extension (incl. dot) from a url path, defaulting to .mp4.
  static String _ext(String url) {
    final path = (Uri.tryParse(url)?.path ?? url).toLowerCase();
    for (final e in const ['.mp4', '.mkv', '.webm', '.mov', '.m4v']) {
      if (path.endsWith(e)) return e;
    }
    return '.mp4';
  }

  /// Subtitle file extension (incl. dot) from the url, then the declared
  /// [format], defaulting to .vtt.
  static String _subExt(String url, String? format) {
    final path = (Uri.tryParse(url)?.path ?? url).toLowerCase();
    for (final e in const ['.vtt', '.srt', '.ass', '.ssa', '.sub']) {
      if (path.endsWith(e)) return e;
    }
    final f = (format ?? '').toLowerCase();
    if (f.contains('srt')) return '.srt';
    if (f.contains('ass')) return '.ass';
    if (f.contains('ssa')) return '.ssa';
    return '.vtt';
  }

  /// HLS sources route through the in-app segment downloader; everything else
  /// through background_downloader.
  static bool _isHls(VideoSource s) {
    if (s.container == SourceContainer.hls) return true;
    return (Uri.tryParse(s.url)?.path ?? s.url).toLowerCase().endsWith('.m3u8');
  }

  /// A DASH manifest — a few KB of XML listing where the video lives, not the
  /// video. There is no DASH segment downloader here (HLS has one), so these
  /// can never produce a file.
  ///
  /// Worth spotting BEFORE downloading: without this the manifest is fetched
  /// as if it were the episode, and only the "under 512KB isn't a video" guard
  /// catches it — after a request, a write and a delete, per server, on a
  /// source where every server is DASH.
  static bool isDash(VideoSource s) =>
      (Uri.tryParse(s.url)?.path ?? s.url).toLowerCase().endsWith('.mpd');

  /// Torrent (magnet/.torrent) sources route through the native torrent
  /// download engine — a distinct branch that never touches the HTTP/HLS paths.
  @visibleForTesting
  static bool isTorrentSource(VideoSource s) =>
      s.container == SourceContainer.torrent;

  Future<void> _startTorrentDownload(
    DownloadRecord rec,
    VideoSource source,
  ) async {
    _put(rec.copyWith(isTorrent: true, status: DownloadStatus.downloading));
    notifyListeners();
    try {
      // Torrent save-to-folder is SAF-only; a detected-drive (plain path) choice
      // isn't wired through the native torrent side yet, so fall back to default.
      final loc = _downloadPrefs.locationUri;
      await _torrentSvc.enqueue(
        rec.id,
        source.url,
        saveTreeUri: loc != null && isUriPath(loc) ? loc : null,
        allowMobileData: TorrentPrefs().allowMobileData,
      );
    } catch (e) {
      if (_isCanceled(rec.id)) return;
      final wifi = e is PlatformException && e.code == 'wifi_only';
      AppLogger.instance.log(
        'torrent download start failed (${rec.showTitle}): $e',
        level: 'E',
      );
      _put(
        rec.copyWith(
          status: DownloadStatus.failed,
          error: () => wifi
              ? 'Torrents are set to Wi-Fi only (Settings › Torrents).'
              : 'Torrent download failed to start.',
        ),
      );
      notifyListeners();
    }
  }

  static int _height(VideoSource s) {
    final m = RegExp(r'(\d{3,4})').firstMatch(s.quality ?? '');
    return m == null ? 0 : int.parse(m.group(1)!);
  }

  /// All sources (HLS + direct, both downloadable now) ordered for the requested
  /// quality. 'best' = highest first; otherwise by CLOSENESS to the requested
  /// height (so 360p gets the smallest file) — ties go to the higher quality.
  /// The full ordered list doubles as the try-next fallback.
  static List<VideoSource> _ranked(
    List<VideoSource> sources,
    String quality, {
    required String category,
  }) {
    // Drop what cannot become a file at all, rather than finding out by
    // downloading it.
    final byCategory = sourcesForDownloadCategory(sources, category);
    final list = List<VideoSource>.from(byCategory.where((s) => !isDash(s)));
    if (list.isEmpty) return const [];
    if (quality == 'best') {
      list.sort((a, b) => _height(b).compareTo(_height(a)));
      return list;
    }
    final want = int.tryParse(
      RegExp(r'(\d{3,4})').firstMatch(quality)?.group(1) ?? '',
    );
    if (want == null) {
      list.sort((a, b) => _height(b).compareTo(_height(a)));
      return list;
    }
    list.sort((a, b) {
      final da = (_height(a) - want).abs();
      final db = (_height(b) - want).abs();
      if (da != db) return da.compareTo(db); // closest to requested first
      return _height(b).compareTo(_height(a)); // tie → higher quality
    });
    return list;
  }
}
