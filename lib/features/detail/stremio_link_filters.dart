// Windows Stremio link list filters (show-9): resolution chips, text search
// and size sorting for the docked links panel. Pure helpers so the rules can
// be unit-tested without building the panel.

import 'package:zangetsu_source_bridge/stremio.dart';

import '../../core/stremio/stremio_link_session.dart';
import '../../l10n/l10n.dart';

/// Resolution bucket a link falls into, read from its addon-provided text.
enum StremioLinkQuality { uhd, fullHd, hd, other }

/// How the links panel orders its rows.
enum StremioLinkSort { addonOrder, largestFirst, smallestFirst }

/// Chip label for a quality bucket.
String stremioLinkQualityLabel(StremioLinkQuality quality) =>
    switch (quality) {
      // Resolutions read the same in every language.
      StremioLinkQuality.uhd => '4K',
      StremioLinkQuality.fullHd => '1080p',
      StremioLinkQuality.hd => '720p',
      StremioLinkQuality.other => appL10n.otherQuality,
    };

/// Menu label for a sort order.
/// Uses appL10n (no context needed); it follows the app language.
String stremioLinkSortLabel(StremioLinkSort sort) => switch (sort) {
  StremioLinkSort.addonOrder => appL10n.addonOrder,
  StremioLinkSort.largestFirst => appL10n.largestFirst,
  StremioLinkSort.smallestFirst => appL10n.smallestFirst,
};

// Addons put the resolution in the name ("Torrentio 4k"), the description
// ("Movie.2160p.WEB-DL") or the file name, so every field is checked.
final RegExp _uhd = RegExp(r'(^|[^a-z0-9])(2160p?|4k|uhd)([^a-z0-9]|$)');
final RegExp _fullHd = RegExp(r'(^|[^a-z0-9])(1080p?|fhd|full ?hd)([^a-z0-9]|$)');
final RegExp _hd = RegExp(r'(^|[^a-z0-9])(720p?)([^a-z0-9]|$)');

/// All searchable text of one link, lower-cased.
String stremioLinkText(StremioLinkChoice choice, {String addonName = ''}) => [
  choice.label,
  choice.stream.name,
  choice.stream.description,
  choice.stream.fileName,
  addonName,
].whereType<String>().join(' ').toLowerCase();

/// Highest resolution mentioned by the link; [StremioLinkQuality.other] when
/// none is named.
StremioLinkQuality stremioLinkQuality(StremioLinkChoice choice) {
  final text = stremioLinkText(choice);
  if (_uhd.hasMatch(text)) return StremioLinkQuality.uhd;
  if (_fullHd.hasMatch(text)) return StremioLinkQuality.fullHd;
  if (_hd.hasMatch(text)) return StremioLinkQuality.hd;
  return StremioLinkQuality.other;
}

/// True when every word of [query] appears somewhere in the link's text
/// (release group, codec, addon name...). An empty query matches everything.
bool stremioLinkMatchesQuery(
  StremioLinkChoice choice,
  String query, {
  String addonName = '',
}) {
  final words = query.toLowerCase().split(RegExp(r'\s+'))
    ..removeWhere((w) => w.isEmpty);
  if (words.isEmpty) return true;
  final text = stremioLinkText(choice, addonName: addonName);
  return words.every(text.contains);
}

/// Keeps the links matching [quality] (null = any) and [query].
List<StremioLinkChoice> filterStremioLinks(
  Iterable<StremioLinkChoice> choices, {
  StremioLinkQuality? quality,
  String query = '',
  String Function(StremioLinkChoice choice)? addonName,
}) => [
  for (final choice in choices)
    if ((quality == null || stremioLinkQuality(choice) == quality) &&
        stremioLinkMatchesQuery(
          choice,
          query,
          addonName: addonName?.call(choice) ?? '',
        ))
      choice,
];

/// Orders links by size; links without a known size always go last. The
/// sort is stable, so equal sizes keep the addon order.
List<StremioLinkChoice> sortStremioLinks(
  List<StremioLinkChoice> choices,
  StremioLinkSort sort,
) {
  if (sort == StremioLinkSort.addonOrder) return choices;
  final indexed = [
    for (var i = 0; i < choices.length; i++) (i: i, choice: choices[i]),
  ];
  int? size(StremioLinkChoice c) {
    final s = c.stream.videoSize;
    return s != null && s > 0 ? s : null;
  }

  indexed.sort((a, b) {
    final sa = size(a.choice), sb = size(b.choice);
    if (sa == null && sb == null) return a.i.compareTo(b.i);
    if (sa == null) return 1;
    if (sb == null) return -1;
    final bySize = sort == StremioLinkSort.largestFirst
        ? sb.compareTo(sa)
        : sa.compareTo(sb);
    return bySize != 0 ? bySize : a.i.compareTo(b.i);
  });
  return [for (final e in indexed) e.choice];
}

/// Counts links per quality bucket, for the chip badges.
Map<StremioLinkQuality, int> countStremioLinkQualities(
  Iterable<StremioLinkChoice> choices,
) {
  final counts = {for (final q in StremioLinkQuality.values) q: 0};
  for (final choice in choices) {
    final q = stremioLinkQuality(choice);
    counts[q] = counts[q]! + 1;
  }
  return counts;
}

/// Short text identifying a link for "Copy title": its name and description.
String stremioLinkTitle(StremioLinkChoice choice) {
  final StremioStream s = choice.stream;
  final parts = [
    s.name?.trim(),
    s.description?.trim(),
  ].whereType<String>().where((p) => p.isNotEmpty).toList();
  return parts.isEmpty ? choice.label : parts.join('\n');
}
