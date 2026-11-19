import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../di/injector.dart';
import '../models/media_detail.dart';
import '../models/media_item.dart';
import '../models/provider_info.dart';
import '../models/watch_status.dart';
import '../privacy/incognito_mode.dart';
import '../repository/catalogue_repository.dart';
import '../ui/global_messenger.dart';
import '../ui/list_status_sheet.dart' show syncListStatusToTrackers;
import 'list_status_store.dart';
import 'my_list.dart';
import 'playback_prefs.dart';

/// What happened in the player that may move a show between list statuses.
enum ListAutoEvent {
  /// An episode started playing for real (past the resume threshold).
  started,

  /// An episode was watched to the end (the same 92% mark the trackers use).
  finished,
}

/// The status a show should move to after [event], or null to leave it alone.
///
/// [current] is null when the show is not on the list at all. [finale] is true
/// only when the finished episode is the last one of a show that has finished
/// airing. The rules:
/// * starting anything not yet in progress (not on the list, Plan to watch,
///   Paused, Dropped) moves it to Watching;
/// * finishing the finale moves anything to Completed;
/// * Watching stays Watching, and a Completed show stays Completed on a rewatch.
WatchStatus? autoListStatus({
  required WatchStatus? current,
  required ListAutoEvent event,
  bool finale = false,
}) {
  if (event == ListAutoEvent.finished && finale) {
    return current == WatchStatus.completed ? null : WatchStatus.completed;
  }
  return switch (current) {
    null ||
    WatchStatus.planning ||
    WatchStatus.paused ||
    WatchStatus.dropped => WatchStatus.watching,
    WatchStatus.watching || WatchStatus.completed => null,
  };
}

/// Whether [episode] is the final episode of a show that finished airing.
/// [lastEpisode] is the highest episode number the show has.
bool isFinale({
  required bool finishedAiring,
  required double? episode,
  required double? lastEpisode,
}) =>
    finishedAiring &&
    episode != null &&
    lastEpisode != null &&
    episode >= lastEpisode;

/// Whether no more episodes/chapters are coming: finished, or cancelled, with
/// nothing scheduled next.
bool showFinished(MediaDetail detail) =>
    (detail.status == MediaStatus.completed ||
        detail.status == MediaStatus.cancelled) &&
    detail.nextEpisode == null;

/// What the detail page knew about a show when it was opened.
class _ShowFacts {
  _ShowFacts(this.item, this.finishedAiring, this.lastEpisode);
  final MediaItem item;
  final bool finishedAiring;
  final double? lastEpisode;
}

/// Windows only: keeps My List in step with what you actually watch.
///
/// The detail page registers each show it opens ([rememberShow]); the player
/// reports [ListAutoEvent]s by the show's page URL. Each change goes through
/// the same path as the status sheet (local list, cloud row, trackers) and is
/// announced with an Undo. Respects the auto-track preference and incognito.
class ListAutoStatus {
  ListAutoStatus._();
  static final ListAutoStatus instance = ListAutoStatus._();

  final Map<String, _ShowFacts> _shows = {};

  static bool get _enabled =>
      defaultTargetPlatform == TargetPlatform.windows &&
      !IncognitoMode.on &&
      (!sl.isRegistered<PlaybackPrefs>() || sl<PlaybackPrefs>().autoTrack);

  /// Called by the detail page once the show's details are known.
  void rememberShow(MediaItem item, MediaDetail detail) {
    if (item.url.isEmpty) return;
    double? last;
    for (final e in detail.episodes) {
      final n = e.number;
      if (n != null && (last == null || n > last)) last = n;
    }
    _shows[item.url] = _ShowFacts(
      item,
      showFinished(detail),
      last,
    );
  }

  /// The player started an episode of the show at [showUrl].
  Future<void> onStarted(String? showUrl) =>
      _handle(showUrl, ListAutoEvent.started, null);

  /// The player finished episode [episode] of the show at [showUrl].
  Future<void> onFinished(String? showUrl, double? episode) =>
      _handle(showUrl, ListAutoEvent.finished, episode);

  /// Reader progress for chapter [chapter] of the title at [showUrl]:
  /// [finished] once that chapter was read to its end. Reported once per
  /// title (start) and once per chapter (finish) per app session, because the
  /// readers save progress on every page turn.
  Future<void> onReadProgress(
    String? showUrl,
    double? chapter, {
    required bool finished,
  }) {
    final key = finished ? '$showUrl#done:$chapter' : '$showUrl#start';
    if (!_readReported.add(key)) return Future.value();
    return _handle(
      showUrl,
      finished ? ListAutoEvent.finished : ListAutoEvent.started,
      chapter,
    );
  }

