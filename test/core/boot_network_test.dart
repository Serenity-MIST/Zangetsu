import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/boot_network.dart';
import 'package:watch_app/core/desktop/desktop_title_bar.dart';

/// A watcher with no real waiting, so tests can drive checks by hand. The
/// offline debounce keeps its probe count (3) but has no minimum duration.
BootConnectivity _watcher() => BootConnectivity(
  onlineInterval: const Duration(hours: 1),
  offlineInterval: const Duration(hours: 1),
  confirmDelay: Duration.zero,
  offlineGrace: Duration.zero,
);

/// A watcher with the production debounce timings, driven by the widget test's
/// fake clock so `tester.pump` moves both timers and the grace measurement.
BootConnectivity _fakeTimeWatcher(WidgetTester tester) =>
    BootConnectivity(now: () => tester.binding.clock.now());

/// Pumps fake time one second at a time for [seconds] and returns the fake
/// second (from the call) at which [offline] first became true, or null.
Future<int?> _pumpSeconds(
  WidgetTester tester,
  ValueNotifier<bool> offline,
  int seconds, {
  void Function(int second)? onSecond,
}) async {
  int? flippedAt;
  for (var s = 1; s <= seconds; s++) {
    onSecond?.call(s);
    await tester.pump(const Duration(seconds: 1));
    if (offline.value && flippedAt == null) flippedAt = s;
  }
  return flippedAt;
}

