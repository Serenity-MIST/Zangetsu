// The Windows download queue panel (dl-5 / dl-6 / dl-7).
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/chapter_download.dart';
import 'package:watch_app/core/download/download_live_stats.dart';
import 'package:watch_app/core/download/download_manager.dart';
import 'package:watch_app/core/download/download_record.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/features/downloads/desktop_active_downloads_panel.dart';

/// Only what the panel reads; records the bulk / row actions it triggers.
class _FakeManager extends ChangeNotifier implements DownloadManager {
  _FakeManager(this.items);
  List<DownloadRecord> items;
  final calls = <String>[];
  final progress = <String, ValueNotifier<double>>{};

  @override
  List<DownloadRecord> get queueItems => items;
  @override
  ValueListenable<double> progressListenable(String id) =>
      progress.putIfAbsent(id, () => ValueNotifier(0));
  @override
  DownloadLiveStats? liveStatsOf(String id) => null;
  @override
  double? speedOf(String id) => id == 'run' ? 2500000 : null;
  @override
  Duration? timeLeftOf(String id) =>
      id == 'run' ? const Duration(minutes: 3) : null;
  @override
  bool canMoveToFront(DownloadRecord r) => r.id == 'wait';
  @override
  Future<int> pauseAll() async {
    calls.add('pauseAll');
    return 0;
  }

  @override
  Future<int> resumeAll() async {
    calls.add('resumeAll');
    return 0;
  }

  @override
  Future<int> retryFailed() async {
    calls.add('retryFailed');
    return 0;
  }

  @override
  Future<void> moveToFront(DownloadRecord r) async => calls.add('next:${r.id}');
  @override
  Future<void> pause(DownloadRecord r) async => calls.add('pause:${r.id}');
  @override
  Future<void> resume(DownloadRecord r) async => calls.add('resume:${r.id}');
  @override
  Future<void> retry(DownloadRecord r) async => calls.add('retry:${r.id}');
  @override
  Future<void> delete(DownloadRecord r) async => calls.add('delete:${r.id}');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

DownloadRecord _record(String id, DownloadStatus status, {double? episode}) =>
    DownloadRecord(
      id: id,
      sourceId: 'src',
      showId: 'show',
      showTitle: 'Show',
      showUrl: '/show',
      episodeId: id,
      episodeUrl: '/$id',
      episodeNumber: episode,
      episodeTitle: id,
      category: 'sub',
      quality: 'best',
      status: status,
      error: status == DownloadStatus.failed ? 'Source returned 404' : null,
      createdAt: 1,
    );

Future<void> _pump(WidgetTester tester, _FakeManager manager) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DesktopActiveDownloadsPanel(manager: manager)),
      ),
    );

