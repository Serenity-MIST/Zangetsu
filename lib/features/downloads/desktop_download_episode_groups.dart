import '../../core/download/download_record.dart';

/// Presentation-only episode grouping. Original jobs, files and languages stay
/// separate; a local file never turns a failed Dub attempt into a Dub success.
List<List<DownloadRecord>> desktopDownloadEpisodeGroups(List<DownloadRecord> records) {
  String title(String value) => value.toLowerCase()
      .replaceAll(RegExp(r'[_\s]+'), ' ').trim();
  final buckets = <Object, List<DownloadRecord>>{};
  for (final record in records) {
    final name = title(record.showTitle);
    final number = record.episodeNumber;
    final Object key = name.isNotEmpty && number?.isFinite == true && record.season != null
        ? (name, record.season, number) : ('record', record.id);
    (buckets[key] ??= []).add(record);
  }
  final groups = <List<DownloadRecord>>[];
  for (final bucket in buckets.values) {
    // Only reconcile the recovered-vs-indexed duplication. Provider-only cuts
    // keep their existing individual entries and requested-language status.
    if (!bucket.any((r) => r.recoveredFromDisk && r.status == DownloadStatus.done)) {
      groups.addAll(bucket.map((r) => [r]));
      continue;
    }
    bucket.sort((a, b) {
      final saved = (b.status == DownloadStatus.done ? 1 : 0)
          .compareTo(a.status == DownloadStatus.done ? 1 : 0);
      if (saved != 0) return saved;
      final known = (a.recoveredFromDisk ? 1 : 0).compareTo(b.recoveredFromDisk ? 1 : 0);
      return known != 0 ? known : b.createdAt.compareTo(a.createdAt);
    });
    groups.add(bucket);
  }
  return groups;
}
