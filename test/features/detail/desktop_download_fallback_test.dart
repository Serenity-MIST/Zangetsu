import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/download_source_search.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/features/detail/desktop_batch_download_dialog.dart';
import 'package:watch_app/features/detail/desktop_single_download_dialog.dart';

// Windows download dialogs: a preferred source that hangs or fails must not
// hold the dialog; a fallback source's links are offered (tagged with their
// source) and the pick carries that source's id to the enqueue.

const ep = Episode(id: 'e1', title: 'Episode 1', url: 'zm://anime/mal:1/ep/1', number: 1, season: 1);
const eps = [
  ep,
  Episode(id: 'e2', title: 'Episode 2', url: 'zm://anime/mal:1/ep/2', number: 2, season: 1),
];
const backupLink = VideoSource(url: 'https://backup.fixture/1080.mp4', label: 'B1',
    quality: '1080p', kind: AudioKind.sub);

/// Anikoto (preferred) never answers; Backup answers with [backupLink]
/// unless [backupFails]. Budgets are short so fake time can run them out.
Stream<List<DownloadSourceStatus>> fakeSearch({bool backupFails = false,
    void Function()? onAsk}) {
  onAsk?.call();
  return searchDownloadSources(
    candidates: const [
      DownloadSourceCandidate(id: 'ani:koto', name: 'Anikoto', budget: Duration(seconds: 3)),
      DownloadSourceCandidate(id: 'cs:backup', name: 'Backup', budget: Duration(seconds: 3)),
    ],
    attempt: (id) {
      if (id == 'ani:koto') return Completer<DownloadSourceHit?>().future;
      if (backupFails) return Future.error(StateError('backup down'));
      return Future.value(const DownloadSourceHit(streams: [backupLink],
          episodeUrl: 'https://backup/ep1', showUrl: 'https://backup/show'));
    },
    wallClock: const Duration(seconds: 10),
  );
}

Future<void> openSingle(WidgetTester tester, Stream<List<DownloadSourceStatus>> Function() search,
    ValueChanged<DesktopSingleDownloadChoice?> done) async {
  await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => Scaffold(
    body: TextButton(onPressed: () async {
      done(await showDialog<DesktopSingleDownloadChoice>(context: context,
        builder: (_) => DesktopSingleDownloadDialog(episode: ep, season: 1,
          initialCategory: 'sub', availableCategories: const ['sub'],
          resolveEpisodes: (_) async => {1: [ep]},
          resolveSources: (_, _) async => throw StateError('legacy path unused'),
          searchSources: (_, _) => search(),
          previewBuilder: (_, _) => const Text('Size preview'))));
    }, child: const Text('Open'))))));
  await tester.tap(find.text('Open'));
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('single: fallback links show while the preferred source is still trying, '
      'and the pick carries the fallback source id', (tester) async {
    DesktopSingleDownloadChoice? result;
    await openSingle(tester, () => fakeSearch(), (r) => result = r);
    await tester.pump(const Duration(milliseconds: 50));
    // Anikoto is still being asked; Backup's link is already choosable.
    expect(find.text('Trying Anikoto...'), findsOneWidget);
    expect(find.text('SUB • B1 · 1080p'), findsOneWidget);
    expect(find.text('Backup'), findsOneWidget); // source header
    // Out of budget, Anikoto is reported as timed out and the search ends.
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('Anikoto · Timed out'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Download'));
    await tester.pumpAndSettle();
    expect(result?.sourceId, 'cs:backup');
    expect(result?.sourceName, 'Backup');
    expect(result?.chosen, backupLink);
    expect(result?.all, [backupLink]);
  });

  testWidgets('single: total failure says so and Retry asks again', (tester) async {
    var asks = 0;
    var fail = true;
    await openSingle(tester, () => fakeSearch(backupFails: fail, onAsk: () => asks++), (_) {});
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('No source had this episode.'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Download')).onPressed,
        isNull);
    fail = false;
    await tester.tap(find.byKey(const ValueKey('download-search-retry')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(asks, 2);
    expect(find.text('SUB • B1 · 1080p'), findsOneWidget);
    // Close and let the pending budget timers be cancelled.
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
  });

  Future<void> openBatch(WidgetTester tester, {required bool backupFails,
      required ValueChanged<DesktopBatchDownloadChoice?> done}) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => Scaffold(
      body: TextButton(onPressed: () async {
        done(await showDialog<DesktopBatchDownloadChoice>(context: context,
          builder: (_) => DesktopBatchDownloadDialog(title: 'Fixture', episodesBySeason: const {1: eps},
            initialSeason: 1, initialCategory: 'sub', availableCategories: const ['sub'],
            resolve: (_) async => throw StateError('legacy path unused'),
            resolveEpisodes: (_) async => {1: eps},
            searchSources: (_, _) => fakeSearch(backupFails: backupFails))));
      }, child: const Text('Open'))))));
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('batch: probe falls back past a hung source and enqueues with its id',
      (tester) async {
    DesktopBatchDownloadChoice? result;
    await openBatch(tester, backupFails: false, done: (r) => result = r);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Trying Anikoto...'), findsOneWidget);
    // Backup's server is already offered while Anikoto is still asked.
    expect(find.byKey(const ValueKey('batch-server')), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    expect(find.byKey(const ValueKey('batch-source-status')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('batch-download')));
    await tester.pumpAndSettle();
    expect(result?.sourceId, 'cs:backup');
    expect(result?.server, backupLink);
    expect(result?.episodes.length, 2);
  });

  testWidgets('batch: total failure ends with a clear message and Retry', (tester) async {
    await openBatch(tester, backupFails: true, done: (_) {});
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('No source had this episode'), findsOneWidget);
    expect(find.byKey(const ValueKey('batch-sources-retry')), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
  });
}
