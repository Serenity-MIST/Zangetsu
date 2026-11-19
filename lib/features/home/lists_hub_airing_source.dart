import 'dart:async';

import '../../core/di/injector.dart';
import '../../core/models/media_item.dart';
import '../../core/models/provider_info.dart';
import '../../core/schedule/airing_service.dart';
import '../../core/schedule/schedule_models.dart';
import '../../core/zmode/zmode_ids.dart';
import 'lists_hub_models.dart';

/// Thrown by [HubAiringSource.today] when the week schedule could not be
/// loaded. [AiringService] swallows its own errors and returns `[]`, and the
/// weekly AniList window is never legitimately empty (the Schedule cubit
/// relies on the same rule), so an empty week is treated as a failure.
class HubAiringUnavailable implements Exception {
  const HubAiringUnavailable({this.offline = false});

  /// True when nothing could reach the network.
  final bool offline;

  @override
  String toString() => offline
      ? 'Airing schedule unavailable (offline)'
      : 'Airing schedule unavailable';
}

/// Today's airing episodes for the Windows "Schedule and lists" page.
///
/// Reads the same AniList week schedule the Schedule screen uses and keeps
/// the entries on the current local calendar day.
///
/// Errors are NOT swallowed: a failed fetch (an exception from the service,
/// or an empty week, see [HubAiringUnavailable]) propagates so the data layer
/// can keep its cached rows. A day with nothing airing while the week has
/// entries is a genuine empty result and returns `[]`.
class HubAiringSource {
  HubAiringSource({AiringService? airing, DateTime Function()? clock})
    : _airing = airing ?? sl<AiringService>(),
      _clock = clock ?? DateTime.now;

  final AiringService _airing;
  final DateTime Function() _clock;

  /// Bound on the week fetch (up to 10 AniList pages). A timeout throws a
  /// [TimeoutException], which the data layer treats as a failed refresh.
  static const Duration timeout = Duration(seconds: 30);

  /// Rows airing today (local day), sorted by [HubAiringItem.airingAt].
  /// [isOnYourList] gets the row's show page item (or a bare anime item when
  /// AniList has no MAL id) plus the airing title, and decides the tag.
  Future<List<HubAiringItem>> today({
    required bool Function(MediaItem item, String title) isOnYourList,
  }) async {
    final now = _clock().toLocal();
    final week = await _airing.weekAiring(now: now).timeout(timeout);
    if (week.isEmpty) {
      throw HubAiringUnavailable(offline: _airing.lastFailureOffline);
    }
    final dayStart = DateTime(now.year, now.month, now.day);
    // Calendar-day arithmetic (not +24h) so DST change days stay correct.
    final dayEnd = DateTime(now.year, now.month, now.day + 1);
    final rows = <HubAiringItem>[];
    for (final e in week) {
      final at = e.airsAtLocal.toLocal();
      if (at.isBefore(dayStart) || !at.isBefore(dayEnd)) continue;
      final show = showItemFor(e);
      rows.add(
        HubAiringItem(
          title: e.title,
          episode: e.episode,
          airingAt: at,
          cover: e.coverUrl,
          onYourList: isOnYourList(show ?? _bareItem(e), e.title),
          item: show,
        ),
      );
    }
    rows.sort((a, b) => a.airingAt.compareTo(b.airingAt));
    return rows;
  }

  /// The show page item the Schedule opens for [e] (same shape as
  /// `openCanonical` in schedule_screen.dart). Null without a MAL id: the
  /// Schedule falls back to a title search there, so the row isn't clickable.
  static MediaItem? showItemFor(AiringEntry e) {
    final malId = e.malId;
    if (malId == null) return null;
    final c = ZCanonical(ZKind.anime, 'mal:$malId');
    // malId (as the AniList catalogue's own items carry it) lets the list
    // matcher match by id; the romaji altTitle rides in englishTitle (the
    // "romanized / English alternative" slot), mirroring FollowedShows'
    // title + alt check. Both survive the data layer's row cache.
    return MediaItem(
      id: c.id,
      title: e.title,
      englishTitle: e.altTitle,
      url: ZmodeIds.showUrl(c),
      type: ProviderType.anime,
      sourceId: ZmodeIds.sourceId,
      cover: e.coverUrl,
      malId: malId,
    );
  }

  /// Id-less stand-in so the list matcher can still compare titles.
  static MediaItem _bareItem(AiringEntry e) => MediaItem(
    id: '',
    title: e.title,
    englishTitle: e.altTitle,
    url: '',
    type: ProviderType.anime,
    sourceId: ZmodeIds.sourceId,
    cover: e.coverUrl,
  );
}
