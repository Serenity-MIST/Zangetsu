import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../boot_network.dart';
import '../hive/safe_box.dart';
import '../models/watch_status.dart';
import '../ui/global_messenger.dart';
import 'tracker.dart';
import '../../l10n/l10n.dart';

// Windows-only offline outbox for tracker writes (track-2).
//
// Before this, TrackerHub swallowed every failed write: finishing an episode
// offline, or while MyAnimeList/AniList/Simkl timed out, simply lost the
// update, and an expired login kept "working" while nothing reached the
// tracker. Now every hub write runs inside a [TrackerWriteScope]; the
// services report what went wrong, and this queue keeps the failed write in
// its own Hive box so it survives an app restart. It is retried on launch,
// when the window regains focus, when the network comes back and on a slow
// timer. A dead login marks the tracker "needs sign-in" instead.

/// What went wrong with one tracker write, worst last.
enum TrackerWriteProblem {
  /// The tracker answered but refused the write (bad id, 4xx). Retrying the
  /// same request would fail again, so it is recorded but not queued.
  rejected,

  /// No answer: offline, timeout or a server error (5xx). Worth retrying.
  network,

  /// The login is gone (401/403, or the token refresh was refused). Kept in
  /// the queue until the user signs in again.
  auth,
}

/// Collects the problems reported while one tracker write runs.
class TrackerWriteReport {
  /// Worst problem seen, or null when the write went through.
  TrackerWriteProblem? problem;

  /// Short technical detail of [problem], for the settings row and logs.
  String? detail;

  /// Whether the tracker actually accepted a request. False for a write the
  /// service skipped (auto-sync off, a kind it has no list for, no match), so
  /// a skip never clears a real failure.
  bool sent = false;

  /// Whether nothing went wrong.
  bool get ok => problem == null;

  /// Records [p] when it is worse than what is already recorded, so an auth
  /// failure is never hidden by a later network one.
  void note(TrackerWriteProblem p, [String? d]) {
    if (problem == null || p.index > problem!.index) {
      problem = p;
      detail = d;
    }
  }
}

/// Lets tracker services report a failed write to whoever started it, without
/// changing their "never throw" contract for the other callers (the sync
/// sheets call the services directly and expect quiet failures).
abstract final class TrackerWriteScope {
  // Zone key holding the active [TrackerWriteReport].
  static final Object _key = Object();

  /// Runs [op] and returns what the services reported while it ran. A throw
  /// from [op] counts as a problem too (network-looking errors are retryable).
  static Future<TrackerWriteReport> run(Future<void> Function() op) async {
    final report = TrackerWriteReport();
    try {
      await runZoned(op, zoneValues: {_key: report});
    } catch (e) {
      report.note(
        isNetworkFailure(e)
            ? TrackerWriteProblem.network
            : TrackerWriteProblem.rejected,
        '$e',
      );
    }
    return report;
  }

  /// Whether a write is being watched right now (inside [run]).
  static bool get active => Zone.current[_key] is TrackerWriteReport;

  /// Reports [problem] for the write in progress. A no-op outside [run], so
  /// services can call it on every failure path.
  static void report(TrackerWriteProblem problem, [String? detail]) {
    final r = Zone.current[_key];
    if (r is TrackerWriteReport) r.note(problem, detail);
  }

  /// Reports that the tracker accepted a write request (2xx). A no-op
  /// outside [run].
  static void reportSent() {
    final r = Zone.current[_key];
    if (r is TrackerWriteReport) r.sent = true;
  }

  /// Reports a non-success HTTP [statusCode]: 401/403 mean the login is gone,
  /// 5xx (and no code at all) is retryable, anything else was refused.
  static void reportStatus(int? statusCode, [String? detail]) {
    final code = statusCode;
    if (code != null && code < 300) return;
    final d = detail ?? 'HTTP ${code ?? '-'}';
    if (code == 401 || code == 403) {
      report(TrackerWriteProblem.auth, d);
    } else if (code == null || code >= 500 || code == 429) {
      // 429 (rate limited) is temporary as well.
      report(TrackerWriteProblem.network, d);
    } else {
      report(TrackerWriteProblem.rejected, d);
    }
  }

