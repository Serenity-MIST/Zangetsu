// Windows player controls (player-5, 6, 7, 10, 12, 15): keyboard map with
// remaps, media-key de-duplication, boost-safe volume, stacking seeks, the
// external-player helpers and the docked More panel.
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RendererBinding;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:watch_app/core/desktop/desktop_media_keys.dart';
import 'package:watch_app/core/desktop/desktop_native.dart';
import 'package:watch_app/core/desktop/desktop_player_input.dart';
import 'package:watch_app/core/desktop/desktop_shortcut_catalog.dart';
import 'package:watch_app/core/desktop/desktop_shortcuts.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/playback/external_player.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/playback/resume_store.dart';
import 'package:watch_app/features/player/mpv_player_pool.dart';
import 'package:watch_app/features/player/player_controller.dart';
import 'package:watch_app/features/player/player_screen.dart';

/// Records the transport calls the cubit makes; everything else is inert.
class _Player extends Fake implements mk.Player {
  final seeks = <Duration>[];
  final volumes = <double>[];
  var toggles = 0;
  @override
  mk.PlatformPlayer? get platform => null;
  @override
  mk.PlayerState get state => const mk.PlayerState();
  @override
  late final stream = mk.PlayerStream(
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
    const Stream.empty(),
  );
  @override
  Future<void> seek(Duration duration) async => seeks.add(duration);
  @override
  Future<void> setVolume(double volume) async => volumes.add(volume);
  @override
  Future<void> playOrPause() async => toggles++;
  @override
  Future<void> open(mk.Playable playable, {bool play = true}) async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
  @override
  Future<void> setRate(double value) async {}
  @override
  Future<void> setSubtitleTrack(mk.SubtitleTrack track) async {}
  @override
  Future<void> setAudioTrack(mk.AudioTrack track) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DesktopPlayerInput keys (player-5)', () {
    setUp(() {
      DesktopShortcuts.debugReset();
      registerDefaultDesktopShortcuts();
      DesktopMediaKeyDedupe.debugReset();
    });
    tearDown(DesktopShortcuts.debugReset);

