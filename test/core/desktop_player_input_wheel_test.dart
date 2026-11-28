// player-13: DesktopPlayerInput.wheelVolume turns the whole-screen wheel
// volume off so the Windows player can handle the wheel over the video only.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/desktop_player_input.dart';

void main() {
  Future<double> wheel(WidgetTester tester, {required bool wheelVolume}) async {
    var volume = 0.0;
    await tester.pumpWidget(
      MaterialApp(
        home: DesktopPlayerInput(
          wheelVolume: wheelVolume,
          onPlayPause: () {},
          onBack: () {},
          onMute: () {},
          onSeek: (_) {},
          onVolume: (v) => volume += v,
          child: const Scaffold(body: SizedBox.expand()),
        ),
      ),
    );
    await tester.pump();
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: const Offset(100, 100),
        scrollDelta: const Offset(0, -120),
      ),
    );
    return volume;
  }

  testWidgets('wheel changes volume by default', (tester) async {
    expect(await wheel(tester, wheelVolume: true), 5);
  });

  testWidgets('wheelVolume: false leaves the wheel alone', (tester) async {
    expect(await wheel(tester, wheelVolume: false), 0);
  });
}
