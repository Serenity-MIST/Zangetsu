import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/features/detail/desktop_single_download_dialog.dart';

const original = Episode(id: 'sub2', title: 'Episode 2', url: '/sub2', number: 2, season: 2);
const dubbed = Episode(id: 'dub2', title: 'Episode 2 English', url: '/dub2', number: 2, season: 2);
const sub = VideoSource(url: 'https://fixture/sub.mp4', label: 'Japanese sub', kind: AudioKind.sub);
const dub = VideoSource(url: 'https://fixture/dub.mp4', label: 'English dub', kind: AudioKind.dub);

void main() {
  test('cut mapping requires unique matching season and number, never position', () {
    expect(matchSingleDownloadEpisode(original, 2, {1: [dubbed]}), isNull);
    expect(matchSingleDownloadEpisode(original, 2, {2: [dubbed, dubbed]}), isNull);
    expect(matchSingleDownloadEpisode(original, 2, {2: [dubbed]})?.url, '/dub2');
    const fraction = Episode(id: 'fraction', title: 'Special', url: '/special', number: 2.5, season: 2);
    expect(matchSingleDownloadEpisode(fraction, 2, {2: [dubbed, fraction]})?.number, 2.5);
    const movie = Episode(id: 'movie', title: 'Movie', url: '/movie');
    expect(matchSingleDownloadEpisode(movie, 1, {1: [movie]})?.id, 'movie');
    expect(matchSingleDownloadEpisode(movie, 1, {1: [movie, movie]}), isNull);
  });

  Future<void> open(WidgetTester tester, {
    required Future<Map<int, List<Episode>>> Function(String) episodes,
    required Future<List<VideoSource>> Function(Episode, String) sources,
    required ValueChanged<DesktopSingleDownloadChoice?> done,
  }) async {
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => Scaffold(
      body: TextButton(onPressed: () async {
        final result = await showDialog<DesktopSingleDownloadChoice>(context: context,
          builder: (_) => DesktopSingleDownloadDialog(episode: original, season: 2,
            initialCategory: 'sub', availableCategories: const ['sub', 'dub'],
            resolveEpisodes: episodes, resolveSources: sources,
            previewBuilder: (_, _) => const Text('Size preview')));
        done(result);
      }, child: const Text('Open'))))));
    await tester.tap(find.text('Open')); await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('chosen dub returns matched episode URL and category, excluding sub server', (tester) async {
    DesktopSingleDownloadChoice? result;
    await open(tester, episodes: (_) async => {2: [dubbed]},
      sources: (_, _) async => [sub, dub], done: (value) => result = value);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'DUB')); await tester.pumpAndSettle();
    expect(find.text('English dub'), findsOneWidget);
    expect(find.text('Japanese sub'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Download')); await tester.pumpAndSettle();
    expect(result?.category, 'dub'); expect(result?.episode.url, '/dub2');
    expect(result?.chosen.kind, AudioKind.dub); expect(result?.all, [dub]);
  });
  testWidgets('missing counterpart disables download without falling back to sub', (tester) async {
    final calls = <String>[];
    await open(tester, episodes: (_) async => {1: [dubbed]},
      sources: (_, cat) async { calls.add(cat); return [sub, dub]; }, done: (_) {});
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'DUB')); await tester.pumpAndSettle();
    expect(find.textContaining('No unique matching episode'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Download')).onPressed, isNull);
    expect(calls, ['sub']);
  });
  testWidgets('retired dub episode lookup cannot replace newer sub selection', (tester) async {
    final held = Completer<Map<int, List<Episode>>>();
    DesktopSingleDownloadChoice? result;
    await open(tester, episodes: (_) => held.future,
      sources: (_, _) async => [sub, dub], done: (value) => result = value);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'DUB')); await tester.pump();
    await tester.tap(find.widgetWithText(ChoiceChip, 'SUB')); await tester.pumpAndSettle();
    held.complete({2: [dubbed]}); await tester.pumpAndSettle();
    expect(find.text('Japanese sub'), findsOneWidget);
    expect(find.text('English dub'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Download')); await tester.pumpAndSettle();
    expect(result?.category, 'sub'); expect(result?.episode.url, '/sub2');
  });
  testWidgets('retired stream error and cancellation cannot revive a closed chooser', (tester) async {
    final held = Completer<List<VideoSource>>();
    DesktopSingleDownloadChoice? result;
    await open(tester, episodes: (_) async => {2: [dubbed]},
      sources: (_, category) => category == 'dub' ? held.future : Future.value([sub]),
      done: (value) => result = value);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'DUB')); await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel')); await tester.pumpAndSettle();
    held.completeError(StateError('retired source error')); await tester.pumpAndSettle();
    expect(result, isNull); expect(tester.takeException(), isNull);
  });
}
