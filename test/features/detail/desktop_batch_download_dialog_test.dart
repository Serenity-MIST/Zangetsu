import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/download_source_search.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/ui/progressive_artwork.dart';
import 'package:watch_app/features/detail/desktop_batch_download_dialog.dart';

// Fake season of four sub episodes; E3 is already downloaded.
const subEps = [
  Episode(id: 's1', title: 'Episode 1', url: '/s1', number: 1),
  Episode(id: 's2', title: 'Episode 2', url: '/s2', number: 2),
  Episode(id: 's3', title: 'Episode 3', url: '/s3', number: 3),
  Episode(id: 's4', title: 'Episode 4', url: '/s4', number: 4),
];
const dubEps = [
  Episode(id: 'd1', title: 'Episode 1', url: '/d1', number: 1),
  Episode(id: 'd2', title: 'Episode 2', url: '/d2', number: 2),
];
const hd = VideoSource(
  url: 'https://alpha.fixture/1080.mp4',
  label: 'Alpha',
  quality: '1080p',
);
const sd = VideoSource(
  url: 'https://alpha.fixture/720.mp4',
  label: 'Alpha',
  quality: '720p',
);
const beta = VideoSource(
  url: 'https://other.fixture/720.mp4',
  label: 'Other',
  quality: '720p',
);

