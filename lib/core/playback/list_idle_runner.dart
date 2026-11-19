// R5: app-side runner for auto Paused / Dropped (rules in
// list_idle_status.dart).
//
// Reads My List + watch/read history, asks [ListIdleService] which titles are
// idle, applies each move through the same path as the status sheet (local
// status, cloud row, trackers via syncListStatusToTrackers and its offline
// queue) and shows one notice with Undo.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';

import '../desktop/desktop_undo_toast.dart';
import '../di/injector.dart';
import '../hive/hive_key.dart';
import '../hive/safe_box.dart';
import '../models/media_item.dart';
import '../models/provider_info.dart';
import '../models/watch_status.dart';
import '../privacy/incognito_mode.dart';
import '../reading/read_history.dart';
import '../ui/global_messenger.dart';
import '../ui/list_status_sheet.dart' show syncListStatusToTrackers;
import 'library_repair.dart';
import 'list_idle_status.dart';
import 'list_status_store.dart';
import 'my_list.dart';
import 'watch_history.dart';

/// Hive-backed [ListIdleClockStore] over the activity box.
class _HiveClockStore implements ListIdleClockStore {
  Box get _box => Hive.box(ListIdleRunner.activityBox);

  @override
  Map? read(String key) => _box.get(key) as Map?;

  @override
  Future<void> write(String key, Map value) => _box.put(key, value);
}

/// Runs the idle sweep on launch and every few hours, and owns its settings.
class ListIdleRunner {
  ListIdleRunner._();
  static final ListIdleRunner instance = ListIdleRunner._();

  /// Settings box (device-local): enabled, day values, timestamps.
  static const String prefsBox = 'list_idle_prefs';

  /// Per-title activity clocks (device-local, see ListIdleService).
  static const String activityBox = 'list_idle_activity';

  // Keys inside [prefsBox].
  static const _kEnabled = 'enabled';
  static const _kPauseDays = 'pauseDays';
  static const _kDropDays = 'dropDays';
  static const _kEnabledSince = 'enabledSinceMs';
  static const _kLastRun = 'lastRunMs';

  /// Delay after boot before the launch sweep, so startup is never slowed.
  static const Duration launchDelay = Duration(seconds: 20);

  /// How often the periodic tick wakes up (it is cheap when nothing is due).
  static const Duration tickEvery = Duration(hours: 1);

  /// Minimum gap between two periodic sweeps.
  static const Duration minGap = Duration(hours: 6);

  /// Bumped when a setting changes so the settings page can rebuild.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  Timer? _tick;
  int _startGen = 0; // which start() call owns the pending launch sweep
  bool _running = false;

  /// Opens both boxes; called from the injector during boot.
  static Future<void> init() async {
    if (!Hive.isBoxOpen(prefsBox)) await openBoxSafely(prefsBox);
    if (!Hive.isBoxOpen(activityBox)) await openBoxSafely(activityBox);
    // Any status change (manual move, auto move, Undo) restarts that title's
    // idle clock immediately. Only stamps when the feature is on, so phone
    // installs with it off write nothing extra.
    ListStatusStore.onStatusSet = (key, status) {
      final runner = ListIdleRunner.instance;
      if (!runner._boxesOpen || !runner.enabled) return;
      unawaited(
        runner._service().markStatusSet(key, status).catchError(
          (Object e) => debugPrint('[list-idle] stamp $e'),
        ),
      );
    };
  }

  bool get _boxesOpen =>
      Hive.isBoxOpen(prefsBox) && Hive.isBoxOpen(activityBox);

  Box get _prefs => Hive.box(prefsBox);

  /// Default: on for the Windows build, off elsewhere (phone unchanged
  /// unless the user switches it on).
  static bool get defaultEnabled =>
      defaultTargetPlatform == TargetPlatform.windows;

  /// Whether idle titles are moved automatically.
  bool get enabled => _boxesOpen
      ? (_prefs.get(_kEnabled) as bool? ?? defaultEnabled)
      : false;

  /// Days of no progress before Watching/Reading moves to Paused (7-30).
  int get pauseDays => ListIdleRule.clampDays(
    (_boxesOpen ? _prefs.get(_kPauseDays) as int? : null) ??
        ListIdleRule.defaultPauseDays,
  );

