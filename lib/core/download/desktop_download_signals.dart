import 'dart:async';

import 'package:flutter/foundation.dart';

import '../desktop/desktop_native.dart';
import '../desktop/desktop_prefs.dart';
import 'chapter_download.dart';
import 'chapter_download_store.dart';
import 'chapter_downloader.dart';
import 'download_manager.dart';
import 'download_record.dart';
import '../../l10n/l10n.dart';

/// Signature of [DesktopNative.setTaskbarProgress], swappable in tests.
typedef TaskbarProgressSink =
    Future<void> Function(DesktopTaskbarState state, double fraction);

/// Signature of [DesktopNative.showNotification], swappable in tests.
typedef DownloadNotificationSink =
    Future<void> Function(String title, String body);

/// Windows-only download feedback while the app is in the background (dl-11):
///
/// * overall progress of every running video and chapter download on the
///   taskbar button (paused when everything left is paused, red while a
///   failed download of the current batch is still failed);
/// * one Windows notification when a batch ends, saying what finished and
///   what failed.
///
/// A "batch" runs from the moment something starts downloading until nothing
/// is running any more. Both features follow the toggles in Download settings
/// ([DesktopPrefs.taskbarProgress] / [DesktopPrefs.downloadNotifications]).
///
/// [DownloadManager.setup] and the [ChapterDownloader] constructor attach
/// themselves on the Windows desktop UI only, so phone never gets here.
class DesktopDownloadSignals {
  DesktopDownloadSignals._();

  /// Shared instance the download services attach to.
  static final DesktopDownloadSignals instance = DesktopDownloadSignals._();

  /// Fresh instance for tests (not attached to anything).
  @visibleForTesting
  factory DesktopDownloadSignals.forTesting() = DesktopDownloadSignals._;

  // ── Outputs (swappable in tests) ──────────────────────────────────────────

  /// Where taskbar updates go.
  @visibleForTesting
  TaskbarProgressSink setTaskbar = (state, fraction) =>
      DesktopNative.setTaskbarProgress(state, fraction);

  /// Where batch notifications go. The payload opens the Downloads page.
  @visibleForTesting
  DownloadNotificationSink notify = (title, body) =>
      DesktopNative.showNotification(
        title: title,
        body: body,
        payload: 'downloads',
      );

  /// Whether taskbar progress is wanted (Download settings toggle).
  @visibleForTesting
  bool Function() taskbarEnabled = () => DesktopPrefs.taskbarProgress;

  /// Whether batch notifications are wanted (Download settings toggle).
  @visibleForTesting
  bool Function() notificationsEnabled = () =>
      DesktopPrefs.downloadNotifications;

  // ── Sources ───────────────────────────────────────────────────────────────

  DownloadManager? _videos;
  ChapterDownloader? _chapters;
  ChapterDownloadStore? _store;

  // The prefs box listenable we listen to (kept to remove the listener).
  Listenable? _prefs;

  // ── Batch state ───────────────────────────────────────────────────────────

  // Last seen status of every video record, to spot done / failed moves.
  final Map<String, DownloadStatus> _videoStatus = {};
  // Chapters that were queued or downloading at the last refresh.
  Set<String> _chapterLive = {};
  // Whether a batch is running (something was active since the last end).
  bool _batchActive = false;
  // Display names of what finished / failed in the current batch.
  final List<String> _finished = [];
  final List<String> _failed = [];
  // Ids that failed in the current batch (video and chapter), for the red bar.
  final Set<String> _failedVideoIds = {};
  final Set<String> _failedChapterIds = {};

  // Last taskbar state sent, to skip identical native calls.
  DesktopTaskbarState _lastState = DesktopTaskbarState.none;
  int _lastPercent = -1;

  /// Starts following the video download manager.
  void attachVideos(DownloadManager manager) {
    if (identical(_videos, manager)) return;
    _videos?.removeListener(refresh);
    _videos = manager;
    // Existing records are history, not events of a new batch.
    _videoStatus
      ..clear()
      ..addEntries(manager.all.map((r) => MapEntry(r.id, r.status)));
    manager.addListener(refresh);
    _listenToPrefs();
    refresh();
  }

  /// Stops following [manager] (on dispose).
  void detachVideos(DownloadManager manager) {
    if (!identical(_videos, manager)) return;
    manager.removeListener(refresh);
    _videos = null;
    _videoStatus.clear();
    refresh();
  }

