// Windows watch page: the Skip pill takes every click (it used to sit under
// the transport bar), and the title under the video links to the show page.
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/player/desktop_skip_pill.dart';
import 'package:watch_app/features/player/player_watch_page.dart';
import 'package:watch_app/features/player/watch_page_info.dart';

/// One playing episode is enough for these checks.
const _episodes = [
  WatchPageEpisode(
    index: 0,
    heading: '5. Daughter of the Demon King',
    label: 'Daughter of the Demon King',
    thumb: '',
    current: true,
    number: 5,
  ),
];

/// Minimal theater page: paused (so the transport bar is up), with an
/// optional skip pill and title link.
PlayerWatchPage _page({VoidCallback? onSkip, VoidCallback? onTitleTap}) =>
    PlayerWatchPage(
      video: const ColoredBox(color: Colors.black),
      header: const WatchPageHeader(
        title: 'Daughter of the Demon King',
        subtitle: 'Black Summoner · E5',
        description: null,
      ),
      showTitle: 'Black Summoner',
      positionStream: const Stream.empty(),
      durationStream: const Stream.empty(),
      playingStream: const Stream.empty(),
      initialPlaying: false,
      initialPosition: const Duration(seconds: 30),
      initialDuration: const Duration(minutes: 24),
      hasPrevious: false,
      autoplay: true,
      episodes: _episodes,
      onTogglePlay: () {},
      onSeek: (_) {},
      onPrevious: () {},
      onNext: () {},
      onFullscreen: () {},
      onBack: () {},
      onServer: () {},
      onAudio: () {},
      onSubtitles: () {},
      onMore: () {},
      onOpenEpisode: (_) {},
      onComments: () {},
      onAutoplayChanged: (_) {},
      onTitleTap: onTitleTap,
      skipButtonFor: onSkip == null
          ? null
          : (_) => TextButton(
              key: const ValueKey('test-skip'),
              onPressed: onSkip,
              child: const Text('Skip'),
            ),
    );

void main() {
  // Desktop-sized surface so the two-column theater layout is used.
  Future<void> setDesktopSize(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('one click on any part of the Skip pill skips, bar up', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await setDesktopSize(tester);
    var skips = 0;
    await tester.pumpWidget(MaterialApp(home: _page(onSkip: () => skips++)));
    // Let the bar's height report in and the pill settle above it.
    await tester.pumpAndSettle();

    final pill = find.byKey(const ValueKey('test-skip'));
    final rect = tester.getRect(pill);
    // The bottom edge used to be covered by the transport bar.
    await tester.tapAt(rect.bottomCenter - const Offset(0, 3));
    await tester.pump();
    await tester.tapAt(rect.center);
    await tester.pump();
    await tester.tapAt(rect.topCenter + const Offset(0, 3));
    await tester.pump();
    expect(skips, 3);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('the title links to the show page only when allowed', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await setDesktopSize(tester);
    var opened = 0;
    await tester.pumpWidget(MaterialApp(home: _page(onTitleTap: () => opened++)));
    await tester.pump();
    await tester.tap(find.text('Daughter of the Demon King').first);
    await tester.pump();
    await tester.tap(find.text('Black Summoner · E5'));
    await tester.pump();
    expect(opened, 2);

    // No action (local file, Watch Together viewer): plain text.
    await tester.pumpWidget(MaterialApp(home: _page()));
    await tester.pump();
    expect(find.byKey(const ValueKey('watch-title-link')), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('the skip pill holds still while the mouse is over it', (
    tester,
  ) async {
    final bottom = ValueNotifier<double>(20);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          children: [
            ValueListenableBuilder<double>(
              valueListenable: bottom,
              builder: (context, b, _) => DesktopSkipPillHost(
                right: 10,
                bottom: b,
                child: const SizedBox(
                  key: ValueKey('pill'),
                  width: 80,
                  height: 30,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    final start = tester.getRect(find.byKey(const ValueKey('pill')));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: start.center);
    await tester.pump();

    // The controls show: the wanted spot moves up, but the pill stays put.
    bottom.value = 120;
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(const ValueKey('pill'))), start);

    // Mouse gone: it moves to the new spot.
    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byKey(const ValueKey('pill'))).top,
      lessThan(start.top),
    );
  });
}
