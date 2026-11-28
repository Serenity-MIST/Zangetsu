// Windows: the entrance plays for the first screenful only. Cards met while
// scrolling, or scrolled away and back, are simply there; on roomy PCs the
// first cards of a list also stay built. Phone keeps its reveal.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/desktop/desktop_memory.dart';
import 'package:watch_app/core/desktop/desktop_row_scroller.dart';
import 'package:watch_app/core/desktop/desktop_smooth_scroll.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/ui/animation_prefs.dart';
import 'package:watch_app/core/ui/reveal_item.dart';

final _windows = TargetPlatformVariant.only(TargetPlatform.windows);
final _phone = TargetPlatformVariant.only(TargetPlatform.android);

class _Card extends StatefulWidget {
  const _Card(this.index);
  final int index;
  @override
  State<_Card> createState() => _CardState();
}

class _CardState extends State<_Card> {
  @override
  Widget build(BuildContext context) => Text('card ${widget.index}');
}

Widget _grid(ScrollController c, {int count = 200}) => MaterialApp(
  home: Scaffold(
    body: GridView.builder(
      controller: c,
      // ignore: deprecated_member_use
      cacheExtent: 800,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisExtent: 150,
      ),
      itemCount: count,
      itemBuilder: (_, i) => RevealItem(index: i, child: _Card(i)),
    ),
  ),
);

/// Cards that are drawn partly (or fully) see-through right now.
int _faded(WidgetTester tester) => tester
    .widgetList<Opacity>(find.byType(Opacity, skipOffstage: false))
    .where((o) => o.opacity < 1)
    .length;