  /// Reports a caught [error]. A server error that reached us as an exception
  /// (validateStatus rejects 5xx) is classified from its status code.
  static void reportError(Object error) {
    if (isNetworkFailure(error)) {
      report(TrackerWriteProblem.network, '$error');
      return;
    }
    final status = _statusOf(error);
    if (status != null) {
      reportStatus(status, 'HTTP $status');
    } else {
      // Unknown errors (timeouts reported as other types, parse errors) are
      // treated as temporary: retrying is cheap and loses nothing.
      report(TrackerWriteProblem.network, '$error');
    }
  }

  // Dio's response status, read dynamically so this file needs no Dio import.
  static int? _statusOf(Object error) {
    try {
      final dynamic e = error;
      final dynamic code = e.response?.statusCode;
      return code is int ? code : null;
    } catch (_) {
      return null;
    }
  }
}

/// Which hub write a queued entry replays.
enum TrackerSyncOp { markWatching, scrobble, setStatus, removeFromList, updateEntry }

/// One failed write waiting to be retried for one tracker.
class TrackerSyncEntry {
  TrackerSyncEntry({
    required this.id,
    required this.tracker,
    required this.op,
    required this.args,
    required this.createdAt,
    this.attempts = 0,
  });

  /// Unique id (creation time + counter), used for removal.
  final String id;

  /// [Tracker.displayName] of the tracker this write belongs to.
  final String tracker;
  final TrackerSyncOp op;

  /// The write's arguments as plain JSON values (see [TrackerSyncArgs]).
  final Map<String, dynamic> args;
  final DateTime createdAt;
  int attempts;

  /// Identity of the title this write is about, so a newer write for the same
  /// title can replace an older one.
  String get titleKey => TrackerSyncArgs.titleKey(args);

  Map<String, dynamic> toJson() => {
    'id': id,
    'tracker': tracker,
    'op': op.name,
    'args': args,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'attempts': attempts,
  };

