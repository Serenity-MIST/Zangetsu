import '../../core/download/download_record.dart';
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
  if (record.season != null) return record.season;
  final id = int.tryParse(
    _seasonPrefix.firstMatch(record.episodeId.trim())?.group(1) ?? '',
  );
  if (id != null && id != 0) return id;
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

/// Offline queue for the Downloads section: the show's finished downloads,
/// ordered only when episode positions are unambiguous, starting at the tapped one — so Next always has
/// somewhere to go. Only files still on disk are listed, so every entry
/// resolves and autoplay can never stall on a missing file.
Future<({List<Episode> episodes, int startIndex})> downloadedSiblingQueue({
  required List<DownloadRecord> showRecords,
  required DownloadRecord record,
  required Future<bool> Function(DownloadRecord record) filePresent,
}) async {
  final done = <DownloadRecord>[];
  final selectedSeason = _downloadSeason(record);
  for (final r in showRecords) {
    // Grouped show IDs can recur across providers, audio cuts and seasons.
    // Never let Next silently change the selected language or title context.
    if (r.sourceId == record.sourceId &&
        r.showId == record.showId &&
        r.category == record.category &&
        _downloadSeason(r) == selectedSeason &&
        r.status == DownloadStatus.done &&
        await filePresent(r)) {
      done.add(r);
    }
  }
  // Unknown numbering or alternate files at the same position cannot safely
  // choose Next. Never start a different file when the tapped entry vanished.
  final positions = {for (final r in done) r.episodeNumber};
  if (!done.any((r) => r.id == record.id) ||
      done.any((r) => r.episodeNumber == null || !r.episodeNumber!.isFinite) ||
      positions.length != done.length) {
    return downloadedEpisodePlaybackQueue(record: record);
  }
  done.sort((a, b) => a.episodeNumber!.compareTo(b.episodeNumber!));
  final episodes = [
    for (final r in done)
      Episode(
        id: r.episodeId,
        title: r.episodeTitle,
        number: r.episodeNumber,
        season: _downloadSeason(r),
        url: r.episodeUrl,
      ),
  ];
  if (episodes.isEmpty) {
    // The tapped file vanished mid-tap; fall back to today's single-entry
    // behavior rather than handing the player an empty queue.
    return downloadedEpisodePlaybackQueue(record: record);
  }
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
