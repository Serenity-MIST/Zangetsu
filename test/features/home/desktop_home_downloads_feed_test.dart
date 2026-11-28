// Windows Home: download progress never redraws Home; the saved-shows shelf
// still follows real changes while it is needed (offline, empty catalogue).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/download_record.dart';
import 'package:watch_app/features/downloads/desktop_download_library.dart';
import 'package:watch_app/features/home/desktop_home_downloads_feed.dart';
import 'package:watch_app/features/home/desktop_home_page.dart';

DownloadRecord _record(
  String id, {
  DownloadStatus status = DownloadStatus.done,
  int episode = 1,
}) => DownloadRecord(
  id: id,
  showId: 'show-1',
  showTitle: 'Frieren',
  showUrl: 'https://example.test/show-1',
  sourceId: 'src',
  episodeId: 'ep-$id',
  episodeUrl: 'https://example.test/show-1/$id',
  episodeTitle: 'Episode $episode',
  episodeNumber: episode.toDouble(),
  category: 'sub',
  quality: '1080p',
  status: status,
  createdAt: episode,
);

void main() {
  late ValueNotifier<int> tick;
  late ValueNotifier<bool> offline;
  late List<DownloadRecord> records;
  late DesktopHomeDownloadsFeed feed;
  late int reads, builds;
  late List<DesktopHomeDownload> cards;
  DesktopDownloadCollection? opened;

  setUp(() {
    tick = ValueNotifier(0);
    offline = ValueNotifier(false);
    records = [_record('a')];
    reads = builds = 0;
    opened = null;
    feed = DesktopHomeDownloadsFeed(
      changes: tick,
      videos: () {
        reads++;
        return records;
      },
      chapters: () => const [],
    );
  });
  tearDown(() => feed.dispose());

  Widget home() => MaterialApp(
    home: ListenableBuilder(
      listenable: Listenable.merge([feed, offline]),
      builder: (_, _) {
        builds++;
        cards = feed.cards(
          needed: offline.value,
          reading: false,
          open: (c) => opened = c,
        );
        return Text(cards.map((c) => c.subtitle).join());
      },
    ),
  );

  testWidgets('online, progress ticks build nothing and read nothing', (
    tester,
  ) async {
    await tester.pumpWidget(home());
    for (var i = 0; i < 10; i++) {
      tick.value++;
      await tester.pump(const Duration(seconds: 1));
    }
    expect(builds, 1);
    expect(reads, 0);
    expect(cards, isEmpty);
  });

  testWidgets('going offline shows the shelf at once, and a finished episode '
      'updates its count', (tester) async {
    await tester.pumpWidget(home());
    offline.value = true;
    await tester.pump();
    expect(find.text('1 episode'), findsOneWidget);
    final before = builds;
    // Progress: same cards, no redraw.
    for (var i = 0; i < 10; i++) {
      records = [
        _record('a'),
        _record('b', status: DownloadStatus.downloading, episode: 2),
      ];
      tick.value++;
      await tester.pump();
    }
    expect(builds, before);
    records = [_record('a'), _record('b', episode: 2)];
    tick.value++;
    await tester.pump();
    expect(builds, before + 1);
    expect(find.text('2 episodes'), findsOneWidget);
  });

  testWidgets('an undrawn change still opens the newest records', (
    tester,
  ) async {
    offline.value = true;
    await tester.pumpWidget(home());
    records = [
      _record('a'),
      _record('b', status: DownloadStatus.queued, episode: 2),
    ];
    tick.value++;
    await tester.pump();
    cards.single.open();
    expect(opened!.videos, hasLength(2));
  });
}
