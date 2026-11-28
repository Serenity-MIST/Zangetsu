import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/desktop_smooth_scroll.dart';
import 'package:watch_app/core/desktop/desktop_window.dart';

/// Checks that the real window root (DesktopWindow) carries the eased wheel
/// glide, so a plain list anywhere in the app glides instead of jumping one
/// notch at a time. If a Flutter upgrade breaks how the glide finds a list's
/// wheel listener, this test fails instead of the jump quietly coming back.
void main() {
  const channel = MethodChannel('com.spyou.zangetsu/window');
  final mouse = TestPointer(1, PointerDeviceKind.mouse);

  /// The app as main.dart wraps it: DesktopWindow around a plain list.
  Future<void> pumpWindow(WidgetTester tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'isFullscreen' ? false : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: DesktopWindow(
          child: Scaffold(
            body: ListView.builder(
              itemExtent: 50,
              itemCount: 400,
              itemBuilder: (_, i) => Text('row $i'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  double offsetOf(WidgetTester tester) =>
      tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels;

  testWidgets(
    'Windows: the window root makes a plain list glide to the target',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      await pumpWindow(tester);
      expect(find.byType(DesktopWheelGlideScope), findsOneWidget);
      final centre = tester.getCenter(find.byType(Scrollable));
      await tester.sendEventToBinding(mouse.hover(centre));
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 200)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      // Moving, but not yet the whole notch: a glide, not a jump.
      final early = offsetOf(tester);
      expect(early, greaterThan(0));
      expect(early, lessThan(200));
      await tester.pumpAndSettle();
      expect(offsetOf(tester), 200);
    },
    // DesktopWindow only builds its window wrappers on a Windows machine.
    skip: !Platform.isWindows,
  );

  testWidgets(
    'Android: a plain list still jumps the whole notch at once',
    variant: TargetPlatformVariant.only(TargetPlatform.android),
    (tester) async {
      await pumpWindow(tester);
      final centre = tester.getCenter(find.byType(Scrollable));
      await tester.sendEventToBinding(mouse.hover(centre));
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 200)));
      await tester.pump();
      expect(offsetOf(tester), 200);
    },
  );
}
