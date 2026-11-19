// Windows theater watch page (player layout work): buffering no longer
// locks the controls, right-click and wheel reach the player, the wheel over
// the header is not volume, keyboard / wheel feedback, and the compact
// volume and speed buttons with the full player's seek bar.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/player/desktop_player_hud.dart';
import 'package:watch_app/features/player/player_watch_page.dart';
import 'package:watch_app/features/player/watch_page_info.dart';

/// One playing episode is enough for the transport tests.
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

/// Theater page with every Windows hook wired to test doubles.
PlayerWatchPage _page({
  bool loading = false,
  Stream<bool>? buffering,
  bool initialBuffering = false,
  VoidCallback? onTogglePlay,
  VoidCallback? onFullscreen,
  ValueChanged<Offset>? onContextMenu,
  ValueChanged<int>? onWheelVolume,
  ValueListenable<DesktopHudEvent?>? hud,
  ValueChanged<double>? onVolumeChanged,
  VoidCallback? onSpeed,
  Widget? seekBar,
}) => PlayerWatchPage(
  video: const ColoredBox(color: Colors.black),
  header: const WatchPageHeader(
    title: 'Pilot',
    subtitle: 'Show · E1',
    description: null,
  ),
  loading: loading,
  bufferingStream: buffering,
  initialBuffering: initialBuffering,
  positionStream: const Stream.empty(),
  durationStream: const Stream.empty(),
  playingStream: const Stream.empty(),
  // Paused, so the transport stays up without hovering first.
  initialPlaying: false,
  initialPosition: Duration.zero,
  initialDuration: const Duration(minutes: 24),
  hasPrevious: false,
  autoplay: true,
  episodes: _episodes,
  onTogglePlay: onTogglePlay ?? () {},
  onSeek: (_) {},
  onPrevious: () {},
  onNext: () {},
  onFullscreen: onFullscreen ?? () {},
  onBack: () {},
  onServer: () {},
  onAudio: () {},
  onSubtitles: () {},
  onMore: () {},
  onOpenEpisode: (_) {},
  onComments: () {},
  onAutoplayChanged: (_) {},
  onContextMenu: onContextMenu,
  onWheelVolume: onWheelVolume,
  hud: hud,
  initialVolume: 60,
  onVolumeChanged: onVolumeChanged,
  onToggleMute: onVolumeChanged == null ? null : () {},
  initialRate: 1.5,
  onSpeed: onSpeed,
  seekBar: seekBar,
);

/// A widget test run as Windows (the override is set and reset for us).
void _windowsTest(String description, WidgetTesterCallback body) => testWidgets(
  description,
  body,
  variant: TargetPlatformVariant.only(TargetPlatform.windows),
);

