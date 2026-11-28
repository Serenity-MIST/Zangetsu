import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/dash_manifest.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/features/detail/desktop_batch_download_dialog.dart';

// Two episodes of a MovieBox-style show.
const _eps = [
  Episode(id: 'e1', title: 'Episode 1', url: '/e1', number: 1),
  Episode(id: 'e2', title: 'Episode 2', url: '/e2', number: 2),
];
// The DASH link is labelled 1080p only; its manifest holds three heights.
const _dash = VideoSource(
  url: 'https://cdn.fixture/e1/master.mpd',
  label: 'MovieBox (Original) DASH',
  quality: '1080p',
);
const _mp4Hd = VideoSource(
  url: 'https://cdn.fixture/e1/1080.mp4',
  label: 'MovieBox (Original) MP4',
  quality: '1080p',
);
const _mp4Sd = VideoSource(
  url: 'https://cdn.fixture/e1/480.mp4',
  label: 'MovieBox (Original) MP4',
  quality: '480p',
);

/// What the player's Quality sheet shows for this stream: 1080/720/480.
const _manifest = DashManifest(
  videos: [
    DashRepresentation(id: 'v1080', isVideo: true, height: 1080),
    DashRepresentation(id: 'v720', isVideo: true, height: 720),
    DashRepresentation(id: 'v480', isVideo: true, height: 480),
  ],
  audios: [],
);

void main() {
  DesktopBatchDownloadChoice? result;
  late int manifestReads;

  /// Opens the dialog; [read] stands in for the manifest fetch.
  Future<void> open(
    WidgetTester tester,
    Future<DashManifest?> Function() read,
  ) async {
    result = null;
    manifestReads = 0;
    tester.view.physicalSize = const Size(1400, 900);
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
                    episodesBySeason: const {1: _eps},
                    initialSeason: 1,
                    initialCategory: 'sub',
                    availableCategories: const ['sub'],
                    resolve: (_) async => const [_dash, _mp4Hd, _mp4Sd],
                    resolveEpisodes: (_) async => const {1: _eps},
                    estimateSize: (_, _, _) async => null,
                    readFreeBytes: () async => null,
                    readDashManifest: (source) {
                      expect(source.url, _dash.url);
                      manifestReads++;
                      return read();
                    },
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
  }

  /// Picks the server whose menu row reads [label].
  Future<void> pickServer(WidgetTester tester, String label) async {
    await tester.tap(find.byKey(const ValueKey('batch-server')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  Finder qualityPill() => find.byKey(const ValueKey('batch-quality'));

  /// Labels the Quality menu offers right now (opens, reads, closes it).
  Future<List<String>> qualityOptions(WidgetTester tester) async {
    await tester.tap(qualityPill());
    await tester.pumpAndSettle();
    final labels = tester
        .widgetList<PopupMenuItem<String>>(find.byType(PopupMenuItem<String>))
        .map((item) => item.value!)
        .toList();
    await tester.tapAt(const Offset(5, 5)); // closes the menu
    await tester.pumpAndSettle();
    return labels;
  }

  testWidgets('a DASH server shows Loading, then every manifest height', (
    tester,
  ) async {
    final manifest = Completer<DashManifest?>();
    await open(tester, () => manifest.future);
    await pickServer(tester, 'MovieBox (Original) DASH');

    // While the manifest is read the pill says so and cannot be opened.
    expect(
      find.descendant(of: qualityPill(), matching: find.text('Loading…')),
      findsOneWidget,
    );
    final pill = tester.widget<PopupMenuButton<String>>(
      find.descendant(
        of: qualityPill(),
        matching: find.byType(PopupMenuButton<String>),
      ),
    );
    expect(pill.enabled, isFalse);
    expect(manifestReads, greaterThan(0));

    manifest.complete(_manifest);
    await tester.pumpAndSettle();
    // The same list as the player: not just the link's own 1080p.
    expect(await qualityOptions(tester), ['best', '1080p', '720p', '480p']);

    await tester.tap(qualityPill());
    await tester.pumpAndSettle();
    await tester.tap(find.text('720p').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('batch-download')));
    await tester.pumpAndSettle();
    // The picked height goes to the manager for every episode.
    expect(result?.quality, '720p');
    expect(result?.server, _dash);
    expect(result?.episodes.map((e) => e.id), ['e1', 'e2']);
  });

  testWidgets('an unreadable manifest keeps the link\'s own quality', (
    tester,
  ) async {
    await open(tester, () async => null);
    await pickServer(tester, 'MovieBox (Original) DASH');
    expect(await qualityOptions(tester), ['best', '1080p']);
  });

  testWidgets('MP4 and Auto keep their link-based quality lists', (
    tester,
  ) async {
    await open(tester, () async => _manifest);
    await pickServer(tester, 'MovieBox (Original) MP4');
    final readsAfterMp4 = manifestReads;
    expect(await qualityOptions(tester), ['best', '1080p', '480p']);

    await pickServer(tester, 'Auto · best available');
    // Auto lists every link's height (DASH label included), no manifest.
    expect(await qualityOptions(tester), ['best', '1080p', '480p']);
    expect(manifestReads, readsAfterMp4);
  });
}
