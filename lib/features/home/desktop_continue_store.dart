import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:hive/hive.dart';

import '../../core/models/media_item.dart';
import '../../core/models/provider_info.dart';
import '../../core/playback/watch_history.dart';
import '../../core/reading/read_history.dart';
import '../../core/ui/route_observer.dart';

/// The Windows Home "Continue" lists (home-10).
///
/// Home used to rebuild completely on every Hive write to the watch/read
/// history, which the player does each time it saves the position. This store
/// listens to the boxes itself and only notifies when the Continue list
/// really changes: an entry is added, removed, finishes, moves to another
/// episode/chapter or changes place. A plain position save is applied in place
/// silently; the fresh progress shows on the next rebuild or [refresh] (for
/// example when the user comes back to Home from the player).
///
/// It also keeps lookups by show, so matching a poster against history is a
/// map read instead of a linear search per poster.
class DesktopContinueStore extends ChangeNotifier {
  DesktopContinueStore({
    required List<HistoryEntry> Function() loadWatched,
    required List<ReadEntry> Function(ProviderType type) loadReading,
    Stream<BoxEvent>? watchEvents,
    Stream<BoxEvent>? readEvents,
  }) : _loadWatched = loadWatched,
       _loadReading = loadReading {
    _recompute();
    _watchSub = watchEvents?.listen(_onWatchEvent);
    _readSub = readEvents?.listen(_onReadEvent);
  }

  /// The real store on top of [watch] / [read] and their Hive boxes. A
  /// missing history or a box that is not open (tests, early startup) reads
  /// as empty.
  factory DesktopContinueStore.fromHistory({
    WatchHistory? watch,
    ReadHistory? read,
  }) {
    final watchOpen = Hive.isBoxOpen(WatchHistory.boxName);
    final readOpen = Hive.isBoxOpen(ReadHistory.boxName);
    return DesktopContinueStore(
      loadWatched: () => watch != null && Hive.isBoxOpen(WatchHistory.boxName)
          ? watch.recent()
          : const <HistoryEntry>[],
      loadReading: (type) =>
          read != null && Hive.isBoxOpen(ReadHistory.boxName)
          ? read.recent(type: type)
          : const <ReadEntry>[],
      watchEvents: watchOpen
          ? Hive.box<Map>(WatchHistory.boxName).watch()
          : null,
      readEvents: readOpen ? Hive.box<Map>(ReadHistory.boxName).watch() : null,
    );
  }

  final List<HistoryEntry> Function() _loadWatched;
  final List<ReadEntry> Function(ProviderType type) _loadReading;
  StreamSubscription<BoxEvent>? _watchSub, _readSub;

  /// Continue watching, newest first (unfinished only, like the phone row).
  List<HistoryEntry> get watched => List.unmodifiable(_watched);
  List<HistoryEntry> _watched = const [];

  /// Continue reading for one kind (manga or novel), newest first.
  List<ReadEntry> reading(ProviderType type) =>
      List.unmodifiable(_reading[type] ?? const <ReadEntry>[]);
  final Map<ProviderType, List<ReadEntry>> _reading = {};

  // Lookups by show id (source + show) and by show URL, rebuilt on change.
  final Map<String, HistoryEntry> _watchById = {}, _watchByUrl = {};
  final Map<String, ReadEntry> _readById = {}, _readByUrl = {};

  /// Bumps on every notification; handy for keys and tests.
  int get revision => _revision;
  int _revision = 0;

  /// True when an in-place position save has not been shown yet.
  bool _progressDirty = false;

  /// A recompute is already queued for this microtask turn (a clear-all or a
  /// cloud merge writes many keys at once; one recompute covers them all).
  bool _recomputeQueued = false;

  bool _disposed = false;

  static String _id(String sourceId, String showId) => '$sourceId\u0000$showId';

  /// The newest unfinished watch entry for [item], matched by show id or URL.
  HistoryEntry? historyFor(MediaItem item) =>
      _watchById[_id(item.sourceId, item.id)] ?? _watchByUrl[item.url];

  /// The newest unfinished manga/novel entry for [item].
  ReadEntry? readingFor(MediaItem item) =>
      _readById[_id(item.sourceId, item.id)] ?? _readByUrl[item.url];

  /// Re-reads both histories now and notifies if anything visible changed,
  /// including progress saved in place since the last notification. Called
  /// when Home becomes visible again.
  void refresh() {
    if (_disposed) return;
    final changed = _recompute();
    if (changed || _progressDirty) _notify();
  }

  /// Re-reads the lists. Returns true when the set, order or episode of the
  /// entries changed (the things the Continue block must redraw for).
  bool _recompute() {
    final before = _signature();
    _watched = [..._loadWatched()];
    _reading
      ..[ProviderType.manga] = [..._loadReading(ProviderType.manga)]
      ..[ProviderType.novel] = [..._loadReading(ProviderType.novel)];
    _rebuildLookups();
    return _signature() != before;
  }

  /// Order-sensitive identity of what the Continue block shows, without the
  /// progress (which changes on every player save).
  String _signature() => [
    for (final e in _watched) '${e.sourceId}|${e.showId}|${e.episodeId}',
    '#',
    for (final type in const [ProviderType.manga, ProviderType.novel])
      for (final e in _reading[type] ?? const <ReadEntry>[])
        '${e.sourceId}|${e.showId}|${e.chapterId}',
  ].join('\n');

