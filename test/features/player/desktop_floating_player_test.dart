// Windows floating mini player: the card above the app takes the live player
// session over from the player page, gives it back on expand, and closes it
// like a normal player exit. No native player: media_kit is faked.
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/playback/resume_store.dart';
import 'package:watch_app/core/playback/title_prefs.dart';
import 'package:watch_app/features/player/desktop_floating_player.dart';
import 'package:watch_app/features/player/mpv_player_pool.dart';
import 'package:watch_app/features/player/player_controller.dart';
import 'package:watch_app/features/player/player_lifecycle.dart';
import 'package:watch_app/features/player/player_screen.dart';

class _Player extends Fake implements mk.Player {
  int toggles = 0;
  int pauses = 0;
  bool disposed = false;

  /// Whether the fake reports itself as playing (the card keeps its
  /// controls up while paused, so hover tests need a playing video).
  bool playing = false;
  @override
  mk.PlatformPlayer? get platform => null;
  @override
  mk.PlayerState get state => mk.PlayerState(playing: playing);
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
  Future<void> playOrPause() async => toggles++;
  @override
  Future<void> pause() async => pauses++;
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async => disposed = true;
}

/// A real session whose close() is counted: closing it is the normal player
/// exit (progress, history, Discord, media overlay, native teardown).
class _Session extends PlayerCubit {
  _Session()
    : super(
        sourceId: 'source',
        episodes: const [Episode(id: '1', title: 'One', url: 'ep-1')],
        resume: ResumeStore(),
        resolveSources: (_) async => const [],
        dio: Dio(),
      );

  int closes = 0;

  /// What happened, in order: the save must finish before the close.
  final steps = <String>[];

  @override
  Future<void> flushProgress() async {
    steps.add('flush start');
    await super.flushProgress();
    // A slower save: it lands a few turns of the event loop later.
    for (var i = 0; i < 3; i++) {
      await Future<void>.value();
    }
    steps.add('flush done');
  }

  @override
  Future<void> close() {
    closes++;
    steps.add('close');
    return super.close();
  }
}

/// A page that starts a new playback: like PlayerScreen, it closes the
/// floating card from initState, while the app is building.
class _NewPlayerPage extends StatefulWidget {
  const _NewPlayerPage();

  @override
  State<_NewPlayerPage> createState() => _NewPlayerPageState();
}

class _NewPlayerPageState extends State<_NewPlayerPage> {
  @override
  void initState() {
    super.initState();
    unawaited(DesktopFloatingPlayer.instance.close());
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Text('new player'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  final players = <_Player>[];
  final host = DesktopFloatingPlayer.instance;
  final navKey = GlobalKey<NavigatorState>();

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('floating_player');
    Hive.init(dir.path);
    await PlaybackPrefs.init();
    await ResumeStore.init();
    await TitlePrefsStore.init();
    await sl.reset();
    sl.registerSingleton<PlaybackPrefs>(PlaybackPrefs());
    sl.registerSingleton<TitlePrefsStore>(TitlePrefsStore());
    players.clear();
    sl.registerSingleton<MpvPlayerPool>(
      MpvPlayerPool(
        createPlayer: (_) {
          final p = _Player();
          players.add(p);
          return p;
        },
      ),
    );
    host.debugReset();
    host.navigatorKey = navKey;
    debugFloatingVideoBuilder = (_) =>
        const ColoredBox(key: ValueKey('fake-video'), color: Colors.black);
  });

