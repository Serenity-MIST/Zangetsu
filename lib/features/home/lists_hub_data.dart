import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../../core/di/injector.dart';
import '../../core/hive/hive_key.dart';
import '../../core/hive/safe_box.dart';
import '../../core/mode/content_mode.dart';
import '../../core/models/media_item.dart';
import '../../core/models/provider_info.dart';
import '../../core/models/watch_status.dart';
import '../../core/profiles/profile_scope.dart';
import '../../core/profiles/viewer_profile.dart';
import '../../core/tracker/tracker.dart';
import '../../core/tracker/tracker_hub.dart';
import 'library_filter.dart';
import 'lists_hub_airing_source.dart';
import 'lists_hub_models.dart';

/// Signature of [HubAiringSource.today], injectable so tests can fake it.
/// Expected to THROW on failure (see [HubAiringSource]); an empty list means
/// "nothing airing today".
typedef HubAiringFetcher =
    Future<List<HubAiringItem>> Function({
      required bool Function(MediaItem item, String title) isOnYourList,
    });

/// The Windows "Schedule and lists" page's data: tracker list summaries and
/// today's airing rows, cached in one Hive box so the page renders instantly
/// and refreshes in the background.
///
/// Scoping: summaries are stored per app profile AND per tracker account
/// (tracker display name + [Tracker.viewerName], the only account identity the
/// [Tracker] interface exposes), so switching profile or tracker account never
/// shows another user's counts. Airing rows are stored per profile and their
/// "On your list" flag is recomputed on every read from the CURRENT accounts'
/// saved list index, never trusted from the cache.
///
/// Refreshes never throw; a failure keeps the cache and sets [lastError].
/// Concurrent refreshes of the same thing share one in-flight future.
class ListsHubDataImpl extends ChangeNotifier implements ListsHubData {
  ListsHubDataImpl({
    Iterable<Tracker> Function()? trackers,
    HubAiringFetcher? airingToday,
    String Function()? currentProfileId,
    DateTime Function()? clock,
    this.fetchTimeout = const Duration(seconds: 30),
    this.airingTimeout = const Duration(seconds: 45),
  }) : _trackers = trackers ?? _defaultTrackers,
       _airingOverride = airingToday,
       _profileId = currentProfileId ?? _defaultProfileId,
       _clock = clock ?? DateTime.now;

  /// Hive box holding every cached summary, list index and airing row.
  /// Pure cache (rebuilt from the network), so it is excluded from backup.
  static const String boxName = 'lists_hub_cache';

  /// Upper bounds so a hung request never leaves the page loading forever.
  /// A timeout counts as a failed refresh (cache kept, [lastError] set).
  /// Worst case for an airing refresh is fetchTimeout (list indexes, read
  /// in parallel) plus airingTimeout.
  final Duration fetchTimeout;
  final Duration airingTimeout;
  static const Duration openTimeout = Duration(seconds: 10);

  final Iterable<Tracker> Function() _trackers;
  final HubAiringFetcher? _airingOverride;
  final String Function() _profileId;
  final DateTime Function() _clock;

  static Iterable<Tracker> _defaultTrackers() =>
      sl.isRegistered<TrackerHub>() ? sl<TrackerHub>().trackers : const [];

  static String _defaultProfileId() => sl.isRegistered<ViewerProfileStore>()
      ? sl<ViewerProfileStore>().dataProfileId
      : kDefaultProfileId;

  Box<dynamic>? _box;
  Future<void>? _opening;
  bool _disposed = false;

  /// In-flight refreshes keyed by cache key, so concurrent callers join.
  final Map<String, Future<List<HubListSummary>>> _summaryJobs = {};
  final Map<String, Future<List<HubAiringItem>>> _airingJobs = {};

  /// Last failure per (profile, job key); success clears its entry.
  final Map<String, String> _errors = {};

  /// Decoded-cache memo so per-frame reads don't re-parse JSON.
  final Map<String, (String, Object?)> _memo = {};

  // ── Box ────────────────────────────────────────────────────────────────

  /// Opens the cache box. Safe to call repeatedly; never throws. The cached
  /// getters return null until it completes, then listeners are notified.
  Future<void> ensureLoaded() {
    // A box closed elsewhere (Hive.close, a restore) is dropped and reopened
    // rather than read, which would throw.
    if (_box != null && !_box!.isOpen) _box = null;
    if (_box != null) return Future.value();
    if (Hive.isBoxOpen(boxName)) {
      _box = Hive.box<dynamic>(boxName);
      return Future.value();
    }
    return _opening ??= () async {
      try {
        _box = await openBoxSafely<dynamic>(boxName).timeout(openTimeout);
        if (!_disposed) notifyListeners();
      } catch (e) {
        debugPrint('[lists_hub] cache unavailable: $e');
      } finally {
        _opening = null;
      }
    }();
  }