  void _rebuildLookups() {
    _watchById.clear();
    _watchByUrl.clear();
    _readById.clear();
    _readByUrl.clear();
    // Lists are newest first, so putIfAbsent keeps the newest match.
    for (final e in _watched) {
      _watchById.putIfAbsent(_id(e.sourceId, e.showId), () => e);
      if (e.showUrl.isNotEmpty) _watchByUrl.putIfAbsent(e.showUrl, () => e);
    }
    for (final list in _reading.values) {
      for (final e in list) {
        _readById.putIfAbsent(_id(e.sourceId, e.showId), () => e);
        final url = e.detailUrl;
        if (url.isNotEmpty) _readByUrl.putIfAbsent(url, () => e);
      }
    }
  }

  /// Queues one recompute + notify for everything written this turn.
  void _scheduleRecompute() {
    if (_recomputeQueued || _disposed) return;
    _recomputeQueued = true;
    scheduleMicrotask(() {
      _recomputeQueued = false;
      if (_disposed) return;
      if (_recompute() || _progressDirty) _notify();
    });
  }

  void _notify() {
    _progressDirty = false;
    _revision++;
    notifyListeners();
  }

  /// A write to the watch history. Only structural changes notify.
  void _onWatchEvent(BoxEvent event) {
    final raw = event.deleted ? null : event.value;
    if (raw is! Map) {
      // A removal (or an unreadable row): rare, so just re-read.
      _scheduleRecompute();
      return;
    }
    final HistoryEntry entry;
    try {
      entry = WatchHistory.entryFromMap(raw);
    } catch (_) {
      _scheduleRecompute();
      return;
    }
    final i = _watched.indexWhere(
      (e) => e.sourceId == entry.sourceId && e.showId == entry.showId,
    );
    if (i < 0) {
      // A finished entry that was not listed stays out of Continue.
      if (!entry.finished) _scheduleRecompute();
      return;
    }
    final old = _watched[i];
    final moved =
        (i > 0 && entry.updatedAt > _watched[i - 1].updatedAt) ||
        (i < _watched.length - 1 &&
            entry.updatedAt < _watched[i + 1].updatedAt);
    if (entry.finished || old.episodeId != entry.episodeId || moved) {
      _scheduleRecompute();
      return;
    }
    // Same entry, same place, new position: update silently.
    _watched[i] = entry;
    _rebuildLookups();
    _progressDirty = true;
  }

  /// A write to the reading history. Same rules as [_onWatchEvent].
  void _onReadEvent(BoxEvent event) {
    final raw = event.deleted ? null : event.value;
    if (raw is! Map) {
      _scheduleRecompute();
      return;
    }
    final ReadEntry entry;
    try {
      entry = ReadEntry.fromJson(Map<String, dynamic>.from(raw));
    } catch (_) {
      _scheduleRecompute();
      return;
    }
    final list = _reading[entry.type];
    if (list == null) return; // anime-typed rows never show in reading modes
    final i = list.indexWhere(
      (e) => e.sourceId == entry.sourceId && e.showId == entry.showId,
    );
    if (i < 0) {
      if (!entry.finished) _scheduleRecompute();
      return;
    }
    final old = list[i];
    final moved =
        (i > 0 && entry.updatedMs > list[i - 1].updatedMs) ||
        (i < list.length - 1 && entry.updatedMs < list[i + 1].updatedMs);
    if (entry.finished || old.chapterId != entry.chapterId || moved) {
      _scheduleRecompute();
      return;
    }
    list[i] = entry;
    _rebuildLookups();
    _progressDirty = true;
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_watchSub?.cancel());
    unawaited(_readSub?.cancel());
    super.dispose();
  }
}

/// Calls [DesktopContinueStore.refresh] whenever the route holding [child]
/// becomes visible again (a pushed player, reader or detail page was popped),
/// so progress saved while it was covered shows up on the Continue cards.
class DesktopContinueRefresher extends StatefulWidget {
  const DesktopContinueRefresher({
    super.key,
    required this.store,
    required this.child,
  });

  final DesktopContinueStore store;
  final Widget child;

  @override
  State<DesktopContinueRefresher> createState() =>
      _DesktopContinueRefresherState();
}

class _DesktopContinueRefresherState extends State<DesktopContinueRefresher>
    with RouteAware {
  PageRoute<dynamic>? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Subscribe to the page route Home lives in (the app shell's route).
    final route = ModalRoute.of(context);
    if (route is PageRoute<dynamic> && route != _route) {
      if (_route != null) appRouteObserver.unsubscribe(this);
      _route = route;
      appRouteObserver.subscribe(this, route);
    }
  }

  @override
  void didPopNext() => widget.store.refresh();

  @override
  void dispose() {
    if (_route != null) appRouteObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// A copy of [e] that counts as finished ([ReadEntry.finished]): the last
/// page, the end of a novel's scroll, or a one-page stand-in when the length
/// is unknown. Used by "Mark chapter read" on the Windows Continue menu.
ReadEntry readEntryMarkedRead(ReadEntry e) {
  final total = e.total > 0 ? e.total : 1;
  // Novels store scroll per mille (total 1000); manga the last page index.
  final pos = total == 1000 ? 1000 : total - 1;
  return ReadEntry(
    sourceId: e.sourceId,
    showId: e.showId,
    showUrl: e.showUrl,
    title: e.title,
    cover: e.cover,
    chapterId: e.chapterId,
    chapterNumber: e.chapterNumber,
    chapterUrl: e.chapterUrl,
    pos: pos,
    total: total,
    updatedMs: e.updatedMs,
    type: e.type,
  );
}
