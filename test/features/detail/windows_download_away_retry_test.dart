import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/download_source_search.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/features/detail/desktop_batch_download_dialog.dart';

// Windows "Download episodes" dialog: a source search that comes up empty
// while the window is minimized (or behind another window) is asked once
// more when the window comes back, instead of leaving "No source had this
// episode" up. Nothing is asked while the window stays away, the retry runs
// at most once, and a failure with the window in front is left alone.

const eps = [
  Episode(id: 'e1', title: 'Episode 1', url: 'zm://anime/mal:1/ep/1', number: 1, season: 1),
  Episode(id: 'e2', title: 'Episode 2', url: 'zm://anime/mal:1/ep/2', number: 2, season: 1),
];
const link = VideoSource(url: 'https://anikoto.fixture/1080.mp4', label: 'HD-1',
    quality: '1080p', kind: AudioKind.sub);

void main() {
  late int asks;
  // Which asks (1-based) find links; every other ask comes up empty.
  late Set<int> findsOn;

  setUp(() {
    asks = 0;
    findsOn = {};
  });

  /// Anikoto answers after 2 s: links on the asks in [findsOn], else nothing.
  Stream<List<DownloadSourceStatus>> search() {
    final n = ++asks;
    return searchDownloadSources(
      candidates: const [
        DownloadSourceCandidate(id: 'ani:koto', name: 'Anikoto', budget: Duration(seconds: 5)),
        DownloadSourceCandidate(id: 'cs:backup', name: 'Backup', budget: Duration(seconds: 5)),
      ],
      attempt: (id) => Future.delayed(const Duration(seconds: 2), () =>
          id == 'ani:koto' && findsOn.contains(n)
              ? const DownloadSourceHit(streams: [link])
              : null),
      wallClock: const Duration(seconds: 10),
    );
  }

  Future<void> open(WidgetTester tester, {TargetPlatform platform = TargetPlatform.windows}) async {
    debugDefaultTargetPlatformOverride = platform;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => Scaffold(
      body: TextButton(onPressed: () async {
        await showDialog<DesktopBatchDownloadChoice>(context: context,
          builder: (_) => DesktopBatchDownloadDialog(title: 'Re:ZERO', episodesBySeason: const {1: eps},
            initialSeason: 1, initialCategory: 'sub', availableCategories: const ['sub'],
            resolve: (_) async => throw StateError('legacy path unused'),
            resolveEpisodes: (_) async => {1: eps},
            searchSources: (_, _) => search()));
      }, child: const Text('Open'))))));
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump();
  }

  /// Moves the window to [state] one real step at a time (resumed, inactive,
  /// hidden, paused), the way the engine reports a minimize or a restore.
  void lifecycle(WidgetTester tester, AppLifecycleState state) {
    const order = [
      AppLifecycleState.resumed,
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ];
    var at = order.indexOf(tester.binding.lifecycleState ?? AppLifecycleState.resumed);
    final to = order.indexOf(state);
    while (at != to) {
      at += at < to ? 1 : -1;
      tester.binding.handleAppLifecycleStateChanged(order[at]);
    }
  }

  Future<void> close(WidgetTester tester) async {
    lifecycle(tester, AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 11));
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
  }

  testWidgets('minimized while finding sources: asked again once it is back',
      (tester) async {
    findsOn = {2};
    await open(tester);
    expect(asks, 1);
    // Minimized part way through the search.
    await tester.pump(const Duration(milliseconds: 500));
    lifecycle(tester, AppLifecycleState.inactive);
    lifecycle(tester, AppLifecycleState.hidden);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('No source had this episode'), findsOneWidget);
    // Nothing runs while it stays minimized.
    await tester.pump(const Duration(seconds: 30));
    expect(asks, 1);
    // Restored: the search runs again by itself and finds the links.
    lifecycle(tester, AppLifecycleState.inactive);
    lifecycle(tester, AppLifecycleState.resumed);
    await tester.pump();
    expect(asks, 2);
    expect(find.text('Trying Anikoto and 1 more...'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('No source had this episode'), findsNothing);
    expect(find.byKey(const ValueKey('batch-server')), findsOneWidget);
    await close(tester);
  });

  testWidgets('back in front before the search ended: retried at once',
      (tester) async {
    findsOn = {2};
    await open(tester);
    await tester.pump(const Duration(milliseconds: 500));
    lifecycle(tester, AppLifecycleState.inactive);
    await tester.pump(const Duration(milliseconds: 500));
    lifecycle(tester, AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 2));
    expect(asks, 2);
    await tester.pump(const Duration(seconds: 3));
    expect(find.byKey(const ValueKey('batch-server')), findsOneWidget);
    await close(tester);
  });

  testWidgets('the quiet retry runs once; Retry stays for the user',
      (tester) async {
    await open(tester);
    await tester.pump(const Duration(milliseconds: 500));
    lifecycle(tester, AppLifecycleState.hidden);
    await tester.pump(const Duration(seconds: 3));
    lifecycle(tester, AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 3));
    expect(asks, 2);
    expect(find.text('No source had this episode'), findsOneWidget);
    // Minimizing and restoring again does not start another one.
    lifecycle(tester, AppLifecycleState.hidden);
    lifecycle(tester, AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 3));
    expect(asks, 2);
    expect(find.byKey(const ValueKey('batch-sources-retry')), findsOneWidget);
    await close(tester);
  });

  testWidgets('a failure with the window in front is not retried', (tester) async {
    await open(tester);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('No source had this episode'), findsOneWidget);
    lifecycle(tester, AppLifecycleState.hidden);
    lifecycle(tester, AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 3));
    expect(asks, 1);
    await close(tester);
  });

  testWidgets('phone/TV platforms: no lifecycle retry', (tester) async {
    await open(tester, platform: TargetPlatform.android);
    await tester.pump(const Duration(milliseconds: 500));
    lifecycle(tester, AppLifecycleState.hidden);
    await tester.pump(const Duration(seconds: 3));
    lifecycle(tester, AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 3));
    expect(asks, 1);
    await close(tester);
  });

  test('every asked source is reported once as it settles', () async {
    final seen = <String, DownloadSourcePhase>{};
    final hang = Completer<DownloadSourceHit?>();
    await searchDownloadSources(
      candidates: const [
        DownloadSourceCandidate(id: 'a', name: 'A', budget: Duration(seconds: 5)),
        DownloadSourceCandidate(id: 'b', name: 'B', budget: Duration(milliseconds: 20)),
        DownloadSourceCandidate(id: 'c', name: 'C', budget: Duration(seconds: 5)),
        DownloadSourceCandidate(id: 'd', name: 'D', budget: Duration(seconds: 5),
            skipReason: 'Cloudflare check needed'),
      ],
      attempt: (id) => switch (id) {
        'a' => Future.value(const DownloadSourceHit(streams: [link])),
        'b' => hang.future,
        _ => Future.error(StateError('down')),
      },
      onSettled: (row, elapsed) {
        expect(seen.containsKey(row.sourceId), isFalse);
        expect(elapsed.isNegative, isFalse);
        seen[row.sourceId] = row.phase;
      },
    ).drain<void>();
    expect(seen, {
      'a': DownloadSourcePhase.found,
      'b': DownloadSourcePhase.timedOut,
      'c': DownloadSourcePhase.failed,
    });
  });
}