  /// Null when the stored row is unreadable (dropped instead of crashing).
  static TrackerSyncEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final op = TrackerSyncOp.values
        .where((o) => o.name == raw['op'])
        .firstOrNull;
    final tracker = raw['tracker'];
    final id = raw['id'];
    if (op == null || tracker is! String || id is! String) return null;
    final args = raw['args'];
    return TrackerSyncEntry(
      id: id,
      tracker: tracker,
      op: op,
      args: args is Map ? Map<String, dynamic>.from(args) : {},
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (raw['createdAt'] as num?)?.toInt() ?? 0,
      ),
      attempts: (raw['attempts'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Builds and replays the plain-JSON argument maps stored in the queue.
abstract final class TrackerSyncArgs {
  /// Packs a hub write's arguments; nulls are left out to keep rows small.
  static Map<String, dynamic> pack({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    String? pinnedId,
    int? episode,
    int? season,
    int? seasonEpisode,
    MediaKind kind = MediaKind.anime,
    bool novel = false,
    WatchStatus? status,
    double? score,
    int? progress,
  }) => {
    'malId': ?malId,
    'title': ?title,
    'tmdbId': ?tmdbId,
    if (tmdbIsTv) 'tmdbIsTv': true,
    'imdbId': ?imdbId,
    'pinnedId': ?pinnedId,
    'episode': ?episode,
    'season': ?season,
    'seasonEpisode': ?seasonEpisode,
    'kind': kind.name,
    if (novel) 'novel': true,
    'status': ?status?.name,
    'score': ?score,
    'progress': ?progress,
  };

  /// Same title = same kind and the most specific id both writes carry.
  static String titleKey(Map<String, dynamic> a) {
    final kind = a['kind'] ?? MediaKind.anime.name;
    final id =
        a['pinnedId'] ??
        (a['malId'] != null ? 'mal:${a['malId']}' : null) ??
        (a['tmdbId'] != null ? 'tmdb:${a['tmdbId']}' : null) ??
        (a['imdbId'] != null ? 'imdb:${a['imdbId']}' : null) ??
        'title:${(a['title'] as String? ?? '').trim().toLowerCase()}';
    return '$kind|$id';
  }

  static WatchStatus? _status(Object? name) =>
      WatchStatus.values.where((s) => s.name == name).firstOrNull;

  /// Calls the matching [Tracker] method with the stored arguments.
  static Future<void> replay(Tracker t, TrackerSyncOp op, Map<String, dynamic> a) {
    final malId = (a['malId'] as num?)?.toInt();
    final title = a['title'] as String?;
    final tmdbId = (a['tmdbId'] as num?)?.toInt();
    final tmdbIsTv = a['tmdbIsTv'] == true;
    final imdbId = a['imdbId'] as String?;
    final kind = mediaKindFromName(a['kind'] as String?);
    switch (op) {
      case TrackerSyncOp.markWatching:
        return t.markWatching(
          malId: malId,
          title: title,
          tmdbId: tmdbId,
          tmdbIsTv: tmdbIsTv,
          imdbId: imdbId,
          kind: kind,
        );
      case TrackerSyncOp.scrobble:
        return t.scrobble(
          malId: malId,
          title: title,
          tmdbId: tmdbId,
          tmdbIsTv: tmdbIsTv,
          imdbId: imdbId,
          episode: (a['episode'] as num?)?.toInt() ?? 0,
          season: (a['season'] as num?)?.toInt(),
          seasonEpisode: (a['seasonEpisode'] as num?)?.toInt(),
          kind: kind,
          novel: a['novel'] == true,
        );
      case TrackerSyncOp.setStatus:
        final status = _status(a['status']);
        if (status == null) return Future.value();
        return t.setStatus(
          malId: malId,
          title: title,
          tmdbId: tmdbId,
          tmdbIsTv: tmdbIsTv,
          imdbId: imdbId,
          status: status,
          kind: kind,
        );
      case TrackerSyncOp.removeFromList:
        return t.removeFromList(
          malId: malId,
          title: title,
          tmdbId: tmdbId,
          tmdbIsTv: tmdbIsTv,
          imdbId: imdbId,
          pinnedId: a['pinnedId'] as String?,
          kind: kind,
        );
      case TrackerSyncOp.updateEntry:
        return t.updateEntry(
          malId: malId,
          title: title,
          tmdbId: tmdbId,
          tmdbIsTv: tmdbIsTv,
          imdbId: imdbId,
          pinnedId: a['pinnedId'] as String?,
          status: _status(a['status']),
          score: (a['score'] as num?)?.toDouble(),
          progress: (a['progress'] as num?)?.toInt(),
          kind: kind,
        );
    }
  }
}

/// Per-tracker sync health shown in tracker settings and on the lists
/// dashboard.
@immutable
class TrackerSyncHealth {
  const TrackerSyncHealth({
    this.needsSignIn = false,
    this.lastError,
    this.lastFailureAt,
    this.notified = false,
  });

  /// The login was refused; writes wait until the user reconnects.
  final bool needsSignIn;

  /// Detail of the most recent failure, or null after a clean sync.
  final String? lastError;
  final DateTime? lastFailureAt;

  /// The one-time notice for the current problem has been shown.
  final bool notified;

  /// Whether the last write failed (and was not followed by a success).
  bool get failed => needsSignIn || lastError != null;

  Map<String, dynamic> toJson() => {
    if (needsSignIn) 'needsSignIn': true,
    'lastError': ?lastError,
    'lastFailureAt': ?lastFailureAt?.millisecondsSinceEpoch,
    if (notified) 'notified': true,
  };

  static TrackerSyncHealth fromJson(Object? raw) {
    if (raw is! Map) return const TrackerSyncHealth();
    final at = (raw['lastFailureAt'] as num?)?.toInt();
    return TrackerSyncHealth(
      needsSignIn: raw['needsSignIn'] == true,
      lastError: raw['lastError'] as String?,
      lastFailureAt: at == null ? null : DateTime.fromMillisecondsSinceEpoch(at),
      notified: raw['notified'] == true,
    );
  }
}

/// The persistent outbox itself. One shared instance ([instance]); tests build
/// their own with [TrackerSyncQueue.new] and [persist] false.
class TrackerSyncQueue extends ChangeNotifier {
  TrackerSyncQueue({this.persist = true, this.notice});

  /// Shared queue used by the app's [TrackerHub].
  static final TrackerSyncQueue instance = TrackerSyncQueue(
    notice: showGlobalSnack,
  );

  /// Hive box holding the queue, opened lazily by [ensureLoaded].
  static const boxName = 'tracker_sync_queue';
  static const _entriesKey = 'entries';
  static const _healthKey = 'health';

  /// Oldest entries are dropped beyond this many, so a tracker that never
  /// comes back cannot grow the box forever.
  static const maxEntries = 300;

  /// Whether to store the queue in Hive (false in unit tests).
  final bool persist;

  /// Shows the one-time notice (a snackbar in the app, captured in tests).
  final void Function(String message)? notice;

  final List<TrackerSyncEntry> _entries = [];
  final Map<String, TrackerSyncHealth> _health = {};
  Box<dynamic>? _box;
  Future<void>? _loading;
  bool _flushing = false;
  int _seq = 0;

  /// The trackers to replay against; set by [attach].
  List<Tracker> _trackers = const [];
  final List<VoidCallback> _detach = [];
  Timer? _timer;
  AppLifecycleListener? _lifecycle;
  DateTime _lastFocusFlush = DateTime.fromMillisecondsSinceEpoch(0);

  /// Every queued write, oldest first.
  List<TrackerSyncEntry> get entries => List.unmodifiable(_entries);

  /// Queued writes for one tracker.
  int pendingFor(String tracker) =>
      _entries.where((e) => e.tracker == tracker).length;

  /// Health of one tracker (a clean default when nothing ever failed).
  TrackerSyncHealth healthOf(String tracker) =>
      _health[tracker] ?? const TrackerSyncHealth();

  /// Whether any tracker needs attention (failed sync or needs sign-in). The
  /// lists dashboard shows its warning dot from this.
  bool get anyProblem =>
      _health.values.any((h) => h.failed) || _entries.isNotEmpty;

  /// Loads the stored queue once. Safe to call repeatedly and when Hive is
  /// unavailable (it then stays in memory only).
  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    if (!persist) return;
    try {
      _box = Hive.isBoxOpen(boxName)
          ? Hive.box<dynamic>(boxName)
          : await openBoxSafely<dynamic>(boxName);
    } catch (e) {
      debugPrint('[trackers] sync queue box unavailable: $e');
      return;
    }
    final rawEntries = _box!.get(_entriesKey);
    if (rawEntries is List) {
      // Rows queued before the box finished loading stay after stored ones.
      final stored = [
        for (final r in rawEntries) ?TrackerSyncEntry.fromJson(r),
      ];
      _entries.insertAll(0, stored);
    }
    final rawHealth = _box!.get(_healthKey);
    if (rawHealth is Map) {
      rawHealth.forEach((k, v) {
        if (k is String) _health.putIfAbsent(k, () => TrackerSyncHealth.fromJson(v));
      });
    }
    notifyListeners();
  }

  Future<void> _save() async {
    final box = _box;
    if (box == null) return;
    try {
      await box.put(_entriesKey, [for (final e in _entries) e.toJson()]);
      await box.put(_healthKey, {
        for (final h in _health.entries) h.key: h.value.toJson(),
      });
    } catch (e) {
      debugPrint('[trackers] sync queue save failed: $e');
    }
  }

  // ── Recording outcomes ─────────────────────────────────────────────────────

  /// Records the outcome of one hub write to [tracker]. A failure is queued
  /// (unless refused for good); a success drops older writes it replaces and
  /// clears the tracker's failure state.
  Future<void> record(
    Tracker tracker,
    TrackerSyncOp op,
    Map<String, dynamic> args,
    TrackerWriteReport report,
  ) async {
    await ensureLoaded();
    final name = tracker.displayName;
    if (report.ok) {
      // Only a write the tracker really took proves the account works again
      // and replaces older queued writes; a skipped one changes nothing.
      if (!report.sent) return;
      _dropSuperseded(name, op, args, succeeded: true);
      _setHealth(name, const TrackerSyncHealth());
    } else {
      final problem = report.problem!;
      if (problem != TrackerWriteProblem.rejected) {
        _enqueue(name, op, args);
      }
      _fail(name, problem, report.detail);
    }
    notifyListeners();
    await _save();
  }

  /// Queues [op] without trying it (the app already knows it is offline).
  Future<void> queueOffline(
    Tracker tracker,
    TrackerSyncOp op,
    Map<String, dynamic> args,
  ) async {
    await ensureLoaded();
    _enqueue(tracker.displayName, op, args);
    notifyListeners();
    await _save();
  }

  void _enqueue(String tracker, TrackerSyncOp op, Map<String, dynamic> args) {
    final key = TrackerSyncArgs.titleKey(args);
    var merged = Map<String, dynamic>.from(args);
    // A queued markWatching is pointless next to a pending status/progress
    // write for the same title: that write already puts it on the list.
    if (op == TrackerSyncOp.markWatching &&
        _entries.any(
          (e) =>
              e.tracker == tracker &&
              e.titleKey == key &&
              e.op != TrackerSyncOp.markWatching &&
              e.op != TrackerSyncOp.removeFromList,
        )) {
      return;
    }
    // A newer manual edit keeps fields an older queued edit set and this one
    // leaves untouched (score from one edit, progress from another).
    if (op == TrackerSyncOp.updateEntry) {
      for (final e in _entries) {
        if (e.tracker == tracker &&
            e.titleKey == key &&
            e.op == TrackerSyncOp.updateEntry) {
          merged = {...e.args, ...merged};
        }
      }
    }
    // Scrobbles never go backwards: keep the highest episode queued.
    if (op == TrackerSyncOp.scrobble) {
      for (final e in _entries) {
        if (e.tracker == tracker &&
            e.titleKey == key &&
            e.op == TrackerSyncOp.scrobble) {
          final older = (e.args['episode'] as num?)?.toInt() ?? 0;
          final newer = (merged['episode'] as num?)?.toInt() ?? 0;
          if (older > newer) merged = e.args;
        }
      }
    }
    _dropSuperseded(tracker, op, merged, succeeded: false);
    _entries.add(
      TrackerSyncEntry(
        id: '${DateTime.now().microsecondsSinceEpoch}-${_seq++}',
        tracker: tracker,
        op: op,
        args: merged,
        createdAt: DateTime.now(),
      ),
    );
    while (_entries.length > maxEntries) {
      _entries.removeAt(0);
    }
  }

  /// Removes queued writes for the same tracker + title that [op] makes
  /// pointless. [succeeded] is true when [op] just went through (then a
  /// queued scrobble for a LATER episode is kept: it still has to be sent).
  void _dropSuperseded(
    String tracker,
    TrackerSyncOp op,
    Map<String, dynamic> args, {
    required bool succeeded,
  }) {
    final key = TrackerSyncArgs.titleKey(args);
    _entries.removeWhere((e) {
      if (e.tracker != tracker || e.titleKey != key) return false;
      return supersedes(op, args, e.op, e.args, succeeded: succeeded);
    });
  }

  /// Whether a write [newOp] for a title replaces an older queued [oldOp] for
  /// the same title. Public for the unit tests.
  @visibleForTesting
  static bool supersedes(
    TrackerSyncOp newOp,
    Map<String, dynamic> newArgs,
    TrackerSyncOp oldOp,
    Map<String, dynamic> oldArgs, {
    bool succeeded = false,
  }) {
    // Removing the title makes every older write moot, and any later write
    // re-adds it, so a pending removal is moot too.
    if (newOp == TrackerSyncOp.removeFromList) return true;
    if (oldOp == TrackerSyncOp.removeFromList) return true;
    if (newOp == oldOp) {
      if (newOp == TrackerSyncOp.scrobble && succeeded) {
        final older = (oldArgs['episode'] as num?)?.toInt() ?? 0;
        final newer = (newArgs['episode'] as num?)?.toInt() ?? 0;
        return newer >= older;
      }
      return true;
    }
    // Any status/progress write already marks the title as on the list.
    if (oldOp == TrackerSyncOp.markWatching) return true;
    // A manual edit that sets a status replaces a plain status change.
    if (newOp == TrackerSyncOp.updateEntry &&
        oldOp == TrackerSyncOp.setStatus &&
        newArgs['status'] != null) {
      return true;
    }
    // A plain status change replaces an older edit that only set a status.
    if (newOp == TrackerSyncOp.setStatus &&
        oldOp == TrackerSyncOp.updateEntry &&
        oldArgs['score'] == null &&
        oldArgs['progress'] == null) {
      return true;
    }
    return false;
  }

  void _fail(String tracker, TrackerWriteProblem problem, String? detail) {
    final before = healthOf(tracker);
    final needsSignIn = before.needsSignIn || problem == TrackerWriteProblem.auth;
    // Notify once per problem: a fresh needs-sign-in always says so, a
    // network failure only the first time it starts failing.
    final shouldNotify =
        !before.notified || (needsSignIn && !before.needsSignIn);
    _setHealth(
      tracker,
      TrackerSyncHealth(
        needsSignIn: needsSignIn,
        lastError: detail ?? problem.name,
        lastFailureAt: DateTime.now(),
        notified: before.notified || shouldNotify,
      ),
    );
    if (shouldNotify) {
      notice?.call(
        needsSignIn
            ? appL10n.trackerNeedsSignInSaved(tracker)
            : appL10n.trackerSyncFailedRetry(tracker),
      );
    }
  }

  void _setHealth(String tracker, TrackerSyncHealth h) {
    if (!h.failed && !h.notified) {
      _health.remove(tracker);
    } else {
      _health[tracker] = h;
    }
  }

  /// Forgets everything queued for [tracker] (it was disconnected).
  Future<void> clearTracker(String tracker) async {
    await ensureLoaded();
    final had = _entries.any((e) => e.tracker == tracker) ||
        _health.containsKey(tracker);
    _entries.removeWhere((e) => e.tracker == tracker);
    _health.remove(tracker);
    if (!had) return;
    notifyListeners();
    await _save();
  }

  // ── Replaying ──────────────────────────────────────────────────────────────

  /// Retries queued writes, oldest first. [only] limits it to one tracker
  /// (the Retry button). Trackers waiting for sign-in are skipped unless
  /// [only] names them (a manual Retry after reconnecting elsewhere).
  Future<void> flush({String? only}) async {
    await ensureLoaded();
    if (_flushing || _entries.isEmpty) return;
    if (BootConnectivity.instance.offline.value) return;
    _flushing = true;
    try {
      // Trackers that hit a network problem this round wait for the next one,
      // so a dead connection costs one timeout per tracker, not per entry.
      final stalled = <String>{};
      for (final entry in List.of(_entries)) {
        if (only != null && entry.tracker != only) continue;
        if (stalled.contains(entry.tracker)) continue;
        final tracker = _trackers
            .where((t) => t.displayName == entry.tracker)
            .firstOrNull;
        if (tracker == null || !tracker.isConnected) continue;
        if (only == null && healthOf(entry.tracker).needsSignIn) continue;
        if (!_entries.contains(entry)) continue; // superseded meanwhile
        final report = await TrackerWriteScope.run(
          () => TrackerSyncArgs.replay(tracker, entry.op, entry.args),
        );
        if (report.ok || report.problem == TrackerWriteProblem.rejected) {
          // Sent, or refused for good: either way it leaves the queue.
          _entries.remove(entry);
          if (report.ok) {
            // A replay the service skipped (e.g. already up to date) leaves
            // the health alone; a real success clears it.
            if (report.sent) {
              _setHealth(entry.tracker, const TrackerSyncHealth());
            }
          } else {
            _fail(entry.tracker, report.problem!, report.detail);
          }
        } else {
          entry.attempts++;
          stalled.add(entry.tracker);
          _fail(entry.tracker, report.problem!, report.detail);
        }
        notifyListeners();
        await _save();
      }
    } finally {
      _flushing = false;
    }
  }

  // ── Wiring (Windows app only) ──────────────────────────────────────────────

  /// Starts retrying for [trackers]: now, when the window regains focus, when
  /// the network returns, every few minutes, and after a tracker reconnects.
  /// A disconnected tracker's queue is dropped. Idempotent.
  ///
  /// [loginExpired] says whether a tracker that stopped counting as connected
  /// merely has an expired login (AniList) rather than being signed out; its
  /// waiting writes are then kept for after the reconnect.
  void attach(
    List<Tracker> trackers, {
    bool Function(Tracker t)? loginExpired,
  }) {
    if (identical(_trackers, trackers)) return;
    for (final d in _detach) {
      d();
    }
    _detach.clear();
    _trackers = trackers;
    for (final t in trackers) {
      var wasConnected = t.isConnected;
      void onTrackerChanged() {
        final now = t.isConnected;
        if (wasConnected && !now && (loginExpired?.call(t) ?? false)) {
          // The login only expired (any later notify, e.g. an auto-sync
          // toggle, reveals it): keep the writes, they need a sign-in.
        } else if (wasConnected && !now) {
          // Signed out: nothing queued for it can ever be sent.
          unawaited(clearTracker(t.displayName));
        } else if (now && healthOf(t.displayName).needsSignIn) {
          // Possibly signed in again (MAL stays "connected" with a dead
          // token, so this can't wait for a disconnected->connected flip):
          // try its writes; a success clears the needs-sign-in state.
          unawaited(flush(only: t.displayName));
        } else if (now) {
          unawaited(flush());
        }
        wasConnected = now;
      }

      t.addListener(onTrackerChanged);
      _detach.add(() => t.removeListener(onTrackerChanged));
    }
    BootConnectivity.instance.addReconnectTask(_onReconnect);
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 5), (_) {
      if (_entries.isNotEmpty) unawaited(flush());
    });
    try {
      _lifecycle?.dispose();
      _lifecycle = AppLifecycleListener(onResume: _onFocus);
    } catch (_) {
      // No widgets binding (pure unit tests): focus retry just isn't wired.
    }
    unawaited(ensureLoaded().then((_) => flush()));
  }