  /// The box when it is ready; otherwise starts opening it and returns null.
  Box<dynamic>? get _readyBox {
    final box = _box;
    if (box == null || !box.isOpen) {
      unawaited(ensureLoaded());
      return null;
    }
    return box;
  }

  String? _readRaw(String key) {
    final v = _readyBox?.get(key);
    return v is String ? v : null;
  }

  Future<void> _write(String key, Object value) async {
    await ensureLoaded();
    try {
      final box = _box;
      if (box != null && box.isOpen) await box.put(key, jsonEncode(value));
    } catch (e) {
      debugPrint('[lists_hub] cache write failed: $e');
    }
    _memo.remove(key);
  }

  /// Decodes [key]'s JSON once per stored value.
  Object? _decoded(String key) {
    final raw = _readRaw(key);
    if (raw == null) return null;
    final hit = _memo[key];
    if (hit != null && identical(hit.$1, raw)) return hit.$2;
    Object? value;
    try {
      value = jsonDecode(raw);
    } catch (_) {
      value = null; // a corrupt entry reads as "no cache"
    }
    _memo[key] = (raw, value);
    return value;
  }

  // ── Keys ───────────────────────────────────────────────────────────────

  /// Per profile + tracker + account. Null when the tracker has no account
  /// (not connected), so nothing cached is ever shown for it.
  String? _accountKey(Tracker t, [String? profile]) {
    final viewer = t.viewerName;
    if (!t.isConnected || viewer == null || viewer.isEmpty) return null;
    // hiveKey: the default profile keeps the raw key, and a Hive key must
    // stay under 255 bytes whatever the account name holds.
    return profileScopedKey(
      profile ?? _profileId(),
      hiveKey('lists:${t.displayName}|$viewer', maxBytes: 160),
    );
  }

  String _airingKey([String? profile]) =>
      profileScopedKey(profile ?? _profileId(), 'airing');
  String _updatedKey([String? profile]) =>
      profileScopedKey(profile ?? _profileId(), 'updated');

  String _day(DateTime d) {
    final l = d.toLocal();
    return '${l.year}-${l.month}-${l.day}';
  }

  // ── Summaries ──────────────────────────────────────────────────────────

  @override
  List<HubListSummary>? cachedSummaries(Tracker tracker) {
    final key = _accountKey(tracker);
    if (key == null) return null;
    final entry = _decoded(key);
    if (entry is! Map) return null;
    final list = entry['summaries'];
    if (list is! List) return null;
    return [
      for (final j in list) ?HubListSummary.fromJson(j),
    ];
  }

  @override
  Future<List<HubListSummary>> refreshSummaries(Tracker tracker) {
    final key = _accountKey(tracker);
    // Not connected: nothing to fetch and nothing to show.
    if (key == null) return Future.value(const []);
    return _summaryJobs[key] ??= _refreshSummaries(tracker, key).whenComplete(
      // Block body: returning the removed future would await itself.
      () {
        _summaryJobs.remove(key);
      },
    );
  }

  Future<List<HubListSummary>> _refreshSummaries(
    Tracker tracker,
    String key,
  ) async {
    final profile = _profileId();
    final errorKey = '$profile|$key';
    await ensureLoaded();
    final before = cachedSummaries(tracker);
    try {
      final items = await tracker.fetchList().timeout(fetchTimeout);
      // The account or profile changed while the list loaded: these items
      // belong to whoever is signed in NOW, so saving them under the old key
      // would show one user's list as another's. Drop them and read again
      // for the account signed in now (joins a refresh already running for
      // it; a caller that dedupes by tracker would otherwise never refill).
      if (_accountKey(tracker) != key) return await refreshSummaries(tracker);
      // fetchList() reports failure as `[]`. An empty answer over a cache that
      // had entries is far likelier a failed read than a wiped library, so it
      // keeps the cache (the retry affordance lets the user try again).
      if (items.isEmpty && before != null && before.any(_hasEntries)) {
        throw StateError('${tracker.displayName} returned an empty list');
      }
      final summaries = summarizeTrackerList(tracker, items);
      await _write(key, {
        'summaries': [for (final s in summaries) s.toJson()],
        'index': _ListIndex.fromItems(items).toJson(),
      });
      _errors.remove(errorKey);
      await _markUpdated(profile);
      _notify();
      return summaries;
    } catch (e) {
      _errors.remove(errorKey);
      _errors[errorKey] = '$e';
      _notify();
      return before ?? const [];
    }
  }

