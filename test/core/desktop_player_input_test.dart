import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/desktop_player_input.dart';

void main() {
  testWidgets('desktop keys and mouse buttons dispatch player actions', (
    tester,
  ) async {
    var play = 0, back = 0, seek = 0, mute = 0;
    var volume = 0.0;
    await tester.pumpWidget(
      MaterialApp(
        home: DesktopPlayerInput(
          onPlayPause: () => play++,
          onBack: () => back++,
          onMute: () => mute++,
          onSeek: (value) => seek += value,
          onVolume: (value) => volume += value,
          child: const Scaffold(body: SizedBox.expand()),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    expect(play, 1);
    expect(seek, 10);
    expect(volume, 5);
    expect(mute, 1);
    final mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kBackMouseButton,
    );
    await mouse.down(const Offset(100, 100));
    await mouse.up();
    expect(back, 1);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: const Offset(100, 100),
        scrollDelta: const Offset(0, -120),
      ),
    );
    expect(volume, 10);
    var fullscreen = true;
    const channel = MethodChannel('com.spyou.zangetsu/window');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      _,
    ) async {
      final exited = fullscreen;
      fullscreen = false;
      return exited;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(back, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(back, 2);
  });
}
