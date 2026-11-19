import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/models/media_item.dart' show normalizeTitle;
import '../../core/models/provider_info.dart';
import '../../core/mode/content_mode.dart';
import '../../core/playback/my_list.dart';
import '../../core/schedule/airing_service.dart';
import '../../core/schedule/coming_soon_service.dart';
import '../../core/schedule/schedule_models.dart';
import '../../core/tracker/tracker.dart';
import '../../core/tracker/tracker_hub.dart';
import 'schedule_offline_cache.dart';

class ScheduleState extends Equatable {
  const ScheduleState({
    this.airingAll = const [],
    this.airingByDay = const {},
    this.myListByDay = const {},
    this.comingSoon = const [],
    this.loadingAiring = true,
    this.loadingSoon = true,
    this.errorAiring = false,
    this.offline = false,
    this.errorSoon = false,
    // ── redesign additions (phone) ──
    this.selectedDay,
    this.myListOnly = false,
    this.followed = const FollowedShows(),
    this.soonByDay = const {},
    this.connectedTrackerNames = const [],
    this.trackerFilterName,
    this.trackerFollowedByName = const {},
    this.loadingTrackerName,
    this.airingSavedAt,
    this.soonSavedAt,
    this.lastUpdated,
  });

  final List<AiringEntry> airingAll;

  /// All week airing entries grouped by local day (the week view / TV Anime).
  final Map<DateTime, List<AiringEntry>> airingByDay;

  /// Week airing narrowed to tracked anime, grouped by day (TV My List tab).
  /// Kept for the unchanged TV screen; the phone redesign uses [followed]
  /// with [myListOnly] instead.
  final Map<DateTime, List<AiringEntry>> myListByDay;

  final List<ComingSoonEntry> comingSoon;
  final bool loadingAiring;
  final bool loadingSoon;
  final bool errorAiring;

  /// Nothing reached the network on the last load. Distinct from an empty
  /// schedule: "nothing airing this week" is a claim, and it should not be
  /// made on a dropped connection.
  final bool offline;
  final bool errorSoon;

  // ── redesign additions ──
  /// The day whose episode list is shown. Null until first load (→ today).
  final DateTime? selectedDay;

  /// My List filter toggle — when on, the anime list/grid narrows to shows the
  /// user follows.
  final bool myListOnly;

  /// MAL ids of anime in My List — drives the green "you follow this" dot and
  /// the [myListOnly] filter. Matches on MAL id OR title — see [FollowedShows].
  final FollowedShows followed;

  /// Coming-soon movies/TV grouped by local release day (both views).
  final Map<DateTime, List<ComingSoonEntry>> soonByDay;

  /// Connected anime-capable trackers available in the schedule filter.
  final List<String> connectedTrackerNames;

  /// Selected tracker name; null means All unless [myListOnly] is true.
  final String? trackerFilterName;

  /// Session-cached tracker libraries, converted to the same title/id matcher
  /// used by the existing local My List filter.
  final Map<String, FollowedShows> trackerFollowedByName;

  /// Name of the tracker whose list is currently being fetched, if any.
  final String? loadingTrackerName;

  /// Set while the anime rows on screen are the saved offline copy
  /// (Windows, track-5 B): when that copy was fetched. Null = live data.
  final DateTime? airingSavedAt;

  /// Same as [airingSavedAt] for the movies/TV rows.
  final DateTime? soonSavedAt;

  /// When a load last succeeded, for the Windows "Updated N min ago".
  final DateTime? lastUpdated;

  /// Active filter, or null when the schedule shows every airing.
  FollowedShows? get activeFollowed {
    if (myListOnly) return followed;
    final name = trackerFilterName;
    return name == null
        ? null
        : trackerFollowedByName[name] ?? const FollowedShows();
  }

