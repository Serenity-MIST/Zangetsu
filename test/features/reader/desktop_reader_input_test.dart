import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/reader/desktop_reader_input.dart';

void main() {
  testWidgets(
    'arrow keys follow live reading direction and vertical scrolling',
    (tester) async {
      final steps = <bool>[];
      final scrolls = <double>[];
      var direction = 'ltr';
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return DesktopReaderInput(
                direction: direction,
                onVerticalScroll: scrolls.add,
                onPageStep: steps.add,
                builder: (_, _) => const SizedBox.expand(),
              );
            },
          ),
        ),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(steps, [true, false]);
      update(() => direction = 'rtl');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(steps, [true, false, true, false]);
      update(() => direction = 'vertical');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      expect(scrolls.first, greaterThan(0));
      expect(scrolls.last, -scrolls.first);
    },
  );

  testWidgets('edge controls appear independently and hide after leaving', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DesktopReaderInput(
          direction: 'ltr',
          onVerticalScroll: (_) {},
          onPageStep: (_) {},
          builder: (top, bottom) =>
              SizedBox.expand(child: Text('$top/$bottom')),
        ),
      ),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(400, 300));
    await mouse.moveTo(const Offset(400, 20));
    await tester.pump();
    expect(find.text('true/false'), findsOneWidget);
    await mouse.moveTo(const Offset(400, 580));
    await tester.pump();
    expect(find.text('false/true'), findsOneWidget);
    await mouse.moveTo(const Offset(400, 300));
    await tester.pump(const Duration(milliseconds: 650));
    expect(find.text('false/false'), findsOneWidget);
    await mouse.removePointer();
  });

  testWidgets('wheel advances paged reading and scrolls vertical reading', (
    tester,
  ) async {
    final steps = <bool>[];
    final scrolls = <double>[];
    Future<void> mount(String direction) async {
      await tester.pumpWidget(
        MaterialApp(
          home: DesktopReaderInput(
            direction: direction,
            onVerticalScroll: scrolls.add,
            onPageStep: steps.add,
            builder: (_, _) => const SizedBox.expand(),
          ),
        ),
      );
    }

    void wheel(Offset delta, int ms) => tester.binding.handlePointerEvent(
      PointerScrollEvent(
        position: const Offset(400, 300),
        scrollDelta: delta,
        timeStamp: Duration(milliseconds: ms),
        kind: PointerDeviceKind.mouse,
      ),
    );
    await mount('ltr');
    wheel(const Offset(0, 100), 1000);
    wheel(const Offset(0, -100), 1200);
    expect(steps, [true, false]);
    await mount('rtl');
    wheel(const Offset(100, 0), 1400);
    expect(steps.last, false);
    await mount('vertical');
    wheel(const Offset(0, 120), 1600);
    expect(scrolls, [120]);
  });
}
