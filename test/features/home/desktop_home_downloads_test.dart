import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/download_record.dart';
import 'package:watch_app/features/downloads/desktop_download_library.dart';
import 'package:watch_app/features/home/desktop_home_downloads.dart';
import 'package:watch_app/features/home/desktop_home_page.dart';

DownloadRecord _record(
  String id, {
  String showId = 'show-1',
  String title = 'Frieren',
  DownloadStatus status = DownloadStatus.done,
  int createdAt = 1,
  int episode = 1,
}) => DownloadRecord(
  id: id,
  showId: showId,
  showTitle: title,
  showUrl: 'https://example.test/$showId',
  sourceId: 'src',
  episodeId: 'ep-$id',
  episodeUrl: 'https://example.test/$showId/$id',
  episodeTitle: 'Episode $episode',
  episodeNumber: episode.toDouble(),
  category: 'sub',
  quality: '1080p',
  status: status,
  createdAt: createdAt,
);

void main() {
  group('desktopHomeDownloads', () {
    test('offers only shows with a finished file, newest first', () {
      final collections = desktopDownloadCollections(
        videos: [
          _record('a', showId: 'old', title: 'Older show', createdAt: 5),
          _record('b', showId: 'new', title: 'Newer show', createdAt: 9),
          _record(
            'c',
            showId: 'failed',
            title: 'Never finished',
            status: DownloadStatus.failed,
            createdAt: 99,
          ),
        ],
        chapters: const [],
      );
      final cards = desktopHomeDownloads(
        collections: collections,
        reading: false,
        open: (_) {},
      );
      expect(cards.map((c) => c.title), ['Newer show', 'Older show']);
    });

    test('counts episodes with the right singular and plural', () {
      final collections = desktopDownloadCollections(
        videos: [
          _record('a', showId: 'one', title: 'One', episode: 1),
          _record('b', showId: 'two', title: 'Two', episode: 1),
          _record('c', showId: 'two', title: 'Two', episode: 2),
        ],
        chapters: const [],
      );
      final cards = {
        for (final c in desktopHomeDownloads(
          collections: collections,
          reading: false,
          open: (_) {},
        ))
          c.title: c.subtitle,
      };
      expect(cards['One'], '1 episode');
      expect(cards['Two'], '2 episodes');
    });

    test('does not offer anime downloads to a reading mode', () {
      final collections = desktopDownloadCollections(
        videos: [_record('a')],
        chapters: const [],
      );
      expect(
        desktopHomeDownloads(
          collections: collections,
          reading: true,
          open: (_) {},
        ),
        isEmpty,
      );
    });

    test('opening a card passes back its collection', () {
      final collections = desktopDownloadCollections(
        videos: [_record('a')],
        chapters: const [],
      );
      DesktopDownloadCollection? opened;
      desktopHomeDownloads(
        collections: collections,
        reading: false,
        open: (c) => opened = c,
      ).single.open();
      expect(opened?.title, 'Frieren');
    });
  });

  group('DesktopHomePage offline', () {
    Widget page({
      bool offline = false,
      List<DesktopHomeDownload> downloads = const [],
      VoidCallback? onDownloads,
    }) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 1200,
          height: 800,
          child: DesktopHomePage(
            featured: const [],
            sections: const [],
            resume: const [],
            releases: const [],
            reading: false,
            onOpen: (_) {},
            onPlay: (_) {},
            onMenu: (_) {},
            onSection: (_) {},
            onHistory: () {},
            onReleases: () {},
            onRefresh: () async {},
            meta: (_) async => null,
            playLabel: (_) => 'Play',
            offline: offline,
            downloads: downloads,
            onDownloads: onDownloads,
          ),
        ),
      ),
    );

    testWidgets('offline with downloads shows the shelf and a shortcut', (
      tester,
    ) async {
      var opened = 0;
      await tester.pumpWidget(
        page(
          offline: true,
          onDownloads: () => opened++,
          downloads: [
            DesktopHomeDownload(
              title: 'Frieren',
              subtitle: '2 episodes',
              open: () {},
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Available offline'), findsOneWidget);
      expect(
        find.text("You're offline. Your downloads are ready to watch."),
        findsOneWidget,
      );
      expect(find.text('Frieren'), findsOneWidget);
      await tester.tap(find.text('Open downloads'));
      expect(opened, 1);
      // The retry action reads as a retry, not a catalogue refresh.
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('offline without downloads says how to recover', (
      tester,
    ) async {
      await tester.pumpWidget(page(offline: true));
      await tester.pumpAndSettle();
      expect(
        find.text("You're offline. Connect to browse the catalogue."),
        findsOneWidget,
      );
      expect(find.text('Open downloads'), findsNothing);
      expect(find.text('Available offline'), findsNothing);
    });

    testWidgets('empty catalogue while online suggests downloads', (
      tester,
    ) async {
      await tester.pumpWidget(
        page(
          downloads: [
            DesktopHomeDownload(
              title: 'Frieren',
              subtitle: '1 episode',
              open: () {},
            ),
          ],
          onDownloads: () {},
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Your catalogue is empty.'), findsOneWidget);
      expect(find.text('Your downloads'), findsOneWidget);
      expect(find.text('Available offline'), findsNothing);
    });
  });
}
