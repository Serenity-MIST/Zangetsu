import 'package:background_downloader/background_downloader.dart';
import 'package:background_downloader/src/base_downloader.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

/// Exercises the real shared dispatcher without native transfers or user data.
final class _Dispatcher extends BaseDownloader {
  @override
  Future<void> removeResumeData([String? taskId]) async {}
  @override
  Future<void> removePausedTask([String? taskId]) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final typed in [true, false]) {
    test('real dispatcher surfaces HTTP429 without scheduling retry typed=$typed', () {
      fakeAsync((clock) {
        final dispatcher = _Dispatcher();
        final received = <TaskStatusUpdate>[];
        dispatcher.groupStatusCallbacks['test'] = received.add;
        final task = DownloadTask(url: 'https://fixture.test/file', group: 'test',
            updates: Updates.status, retries: 5);
        final update = TaskStatusUpdate(task, TaskStatus.failed,
            typed ? TaskHttpException('busy', 429) : null,
            null, {'retry-after': '120'}, typed ? null : 429);
        dispatcher.processStatusUpdate(update);
        clock.flushMicrotasks();
        expect(received, [same(update)]);
        expect(dispatcher.tasksWaitingToRetry, isEmpty);
        expect(task.retriesRemaining, 5);
        expect(clock.nonPeriodicTimerCount, 0);
        dispatcher.updates.close();
      });
    });
  }
  test('ordinary transport failure retains generic retry policy', () {
    fakeAsync((clock) {
      final dispatcher = _Dispatcher();
      final received = <TaskStatusUpdate>[];
      dispatcher.groupStatusCallbacks['test'] = received.add;
      final task = DownloadTask(url: 'https://fixture.test/file', group: 'test',
          updates: Updates.status, retries: 5);
      dispatcher.processStatusUpdate(TaskStatusUpdate(task, TaskStatus.failed,
          TaskException('connection reset')));
      expect(received.single.status, TaskStatus.waitingToRetry);
      expect(dispatcher.tasksWaitingToRetry, contains(task));
      expect(task.retriesRemaining, 4);
      expect(clock.nonPeriodicTimerCount, 1);
      dispatcher.tasksWaitingToRetry.clear();
      clock.elapse(const Duration(seconds: 3));
      dispatcher.updates.close();
    });
  });
}
