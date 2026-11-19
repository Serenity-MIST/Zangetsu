// R5: rules for auto Paused / Dropped (pure service, fake clock, no Hive).
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/playback/list_idle_status.dart';

void main() {
  // Fake clock the tests move forward by hand.
  var now = DateTime(2026, 1, 1);
  late MemoryListIdleClockStore store;
  late ListIdleService service;
  final rule = ListIdleRule(enabled: true); // 15 / 30 defaults

  setUp(() {
    now = DateTime(2026, 1, 1);
    store = MemoryListIdleClockStore();
    service = ListIdleService(store: store, now: () => now);
  });

  ListIdleEntry entry(WatchStatus? s, {int? progress}) =>
      ListIdleEntry(key: 'k', status: s, progressMs: progress);

  /// Advances the fake clock by [days].
  void later(int days) => now = now.add(Duration(days: days));

  test('first run seeds every title and moves nothing', () async {
    final moves = await service.sweep([
      const ListIdleEntry(key: 'a', status: WatchStatus.watching),
      const ListIdleEntry(key: 'b', status: WatchStatus.paused),
    ], rule);
    expect(moves, isEmpty);
    expect(store.data.keys, containsAll(['a', 'b']));
    expect(store.data['a']!['at'], now.millisecondsSinceEpoch);
  });

  test('watching pauses at 15 idle days, not at 14', () async {
    await service.sweep([entry(WatchStatus.watching)], rule); // seed
    later(14);
    expect(await service.sweep([entry(WatchStatus.watching)], rule), isEmpty);
    later(1);
    final moves = await service.sweep([entry(WatchStatus.watching)], rule);
    expect(moves.single.from, WatchStatus.watching);
    expect(moves.single.to, WatchStatus.paused);
    expect(moves.single.idleDays, 15);
  });

  test('paused drops after its own 30 days, counted from the move', () async {
    await service.sweep([entry(WatchStatus.watching)], rule);
    later(15);
    final pause = (await service.sweep([entry(WatchStatus.watching)], rule))
        .single;
    await service.markMoved(pause);
    later(29);
    expect(await service.sweep([entry(WatchStatus.paused)], rule), isEmpty);
    later(1);
    final drop = (await service.sweep([entry(WatchStatus.paused)], rule))
        .single;
    expect(drop.to, WatchStatus.dropped);
  });

  test('other statuses never move', () async {
    for (final s in [
      WatchStatus.planning,
      WatchStatus.completed,
      WatchStatus.dropped,
      null,
    ]) {
      store.data.clear();
      await service.sweep([entry(s)], rule);
      later(90);
      expect(await service.sweep([entry(s)], rule), isEmpty, reason: '$s');
    }
  });

  test('new history progress resets the clock', () async {
    await service.sweep([entry(WatchStatus.watching, progress: 1)], rule);
    later(10);
    final watchedAt = now.millisecondsSinceEpoch;
    await service.sweep(
      [entry(WatchStatus.watching, progress: watchedAt)],
      rule,
    );
    later(14); // 24 days since seed, 14 since progress
    expect(
      await service.sweep(
        [entry(WatchStatus.watching, progress: watchedAt)],
        rule,
      ),
      isEmpty,
    );
    later(1);
    expect(
      await service.sweep(
        [entry(WatchStatus.watching, progress: watchedAt)],
        rule,
      ),
      hasLength(1),
    );
  });

  test('a manual status change resets the clock', () async {
    await service.sweep([entry(WatchStatus.planning)], rule);
    later(20);
    // The user moved it to Watching by hand: no instant pause.
    expect(await service.sweep([entry(WatchStatus.watching)], rule), isEmpty);
    later(14);
    expect(await service.sweep([entry(WatchStatus.watching)], rule), isEmpty);
    later(1);
    expect(
      (await service.sweep([entry(WatchStatus.watching)], rule)).single.to,
      WatchStatus.paused,
    );
  });

  test('day values clamp to 7..30', () {
    final low = ListIdleRule(enabled: true, pauseDays: 3, dropDays: 1);
    final high = ListIdleRule(enabled: true, pauseDays: 45, dropDays: 99);
    expect(low.pauseDays, 7);
    expect(low.dropDays, 7);
    expect(high.pauseDays, 30);
    expect(high.dropDays, 30);
  });

  test('custom (clamped) thresholds are honoured', () async {
    final short = ListIdleRule(enabled: true, pauseDays: 3, dropDays: 3);
    await service.sweep([entry(WatchStatus.watching)], short);
    later(6);
    expect(await service.sweep([entry(WatchStatus.watching)], short), isEmpty);
    later(1);
    expect(
      await service.sweep([entry(WatchStatus.watching)], short),
      hasLength(1),
    );
  });

  test('disabled is a no-op and writes nothing', () async {
    final off = ListIdleRule(enabled: false);
    expect(await service.sweep([entry(WatchStatus.watching)], off), isEmpty);
    expect(store.data, isEmpty);
  });

  test('re-enabling never counts idle time from before the enable', () async {
    await service.sweep([entry(WatchStatus.watching)], rule);
    later(60); // feature was off all this time
    final enabledAt = now.millisecondsSinceEpoch;
    expect(
      await service.sweep(
        [entry(WatchStatus.watching)],
        rule,
        enabledSinceMs: enabledAt,
      ),
      isEmpty,
    );
    later(15);
    expect(
      await service.sweep(
        [entry(WatchStatus.watching)],
        rule,
        enabledSinceMs: enabledAt,
      ),
      hasLength(1),
    );
  });

  test('undo restores the old status and restarts the clock', () async {
    await service.sweep([entry(WatchStatus.watching)], rule);
    later(15);
    final move = (await service.sweep([entry(WatchStatus.watching)], rule))
        .single;
    await service.markMoved(move);
    later(1);
    await service.markUndone(move);
    expect(store.data['k']!['status'], 'watching');
    expect(store.data['k']!['at'], now.millisecondsSinceEpoch);
    // Back in Watching: a full 15 days again before the next pause.
    later(14);
    expect(await service.sweep([entry(WatchStatus.watching)], rule), isEmpty);
    later(1);
    expect(
      await service.sweep([entry(WatchStatus.watching)], rule),
      hasLength(1),
    );
  });

  test('an unapplied move is retried, not recorded', () async {
    await service.sweep([entry(WatchStatus.watching)], rule);
    later(15);
    expect(
      await service.sweep([entry(WatchStatus.watching)], rule),
      hasLength(1),
    );
    // markMoved never called (e.g. signed out): still due next time.
    expect(
      await service.sweep([entry(WatchStatus.watching)], rule),
      hasLength(1),
    );
  });
  // A status changed and changed back between sweeps is still a manual move:
  // the store hook calls markStatusSet, which restarts the clock.
  test('markStatusSet restarts the clock even if the status is unchanged',
      () async {
    await service.sweep([entry(WatchStatus.watching)], rule);
    later(14);
    await service.markStatusSet('k', WatchStatus.watching);
    later(14);
    expect(await service.sweep([entry(WatchStatus.watching)], rule), isEmpty);
    later(1);
    expect(
      await service.sweep([entry(WatchStatus.watching)], rule),
      hasLength(1),
    );
  });
}