  static bool _hasEntries(HubListSummary s) =>
      s.active + s.planned + s.completed > 0 || s.covers.isNotEmpty;

  /// Builds one tile per list kind [tracker] holds (same kinds as the list
  /// screen's tabs) using the list screen's own split
  /// ([ContentMode.matchesProvider] on the item type). Covers are the three
  /// most recently updated entries with a cover; undated entries sort last.
  @visibleForTesting
  static List<HubListSummary> summarizeTrackerList(
    Tracker tracker,
    List<TrackerListItem> items,
  ) => [
    for (final kind in libraryKindsForTracker(tracker))
      _summaryFor(tracker.displayName, kind, items),
  ];

  static HubListSummary _summaryFor(
    String trackerName,
    ContentMode kind,
    List<TrackerListItem> all,
  ) {
    final mine = [
      for (final e in all)
        if (kind.matchesProvider(e.item.type)) e,
    ];
    int count(WatchStatus s) => mine.where((e) => e.status == s).length;
    final dated = [
      for (final e in mine)
        if ((e.item.cover ?? '').isNotEmpty) e,
    ];
    // Stable sort: equal/undated entries keep the tracker's own order.
    final order = List<int>.generate(dated.length, (i) => i)
      ..sort((a, b) {
        final ua = dated[a].updatedAt, ub = dated[b].updatedAt;
        if (ua == null && ub == null) return a.compareTo(b);
        if (ua == null) return 1;
        if (ub == null) return -1;
        final c = ub.compareTo(ua);
        return c != 0 ? c : a.compareTo(b);
      });
    return HubListSummary(
      trackerName: trackerName,
      kind: kind,
      active: count(WatchStatus.watching),
      planned: count(WatchStatus.planning),
      completed: count(WatchStatus.completed),
      covers: [for (final i in order.take(3)) dated[i].item.cover!],
    );
  }

  // ── Airing today ───────────────────────────────────────────────────────

  @override
  List<HubAiringItem>? cachedAiringToday() {
    final entry = _decoded(_airingKey());
    if (entry is! Map || entry['day'] != _day(_clock())) return null;
    final rows = entry['rows'];
    if (rows is! List) return null;
    final match = _onYourListMatcher();
    final out = <HubAiringItem>[];
    for (final r in rows) {
      final row = _rowFromJson(r);
      if (row == null) continue;
      out.add(
        HubAiringItem(
          title: row.title,
          episode: row.episode,
          airingAt: row.airingAt,
          cover: row.cover,
          item: row.item,
          // Recomputed for the accounts connected NOW, never read back.
          onYourList: match(row.item ?? _bareItem(row.title), row.title),
        ),
      );
    }
    return out..sort((a, b) => a.airingAt.compareTo(b.airingAt));
  }

  @override
  Future<List<HubAiringItem>> refreshAiringToday() {
    final key = _airingKey();
    return _airingJobs[key] ??= _refreshAiring(key).whenComplete(() {
      _airingJobs.remove(key);
    });
  }

  Future<List<HubAiringItem>> _refreshAiring(String key) async {
    final profile = _profileId();
    final errorKey = '$profile|$key';
    try {
      await ensureLoaded();
      // A connected account with no saved list index yet is read first (or
      // joins a refresh already running), so tags are right on first load.
      await Future.wait([
        for (final t in _trackers())
          if (_accountKey(t) case final k? when _index(k) == null)
            refreshSummaries(t),
      ]);
      final fetch = _airingOverride ?? HubAiringSource().today;
      final rows = await fetch(
        isOnYourList: _onYourListMatcher(),
      ).timeout(airingTimeout);
      final sorted = [...rows]
        ..sort((a, b) => a.airingAt.compareTo(b.airingAt));
      await _write(key, {
        'day': _day(_clock()),
        'rows': [for (final r in sorted) _rowToJson(r)],
      });
      _errors.remove(errorKey);
      await _markUpdated(profile);
      _notify();
      return sorted;
    } catch (e) {
      _errors.remove(errorKey);
      _errors[errorKey] = '$e';
      _notify();
      return cachedAiringToday() ?? const [];
    }
  }

  /// "On your list" for any connected account's saved video list: MAL /
  /// AniList / TMDB id first, else normalised title (the Schedule's rule).
  bool Function(MediaItem item, String title) _onYourListMatcher() {
    final indexes = [
      for (final t in _trackers())
        if (_accountKey(t) case final k?) ?_index(k),
    ];
    if (indexes.isEmpty) return (_, _) => false;
    return (item, title) => indexes.any((i) => i.matches(item, title));
  }

  _ListIndex? _index(String accountKey) {
    final entry = _decoded(accountKey);
    return entry is Map ? _ListIndex.fromJson(entry['index']) : null;
  }

