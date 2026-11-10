import '../../core/download/download_record.dart';
import '../../core/models/episode.dart';

/// Finds suggestions only, never assigns provider or language to recovered files.
/// Unknown seasons, duplicate releases and partial title matches are ambiguous.
Map<Episode, DownloadRecord> recoveredDownloadSuggestions({
  required String title,
  required List<Episode> episodes,
  required List<DownloadRecord> records,
}) {
  String key(String value) => value.toLowerCase()
      .replaceAll(RegExp(r'[_\s]+'), ' ').trim();
  final wanted = key(title);
  if (wanted.isEmpty) return const {};
  final suggestions = <Episode, DownloadRecord>{};
  for (final episode in episodes) {
    if (episode.number?.isFinite != true || episode.season == null) continue;
    final matches = records.where((r) => r.recoveredFromDisk &&
        r.status == DownloadStatus.done && r.season == episode.season &&
        r.episodeNumber == episode.number && key(r.showTitle) == wanted).toList();
    if (matches.length == 1) suggestions[episode] = matches.single;
  }
  return suggestions;
}

/// Recheck after confirmation: a missing file must remain in the download batch.
Future<List<Episode>> omitReusableDownloads(List<Episode> episodes,
    Map<Episode, DownloadRecord> approved,
    Future<bool> Function(DownloadRecord) filePresent) async {
  final pending = <Episode>[];
  for (final episode in episodes) {
    final record = approved[episode];
    if (record == null || !await filePresent(record)) pending.add(episode);
  }
  return pending;
}
