import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/download_source_search.dart';
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
    // show-13: optional multi-source search stream.
    Stream<List<DownloadSourceStatus>> Function(Episode, String)? search,
    List<String> categories = const ['sub', 'dub'],
  }) async {
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => Scaffold(
      body: TextButton(onPressed: () async {
        final result = await showDialog<DesktopSingleDownloadChoice>(context: context,
          builder: (_) => DesktopSingleDownloadDialog(episode: original, season: 2,
            initialCategory: 'sub', availableCategories: categories,
            resolveEpisodes: episodes, resolveSources: sources, searchSources: search,
            previewBuilder: (_, _) => const Text('Size preview')));
        done(result);
      }, child: const Text('Open'))))));
    await tester.tap(find.text('Open')); await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('chosen dub returns matched episode URL and category, sub listed too', (tester) async {
    DesktopSingleDownloadChoice? result;
    await open(tester, episodes: (_) async => {2: [dubbed]},
      sources: (_, _) async => [sub, dub], done: (value) => result = value);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'DUB')); await tester.pumpAndSettle();
    // Every link is listed with player-style labels; the dub link is preselected.
    expect(find.text('DUB • English dub'), findsOneWidget);
    expect(find.text('SUB • Japanese sub'), findsOneWidget);
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
    expect(find.text('SUB • Japanese sub'), findsOneWidget);
    expect(find.text('DUB • English dub'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Download')); await tester.pumpAndSettle();
    expect(result?.category, 'sub'); expect(result?.episode.url, '/sub2');
  });
  // show-13: Windows Enter downloads the selected link.
  testWidgets('Windows: Enter downloads the selected link', (tester) async {
    DesktopSingleDownloadChoice? result;
    await open(tester, episodes: (_) async => {2: [dubbed]},
      sources: (_, _) async => [sub, dub], done: (value) => result = value);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter); await tester.pumpAndSettle();
    expect(result?.category, 'sub'); expect(result?.chosen.url, sub.url);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  // show-13: double-clicking a link downloads it; a single click only selects.
  testWidgets('Windows: double-click a link downloads that link', (tester) async {
    const sub2 = VideoSource(url: 'https://fixture/sub2.mp4', label: 'Backup sub', kind: AudioKind.sub);
    DesktopSingleDownloadChoice? result;
    var closed = false;
    await open(tester, episodes: (_) async => {2: [dubbed]},
      sources: (_, _) async => [sub, sub2], done: (value) { result = value; closed = true; });
    await tester.pumpAndSettle();
    await tester.tap(find.text('SUB • Backup sub')); await tester.pump(const Duration(milliseconds: 500));
    expect(closed, isFalse);
    await tester.tap(find.text('SUB • Backup sub')); await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('SUB • Backup sub')); await tester.pumpAndSettle();
    expect(closed, isTrue); expect(result?.chosen.url, sub2.url);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  // show-13: a search stream that throws ends in the error state with Retry.
  testWidgets('a failing source search ends in Retry instead of hanging', (tester) async {
    var calls = 0;
    await open(tester, episodes: (_) async => {2: [dubbed]},
      sources: (_, _) async => [sub], done: (_) {},
      search: (_, _) {
        calls++;
        if (calls > 1) {
          return Stream.value(const [DownloadSourceStatus(sourceId: 'a', name: 'A',
            phase: DownloadSourcePhase.found, streams: [sub])]);
        }
        final c = StreamController<List<DownloadSourceStatus>>();
        c.add(const [DownloadSourceStatus(sourceId: 'a', name: 'A', phase: DownloadSourcePhase.trying)]);
        c.addError(StateError('addon exploded'));
        return c.stream;
      });
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byKey(const ValueKey('download-search-retry')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('download-search-retry'))); await tester.pumpAndSettle();
    expect(find.text('SUB • Japanese sub'), findsOneWidget);
  });

  // dlsource: Anikoto returns SUB and DUB links for one episode, with the
  // server name in `quality` and no label. A catalogue title without a dub
  // count offers only the SUB cut, which used to hide every DUB link.
  testWidgets('mixed SUB/DUB links all show; a DUB pick pops dub and only its server', (tester) async {
    const subHd = VideoSource(url: 'https://cdn.test/s-hd1.m3u8', quality: 'HD - 1 - 1080p', kind: AudioKind.sub, container: SourceContainer.hls);
    const subVs = VideoSource(url: 'https://cdn.test/s-vs2.m3u8', quality: 'Vidstream - 2 - 1080p', kind: AudioKind.sub, container: SourceContainer.hls);
    const dubHd = VideoSource(url: 'https://cdn.test/d-hd1.m3u8', quality: 'HD - 1 - 1080p', kind: AudioKind.dub, container: SourceContainer.hls);
    const dubVs = VideoSource(url: 'https://cdn.test/d-vs2.m3u8', quality: 'Vidstream - 2 - 1080p', kind: AudioKind.dub, container: SourceContainer.hls);
    DesktopSingleDownloadChoice? result;
    await open(tester, episodes: (_) async => {2: [dubbed]}, categories: const ['sub'],
      sources: (_, _) async => [subHd, subVs, dubHd, dubVs], done: (value) => result = value);
    await tester.pumpAndSettle();
    for (final label in ['SUB • HD - 1 - 1080p', 'SUB • Vidstream - 2 - 1080p',
        'DUB • HD - 1 - 1080p', 'DUB • Vidstream - 2 - 1080p']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    await tester.tap(find.text('DUB • HD - 1 - 1080p')); await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Download')); await tester.pumpAndSettle();
    expect(result?.category, 'dub');
    expect(result?.chosen, dubHd);
    // No fallback to the SUB twin or to the other server.
    expect(result?.all, [dubHd]);
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
