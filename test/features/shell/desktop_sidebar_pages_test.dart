import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/desktop_memory.dart';
import 'package:watch_app/features/shell/desktop_sidebar_pages.dart';

/// Visible state makes retained page behavior observable without real accounts.
class _Counter extends StatefulWidget {
  const _Counter();
  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int count = 0;
  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () => setState(() => count++),
    child: Text('count:$count'),
  );
}

void main() {
  testWidgets('sidebar swaps retain state without pushing another route', (
    tester,
  ) async {
    String? selected;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, set) {
            update = set;
            return Scaffold(
              body: DesktopSidebarPages(
                selected: selected,
                builders: {
                  'streaming': (_) => const _Counter(),
                  'genres': (_) => const Text('Genres'),
                },
                fallback: const Text('Home'),
              ),
            );
          },
        ),
      ),
    );
    expect(find.text('Home'), findsOneWidget);
    expect(find.byType(_Counter), findsNothing);
    update(() => selected = 'streaming');
    await tester.pumpAndSettle();
    await tester.tap(find.text('count:0'));
    await tester.pump();
    update(() => selected = 'genres');
    await tester.pumpAndSettle();
    expect(find.text('Genres'), findsOneWidget);
    expect(find.text('count:1'), findsNothing);
    update(() => selected = 'streaming');
    await tester.pumpAndSettle();
    expect(find.text('count:1'), findsOneWidget);
    expect(
      Navigator.of(tester.element(find.text('count:1'))).canPop(),
      isFalse,
    );
    update(() => selected = null);
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  // historybugs: clicking a button switches the page in the same frame its
  // tooltip starts fading. The hidden page's tickers are muted, so the fade
  // froze and the label ('Back', 'History') stayed on screen. Hidden pages
  // now drop their tooltips; the shown page's tooltips still work.
  testWidgets(
    'a hidden page leaves no tooltip label behind',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      String? selected = 'profile';
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, set) {
              update = set;
              return Scaffold(
                body: DesktopSidebarPages(
                  selected: selected,
                  builders: {
                    'profile': (_) => const Tooltip(
                      message: 'History tip',
                      child: Text('Profile'),
                    ),
                    'history': (_) => const Tooltip(
                      message: 'Back tip',
                      child: Text('History page'),
                    ),
                  },
                  fallback: const Tooltip(
                    message: 'Home tip',
                    child: Text('Home'),
                  ),
                ),
              );
            },
          ),
        ),
      );
      // Show the Profile page tooltip, then start its fade-out and switch page
      // in the same frame, like a click on the button does.
      tester
          .state<TooltipState>(find.byType(Tooltip).first)
          .ensureTooltipVisible();
      await tester.pumpAndSettle();
      expect(find.text('History tip'), findsOneWidget);
      Tooltip.dismissAllToolTips();
      update(() => selected = 'history');
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      // skipOffstage: false because the label is painted in the app Overlay but,
      // as an element, sits under the hidden page that finders skip.
      expect(find.text('History tip', skipOffstage: false), findsNothing);
      // The page now shown still shows its own tooltip.
      final shown = find.ancestor(
        of: find.text('History page'),
        matching: find.byType(Tooltip),
      );
      expect(tester.state<TooltipState>(shown).ensureTooltipVisible(), isTrue);
      await tester.pumpAndSettle();
      expect(find.text('Back tip'), findsOneWidget);
      // Leaving to the fallback (dock tabs) clears it as well.
      update(() => selected = null);
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('Back tip', skipOffstage: false), findsNothing);
      expect(find.text('Home'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('profile key discards retained page state', (tester) async {
    Future<void> show(String profile) => tester.pumpWidget(
      MaterialApp(
        home: DesktopSidebarPages(
          key: ValueKey(profile),
          selected: 'schedule',
          builders: {'schedule': (_) => const _Counter()},
          fallback: const SizedBox(),
        ),
      ),
    );
    await show('first');
    await tester.tap(find.text('count:0'));
    await tester.pump();
    expect(find.text('count:1'), findsOneWidget);
    await show('second');
    await tester.pumpAndSettle();
    expect(find.text('count:0'), findsOneWidget);
  });
  // 8 GB PCs keep only the shown page and the last one; older pages are
  // dropped so their posters can leave memory, and rebuild when reopened.
  testWidgets('only the most recent pages stay open', (tester) async {
    DesktopSidebarPages.debugRetainedLimit = 2;
    addTearDown(() => DesktopSidebarPages.debugRetainedLimit = null);
    String? selected = 'a';
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, set) {
            update = set;
            return Scaffold(
              body: DesktopSidebarPages(
                selected: selected,
                builders: {
                  'a': (_) => const _Counter(),
                  'b': (_) => const Text('B'),
                  'c': (_) => const Text('C'),
                },
                fallback: const Text('Home'),
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('count:0'));
    await tester.pump();
    update(() => selected = 'b');
    await tester.pumpAndSettle();
    // Two pages: 'a' is still kept with its state.
    expect(find.text('count:1', skipOffstage: false), findsOneWidget);
    update(() => selected = 'c');
    await tester.pumpAndSettle();
    // Three pages with a limit of two: the oldest ('a') is dropped.
    expect(find.byType(_Counter, skipOffstage: false), findsNothing);
    update(() => selected = 'a');
    await tester.pumpAndSettle();
    expect(find.text('count:0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  // Only 8 GB PCs drop pages; larger PCs and an unknown size keep them all.
  test('pages are limited only on low-memory PCs', () {
    addTearDown(() => DesktopMemory.systemMemoryMb = 0);
    DesktopMemory.systemMemoryMb = 0;
    expect(DesktopSidebarPages.retainedLimit, 0);
    DesktopMemory.systemMemoryMb = 16384;
    expect(DesktopSidebarPages.retainedLimit, 0);
    DesktopMemory.systemMemoryMb = 8192;
    expect(DesktopSidebarPages.retainedLimit, 2);
  });
}
