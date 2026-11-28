// B3: the Windows batch download dialog follows the show page's episode list
// when it grows while the dialog is open (seen: 56 episodes kept after the
// page reached 104).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/features/detail/desktop_batch_download_dialog.dart';

List<Episode> _eps(int count, {String prefix = 's'}) => [
  for (var i = 1; i <= count; i++)
    Episode(id: '$prefix$i', title: 'Episode $i', url: '/$prefix$i', number: i.toDouble()),
];

const _sd = VideoSource(
  url: 'https://alpha.fixture/720.mp4',
  label: 'Alpha',
  quality: '720p',
);

void main() {
  group('batchNewlySelectedIds', () {
    test('a fully ticked season ticks its new episodes', () {
      final before = {1: _eps(4)};
      final after = {1: _eps(6)};
      final ids = batchNewlySelectedIds(
        before: before,
        after: after,
        selected: {'s1', 's2', 's4'},
        downloaded: {'s3'},
      );
      expect(ids, {'s5', 's6'});
    });

    test('a hand-made selection is never widened', () {
      final ids = batchNewlySelectedIds(
        before: {1: _eps(4)},
        after: {1: _eps(6)},
        selected: {'s1'},
        downloaded: const {},
      );
      expect(ids, isEmpty);
    });

    test('a season that was not loaded before stays unticked', () {
      final ids = batchNewlySelectedIds(
        before: {1: _eps(2)},
        after: {1: _eps(2), 2: _eps(3, prefix: 't')},
        selected: {'s1', 's2'},
        downloaded: const {},
      );
      expect(ids, isEmpty);
    });

    test('counts every season', () {
      expect(batchEpisodeCount({1: _eps(56), 2: _eps(48, prefix: 't')}), 104);
      expect(batchEpisodeCount(const {}), 0);
    });
  });

  group('dialog with a live list', () {
    Future<ValueNotifier<Map<int, List<Episode>>>> open(
      WidgetTester tester, {
      String initialCategory = 'sub',
    }) async {
      final live = ValueNotifier<Map<int, List<Episode>>>({1: _eps(4)});
      addTearDown(live.dispose);
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<DesktopBatchDownloadChoice>(
                  context: context,
                  builder: (_) => DesktopBatchDownloadDialog(
                    title: 'Fixture Show',
                    episodesBySeason: {1: _eps(4)},
                    liveEpisodesBySeason: live,
                    initialSeason: 1,
                    initialCategory: initialCategory,
                    availableCategories: const ['sub', 'dub'],
                    resolve: (_) async => [_sd],
                    resolveEpisodes: (cat) async => {1: _eps(2, prefix: 'd')},
                    downloadedIds: (cat, eps) async => {
                      if (cat == 'sub') 's3',
                    },
                    estimateSize: (_, _, _) async => null,
                    readFreeBytes: () async => null,
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
      return live;
    }

    testWidgets('new episodes appear and join the default selection', (
      tester,
    ) async {
      final live = await open(tester);
      expect(find.text('Download 3 episodes'), findsOneWidget);

      live.value = {1: _eps(6)};
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('batch-ep-s6')), findsOneWidget);
      expect(find.text('Download 5 episodes'), findsOneWidget);
    });

    testWidgets('after "None" the new episodes are listed but not ticked', (
      tester,
    ) async {
      final live = await open(tester);
      await tester.tap(find.text('None'));
      await tester.pump();

      live.value = {1: _eps(6)};
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('batch-ep-s6')), findsOneWidget);
      expect(find.text('Select episodes'), findsOneWidget);
    });

    testWidgets('a shorter list never replaces the open one', (tester) async {
      final live = await open(tester);
      live.value = {1: _eps(2)};
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('batch-ep-s4')), findsOneWidget);
    });
  });
}