  /// Starts following the chapter downloader and its store.
  void attachChapters(
    ChapterDownloader downloader,
    ChapterDownloadStore store,
  ) {
    if (identical(_chapters, downloader)) return;
    _chapters?.removeListener(refresh);
    _chapters = downloader;
    _store = store;
    _chapterLive = downloader.inFlight.keys.toSet();
    downloader.addListener(refresh);
    _listenToPrefs();
    refresh();
  }

  /// Stops following [downloader] (on dispose).
  void detachChapters(ChapterDownloader downloader) {
    if (!identical(_chapters, downloader)) return;
    downloader.removeListener(refresh);
    _chapters = null;
    _store = null;
    _chapterLive = {};
    refresh();
  }

  /// Re-reads the toggles when Download settings change them.
  void _listenToPrefs() {
    if (_prefs != null) return;
    try {
      final prefs = DesktopPrefs.changes;
      prefs.addListener(refresh);
      _prefs = prefs;
    } catch (_) {
      // No prefs box (tests): the getters fall back to their defaults.
    }
  }

  /// Recomputes the batch and pushes the taskbar state. Called on every
  /// change of either download service (about once a second while only
  /// progress moves, see [DownloadManager.progressNotifyIntervalMs]).
  void refresh() {
    var active = 0;
    var progressSum = 0.0;
    var paused = 0;
    var pausedProgress = 0.0;

    // Videos: spot status moves and sum the running progress.
    final videos = _videos;
    if (videos != null) {
      final seen = <String>{};
      for (final r in videos.all) {
        seen.add(r.id);
        final before = _videoStatus[r.id];
        _videoStatus[r.id] = r.status;
        if (before != null && before != r.status && _wasWorking(before)) {
          if (r.status == DownloadStatus.done) {
            _finished.add(_videoName(r));
          } else if (r.status == DownloadStatus.failed) {
            _failed.add(_videoName(r));
            _failedVideoIds.add(r.id);
          }
        }
        if (DownloadManager.runningStatuses.contains(r.status)) {
          active++;
          progressSum +=
              r.status == DownloadStatus.downloading ||
                  r.status == DownloadStatus.finalizing
              ? r.progress.clamp(0.0, 1.0)
              : 0;
        } else if (r.status == DownloadStatus.paused) {
          paused++;
          pausedProgress += r.progress.clamp(0.0, 1.0);
        }
      }
      _videoStatus.removeWhere((id, _) => !seen.contains(id));
      _failedVideoIds.removeWhere(
        (id) => _videoStatus[id] != DownloadStatus.failed,
      );
    }

    // Chapters: anything that left the live queue finished, failed or was
    // canceled; the store says which.
    final chapters = _chapters;
    final store = _store;
    if (chapters != null) {
      final live = chapters.inFlight;
      for (final id in _chapterLive.difference(live.keys.toSet())) {
        final saved = store?.get(id);
        if (saved == null) continue; // canceled and removed
        if (saved.status == ChapterDownloadStatus.done) {
          _finished.add(_chapterName(saved));
        } else if (saved.status == ChapterDownloadStatus.failed) {
          _failed.add(_chapterName(saved));
          _failedChapterIds.add(id);
        }
      }
      _chapterLive = live.keys.toSet();
      for (final c in live.values) {
        active++;
        progressSum += c.pageCount > 0
            ? (c.pagesDone / c.pageCount).clamp(0.0, 1.0)
            : 0;
      }
      _failedChapterIds.removeWhere(
        (id) =>
            live.containsKey(id) ||
            store?.get(id)?.status != ChapterDownloadStatus.failed,
      );
    }

    // Batch start / end.
    if (active > 0 && !_batchActive) {
      _batchActive = true;
      _finished.clear();
      _failed.clear();
    } else if (active == 0 && _batchActive) {
      _batchActive = false;
      _announceBatch();
    }

    // Overall fraction across the whole batch, so the bar never jumps back
    // when one item finishes and leaves the running set.
    final doneItems = _finished.length + _failed.length;
    final total = active + doneItems;
    final fraction = total == 0 ? 0.0 : (progressSum + doneItems) / total;
    final hasFailure =
        _failedVideoIds.isNotEmpty || _failedChapterIds.isNotEmpty;

    final DesktopTaskbarState state;
    var value = fraction;
    if (active > 0) {
      state = hasFailure
          ? DesktopTaskbarState.error
          : fraction <= 0
          ? DesktopTaskbarState.indeterminate
          : DesktopTaskbarState.normal;
    } else if (paused > 0) {
      state = DesktopTaskbarState.paused;
      value = pausedProgress / paused;
    } else if (hasFailure) {
      // Stays red until the failed items are retried or removed.
      state = DesktopTaskbarState.error;
      value = 1;
    } else {
      state = DesktopTaskbarState.none;
      value = 0;
    }
    _pushTaskbar(state, value);
  }

