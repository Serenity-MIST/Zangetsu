// 'Download next' support in the shared slot FIFO (dl-6).
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/transfer_slots.dart';

void main() {
  test('moveToFront gives a waiting job the next free slot', () async {
    final slots = TransferSlots(1);
    final running = (await slots.acquire('running'))!;
    final started = <String>[];
    for (final id in ['a', 'b', 'c']) {
      slots.acquire(id).then((lease) {
        if (lease != null) started.add(id);
      });
    }
    expect(slots.waitingPosition('c'), 2);
    expect(slots.moveToFront('c'), isTrue);
    expect(slots.waitingPosition('c'), 0);
    expect(slots.waitingPosition('a'), 1);
    running.release();
    await Future<void>.delayed(Duration.zero);
    expect(started, ['c']);
  });

  test('moveToFront ignores jobs that are not waiting', () async {
    final slots = TransferSlots(1);
    await slots.acquire('running');
    expect(slots.moveToFront('running'), isFalse);
    expect(slots.moveToFront('unknown'), isFalse);
    expect(slots.isWaiting('running'), isFalse);
    expect(slots.waitingPosition('unknown'), -1);
  });
}
