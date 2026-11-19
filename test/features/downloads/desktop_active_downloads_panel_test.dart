// The Windows download queue panel (dl-5 / dl-6 / dl-7).
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/download_live_stats.dart';
import 'package:watch_app/core/download/download_manager.dart';
import 'package:watch_app/core/download/download_record.dart';
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
}
