// Windows player flow: playback opens on the watch page, theatre mode and
// full screen come back to it, the watch page bar holds mini player /
// theatre / full screen, the header shows the episode number once and the
// buffering circle cannot stay stuck. Each check also pins that phones keep
// their old behaviour.
import 'dart:async';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/desktop_shortcut_catalog.dart';
import 'package:watch_app/core/desktop/desktop_shortcuts.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/playback/playback_prefs.dart'
    show PlayerPresentation;
import 'package:watch_app/features/player/desktop_buffering_gate.dart';
import 'package:watch_app/features/player/desktop_watch_page.dart';
import 'package:watch_app/features/player/player_screen.dart';
import 'package:watch_app/features/player/player_watch_page.dart';
import 'package:watch_app/features/player/watch_page_info.dart';
import 'package:watch_app/l10n/app_localizations.dart';

Episode _ep(String title, {double n = 1166, String? metaTitle}) => Episode(
  id: 'e$n',
  title: title,
  url: 'https://x/e$n',
  number: n,
  metaTitle: metaTitle,
);

const _episodes = [
  WatchPageEpisode(
    index: 0,
    heading: '1. Pilot',
    label: 'Pilot',
    thumb: '',
    current: true,
    number: 1,
  ),
];

PlayerWatchPage _page({
  VoidCallback? onTheatre,
  VoidCallback? onFullScreen,
  VoidCallback? onMiniPlayer,
}) => PlayerWatchPage(
  video: const ColoredBox(color: Colors.black),
  header: const WatchPageHeader(
    title: 'Pilot',
    subtitle: 'Show · E1',
    description: 'Desc',
  ),
  showTitle: 'Show',
  positionStream: const Stream.empty(),
  durationStream: const Stream.empty(),
  playingStream: const Stream.empty(),
  initialPlaying: true,
  initialPosition: Duration.zero,
  initialDuration: const Duration(minutes: 24),
  hasPrevious: false,
  autoplay: true,
  episodes: _episodes,
  onTogglePlay: () {},
  onSeek: (_) {},
  onPrevious: () {},
  onNext: () {},
  onFullscreen: onTheatre ?? () {},
  onFullScreen: onFullScreen,
  onMiniPlayer: onMiniPlayer,
  onBack: () {},
  onServer: () {},
  onAudio: () {},
  onSubtitles: () {},
  onMore: () {},
  onOpenEpisode: (_) {},
  onComments: () {},
  onAutoplayChanged: (_) {},
  onShowPage: () {},
);

Widget _app(Widget home) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: home,
);