    Future<List<String>> pump(WidgetTester tester) async {
      final log = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: DesktopPlayerInput(
            onPlayPause: () => log.add('play'),
            onSeek: (s) => log.add('seek $s'),
            onVolume: (v) => log.add('vol $v'),
            onMute: () => log.add('mute'),
            onBack: () => log.add('back'),
            onNextEpisode: () => log.add('next'),
            onPreviousEpisode: () => log.add('prev'),
            onSkip: () => log.add('skip'),
            onSpeedStep: (d) => log.add('speed $d'),
            onToggleSubtitles: () => log.add('subs'),
            onJumpToFraction: (f) => log.add('jump $f'),
            onFrameStep: (d) => log.add('frame $d'),
            onSubtitleDelayStep: (d) => log.add('delay $d'),
            onMiniPlayer: () => log.add('mini'),
            onAlwaysOnTop: () => log.add('top'),
            onHelp: () => log.add('help'),
            child: const Scaffold(body: SizedBox.expand()),
          ),
        ),
      );
      await tester.pump();
      return log;
    }

    testWidgets('new player keys dispatch their actions', (tester) async {
      final log = await pump(tester);
      for (final k in [
        LogicalKeyboardKey.keyN,
        LogicalKeyboardKey.keyP,
        LogicalKeyboardKey.keyS,
        LogicalKeyboardKey.bracketLeft,
        LogicalKeyboardKey.bracketRight,
        LogicalKeyboardKey.keyC,
        LogicalKeyboardKey.digit0,
        LogicalKeyboardKey.digit5,
        LogicalKeyboardKey.comma,
        LogicalKeyboardKey.period,
        LogicalKeyboardKey.keyG,
        LogicalKeyboardKey.keyH,
      ]) {
        await tester.sendKeyEvent(k);
      }
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(log, [
        'next',
        'prev',
        'skip',
        'speed -1',
        'speed 1',
        'subs',
        'jump 0.0',
        'jump 0.5',
        'frame -1',
        'frame 1',
        'delay -1',
        'delay 1',
        'mini',
        'top',
        'seek 60',
      ]);
    });

    testWidgets('a remap on the shortcuts page applies straight away', (
      tester,
    ) async {
      final log = await pump(tester);
      await DesktopShortcuts.setOverride('player.nextEpisode', const [
        SingleActivator(LogicalKeyboardKey.keyX),
      ]);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
      expect(log, ['next']);
    });

    testWidgets('media keys work and claim the press from the overlay', (
      tester,
    ) async {
      final log = await pump(tester);
      // The test key simulator's Windows map has no Next / Previous keys, so
      // send them with the Android map (same logical keys).
      await tester.sendKeyEvent(
        LogicalKeyboardKey.mediaPlayPause,
        platform: 'android',
      );
      await tester.sendKeyEvent(
        LogicalKeyboardKey.mediaTrackNext,
        platform: 'android',
      );
      expect(log, ['play', 'next']);
      // The same press arriving from the Windows media overlay is dropped.
      expect(
        DesktopMediaKeyDedupe.claim(DesktopMediaKeyAction.playPause),
        false,
      );
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('media keys without a callback stay unbound', (tester) async {
      // No onStop: the Stop key is not claimed, so the Windows media overlay
      // path still gets it.
      await pump(tester);
      final handled = await tester.sendKeyEvent(LogicalKeyboardKey.mediaStop);
      expect(handled, isFalse);
      expect(DesktopMediaKeyDedupe.claim(DesktopMediaKeyAction.stop), true);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  });

  test('media-key de-duplication window is ~300ms per action', () {
    var now = 1000;
    DesktopMediaKeyDedupe.debugReset();
    DesktopMediaKeyDedupe.clock = () => now;
    addTearDown(DesktopMediaKeyDedupe.debugReset);
    expect(DesktopMediaKeyDedupe.claim(DesktopMediaKeyAction.playPause), true);
    now += 120;
    expect(DesktopMediaKeyDedupe.claim(DesktopMediaKeyAction.playPause), false);
    // A different action is independent.
    expect(DesktopMediaKeyDedupe.claim(DesktopMediaKeyAction.next), true);
    now += 400;
    expect(DesktopMediaKeyDedupe.claim(DesktopMediaKeyAction.playPause), true);
    expect(
      DesktopMediaKeyDedupe.actionFor(DesktopMediaCommandKind.pause),
      DesktopMediaKeyAction.playPause,
    );
    expect(DesktopMediaKeyDedupe.actionFor(DesktopMediaCommandKind.seek), null);
  });

  group('PlayerCubit on Windows', () {
    late Directory dir;
    late _Player player;
    PlayerCubit? cubit;

    setUp(() async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      DesktopMediaKeyDedupe.debugReset();
      dir = await Directory.systemTemp.createTemp('player_controls_desktop');
      Hive.init(dir.path);
      await PlaybackPrefs.init();
      await sl.reset();
      sl.registerSingleton<PlaybackPrefs>(PlaybackPrefs());
      player = _Player();
      sl.registerSingleton<MpvPlayerPool>(
        MpvPlayerPool(createPlayer: (_) => player),
      );
      cubit = PlayerCubit(
        sourceId: 'source',
        episodes: const [Episode(id: '1', title: 'First', url: 'episode-1')],
        resume: ResumeStore(),
        resolveSources: (_) async => const [],
        dio: Dio(),
      );
    });
    tearDown(() async {
      debugDefaultTargetPlatformOverride = null;
      DesktopMediaKeyDedupe.debugReset();
      await cubit?.close();
      cubit = null;
      await sl.reset();
      await Hive.close();
      await dir.delete(recursive: true);
    });

    test('quick seeks add to the pending target (player-7)', () {
      final c = cubit!;
      var now = 10000;
      c.seekClock = () => now;
      for (var i = 0; i < 5; i++) {
        c.seekBy(const Duration(seconds: 10));
        now += 150;
      }
      expect(player.seeks.last, const Duration(seconds: 50));
      // After the window the reported position (still 0 here) is the base.
      now += 2000;
      c.seekBy(const Duration(seconds: 10));
      expect(player.seeks.last, const Duration(seconds: 10));
      // An absolute seek drops the pending target.
      c.seekTo(const Duration(seconds: 100));
      c.seekBy(const Duration(seconds: 10));
      expect(player.seeks.last, const Duration(seconds: 10));
    });

    test(
      'volume steps keep the boost and unmute restores (player-6)',
      () async {
        await sl<PlaybackPrefs>().setVolumeBoost(150);
        final c = cubit!;
        expect(c.userVolume, 100);
        expect(c.stepUserVolume(-10), 90);
        await Future<void>.delayed(Duration.zero);
        // 90% of the user range, boosted by 150%.
        expect(player.volumes.last, closeTo(135, 0.001));
        expect(c.stepUserVolume(50), 100, reason: 'keys stay within 0-100');
        expect(c.toggleUserMute(), 0);
        expect(c.toggleUserMute(), 100, reason: 'unmute returns to the level');
        await Future<void>.delayed(Duration.zero);
        expect(player.volumes.last, closeTo(150, 0.001));
        expect(c.userVolumeFromMpv(150), 100);
        // Dragging the slider to 0 then pressing M comes back to the last
        // non-zero level, not 100.
        await c.setUserVolume(40);
        await c.setUserVolume(0);
        expect(c.toggleUserMute(), 40);
      },
    );

    test(
      'a media command after the focused key press is dropped (player-10)',
      () {
        final c = cubit!..init(0);
        // Same press: the focused key handler claimed it first.
        expect(
          DesktopMediaKeyDedupe.claim(DesktopMediaKeyAction.playPause),
          true,
        );
        c.debugDesktopMediaCommand(
          const DesktopMediaCommand(DesktopMediaCommandKind.toggle),
        );
        expect(player.toggles, 0);
        DesktopMediaKeyDedupe.debugReset();
        c.debugDesktopMediaCommand(
          const DesktopMediaCommand(DesktopMediaCommandKind.toggle),
        );
        expect(player.toggles, 1);
        c.debugDesktopMediaCommand(
          const DesktopMediaCommand(
            DesktopMediaCommandKind.seek,
            position: Duration(seconds: 42),
          ),
        );
        expect(player.seeks.last, const Duration(seconds: 42));
      },
    );
  });

  group('external players (player-12)', () {
    tearDown(DesktopExternalPlayers.debugReset);

    test('copy text carries the needed headers', () {
      expect(
        streamLinkWithHeaders('https://a/b.m3u8', null),
        'https://a/b.m3u8',
      );
      expect(
        streamLinkWithHeaders('https://a/b.m3u8', {
          'Referer': 'https://site/',
          'User-Agent': 'UA',
        }),
        'https://a/b.m3u8\nReferer: https://site/\nUser-Agent: UA',
      );
    });

    test('finds players in PATH, install folders and the registry', () async {
      DesktopExternalPlayers.debugEnvironment = {
        'Path': r'C:\tools;C:\bin',
        'ProgramFiles': r'C:\Program Files',
      };
      final files = {
        r'C:\bin\mpv.exe',
        r'C:\Program Files\VideoLAN\VLC\vlc.exe',
        r'D:\MPC\mpc-hc64.exe',
      };
      DesktopExternalPlayers.debugFileExists = files.contains;
      DesktopExternalPlayers.debugRegistryRead = (key, value) async =>
          key.endsWith(r'MPC-HC\MPC-HC') && value == 'ExePath'
          ? r'D:\MPC\mpc-hc64.exe'
          : null;
      final apps = await DesktopExternalPlayers.detect(refresh: true);
      expect(apps.map((a) => a.label), ['mpv', 'VLC', 'MPC-HC']);
      expect(apps.map((a) => a.exePath), [
        r'C:\bin\mpv.exe',
        r'C:\Program Files\VideoLAN\VLC\vlc.exe',
        r'D:\MPC\mpc-hc64.exe',
      ]);
    });

    test('each player gets the URL plus the headers it supports', () async {
      const headers = {'Referer': 'https://r/', 'User-Agent': 'UA', 'X-T': '1'};
      const mpv = DesktopExternalPlayerApp(
        kind: DesktopExternalPlayerKind.mpv,
        exePath: 'mpv.exe',
      );
      const vlc = DesktopExternalPlayerApp(
        kind: DesktopExternalPlayerKind.vlc,
        exePath: 'vlc.exe',
      );
      const mpc = DesktopExternalPlayerApp(
        kind: DesktopExternalPlayerKind.mpcHc,
        exePath: 'mpc.exe',
      );
      expect(
        DesktopExternalPlayers.argsFor(
          mpv,
          url: 'u',
          headers: headers,
          title: 'Show • Ep',
        ),
        [
          '--force-media-title=Show • Ep',
          '--referrer=https://r/',
          '--user-agent=UA',
          '--http-header-fields-append=X-T: 1',
          'u',
        ],
      );
      expect(DesktopExternalPlayers.argsFor(vlc, url: 'u', headers: headers), [
        'u',
        ':http-referrer=https://r/',
        ':http-user-agent=UA',
      ]);
      expect(DesktopExternalPlayers.argsFor(mpc, url: 'u', headers: headers), [
        'u',
      ]);
      expect(mpv.dropsHeaders(headers), false);
      expect(vlc.dropsHeaders(headers), true);
      expect(mpc.dropsHeaders(const {}), false);
      final started = <String>[];
      DesktopExternalPlayers.debugStart = (exe, args) async {
        started.add(exe);
        return true;
      };
      expect(await DesktopExternalPlayers.launch(vlc, url: 'u'), true);
      expect(started, ['vlc.exe']);
    });
  });

  group('More panel on Windows (player-15)', () {
    setUp(() {
      DesktopShortcuts.debugReset();
      registerDefaultDesktopShortcuts();
    });

    testWidgets('docked panel; sub-options open in place with a back arrow', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => debugShowPlayerMorePanel(
                  context,
                  // The player always passes its mini player action on
                  // Windows; without one the row is left out.
                  onPip: () {},
                  // Like the real decoder menu: a list body in a docked
                  // panel.
                  onDecoder: () => showDesktopPlayerPanel<void>(
                    context,
                    builder: (_) => debugPlayerMenuList('Decoder list', [
                      'Hardware',
                      'Software',
                    ]),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('player-more-panel')), findsOneWidget);
      expect(find.byKey(const ValueKey('more-mini-player')), findsOneWidget);
      expect(find.byKey(const ValueKey('more-always-on-top')), findsOneWidget);

      await tester.tap(find.textContaining('Decoder'));
      await tester.pumpAndSettle();
      // Same panel, no second dialog stacked on top.
      expect(find.text('Decoder list'), findsOneWidget);
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byKey(const ValueKey('player-panel-back')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('player-panel-back')));
      await tester.pumpAndSettle();
      expect(find.text('Decoder list'), findsNothing);
      expect(find.byKey(const ValueKey('more-mini-player')), findsOneWidget);

      // Esc inside a sub-page goes back; Esc on the list closes the panel.
      await tester.tap(find.textContaining('Decoder'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('more-mini-player')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('player-more-panel')), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  });

  // The "Show page" button is gone: the title and episode line in the top
  // bar are the link to the show page now.
  group('clickable show title (playertitle)', () {
    // Lays the title block out in a wide bar, like the real top bar, with a
    // tap counter behind it standing in for the video's tap zones.
    Future<List<String>> pump(
      WidgetTester tester, {
      required bool link,
    }) async {
      final log = <String>[];
      await tester.binding.setSurfaceSize(const Size(1280, 200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => log.add('video'),
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: debugPlayerTopBarTitle(
                        title: 'The Master of Ragnarok',
                        secondaryLine: 'E1',
                        onShowPage: link ? () => log.add('show') : null,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
      return log;
    }

    testWidgets('title and episode line open the show page', (tester) async {
      final log = await pump(tester, link: true);
      expect(find.byKey(const ValueKey('player-show-page')), findsNothing);
      expect(find.text('Show page'), findsNothing);
      await tester.tap(find.text('The Master of Ragnarok'));
      await tester.tap(find.text('E1'));
      expect(log, ['show', 'show']);
      // Both lines carry the tooltip.
      expect(
        find.byWidgetPredicate(
          (w) => w is Tooltip && w.message == 'Open show page',
        ),
        findsNWidgets(2),
      );
      // The hit area hugs the text: the empty bar to its right still
      // reaches the video.
      await tester.tapAt(const Offset(1200, 10));
      expect(log, ['show', 'show', 'video']);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('hand cursor and underline on hover', (tester) async {
      await pump(tester, link: true);
      TextDecoration? deco(String text) =>
          tester.widget<Text>(find.text(text)).style?.decoration;
      expect(deco('The Master of Ragnarok'), TextDecoration.none);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.text('The Master of Ragnarok')));
      await tester.pump();
      // Both lines underline together: they read as one link.
      expect(deco('The Master of Ragnarok'), TextDecoration.underline);
      expect(deco('E1'), TextDecoration.underline);
      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.click,
      );
      await mouse.moveTo(const Offset(1200, 150));
      await tester.pump();
      expect(deco('The Master of Ragnarok'), TextDecoration.none);
      // Let the hover tooltip's timers run out before the test ends.
      await tester.pumpAndSettle(const Duration(seconds: 3));
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('without a show page the title stays inert', (tester) async {
      final log = await pump(tester, link: false);
      await tester.tap(find.text('The Master of Ragnarok'), warnIfMissed: false);
      // The tap falls through to the video, as on phone.
      expect(log, ['video']);
      expect(find.byType(Tooltip), findsNothing);
    });
  });
}