/// Desktop-sized surface so the two-column theater layout is used.
Future<void> _desktop(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1600, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// A mouse click (down + up) at [at].
Future<void> _click(
  WidgetTester tester,
  Offset at, {
  int buttons = kPrimaryMouseButton,
}) async {
  final g = await tester.startGesture(
    at,
    kind: PointerDeviceKind.mouse,
    buttons: buttons,
  );
  await g.up();
}

void main() {
  group('Theater watch page (Windows)', () {
    _windowsTest('buffering mid-episode keeps play/pause usable', (
      tester,
    ) async {
      await _desktop(tester);
      var toggles = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: _page(initialBuffering: true, onTogglePlay: () => toggles++),
        ),
      );
      await tester.pump();
      // Spinner shows, but the play button is live.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      final play = tester.widget<IconButton>(
        find.descendant(
          of: find.byKey(const ValueKey('watch-play')),
          matching: find.byType(IconButton),
        ),
      );
      expect(play.onPressed, isNotNull);
      // A click on the picture pauses right away too.
      await _click(
        tester,
        tester.getCenter(find.byKey(const ValueKey('watch-video'))),
      );
      expect(toggles, 1);
    });

    _windowsTest('while a source loads the controls stay locked', (
      tester,
    ) async {
      await _desktop(tester);
      var toggles = 0;
      await tester.pumpWidget(
        MaterialApp(home: _page(loading: true, onTogglePlay: () => toggles++)),
      );
      await tester.pump();
      final play = tester.widget<IconButton>(
        find.descendant(
          of: find.byKey(const ValueKey('watch-play')),
          matching: find.byType(IconButton),
        ),
      );
      expect(play.onPressed, isNull);
      await _click(
        tester,
        tester.getCenter(find.byKey(const ValueKey('watch-video'))),
      );
      expect(toggles, 0);
    });

    _windowsTest('right-click and wheel over the video reach the player', (
      tester,
    ) async {
      await _desktop(tester);
      Offset? menuAt;
      final steps = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: _page(
            onContextMenu: (p) => menuAt = p,
            onWheelVolume: steps.add,
          ),
        ),
      );
      await tester.pump();
      final centre = tester.getCenter(
        find.byKey(const ValueKey('watch-video')),
      );
      await _click(tester, centre, buttons: kSecondaryMouseButton);
      expect(menuAt, centre);

      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(centre));
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, -20)));
      await tester.pump();
      expect(steps, [1]);
      // Let the hover idle timer run out.
      await tester.pump(const Duration(seconds: 3));
    });

    _windowsTest('wheel over the header never reaches the page-wide handler', (
      tester,
    ) async {
      await _desktop(tester);
      var outer = 0;
      final steps = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          // Stands in for DesktopPlayerInput's page-wide wheel listener.
          home: Listener(
            onPointerSignal: (e) => GestureBinding
                .instance
                .pointerSignalResolver
                .register(e, (_) => outer++),
            child: _page(onWheelVolume: steps.add),
          ),
        ),
      );
      await tester.pump();
      final header = tester.getCenter(find.byKey(const ValueKey('watch-back')));
      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(header));
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, -20)));
      await tester.pump();
      expect(outer, 0);
      expect(steps, isEmpty);
    });

    _windowsTest('keyboard / wheel feedback shows over the video', (
      tester,
    ) async {
      await _desktop(tester);
      final hud = DesktopHudController();
      addTearDown(hud.dispose);
      await tester.pumpWidget(MaterialApp(home: _page(hud: hud)));
      await tester.pump();
      hud.showVolume(40);
      await tester.pump();
      expect(find.byKey(const ValueKey('watch-hud-volume')), findsOneWidget);
      expect(find.text('40%'), findsOneWidget);
      hud.showSeek(-10);
      await tester.pump();
      expect(find.text('−10s'), findsOneWidget);
      // Fades out after the hold.
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('−10s'), findsNothing);
    });

    _windowsTest('volume and speed buttons sit in the transport', (
      tester,
    ) async {
      await _desktop(tester);
      final volumes = <double>[];
      var speed = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: _page(
            onVolumeChanged: volumes.add,
            onSpeed: () => speed++,
            seekBar: const SizedBox(key: ValueKey('full-seek-bar'), height: 20),
          ),
        ),
      );
      await tester.pump();
      // The player's own seek bar replaces the plain slider.
      expect(find.byKey(const ValueKey('full-seek-bar')), findsOneWidget);
      expect(find.byKey(const ValueKey('watch-volume')), findsOneWidget);
      expect(find.text('1.5x'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('watch-speed')));
      expect(speed, 1);

      // Hovering the speaker opens its slider; dragging it sets the level.
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(
        tester.getCenter(find.byKey(const ValueKey('watch-volume'))),
      );
      await tester.pumpAndSettle();
      final slider = find.byKey(const ValueKey('watch-volume-slider'));
      expect(tester.getSize(slider).width, greaterThan(40));
      await tester.tapAt(tester.getCenter(slider) + const Offset(30, 0));
      await tester.pump();
      expect(volumes, isNotEmpty);
      await tester.pump(const Duration(seconds: 3));
    });
  });
}
