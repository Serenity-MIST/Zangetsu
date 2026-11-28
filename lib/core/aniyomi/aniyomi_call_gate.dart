import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

/// Windows only: keeps heavy Aniyomi calls from starving each other.
///
/// On Windows every Aniyomi source runs inside one companion extension
/// engine. A playback sweep asks three Aniyomi sources at once, and a named
/// lookup that just ran out of budget is often still running, so four or
/// more episode-list and video-list requests piled onto the one engine and
/// all of them ran past their limits together. This gate:
///
/// * lets at most [maxParallel] of those calls run at a time; the rest wait
///   their turn in order, so the first ones finish instead of all crawling;
/// * joins a call that is identical to one already running (same method and
///   arguments) to that running call instead of sending it twice.
///
/// Phone and TV never use it: Android runs each source natively.
class AniyomiCallGate {
  AniyomiCallGate({
    this.maxParallel = 2,
    this.callTimeout = defaultCallTimeout,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// Safety limit for one gated call once it has a slot. The engine's own
  /// limit for a video list is 60s; this is a little longer so the engine
  /// normally answers first, and a stuck call can never hold a slot forever.
  static const Duration defaultCallTimeout = Duration(seconds: 70);

  /// See [defaultCallTimeout].
  final Duration callTimeout;

  final DateTime Function() _now;

  /// Last time a call had to queue for a slot, or was handed one after
  /// queueing. See [queuedSince].
  DateTime? _lastQueueAt;

  /// The gate the Windows Aniyomi providers share.
  static final AniyomiCallGate instance = AniyomiCallGate();

  /// True where the gate applies (Windows desktop).
  static bool get enabled =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  /// The calls worth gating: the heavy, per-episode ones a sweep makes.
  /// Browsing calls (search, popular, covers) are left alone.
  static bool gates(String method) =>
      method == 'getEpisodes' || method == 'getVideoList';

  /// How many gated calls may run at the same time.
  final int maxParallel;

  int _running = 0;
  final Queue<Completer<void>> _waiting = Queue<Completer<void>>();
  final Map<String, Future<String?>> _inFlight = {};

  /// Calls running right now (for tests).
  @visibleForTesting
  int get running => _running;

  /// Calls waiting for a free slot (for tests).
  @visibleForTesting
  int get waiting => _waiting.length;

  /// True when some call is queued right now, or queued (or left the queue)
  /// after [since]. Time spent in the queue is not the source's fault, so the
  /// playback resolver does not count a slow answer against an Aniyomi source
  /// while this is true.
  bool queuedSince(DateTime since) {
    if (_waiting.isNotEmpty) return true;
    final at = _lastQueueAt;
    return at != null && at.isAfter(since);
  }

  /// Runs [call] under the gate. [key] names the request (method plus its
  /// arguments); a second request with the same key while the first is still
  /// running gets the first one's result instead of a new call.
  Future<String?> run(String key, Future<String?> Function() call) {
    final joined = _inFlight[key];
    if (joined != null) return joined;
    final future = _limited(call);
    _inFlight[key] = future;
    // Forget the entry once it settles. Errors are left for the callers;
    // this side listener only swallows its own copy.
    unawaited(
      future.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
        if (identical(_inFlight[key], future)) _inFlight.remove(key);
      }),
    );
    return future;
  }

  Future<String?> _limited(Future<String?> Function() call) async {
    if (_running >= maxParallel) {
      final turn = Completer<void>();
      _waiting.add(turn);
      _lastQueueAt = _now();
      // The slot is handed over by the call that finishes, still counted.
      await turn.future;
    } else {
      _running++;
    }
    try {
      // A stuck call gives its slot back after [callTimeout]; the caller
      // gets a TimeoutException (the provider turns that into "no answer").
      return await call().timeout(callTimeout);
    } finally {
      if (_waiting.isNotEmpty) {
        // Pass this slot straight to the next waiting call.
        _lastQueueAt = _now();
        _waiting.removeFirst().complete();
      } else {
        _running--;
      }
    }
  }
}
