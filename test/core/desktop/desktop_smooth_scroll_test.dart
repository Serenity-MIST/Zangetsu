import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/desktop_smooth_scroll.dart';

/// A tall list driven by [controller], wheel-scrolled at its centre.
Widget _list(ScrollController controller, {bool reduceMotion = false}) =>
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: ListView.builder(
          controller: controller,
          itemExtent: 50,
          itemCount: 200,
          itemBuilder: (_, i) => Text('row $i'),
        ),
      ),
    );

Future<void> _wheel(WidgetTester tester, double dy) async {
  final centre = tester.getCenter(find.byType(ListView));
  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(pointer.hover(centre));
  await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
}

void main() {
  testWidgets(
    'Windows wheel glides and notches add up to one target',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      final controller = DesktopSmoothScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_list(controller));
      await _wheel(tester, 100);
      await tester.pump();
      // Not there in one jump: the first frame of the glide is short of it.
      expect(controller.offset, lessThan(100));
      await _wheel(tester, 100);
      await tester.pumpAndSettle();
      // Two notches during one glide land on the combined target.
      expect(controller.offset, 200);
    },
  );

  testWidgets(
    'hover and taps keep working while a wheel glide runs',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      final controller = DesktopSmoothScrollController();
      addTearDown(controller.dispose);
      var exits = 0;
      var taps = 0;
      // Every row is one big hover-and-tap target, so the mouse stays over
      // one of them while the list moves under it.
      await tester.pumpWidget(
        MaterialApp(
          home: ListView.builder(
            controller: controller,
            itemExtent: 50,
            itemCount: 200,
            itemBuilder: (_, i) => MouseRegion(
              onExit: (_) => exits++,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => taps++,
                child: Text('row $i'),
              ),
            ),
          ),
        ),
      );
      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      // Park the mouse well inside a row so a 10 px glide keeps it there.
      final spot = tester.getTopLeft(find.text('row 4')) + const Offset(5, 20);
      await tester.sendEventToBinding(mouse.hover(spot));
      await tester.pump();
      exits = 0;
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 10)));
      // The first frame starts the glide clock; the second is 50 ms in.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      // Mid-glide: the page is moving and the pointer is not ignored.
      expect(controller.offset, greaterThan(0));
      expect(controller.offset, lessThan(10));
      expect(exits, 0);
      await tester.sendEventToBinding(mouse.down(spot));
      await tester.sendEventToBinding(mouse.up());
      await tester.pump();
      expect(taps, 1);
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'reduced motion jumps straight to the target',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      final controller = DesktopSmoothScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_list(controller, reduceMotion: true));
      await _wheel(tester, 100);
      await tester.pump();
      expect(controller.offset, 100);
    },
  );

  testWidgets(
    'the glide stops at the end of the list',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      final controller = DesktopSmoothScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_list(controller));
      final max = controller.position.maxScrollExtent;
      for (var i = 0; i < 5; i++) {
        await _wheel(tester, max);
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();
      expect(controller.offset, max);
    },
  );

  testWidgets(
    'a plain controller off Windows still jumps per notch',
    variant: TargetPlatformVariant.only(TargetPlatform.android),
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_list(controller));
      await _wheel(tester, 100);
      await tester.pump();
      expect(controller.offset, 100);
    },
  );

  testWidgets(
    'DesktopSmoothScroll gives no controller off Windows',
    variant: TargetPlatformVariant.only(TargetPlatform.android),
    (tester) async {
      ScrollController? given;
      await tester.pumpWidget(
        MaterialApp(
          home: DesktopSmoothScroll(
            builder: (context, controller) {
              given = controller;
              return ListView(controller: controller);
            },
          ),
        ),
      );
      expect(given, isNull);
    },
  );
}
