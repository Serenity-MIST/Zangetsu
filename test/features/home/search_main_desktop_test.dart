// Windows behaviour of the main Search screen (search-1, search-3, search-4,
// search-7, search-9) and the phone screen left as it was.
//
// Tests run on a Windows host that pretends to be Android; Windows cases
// use winTestWidgets (a TargetPlatformVariant that resets the override).

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/desktop/desktop_row_scroller.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/playback/my_list.dart';
import 'package:watch_app/core/playback/search_history.dart';
import 'package:watch_app/core/playback/search_prefs.dart';
import 'package:watch_app/core/playback/search_source_prefs.dart';
import 'package:watch_app/core/playback/source_health_store.dart';
import 'package:watch_app/core/repository/catalogue_repository.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/search/title_suggestion_service.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/core/zmode/metadata_filters.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/features/home/search_row_scroller.dart';
import 'package:watch_app/features/home/search_screen.dart';
import 'package:watch_app/features/search/meta_filter_sheet.dart';
import 'package:watch_app/l10n/app_localizations.dart';

import '../../support/picker_deps.dart';

/// Repository with no sources: the screen renders, searches return nothing.
class _FakeSourceRepo implements SourceRepository {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  List<({String id, String name})> get pickableSources => loadedSources;

  @override
  List<({String id, String name})> get loadedSources => const [];

  @override
  String get sourceId => 'fake-source';

  @override
  String displayName(String id) => id;

  @override
  bool hasSource(String id) => false;

  @override
  Future<bool> ensureSourceLoaded(String sourceId) async => true;

  @override
  void syncSearchCache() {}

  @override
  Future<List<HomeSection>> home({
    String category = 'sub',
    String? sourceId,
  }) async => const [];

  @override
  Future<({List<MediaItem> items, SourceOutcome outcome})> searchStatus(
    String query, {
    String category = 'sub',
    String? sourceId,
    String? filtersJson,
    bool cache = false,
    int page = 1,
  }) async => (items: const <MediaItem>[], outcome: SourceOutcome.ok);
}

class _FakeMyListStore implements MyListStore {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  List<MediaItem> all() => const [];

  @override
  bool contains(MediaItem m) => false;

  @override
  final ValueNotifier<int> revision = ValueNotifier<int>(0);
}

class _FakeHealth implements SourceHealthStore {
  @override
  bool isSkippable(String id) => false;

  @override
  SourceHealth statusOf(String id) => SourceHealth.ok;

  @override
  Future<void> record(
    String id,
    SourceOutcome outcome, {
    int? responseMs,
  }) async {}

  @override
  Future<void> clear(String id) async {}

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// No live title suggestions: the list is just the history matches.
class _NoLiveSuggestions implements TitleSuggestionService {
  @override
  Future<List<String>> suggest(String query, {int limit = 8}) async => const [];

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// Eight live titles, so the suggestion list is long enough to scroll.
class _ManyLiveSuggestions implements TitleSuggestionService {
  @override
  Future<List<String>> suggest(String query, {int limit = 8}) async => [
    for (var i = 1; i <= 8; i++) 'nar title $i',
  ];

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// A widget test run as Windows; the variant resets the platform override.
void winTestWidgets(String description, WidgetTesterCallback body) =>
    testWidgets(
      description,
      body,
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

void main() {
  late Directory dir;
  late SearchHistory history;

  Widget harness() => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: child!,
    ),
    home: BlocProvider<ActiveSourceCubit>.value(
      value: sl<ActiveSourceCubit>(),
      child: const SearchScreen(forceSources: true),
    ),
  );

  /// The search box's focus node.
  FocusNode fieldFocus(WidgetTester t) =>
      t.widget<TextField>(find.byType(TextField)).focusNode!;

  /// The search box's text.
  String fieldText(WidgetTester t) =>
      t.widget<TextField>(find.byType(TextField)).controller!.text;

  /// Focuses the box and types [text], letting the history suggestions in.
  Future<void> typeQuery(WidgetTester t, String text) async {
    await t.tap(find.byType(TextField));
    await t.enterText(find.byType(TextField), text);
    // The live-suggestion debounce is 250 ms.
    await t.pump(const Duration(milliseconds: 300));
    await t.pumpAndSettle();
  }