  ScheduleState copyWith({
    List<AiringEntry>? airingAll,
    Map<DateTime, List<AiringEntry>>? airingByDay,
    Map<DateTime, List<AiringEntry>>? myListByDay,
    List<ComingSoonEntry>? comingSoon,
    bool? loadingAiring,
    bool? loadingSoon,
    bool? errorAiring,
    bool? offline,
    bool? errorSoon,
    DateTime? selectedDay,
    bool? myListOnly,
    FollowedShows? followed,
    Map<DateTime, List<ComingSoonEntry>>? soonByDay,
    List<String>? connectedTrackerNames,
    String? trackerFilterName,
    bool clearTrackerFilterName = false,
    Map<String, FollowedShows>? trackerFollowedByName,
    String? loadingTrackerName,
    bool clearLoadingTrackerName = false,
    DateTime? airingSavedAt,
    bool clearAiringSavedAt = false,
    DateTime? soonSavedAt,
    bool clearSoonSavedAt = false,
    DateTime? lastUpdated,
  }) => ScheduleState(
    airingAll: airingAll ?? this.airingAll,
    airingByDay: airingByDay ?? this.airingByDay,
    myListByDay: myListByDay ?? this.myListByDay,
    comingSoon: comingSoon ?? this.comingSoon,
    loadingAiring: loadingAiring ?? this.loadingAiring,
    loadingSoon: loadingSoon ?? this.loadingSoon,
    errorAiring: errorAiring ?? this.errorAiring,
    offline: offline ?? this.offline,
    errorSoon: errorSoon ?? this.errorSoon,
    selectedDay: selectedDay ?? this.selectedDay,
    myListOnly: myListOnly ?? this.myListOnly,
    followed: followed ?? this.followed,
    soonByDay: soonByDay ?? this.soonByDay,
    connectedTrackerNames: connectedTrackerNames ?? this.connectedTrackerNames,
    trackerFilterName: clearTrackerFilterName
        ? null
        : trackerFilterName ?? this.trackerFilterName,
    trackerFollowedByName: trackerFollowedByName ?? this.trackerFollowedByName,
    loadingTrackerName: clearLoadingTrackerName
        ? null
        : loadingTrackerName ?? this.loadingTrackerName,
    airingSavedAt: clearAiringSavedAt
        ? null
        : airingSavedAt ?? this.airingSavedAt,
    soonSavedAt: clearSoonSavedAt ? null : soonSavedAt ?? this.soonSavedAt,
    lastUpdated: lastUpdated ?? this.lastUpdated,
  );

  @override
  List<Object?> get props => [
    airingAll,
    airingByDay,
    myListByDay,
    comingSoon,
    loadingAiring,
    loadingSoon,
    errorAiring,
    errorSoon,
    offline,
    selectedDay,
    myListOnly,
    followed,
    soonByDay,
    connectedTrackerNames,
    trackerFilterName,
    trackerFollowedByName,
    loadingTrackerName,
    airingSavedAt,
    soonSavedAt,
    lastUpdated,
  ];
}

class ScheduleCubit extends Cubit<ScheduleState> {
  ScheduleCubit(
    this._airing,
    this._soon,
    this._myList, {
    List<Duration>? retryDelays,
    TrackerHub? trackerHub,
    ScheduleOfflineCache? offlineCache,
    ValueListenable<int>? trackerListChanges,
    bool reloadTrackersOnRefresh = false,
    Duration trackerInvalidateDelay = const Duration(seconds: 4),
  }) : _retryDelays = retryDelays ?? _defaultRetryDelays,
       _trackerHub = trackerHub,
       _offlineCache = offlineCache,
       _trackerListChanges = trackerListChanges,
       _reloadTrackersOnRefresh = reloadTrackersOnRefresh,
       _trackerInvalidateDelay = trackerInvalidateDelay,
       super(const ScheduleState()) {
    _myList.revision.addListener(_onLibraryChanged);
    // Windows (track-11 B): a list/status edit made in the app also goes to
    // the trackers, so their cached lists are stale from then on.
    _trackerListChanges?.addListener(_onTrackerListsEdited);
    final hub = _trackerHub;
    if (hub != null) {
      _syncConnectedTrackers();
      for (final tracker in hub.trackers) {
        void listener() => _onTrackerChanged(tracker);
        _trackerListeners[tracker] = listener;
        tracker.addListener(listener);
      }
    }
  }