  // Reconnect task: same function object every time so it registers once.
  Future<void> _onReconnect() => flush();

  // Window focused again: retry, at most once every 30 seconds.
  void _onFocus() {
    final now = DateTime.now();
    if (now.difference(_lastFocusFlush) < const Duration(seconds: 30)) return;
    _lastFocusFlush = now;
    if (_entries.isNotEmpty) unawaited(flush());
  }

  /// The user reconnected [tracker] (the "Reconnect" button or the regular
  /// connect flow): its writes may go out again.
  void _clearSignIn(String tracker) {
    final h = healthOf(tracker);
    _setHealth(
      tracker,
      TrackerSyncHealth(
        lastError: h.lastError,
        lastFailureAt: h.lastFailureAt,
      ),
    );
    notifyListeners();
    unawaited(_save());
  }

  /// Called after a successful reconnect from settings.
  Future<void> signedInAgain(String tracker) async {
    await ensureLoaded();
    _clearSignIn(tracker);
    await flush(only: tracker);
  }

  @visibleForTesting
  void debugDetach() {
    for (final d in _detach) {
      d();
    }
    _detach.clear();
    _trackers = const [];
    _timer?.cancel();
    _lifecycle?.dispose();
    _lifecycle = null;
  }

  @override
  void dispose() {
    debugDetach();
    super.dispose();
  }
}

/// Amber used for "needs attention" tracker states (track-2): distinct from
/// the accent (connected) and the red destructive colour. Shared by tracker
/// settings and the lists dashboard warning dot.
const Color trackerWarningColor = Color(0xFFF2B33D);