  final Set<String> _readReported = {};

  static bool _isReading(MediaItem m) =>
      m.type == ProviderType.manga || m.type == ProviderType.novel;

  /// The list status the show is in now (null when not on the list), so the
  /// player can avoid telling trackers "watching" about a Completed rewatch.
  WatchStatus? currentStatus(String? showUrl) {
    final item = _itemFor(showUrl);
    return item == null ? null : _statusOf(item);
  }

  MediaItem? _itemFor(String? showUrl) {
    if (showUrl == null || showUrl.isEmpty) return null;
    final known = _shows[showUrl]?.item;
    if (known != null) return known;
    if (!sl.isRegistered<MyListStore>()) return null;
    for (final m in sl<MyListStore>().all()) {
      if (m.url == showUrl) return m;
    }
    return null;
  }

  WatchStatus? _statusOf(MediaItem item) {
    if (!sl<MyListStore>().contains(item)) return null;
    // On the list with no status yet reads as "planned".
    return sl<ListStatusStore>().statusOf(item) ?? WatchStatus.planning;
  }

  Future<void> _handle(
    String? showUrl,
    ListAutoEvent event,
    double? episode,
  ) async {
    if (!_enabled || showUrl == null || showUrl.isEmpty) return;
    if (!sl.isRegistered<MyListStore>() || !sl.isRegistered<ListStatusStore>()) {
      return;
    }
    try {
      var facts = _shows[showUrl];
      final item = _itemFor(showUrl);
      if (item == null) return; // nothing we can safely add
      // Finishing an episode needs to know whether it was the finale. A show
      // opened straight from Continue Watching skipped the detail page, so
      // ask once (cached by the repository) and remember the answer.
      if (event == ListAutoEvent.finished && facts == null &&
          sl.isRegistered<CatalogueRepository>()) {
        final d = await sl<CatalogueRepository>()
            .detail(item.url, sourceId: item.sourceId)
            .timeout(const Duration(seconds: 12));
        rememberShow(item, d);
        facts = _shows[showUrl];
      }
      final current = _statusOf(item);
      final next = autoListStatus(
        current: current,
        event: event,
        finale: isFinale(
          finishedAiring: facts?.finishedAiring ?? false,
          episode: episode,
          lastEpisode: facts?.lastEpisode,
        ),
      );
      if (next == null) return;
      // Adding a show that is not listed yet follows the existing
      // "Auto-add to My List" setting (on by default), like Play on Detail.
      if (current == null &&
          sl.isRegistered<PlaybackPrefs>() &&
          !sl<PlaybackPrefs>().autoAddToMyList) {
        return;
      }
      await _apply(item, next);
      if (_statusOf(item) != next) return; // not signed in: nothing changed
      _announce(item, from: current, to: next);
    } catch (e) {
      debugPrint('[list-auto] $e');
    }
  }

  Future<void> _apply(MediaItem item, WatchStatus status) async {
    final myList = sl<MyListStore>();
    await myList.add(item); // no-op when signed out or already listed
    if (!myList.contains(item)) return;
    await sl<ListStatusStore>().setStatus(item, status);
    await myList.pushStatus(item);
    unawaited(_trackers(item, status));
  }

  Future<void> _trackers(MediaItem item, WatchStatus? status,
      {bool remove = false}) =>
      syncListStatusToTrackers(
        item,
        status,
        item.malId,
        item.tmdbId,
        item.tmdbIsTv,
        item.imdbId,
        item.type == ProviderType.anime,
        reading: _isReading(item),
        remove: remove,
      );

  /// Puts the show back where it was before an automatic change.
  Future<void> _undo(MediaItem item, WatchStatus? before) async {
    final myList = sl<MyListStore>();
    if (before == null) {
      await myList.remove(item);
      await sl<ListStatusStore>().remove(item);
      unawaited(_trackers(item, null, remove: true));
      return;
    }
    await sl<ListStatusStore>().setStatus(item, before);
    await myList.pushStatus(item);
    unawaited(_trackers(item, before));
  }

  void _announce(MediaItem item,
      {required WatchStatus? from, required WatchStatus to}) {
    final messenger = rootMessengerKey.currentState;
    if (messenger == null) return;
    final verb = from == null ? 'Added' : 'Moved';
    messenger.showSnackBar(SnackBar(
      key: const ValueKey('list-auto-status'),
      content: Text('$verb "${item.title}" to '
          '${labelFor(to, reading: _isReading(item))}'),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 6),
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () => unawaited(_undo(item, from)),
      ),
    ));
  }
}
