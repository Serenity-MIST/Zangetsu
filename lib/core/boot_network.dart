import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// Opens a TCP connection to [host]:443 and reports whether the network looks
/// unreachable. Any failure (DNS, refused, timeout) counts as offline.
///
/// Cold start awaits cloud work serially (Supabase init, profile merge,
/// library sync, lock-status RPC). On a dead network (Wi-Fi with no internet
/// is the common case) every call waits out its own timeout, so the splash
/// could sit for most of a minute and then fail. One short probe lets boot
/// skip the cloud half; everything skipped self-heals once the network is
/// back (retry init, resume sync, lock cache fallback, and the reconnect
/// tasks run by [BootConnectivity]).
Future<bool> probeBootOffline({
  required String host,
  Duration timeout = const Duration(seconds: 2),
}) async {
  if (host.isEmpty) return false;
  try {
    final socket = await Socket.connect(host, 443, timeout: timeout);
    socket.destroy();
    return false;
  } catch (_) {
    return true;
  }
}

/// True only when **none** of [hosts] can be reached. One host being down (a
/// single service outage) must not flip the whole app offline, so the network
/// counts as down only when every host fails. Hosts are tried at the same time,
/// so a dead network costs one timeout, not one per host. An empty list is
/// treated as online.
Future<bool> probeAllUnreachable(
  Iterable<String> hosts, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final list = hosts.where((h) => h.isNotEmpty).toSet().toList();
  if (list.isEmpty) return false;
  final results = await Future.wait([
    for (final host in list) probeBootOffline(host: host, timeout: timeout),
  ]);
  return results.every((unreachable) => unreachable);
}

/// Whether [error] means "the network is gone" (as opposed to a server that
/// answered with an error). Used to trigger an immediate connectivity check when
/// a request fails, instead of waiting for the next scheduled one.
bool isNetworkFailure(Object? error) {
  if (error is SocketException) return true;
  if (error is DioException) {
    return switch (error.type) {
      DioExceptionType.connectionError ||
      DioExceptionType.connectionTimeout => true,
      DioExceptionType.unknown => error.error is SocketException,
      _ => false,
    };
  }
  return false;
}

/// Signature of the connectivity check, so tests can replace the real socket.
/// Returns true when the network looks unreachable.
typedef OfflineProbe = Future<bool> Function();

