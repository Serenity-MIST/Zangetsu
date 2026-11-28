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

  testWidgets(
    'Contain-fit PageView never drifts sideways on tilt or Shift+wheel',
    (tester) async {
      final steps = <bool>[];
      final pages = PageController();
      addTearDown(pages.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: DesktopReaderInput(
            direction: 'ltr',
            onVerticalScroll: (_) {},
            onPageStep: steps.add,
            // Contain/Height fit: plain PageView items, no page scroller.
            builder: (_, _) => PageView(
              controller: pages,
              children: const [
                SizedBox.expand(),
                SizedBox.expand(),
                SizedBox.expand(),
              ],
            ),
          ),
        ),
      );

      void wheel(Offset delta, int ms) => tester.binding.handlePointerEvent(
        PointerScrollEvent(
          position: const Offset(400, 300),
          scrollDelta: delta,
          timeStamp: Duration(milliseconds: ms),
          kind: PointerDeviceKind.mouse,
        ),
      );

      // Tilt wheel: a page turn, never a pixel nudge of the PageView.
      wheel(const Offset(120, 0), 1000);
      expect(pages.position.pixels, 0);
      expect(steps, [true]);
      await tester.pump();

      // Shift+wheel: Flutter swaps the axes for the horizontal PageView.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      wheel(const Offset(0, 120), 1400);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(pages.position.pixels, 0);
      expect(steps, [true, true]);
      await tester.pumpAndSettle();
      expect(pages.position.pixels, 0);
    },
  );

  // reader-3: arrows move a short step, PageUp/PageDown a screenful, and
  // keyboard scrolling goes to the (animated) key-scroll callback.
  testWidgets('vertical keys: short arrow step, screenful page keys', (
    tester,
  ) async {
    final wheel = <double>[];
    final keys = <double>[];
    await tester.pumpWidget(
      MaterialApp(
        home: DesktopReaderInput(
          direction: 'vertical',
          onVerticalScroll: wheel.add,
          onVerticalKeyScroll: keys.add,
          onPageStep: (_) {},
          builder: (_, _) => const SizedBox.expand(),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
    expect(wheel, isEmpty);
    expect(keys.take(2), [100, -100]);
    // 85% of the 600px test surface.
    expect(keys[2], closeTo(510, 0.5));
    expect(keys[3], closeTo(-510, 0.5));
  });

  // reader-4: the reader.* shortcut ids reach their callbacks, once per
  // press, and Ctrl is honoured for the zoom keys only.
  testWidgets('reader shortcut keys run their actions', (tester) async {
    final log = <String>[];
    final zooms = <double>[];
    await tester.pumpWidget(
      MaterialApp(
        home: DesktopReaderInput(
          direction: 'ltr',
          onVerticalScroll: (_) {},
          onPageStep: (_) {},
          onNextChapter: () => log.add('next'),
          onPreviousChapter: () => log.add('prev'),
          onChapterList: () => log.add('list'),
          onSettings: () => log.add('settings'),
          onAutoScroll: () => log.add('auto'),
          onToggleFullscreen: () => log.add('full'),
          onBack: () => log.add('back'),
          onShowHelp: () => log.add('help'),
          onZoomBy: (f, _) => zooms.add(f),
          onZoomReset: () => log.add('reset'),
          builder: (top, bottom) =>
              SizedBox.expand(child: Text('$top/$bottom')),
        ),
      ),
    );
    await tester.pump();
    for (final key in [
      LogicalKeyboardKey.keyN,
      LogicalKeyboardKey.bracketRight,
      LogicalKeyboardKey.keyP,
      LogicalKeyboardKey.bracketLeft,
      LogicalKeyboardKey.keyC,
      LogicalKeyboardKey.keyS,
      LogicalKeyboardKey.keyA,
      LogicalKeyboardKey.keyF,
      LogicalKeyboardKey.f11,
      LogicalKeyboardKey.backspace,
    ]) {
      await tester.sendKeyEvent(key);
    }
    expect(log, [
      'next',
      'next',
      'prev',
      'prev',
      'list',
      'settings',
      'auto',
      'full',
      'full',
      'back',
    ]);

    // Holding N fires once, not once per auto-repeat.
    log.clear();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyN);
    expect(log, ['next']);

    // '?' (Shift+/) opens help.
    log.clear();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.slash, character: '?');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(log, ['help']);

    // M pins both bars open, and again unpins them.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pump();
    expect(find.text('true/true'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pump();
    expect(find.text('false/false'), findsOneWidget);

    // Ctrl+= / Ctrl+- / Ctrl+0 zoom; a plain N with Ctrl does nothing.
    log.clear();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.equal);
    await tester.sendKeyEvent(LogicalKeyboardKey.minus);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(zooms, [
      DesktopReaderInput.zoomStep,
      1 / DesktopReaderInput.zoomStep,
    ]);
    expect(log, ['reset']);
  });

  // reader-7: side buttons turn pages, middle click pins the bars.
  testWidgets('mouse side buttons page and middle click shows the bars', (
    tester,
  ) async {
    final steps = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: DesktopReaderInput(
          direction: 'ltr',
          onVerticalScroll: (_) {},
          onPageStep: steps.add,
          builder: (top, bottom) =>
              SizedBox.expand(child: Text('$top/$bottom')),
        ),
      ),
    );
    Future<void> press(int buttons) async {
      final g = await tester.startGesture(
        const Offset(400, 300),
        kind: PointerDeviceKind.mouse,
        buttons: buttons,
      );
      await g.up();
      await g.removePointer();
    }

    await press(kBackMouseButton);
    await press(kForwardMouseButton);
    expect(steps, [false, true]);
    await press(kMiddleMouseButton);
    await tester.pump();
    expect(find.text('true/true'), findsOneWidget);
  });

  // reader-7: a still left click reports its position; a drag, a click on a
  // button and a double click (with deferClicks) do not.
  testWidgets('page clicks skip drags, buttons and double clicks', (
    tester,
  ) async {
    final clicks = <Offset>[];
    var buttonTaps = 0;
    var defer = false;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return DesktopReaderInput(
              direction: 'ltr',
              onVerticalScroll: (_) {},
              onPageStep: (_) {},
              deferClicks: defer,
              onPageClick: (local, size) => clicks.add(local),
              builder: (_, _) => Stack(
                children: [
                  const SizedBox.expand(),
                  Positioned(
                    left: 380,
                    top: 280,
                    child: TextButton(
                      onPressed: () => buttonTaps++,
                      child: const Text('btn'),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
    await tester.tapAt(const Offset(100, 300), kind: PointerDeviceKind.mouse);
    expect(clicks, [const Offset(100, 300)]);

    await tester.tap(find.text('btn'), kind: PointerDeviceKind.mouse);
    expect(buttonTaps, 1);
    expect(clicks, hasLength(1));

    final drag = await tester.startGesture(
      const Offset(100, 300),
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveTo(const Offset(160, 300));
    await drag.up();
    expect(clicks, hasLength(1));

    update(() => defer = true);
    await tester.pump();
    // Double click: neither click is a page click.
    await tester.tapAt(const Offset(700, 300), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(const Offset(700, 300), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 400));
    expect(clicks, hasLength(1));
    // Single click: reported once the double-click time has passed.
    await tester.tapAt(const Offset(700, 300), kind: PointerDeviceKind.mouse);
    expect(clicks, hasLength(1));
    await tester.pump(const Duration(milliseconds: 400));
    expect(clicks.last, const Offset(700, 300));
    expect(clicks, hasLength(2));
    // Triple click (paragraph selection): the third click is not a page
    // click either.
    for (var i = 0; i < 3; i++) {
      await tester.tapAt(const Offset(700, 300), kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 60));
    }
    await tester.pump(const Duration(milliseconds: 400));
    expect(clicks, hasLength(2));
  });

  // reader-13: the cursor hides after resting and returns on movement.
  testWidgets('cursor hides after the mouse rests over the page', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DesktopReaderInput(
          direction: 'ltr',
          onVerticalScroll: (_) {},
          onPageStep: (_) {},
          builder: (_, _) => const SizedBox.expand(),
        ),
      ),
    );
    final hidden = find.byWidgetPredicate(
      (w) => w is MouseRegion && w.cursor == SystemMouseCursors.none,
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(400, 300));
    await mouse.moveTo(const Offset(410, 300));
    await tester.pump(const Duration(seconds: 1));
    expect(hidden, findsNothing);
    await tester.pump(kDesktopReaderCursorHideDelay);
    expect(hidden, findsOneWidget);
    await mouse.moveTo(const Offset(420, 300));
    await tester.pump();
    expect(hidden, findsNothing);
    await mouse.removePointer();
  });

  testWidgets('touch drag still pages the PageView after a wheel event', (
    tester,
  ) async {
    final pages = PageController();
    addTearDown(pages.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: DesktopReaderInput(
          direction: 'ltr',
          onVerticalScroll: (_) {},
          onPageStep: (_) {},
          builder: (_, _) => PageView(
            controller: pages,
            children: const [SizedBox.expand(), SizedBox.expand()],
          ),
        ),
      ),
    );
    tester.binding.handlePointerEvent(
      const PointerScrollEvent(
        position: Offset(400, 300),
        scrollDelta: Offset(120, 0),
        kind: PointerDeviceKind.mouse,
      ),
    );
    await tester.pump();
    await tester.fling(find.byType(PageView), const Offset(-500, 0), 1500);
    await tester.pumpAndSettle();
    expect(pages.page, 1);
  });
}
