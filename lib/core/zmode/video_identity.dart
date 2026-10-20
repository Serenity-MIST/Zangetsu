import 'dart:convert';
import '../models/media_item.dart';
import 'zmode_ids.dart';

/// Reads an explicit movie/series discriminator from opaque provider data.
/// A missing discriminator remains unknown; URL paths and title text are not
/// reliable evidence that a source entry is a movie rather than a TV series.
ZKind? sourceVideoKind(String url) {
  try {
    final value = jsonDecode(url);
    if (value is! Map) return null;
    final type =
        '${value['type'] ?? value['tvtype'] ?? value['media_type'] ?? ''}'
            .toLowerCase();
    return switch (type) {
      'movie' => ZKind.movie,
      'series' || 'tv' || 'tvseries' => ZKind.tv,
      _ => null,
    };
  } on FormatException {
    return null;
  }
}

/// Keeps explicitly incompatible formats out of automatic matching and puts
/// known compatible formats first on title ties. Unknown sources remain usable.
List<MediaItem> videoCandidatesFor(ZKind wanted, List<MediaItem> results) {
  if (wanted != ZKind.tv && wanted != ZKind.movie) return results;
  final known = <MediaItem>[];
  final unknown = <MediaItem>[];
  for (final item in results) {
    final kind = sourceVideoKind(item.url) ?? (item.tmdbIsTv ? ZKind.tv : null);
    if (kind == wanted) known.add(item);
    if (kind == null) unknown.add(item);
  }
  return [...known, ...unknown];
}
