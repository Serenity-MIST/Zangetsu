// Windows seek bar: the time under the mouse shows in a small bubble, and
// the theater watch page can drop the elapsed / total chip (it prints the
// time in its own transport row). Phone keeps the bar as it was.
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' as media;
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/features/player/player_controller.dart';
import 'package:watch_app/features/player/player_screen.dart';

/// No skip marks, so only the buffered track and the thumb are drawn.
class _Prefs extends PlaybackPrefs {
  @override
  bool get skipIntro => false;
}

class _Streams implements media.PlayerStream {
  @override
  Stream<Duration> get position => const Stream.empty();
  @override
  Stream<Duration> get buffer => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Player implements media.Player {
  @override
  final stream = _Streams();
  @override
  final state = const media.PlayerState(position: Duration(seconds: 20));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Records the seek so the test can see the bar goes through the cubit.
class _Controller implements PlayerCubit {
  @override
  final player = _Player();
  @override
  String? get previewUri => null;
  Duration? sought;
  @override
  void seekTo(Duration value) => sought = value;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _bar(_Controller c, {bool showTime = true}) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: 414, // 400px of track plus the slider's 7px side insets
        child: PlayerSeekBar(
          controller: c,
          duration: const Duration(seconds: 100),
          onInteract: () {},
          showTime: showTime,
        ),
      ),
    ),
  ),
);

void main() {
  setUp(() => sl.registerSingleton<PlaybackPrefs>(_Prefs()));
  tearDown(() => sl.reset());

  testWidgets(
    'Windows: hovering the bar shows the time under the mouse',
    (tester) async {
      await tester.pumpWidget(_bar(_Controller()));
      await tester.pump();
      final slider = tester.getRect(find.byType(Slider));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      // Three quarters along the track: 75 of 100 seconds.
      await mouse.moveTo(Offset(slider.left + 7 + 300, slider.center.dy));
      await tester.pump();
      expect(find.byKey(const ValueKey('seek-hover-time')), findsOneWidget);
      expect(find.text('01:15'), findsOneWidget);
      // Leaving the bar hides it again.
      await mouse.moveTo(Offset(slider.center.dx, slider.top - 200));
      await tester.pump();
      expect(find.byKey(const ValueKey('seek-hover-time')), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('phone never shows a hover bubble', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.pumpWidget(_bar(_Controller()));
    await tester.pump();
    final slider = tester.getRect(find.byType(Slider));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(slider.center);
    await tester.pump();
    expect(find.byKey(const ValueKey('seek-hover-time')), findsNothing);
    await mouse.removePointer();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('the watch page can drop the elapsed / total chip', (
    tester,
  ) async {
    await tester.pumpWidget(_bar(_Controller(), showTime: false));
    await tester.pump();
    expect(find.text('00:20 / 01:40'), findsNothing);
    await tester.pumpWidget(_bar(_Controller()));
    await tester.pump();
    expect(find.text('00:20 / 01:40'), findsOneWidget);
  });

  testWidgets('releasing a drag seeks through the cubit', (tester) async {
    final c = _Controller();
    await tester.pumpWidget(_bar(c, showTime: false));
    await tester.pump();
    final slider = tester.getRect(find.byType(Slider));
    await tester.tapAt(Offset(slider.left + 7 + 100, slider.center.dy));
    await tester.pump();
    // A quarter along: about 25s, sent through PlayerCubit.seekTo.
    expect(c.sought, isNotNull);
    expect(c.sought!.inSeconds, inInclusiveRange(23, 27));
  });
}