void main() {
  testWidgets('renders nothing when the queue is empty', (tester) async {
    await _pump(tester, _FakeManager([]));
    expect(find.byKey(const ValueKey('desktop-active-downloads')), findsNothing);
  });

  testWidgets('lists queue rows with speed, time left and bulk actions',
      (tester) async {
    final manager = _FakeManager([
      _record('run', DownloadStatus.downloading, episode: 3),
      _record('wait', DownloadStatus.queued, episode: 4),
      _record('held', DownloadStatus.paused),
      _record('bad', DownloadStatus.failed),
    ]);
    await _pump(tester, manager);
    manager.progress['run']!.value = .42;
    await tester.pump();

    expect(find.text('Show · E3'), findsOneWidget);
    expect(find.textContaining('42%'), findsOneWidget);
    expect(find.textContaining('2.5 MB/s'), findsWidgets);
    expect(find.textContaining('3 min left'), findsOneWidget);
    expect(find.text('Source returned 404'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('queue-pause-all')));
    await tester.tap(find.byKey(const ValueKey('queue-resume-all')));
    await tester.tap(find.byKey(const ValueKey('queue-retry-failed')));
    // 'Download next' only shows on the item that can move.
    await tester.tap(find.byTooltip('Download next'));
    expect(manager.calls, [
      'pauseAll',
      'resumeAll',
      'retryFailed',
      'next:wait',
    ]);
  });

  testWidgets('progress ticks repaint the row without a manager notify',
      (tester) async {
    final manager = _FakeManager([
      _record('run', DownloadStatus.downloading, episode: 1),
    ]);
    await _pump(tester, manager);
    manager.progress['run']!.value = .1;
    await tester.pump();
    expect(find.textContaining('10%'), findsOneWidget);
    manager.progress['run']!.value = .75;
    await tester.pump();
    expect(find.textContaining('75%'), findsOneWidget);
  });

  testWidgets('an unsupported episode shows its reason and Delete, no Retry',
      (tester) async {
    final manager = _FakeManager([
      DownloadRecord.fromMap({
        ..._record('bad', DownloadStatus.unsupported, episode: 8).toMap(),
        'error': 'No downloadable stream for the selected dub audio',
      }),
    ]);
    await _pump(tester, manager);
    expect(find.text('Show · E8'), findsOneWidget);
    expect(
      find.text('No downloadable stream for the selected dub audio'),
      findsOneWidget,
    );
    // Counts as failed in the header, but there is nothing to retry.
    expect(find.text('1 failed'), findsOneWidget);
    expect(find.byTooltip('Retry'), findsNothing);
    expect(find.byKey(const ValueKey('queue-retry-failed')), findsNothing);
    await tester.tap(find.byTooltip('Delete'));
    expect(manager.calls, ['delete:bad']);
  });

  testWidgets('a failed row retries; one with its file can also resume',
      (tester) async {
    final manager = _FakeManager([
      DownloadRecord.fromMap({
        ..._record('bad', DownloadStatus.failed).toMap(),
        'pendingAudioFinalization': true,
      }),
    ]);
    await _pump(tester, manager);
    await tester.tap(find.byTooltip('Retry'));
    await tester.tap(find.byTooltip('Resume'));
    await tester.tap(find.byTooltip('Delete'));
    expect(manager.calls, ['retry:bad', 'resume:bad', 'delete:bad']);
  });

  testWidgets('deleting a failed row that owns a saved file asks first',
      (tester) async {
    final manager = _FakeManager([
      // The re-download was unsupported; the older copy is still on disk.
      DownloadRecord.fromMap({
        ..._record('old', DownloadStatus.unsupported, episode: 3).toMap(),
        'supersededPath': r'D:\Videos\Show\old.mp4',
      }),
    ]);
    await _pump(tester, manager);
    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete download?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(manager.calls, isEmpty);
    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(manager.calls, ['delete:old']);
  });

  testWidgets('failed chapters are listed with Retry and Delete',
      (tester) async {
    const chapter = ChapterDownload(
      id: 'm1',
      sourceId: 'src',
      showId: 'manga',
      showTitle: 'Manga',
      chapterId: 'm1',
      chapterUrl: '/m1',
      chapterTitle: 'Chapter 7',
      mode: ContentMode.manga,
      status: ChapterDownloadStatus.failed,
      error: 'Source is gone',
    );
    final calls = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          // No video downloads at all: the panel still shows.
          body: DesktopActiveDownloadsPanel(
            manager: _FakeManager([]),
            failedChapters: const [chapter],
            onRetryChapter: (c) => calls.add('retry:${c.id}'),
            onRetryFailedChapters: () => calls.add('retryAll'),
            onDeleteChapter: (c) => calls.add('delete:${c.id}'),
          ),
        ),
      ),
    );
    expect(find.text('Manga · Chapter 7'), findsOneWidget);
    expect(find.text('Source is gone'), findsOneWidget);
    expect(find.text('1 failed'), findsOneWidget);
    await tester.tap(find.byTooltip('Retry'));
    await tester.tap(find.byTooltip('Delete'));
    await tester.tap(find.byKey(const ValueKey('queue-retry-failed')));
    expect(calls, ['retry:m1', 'delete:m1', 'retryAll']);
  });

  testWidgets('clicking the header collapses and expands the rows',
      (tester) async {
    final manager = _FakeManager([
      _record('run', DownloadStatus.downloading, episode: 1),
      _record('wait', DownloadStatus.queued, episode: 2),
    ]);
    await _pump(tester, manager);
    expect(find.text('Show · E2'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('queue-toggle')));
    await tester.pump();
    // Folded: rows hidden, the header and its bulk actions stay.
    expect(find.text('Show · E2'), findsNothing);
    expect(find.byKey(const ValueKey('queue-pause-all')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('queue-toggle')));
    await tester.pump();
    expect(find.text('Show · E2'), findsOneWidget);
  });
}