  final AiringService _airing;
  final ComingSoonService _soon;
  final MyListStore _myList;
  final TrackerHub? _trackerHub;

  /// Saved last good week (Windows only; null keeps phone behaviour).
  final ScheduleOfflineCache? _offlineCache;

  /// Bumps when the app edits a list status (Windows, track-11 B).
  final ValueListenable<int>? _trackerListChanges;

  /// refresh() also re-reads tracker filter lists (Windows, track-11 A).
  final bool _reloadTrackersOnRefresh;

  /// Wait after a status edit before refetching: the tracker write runs in
  /// the background after the local store changes, so give it time to land.
  final Duration _trackerInvalidateDelay;
  Timer? _trackerInvalidateTimer;

  final Map<String, int> _trackerRequestVersions = {};
  final Set<String> _fetchingTrackers = {};
  final Map<Tracker, VoidCallback> _trackerListeners = {};

  // Backoff between retries when a fetch comes back empty. Both services
  // already swallow errors and return [] on failure, and neither AniList's
  // weekly airing nor TMDB's upcoming window is ever legitimately empty — so
  // an empty result means the request failed (e.g. network not ready at the
  // startup load) and is worth retrying. Stays on the loading spinner across
  // retries rather than flashing a false "nothing here". Injectable so tests
  // can pass `const []` and skip the real delays.
  static const List<Duration> _defaultRetryDelays = [
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
  ];
  final List<Duration> _retryDelays;

  bool _inFlight = false;

  /// Set by [rollOverDay] when a load was already running (Windows).
  bool _reloadAfterFlight = false;

  static DateTime _dayOf(DateTime d) => DateTime(d.year, d.month, d.day);

  Future<void> load() async {
    if (_inFlight) return; // don't stack retry loops (e.g. refresh mid-retry)
    _inFlight = true;
    // Seed today on the first load so the day strip has a selection.
    final now = DateTime.now();
    if (state.selectedDay == null) {
      emit(state.copyWith(selectedDay: _dayOf(now)));
    }
    try {
      await _showSavedCopyIfEmpty();
      await Future.wait([_loadAiring(), _loadSoon()]);
    } finally {
      _inFlight = false;
    }
    // A midnight roll-over that arrived mid-load still needs the new week.
    if (_reloadAfterFlight && !isClosed) {
      _reloadAfterFlight = false;
      await load();
    }
  }

  Future<void> refresh() {
    // Windows (track-11 A): a manual refresh must not keep a tracker list
    // fetched earlier this session; re-read the active one, drop the rest.
    if (_reloadTrackersOnRefresh) _invalidateTrackerLists();
    return load();
  }

  /// Windows (track-4): the page stays alive past midnight. Call with the
  /// local day the page last saw as "today"; when the day has changed and
  /// the selection was still on that old today, it moves to the new today,
  /// and the week is reloaded so the newest day is not left empty.
  /// Returns true when it reloaded.
  bool rollOverDay(DateTime previousToday, {DateTime? now}) {
    final today = _dayOf(now ?? DateTime.now());
    final before = _dayOf(previousToday);
    if (today == before) return false;
    final selected = state.selectedDay;
    if (selected == null || selected == before) selectDay(today);
    // load() ignores calls while one runs; queue one so the reload is not
    // lost when the day changes during a (retrying) load.
    if (_inFlight) {
      _reloadAfterFlight = true;
    } else {
      unawaited(load());
    }
    return true;
  }

  void selectDay(DateTime day) =>
      emit(state.copyWith(selectedDay: _dayOf(day)));

  void selectAllAirings() {
    emit(
      state.copyWith(
        myListOnly: false,
        clearTrackerFilterName: true,
        clearLoadingTrackerName: true,
      ),
    );
  }