  /// Sends the taskbar state when it (or the whole percent) changed.
  void _pushTaskbar(DesktopTaskbarState state, double fraction) {
    final enabled = _safe(taskbarEnabled, true);
    final effective = enabled ? state : DesktopTaskbarState.none;
    final percent = effective == DesktopTaskbarState.none
        ? 0
        : (fraction.clamp(0.0, 1.0) * 100).round();
    if (effective == _lastState && percent == _lastPercent) return;
    _lastState = effective;
    _lastPercent = percent;
    unawaited(setTaskbar(effective, percent / 100).catchError((Object _) {}));
  }

  /// One notification summing up the batch that just ended.
  void _announceBatch() {
    final finished = List<String>.of(_finished);
    final failed = List<String>.of(_failed);
    _finished.clear();
    _failed.clear();
    if (finished.isEmpty && failed.isEmpty) return;
    if (!_safe(notificationsEnabled, true)) return;
    final (title, body) = batchMessage(finished: finished, failed: failed);
    unawaited(notify(title, body).catchError((Object _) {}));
  }

  /// Title and body of the end-of-batch notification.
  @visibleForTesting
  static (String, String) batchMessage({
    required List<String> finished,
    required List<String> failed,
  }) {
    // Background notification: no widget context, appL10n follows the app language.
    final l10n = appL10n;
    if (failed.isEmpty) {
      return finished.length == 1
          ? (l10n.downloadFinished, l10n.downloadNameIsReady(finished.single))
          : (l10n.downloadsFinished, l10n.downloadsAreReady(finished.length));
    }
    final failedText = failed.length == 1
        ? l10n.downloadNameFailed(failed.single)
        : l10n.downloadsCountFailed(failed.length);
    final body = finished.isEmpty
        ? failedText
        : l10n.downloadsFailedAndFinished(failedText, finished.length);
    return (
      failed.length == 1 ? l10n.downloadFailed : l10n.downloadsFailedTitle,
      body,
    );
  }

  /// Statuses a record can leave to count as finished / failed in a batch.
  static bool _wasWorking(DownloadStatus s) =>
      DownloadManager.runningStatuses.contains(s) || s == DownloadStatus.paused;

  /// 'Show · Episode 3' (or the episode title when it has no number).
  static String _videoName(DownloadRecord r) {
    final n = r.episodeNumber;
    final episode = n == null
        ? r.episodeTitle
        : appL10n.episodeNumberLabel(
            '${n == n.roundToDouble() ? n.toInt() : n}',
          );
    return episode.isEmpty ? r.showTitle : '${r.showTitle} · $episode';
  }

  /// 'Show · Chapter title'.
  static String _chapterName(ChapterDownload c) => c.chapterTitle.isEmpty
      ? c.showTitle
      : '${c.showTitle} · ${c.chapterTitle}';

  /// Reads a toggle, falling back when prefs are unavailable.
  static bool _safe(bool Function() read, bool fallback) {
    try {
      return read();
    } catch (_) {
      return fallback;
    }
  }

  /// Detaches everything and forgets the batch (tests).
  @visibleForTesting
  void debugReset() {
    _videos?.removeListener(refresh);
    _chapters?.removeListener(refresh);
    _prefs?.removeListener(refresh);
    _videos = null;
    _chapters = null;
    _store = null;
    _prefs = null;
    _videoStatus.clear();
    _chapterLive = {};
    _batchActive = false;
    _finished.clear();
    _failed.clear();
    _failedVideoIds.clear();
    _failedChapterIds.clear();
    _lastState = DesktopTaskbarState.none;
    _lastPercent = -1;
  }
}
