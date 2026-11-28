import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/desktop_smooth_scroll.dart';

final _mouse = TestPointer(1, PointerDeviceKind.mouse);

Future<void> _notch(WidgetTester tester, Offset at) async {
  await tester.sendEventToBinding(_mouse.hover(at));
  await tester.sendEventToBinding(_mouse.scroll(const Offset(0, 100)));
}

double _offset(WidgetTester tester) =>
    tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels;

void main() {
  final windows = TargetPlatformVariant.only(TargetPlatform.windows);

  test('a fresh stretch is an ease-out cubic, as before', () {
    for (var s = 0.0; s <= 1.0; s += .05) {
      final rest = 1 - s;
      expect(
        desktopGlideStretchValue(s, 3),
        closeTo(1 - rest * rest * rest, 1e-9),
      );
      // Flutter's easeOutCubic (used before) is a close curve fit of it.
      expect(
        desktopGlideStretchValue(s, 3),
        closeTo(Curves.easeOutCubic.transform(s), .05),
      );
    }
  });

  test('every start speed used lands on the target, never past it', () {
    for (final k in [1.0, 1.5, 2.0, 2.5, 3.0]) {
      expect(desktopGlideStretchValue(0, k), 0);
      expect(desktopGlideStretchValue(1, k), closeTo(1, 1e-9));
      expect(desktopGlideStretchSpeed(0, k), closeTo(k, 1e-9));
      expect(desktopGlideStretchSpeed(1, k), closeTo(0, 1e-9));
      var last = 0.0;
      for (var s = 0.01; s <= 1.0; s += .01) {
        final v = desktopGlideStretchValue(s, k);
        expect(v, greaterThanOrEqualTo(last));
        expect(v, lessThanOrEqualTo(1 + 1e-9));
        last = v;
      }
    }
  });

  testWidgets(
    'fast wheeling keeps a steady speed instead of lurching on each notch',
    variant: windows,
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: DesktopWheelGlideScope(
            child: ListView.builder(
              itemExtent: 50,
              itemCount: 1000,
              itemBuilder: (_, i) => Text('row $i'),
            ),
          ),
        ),
      );
      final centre = tester.getCenter(find.byType(Scrollable));
      final positions = <double>[];
      // A fast spin: one notch every three frames (about 20 a second).
      for (var i = 0; i < 8; i++) {
        await _notch(tester, centre);
        for (var f = 0; f < 3; f++) {
          await tester.pump(const Duration(milliseconds: 16));
          positions.add(_offset(tester));
        }
      }
      final steps = [
        for (var i = 1; i < positions.length; i++)
          positions[i] - positions[i - 1],
      ];
      // After the first notches got it going, no frame moves much further
      // than the frame before it: a notch carries the speed on rather than
      // kicking the page back to top speed. (Restarting the ease-out on each
      // notch made the step jump by about 70 percent every third frame.)
      for (var i = 4; i < steps.length; i++) {
        expect(
          steps[i],
          lessThanOrEqualTo(steps[i - 1] * 1.3 + 0.5),
          reason: 'frame $i: ${steps[i - 1]} -> ${steps[i]}',
        );
        expect(steps[i], greaterThan(0));
      }
      await tester.pumpAndSettle();
      expect(_offset(tester), 800);
    },
  );
}
