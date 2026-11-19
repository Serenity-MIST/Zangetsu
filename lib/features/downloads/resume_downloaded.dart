import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../core/di/injector.dart';
import '../../core/download/download_manager.dart';
import '../../core/models/episode.dart';
import '../../core/models/video_source.dart';
import '../../core/playback/watch_history.dart';
import 'downloaded_episode_playback.dart';
import 'downloads_screen.dart' show launchDownloadedEpisode;

/// How long Continue waits for the online episode list before settling for
/// the downloaded episodes. Offline, the lookup usually fails much sooner.
const resumeOnlineListTimeout = Duration(seconds: 6);

/// Continue watching: when the episode being resumed is downloaded, play the
/// saved file (the same path the show page uses), so resuming works offline.
///
/// The online episode list is still tried first so Next can stream episodes
/// that were never downloaded; when it fails or is slow (offline), the queue
/// is built from the show's downloaded episodes instead.
///
/// Returns false when there is no finished download for [entry], leaving the
/// caller to stream as before.
Future<bool> resumeFromDownload(
  BuildContext context,
  HistoryEntry entry, {
  required Future<List<Episode>> Function() onlineEpisodes,
  required Future<List<VideoSource>> Function(String episodeUrl) onlineSources,
}) async {
  // Windows only; phone and TV keep upstream's streaming resume.
  if (defaultTargetPlatform != TargetPlatform.windows) return false;
  if (!sl.isRegistered<DownloadManager>()) return false;
  final manager = sl<DownloadManager>();
  final record = await manager.finishedForEpisode(
    sourceId: entry.sourceId,
    showId: entry.showId,
    episodeId: entry.episodeId,
    episodeUrl: entry.episodeUrl,
    malId: entry.malId,
    episodeNumber: entry.episodeNumber,
    category: entry.category,
  );
  if (record == null || !context.mounted) return false;

  // Full online list when reachable, positioned on the resumed episode.
  List<Episode>? episodes;
  var startIndex = 0;
  try {
    final online = await onlineEpisodes().timeout(resumeOnlineListTimeout);
    final index = resumeIndexIn(online, entry);
    if (index >= 0) {
      episodes = online;
      startIndex = index;
    }
  } catch (_) {
    // Offline or the source failed: the downloaded queue below covers it.
  }

  // Offline: the show's downloaded episodes, starting at the resumed one.
  if (episodes == null) {
    final queue = await downloadedSiblingQueue(
      showRecords: manager.byShow[record.showId] ?? const [],
      record: record,
      filePresent: manager.filePresent,
      // Windows keeps Next inside the same season, like the Downloads page.
      sameSeason: defaultTargetPlatform == TargetPlatform.windows,
    );
    episodes = queue.episodes;
    startIndex = queue.startIndex;
  }
  if (!context.mounted) return true;

  await launchDownloadedEpisode(
    context,
    record,
    episodes: episodes,
    startIndex: startIndex,
    // Episodes that were never downloaded still stream when online.
    fallbackResolveSources: onlineSources,
    // Used when the saved per-episode mark doesn't match the file's key.
    resumePosition: entry.position,
  );
  return true;
}

/// Position of the resumed episode in an online list: exact id, then URL,
/// then episode number. -1 when it isn't there.
@visibleForTesting
int resumeIndexIn(List<Episode> episodes, HistoryEntry entry) {
  var index = episodes.indexWhere((e) => e.id == entry.episodeId);
  if (index < 0 && entry.episodeUrl.isNotEmpty) {
    index = episodes.indexWhere((e) => e.url == entry.episodeUrl);
  }
  if (index < 0 && entry.episodeNumber != null) {
    index = episodes.indexWhere((e) => e.number == entry.episodeNumber);
  }
  return index;
}
