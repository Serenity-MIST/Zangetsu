import '../../core/download/download_record.dart';
import '../../core/models/episode.dart';
import '../../core/models/video_source.dart';

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
/// oldest episode first, starting at the tapped one — so Next always has
/// somewhere to go. Only files still on disk are listed, so every entry
/// resolves and autoplay can never stall on a missing file.
Future<({List<Episode> episodes, int startIndex})> downloadedSiblingQueue({
  required List<DownloadRecord> showRecords,
  required DownloadRecord record,
  required Future<bool> Function(DownloadRecord record) filePresent,
}) async {
  final done = <DownloadRecord>[];
  for (final r in showRecords) {
    if (r.status == DownloadStatus.done && await filePresent(r)) {
      done.add(r);
    }
  }
  done.sort((a, b) => (a.episodeNumber ?? 0).compareTo(b.episodeNumber ?? 0));
  final episodes = [
    for (final r in done)
      Episode(
        id: r.episodeId,
        title: r.episodeTitle,
        number: r.episodeNumber ?? 0,
        url: r.episodeUrl,
      ),
  ];
  if (episodes.isEmpty) {
    // The tapped file vanished mid-tap; fall back to today's single-entry
    // behavior rather than handing the player an empty queue.
    return downloadedEpisodePlaybackQueue(record: record);
  }
  var startIndex = done.indexWhere((r) => r.episodeId == record.episodeId);
  if (startIndex < 0) startIndex = 0;
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