  Finder fillArrow(String q) =>
      find.byKey(ValueKey('search-suggestion-fill-$q'));

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('search_main_desktop');
    Hive.init(dir.path);
    // In-memory history box: a disk write started inside a widget test's
    // fake-async zone (running a search records it; Clear / Undo / remove
    // rewrite it) never completes, and tearDown's Hive.close() then hangs
    // forever. A memory-backed box writes synchronously.
    await Hive.openBox<dynamic>(SearchHistory.boxName, bytes: Uint8List(0));
    await SearchHistory.init();
    await SearchPrefs.init();
    await SearchSourcePrefs.init();
    await registerPickerDeps();

    history = SearchHistory();
    // Newest first: naruto, then naruto shippuden.
    await history.add('naruto shippuden');
    await history.add('naruto');
    sl.registerSingleton<SearchHistory>(history);
    sl.registerSingleton<SearchPrefs>(SearchPrefs());
    sl.registerSingleton<SearchSourcePrefs>(SearchSourcePrefs());
    sl.registerSingleton<SourceHealthStore>(_FakeHealth());
    final repo = _FakeSourceRepo();
    sl.registerSingleton<SourceRepository>(repo);
    sl.registerSingleton<CatalogueRepository>(repo);
    sl.registerSingleton<MyListStore>(_FakeMyListStore());
    sl.registerSingleton<TitleSuggestionService>(_NoLiveSuggestions());
  });