void main() {
  late bool animations;
  setUp(() async {
    animations = AnimationPrefs.listAnimations;
    AnimationPrefs.listAnimations = true;
    await sl.reset();
    sl.registerSingleton<AppMode>(const AppMode(isTv: false));
  });
  tearDown(() async {
    AnimationPrefs.listAnimations = animations;
    DesktopMemory.systemMemoryMb = 0;
    await sl.reset();
  });

  testWidgets('Windows: the first screen animates, scrolling never does', (
    tester,
  ) async {
    final c = ScrollController();
    addTearDown(c.dispose);
    await tester.pumpWidget(_grid(c));
    // The first screenful starts from nothing; the cards built ahead below it
    // are finished already.
    await tester.pump();
    final faded = _faded(tester);
    expect(faded, 16);
    expect(
      find.byType(RevealItem, skipOffstage: false).evaluate().length,
      greaterThan(faded),
    );
    await tester.pumpAndSettle();
    expect(_faded(tester), 0);
    Future<void> to(double target) async {
      while ((c.offset - target).abs() > .5) {
        c.jumpTo(c.offset + (target - c.offset).clamp(-90.0, 90.0));
        await tester.pump(const Duration(milliseconds: 16));
        expect(_faded(tester), 0);
      }
    }

    await to(4000);
    await to(0);
    await tester.pumpAndSettle();
    expect(find.byType(VisibilityDetector), findsNothing);
  }, variant: _windows);

  testWidgets('Windows: a grid inside a scrolled page skips it too', (
    tester,
  ) async {
    final c = ScrollController(initialScrollOffset: 500);
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ListView(
          controller: c,
          children: [
            const SizedBox(height: 600),
            GridView.count(
              shrinkWrap: true,
              primary: false,
              crossAxisCount: 4,
              children: [
                for (var i = 0; i < 40; i++)
                  RevealItem(index: i, child: _Card(i)),
              ],
            ),
          ],
        ),
      ),
    );
    expect(_faded(tester), 0);
    expect(find.text('card 0'), findsOneWidget);
  }, variant: _windows);

  testWidgets('Windows, more than 8 GB: the first 96 cards stay built', (
    tester,
  ) async {
    DesktopMemory.systemMemoryMb = 24000;
    final c = ScrollController();
    addTearDown(c.dispose);
    await tester.pumpWidget(_grid(c));
    await tester.pumpAndSettle();
    final first = tester.state(find.byWidgetPredicate(
      (w) => w is _Card && w.index == 0,
    ));
    for (var y = 0.0; y < 6000; y += 100) {
      c.jumpTo(y);
      await tester.pump();
    }
    Finder card(int i) => find.byWidgetPredicate(
      (w) => w is _Card && w.index == i,
      skipOffstage: false,
    );
    expect(identical(tester.state(card(0)), first), isTrue);
    expect(card(95), findsOneWidget);
    // Further down the list only what is near stays.
    c.jumpTo(0);
    await tester.pump();
    expect(card(96), findsNothing);
  }, variant: _windows);

  Finder anyCard() =>
      find.byWidgetPredicate((w) => w is _Card, skipOffstage: false);

  testWidgets('Windows, more than 8 GB: tabs left behind keep nothing', (
    tester,
  ) async {
    DesktopMemory.systemMemoryMb = 24000;
    final grids = [for (var i = 0; i < 6; i++) ScrollController()];
    addTearDown(() {
      for (final c in grids) {
        c.dispose();
      }
    });
    late TabController tabs;
    await tester.pumpWidget(
      MaterialApp(
        home: DefaultTabController(
          length: 6,
          child: Builder(
            builder: (context) {
              tabs = DefaultTabController.of(context);
              return TabBarView(
                children: [
                  for (final c in grids)
                    GridView.builder(
                      controller: c,
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 4,
                            mainAxisExtent: 150,
                          ),
                      itemCount: 300,
                      itemBuilder: (_, i) =>
                          RevealItem(index: i, child: _Card(i)),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (var i = 0; i < 6; i++) {
      tabs.animateTo(i);
      await tester.pumpAndSettle();
      for (var y = 0.0; y < 6000; y += 100) {
        grids[i].jumpTo(y);
        await tester.pump();
      }
      await tester.pumpAndSettle();
      // This tab's first 96 cards and what is on screen; no other tab's.
      final kept = anyCard().evaluate().length;
      expect(kept, greaterThan(96), reason: 'tab $i');
      expect(kept, lessThan(96 + 60), reason: 'tab $i');
    }
  }, variant: _windows);

  testWidgets('Windows, more than 8 GB: rows scrolled away keep nothing', (
    tester,
  ) async {
    Future<int> kept(int mb) async {
      DesktopMemory.systemMemoryMb = mb;
      final c = ScrollController();
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          key: ValueKey(mb),
          home: ListView.builder(
            controller: c,
            itemCount: 40,
            itemBuilder: (_, row) => SizedBox(
              height: 200,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: 12,
                itemBuilder: (_, i) => SizedBox(
                  width: 100,
                  child: RevealItem(index: i, child: _Card(i)),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (var y = 0.0; y < 6000; y += 100) {
        c.jumpTo(y);
        await tester.pump();
      }
      await tester.pumpAndSettle();
      return anyCard().evaluate().length;
    }

    final small = await kept(8192);
    expect(await kept(24000), small);
  }, variant: _windows);

  testWidgets('Windows: Tab never lands on a kept card that is scrolled away', (
    tester,
  ) async {
    DesktopMemory.systemMemoryMb = 24000;
    final c = ScrollController();
    addTearDown(c.dispose);
    final nodes = [for (var i = 0; i < 300; i++) FocusNode(debugLabel: 'c$i')];
    addTearDown(() {
      for (final n in nodes) {
        n.dispose();
      }
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GridView.builder(
            controller: c,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              mainAxisExtent: 150,
            ),
            itemCount: 300,
            itemBuilder: (_, i) => RevealItem(
              index: i,
              child: Focus(focusNode: nodes[i], child: _Card(i)),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    nodes[0].requestFocus();
    await tester.pump();
    // On screen everything works as usual.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    expect(nodes[1].hasFocus, isTrue);
    for (var y = 0.0; y < c.position.maxScrollExtent; y += 100) {
      c.jumpTo(y);
      await tester.pump();
    }
    c.jumpTo(c.position.maxScrollExtent);
    await tester.pumpAndSettle();
    // The focused card is kept as well; Tab leaves it for one that is laid out.
    expect(anyCard().evaluate().length, greaterThan(96));
    void expectVisible() {
      final i = nodes.indexWhere((n) => n.hasFocus);
      if (i >= 0) expect(i, greaterThan(200), reason: 'card $i is not shown');
    }

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expectVisible();
    nodes[299].requestFocus();
    await tester.pump();
    for (var i = 0; i < 8; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expectVisible();
    }
    // Scrolled back, the same cards take focus again.
    c.jumpTo(0);
    await tester.pumpAndSettle();
    nodes[4].requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(nodes[5].hasFocus, isTrue);
  }, variant: _windows);

  testWidgets('8 GB PCs keep no scrolled-away cards', (tester) async {
    DesktopMemory.systemMemoryMb = 8192;
    final c = ScrollController();
    addTearDown(c.dispose);
    await tester.pumpWidget(_grid(c));
    await tester.pumpAndSettle();
    c.jumpTo(5000);
    await tester.pump();
    expect(find.text('card 0', skipOffstage: false), findsNothing);
  }, variant: _windows);

  testWidgets('phone: cards still reveal as they scroll in', (tester) async {
    DesktopMemory.systemMemoryMb = 24000;
    final c = ScrollController();
    addTearDown(c.dispose);
    await tester.pumpWidget(_grid(c));
    await tester.pumpAndSettle();
    c.jumpTo(5000);
    await tester.pump();
    expect(_faded(tester), greaterThan(0));
    expect(find.text('card 0', skipOffstage: false), findsNothing);
    await tester.pumpAndSettle();
  }, variant: _phone);

  group('row arrows', () {
    Widget page(ScrollController rows) => MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            for (var r = 0; r < 12; r++)
              SizedBox(
                key: ValueKey('row-$r'),
                height: 200,
                child: r != 1
                    ? null
                    : DesktopRowScroller(
                        controller: rows,
                        child: ListView.builder(
                          controller: rows,
                          scrollDirection: Axis.horizontal,
                          itemCount: 30,
                          itemBuilder: (_, i) => const SizedBox(width: 100),
                        ),
                      ),
              ),
          ],
        ),
      ),
    );
    final arrows = find.descendant(
      of: find.byType(DesktopRowScroller),
      matching: find.byType(AnimatedOpacity),
    );

    testWidgets('hidden arrows are not built; hover waits for the page to '
        'stop', (tester) async {
      final rows = ScrollController();
      addTearDown(rows.dispose);
      await tester.pumpWidget(page(rows));
      await tester.pump();
      expect(arrows, findsNothing);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: const Offset(400, 590));
      final scroll = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      // The row passes under a resting mouse while the page moves.
      desktopSmoothScrollBy(scroll.position, 30);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await mouse.moveTo(const Offset(400, 280));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      expect(scroll.position.isScrollingNotifier.value, isTrue);
      expect(arrows, findsNothing);
      await tester.pump(const Duration(milliseconds: 200));
      expect(scroll.position.isScrollingNotifier.value, isFalse);
      expect(arrows, findsNothing);
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpAndSettle();
      expect(arrows, findsOneWidget);
      // Leaving fades it out and then removes it.
      await mouse.moveTo(const Offset(400, 590));
      await tester.pumpAndSettle();
      expect(arrows, findsNothing);
    }, variant: _windows);
  });
}
