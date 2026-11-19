import '../../core/download/download_record.dart';
import '../../core/download/subtitle_sidecars.dart';
import '../../core/models/episode.dart';
import '../../core/models/video_source.dart';

/// Only structured season prefixes are safe for legacy records; ordinary title
/// digits (years, part numbers) must never determine a playback season.
final _seasonPrefix = RegExp(
  r'^S(\d+)(?=E\d|\s|[\u00b7.]|$)',
  caseSensitive: false,
);

/// Keep the existing stored season authoritative, including explicit specials.
/// Legacy CloudStream S0 IDs mean unspecified; a structured title can refine it.
int? _downloadSeason(DownloadRecord record) {
  // DownloadRecord mirrors season/episodeSeason, so either spelling works.
  if (record.episodeSeason != null) return record.episodeSeason;
  final idSeason = int.tryParse(
    _seasonPrefix.firstMatch(record.episodeId.trim())?.group(1) ?? '',
  );
  // CloudStream also uses S0 in IDs when the source reports no season.
  if (idSeason != null && idSeason != 0) return idSeason;
  return int.tryParse(
    _seasonPrefix.firstMatch(record.episodeTitle.trim())?.group(1) ?? '',
  );
}

/// Preserve the detail-page queue; standalone playback uses the selected file.
({List<Episode> episodes, int startIndex}) downloadedEpisodePlaybackQueue({
  required DownloadRecord record,
  List<Episode>? episodes,
  int startIndex = 0,
}) {
  if (episodes == null || episodes.isEmpty) {
    return (
      episodes: [
        Episode(
          id: record.episodeId,
          title: record.episodeTitle,
          number: record.episodeNumber,
          season: _downloadSeason(record),
          url: record.episodeUrl,
        ),
      ],
      startIndex: 0,
    );
  }
  return (
    episodes: episodes,
    startIndex: startIndex.clamp(0, episodes.length - 1),
  );
}

/// Offline queue for the Downloads section: the show's finished downloads
/// from the same source/category, ordered by season and episode and starting
/// at the tapped one — so Next always has somewhere to go. Only files still on
/// disk are listed, so every entry resolves and autoplay never stalls.
/// Older records recover seasons from structured IDs or titles. Ambiguous
/// numbering keeps selected-episode playback instead of guessing an order.
/// [sameSeason] (Windows) limits the queue to the tapped episode's season.
Future<({List<Episode> episodes, int startIndex})> downloadedSiblingQueue({
  required List<DownloadRecord> showRecords,
  required DownloadRecord record,
  required Future<bool> Function(DownloadRecord record) filePresent,
  bool sameSeason = false,
}) async {
  final done = <DownloadRecord>[];
  final selectedSeason = _downloadSeason(record);
  for (final r in showRecords) {
    // Grouped show IDs can recur across providers, audio cuts and seasons.
    // Never let Next silently change the selected language or title context.
    if (r.sourceId != record.sourceId ||
        r.showId != record.showId ||
        r.category != record.category) {
      continue;
    }
    // Windows keeps Next inside the tapped season; elsewhere the queue
    // spans every downloaded season in order.
    if (sameSeason && _downloadSeason(r) != selectedSeason) continue;
    if (r.status == DownloadStatus.done && await filePresent(r)) {
      done.add(r);
    }
  }
  // Unknown numbering, mixed known/unknown seasons, or alternate files at the
  // same position cannot safely choose Next. Never start a different file
  // when the tapped entry vanished.
  final seasons = {for (final r in done) r.id: _downloadSeason(r)};
  final positions = {for (final r in done) (seasons[r.id], r.episodeNumber)};
  if (!done.any((r) => r.id == record.id) ||
      done.any((r) => r.episodeNumber == null || !r.episodeNumber!.isFinite) ||
      (seasons.values.contains(null) &&
          seasons.values.any((season) => season != null)) ||
      positions.length != done.length) {
    return downloadedEpisodePlaybackQueue(record: record);
  }
  done.sort((a, b) {
    final bySeason = (seasons[a.id] ?? 0).compareTo(seasons[b.id] ?? 0);
    return bySeason != 0
        ? bySeason
        : a.episodeNumber!.compareTo(b.episodeNumber!);
  });
  final episodes = [
    for (final r in done)
      Episode(
        id: r.episodeId,
        title: r.episodeTitle,
        number: r.episodeNumber,
        season: seasons[r.id],
        url: r.episodeUrl,
      ),
  ];
  final startIndex = done.indexWhere((r) => r.id == record.id);
  return (
    episodes: episodes,
    startIndex: startIndex.clamp(0, episodes.length - 1),
  );
}

VideoSource downloadedVideoSource(DownloadRecord record) {
  final path = record.filePath;
  if (path == null || path.isEmpty) {
    throw ArgumentError.value(record.filePath, 'record.filePath');
  }
  return VideoSource(
    url: path,
    container: SourceContainer.mp4,
    // The record's own list when its files exist; otherwise the subtitle files
    // saved next to the video (some downloads have them on disk but an empty
    // list in their record, which left the player with nothing to show).
    subtitles: [
      for (final subtitle in playableSubtitlesFor(record))
        Subtitle(
          url: subtitle.path,
          lang: subtitle.lang,
          label: subtitle.label,
          isDefault: subtitle.isDefault,
        ),
    ],
  );
}