  /// Further days in Paused before the title moves to Dropped (7-30).
  int get dropDays => ListIdleRule.clampDays(
    (_boxesOpen ? _prefs.get(_kDropDays) as int? : null) ??
        ListIdleRule.defaultDropDays,
  );

  /// Turns the feature on/off. Switching on restarts every idle count from
  /// now, so nothing moves the moment it is enabled.
  Future<void> setEnabled(bool on) async {
    if (!_boxesOpen) return;
    await _prefs.put(_kEnabled, on);
    if (on) {
      await _prefs.put(_kEnabledSince, DateTime.now().millisecondsSinceEpoch);
    }
    revision.value++;
  }

  /// Saves the Paused stage length (clamped to 7-30).
  Future<void> setPauseDays(int days) async {
    if (!_boxesOpen) return;
    await _prefs.put(_kPauseDays, ListIdleRule.clampDays(days));
    revision.value++;
  }

  /// Saves the Dropped stage length (clamped to 7-30).
  Future<void> setDropDays(int days) async {
    if (!_boxesOpen) return;
    await _prefs.put(_kDropDays, ListIdleRule.clampDays(days));
    revision.value++;
  }

  /// Schedules the deferred launch sweep and the periodic tick. Safe to call
  /// again (a boot retry): the old timers are replaced.
  void start() {
    _tick?.cancel();
    final gen = ++_startGen;
    // Wait for the real shell (boot finished), then the launch delay; a
    // newer start() call supersedes this one.
    unawaited(appShellReady.then((_) async {
      await Future<void>.delayed(launchDelay);
      if (gen == _startGen) await sweep(force: true);
    }));
    _tick = Timer.periodic(tickEvery, (_) => unawaited(sweep()));
  }