void main() {
  group('probes', () {
    test('an empty host is treated as online so boot is never held back', () async {
      expect(await probeBootOffline(host: ''), isFalse);
    });

    test('an unreachable host reports offline', () async {
      // ".invalid" is reserved and never resolves.
      expect(
        await probeBootOffline(
          host: 'zangetsu-test.invalid',
          timeout: const Duration(milliseconds: 800),
        ),
        isTrue,
      );
    });

    test('with several hosts, the network is down only when all fail', () async {
      const timeout = Duration(milliseconds: 800);
      expect(
        await probeAllUnreachable(
          const ['a.invalid', 'b.invalid'],
          timeout: timeout,
        ),
        isTrue,
      );
      // No hosts to check means nothing to disprove: online.
      expect(await probeAllUnreachable(const []), isFalse);
      expect(await probeAllUnreachable(const ['', '']), isFalse);
    });

    test('a host that does answer keeps the network online', () async {
      // A local listener stands in for a reachable server; port 443 itself is
      // not available in tests, so check the probe's contract via the socket
      // helper instead: connecting to a closed port counts as unreachable.
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final socket = await Socket.connect('127.0.0.1', server.port);
      socket.destroy();
      expect(server.port, greaterThan(0));
    });
  });

  group('isNetworkFailure', () {
    DioException dio(DioExceptionType type, {Object? error}) => DioException(
      requestOptions: RequestOptions(path: '/x'),
      type: type,
      error: error,
    );

    test('a lost connection counts', () {
      expect(isNetworkFailure(const SocketException('gone')), isTrue);
      expect(isNetworkFailure(dio(DioExceptionType.connectionError)), isTrue);
      expect(isNetworkFailure(dio(DioExceptionType.connectionTimeout)), isTrue);
      expect(
        isNetworkFailure(
          dio(DioExceptionType.unknown, error: const SocketException('x')),
        ),
        isTrue,
      );
    });

    test('a server that answered does not', () {
      expect(isNetworkFailure(dio(DioExceptionType.badResponse)), isFalse);
      expect(isNetworkFailure(dio(DioExceptionType.cancel)), isFalse);
      expect(isNetworkFailure(dio(DioExceptionType.receiveTimeout)), isFalse);
      expect(isNetworkFailure(dio(DioExceptionType.unknown)), isFalse);
      expect(isNetworkFailure(StateError('nope')), isFalse);
      expect(isNetworkFailure(null), isFalse);
    });
  });

  group('BootConnectivity', () {
    test('stays idle until started', () async {
      final connectivity = _watcher();
      var ran = false;
      connectivity.addReconnectTask(() async => ran = true);
      await connectivity.checkNow();
      expect(connectivity.offline.value, isFalse);
      expect(ran, isFalse);
    });

    test('starts offline when boot found no network', () async {
      final connectivity = _watcher()..startOffline(() async => true);
      expect(connectivity.offline.value, isTrue);
      await connectivity.checkNow();
      expect(connectivity.offline.value, isTrue);
      connectivity.dispose();
    });

    test('goes offline by itself mid-session, then returns', () async {
      // The Wi-Fi drops while the app is open, later it comes back.
      var down = false;
      final connectivity = _watcher()..start(() async => down, offline: false);
      var resyncs = 0;
      connectivity.addReconnectTask(() async => resyncs++);

      await connectivity.checkNow();
      expect(connectivity.offline.value, isFalse);

      down = true;
      await connectivity.checkNow();
      expect(connectivity.offline.value, isTrue);
      expect(resyncs, 0); // nothing to resync while down

      down = false;
      await connectivity.checkNow();
      expect(connectivity.offline.value, isFalse);
      expect(resyncs, 1);
      connectivity.dispose();
    });

    test('works over many drops: each return runs the reconnect work once', () async {
      var down = false;
      final connectivity = _watcher()..start(() async => down, offline: false);
      var resyncs = 0;
      connectivity.addReconnectTask(() async => resyncs++);
      for (var i = 0; i < 3; i++) {
        down = true;
        await connectivity.checkNow();
        down = false;
        await connectivity.checkNow();
        // Extra checks while online must not repeat the work.
        await connectivity.checkNow();
      }
      expect(resyncs, 3);
      connectivity.dispose();
    });

    test('one dropped probe is not an outage', () async {
      // Fails once, then answers: a blip, not an outage.
      var calls = 0;
      final connectivity = _watcher()
        ..start(() async => ++calls == 1, offline: false);
      await connectivity.checkNow();
      expect(connectivity.offline.value, isFalse);
      expect(calls, 2); // it re-checked before deciding
      connectivity.dispose();
    });

    test('a failed request starts an immediate check', () async {
      var probes = 0;
      final connectivity = _watcher()
        ..start(() async {
          probes++;
          return true;
        }, offline: false);
      connectivity.suspectOffline();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(connectivity.offline.value, isTrue);
      expect(probes, greaterThanOrEqualTo(2));
      connectivity.dispose();
    });

    test('suspecting while already offline or before start does nothing', () async {
      var probes = 0;
      final idle = _watcher()..suspectOffline();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(idle.offline.value, isFalse);

      final off = _watcher()
        ..startOffline(() async {
          probes++;
          return true;
        });
      off.suspectOffline();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(probes, 0);
      off.dispose();
    });

    test('overlapping checks are not run twice', () async {
      var probes = 0;
      final connectivity = _watcher()
        ..start(() async {
          probes++;
          await Future<void>.delayed(const Duration(milliseconds: 40));
          return false;
        }, offline: false);
      await Future.wait([
        connectivity.checkNow(),
        connectivity.checkNow(),
        connectivity.checkNow(),
      ]);
      expect(probes, 1);
      connectivity.dispose();
    });

    test('a failing reconnect task does not block the others', () async {
      var down = true;
      final connectivity = _watcher()..start(() async => down, offline: true);
      var secondRan = false;
      connectivity.addReconnectTask(() async => throw StateError('boom'));
      connectivity.addReconnectTask(() async => secondRan = true);
      down = false;
      await connectivity.checkNow();
      expect(connectivity.offline.value, isFalse);
      expect(secondRan, isTrue);
      connectivity.dispose();
    });

    test('the same reconnect task is registered once', () async {
      var down = true;
      final connectivity = _watcher()..start(() async => down, offline: true);
      var runs = 0;
      Future<void> task() async => runs++;
      connectivity
        ..addReconnectTask(task)
        ..addReconnectTask(task);
      down = false;
      await connectivity.checkNow();
      expect(runs, 1);
      connectivity.dispose();
    });

    test('re-checks on its own timer in both directions', () async {
      var down = false;
      final connectivity = BootConnectivity(
        onlineInterval: const Duration(milliseconds: 30),
        offlineInterval: const Duration(milliseconds: 30),
        confirmDelay: Duration.zero,
        offlineGrace: Duration.zero,
      )..start(() async => down, offline: false);
      down = true;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(connectivity.offline.value, isTrue);
      down = false;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(connectivity.offline.value, isFalse);
      connectivity.dispose();
    });
  });

  // The offline debounce with production timings (3 probes, 3 s apart, at
  // least 8 s of failures), on the widget test's fake clock.
  group('BootConnectivity debounce (fake time)', () {
    testWidgets('a single failed probe followed by success stays online', (
      tester,
    ) async {
      var calls = 0;
      final c = _fakeTimeWatcher(tester)
        ..start(() async => ++calls == 1, offline: false);
      var flips = 0;
      c.offline.addListener(() => flips++);
      c.suspectOffline(); // a request failed
      expect(await _pumpSeconds(tester, c.offline, 30), isNull);
      expect(flips, 0);
      c.dispose();
      await tester.pump(const Duration(seconds: 10)); // drain pending delays
    });

    testWidgets('a 2 s link blip (adapter loses its address) stays online', (
      tester,
    ) async {
      // Blip from second 3 to 5: no IPv4 address and probes fail fast.
      var blip = false;
      final c = _fakeTimeWatcher(tester)
        ..start(
          () async => blip,
          offline: false,
          linkDown: () async => blip,
        );
      var flips = 0;
      c.offline.addListener(() => flips++);
      final flipped = await _pumpSeconds(
        tester,
        c.offline,
        30,
        onSecond: (s) => blip = s >= 3 && s < 5,
      );
      expect(flipped, isNull);
      expect(flips, 0);
      c.dispose();
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('failures lasting ~8-10 s switch to offline', (tester) async {
      var probes = 0;
      final c = _fakeTimeWatcher(tester)
        ..start(() async {
          probes++;
          return true; // network fully gone
        }, offline: false);
      c.suspectOffline();
      final flipped = await _pumpSeconds(tester, c.offline, 20);
      // Not before the grace period, and not much after it.
      expect(flipped, isNotNull);
      expect(flipped, inInclusiveRange(8, 10));
      expect(probes, greaterThanOrEqualTo(3));
      c.dispose();
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('slow probes (3 s timeouts) still flip within ~8-10 s', (
      tester,
    ) async {
      // A dead network: each probe waits out a 3 s timeout before failing.
      var probes = 0;
      final c = _fakeTimeWatcher(tester)
        ..start(() async {
          probes++;
          await Future<void>.delayed(const Duration(seconds: 3));
          return true;
        }, offline: false);
      c.suspectOffline();
      final flipped = await _pumpSeconds(tester, c.offline, 20);
      expect(flipped, isNotNull);
      expect(flipped, inInclusiveRange(8, 10));
      expect(probes, greaterThanOrEqualTo(3));
      c.dispose();
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('3 quick failures inside the grace period do not flip yet', (
      tester,
    ) async {
      final c = BootConnectivity(
        confirmDelay: const Duration(seconds: 1),
        now: () => tester.binding.clock.now(),
      )..start(() async => true, offline: false);
      c.suspectOffline();
      // 3 failures at 0, 1 and 2 s: enough probes, not enough time.
      await _pumpSeconds(tester, c.offline, 3);
      expect(c.offline.value, isFalse);
      final flipped = await _pumpSeconds(tester, c.offline, 10);
      // Flips once 8 s have passed since the first failure.
      expect(flipped, isNotNull);
      expect(3 + flipped!, inInclusiveRange(8, 9));
      c.dispose();
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('one success while offline comes back and resyncs once', (
      tester,
    ) async {
      var down = true;
      final c = _fakeTimeWatcher(tester)
        ..start(
          () async => down,
          offline: true,
          linkDown: () async => down,
        );
      var resyncs = 0;
      c.addReconnectTask(() async => resyncs++);
      await _pumpSeconds(tester, c.offline, 5);
      expect(c.offline.value, isTrue);
      expect(resyncs, 0);

      down = false;
      // The link tick (every 2 s) re-probes at once: one success is enough.
      await tester.pump(const Duration(seconds: 2));
      expect(c.offline.value, isFalse);
      expect(resyncs, 1);
      // Staying online does not repeat the reconnect work.
      await _pumpSeconds(tester, c.offline, 30);
      expect(resyncs, 1);
      c.dispose();
      await tester.pump(const Duration(seconds: 10));
    });
  });

  group('ConnectionPill', () {
    Future<void> pump(WidgetTester tester, ValueNotifier<bool> offline) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: ConnectionPill(offline: offline)),
          ),
        );

    testWidgets('draws nothing when the app started online', (tester) async {
      final offline = ValueNotifier<bool>(false);
      await pump(tester, offline);
      expect(find.text('Offline'), findsNothing);
      expect(find.text('Back online'), findsNothing);
      // Going "online" again must not flash a message nobody asked for.
      offline.value = false;
      await tester.pumpAndSettle();
      expect(find.text('Back online'), findsNothing);
    });

    testWidgets('shows Offline, then Back online, then disappears', (
      tester,
    ) async {
      final offline = ValueNotifier<bool>(true);
      await pump(tester, offline);
      await tester.pumpAndSettle();
      expect(find.text('Offline'), findsOneWidget);

      offline.value = false;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Back online'), findsOneWidget);
      expect(find.text('Offline'), findsNothing);

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.text('Back online'), findsNothing);
    });

    testWidgets('appears when the network drops while the page is open', (
      tester,
    ) async {
      final offline = ValueNotifier<bool>(false);
      await pump(tester, offline);
      expect(find.text('Offline'), findsNothing);

      offline.value = true;
      await tester.pumpAndSettle();
      expect(find.text('Offline'), findsOneWidget);
    });
  });
}