void main() {
  group('opening layout', () {
    test('Windows always opens the watch page, whatever the setting', () {
      for (final pref in ['portrait', 'landscape', 'system']) {
        for (final wide in [true, false]) {
          expect(
            initialPresentation(
              isTv: false,
              orientation: pref,
              isLandscape: wide,
              windows: true,
            ),
            PlayerPresentation.watchPage,
            reason: '$pref wide=$wide',
          );
        }
      }
    });

    test('phone keeps following the saved orientation', () {
      expect(
        initialPresentation(
          isTv: false,
          orientation: 'landscape',
          isLandscape: true,
        ),
        PlayerPresentation.fullscreen,
      );
      expect(
        initialPresentation(
          isTv: false,
          orientation: 'portrait',
          isLandscape: true,
        ),
        PlayerPresentation.watchPage,
      );
      expect(
        initialPresentation(
          isTv: true,
          orientation: 'portrait',
          isLandscape: true,
        ),
        PlayerPresentation.fullscreen,
      );
    });
  });

  group('full screen comes back to where it started', () {
    test('watch page -> full screen -> watch page', () {
      final into = desktopFullScreenLayout(
        fullScreen: true,
        current: PlayerPresentation.watchPage,
      );
      expect(into.presentation, PlayerPresentation.fullscreen);
      expect(into.before, PlayerPresentation.watchPage);
      final out = desktopFullScreenLayout(
        fullScreen: false,
        current: into.presentation,
        before: into.before,
      );
      expect(out.presentation, PlayerPresentation.watchPage);
      expect(out.before, isNull);
    });

    test('theatre -> full screen -> theatre (Esc once more: watch page)', () {
      final into = desktopFullScreenLayout(
        fullScreen: true,
        current: PlayerPresentation.fullscreen,
      );
      expect(into.before, PlayerPresentation.fullscreen);
      final out = desktopFullScreenLayout(
        fullScreen: false,
        current: into.presentation,
        before: into.before,
      );
      expect(out.presentation, PlayerPresentation.fullscreen);
    });

    test('a repeated full screen event keeps the first record', () {
      final again = desktopFullScreenLayout(
        fullScreen: true,
        current: PlayerPresentation.fullscreen,
        before: PlayerPresentation.watchPage,
      );
      expect(again.before, PlayerPresentation.watchPage);
    });

    test('leaving full screen with nothing recorded keeps the layout', () {
      final out = desktopFullScreenLayout(
        fullScreen: false,
        current: PlayerPresentation.watchPage,
      );
      expect(out.presentation, PlayerPresentation.watchPage);
    });
  });

  group('header shows the episode number once', () {
    const name = 'Encountering Loki: Gunko of the Knights of God';
    test('leading copies of the number are stripped', () {
      for (final raw in [
        'E1166 — $name',
        'E1166 - $name',
        'E1166 $name',
        'e01166: $name',
        'Ep. 1166 $name',
        'EP1166 | $name',
        'Episode 1166: $name',
        'Episode 1166 - $name',
        '#1166 $name',
        'S1E1166 - $name',
        'S01 E1166 · $name',
        '1166. $name',
        '1166 - $name',
        'E1166 · E1166 — $name',
        'Episode 1166 · E1166: $name',
      ]) {
        expect(stripRepeatedEpisodeNumber(raw, 1166), name, reason: raw);
      }
    });

    test('names that only look similar are left alone', () {
      expect(
        stripRepeatedEpisodeNumber('E1167 — $name', 1166),
        'E1167 — $name',
      );
      expect(
        stripRepeatedEpisodeNumber('100 Ways to Die', 100),
        '100 Ways to Die',
      );
      expect(stripRepeatedEpisodeNumber('Eden 5', 5), 'Eden 5');
      expect(stripRepeatedEpisodeNumber(name, 1166), name);
      expect(stripRepeatedEpisodeNumber('E1166', 1166), '');
    });

    test('the Windows header name has no repeated number', () {
      expect(
        playerHeaderEpisodeName(
          _ep('E1166 · E1166 — $name'),
          1166,
          windows: true,
        ),
        name,
      );
      expect(
        playerHeaderEpisodeName(_ep('#1166'), 1166, windows: true),
        isNull,
      );
      // A looked-up name is cleaned the same way.
      expect(
        playerHeaderEpisodeName(
          _ep('Episode 1166', metaTitle: 'Episode 1166 - $name'),
          1166,
          windows: true,
        ),
        name,
      );
    });

    test('phone keeps the source title as it was', () {
      expect(
        playerHeaderEpisodeName(_ep('E1166 — $name'), 1166, windows: false),
        'E1166 — $name',
      );
    });
  });

  group('buffering circle', () {
    test('only small forward steps count as playing', () {
      const s = Duration(seconds: 10);
      expect(isPlaybackStep(s, s + const Duration(milliseconds: 250)), isTrue);
      expect(isPlaybackStep(s, s), isFalse);
      expect(isPlaybackStep(s, s - const Duration(seconds: 1)), isFalse);
      expect(isPlaybackStep(s, s + const Duration(seconds: 30)), isFalse);
      expect(showBufferingCircle(buffering: true, moving: false), isTrue);
      expect(showBufferingCircle(buffering: true, moving: true), isFalse);
      expect(showBufferingCircle(buffering: false, moving: false), isFalse);
    });

    testWidgets('a stuck buffering flag is ignored while frames play', (
      tester,
    ) async {
      final buffering = StreamController<bool>.broadcast();
      final position = StreamController<Duration>.broadcast();
      addTearDown(buffering.close);
      addTearDown(position.close);
      final seen = <bool>[];
      await tester.pumpWidget(
        DesktopBufferingGate(
          bufferingStream: buffering.stream,
          initialBuffering: false,
          positionStream: position.stream,
          initialPosition: Duration.zero,
          builder: (context, b) {
            seen.add(b);
            return const SizedBox();
          },
        ),
      );
      // pump(Duration.zero) lets the stream event land before the frame.
      buffering.add(true);
      await tester.pump(Duration.zero);
      expect(seen.last, isTrue);
      // Frames play: the position moves forward on its own.
      for (var i = 1; i <= 4; i++) {
        position.add(Duration(milliseconds: 250 * i));
        await tester.pump(const Duration(milliseconds: 250));
        expect(seen.last, isFalse, reason: 'tick $i');
      }
      // Playback really stalls: the circle comes back.
      await tester.pump(kDesktopPlaybackMovingWindow);
      expect(seen.last, isTrue);
      // A seek jump while buffering keeps the circle up.
      position.add(const Duration(minutes: 5));
      await tester.pump(Duration.zero);
      expect(seen.last, isTrue);
      buffering.add(false);
      await tester.pump(Duration.zero);
      expect(seen.last, isFalse);
    });

    // The user's screenshot: 00:00 / 00:00, a picture on screen, the player
    // playing, and the buffering flag never clearing.
    testWidgets('a held flag with the position stuck at 0 clears once the '
        'player is playing with a picture up', (tester) async {
      final buffering = StreamController<bool>.broadcast();
      final position = StreamController<Duration>.broadcast();
      final playing = StreamController<bool>.broadcast();
      final frame = StreamController<int?>.broadcast();
      addTearDown(buffering.close);
      addTearDown(position.close);
      addTearDown(playing.close);
      addTearDown(frame.close);
      final seen = <bool>[];
      await tester.pumpWidget(
        DesktopBufferingGate(
          bufferingStream: buffering.stream,
          initialBuffering: true,
          positionStream: position.stream,
          initialPosition: Duration.zero,
          playingStream: playing.stream,
          initialPlaying: false,
          frameStream: frame.stream,
          builder: (context, b) {
            seen.add(b);
            return const SizedBox();
          },
        ),
      );
      expect(seen.last, isTrue);
      // Not playing yet: the circle stays however long it takes.
      await tester.pump(kDesktopStaleBufferingAfter * 2);
      expect(seen.last, isTrue);
      playing.add(true);
      await tester.pump(kDesktopStaleBufferingAfter * 2);
      expect(seen.last, isTrue, reason: 'no picture yet');
      // A picture arrives; the position stays at 0.
      frame.add(1920);
      position.add(Duration.zero);
      await tester.pump(const Duration(seconds: 1));
      expect(seen.last, isTrue, reason: 'a short stall still shows');
      await tester.pump(kDesktopStaleBufferingAfter);
      expect(seen.last, isFalse);
      // A seek shows it again for a moment.
      position.add(const Duration(minutes: 3));
      await tester.pump(Duration.zero);
      expect(seen.last, isTrue);
      await tester.pump(kDesktopStaleBufferingAfter);
      expect(seen.last, isFalse);
      // Pausing and playing again starts the wait over.
      playing.add(false);
      await tester.pump(Duration.zero);
      expect(seen.last, isTrue);
      playing.add(true);
      await tester.pump(kDesktopStaleBufferingAfter);
      expect(seen.last, isFalse);
    });
  });

  group('watch page bar', () {
    setUp(() {
      DesktopShortcuts.debugReset();
      registerDefaultDesktopShortcuts();
    });
    tearDown(DesktopShortcuts.debugReset);

    Future<void> desktop(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    testWidgets('top bar has no full player button; the video bar has '
        'mini player, theatre and full screen', (tester) async {
      await desktop(tester);
      final log = <String>[];
      await tester.pumpWidget(
        _app(
          _page(
            onTheatre: () => log.add('theatre'),
            onFullScreen: () => log.add('full'),
            onMiniPlayer: () => log.add('mini'),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('watch-full-player')), findsNothing);
      // Hover the video so its bar is up.
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(gesture.removePointer);
      await gesture.addPointer(
        location: tester.getCenter(find.byKey(const ValueKey('watch-video'))),
      );
      await gesture.moveBy(const Offset(4, 4));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('watch-mini-player')));
      await tester.tap(find.byKey(const ValueKey('watch-theatre')));
      await tester.tap(find.byKey(const ValueKey('watch-full-screen')));
      expect(log, ['mini', 'theatre', 'full']);
      // Tooltips name the keys (remaps included).
      final theatre = tester.widget<IconButton>(
        find.descendant(
          of: find.byKey(const ValueKey('watch-theatre')),
          matching: find.byType(IconButton),
        ),
      );
      expect(theatre.tooltip, 'Theatre mode · T');
      await tester.pump(const Duration(seconds: 3));
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('phone page shows none of the Windows buttons', (tester) async {
      await tester.pumpWidget(_app(_page(onMiniPlayer: () {})));
      await tester.pump();
      expect(
        tester.state(find.byType(PlayerWatchPage)),
        isNot(isA<DesktopWatchPageState>()),
      );
      expect(find.byKey(const ValueKey('watch-theatre')), findsNothing);
      expect(find.byKey(const ValueKey('watch-mini-player')), findsNothing);
      await tester.pump(const Duration(seconds: 3));
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  });

  group('shortcuts', () {
    setUp(() {
      DesktopShortcuts.debugReset();
      registerDefaultDesktopShortcuts();
    });
    tearDown(DesktopShortcuts.debugReset);

    test('T is theatre mode; full screen and mini player keep their keys', () {
      expect(DesktopShortcuts.describeAll('player.theatre'), 'T');
      expect(DesktopShortcuts.describeAll('player.fullscreen'), 'F');
      expect(DesktopShortcuts.describeAll('player.miniPlayer'), 'Ctrl+M');
      expect(
        DesktopShortcuts.conflictWith(
          'player.theatre',
          const SingleActivator(LogicalKeyboardKey.keyT),
        ),
        isNull,
      );
    });
  });

  test('PlayerPresentation values are unchanged', () {
    expect(PlayerPresentation.values, [
      PlayerPresentation.watchPage,
      PlayerPresentation.fullscreen,
    ]);
  });
}
