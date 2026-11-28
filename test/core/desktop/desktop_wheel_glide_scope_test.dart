import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/desktop_smooth_scroll.dart';

/// The app as the window root builds it: the glide scope around a page.
Widget _app(Widget page, {bool reduceMotion = false}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduceMotion),
    child: DesktopWheelGlideScope(child: page),
  ),
);

/// A tall plain list with no controller of its own (the common case).
Widget _plainList({ScrollController? controller}) => ListView.builder(
  controller: controller,
  itemExtent: 50,
  itemCount: 400,
  itemBuilder: (_, i) => Text('row $i'),
);

final _mouse = TestPointer(1, PointerDeviceKind.mouse);

Future<void> _wheel(WidgetTester tester, Offset at, Offset delta) async {
  await tester.sendEventToBinding(_mouse.hover(at));
  await tester.sendEventToBinding(_mouse.scroll(delta));
}

/// The scroll offset of the first scrollable found by [finder].
double _offsetOf(WidgetTester tester, Finder finder) =>
    tester.state<ScrollableState>(finder).position.pixels;

void main() {
  final windows = TargetPlatformVariant.only(TargetPlatform.windows);

  testWidgets(
    'rapid notches flow into one glide that reaches the summed target',
    variant: windows,
    (tester) async {
      await tester.pumpWidget(_app(_plainList()));
      final list = find.byType(Scrollable);
      final centre = tester.getCenter(list);
      final seen = <double>[];
      // Three notches, one every two frames, while the first is still moving.
      for (var i = 0; i < 3; i++) {
        await _wheel(tester, centre, const Offset(0, 100));
        await tester.pump(const Duration(milliseconds: 16));
        seen.add(_offsetOf(tester, list));
        await tester.pump(const Duration(milliseconds: 16));
        seen.add(_offsetOf(tester, list));
      }
      // Not one jump per notch: still short of the total after the notches.
      expect(seen.last, lessThan(300));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        seen.add(_offsetOf(tester, list));
      }
      await tester.pumpAndSettle();
      seen.add(_offsetOf(tester, list));
      expect(seen.last, 300);
      // Every frame moved forward (no still frame when a notch lands, never
      // backwards), so it reads as one continuous slide.
      for (var i = 1; i < seen.length; i++) {
        if (seen[i - 1] < 300) expect(seen[i], greaterThan(seen[i - 1]));
      }
      // The first frame after a notch already moves the page.
      expect(seen.first, greaterThan(0));
    },
  );

  testWidgets(
    'a glide eases out and ends within about a quarter second',
    variant: windows,
    (tester) async {
      await tester.pumpWidget(_app(_plainList()));
      final list = find.byType(Scrollable);
      await _wheel(tester, tester.getCenter(list), const Offset(0, 200));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final early = _offsetOf(tester, list);
      await tester.pump(const Duration(milliseconds: 60));
      final later = _offsetOf(tester, list);
      // Ease-out: the first 60 ms cover more ground than the next 60 ms.
      expect(early, greaterThan(later - early));
      await tester.pump(desktopWheelGlide);
      expect(_offsetOf(tester, list), 200);
    },
  );

  testWidgets(
    'touchpad and fine-step wheels are passed straight through',
    variant: windows,
    (tester) async {
      await tester.pumpWidget(_app(_plainList()));
      final list = find.byType(Scrollable);
      // 5 logical px at the test's 3x display = 15 real px: not a notch.
      await _wheel(tester, tester.getCenter(list), const Offset(0, 5));
      await tester.pump();
      expect(_offsetOf(tester, list), 5);
      expect(desktopWheelIsNotch(_mouse.scroll(const Offset(0, 5)), 3), false);
      expect(desktopWheelIsNotch(_mouse.scroll(const Offset(0, 100)), 3), true);
      const pad = PointerScrollEvent(
        kind: PointerDeviceKind.trackpad,
        scrollDelta: Offset(0, 100),
      );
      expect(desktopWheelIsNotch(pad, 1), false);
    },
  );

  testWidgets(
    'touchpad steps on a smooth controller are not animated either',
    variant: windows,
    (tester) async {
      final controller = DesktopSmoothScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_app(_plainList(controller: controller)));
      await _wheel(
        tester,
        tester.getCenter(find.byType(Scrollable)),
        const Offset(0, 4),
      );
      await tester.pump();
      expect(controller.offset, 4);
    },
  );

  testWidgets('reduced motion jumps straight to the target', variant: windows, (
    tester,
  ) async {
    await tester.pumpWidget(_app(_plainList(), reduceMotion: true));
    final list = find.byType(Scrollable);
    await _wheel(tester, tester.getCenter(list), const Offset(0, 100));
    await tester.pump();
    expect(_offsetOf(tester, list), 100);
  });

  testWidgets(
    'NestedScrollView (show page) glides header and list together',
    variant: windows,
    (tester) async {
      await tester.pumpWidget(
        _app(
          NestedScrollView(
            headerSliverBuilder: (_, _) => const [
              SliverToBoxAdapter(child: SizedBox(height: 300)),
            ],
            body: ListView.builder(
              itemExtent: 50,
              itemCount: 200,
              itemBuilder: (_, i) => Text('episode $i'),
            ),
          ),
        ),
      );
      final outer = find.byType(Scrollable).first;
      final inner = find.byType(Scrollable).last;
      await _wheel(tester, tester.getCenter(inner), const Offset(0, 100));
      await _wheel(tester, tester.getCenter(inner), const Offset(0, 100));
      await _wheel(tester, tester.getCenter(inner), const Offset(0, 200));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      // Moving, but not there in one jump.
      final mid = _offsetOf(tester, outer) + _offsetOf(tester, inner);
      expect(mid, greaterThan(0));
      expect(mid, lessThan(400));
      await tester.pumpAndSettle();
      // The header scrolled away first, then the list took the rest.
      expect(_offsetOf(tester, outer), 300);
      expect(_offsetOf(tester, inner), 100);
      // And back up with the wheel the other way.
      await _wheel(tester, tester.getCenter(inner), const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(_offsetOf(tester, outer) + _offsetOf(tester, inner), 0);
    },
  );

  testWidgets(
    'Shift+wheel glides a horizontal row, a plain wheel scrolls the page',
    variant: windows,
    (tester) async {
      await tester.pumpWidget(
        _app(
          ListView(
            children: [
              SizedBox(
                height: 120,
                child: ListView.builder(
                  key: const Key('row'),
                  scrollDirection: Axis.horizontal,
                  itemExtent: 120,
                  itemCount: 50,
                  itemBuilder: (_, i) => Text('card $i'),
                ),
              ),
              for (var i = 0; i < 60; i++)
                SizedBox(height: 50, child: Text('line $i')),
            ],
          ),
        ),
      );
      final page = find.byType(Scrollable).first;
      final row = find.descendant(
        of: find.byKey(const Key('row')),
        matching: find.byType(Scrollable),
      );
      final overRow = tester.getCenter(find.byKey(const Key('row')));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await _wheel(tester, overRow, const Offset(0, 100));
      await tester.pump();
      expect(_offsetOf(tester, row), greaterThan(0));
      expect(_offsetOf(tester, row), lessThan(100));
      await tester.pumpAndSettle();
      expect(_offsetOf(tester, row), 100);
      expect(_offsetOf(tester, page), 0);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await _wheel(tester, overRow, const Offset(0, 100));
      await tester.pumpAndSettle();
      expect(_offsetOf(tester, page), 100);
      expect(_offsetOf(tester, row), 100);
    },
  );

  testWidgets(
    'a widget with its own wheel handling inside a list still gets it',
    variant: windows,
    (tester) async {
      var own = 0;
      await tester.pumpWidget(
        _app(
          ListView(
            children: [
              Listener(
                onPointerSignal: (event) {
                  GestureBinding.instance.pointerSignalResolver.register(
                    event,
                    (_) => own++,
                  );
                },
                child: const SizedBox(height: 200, child: Text('volume')),
              ),
              for (var i = 0; i < 60; i++)
                SizedBox(height: 50, child: Text('line $i')),
            ],
          ),
        ),
      );
      final list = find.byType(Scrollable);
      await _wheel(
        tester,
        tester.getCenter(find.text('volume')),
        const Offset(0, 100),
      );
      await tester.pumpAndSettle();
      expect(own, 1);
      expect(_offsetOf(tester, list), 0);
    },
  );

  testWidgets(
    'scrolling the other way mid-glide turns back from where the page is',
    variant: windows,
    (tester) async {
      await tester.pumpWidget(_app(_plainList()));
      final list = find.byType(Scrollable);
      final centre = tester.getCenter(list);
      await _wheel(tester, centre, const Offset(0, 300));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final turnedAt = _offsetOf(tester, list);
      await _wheel(tester, centre, const Offset(0, -100));
      await tester.pumpAndSettle();
      expect(_offsetOf(tester, list), closeTo(turnedAt - 100, 1));
    },
  );

  testWidgets('leaving the page mid-glide is safe', variant: windows, (
    tester,
  ) async {
    await tester.pumpWidget(_app(_plainList()));
    await _wheel(
      tester,
      tester.getCenter(find.byType(Scrollable)),
      const Offset(0, 300),
    );
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pumpWidget(_app(const SizedBox()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Android: the same tree still jumps one notch at once',
    variant: TargetPlatformVariant.only(TargetPlatform.android),
    (tester) async {
      await tester.pumpWidget(_app(_plainList()));
      final list = find.byType(Scrollable);
      await _wheel(tester, tester.getCenter(list), const Offset(0, 100));
      await tester.pump();
      expect(_offsetOf(tester, list), 100);
    },
  );
}