  tearDown(() async {
    await disposePickerDeps();
    await sl.reset();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  group('SearchHistory.restore', () {
    test('puts the cleared list back after newer searches', () async {
      final before = history.recent().toList();
      await history.clear();
      await history.add('bleach');
      await history.restore(before);
      expect(history.recent(), ['bleach', 'naruto', 'naruto shippuden']);
    });

    test('skips duplicates and blanks', () async {
      await history.restore(['NARUTO', '  ', 'one piece']);
      expect(history.recent(), ['naruto', 'naruto shippuden', 'one piece']);
    });
  });

  winTestWidgets('Windows Esc: suggestions, then text, then focus (search-1)', (
    t,
  ) async {
    await t.pumpWidget(harness());
    await t.pumpAndSettle();
    await typeQuery(t, 'nar');
    expect(fillArrow('naruto'), findsOneWidget);

    // 1st Esc hides the suggestion list, text and focus stay.
    expect(await t.sendKeyEvent(LogicalKeyboardKey.escape), isTrue);
    await t.pumpAndSettle();
    expect(fillArrow('naruto'), findsNothing);
    expect(fieldText(t), 'nar');
    expect(fieldFocus(t).hasFocus, isTrue);

    // 2nd Esc clears the text.
    expect(await t.sendKeyEvent(LogicalKeyboardKey.escape), isTrue);
    await t.pumpAndSettle();
    expect(fieldText(t), isEmpty);
    expect(fieldFocus(t).hasFocus, isTrue);

    // 3rd Esc leaves the box; the next one is the app's to handle.
    expect(await t.sendKeyEvent(LogicalKeyboardKey.escape), isTrue);
    await t.pumpAndSettle();
    expect(fieldFocus(t).hasFocus, isFalse);
  });

  winTestWidgets('typing again brings back suggestions hidden with Esc', (
    t,
  ) async {
    await t.pumpWidget(harness());
    await t.pumpAndSettle();
    await typeQuery(t, 'nar');
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(fillArrow('naruto'), findsNothing);

    await typeQuery(t, 'naru');
    expect(fillArrow('naruto'), findsOneWidget);
  });

  winTestWidgets('Up/Down + Enter run the highlighted suggestion (search-7)', (
    t,
  ) async {
    await t.pumpWidget(harness());
    await t.pumpAndSettle();
    await typeQuery(t, 'nar');

    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown); // stays on the last
    await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.pumpAndSettle();
    expect(await t.sendKeyEvent(LogicalKeyboardKey.enter), isTrue);
    await t.pumpAndSettle();

    expect(fieldText(t), 'naruto shippuden');
    // The box keeps focus on Windows so the query can be refined.
    expect(fieldFocus(t).hasFocus, isTrue);
  });

  winTestWidgets('Up through a long list scrolls the highlight back into view', (
    t,
  ) async {
    // A short window and many live suggestions, so the list scrolls.
    t.view.physicalSize = const Size(900, 420);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    sl.unregister<TitleSuggestionService>();
    sl.registerSingleton<TitleSuggestionService>(_ManyLiveSuggestions());
    await t.pumpWidget(harness());
    await t.pumpAndSettle();
    await typeQuery(t, 'nar');

    // Top edge of the suggestion list's viewport, and of row index 1.
    final list = find.ancestor(
      of: fillArrow('naruto shippuden'),
      matching: find.byType(Scrollable),
    );
    final listTop = t.getRect(list.first).top;
    // skipOffstage: false, so the row is found while scrolled out of view.
    double rowTop() => t
        .getRect(
          find.byKey(
            const ValueKey('search-suggestion-fill-naruto shippuden'),
            skipOffstage: false,
          ),
        )
        .top;

    // The list is capped at 8 rows: Down to the last one (index 7)...
    for (var i = 0; i < 8; i++) {
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.pumpAndSettle();
    }
    expect(
      t.state<ScrollableState>(list.first).position.pixels,
      greaterThan(0),
      reason: 'the list must have scrolled to show the last row',
    );
    expect(rowTop(), lessThan(listTop), reason: 'row 1 is scrolled off');
    // ...then Up six times to the second row (index 1).
    for (var i = 0; i < 6; i++) {
      await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await t.pumpAndSettle();
    }
    // The highlighted row is back inside the viewport.
    expect(rowTop(), greaterThanOrEqualTo(listTop - 0.5));
  });

  winTestWidgets('Tab fills in the highlighted suggestion without running it', (
    t,
  ) async {
    await t.pumpWidget(harness());
    await t.pumpAndSettle();
    await typeQuery(t, 'nar');

    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(await t.sendKeyEvent(LogicalKeyboardKey.tab), isTrue);
    await t.pump(const Duration(milliseconds: 300));
    await t.pumpAndSettle();

    expect(fieldText(t), 'naruto');
    expect(fieldFocus(t).hasFocus, isTrue);
    // Still on the suggestion list (not results): the other suggestion's
    // arrow is there (the exact match itself is never suggested).
    expect(fillArrow('naruto shippuden'), findsOneWidget);
  });

  winTestWidgets('Right fills in only with the caret at the end', (t) async {
    await t.pumpWidget(harness());
    await t.pumpAndSettle();
    await typeQuery(t, 'nar');
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(await t.sendKeyEvent(LogicalKeyboardKey.arrowRight), isTrue);
    await t.pumpAndSettle();
    expect(fieldText(t), 'naruto');
  });

  winTestWidgets('fill-in arrow has a tooltip and fills the box', (t) async {
    await t.pumpWidget(harness());
    await t.pumpAndSettle();
    await typeQuery(t, 'nar');

    final tooltip = find.ancestor(
      of: fillArrow('naruto shippuden'),
      matching: find.byType(Tooltip),
    );
    expect(tooltip, findsOneWidget);
    expect(t.getSize(fillArrow('naruto shippuden')).width, greaterThan(30));
    await t.tap(fillArrow('naruto shippuden'));
    await t.pump(const Duration(milliseconds: 300));
    await t.pumpAndSettle();
    expect(fieldText(t), 'naruto shippuden');
  });

  winTestWidgets('Enter on typed text keeps focus on Windows', (t) async {
    await t.pumpWidget(harness());
    await t.pumpAndSettle();
    await typeQuery(t, 'zzz');
    await t.testTextInput.receiveAction(TextInputAction.search);
    await t.pumpAndSettle();
    expect(fieldFocus(t).hasFocus, isTrue);
  });

  winTestWidgets('Clear all can be undone on Windows (search-9)', (t) async {
    await t.pumpWidget(harness());
    await t.pumpAndSettle();
    expect(find.text('naruto shippuden'), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('search-recent-clear')));
    await t.pumpAndSettle();
    expect(history.recent(), isEmpty);
    expect(find.text('naruto shippuden'), findsNothing);
    expect(find.text('Recent searches cleared'), findsOneWidget);

    await t.tap(find.text('Undo'));
    await t.pumpAndSettle();
    expect(history.recent(), ['naruto', 'naruto shippuden']);
    expect(find.text('naruto shippuden'), findsOneWidget);
  });