  static MediaItem _bareItem(String title) => MediaItem(
    id: '',
    title: title,
    url: '',
    type: ProviderType.anime,
    sourceId: '',
  );

  static Map<String, Object?> _rowToJson(HubAiringItem r) => {
    'title': r.title,
    'ep': r.episode,
    'at': r.airingAt.millisecondsSinceEpoch,
    'cover': r.cover,
    'item': r.item?.toJson(),
  };

  static HubAiringItem? _rowFromJson(Object? j) {
    if (j is! Map) return null;
    final title = j['title'], ep = j['ep'], at = j['at'];
    if (title is! String || ep is! int || at is! int) return null;
    MediaItem? item;
    final raw = j['item'];
    if (raw is Map) {
      try {
        item = MediaItem.fromJson(Map<String, dynamic>.from(raw));
      } catch (_) {
        item = null; // row stays, just not clickable
      }
    }
    final cover = j['cover'];
    return HubAiringItem(
      title: title,
      episode: ep,
      airingAt: DateTime.fromMillisecondsSinceEpoch(at),
      cover: cover is String ? cover : null,
      item: item,
    );
  }

  // ── Status ─────────────────────────────────────────────────────────────

  @override
  DateTime? get lastUpdated {
    final ms = _readyBox?.get(_updatedKey());
    return ms is int ? DateTime.fromMillisecondsSinceEpoch(ms) : null;
  }

  /// Stamps [profile]'s "updated" time. The profile is captured when the
  /// refresh began, so a profile switch mid-refresh can't stamp the other one.
  Future<void> _markUpdated(String profile) async {
    await ensureLoaded();
    try {
      final box = _box;
      if (box != null && box.isOpen) {
        await box.put(_updatedKey(profile), _clock().millisecondsSinceEpoch);
      }
    } catch (_) {}
  }

  /// Latest failure for the current profile, counting only accounts that are
  /// connected now (plus airing). An error left by an account that was since
  /// disconnected or switched would otherwise show "Couldn't refresh" with
  /// nothing left to retry.
  @override
  String? get lastError {
    final profile = _profileId();
    final live = {
      '$profile|${_airingKey(profile)}',
      for (final t in _trackers())
        if (_accountKey(t, profile) case final k?) '$profile|$k',
    };
    String? last;
    for (final e in _errors.entries) {
      if (live.contains(e.key)) last = e.value;
    }
    return last;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Compact ids/titles of an account's video entries, saved next to its
/// summaries so "On your list" works from cache without refetching.
class _ListIndex {
  const _ListIndex(this.mal, this.anilist, this.tmdb, this.titles);

  final Set<int> mal;
  final Set<int> anilist;
  final Set<int> tmdb;

  /// Already passed through [normalizeTitle].
  final Set<String> titles;

  /// Anime-type entries only, exactly like the Schedule's FollowedShows. The
  /// airing feed is anime; counting movie/TV entries let a live-action show
  /// with the same title (e.g. "One Piece") tag the anime as on your list.
  factory _ListIndex.fromItems(List<TrackerListItem> items) {
    final video = [
      for (final e in items)
        if (e.item.type == ProviderType.anime) e.item,
    ];
    return _ListIndex(
      {for (final m in video) ?m.malId},
      {for (final m in video) ?m.anilistId},
      {for (final m in video) ?m.tmdbId},
      {
        for (final m in video) ...[
          normalizeTitle(m.title),
          if (m.englishTitle != null) normalizeTitle(m.englishTitle!),
        ],
      }..remove(''),
    );
  }

  static _ListIndex? fromJson(Object? j) {
    if (j is! Map) return null;
    Set<int> ints(Object? v) => {
      for (final x in (v is List ? v : const []))
        if (x is int) x,
    };
    final t = j['titles'];
    return _ListIndex(ints(j['mal']), ints(j['al']), ints(j['tmdb']), {
      for (final x in (t is List ? t : const []))
        if (x is String) x,
    });
  }

  Map<String, Object?> toJson() => {
    'mal': mal.toList(),
    'al': anilist.toList(),
    'tmdb': tmdb.toList(),
    'titles': titles.toList(),
  };

  bool matches(MediaItem item, String title) {
    if (item.malId != null && mal.contains(item.malId)) return true;
    if (item.anilistId != null && anilist.contains(item.anilistId)) {
      return true;
    }
    if (item.tmdbId != null && tmdb.contains(item.tmdbId)) return true;
    if (titles.isEmpty) return false;
    return titles.contains(normalizeTitle(title)) ||
        titles.contains(normalizeTitle(item.title)) ||
        (item.englishTitle != null &&
            titles.contains(normalizeTitle(item.englishTitle!)));
  }
}