  /// Checks My List and moves idle titles. [force] skips the [minGap]
  /// throttle (used for the launch sweep). Returns the moves applied.
  Future<List<ListIdleMove>> sweep({bool force = false}) async {
    if (_running || !_boxesOpen || !enabled || IncognitoMode.on) {
      return const [];
    }
    if (!sl.isRegistered<MyListStore>() || !sl.isRegistered<ListStatusStore>()) {
      return const [];
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final last = _prefs.get(_kLastRun) as int?;
    if (!force && last != null && nowMs - last < minGap.inMilliseconds) {
      return const [];
    }
    _running = true;
    try {
      await _prefs.put(_kLastRun, nowMs);
      // Default-on installs never stored an enable time: count from now.
      var since = _prefs.get(_kEnabledSince) as int?;
      if (since == null) {
        since = nowMs;
        await _prefs.put(_kEnabledSince, since);
      }
      final statuses = sl<ListStatusStore>();
      final progress = _progressIndex();
      final items = <String, MediaItem>{};
      final entries = <ListIdleEntry>[];
      for (final m in sl<MyListStore>().all()) {
        final key = statuses.keyOf(m);
        items[key] = m;
        entries.add(ListIdleEntry(
          key: key,
          status: statuses.statusOf(m),
          progressMs: _progressFor(m, progress),
        ));
      }
      final service = _service();
      final due = await service.sweep(
        entries,
        ListIdleRule(enabled: true, pauseDays: pauseDays, dropDays: dropDays),
        enabledSinceMs: since,
      );
      final applied = <(ListIdleMove, MediaItem)>[];
      for (final move in due) {
        final item = items[move.key];
        if (item == null) continue;
        if (await _set(item, move.to)) {
          await service.markMoved(move);
          applied.add((move, item));
        }
      }
      if (applied.isNotEmpty) _announce(applied);
      return [for (final a in applied) a.$1];
    } catch (e) {
      debugPrint('[list-idle] $e');
      return const [];
    } finally {
      _running = false;
    }
  }

  ListIdleService _service() =>
      ListIdleService(store: _HiveClockStore(), now: DateTime.now);

  /// Newest progress time per show, indexed by its `source::id` key and by
  /// its page URL. Watch history is rewritten on every resume-position save,
  /// so it also covers ResumeStore updates (which carry no timestamp).
  Map<String, int> _progressIndex() {
    final out = <String, int>{};
    void note(String k, int t) {
      if (k.isEmpty) return;
      final old = out[k];
      if (old == null || t > old) out[k] = t;
    }

    if (sl.isRegistered<WatchHistory>()) {
      for (final e in sl<WatchHistory>().all()) {
        note(hiveKey('${e.sourceId}::${e.showId}'), e.updatedAt);
        note(e.showUrl, e.updatedAt);
      }
    }
    if (sl.isRegistered<ReadHistory>()) {
      for (final e in sl<ReadHistory>().all()) {
        note(hiveKey('${e.sourceId}::${e.showId}'), e.updatedMs);
        if (e.showUrl != null) note(e.showUrl!, e.updatedMs);
      }
    }
    return out;
  }

  /// Newest progress for [m] across its repaired key, raw key and URL.
  int? _progressFor(MediaItem m, Map<String, int> index) {
    int? best;
    for (final k in {
      libraryStorageKey(m),
      hiveKey('${m.sourceId}::${m.id}'),
      m.url,
      // Canonical page URL too (legacy or tracker-saved rows whose stored
      // url differs from the one history records for the same title).
      repairedLibraryItem(m).url,
    }) {
      final t = index[k];
      if (t != null && (best == null || t > best)) best = t;
    }
    return best;
  }

  static bool _isReading(MediaItem m) =>
      m.type == ProviderType.manga || m.type == ProviderType.novel;

  /// Sets [item]'s status the same way as the status sheet / auto status:
  /// local mirror, cloud row, then trackers (fire-and-forget; the tracker
  /// queue retries offline). False when the title is no longer listed.
  Future<bool> _set(MediaItem item, WatchStatus status) async {
    final myList = sl<MyListStore>();
    if (!myList.contains(item)) return false; // signed out / removed
    await sl<ListStatusStore>().setStatus(item, status);
    await myList.pushStatus(item);
    unawaited(
      syncListStatusToTrackers(
        item,
        status,
        item.malId,
        item.tmdbId,
        item.tmdbIsTv,
        item.imdbId,
        item.type == ProviderType.anime,
        reading: _isReading(item),
      ).catchError((Object e) => debugPrint('[list-idle] tracker $e')),
    );
    return true;
  }

  /// Undo: every moved title goes back to its old status, locally and on
  /// trackers, and its idle clock restarts now.
  Future<void> _undo(List<(ListIdleMove, MediaItem)> applied) async {
    final service = _service();
    for (final (move, item) in applied) {
      try {
        // Leave titles alone that were changed again since the move.
        if (sl<ListStatusStore>().statusOf(item) != move.to) continue;
        if (await _set(item, move.from)) await service.markUndone(move);
      } catch (e) {
        debugPrint('[list-idle] undo $e');
      }
    }
  }

  /// The notice text, listing what moved (first few titles by name).
  @visibleForTesting
  static String noticeText(List<(ListIdleMove, MediaItem)> applied) {
    if (applied.length == 1) {
      final (move, item) = applied.single;
      return 'Moved "${item.title}" to '
          '${labelFor(move.to, reading: _isReading(item))} '
          '(no progress for ${move.idleDays} days)';
    }
    const shown = 3;
    final names = [
      for (final (move, item) in applied.take(shown))
        '${item.title} → ${labelFor(move.to, reading: _isReading(item))}',
    ].join(', ');
    final more = applied.length > shown
        ? ' +${applied.length - shown} more'
        : '';
    return 'Moved ${applied.length} idle titles: $names$more';
  }

  /// One notice with Undo: the desktop toast on Windows, a SnackBar elsewhere.
  void _announce(List<(ListIdleMove, MediaItem)> applied) {
    final message = noticeText(applied);
    void undo() => unawaited(_undo(applied));
    const duration = Duration(seconds: 10);
    if (defaultTargetPlatform == TargetPlatform.windows) {
      final ctx = _toastContext();
      if (ctx != null) {
        showUndoToast(ctx, message: message, onUndo: undo, duration: duration);
        return;
      }
    }
    rootMessengerKey.currentState?.showSnackBar(SnackBar(
      key: const ValueKey('list-idle-status'),
      content: Text(message),
      behavior: SnackBarBehavior.floating,
      duration: duration,
      action: SnackBarAction(label: 'Undo', onPressed: undo),
    ));
  }

  /// A context just below the root navigator's overlay, so the toast can
  /// find that overlay (the navigator's own context sits above it).
  BuildContext? _toastContext() {
    final overlayCtx = rootNavigatorKey.currentState?.overlay?.context;
    if (overlayCtx == null) return null;
    BuildContext? child;
    overlayCtx.visitChildElements((e) => child ??= e);
    return child;
  }
}