/// Watches whether the PC can reach the internet, for the whole session.
///
/// The title bar shows an Offline pill, and Home shows downloaded shows, while
/// [offline] is true. It starts true when boot found no network, and flips by
/// itself later: a Wi-Fi drop or an ISP outage while the app is open switches to
/// offline mode, and the network coming back switches it off again.
///
/// Going offline is debounced so a short network blip (Wi-Fi reassociation,
/// DHCP renew, one failed request) never flips the app: it needs
/// [offlineConfirmProbes] failed probes in a row that also span at least
/// [offlineGrace], re-probing every [confirmDelay]. Any success in between
/// cancels it. Coming back online needs one success only. Checks run on a timer
/// ([onlineInterval] while online, [offlineInterval] while offline) and
/// immediately when [suspectOffline] is called because a request just failed.
/// Every time the network returns, the registered reconnect tasks run once
/// (profile merge, library sync, ...).
class BootConnectivity {
  BootConnectivity({
    this.onlineInterval = const Duration(seconds: 10),
    this.offlineInterval = const Duration(seconds: 3),
    this.confirmDelay = const Duration(seconds: 3),
    this.linkInterval = const Duration(seconds: 2),
    this.offlineConfirmProbes = 3,
    this.offlineGrace = const Duration(seconds: 8),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// Failed probes in a row needed before switching to offline (min 1).
  final int offlineConfirmProbes;

  /// How long the failures must last (first probe to last) before switching
  /// to offline. Together with [offlineConfirmProbes] this is the debounce.
  final Duration offlineGrace;

  /// Clock used to measure [offlineGrace]; injectable so tests can fake time.
  final DateTime Function() _now;

  /// Set by [dispose] so a confirmation loop in flight stops early.
  bool _disposed = false;

  /// How often the cheap local-link check runs (see [start]'s `linkDown`).
  final Duration linkInterval;
  Timer? _linkTimer;

  /// Optional cheap check: true when the PC has no network adapter with an
  /// address (Wi-Fi switched off, cable out). Wi-Fi off starts the debounced
  /// offline confirmation at once (an address can vanish for a second during a
  /// Wi-Fi reassociation, so it never flips by itself), and Wi-Fi on triggers a
  /// real check at once, instead of waiting for a timer.
  Future<bool> Function()? _linkDown;

  /// Shared instance used by the app. Tests build their own.
  static final BootConnectivity instance = BootConnectivity();

  final Duration onlineInterval, offlineInterval, confirmDelay;
  OfflineProbe? _probe;

  /// True while the network is unreachable.
  final ValueNotifier<bool> offline = ValueNotifier<bool>(false);

  final List<Future<void> Function()> _reconnectTasks = [];
  Timer? _timer;
  bool _checking = false;

  /// Registers work to run each time the network returns after being down.
  /// Registering the same task again is ignored.
  void addReconnectTask(Future<void> Function() task) {
    if (!_reconnectTasks.contains(task)) _reconnectTasks.add(task);
  }

  /// Stops running [task] on reconnect (its owner was disposed).
  void removeReconnectTask(Future<void> Function() task) {
    _reconnectTasks.remove(task);
  }

  /// Begins watching. [offline] is what boot already found; later changes come
  /// from the checks.
  void start(
    OfflineProbe probe, {
    required bool offline,
    Future<bool> Function()? linkDown,
  }) {
    _disposed = false;
    _probe = probe;
    _linkDown = linkDown;
    this.offline.value = offline;
    _arm();
    _linkTimer?.cancel();
    if (linkDown != null) {
      _linkTimer = Timer.periodic(linkInterval, (_) => unawaited(_linkTick()));
    }
  }

  Future<void> _linkTick() async {
    final check = _linkDown;
    if (check == null || _checking) return;
    final down = await check();
    if (down && !offline.value) {
      // No adapter has an address. This also happens for a second or two
      // during a Wi-Fi reassociation or DHCP renew, so only start the debounced
      // confirmation; checkNow decides whether it is a real outage.
      unawaited(checkNow());
    } else if (!down && offline.value) {
      // A link is back: verify with the real probe right now.
      unawaited(checkNow());
    }
  }

  /// Boot found the network down. Equivalent to `start(probe, offline: true)`.
  void startOffline(OfflineProbe probe) => start(probe, offline: true);

  /// Call when a request failed in a way that looks like a lost connection.
  /// Starts a check right away (when online) instead of waiting for the timer.
  /// Safe to call often: a check already running is not repeated.
  void suspectOffline() {
    if (_probe != null && !offline.value) unawaited(checkNow());
  }

  /// One check, now. Updates [offline], re-arms the timer for the new state and
  /// runs reconnect tasks when the network just came back.
  Future<void> checkNow() async {
    final probe = _probe;
    if (_checking || probe == null) return;
    _checking = true;
    try {
      if (offline.value) {
        // Coming back online needs only one success, so recovery is prompt.
        if (await probe() || _disposed) return;
        offline.value = false;
        _arm();
        await _runReconnectTasks();
        return;
      }
      // Online: debounce. Keep probing every confirmDelay; any success means
      // it was a blip and nothing changes. Switch to offline only after
      // offlineConfirmProbes failures in a row that span offlineGrace.
      final started = _now();
      var failures = 0;
      while (true) {
        final probeStarted = _now();
        if (!await probe()) return; // reachable: the streak is over
        if (_disposed) return;
        failures++;
        final enoughProbes = failures >= offlineConfirmProbes;
        final longEnough = _now().difference(started) >= offlineGrace;
        if (enoughProbes && longEnough) break;
        // Probes start confirmDelay apart: a probe that waited out its own
        // timeout (about 3 s on a dead network) already used that time, so a
        // real outage still shows Offline after ~9 s instead of ~15 s.
        final left = confirmDelay - _now().difference(probeStarted);
        await Future<void>.delayed(left.isNegative ? Duration.zero : left);
        if (_disposed) return;
      }
      offline.value = true;
      _arm();
    } finally {
      _checking = false;
    }
  }

  Future<void> _runReconnectTasks() async {
    // One task failing must not stop the others or leave the pill stuck.
    for (final task in List.of(_reconnectTasks)) {
      try {
        await task();
      } catch (e) {
        debugPrint('[net] reconnect task failed: $e');
      }
    }
  }

  void _arm() {
    _timer?.cancel();
    _timer = Timer.periodic(
      offline.value ? offlineInterval : onlineInterval,
      (_) => unawaited(checkNow()),
    );
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _linkTimer?.cancel();
    _linkTimer = null;
  }
}

/// True when no non-loopback network adapter has an IPv4 address. Cheap (no
/// traffic), so it can run every couple of seconds. Errors count as "link up" so
/// a failure here never flips the app offline by itself.
Future<bool> localLinkDown() async {
  try {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      includeLinkLocal: false,
      type: InternetAddressType.IPv4,
    );
    return interfaces.every((i) => i.addresses.isEmpty);
  } catch (_) {
    return false;
  }
}
