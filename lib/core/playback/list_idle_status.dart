// R5: auto Paused / Dropped for titles that stopped moving.
//
// Pure logic only (no Hive, no singletons): the clock and the storage are
// injected so the rules can be unit-tested. The app-side wiring (reading My
// List, applying moves, trackers, the Undo notice) lives in
// list_idle_runner.dart.

import '../models/watch_status.dart';

/// The user's settings for idle moves, clamped to the allowed range.
class ListIdleRule {
  /// Builds a rule; both day values are clamped to [minDays]..[maxDays].
  ListIdleRule({
    required this.enabled,
    int pauseDays = defaultPauseDays,
    int dropDays = defaultDropDays,
  }) : pauseDays = clampDays(pauseDays),
       dropDays = clampDays(dropDays);

  /// Smallest allowed value for either stage.
  static const int minDays = 7;

  /// Largest allowed value for either stage (so the full cycle is <= 60).
  static const int maxDays = 30;

  /// Default days of no progress before Watching/Reading moves to Paused.
  static const int defaultPauseDays = 15;

  /// Default further days in Paused before the title moves to Dropped.
  static const int defaultDropDays = 30;

  /// Keeps a stored or typed value inside [minDays]..[maxDays].
  static int clampDays(int days) => days.clamp(minDays, maxDays);

  /// Master switch; when false a sweep changes nothing.
  final bool enabled;

  /// Idle days before Watching (or Reading) moves to Paused.
  final int pauseDays;

  /// Idle days in Paused before the title moves to Dropped.
  final int dropDays;
}

/// One My List title as the sweep sees it.
class ListIdleEntry {
  const ListIdleEntry({
    required this.key,
    required this.status,
    this.progressMs,
  });

  /// Stable per-profile library key (same key the status store uses).
  final String key;

  /// The title's current list status (null = listed without a status).
  final WatchStatus? status;

  /// Newest watch/read/resume progress time for the title, in epoch ms
  /// (null when there is no history at all).
  final int? progressMs;
}

/// A status change the sweep wants to make.
class ListIdleMove {
  const ListIdleMove({
    required this.key,
    required this.from,
    required this.to,
    required this.idleDays,
  });

  /// Library key of the title to move.
  final String key;

  /// Status before the move (what Undo restores).
  final WatchStatus from;

  /// Status after the move (paused or dropped).
  final WatchStatus to;

  /// Whole days the title had been idle, for the notice.
  final int idleDays;
}

/// Where per-title activity clocks are kept. The app backs it with a Hive
/// box; tests use [MemoryListIdleClockStore].
abstract class ListIdleClockStore {
  /// The stored record for [key], or null when there is none.
  Map? read(String key);

  /// Replaces the record for [key].
  Future<void> write(String key, Map value);
}

/// In-memory [ListIdleClockStore] for tests.
class MemoryListIdleClockStore implements ListIdleClockStore {
  /// Raw records, exposed so tests can inspect or age them.
  final Map<String, Map> data = {};

  @override
  Map? read(String key) => data[key];

  @override
  Future<void> write(String key, Map value) async => data[key] = value;
}

/// The per-title "last activity" clock and the idle rules.
///
/// Each record holds:
/// * `at`: when the title last showed activity (progress, a manual status
///   change, an automatic move or an Undo), epoch ms;
/// * `status`: the list status seen at that time, so a manual move made
///   anywhere in the app is spotted on the next sweep without hooking the
///   status store;
/// * `progress`: the newest history time already counted, so new progress
///   is spotted the same way.
class ListIdleService {
  ListIdleService({required this.store, required DateTime Function() now})
    : _now = now;

  /// Backing storage for the clocks.
  final ListIdleClockStore store;

  /// Injected clock (DateTime.now in the app, a fake in tests).
  final DateTime Function() _now;

  static const int _dayMs = Duration.millisecondsPerDay;

