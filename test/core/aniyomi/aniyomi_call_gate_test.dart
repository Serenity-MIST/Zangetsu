import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/aniyomi/aniyomi_call_gate.dart';

void main() {
  test('at most two gated calls run at once; the rest wait in order', () async {
    final gate = AniyomiCallGate(maxParallel: 2);
    final release = [for (var i = 0; i < 3; i++) Completer<String?>()];
    final started = <int>[];
    final results = [
      for (var i = 0; i < 3; i++)
        gate.run('call $i', () {
          started.add(i);
          return release[i].future;
        }),
    ];
    await Future<void>.delayed(Duration.zero);
    expect(started, [0, 1]);
    expect(gate.running, 2);
    expect(gate.waiting, 1);

    release[0].complete('a');
    await Future<void>.delayed(Duration.zero);
    expect(started, [0, 1, 2]);

    release[1].complete('b');
    release[2].complete('c');
    expect(await Future.wait(results), ['a', 'b', 'c']);
    expect(gate.running, 0);
  });

  test('an identical call joins the one already running', () async {
    final gate = AniyomiCallGate();
    final release = Completer<String?>();
    var calls = 0;
    Future<String?> call() {
      calls++;
      return release.future;
    }

    final first = gate.run('getVideoList {"url":"x"}', call);
    final second = gate.run('getVideoList {"url":"x"}', call);
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    release.complete('videos');
    expect(await first, 'videos');
    expect(await second, 'videos');

    // Once settled, the same request is sent fresh again.
    final third = gate.run('getVideoList {"url":"x"}', () async => 'again');
    expect(await third, 'again');
  });

  test('a failing call frees its slot and reaches every caller', () async {
    final gate = AniyomiCallGate(maxParallel: 1);
    final failing = gate.run('a', () async => throw StateError('boom'));
    final next = gate.run('b', () async => 'ok');
    await expectLater(failing, throwsStateError);
    expect(await next, 'ok');
    expect(gate.running, 0);
  });

  testWidgets(
    'the gate is on for Windows',
    (tester) async => expect(AniyomiCallGate.enabled, isTrue),
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'the gate stays off on phones and TV',
    (tester) async => expect(AniyomiCallGate.enabled, isFalse),
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  test('only the heavy per-episode calls are gated', () {
    expect(AniyomiCallGate.gates('getVideoList'), isTrue);
    expect(AniyomiCallGate.gates('getEpisodes'), isTrue);
    expect(AniyomiCallGate.gates('search'), isFalse);
    expect(AniyomiCallGate.gates('getImage'), isFalse);
  });

  test('queuedSince tells when a call had to wait for a slot', () async {
    var clock = DateTime(2026, 1, 1, 12);
    final gate = AniyomiCallGate(maxParallel: 1, now: () => clock);
    final before = clock.subtract(const Duration(seconds: 1));
    // Nothing queued yet.
    expect(gate.queuedSince(before), isFalse);

    final release = Completer<String?>();
    final first = gate.run('a', () => release.future);
    await Future<void>.delayed(Duration.zero);
    // One call running, none waiting: still no queue.
    expect(gate.queuedSince(before), isFalse);

    final second = gate.run('b', () async => 'b');
    await Future<void>.delayed(Duration.zero);
    expect(gate.queuedSince(before), isTrue); // waiting right now

    clock = clock.add(const Duration(seconds: 30));
    release.complete('a');
    expect(await first, 'a');
    expect(await second, 'b');
    // The queue is empty again, but it was busy after [before].
    expect(gate.queuedSince(before), isTrue);
    // A later attempt that started after the queue cleared is not excused.
    expect(gate.queuedSince(clock.add(const Duration(seconds: 1))), isFalse);
  });

  test('a stuck call gives its slot back after the safety timeout', () async {
    // The default is a little over the engine's 60s video-list limit.
    expect(AniyomiCallGate.defaultCallTimeout, const Duration(seconds: 70));
    final gate = AniyomiCallGate(
      maxParallel: 1,
      callTimeout: const Duration(milliseconds: 30),
    );
    final stuck = gate.run('stuck', () => Completer<String?>().future);
    final next = gate.run('next', () async => 'ok');
    await Future<void>.delayed(Duration.zero);
    expect(gate.waiting, 1);
    await expectLater(stuck, throwsA(isA<TimeoutException>()));
    expect(await next, 'ok');
    expect(gate.running, 0);
  });
}