  winTestWidgets('recent chips show a remove x on hover on Windows', (t) async {
    await t.pumpWidget(harness());
    await t.pumpAndSettle();

    final remove = find.byKey(const ValueKey('search-recent-remove-naruto'));
    expect(remove, findsOneWidget);
    // Hidden (and not clickable) until the chip is hovered.
    expect(
      t
          .widget<AnimatedOpacity>(
            find.ancestor(of: remove, matching: find.byType(AnimatedOpacity)),
          )
          .opacity,
      0,
    );

    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(t.getCenter(find.text('naruto')));
    await t.pumpAndSettle();
    expect(
      t
          .widget<AnimatedOpacity>(
            find.ancestor(of: remove, matching: find.byType(AnimatedOpacity)),
          )
          .opacity,
      1,
    );

    await t.tap(remove);
    await t.pumpAndSettle();
    expect(history.recent(), ['naruto shippuden']);
  });

  testWidgets('phone keeps its search box unchanged', (t) async {
    await t.pumpWidget(harness());
    await t.pumpAndSettle();
    // Default (sources) style has no per-chip x on phone.
    expect(
      find.byKey(const ValueKey('search-recent-remove-naruto')),
      findsNothing,
    );
    await typeQuery(t, 'nar');
    // No Windows fill-in button, and Esc is not taken by the field.
    expect(fillArrow('naruto'), findsNothing);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(fieldText(t), 'nar');

    // Clear wipes at once, with no undo toast.
    await t.enterText(find.byType(TextField), '');
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('search-recent-clear')));
    await t.pumpAndSettle();
    expect(history.recent(), isEmpty);
    expect(find.text('Recent searches cleared'), findsNothing);
  });

  group('SearchRowScroller (search-3)', () {
    Widget row() => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 60,
          child: SearchRowScroller(
            builder: (controller) => ListView(
              controller: controller,
              scrollDirection: Axis.horizontal,
              children: [
                for (var i = 0; i < 30; i++)
                  SizedBox(width: 100, child: Text('item $i')),
              ],
            ),
          ),
        ),
      ),
    );

    winTestWidgets('Windows wraps the row in DesktopRowScroller', (t) async {
      await t.pumpWidget(row());
      await t.pumpAndSettle();
      expect(find.byType(DesktopRowScroller), findsOneWidget);

      // A mouse can drag the row sideways.
      final listView = find.byType(Scrollable);
      final before = t.state<ScrollableState>(listView).position.pixels;
      final mouse = await t.startGesture(
        t.getCenter(listView),
        kind: PointerDeviceKind.mouse,
      );
      await mouse.moveBy(const Offset(-300, 0));
      await mouse.up();
      await t.pumpAndSettle();
      expect(
        t.state<ScrollableState>(listView).position.pixels,
        greaterThan(before),
      );
    });

    testWidgets('phone gets the plain row', (t) async {
      await t.pumpWidget(row());
      await t.pumpAndSettle();
      expect(find.byType(DesktopRowScroller), findsNothing);
    });
  });

  group('filter sheets (search-4)', () {
    Future<void> openMeta(WidgetTester t) async {
      await t.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (ctx) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showMetaFilterSheet(
                    ctx,
                    ZKind.anime,
                    const MetaFilters(),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
    }

    const dialogKey = ValueKey('desktop-adaptive-sheet');

    winTestWidgets('Windows: centred dialog, pickers open as dialogs', (
      t,
    ) async {
      t.view.physicalSize = const Size(1600, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await openMeta(t);
      expect(find.byKey(dialogKey), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(DraggableScrollableSheet), findsNothing);

      await t.tap(find.text('GENRES'));
      await t.pumpAndSettle();
      // The genre picker is a second dialog over the first, not a sheet.
      expect(find.byKey(dialogKey), findsNWidgets(2));
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('Action'), findsOneWidget);
    });

    testWidgets('phone keeps the bottom sheet', (t) async {
      await openMeta(t);
      expect(find.byKey(dialogKey), findsNothing);
      expect(find.byType(BottomSheet), findsOneWidget);
    });
  });
}