void main() {
  late List<String> resolvedCategories;
  DesktopBatchDownloadChoice? result;
  var closed = false;

  /// Pumps the dialog on a desktop-sized surface with injected fakes.
  Future<void> open(
    WidgetTester tester, {
    Size size = const Size(1400, 900),
    bool failFirstDub = false,
    String coverUrl = '',
    String? wideCoverUrl,
  }) async {
    var dubFailures = failFirstDub ? 1 : 0;
    resolvedCategories = [];
    result = null;
    closed = false;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showDialog<DesktopBatchDownloadChoice>(
                  context: context,
                  builder: (_) => DesktopBatchDownloadDialog(
                    title: 'Fixture Show',
                    coverUrl: coverUrl,
                    wideCoverUrl: wideCoverUrl,
                    episodesBySeason: const {1: subEps},
                    initialSeason: 1,
                    initialCategory: 'sub',
                    availableCategories: const ['sub', 'dub'],
                    resolve: (_) async => [sd, beta, hd],
                    resolveEpisodes: (cat) async {
                      resolvedCategories.add(cat);
                      // Simulated offline failure for the first dub lookup.
                      if (cat == 'dub' && dubFailures-- > 0) {
                        throw StateError('offline');
                      }
                      return {1: cat == 'dub' ? dubEps : subEps};
                    },
                    downloadedIds: (cat, eps) async => {if (cat == 'sub') 's3'},
                    estimateSize: (_, _, _) async => null,
                    readFreeBytes: () async => null,
                  ),
                );
                closed = true;
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  Finder tile(String id) => find.byKey(ValueKey('batch-ep-$id'));
  FilledButton downloadButton(WidgetTester tester) =>
      tester.widget<FilledButton>(find.byKey(const ValueKey('batch-download')));

  testWidgets('season preselected minus downloaded; toggle, none, select all', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('Downloaded'), findsOneWidget);
    expect(find.text('Download 3 episodes'), findsOneWidget);

    await tester.tap(find.text('None'));
    await tester.pump();
    expect(find.text('Select episodes'), findsOneWidget);
    expect(downloadButton(tester).onPressed, isNull);

    await tester.tap(tile('s1'));
    await tester.tap(tile('s2'));
    await tester.pump();
    expect(find.text('Download 2 episodes'), findsOneWidget);

    // Downloaded tile cannot be selected.
    await tester.tap(tile('s3'));
    await tester.pump();
    expect(find.text('Download 2 episodes'), findsOneWidget);

    await tester.tap(tile('s2'));
    await tester.pump();
    expect(find.text('Download 1 episode'), findsOneWidget);

    await tester.tap(find.text('Select all'));
    await tester.pump();
    expect(find.text('Download 3 episodes'), findsOneWidget);
  });

  testWidgets('shift-click selects a range and range input replaces picks', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.text('None'));
    await tester.pump();
    await tester.tap(tile('s1'));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(tile('s4'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    // E1..E4 minus the downloaded E3.
    expect(find.text('Download 3 episodes'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('batch-range-from')), '2');
    await tester.enterText(find.byKey(const ValueKey('batch-range-to')), '2');
    await tester.tap(find.byKey(const ValueKey('batch-range-apply')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('batch-download')));
    await tester.pumpAndSettle();
    expect(result?.episodes.map((e) => e.id), ['s2']);
  });

  testWidgets(
    'sub/dub switch re-resolves episodes and returns the dub record',
    (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('batch-category-dub')));
      await tester.pumpAndSettle();
      expect(resolvedCategories, ['dub']);
      expect(find.text('Downloaded'), findsNothing);
      expect(find.text('Download 2 episodes'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('batch-download')));
      await tester.pumpAndSettle();
      expect(result?.category, 'dub');
      expect(result?.episodes.map((e) => e.id), ['d1', 'd2']);
    },
  );

  testWidgets('failed sub/dub switch shows retry that recovers', (tester) async {
    await open(tester, failFirstDub: true);
    await tester.tap(find.byKey(const ValueKey('batch-category-dub')));
    await tester.pumpAndSettle();
    final retry = find.byKey(const ValueKey('batch-episodes-retry'));
    expect(retry, findsOneWidget);
    expect(downloadButton(tester).onPressed, isNull);

    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(resolvedCategories, ['dub', 'dub']);
    expect(find.text('Download 2 episodes'), findsOneWidget);
  });

  testWidgets('download returns picked quality and server', (tester) async {
    await open(tester);
    // Defaults: best-ranked source's server and quality.
    expect(find.text('1080p'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('batch-server')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Other').last);
    await tester.pumpAndSettle();
    expect(find.text('720p'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('batch-download')));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(result?.category, 'sub');
    expect(result?.quality, '720p');
    expect(result?.server?.label, 'Other');
    expect(result?.episodes.map((e) => e.id), ['s1', 's2', 's4']);
  });

  // dlsource: Anikoto links carry the server name in `quality`, no label, one
  // CDN host and both SUB and DUB. The Server menu used to collapse them into
  // one host entry and drop DUB; now it lists each server per kind and a DUB
  // pick makes the whole batch dub.
  testWidgets('server menu lists SUB/DUB servers; a DUB pick sets the batch cut', (
    tester,
  ) async {
    const subHd = VideoSource(url: 'https://cdn.fixture/s-hd1.m3u8', quality: 'HD - 1 - 1080p', kind: AudioKind.sub);
    const subVs = VideoSource(url: 'https://cdn.fixture/s-vs2.m3u8', quality: 'Vidstream - 2 - 1080p', kind: AudioKind.sub);
    const dubHd = VideoSource(url: 'https://cdn.fixture/d-hd1.m3u8', quality: 'HD - 1 - 1080p', kind: AudioKind.dub);
    const dubVs = VideoSource(url: 'https://cdn.fixture/d-vs2.m3u8', quality: 'Vidstream - 2 - 1080p', kind: AudioKind.dub);
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    DesktopBatchDownloadChoice? picked;
    final marksAsked = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                picked = await showDialog<DesktopBatchDownloadChoice>(
                  context: context,
                  builder: (_) => DesktopBatchDownloadDialog(
                    title: 'Fixture Show',
                    episodesBySeason: const {1: subEps},
                    initialSeason: 1,
                    initialCategory: 'sub',
                    // Catalogue details without a dub count: no Sub/Dub toggle.
                    availableCategories: const ['sub'],
                    resolve: (_) async => const [subHd, subVs, dubHd, dubVs],
                    resolveEpisodes: (_) async => const {1: subEps},
                    downloadedIds: (cat, eps) async {
                      marksAsked.add(cat);
                      return const {};
                    },
                    estimateSize: (_, _, _) async => null,
                    readFreeBytes: () async => null,
                  ),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    // Default stays on the page's SUB cut.
    expect(find.text('SUB • HD - 1'), findsOneWidget);
    expect(find.text('1080p'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('batch-server')));
    await tester.pumpAndSettle();
    for (final label in ['SUB • Vidstream - 2', 'DUB • HD - 1', 'DUB • Vidstream - 2']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    await tester.tap(find.text('DUB • HD - 1'));
    await tester.pumpAndSettle();
    // Already-downloaded marks are re-read for the dub cut.
    expect(marksAsked, ['sub', 'dub']);

    await tester.tap(find.byKey(const ValueKey('batch-download')));
    await tester.pumpAndSettle();
    expect(picked?.category, 'dub');
    expect(picked?.server, dubHd);
    expect(picked?.quality, '1080p');
  });

  // Episodes here have no still: the show's wide picture is used before
  // the portrait poster, and a poster on its own is shown whole.
  testWidgets('tiles without a still use the wide picture, then the whole '
      'poster', (tester) async {
    await open(
      tester,
      coverUrl: 'https://cdn.fixture/poster.jpg',
      wideCoverUrl: 'https://cdn.fixture/wide.jpg',
    );
    final wide = find.descendant(
      of: tile('s1'),
      matching: find.byWidgetPredicate(
        (w) => w is CachedNetworkImage && w.imageUrl.contains('wide.jpg'),
      ),
    );
    expect(wide, findsOneWidget);
    expect(tester.widget<CachedNetworkImage>(wide).httpHeaders, isNull);
    expect(
      find.descendant(
        of: tile('s1'),
        matching: find.byType(ProgressiveArtwork),
      ),
      findsNothing,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    await open(tester, coverUrl: 'https://cdn.fixture/poster.jpg');
    expect(
      find.descendant(
        of: tile('s1'),
        matching: find.byType(ProgressiveArtwork),
      ),
      findsOneWidget,
    );
  });

  testWidgets('Escape cancels without a result', (tester) async {
    await open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(result, isNull);
  });

  testWidgets('fits a small 860px desktop window without overflow', (
    tester,
  ) async {
    await open(tester, size: const Size(860, 640));
    expect(tester.takeException(), isNull);
    expect(find.text('Download 3 episodes'), findsOneWidget);
  });

  // R2 regression: 10 selected episodes, two found sources and long server
  // labels used to starve the footer summary to 0px wide (one glyph per
  // line) and push the episode list to 0 height at the 940px dialog cap.
  for (final size in const [Size(1366, 720), Size(1920, 1080)]) {
    testWidgets('footer keeps summary and rows with many controls at $size', (
      tester,
    ) async {
      final eps = [
        for (var i = 1; i <= 10; i++)
          Episode(
            id: 'e$i',
            title: 'Episode $i',
            url: '/e$i',
            number: i.toDouble(),
          ),
      ];
      const streams = [
        VideoSource(
          url: 'https://a.fixture/1080.m3u8',
          label: 'HD-1 Very Long Server Name Megacloud',
          quality: '1080p',
        ),
        VideoSource(
          url: 'https://b.fixture/720.m3u8',
          label: 'HD-2 Another Long Server Label',
          quality: '720p',
        ),
      ];
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => DesktopBatchDownloadDialog(
                    title: 'Fixture Show Season 2',
                    episodesBySeason: {1: eps},
                    initialSeason: 1,
                    initialCategory: 'sub',
                    availableCategories: const ['sub', 'dub'],
                    resolve: (_) async => streams,
                    resolveEpisodes: (_) async => {1: eps},
                    estimateSize: (_, _, _) async =>
                        (bytes: 1300 * 1024 * 1024, solid: true),
                    readFreeBytes: () async => 250000000000,
                    // Two sources answered, so the source pill shows too.
                    searchSources: (_, _) => Stream.value(const [
                      DownloadSourceStatus(
                        sourceId: 'alpha',
                        name: 'Alpha Source',
                        phase: DownloadSourcePhase.found,
                        streams: streams,
                      ),
                      DownloadSourceStatus(
                        sourceId: 'other',
                        name: 'Other Mirror Source',
                        phase: DownloadSourcePhase.found,
                        streams: streams,
                      ),
                    ]),
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // Checks the layout stayed sane: no overflow, readable summary,
      // episode rows still on screen and Download reachable.
      void expectHealthy() {
        expect(tester.takeException(), isNull);
        final count = find.byKey(const ValueKey('batch-count'));
        expect(tester.getSize(count).width, greaterThan(150));
        expect(tile('e1').hitTestable(), findsOneWidget);
        expect(
          find.byKey(const ValueKey('batch-download')).hitTestable(),
          findsOneWidget,
        );
      }

      expect(find.text('Download 10 episodes'), findsOneWidget);
      expect(find.byKey(const ValueKey('batch-source')), findsOneWidget);
      expectHealthy();

      // Deselecting everything must keep the same healthy layout.
      await tester.tap(find.text('None'));
      await tester.pumpAndSettle();
      expect(find.text('Select episodes'), findsOneWidget);
      expectHealthy();
    });
  }
}