  void selectMyListFilter() {
    emit(
      state.copyWith(
        myListOnly: true,
        clearTrackerFilterName: true,
        clearLoadingTrackerName: true,
      ),
    );
  }

  /// Kept for existing callers: tapping My List still toggles between it and
  /// All, and always clears a selected tracker filter.
  void toggleMyListOnly() =>
      state.myListOnly ? selectAllAirings() : selectMyListFilter();

  /// Read and cache the selected tracker's anime list on demand. Merely
  /// opening Schedule never causes a tracker API request.
  Future<void> selectTrackerFilter(String trackerName) async {
    Tracker? tracker;
    for (final candidate in _connectedAnimeTrackers) {
      if (candidate.displayName == trackerName) {
        tracker = candidate;
        break;
      }
    }
    if (tracker == null) {
      selectAllAirings();
      return;
    }

    emit(
      state.copyWith(
        myListOnly: false,
        trackerFilterName: trackerName,
        clearLoadingTrackerName: true,
      ),
    );
    if (state.trackerFollowedByName.containsKey(trackerName)) return;
    if (_fetchingTrackers.contains(trackerName)) {
      emit(state.copyWith(loadingTrackerName: trackerName));
      return;
    }

    await _fetchTracker(tracker);
  }

  List<Tracker> get _connectedAnimeTrackers =>
      _trackerHub?.connectedForMode(ContentMode.anime).toList() ?? const [];

  void _syncConnectedTrackers() {
    emit(
      state.copyWith(
        connectedTrackerNames: [
          for (final tracker in _connectedAnimeTrackers) tracker.displayName,
        ],
      ),
    );
  }

  void _onTrackerChanged(Tracker tracker) {
    final hub = _trackerHub;
    if (hub == null) return;
    final names = [
      for (final connected in hub.connectedForMode(ContentMode.anime))
        connected.displayName,
    ];
    if (listEquals(names, state.connectedTrackerNames)) return;

    // A disconnect during a fetch invalidates that response so it cannot
    // repopulate a now-disconnected filter. Other tracker requests stay valid.
    if (!names.contains(tracker.displayName)) {
      _trackerRequestVersions[tracker.displayName] =
          (_trackerRequestVersions[tracker.displayName] ?? 0) + 1;
      _fetchingTrackers.remove(tracker.displayName);
    }
    final followed = Map<String, FollowedShows>.of(state.trackerFollowedByName)
      ..remove(tracker.displayName);
    final selectedDisconnected =
        state.trackerFilterName == tracker.displayName &&
        !names.contains(tracker.displayName);
    emit(
      state.copyWith(
        connectedTrackerNames: names,
        trackerFollowedByName: followed,
        myListOnly: selectedDisconnected ? false : state.myListOnly,
        clearTrackerFilterName: selectedDisconnected,
        clearLoadingTrackerName:
            state.loadingTrackerName == tracker.displayName,
      ),
    );
  }

  /// Status edit seen (track-11 B): debounce, then invalidate.
  void _onTrackerListsEdited() {
    if (isClosed) return;
    _trackerInvalidateTimer?.cancel();
    _trackerInvalidateTimer = Timer(_trackerInvalidateDelay, () {
      if (!isClosed) _invalidateTrackerLists();
    });
  }

  /// Forgets every cached tracker list. The active filter keeps showing its
  /// old list while a quiet refetch runs (no empty flash, no skeleton); the
  /// others are simply fetched again the next time they are picked.
  void _invalidateTrackerLists() {
    final active = state.trackerFilterName;
    final keep = <String, FollowedShows>{};
    final activeCached = active == null
        ? null
        : state.trackerFollowedByName[active];
    if (active != null && activeCached != null) keep[active] = activeCached;
    // Drop in-flight answers for the dropped lists so they cannot come back.
    for (final name in state.trackerFollowedByName.keys) {
      if (name == active) continue;
      _trackerRequestVersions[name] = (_trackerRequestVersions[name] ?? 0) + 1;
      _fetchingTrackers.remove(name);
    }
    emit(state.copyWith(trackerFollowedByName: keep));
    if (active == null || activeCached == null) return;
    for (final tracker in _connectedAnimeTrackers) {
      if (tracker.displayName == active) {
        unawaited(_fetchTracker(tracker, quiet: true));
        break;
      }
    }
  }

