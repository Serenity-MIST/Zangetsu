import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/transfer_slots.dart';

void main() {
  test(
    'adopted native work consumes capacity even above a lowered limit',
    () async {
      final slots = TransferSlots(1)
        ..adopt('native1')
        ..adopt('native2');
      var started = false;
      final waiting = slots.acquire('new').then((lease) {
        started = true;
        return lease;
      });
      slots.release('native1');
      await Future<void>.delayed(Duration.zero);
      expect(started, isFalse);
      slots.release('native2');
      (await waiting)!.release();
      expect(started, isTrue);
    },
  );
  test(
    'one slot is shared and waits until the actual transfer finishes',
    () async {
      final slots = TransferSlots(1);
      final hls = (await slots.acquire('hls'))!;
      var fileStarted = false;
      final next = slots.acquire('mp4').then((lease) {
        fileStarted = lease != null;
        return lease;
      });
      await Future<void>.delayed(Duration.zero);
      expect(fileStarted, isFalse);
      hls.release();
      (await next)!.release();
      expect(fileStarted, isTrue);
    },
  );
  test(
    'raising the limit admits waiters and lowering waits for active work',
    () async {
      final slots = TransferSlots(1);
      final first = (await slots.acquire('first'))!;
      final secondFuture = slots.acquire('second');
      slots.limit = 2;
      final second = (await secondFuture)!;
      slots.limit = 1;
      var thirdStarted = false;
      final thirdFuture = slots.acquire('third').then((lease) {
        thirdStarted = lease != null;
        return lease;
      });
      first.release();
      await Future<void>.delayed(Duration.zero);
      expect(thirdStarted, isFalse);
      second.release();
      (await thirdFuture)!.release();
    },
  );
  test('canceling queued work prevents it from acquiring a slot', () async {
    final slots = TransferSlots(1);
    final first = (await slots.acquire('first'))!;
    final canceled = slots.acquire('cancel');
    slots.cancelPending('cancel');
    expect(await canceled, isNull);
    first.release();
    (await slots.acquire('next'))!.release();
  });
  test(
    'old retry completion cannot release a newer lease with the same id',
    () async {
      final slots = TransferSlots(1);
      final old = (await slots.acquire('episode'))!;
      old.release();
      final current = (await slots.acquire('episode'))!;
      old.release();
      var otherStarted = false;
      final other = slots.acquire('other').then((lease) {
        otherStarted = lease != null;
        return lease;
      });
      await Future<void>.delayed(Duration.zero);
      expect(otherStarted, isFalse);
      current.release();
      (await other)!.release();
    },
  );
  test(
    'duplicate acquisition and closed waiting jobs cannot start twice',
    () async {
      final slots = TransferSlots(1);
      final first = (await slots.acquire('first'))!;
      expect(await slots.acquire('first'), isNull);
      final waiting = slots.acquire('waiting');
      expect(await slots.acquire('waiting'), isNull);
      slots.close();
      expect(await waiting, isNull);
      expect(await slots.acquire('new'), isNull);
      first.release();
    },
  );
}