  tearDown(() async {
    host.debugReset();
    debugFloatingVideoBuilder = null;
    await sl.reset();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  // The app shape from main.dart: the Navigator, the card layer above it,
  // and the Space handler around both.
  Widget app() => MaterialApp(
    navigatorKey: navKey,
    builder: (_, child) => DesktopFloatingPlayerKeys(
      child: Stack(
        children: [
          ?child,
          const Positioned.fill(child: DesktopFloatingPlayerLayer()),
        ],
      ),
    ),
    home: const Scaffold(body: Text('home')),
  );

  FloatingPlayback playback(
    _Session cubit, {
    PlayerRouteTeardownLease? lease,
    Widget Function(FloatingPlayback)? reopen,
  }) => FloatingPlayback(
    cubit: cubit,
    reopen:
        reopen ??
        (p) => Scaffold(
          body: Text('reopened', key: ValueKey(identityHashCode(p.cubit))),
        ),
    layout: PlayerPresentation.fullscreen,
    lease: lease,
    title: 'Show',
  );

  /// Stands in for the player page: its mini player button hands the
  /// session to the card and closes the page, like _popOutToFloatingPlayer.
  Future<void> openPage(WidgetTester tester, FloatingPlayback p) async {
    unawaited(
      navKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () {
                unawaited(host.adopt(p));
                Navigator.of(context).pop();
              },
              child: const Text('mini player'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  final windows = TargetPlatformVariant.only(TargetPlatform.windows);

  testWidgets(
    'the mini player button pops the video into the floating card; the '
    'page closes but the player keeps running',
    (tester) async {
      await tester.pumpWidget(app());
      final cubit = _Session();
      await openPage(tester, playback(cubit));
      expect(find.byKey(const ValueKey('floating-player-card')), findsNothing);

      await tester.tap(find.text('mini player'));
      await tester.pumpAndSettle();

      expect(find.text('mini player'), findsNothing); // page closed
      expect(find.text('home'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('floating-player-card')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('fake-video')), findsOneWidget);
      expect(host.isActive, isTrue);
      expect(cubit.isClosed, isFalse);
      expect(cubit.closes, 0);
      expect(cubit.player, same(players.single));
      expect(players.single.disposed, isFalse);
    },
    variant: windows,
  );

  testWidgets(
    'expand reopens the player page with the same session, not a new one',
    (tester) async {
      await tester.pumpWidget(app());
      final cubit = _Session();
      final lease = playerRouteTeardownBarrier.acquire();
      FloatingPlayback? reopenedWith;
      await host.adopt(
        playback(
          cubit,
          lease: lease,
          reopen: (p) {
            reopenedWith = p;
            return const Scaffold(body: Text('reopened'));
          },
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('floating-player-expand')));
      await tester.pumpAndSettle();

      expect(find.text('reopened'), findsOneWidget);
      expect(find.byKey(const ValueKey('floating-player-card')), findsNothing);
      expect(host.isActive, isFalse);
      expect(reopenedWith!.cubit, same(cubit));
      expect(reopenedWith!.layout, PlayerPresentation.fullscreen);
      expect(cubit.closes, 0);
      expect(players.single.disposed, isFalse);
      // The trailer lease moves on with the playback to the new page.
      expect(reopenedWith!.takeLease(), same(lease));
      lease.release();
    },
    variant: windows,
  );

  testWidgets(
    'close stops the video through the normal player exit and frees it',
    (tester) async {
      await tester.pumpWidget(app());
      final cubit = _Session();
      final lease = playerRouteTeardownBarrier.acquire();
      await host.adopt(playback(cubit, lease: lease));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('floating-player-close')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('floating-player-card')), findsNothing);
      expect(host.isActive, isFalse);
      // PlayerCubit.close() is what saves progress and history and ends
      // Discord / the media overlay on every normal player exit.
      expect(cubit.closes, 1);
      expect(cubit.isClosed, isTrue);
      await tester.runAsync(() => cubit.nativeTeardown);
      expect(players.single.disposed, isTrue);
      // Detail trailers may play again once the player is gone.
      await tester.runAsync(
        () => playerRouteTeardownBarrier.waitUntilIdle().timeout(
          const Duration(seconds: 2),
        ),
      );
    },
    variant: windows,
  );

  testWidgets(
    'starting a different playback replaces the floating one cleanly',
    (tester) async {
      await tester.pumpWidget(app());
      final first = _Session();
      await host.adopt(playback(first));
      await tester.pumpAndSettle();

      final second = _Session();
      await host.adopt(playback(second));
      await tester.pumpAndSettle();

      expect(first.closes, 1); // saved and stopped first
      expect(second.closes, 0);
      expect(host.current!.cubit, same(second));
      expect(
        find.byKey(const ValueKey('floating-player-card')),
        findsOneWidget,
      );

      // A new player page (not an expand) closes it the same way.
      await host.close();
      expect(second.closes, 1);
    },
    variant: windows,
  );

  testWidgets('Space toggles the floating video, but not while typing', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    final cubit = _Session();
    await host.adopt(playback(cubit));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(players.single.toggles, 1);

    // Esc does not close the card.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(host.isActive, isTrue);

    final field = FocusNode();
    addTearDown(field.dispose);
    unawaited(
      navKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) =>
              Scaffold(body: TextField(focusNode: field, autofocus: true)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(field.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(players.single.toggles, 1);
  }, variant: windows);

  testWidgets('the card snaps to the corner it is dragged to', (tester) async {
    await tester.pumpWidget(app());
    await host.adopt(playback(_Session()));
    await tester.pumpAndSettle();
    expect(host.corner, FloatingCorner.bottomRight);

    final card = find.byKey(const ValueKey('floating-player-card'));
    final start = tester.getCenter(card);
    await tester.dragFrom(start, const Offset(-600, -500));
    await tester.pumpAndSettle();
    expect(host.corner, FloatingCorner.topLeft);
    expect(tester.getTopLeft(card), const Offset(16, 16));
  }, variant: windows);

  // How visible the card's controls are right now (0 hidden, 1 shown).
  double controlsOpacity(WidgetTester tester) => tester
      .widget<AnimatedOpacity>(
        find.ancestor(
          of: find.byKey(const ValueKey('floating-player-expand')),
          matching: find.byType(AnimatedOpacity),
        ),
      )
      .opacity;

  testWidgets(
    'hovering the card shows the controls; they hide 2 s after the mouse '
    'stops or right away when it leaves, and the buttons still click',
    (tester) async {
      await tester.pumpWidget(app());
      final cubit = _Session();
      // A playing video: paused, the controls would stay up anyway.
      (cubit.player as _Player).playing = true;
      await host.adopt(playback(cubit));
      await tester.pumpAndSettle();
      expect(controlsOpacity(tester), 0);

      final card = find.byKey(const ValueKey('floating-player-card'));
      final center = tester.getCenter(card);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await tester.pump();

      // Mouse over the card: the controls come up.
      await mouse.moveTo(center);
      await tester.pump();
      expect(controlsOpacity(tester), 1);

      // Moving keeps them up past 2 s: each move restarts the hide timer.
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(seconds: 1));
        await mouse.moveTo(center + Offset(10.0 * (i + 1), 0));
        await tester.pump();
      }
      expect(controlsOpacity(tester), 1);

      // The mouse stays still: they hide about 2 s later.
      await tester.pump(const Duration(milliseconds: 1900));
      expect(controlsOpacity(tester), 1);
      await tester.pump(const Duration(milliseconds: 200));
      expect(controlsOpacity(tester), 0);

      // Moving again brings them back; leaving the card hides them at once.
      await mouse.moveTo(center);
      await tester.pump();
      expect(controlsOpacity(tester), 1);
      await mouse.moveTo(const Offset(5, 5));
      await tester.pump();
      expect(controlsOpacity(tester), 0);

      // A plain click (touch, no hover) on the card shows them as well.
      await tester.tapAt(center);
      await tester.pump();
      expect(controlsOpacity(tester), 1);
      await tester.pump(const Duration(milliseconds: 2100));
      expect(controlsOpacity(tester), 0);

      // Hover, then click the expand button with the mouse: it works.
      await mouse.moveTo(center);
      await tester.pump();
      final expand = tester.getCenter(
        find.byKey(const ValueKey('floating-player-expand')),
      );
      await mouse.moveTo(expand);
      await tester.pump();
      await mouse.down(expand);
      await mouse.up();
      await tester.pumpAndSettle();
      expect(find.text('reopened'), findsOneWidget);
      expect(host.isActive, isFalse);
      expect(cubit.closes, 0);
      unawaited(cubit.close());
    },
    variant: windows,
  );

  test('corner maths', () {
    const area = Size(1280, 720);
    final card = floatingCardSize(area);
    expect(card, const Size(400, 225));
    expect(
      floatingCardOrigin(FloatingCorner.bottomRight, area, card),
      const Offset(1280 - 400 - 16, 720 - 225 - 16),
    );
    expect(
      nearestFloatingCorner(const Offset(700, 50), area, card),
      FloatingCorner.topRight,
    );
    expect(
      nearestFloatingCorner(const Offset(10, 500), area, card),
      FloatingCorner.bottomLeft,
    );
  });

  test('expand rebuilds the same player page around the floating session', () {
    final cubit = _Session();
    final p = playback(cubit);
    final page = PlayerScreen(
      sourceId: 'source',
      resume: ResumeStore(),
      resolveSources: (_) async => const [],
      episodes: const [Episode(id: '1', title: 'One', url: 'ep-1')],
      showTitle: 'Show',
      tmdbId: 7,
      joinRoomCode: 'ROOM',
    );
    final again = page.adopting(p);
    expect(again.adopt, same(p));
    expect(again.sourceId, 'source');
    expect(again.showTitle, 'Show');
    expect(again.tmdbId, 7);
    expect(again.resolveSources, same(page.resolveSources));
    // The room was already joined by the first page.
    expect(again.joinRoomCode, isNull);
    expect(page.adopt, isNull);
    unawaited(cubit.close());
  });

  testWidgets(
    'a new player page closing the card from initState reports no error '
    'and the card goes away',
    (tester) async {
      await tester.pumpWidget(app());
      final cubit = _Session();
      await host.adopt(playback(cubit));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('floating-player-card')),
        findsOneWidget,
      );

      unawaited(
        navKey.currentState!.push(
          MaterialPageRoute<void>(builder: (_) => const _NewPlayerPage()),
        ),
      );
      await tester.pumpAndSettle();

      // No "setState() called during build" from the card layer.
      expect(tester.takeException(), isNull);
      expect(find.text('new player'), findsOneWidget);
      expect(find.byKey(const ValueKey('floating-player-card')), findsNothing);
      expect(host.isActive, isFalse);
      expect(cubit.closes, 1);
    },
    variant: windows,
  );

