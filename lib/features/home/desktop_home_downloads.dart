import '../downloads/desktop_download_library.dart';
import 'desktop_home_page.dart';

/// Turns the Downloads library into Home cards for the offline shelf.
///
/// Only shows with at least one finished file are offered, newest first, and
/// only those that match the current content mode (video for watching,
/// chapters for reading), so a manga reader never gets anime suggestions.
/// Counts come from the collection itself, so a show whose files failed or are
/// still queued is never advertised as playable.
List<DesktopHomeDownload> desktopHomeDownloads({
  required List<DesktopDownloadCollection> collections,
  required bool reading,
  required void Function(DesktopDownloadCollection) open,
  int limit = 20,
}) {
  final playable =
      collections
          .where(
            (c) =>
                c.saved > 0 && (reading ? c.key.kind != 'video' : c.key.kind == 'video'),
          )
          .toList()
        ..sort((a, b) => b.newest.compareTo(a.newest));
  return [
    for (final c in playable.take(limit))
      DesktopHomeDownload(
        title: c.title,
        subtitle: _countLabel(c.saved, reading),
        image: c.cover,
        headers: c.coverHeaders,
        open: () => open(c),
      ),
  ];
}

String _countLabel(int count, bool reading) {
  final unit = reading ? 'chapter' : 'episode';
  return '$count $unit${count == 1 ? '' : 's'}';
}
