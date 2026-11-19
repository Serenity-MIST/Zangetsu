import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/reader/desktop_page_scroller.dart';
import 'package:watch_app/features/reader/desktop_reader_input.dart';

/// A page taller than the 600px test window inside the real
/// DesktopReaderInput, which counts the page turns the wheel falls through to.
class _Harness {
  final steps = <bool>[];
  DesktopPageScrollerState? scroller;

  Widget build({double pageHeight = 2000, bool startAtEnd = false}) =>
      MaterialApp(
        home: Scaffold(
          body: DesktopReaderInput(
            direction: 'ltr',
            onVerticalScroll: (_) {},
            onPageStep: steps.add,
            builder: (_, _) => DesktopPageScroller(
              startAtEnd: startAtEnd,
              onAttach: (s) => scroller = s,
              child: SizedBox(
                key: const ValueKey('tall-page'),
                width: double.infinity,
                height: pageHeight,
                child: const ColoredBox(color: Colors.white),
              ),
            ),
          ),
        ),
      );
}

void main() {
  /// One mouse-wheel notch at [ms] on the fake event clock.
  Future<void> wheel(WidgetTester tester, double dy, int ms) async {
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    final at = tester.getCenter(find.byType(DesktopPageScroller));
    await tester.sendEventToBinding(
      pointer.hover(at, timeStamp: Duration(milliseconds: ms)),
    );
    await tester.sendEventToBinding(
      pointer.scroll(Offset(0, dy), timeStamp: Duration(milliseconds: ms)),
    );
    await tester.pump();
  }

  // Every test runs as a Windows target; the variant resets it afterwards.
  final windows = TargetPlatformVariant.only(TargetPlatform.windows);

  testWidgets('the wheel scrolls a tall page before it can turn it', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final h = _Harness();
    await tester.pumpWidget(h.build());

    await wheel(tester, 400, 0);
    expect(h.scroller!.vertical.offset, 400);
    expect(h.steps, isEmpty, reason: 'the page scrolled, nothing turned');

    // Run to the bottom edge (2000 - 600 = 1400).
    for (var i = 1; i <= 3; i++) {
      await wheel(tester, 400, i * 100);
    }
    expect(h.scroller!.vertical.offset, 1400);
    expect(h.steps, isEmpty);

    // A fast flick that keeps spinning is held at the bottom of the page.
    await wheel(tester, 400, 400);
    await wheel(tester, 400, 500);
    expect(h.steps, isEmpty, reason: 'wheel has not rested at the edge');

    // Resting at the edge, the next notch turns the page forward.
    await wheel(tester, 400, 1200);
    expect(h.steps, [true]);
  }, variant: windows);

  testWidgets('a page that fits turns on the first wheel notch', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final h = _Harness();
    await tester.pumpWidget(h.build(pageHeight: 300));
    await wheel(tester, 120, 0);
    expect(h.steps, [true]);
  }, variant: windows);

  testWidgets('small high-resolution wheel steps add up to a page turn', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final h = _Harness();
    await tester.pumpWidget(h.build());
    // Rest at the bottom edge first.
    h.scroller!.jumpToEdge(end: true);
    await tester.pump();
    // 20px steps 40ms apart: each is below the reader's 32px threshold, so
    // they must keep flowing to the reader once the edge has been released.
    for (var i = 0; i < 4; i++) {
      await wheel(tester, 20, 1000 + i * 40);
    }
    expect(h.steps, [true]);
  }, variant: windows);

  testWidgets('wheel up at the top of a page turns back', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final h = _Harness();
    await tester.pumpWidget(h.build());
    await wheel(tester, -120, 0);
    expect(h.steps, [false]);
  }, variant: windows);

  testWidgets('a mouse drag pans the page', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final h = _Harness();
    await tester.pumpWidget(h.build());
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(DesktopPageScroller)),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, -300));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(h.scroller!.vertical.offset, greaterThan(200));
    expect(h.steps, isEmpty);
  }, variant: windows);

  testWidgets('keyboard helpers stop at the edges', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final h = _Harness();
    await tester.pumpWidget(h.build());
    final s = h.scroller!;
    expect(s.canScrollUp, isFalse);
    expect(s.scrollBy(-80), isFalse, reason: 'already at the top');
    expect(s.scrollBy(500), isTrue);
    expect(s.vertical.offset, 500);
    expect(s.jumpToEdge(end: true), isTrue);
    expect(s.vertical.offset, 1400);
    expect(s.scrollBy(80), isFalse, reason: 'bottom reached: caller turns');
    expect(s.jumpToEdge(end: false), isTrue);
    expect(s.vertical.offset, 0);
  }, variant: windows);

  testWidgets('a page reached by stepping back opens at its bottom', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final h = _Harness();
    await tester.pumpWidget(h.build(startAtEnd: true));
    await tester.pump();
    expect(h.scroller!.vertical.offset, 1400);
  }, variant: windows);

  testWidgets('the key scope sees keys first and passes the rest up', (
    tester,
  ) async {
    final seen = <LogicalKeyboardKey>[];
    final steps = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: DesktopReaderInput(
          direction: 'ltr',
          onVerticalScroll: (_) {},
          onPageStep: steps.add,
          builder: (_, _) => DesktopReaderKeyScope(
            onKey: (event) {
              seen.add(event.logicalKey);
              return event.logicalKey == LogicalKeyboardKey.space
                  ? KeyEventResult.handled
                  : KeyEventResult.ignored;
            },
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(seen, [LogicalKeyboardKey.space, LogicalKeyboardKey.arrowRight]);
    // Right arrow was ignored by the scope and still turned the page.
    expect(steps, [true]);
  }, variant: windows);

  testWidgets('reader panels are a side panel on Windows, a sheet on phones', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) {
            ctx = c;
            return const SizedBox.expand();
          },
        ),
      ),
    );
    showReaderPanel<void>(
      context: ctx,
      builder: (_) => const SizedBox(height: 200, child: Text('panel body')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reader-desktop-panel')), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    final rect = tester.getRect(
      find.byKey(const ValueKey('reader-desktop-panel')),
    );
    expect(rect.width, 460);
    expect(rect.right, lessThanOrEqualTo(1280));
    // A click on the page side closes it.
    await tester.tapAt(const Offset(100, 360));
    await tester.pumpAndSettle();
    expect(find.text('panel body'), findsNothing);

    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    showReaderPanel<void>(
      context: ctx,
      builder: (_) => const SizedBox(height: 200, child: Text('panel body')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-desktop-panel')), findsNothing);
  }, variant: windows);

  // reader-3 B: keyboard scrolling glides, and presses during a glide add up
  // to the full distance instead of restarting from where the glide was.
  testWidgets('desktopAnimatedScrollBy glides and accumulates', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ListView(
          controller: controller,
          children: const [SizedBox(height: 5000)],
        ),
      ),
    );
    desktopAnimatedScrollBy(controller, kDesktopArrowScrollStep);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    // Mid-glide: moving but not there yet.
    expect(controller.offset, greaterThan(0));
    expect(controller.offset, lessThan(kDesktopArrowScrollStep));
    desktopAnimatedScrollBy(controller, kDesktopArrowScrollStep);
    await tester.pumpAndSettle();
    expect(controller.offset, 2 * kDesktopArrowScrollStep);
    // Clamped at the top.
    desktopAnimatedScrollBy(controller, -10000);
    await tester.pumpAndSettle();
    expect(controller.offset, 0);
  });

  // The tall-page scroller can glide too (manga paged arrows).
  testWidgets('DesktopPageScrollerState.scrollBy can animate', (tester) async {
    final harness = _Harness();
    await tester.pumpWidget(harness.build());
    await tester.pump();
    expect(harness.scroller!.scrollBy(100, animate: true), isTrue);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(harness.scroller!.vertical.offset, lessThan(100));
    await tester.pumpAndSettle();
    expect(harness.scroller!.vertical.offset, 100);
  });
}
