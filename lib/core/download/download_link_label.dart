import '../models/video_source.dart';
import '../playback/source_selection.dart';

/// Download-side naming of one stream link, kept identical to how the player's
/// Sources sheet names it so the download dialogs list the same rows
/// ("SUB • HD - 1 - 1080p", "DUB • Vidstream - 2 - 1080p", ...).

/// Resolution tokens ("1080p", "720P", "4K", "2K") that are quality, not server.
final _resolutionToken = RegExp(r'\b(\d{3,4}p|[24]k)\b', caseSensitive: false);

/// Separator characters left dangling after a resolution token is removed.
final _edgeSeparators = RegExp(r'^[\s\-·•|,_/()\[\]]+|[\s\-·•|,_/()\[\]]+$');

/// Player-style label for [s]: the provider's own name with its resolution
/// appended, or (when the link has no name) `KIND • quality`. The kind prefix
/// is only shown for a real sub/dub/raw kind, never "UNKNOWN".
String downloadLinkLabel(VideoSource s) {
  final label = s.label?.trim() ?? '';
  final quality = s.quality?.trim() ?? '';
  final prefix = s.kind == AudioKind.unknown
      ? ''
      : '${s.kind.name.toUpperCase()} • ';
  if (label.isNotEmpty) {
    // Same rule as the player: skip "auto" and qualities the label already has.
    final withQuality =
        quality.isEmpty ||
            quality.toLowerCase() == 'auto' ||
            label.toLowerCase().contains(quality.toLowerCase())
        ? label
        : '$label · $quality';
    return '$prefix$withQuality';
  }
  return '$prefix${quality.isNotEmpty ? quality : s.container.name}';
}

/// Stable server identity of [s] across episodes: its own label, else the
/// server name some providers (Aniyomi/Anikoto) put in `quality` with the
/// resolution stripped ("HD - 1 - 1080p" -> "HD - 1"). Empty when the link
/// carries no name at all (a bare "1080p").
String downloadServerName(VideoSource s) {
  final label = s.label?.trim() ?? '';
  if (label.isNotEmpty) return label;
  final quality = s.quality?.trim() ?? '';
  return quality
      .replaceAll(_resolutionToken, '')
      .replaceAll(_edgeSeparators, '')
      .replaceAll(RegExp(r'\s{2,}'), ' ')
      .trim();
}

/// Server name for menus: [downloadServerName] with its kind prefix, falling
/// back to the host when the link has no name ("SUB • HD - 1").
String downloadServerLabel(VideoSource s) {
  final name = downloadServerName(s);
  final shown = name.isNotEmpty
      ? name
      : (Uri.tryParse(s.url)?.host ?? '').replaceFirst('www.', '');
  return s.kind == AudioKind.unknown
      ? shown
      : '${s.kind.name.toUpperCase()} • $shown';
}

/// Identity of one server row: kind + server name + host, so SUB and DUB of
/// the same server (and same-named servers on different hosts) stay apart.
String downloadServerKey(VideoSource s) =>
    '${s.kind.name}|${downloadServerName(s).toLowerCase()}|'
    '${Uri.tryParse(s.url)?.host.toLowerCase() ?? ''}';

/// Download category ('sub'/'dub') a link belongs to, or null for a link of
/// unknown/raw kind (the caller keeps its current cut then).
String? downloadCategoryForKind(AudioKind kind) => switch (kind) {
  AudioKind.sub => 'sub',
  AudioKind.dub => 'dub',
  _ => null,
};

/// Links ordered like the player's Sources sheet (grouped by kind in
/// first-seen order, best quality first in each group), except that the
/// [preferredCategory]'s kind group is listed first.
List<VideoSource> orderDownloadLinks(
  List<VideoSource> links,
  String preferredCategory,
) {
  // Only links a download category can take: SUB/DUB when the source labels
  // its links, all of them when it labels none. A RAW (or unlabelled link
  // beside labelled ones) would be listed but then dropped by the category
  // filter in the manager ("selected audio is unavailable").
  final known = links.any((s) => s.kind != AudioKind.unknown);
  if (known) {
    links = [
      for (final s in links)
        if (downloadCategoryForKind(s.kind) != null) s,
    ];
  }
  final seen = availableKinds(links);
  // Only the preferred kind moves to the front; the rest keep first-seen order
  // (built by hand because List.sort is not stable).
  bool preferred(AudioKind k) =>
      downloadCategoryForKind(k) == preferredCategory;
  final kinds = [...seen.where(preferred), ...seen.where((k) => !preferred(k))];
  return [for (final k in kinds) ...sortByQuality(sourcesForKind(links, k))];
}