  testWidgets(
    'closing waits until progress is saved before the session closes',
    (tester) async {
      await tester.pumpWidget(app());
      final cubit = _Session();
      await host.adopt(playback(cubit));
      await tester.pumpAndSettle();
      final pausesBefore = players.single.pauses;

      await closeFloatingPlayerBeforeProfileSwitch();

      // Sound stopped first, then the save finished, then the close: a
      // profile switch after this await cannot catch the save half done.
      expect(players.single.pauses, greaterThan(pausesBefore));
      expect(cubit.steps, ['flush start', 'flush done', 'close']);
      expect(cubit.closes, 1);
      await tester.pumpAndSettle();
    },
    variant: windows,
  );

  testWidgets(
    'expand: a page that goes away before taking the video over closes it',
    (tester) async {
      await tester.pumpWidget(app());
      final cubit = _Session();
      await host.adopt(playback(cubit));
      await tester.pumpAndSettle();

      expect(host.expand(), isTrue);
      await tester.pumpAndSettle();
      // The reopened page never marked the playback as taken over.
      navKey.currentState!.pop();
      await tester.pumpAndSettle();

      expect(cubit.closes, 1);
      expect(cubit.isClosed, isTrue);
    },
    variant: windows,
  );

  testWidgets(
    'expand: a page that took the video over keeps it when it closes',
    (tester) async {
      await tester.pumpWidget(app());
      final cubit = _Session();
      await host.adopt(
        playback(
          cubit,
          reopen: (p) {
            p.adopted = true; // what PlayerScreen does in _startSession
            return const Scaffold(body: Text('reopened'));
          },
        ),
      );
      await tester.pumpAndSettle();

      expect(host.expand(), isTrue);
      await tester.pumpAndSettle();
      navKey.currentState!.pop();
      await tester.pumpAndSettle();

      // The page owns it (its own dispose closes it); the manager did not.
      expect(cubit.closes, 0);
      unawaited(cubit.close());
    },
    variant: windows,
  );

  testWidgets('the trailer page pauses the floating video but leaves it open', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    final cubit = _Session();
    await host.adopt(playback(cubit));
    await tester.pumpAndSettle();
    final before = players.single.pauses;

    pauseFloatingPlayerForOwnSound();

    expect(players.single.pauses, before + 1);
    expect(host.isActive, isTrue);
    expect(cubit.closes, 0);
    await host.close();
  }, variant: windows);

  testWidgets('Android: the trailer page leaves other playback alone', (
    tester,
  ) async {
    final cubit = _Session();
    await host.adopt(playback(cubit));
    final before = players.single.pauses;
    pauseFloatingPlayerForOwnSound();
    expect(players.single.pauses, before);
    await host.close();
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('Android: nothing floats and Space is left alone', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    // Even a session handed over by mistake draws nothing off Windows.
    final cubit = _Session();
    await host.adopt(playback(cubit));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('floating-player-card')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(players.every((p) => p.toggles == 0), isTrue);
    await host.close();
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
