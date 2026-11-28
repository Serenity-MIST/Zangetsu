// The Windows top-bar quick search dropdown (mockup q2): it opens after the
// debounce with the top matches, the keyboard and mouse work, and it never
// takes focus away from the box.

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/features/search/desktop_quick_search.dart';
import 'package:watch_app/features/search/desktop_search_dropdown.dart';

/// A widget test run as Windows; the variant resets the platform override.
void winTestWidgets(String description, WidgetTesterCallback body) =>
    testWidgets(
      description,
      body,
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

/// A plain anime title.
MediaItem _item(String title) => MediaItem(
  id: title,
  title: title,
  url: '/$title',
  type: ProviderType.anime,
  sourceId: 'src',
);

const _fieldKey = ValueKey('field');
const _panel = ValueKey('desktop-search-dropdown');
const _seeAll = ValueKey('desktop-search-dropdown-see-all');
ValueKey<String> _row(int i) => ValueKey('desktop-search-dropdown-row-$i');

void main() {
  late TextEditingController controller;
  late FocusNode focus;
  late List<String> seeAll;
  late List<MediaItem> opened;
  late List<String> submitted;
  late List<String> queries;

  setUp(() {
    controller = TextEditingController();
    focus = FocusNode();
    seeAll = [];
    opened = [];
    submitted = [];
    queries = [];
  });

  tearDown(() {
    controller.dispose();
    focus.dispose();
  });

  /// The box with the dropdown, plus a button elsewhere to click away to.
  /// [quick] replaces the default catalogue-style lookup.
  Widget harness({bool? enabled, DesktopQuickSearch? quick}) => MaterialApp(
    home: Scaffold(
      body: Column(
        children: [
          Align(
            alignment: Alignment.topRight,
            child: SizedBox(
              width: 340,
              child: DesktopSearchDropdown(
                controller: controller,
                focusNode: focus,
                enabled: enabled,
                onSeeAll: seeAll.add,
                onOpenItem: opened.add,
                quickSearch:
                    quick ??
                    DesktopQuickSearch(
                      search: (q) async {
                        queries.add(q);
                        return [for (var i = 1; i <= 6; i++) _item('$q $i')];
                      },
                    ),
                child: TextField(
                  key: _fieldKey,
                  controller: controller,
                  focusNode: focus,
                  onSubmitted: submitted.add,
                ),
              ),
            ),
          ),
          const SizedBox(height: 400),
          TextButton(
            key: const ValueKey('elsewhere'),
            onPressed: () {},
            child: const Text('elsewhere'),
          ),
        ],
      ),
    ),
  );

  /// Types [text] and waits out the debounce and the (instant) answer.
  Future<void> type(WidgetTester t, String text) async {
    await t.enterText(find.byKey(_fieldKey), text);
    await t.pump(kDesktopQuickSearchDebounce);
    await t.pump();
    await t.pump();
  }

  winTestWidgets('opens after the debounce with the top four matches', (
    t,
  ) async {
    await t.pumpWidget(harness());
    await t.enterText(find.byKey(_fieldKey), 'naruto');
    await t.pump(const Duration(milliseconds: 200));
    expect(find.byKey(_panel), findsNothing, reason: 'still debouncing');
    await t.pump(const Duration(milliseconds: 60));
    await t.pump();
    expect(find.byKey(_panel), findsOneWidget);
    for (var i = 0; i < 4; i++) {
      expect(find.byKey(_row(i)), findsOneWidget);
    }
    expect(find.byKey(_row(4)), findsNothing, reason: 'capped at four');
    expect(find.text('naruto 1'), findsOneWidget);
    expect(find.text('See all results ⏎'), findsOneWidget);
    // One lookup for the settled text, none for the keystrokes before it.
    expect(queries, ['naruto']);
  });

  winTestWidgets('Down + Enter opens the highlighted title', (t) async {
    await t.pumpWidget(harness());
    await type(t, 'naruto');
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pump();
    expect(opened.single.title, 'naruto 2');
    expect(seeAll, isEmpty);
    expect(submitted, isEmpty);
    expect(find.byKey(_panel), findsNothing);
  });

  winTestWidgets('Enter with nothing highlighted opens See all once', (
    t,
  ) async {
    await t.pumpWidget(harness());
    await type(t, 'naruto');
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pump();
    expect(seeAll, ['naruto']);
    expect(opened, isEmpty);
    expect(submitted, isEmpty, reason: 'the field must not submit as well');
    expect(find.byKey(_panel), findsNothing);
    expect(focus.hasFocus, isTrue);
  });

  winTestWidgets('Up from nothing lands on See all; Enter opens it', (t) async {
    await t.pumpWidget(harness());
    await type(t, 'naruto');
    await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pump();
    expect(seeAll, ['naruto']);
  });

  winTestWidgets('Esc closes the panel and keeps the box focused', (t) async {
    await t.pumpWidget(harness());
    await type(t, 'naruto');
    expect(find.byKey(_panel), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();
    expect(find.byKey(_panel), findsNothing);
    expect(focus.hasFocus, isTrue);
    expect(controller.text, 'naruto');
  });

  winTestWidgets('clicking a row opens it without unfocusing the box first', (
    t,
  ) async {
    await t.pumpWidget(harness());
    await type(t, 'naruto');
    // Hovering highlights the row (a mouse pointer, like Windows).
    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(t.getCenter(find.byKey(_row(2))));
    await t.pump();
    // Press and release on the row: the tap lands on the row (the panel is in
    // the field's tap region, so the box is not unfocused on pointer down).
    await mouse.down(t.getCenter(find.byKey(_row(2))));
    await t.pump();
    expect(focus.hasFocus, isTrue);
    expect(find.byKey(_panel), findsOneWidget);
    await mouse.up();
    await t.pump();
    expect(opened.single.title, 'naruto 3');
    expect(find.byKey(_panel), findsNothing);
  });

  winTestWidgets('clicking See all opens the results page', (t) async {
    await t.pumpWidget(harness());
    await type(t, 'naruto');
    await t.tap(find.byKey(_seeAll));
    await t.pump();
    expect(seeAll, ['naruto']);
    expect(focus.hasFocus, isTrue);
  });

  winTestWidgets('clicking elsewhere closes the panel', (t) async {
    await t.pumpWidget(harness());
    await type(t, 'naruto');
    await t.tap(
      find.byKey(const ValueKey('elsewhere')),
      kind: PointerDeviceKind.mouse,
    );
    await t.pump();
    expect(find.byKey(_panel), findsNothing);
  });

  winTestWidgets('focusing the box with old text does not open the panel', (
    t,
  ) async {
    controller.text = 'naruto';
    await t.pumpWidget(harness());
    focus.requestFocus();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byKey(_panel), findsNothing);
    expect(queries, isEmpty);
  });

  winTestWidgets('text shorter than two characters closes the panel', (
    t,
  ) async {
    await t.pumpWidget(harness());
    await type(t, 'naruto');
    expect(find.byKey(_panel), findsOneWidget);
    await type(t, 'n');
    expect(find.byKey(_panel), findsNothing);
  });

  winTestWidgets('Enter with the panel closed still submits the field', (
    t,
  ) async {
    await t.pumpWidget(harness());
    await t.enterText(find.byKey(_fieldKey), 'naruto');
    // Before the debounce: the panel is not open, so Enter is the field's.
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.pump(const Duration(milliseconds: 400));
    expect(submitted, ['naruto']);
    expect(seeAll, isEmpty);
    // The pending lookup was dropped, so no panel pops over the page.
    expect(find.byKey(_panel), findsNothing);
  });

  testWidgets('off Windows the box is left exactly as it was', (t) async {
    await t.pumpWidget(harness());
    await type(t, 'naruto');
    expect(find.byKey(_panel), findsNothing);
    expect(queries, isEmpty);
  });

  // Novel "Browse" (no tracker catalogue): the dropdown searches the
  // installed sources and shows titles as they arrive.
  group('installed sources lookup', () {
    /// One fan-out per query; the test drives its answers.
    late Map<String, StreamController<QuickSearchResult>> runs;
    late List<String> cancelled;
    late bool catalogueAsked;

    setUp(() {
      runs = {};
      cancelled = [];
      catalogueAsked = false;
    });

    DesktopQuickSearch sourcesQuick() => DesktopQuickSearch(
      useSources: () => true,
      search: (q) async {
        catalogueAsked = true;
        return const [];
      },
      sourcesSearch: (q, limit) {
        final c = StreamController<QuickSearchResult>(
          onCancel: () => cancelled.add(q),
        );
        runs[q] = c;
        return c.stream;
      },
    );

    MediaItem novel(String title, String source) => MediaItem(
      id: '$source-$title',
      title: title,
      url: '/$title',
      type: ProviderType.novel,
      sourceId: source,
    );

    winTestWidgets('first source titles show with their source, then done', (
      t,
    ) async {
      await t.pumpWidget(harness(quick: sourcesQuick()));
      await type(t, 'i can devour monsters');
      final run = runs['i can devour monsters']!;
      // Nothing back yet: placeholders, never "No quick matches".
      expect(find.byKey(_panel), findsOneWidget);
      expect(find.textContaining('No quick matches'), findsNothing);

      // Sources picked, none answered yet: the searching row shows.
      run.add(const QuickSearchResult([], searching: true, pendingSources: 3));
      await t.pump();
      expect(find.text('Searching 3 sources…'), findsOneWidget);
      expect(find.textContaining('No quick matches'), findsNothing);

      // Novel Ping answers: its title shows with the source under it.
      final hit = novel('I Can Devour Monsters', 'lnr:ping');
      run.add(
        QuickSearchResult(
          [hit],
          sourceNames: const ['Novel Ping'],
          searching: true,
          pendingSources: 2,
        ),
      );
      await t.pump();
      expect(find.byKey(_row(0)), findsOneWidget);
      expect(find.text('I Can Devour Monsters'), findsOneWidget);
      expect(find.text('Novel Ping · Novel'), findsOneWidget);
      expect(find.text('Searching 2 sources…'), findsOneWidget);

      // Everyone answered: the searching row goes, the title stays.
      run.add(
        QuickSearchResult(
          [hit, novel('I Can Devour Monsters', 'lnr:phoenix')],
          sourceNames: const ['Novel Ping', 'Novel Phoenix'],
        ),
      );
      await run.close();
      await t.pump();
      expect(find.textContaining('Searching'), findsNothing);
      expect(find.text('Novel Phoenix · Novel'), findsOneWidget);
      expect(catalogueAsked, isFalse, reason: 'the catalogue is not asked');

      // Clicking the source's title opens that item (its own source).
      await t.tap(find.byKey(_row(0)));
      await t.pump();
      expect(opened.single.sourceId, 'lnr:ping');
    });

    winTestWidgets('typing more cancels the older fan-out', (t) async {
      await t.pumpWidget(harness(quick: sourcesQuick()));
      await type(t, 'devour');
      final old = runs['devour']!;
      await type(t, 'devour m');
      expect(cancelled, contains('devour'));
      // A late answer for the old text never lands.
      if (!old.isClosed) {
        old.add(
          QuickSearchResult(
            [novel('Old hit', 'lnr:a')],
            sourceNames: const ['A'],
          ),
        );
      }
      await t.pump();
      expect(find.text('Old hit'), findsNothing);
    });

    winTestWidgets('"No quick matches" only once every source is empty', (
      t,
    ) async {
      await t.pumpWidget(harness(quick: sourcesQuick()));
      await type(t, 'nothing');
      final run = runs['nothing']!;
      run.add(const QuickSearchResult([], searching: true, pendingSources: 1));
      await t.pump();
      expect(find.textContaining('No quick matches'), findsNothing);
      run.add(const QuickSearchResult([]));
      await run.close();
      await t.pump();
      expect(find.text('No quick matches for “nothing”.'), findsOneWidget);
    });

    // Typing more must not flash placeholders: the shorter query's titles
    // stay until the longer query's sources bring their own.
    winTestWidgets('typing more keeps the old titles until new ones arrive', (
      t,
    ) async {
      await t.pumpWidget(harness(quick: sourcesQuick()));
      await type(t, 'devour');
      runs['devour']!.add(
        QuickSearchResult(
          [novel('Devour Hit', 'lnr:ping')],
          sourceNames: const ['Novel Ping'],
        ),
      );
      // Two frames: one delivers the stream event, one paints its setState.
      await t.pump();
      await t.pump();
      expect(find.text('Devour Hit'), findsOneWidget);

      await type(t, 'devour m');
      final next = runs['devour m']!;
      // The new run's first, still-empty answer keeps the old row.
      next.add(const QuickSearchResult([], searching: true, pendingSources: 2));
      await t.pump();
      await t.pump();
      expect(find.text('Devour Hit'), findsOneWidget);
      expect(find.text('Searching 2 sources…'), findsOneWidget);

      // Its own titles then replace it.
      next.add(
        QuickSearchResult(
          [novel('Devour Monsters', 'lnr:phoenix')],
          sourceNames: const ['Novel Phoenix'],
        ),
      );
      await t.pump();
      await t.pump();
      expect(find.text('Devour Hit'), findsNothing);
      expect(find.text('Devour Monsters'), findsOneWidget);
    });
  });
}
