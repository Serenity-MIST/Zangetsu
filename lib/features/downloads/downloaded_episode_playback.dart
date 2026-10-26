import '../../core/download/download_record.dart';
import '../../core/models/episode.dart';
import '../../core/models/video_source.dart';

final _seasonPrefix = RegExp(
  r'^S(\d+)(?=E\d|\s|[\u00b7.]|$)',
  caseSensitive: false,
);

int? _downloadSeason(DownloadRecord record) {
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

/// Queues finished downloads from the same source/category by season and episode.
/// Older records recover seasons from structured IDs or titles. Ambiguous
/// numbering keeps selected-episode playback instead of guessing an order.
Future<({List<Episode> episodes, int startIndex})> downloadedSiblingQueue({
  required List<DownloadRecord> showRecords,
  required DownloadRecord record,
  required Future<bool> Function(DownloadRecord record) filePresent,
}) async {
  final done = <DownloadRecord>[];
  for (final r in showRecords) {
    if (r.sourceId != record.sourceId || r.category != record.category) {
      continue;
    }
    if (r.status == DownloadStatus.done && await filePresent(r)) {
      done.add(r);
    }
  }
  final seasons = {for (final r in done) r.id: _downloadSeason(r)};
  final positions = {for (final r in done) (seasons[r.id], r.episodeNumber)};
  if (!done.any((r) => r.id == record.id) ||
      done.any((r) => r.episodeNumber == null) ||
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
    subtitles: [
      for (final subtitle in record.subtitles)
        Subtitle(
          url: subtitle.path,
          lang: subtitle.lang,
          label: subtitle.label,
          isDefault: subtitle.isDefault,
        ),
    ],
  );
}
