// Windows theater watch page: layout, show page button, episode rows.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/player/desktop_watch_page.dart';
import 'package:watch_app/features/player/player_watch_page.dart';
import 'package:watch_app/features/player/watch_page_info.dart';

/// Three episodes, the second one playing, the first half watched.
const _episodes = [
  WatchPageEpisode(
    index: 0,
    heading: '1. Pilot',
    label: 'Pilot',
    thumb: '',
    current: false,
    number: 1,
  ),
  WatchPageEpisode(
    index: 1,
    heading: '2. The Fall',
    label: 'The Fall',
    thumb: '',
    current: true,
    number: 2,
  ),
  WatchPageEpisode(
    index: 2,
    heading: '3. Rise',
    label: 'Rise',
    thumb: '',
    current: false,
    number: 3,
  ),
];

/// Minimal page config; callbacks default to no-ops.
PlayerWatchPage _page({
  VoidCallback? onShowPage,
  VoidCallback? onBack,
  ValueChanged<int>? onOpenEpisode,
  List<WatchPageEpisode> episodes = _episodes,
  List<int>? seasons,
  ValueChanged<int?>? onSelectSeason,
  void Function(int, bool)? onSetWatched,
}) => PlayerWatchPage(
  seasons: seasons,
  selectedSeason: seasons?.first,
  onSelectSeason: onSelectSeason,
  onSetWatched: onSetWatched,
  video: const ColoredBox(color: Colors.black),
  header: const WatchPageHeader(
    title: 'The Fall',
    subtitle: 'Show · S1 E2',
    description: 'A great episode.',
  ),
  showTitle: 'Show',
  positionStream: const Stream.empty(),
  durationStream: const Stream.empty(),
  playingStream: const Stream.empty(),
  initialPlaying: false,
  initialPosition: Duration.zero,
  initialDuration: const Duration(minutes: 24),
  hasPrevious: true,
  nextLabel: 'S1 E3',
  nextTitle: 'Rise',
  autoplay: true,
  episodes: episodes,
  episodeProgress: (i) => i == 0 ? 0.5 : null,
  onTogglePlay: () {},
  onSeek: (_) {},
  onPrevious: () {},
  onNext: () {},
  onFullscreen: () {},
  onBack: onBack ?? () {},
  onServer: () {},
  onAudio: () {},
  onSubtitles: () {},
  onMore: () {},
  onOpenEpisode: onOpenEpisode ?? (_) {},
  onComments: () {},
  onAutoplayChanged: (_) {},
  onShowPage: onShowPage,
);

void main() {
  // Desktop-sized surface so the two-column theater layout is used.
  Future<void> setDesktopSize(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('Windows uses the theater layout with a side panel', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await setDesktopSize(tester);
    await tester.pumpWidget(MaterialApp(home: _page(onShowPage: () {})));
    await tester.pump();

    expect(
      tester.state(find.byType(PlayerWatchPage)),
      isA<DesktopWatchPageState>(),
    );
    expect(find.byKey(const ValueKey('watch-episode-list')), findsOneWidget);
    expect(find.byKey(const ValueKey('watch-tab-comments')), findsOneWidget);
    // The playing row is marked; the half-watched one shows its progress.
    expect(find.text('E2 · Now playing'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    // The video sits left of the side panel, not above a phone list.
    final video = tester.getRect(find.byKey(const ValueKey('watch-video')));
    final list = tester.getRect(
      find.byKey(const ValueKey('watch-episode-list')),
    );
    expect(video.right, lessThan(list.left));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Show page pops back to the route below in one click', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await setDesktopSize(tester);
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        home: const Scaffold(body: Text('detail page')),
      ),
    );
    nav.currentState!.push(
      MaterialPageRoute<void>(
        builder: (context) =>
            _page(onShowPage: () => Navigator.of(context).pop()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('detail page'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('watch-show-page')));
    await tester.pumpAndSettle();
    expect(find.text('detail page'), findsOneWidget);
    expect(find.byType(PlayerWatchPage), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('clicking a row opens that episode, the playing row is inert', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await setDesktopSize(tester);
    final opened = <int>[];
    await tester.pumpWidget(MaterialApp(home: _page(onOpenEpisode: opened.add)));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('watch-row-2')));
    await tester.tap(find.byKey(const ValueKey('watch-row-1')));
    await tester.pump();
    expect(opened, [2]);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('an empty episode list shows a quiet empty state', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await setDesktopSize(tester);
    await tester.pumpWidget(MaterialApp(home: _page(episodes: const [])));
    await tester.pump();

    expect(find.byKey(const ValueKey('watch-episode-list')), findsNothing);
    expect(find.text('No episodes'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('season pill opens the graphite menu, not a Material popup', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await setDesktopSize(tester);
    final picked = <int?>[];
    await tester.pumpWidget(
      MaterialApp(home: _page(seasons: [1, 2], onSelectSeason: picked.add)),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('watch-season-menu')));
    await tester.pumpAndSettle();
    expect(find.byType(PopupMenuItem<int>), findsNothing);
    await tester.tap(find.text('Season 2'));
    await tester.pumpAndSettle();
    expect(picked, [2]);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('right-click on a row opens its menu and acts on the pick', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await setDesktopSize(tester);
    final calls = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: _page(onSetWatched: (i, w) => calls.add('$i:$w')),
      ),
    );
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey('watch-row-2')),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mark as watched'));
    await tester.pumpAndSettle();
    expect(calls, ['2:true']);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('list options button drops the graphite menu', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await setDesktopSize(tester);
    await tester.pumpWidget(MaterialApp(home: _page()));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('watch-list-menu')));
    await tester.pumpAndSettle();
    expect(find.text('Reverse order'), findsOneWidget);
    expect(find.byType(CheckedPopupMenuItem<Object?>), findsNothing);
    // Esc closes the menu without touching the page.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Reverse order'), findsNothing);
    expect(find.byType(PlayerWatchPage), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('jump to episode uses the graphite text prompt', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await setDesktopSize(tester);
    await tester.pumpWidget(MaterialApp(home: _page()));
    await tester.pump();

    await tester.tap(find.byTooltip('Find episode'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(
      find.byKey(const ValueKey('desktop-text-prompt-field')),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const ValueKey('desktop-text-prompt-field')),
      '3',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('desktop-text-prompt-field')),
      findsNothing,
    );
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('phone keeps the portrait page without the show button', (    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.pumpWidget(MaterialApp(home: _page(onShowPage: () {})));
    await tester.pump();

    expect(
      tester.state(find.byType(PlayerWatchPage)),
      isNot(isA<DesktopWatchPageState>()),
    );
    expect(find.byKey(const ValueKey('watch-show-page')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });
}