  /// Reads [tracker]'s list into the filter cache. [quiet] = a background
  /// re-read: no loading state, and a failure keeps the list already cached.
  Future<void> _fetchTracker(Tracker tracker, {bool quiet = false}) async {
    final name = tracker.displayName;
    final version = (_trackerRequestVersions[name] ?? 0) + 1;
    _trackerRequestVersions[name] = version;
    _fetchingTrackers.add(name);
    if (!quiet) emit(state.copyWith(loadingTrackerName: name));

    var followed = const FollowedShows();
    var failed = false;
    try {
      final items = await tracker.fetchList();
      // fetchList() answers [] on any error instead of throwing, so a quiet
      // re-read that comes back empty is treated as failed: it must not wipe
      // a good cached list while offline (track-11).
      if (quiet && items.isEmpty) failed = true;
      followed = _followedShowsFromTracker(items);
    } catch (_) {
      // Tracker implementations are best-effort, but keep the schedule usable
      // even if a third-party implementation throws unexpectedly.
      failed = true;
    }

    if (isClosed || _trackerRequestVersions[name] != version) return;
    _fetchingTrackers.remove(name);
    final previous = state.trackerFollowedByName[name];
    final cache = Map<String, FollowedShows>.of(state.trackerFollowedByName)
      ..[name] = quiet && failed && previous != null ? previous : followed;
    emit(
      state.copyWith(
        trackerFollowedByName: cache,
        clearLoadingTrackerName: state.loadingTrackerName == name,
      ),
    );
  }

  FollowedShows _followedShowsFromTracker(List<TrackerListItem> items) {
    final anime = items.where((entry) => entry.item.type == ProviderType.anime);
    return FollowedShows(
      malIds: {
        for (final entry in anime)
          if (entry.item.malId != null) entry.item.malId!,
      },
      titles: {
        for (final entry in anime) ...[
          normalizeTitle(entry.item.title),
          if (entry.item.englishTitle != null)
            normalizeTitle(entry.item.englishTitle!),
        ],
      }..removeWhere((title) => title.isEmpty),
    );
  }

  /// Retained calendars must reflect local edits and asynchronous cloud pulls
  /// without another network fetch or resetting the user's calendar selection.
  void _onLibraryChanged() {
    if (isClosed) return;
    final followed = _followedShows();
    emit(state.copyWith(
      followed: followed,
      myListByDay: groupByLocalDay(filterByFollowed(state.airingAll, followed)),
    ));
  }

  @override
  Future<void> close() {
    _myList.revision.removeListener(_onLibraryChanged);
    _trackerListChanges?.removeListener(_onTrackerListsEdited);
    _trackerInvalidateTimer?.cancel();
    _trackerListeners.forEach((tracker, listener) {
      tracker.removeListener(listener);
    });
    return super.close();
  }