  /// Checks every title and returns the moves that are due.
  ///
  /// Side effects on the clock store only: missing titles are seeded to now
  /// (so nothing moves right after an update or the first enable), and titles
  /// with new progress or a changed status get their clock reset. Moves are
  /// NOT recorded here; the caller confirms each one with [markMoved] once it
  /// was applied, so a move that failed is simply retried next time.
  ///
  /// [enabledSinceMs] is when the feature was last switched on: idle time is
  /// never counted from before it, so re-enabling never mass-moves titles.
  Future<List<ListIdleMove>> sweep(
    List<ListIdleEntry> entries,
    ListIdleRule rule, {
    int? enabledSinceMs,
  }) async {
    // Disabled: touch nothing at all.
    if (!rule.enabled) return const [];
    final now = _now().millisecondsSinceEpoch;
    final moves = <ListIdleMove>[];
    for (final e in entries) {
      final rec = store.read(e.key);
      // First time this title is seen: start its clock now.
      if (rec == null) {
        await _stamp(e.key, now, e.status, e.progressMs);
        continue;
      }
      final at = (rec['at'] as num?)?.toInt() ?? now;
      final seenStatus = watchStatusFromName(rec['status'] as String?);
      final seenProgress = (rec['progress'] as num?)?.toInt();
      // A status change we did not make (manual move, cloud pull) resets.
      if (seenStatus != e.status) {
        await _stamp(e.key, now, e.status, e.progressMs);
        continue;
      }
      // New watch/read progress resets to when it happened (never later
      // than now, in case another device's clock runs ahead).
      final p = e.progressMs;
      if (p != null && (seenProgress == null || p > seenProgress)) {
        final when = p > now ? now : (p > at ? p : at);
        await _stamp(e.key, when, e.status, p);
        continue;
      }
      // Idle time counts from the later of the clock and the enable time.
      final since = enabledSinceMs != null && enabledSinceMs > at
          ? enabledSinceMs
          : at;
      final idleMs = now - since;
      final next = _due(e.status, idleMs, rule);
      if (next != null) {
        moves.add(ListIdleMove(
          key: e.key,
          from: e.status!,
          to: next,
          idleDays: idleMs ~/ _dayMs,
        ));
      }
    }
    return moves;
  }

  /// The status [status] should move to after [idleMs], or null.
  /// Only Watching/Reading and Paused ever move.
  static WatchStatus? _due(WatchStatus? status, int idleMs, ListIdleRule r) {
    switch (status) {
      case WatchStatus.watching:
        return idleMs >= r.pauseDays * _dayMs ? WatchStatus.paused : null;
      case WatchStatus.paused:
        return idleMs >= r.dropDays * _dayMs ? WatchStatus.dropped : null;
      default:
        return null;
    }
  }

  /// Records an applied automatic move: the clock restarts now in the new
  /// status, so Paused waits its own full stage before Dropped.
  Future<void> markMoved(ListIdleMove move, {int? progressMs}) =>
      _stamp(move.key, _now().millisecondsSinceEpoch, move.to,
          progressMs ?? _progressOf(move.key));

  /// Records a status change made anywhere (status sheet, menus, trackers):
  /// the clock restarts now in [status]. Keeps the counted progress time.
  Future<void> markStatusSet(String key, WatchStatus status) => _stamp(
    key,
    _now().millisecondsSinceEpoch,
    status,
    _progressOf(key),
  );

  /// Records an Undo: the old status is back and the clock restarts now.
  Future<void> markUndone(ListIdleMove move) => _stamp(
    move.key,
    _now().millisecondsSinceEpoch,
    move.from,
    _progressOf(move.key),
  );

  /// The progress time already counted for [key], kept across stamps.
  int? _progressOf(String key) =>
      (store.read(key)?['progress'] as num?)?.toInt();

  Future<void> _stamp(String key, int at, WatchStatus? status, int? progress) =>
      store.write(key, {
        'at': at,
        'status': status?.name,
        'progress': ?progress,
      });
}
