import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/download_manager.dart';
import 'package:watch_app/core/download/download_record.dart';
import 'package:watch_app/features/downloads/downloads_screen.dart';

/// Records real rendered menu dispatch without opening stores or source engines.
class _Manager extends ChangeNotifier implements DownloadManager {
  final actions = <String>[];
  @override
  Future<void> pause(DownloadRecord rec) async =>
      actions.add('pause:${rec.id}');
  @override
  Future<void> resume(DownloadRecord rec) async =>
      actions.add('resume:${rec.id}');
  @override
  Future<void> retry(DownloadRecord rec) async =>
      actions.add('retry:${rec.id}');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Future<_Manager> open(
    WidgetTester tester,
    DownloadStatus status, {
    bool pending = true,
    bool waiting = false,
  }) async {
    final manager = _Manager();
    final record = DownloadRecord(
      id: 'local',
      sourceId: 'fixture',
      showId: 'show',
      showTitle: 'Fixture',
      showUrl: '/show',
      episodeId: 'episode',
      episodeUrl: '/episode',
      episodeTitle: 'Episode',
      category: 'dub',
      quality: 'best',
      createdAt: 1,
      status: status,
      pendingAudioFinalization: pending,
      autoResumePending: waiting,
      retryAt: waiting ? 2000000000000 : null,
      error: waiting ? 'Source is rate limiting downloads (429). Waiting to retry.' : null,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DownloadTile(record: record, manager: manager),
        ),
      ),
    );
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    return manager;
  }

  for (final status in [DownloadStatus.finalizing, DownloadStatus.queued]) {
    testWidgets('Windows $status local worker exposes functional Pause', (
      tester,
    ) async {
      final manager = await open(tester, status);
      expect(find.text('Pause'), findsOneWidget);
      await tester.tap(find.text('Pause'));
      await tester.pump();
      expect(manager.actions, ['pause:local']);
    }, variant: TargetPlatformVariant({TargetPlatform.windows}));
  }

  testWidgets('failed Windows local media exposes Resume and explicit Retry', (
    tester,
  ) async {
    final manager = await open(tester, DownloadStatus.failed);
    expect(find.text('Resume'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Resume'));
    await tester.pump();
    expect(manager.actions, ['resume:local']);
  }, variant: TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets('ordinary queued transfer does not gain local-worker Pause', (
    tester,
  ) async {
    await open(tester, DownloadStatus.queued, pending: false);
    expect(find.text('Pause'), findsNothing);
  }, variant: TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets('Windows cooldown row exposes Pause and static waiting indicator', (tester) async {
    final manager = await open(tester, DownloadStatus.queued, pending: false, waiting: true);
    expect(find.byIcon(Icons.schedule_rounded), findsOneWidget);
    expect(find.textContaining('Waiting to retry'), findsOneWidget);
    expect(find.text('Pause'), findsOneWidget);
    await tester.tap(find.text('Pause'));
    await tester.pump();
    expect(manager.actions, ['pause:local']);
  }, variant: TargetPlatformVariant({TargetPlatform.windows}));

  for (final status in [DownloadStatus.finalizing, DownloadStatus.failed]) {
    testWidgets('Android $status has no Windows-only local controls', (
      tester,
    ) async {
      await open(tester, status);
      expect(find.text('Pause'), findsNothing);
      expect(find.text('Resume'), findsNothing);
    }, variant: TargetPlatformVariant({TargetPlatform.android}));
  }
}