  Future<void> _loadAiring() async {
    emit(state.copyWith(loadingAiring: true, errorAiring: false));
    var entries = await _airing.weekAiring();
    for (var i = 0; entries.isEmpty && i < _retryDelays.length; i++) {
      await Future<void>.delayed(_retryDelays[i]);
      if (isClosed) return; // widget disposed mid-retry
      entries = await _airing.weekAiring();
    }
    if (isClosed) return;
    final followed = _followedShows();
    // Windows: a good load is saved; a failed one falls back to that copy.
    final cache = _offlineCache;
    final saved = entries.isEmpty ? cache?.readAiring() : null;
    final usingSaved = saved != null && saved.entries.isNotEmpty;
    if (usingSaved) entries = saved.entries;
    final now = DateTime.now();
    if (cache != null && !usingSaved && entries.isNotEmpty) {
      unawaited(cache.writeAiring(entries, now));
    }
    emit(
      state.copyWith(
        airingAll: entries,
        airingByDay: groupByLocalDay(entries),
        myListByDay: groupByLocalDay(filterByFollowed(entries, followed)),
        followed: followed,
        loadingAiring: false,
        // Still empty after retries → genuine miss. Stays true while the
        // saved copy is shown, so the page can say the load failed.
        errorAiring: usingSaved || entries.isEmpty,
        offline:
            (usingSaved || entries.isEmpty) && _airing.lastFailureOffline,
        airingSavedAt: usingSaved ? saved.savedAt : null,
        clearAiringSavedAt: !usingSaved,
        lastUpdated: !usingSaved && entries.isNotEmpty ? now : null,
      ),
    );
  }

  /// Windows: before the first fetch, show the saved week straight away so
  /// the page is never blank while (or instead of) loading.
  Future<void> _showSavedCopyIfEmpty() async {
    final cache = _offlineCache;
    if (cache == null) return;
    await cache.ensureOpen();
    if (isClosed) return;
    final airing = state.airingAll.isEmpty ? cache.readAiring() : null;
    final soon = state.comingSoon.isEmpty ? cache.readSoon() : null;
    if (airing == null && soon == null) return;
    final followed = _followedShows();
    emit(
      state.copyWith(
        airingAll: airing?.entries,
        airingByDay: airing == null ? null : groupByLocalDay(airing.entries),
        myListByDay: airing == null
            ? null
            : groupByLocalDay(filterByFollowed(airing.entries, followed)),
        followed: followed,
        airingSavedAt: airing?.savedAt,
        comingSoon: soon?.entries,
        soonByDay: soon == null ? null : groupSoonByLocalDay(soon.entries),
        soonSavedAt: soon?.savedAt,
      ),
    );
  }

  Future<void> _loadSoon() async {
    emit(state.copyWith(loadingSoon: true, errorSoon: false));
    var soon = await _soon.upcoming();
    for (var i = 0; soon.isEmpty && i < _retryDelays.length; i++) {
      await Future<void>.delayed(_retryDelays[i]);
      if (isClosed) return;
      soon = await _soon.upcoming();
    }
    if (isClosed) return;
    // Windows: same saved-copy fallback as the anime week.
    final cache = _offlineCache;
    final saved = soon.isEmpty ? cache?.readSoon() : null;
    final usingSaved = saved != null && saved.entries.isNotEmpty;
    if (usingSaved) soon = saved.entries;
    final now = DateTime.now();
    if (cache != null && !usingSaved && soon.isNotEmpty) {
      unawaited(cache.writeSoon(soon, now));
    }
    emit(
      state.copyWith(
        comingSoon: soon,
        soonByDay: groupSoonByLocalDay(soon),
        loadingSoon: false,
        errorSoon: usingSaved || soon.isEmpty,
        offline: (usingSaved || soon.isEmpty) && _soon.lastFailureOffline,
        soonSavedAt: usingSaved ? saved.savedAt : null,
        clearSoonSavedAt: !usingSaved,
        lastUpdated: !usingSaved && soon.isNotEmpty ? now : null,
      ),
    );
  }

  /// What the My List filter matches against.
  ///
  /// Both ids AND titles: most list entries have no malId (it only arrives with
  /// metadata enrichment), so an id-only set was usually empty and the filter
  /// hid everything.
  FollowedShows _followedShows() {
    final mine = _myList
        .all()
        .where((m) => m.type == ProviderType.anime)
        .toList();
    return FollowedShows(
      malIds: {
        for (final m in mine)
          if (m.malId != null) m.malId!,
      },
      titles: {
        for (final m in mine) ...[
          normalizeTitle(m.title),
          if (m.englishTitle != null) normalizeTitle(m.englishTitle!),
        ],
      }..removeWhere((t) => t.isEmpty),
    );
  }
}
