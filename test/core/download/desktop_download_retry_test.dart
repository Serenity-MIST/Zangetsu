import 'dart:async';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/desktop_download_retry.dart';
import 'package:watch_app/core/download/download_record.dart';

/// Can deliberately deliver a stale callback after cancellation.
class _LateTimer implements Timer {
  _LateTimer(this.action);
  final void Function() action;
  bool active = true;
  @override bool get isActive => active;
  @override int get tick => 0;
  @override void cancel() { active = false; }
}

void main() {
  final epoch = DateTime.utc(2026, 10, 28);
  test('deadline does not fire early and runs exactly once', () {
    fakeAsync((async) {
      final clock = async.getClock(epoch);
      final scheduler = DesktopDownloadRetry(now: clock.now);
      var calls = 0;
      scheduler.schedule('episode', 'one', epoch.add(const Duration(minutes: 2)), () => calls++);
      async.elapse(const Duration(seconds: 119));
      expect(calls, 0);
      async.elapse(const Duration(seconds: 1));
      expect(calls, 1);
      async.elapse(const Duration(days: 1));
      expect(calls, 1);
      scheduler.dispose();
    });
  });
  test('replacement, cancellation and disposal retire their callbacks', () {
    fakeAsync((async) {
      final scheduler = DesktopDownloadRetry(now: async.getClock(epoch).now);
      var old = 0; var fresh = 0;
      scheduler.schedule('same', 'old', epoch.add(const Duration(seconds: 1)), () => old++);
      scheduler.schedule('same', 'new', epoch.add(const Duration(seconds: 2)), () => fresh++);
      async.elapse(const Duration(seconds: 2));
      expect(old, 0); expect(fresh, 1);
      scheduler.schedule('paused', 'one', epoch.add(const Duration(seconds: 3)), () => old++);
      scheduler.cancel('paused');
      scheduler.schedule('disposed', 'one', epoch.add(const Duration(seconds: 3)), () => old++);
      scheduler.dispose();
      async.elapse(const Duration(days: 2));
      expect(old, 0);
    });
  });
  test('huge hints use bounded timers without shortening the deadline', () {
    var now = epoch;
    final durations = <Duration>[];
    final timers = <_LateTimer>[];
    final scheduler = DesktopDownloadRetry(now: () => now, timerFactory: (duration, action) {
      durations.add(duration);
      final timer = _LateTimer(action); timers.add(timer); return timer;
    });
    var calls = 0;
    scheduler.schedule('long', 'one', epoch.add(const Duration(days: 10)), () => calls++);
    expect(durations.single, const Duration(days: 1));
    now = epoch.add(const Duration(days: 1)); timers.first.action();
    expect(calls, 0);
    expect(durations.last, const Duration(days: 1));
    now = epoch.add(const Duration(days: 10)); timers.last.action();
    expect(calls, 1);
    scheduler.dispose();
  });
  test('already-delivered obsolete timer cannot fire replacement', () {
    final timers = <_LateTimer>[];
    final scheduler = DesktopDownloadRetry(now: () => epoch, timerFactory: (_, action) {
      final timer = _LateTimer(action); timers.add(timer); return timer;
    });
    var calls = 0;
    scheduler.schedule('same', 'old', epoch, () => calls += 10);
    scheduler.schedule('same', 'new', epoch, () => calls++);
    timers.first.action(); expect(calls, 0);
    timers.last.action(); expect(calls, 1);
    scheduler.dispose();
  });
  test('persisted pending intent and nullable clearing preserve legacy defaults', () {
    final legacy = DownloadRecord.fromMap({'id': 'episode'});
    expect(legacy.retryAt, isNull); expect(legacy.retryHost, isNull);
    expect(legacy.retryCount, 0); expect(legacy.autoResumePending, isFalse);
    final waiting = legacy.copyWith(retryAt: () => epoch.millisecondsSinceEpoch,
        retryHost: () => 'cdn.test', retryCount: 2, autoResumePending: true);
    final reopened = DownloadRecord.fromMap(waiting.toMap());
    expect(reopened.retryAt, epoch.millisecondsSinceEpoch);
    expect(reopened.retryHost, 'cdn.test'); expect(reopened.retryCount, 2);
    expect(reopened.autoResumePending, isTrue);
    final resumed = reopened.copyWith(retryAt: () => null, retryHost: () => null);
    expect(resumed.retryAt, isNull); expect(resumed.retryHost, isNull);
    expect(resumed.retryCount, 2);
  });
}
