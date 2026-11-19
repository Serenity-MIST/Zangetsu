import 'package:flutter/foundation.dart';

import '../../core/mode/content_mode.dart';
import '../../core/models/media_item.dart';
import '../../core/tracker/tracker.dart';

/// Shared shapes for the Windows "Schedule and lists" page. The data layer
/// fills them; the airing panel and the library tiles only read them.

/// One tile on the page: a tracker's list of one kind (anime, manga, novel).
@immutable
class HubListSummary {
  const HubListSummary({
    required this.trackerName,
    required this.kind,
    required this.active,
    required this.planned,
    required this.completed,
    this.covers = const [],
  });

  /// [Tracker.displayName], e.g. "AniList".
  final String trackerName;
  final ContentMode kind;

  /// Watching (anime) or reading (manga/novel).
  final int active;
  final int planned;
  final int completed;

  /// Up to three cover URLs from the list, most recently updated first.
  final List<String> covers;

  Map<String, dynamic> toJson() => {
    'tracker': trackerName,
    'kind': kind.name,
    'active': active,
    'planned': planned,
    'completed': completed,
    'covers': covers,
  };

  /// Null when a cached entry is malformed, so a bad cache never crashes.
  static HubListSummary? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = ContentMode.values
        .where((k) => k.name == json['kind'])
        .firstOrNull;
    final tracker = json['tracker'];
    if (kind == null || tracker is! String) return null;
    int n(Object? v) => v is int && v >= 0 ? v : 0;
    return HubListSummary(
      trackerName: tracker,
      kind: kind,
      active: n(json['active']),
      planned: n(json['planned']),
      completed: n(json['completed']),
      covers: [
        for (final c in (json['covers'] as List? ?? const []))
          if (c is String && c.isNotEmpty) c,
      ].take(3).toList(),
    );
  }
}

/// One row in the "Airing today" panel.
@immutable
class HubAiringItem {
  const HubAiringItem({
    required this.title,
    required this.episode,
    required this.airingAt,
    this.cover,
    this.onYourList = false,
    this.item,
  });

  final String title;
  final int episode;

  /// Local time the episode airs.
  final DateTime airingAt;
  final String? cover;

  /// True when the show is on one of the user's connected tracker lists.
  final bool onYourList;

  /// What to open when the row is clicked (show page). Null = not clickable.
  final MediaItem? item;
}

/// What the page reads. Cached values come back instantly (or null when
/// nothing was saved yet); the refresh calls fetch fresh data, save it and
/// notify listeners. Implementations never throw from the refresh calls —
/// a failed refresh keeps the cached value and records [lastError].
abstract class ListsHubData implements Listenable {
  /// Saved tiles for [tracker], or null before the first successful load.
  List<HubListSummary>? cachedSummaries(Tracker tracker);

  /// Fetches the tracker's lists, updates the cache, returns the tiles.
  Future<List<HubListSummary>> refreshSummaries(Tracker tracker);

  /// Saved airing-today rows, or null before the first successful load.
  List<HubAiringItem>? cachedAiringToday();

  /// Fetches today's airing schedule (local day), marks shows on the user's
  /// lists, updates the cache and returns rows sorted by [HubAiringItem.airingAt].
  Future<List<HubAiringItem>> refreshAiringToday();

  /// When data was last refreshed successfully (for "Updated just now").
  DateTime? get lastUpdated;

  /// Message of the last failed refresh, or null.
  String? get lastError;
}
