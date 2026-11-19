// The Windows search results page header (mockup q1): "Results for “q”",
// the title count, filter chips that open compact menus, Clear filters, and
// only ONE search box on the shell's results page.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
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
import 'package:watch_app/features/home/search_screen.dart';
import 'package:watch_app/features/search/bloc/search_event.dart';
import 'package:watch_app/features/search/bloc/search_state.dart';
import 'package:watch_app/features/search/desktop_results_header.dart';
import 'package:watch_app/l10n/app_localizations.dart';

import '../../support/picker_deps.dart';

/// A widget test run as Windows; the variant resets the platform override.
void winTestWidgets(String description, WidgetTesterCallback body) =>
    testWidgets(
      description,
      body,
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

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

class _NoLiveSuggestions implements TitleSuggestionService {
  @override
  Future<List<String>> suggest(String query, {int limit = 8}) async => const [];

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// Hosts [child] with localisations and no animations.
Widget _app(Widget child) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (context, c) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: true),
    child: c!,
  ),
  home: Scaffold(body: child),
);

/// A result with a genre, so the sources Genre chip has something to offer.
MediaItem _item(String title) => MediaItem(
  id: title,
  title: title,
  url: '/$title',
  type: ProviderType.anime,
  sourceId: 'src',
  genres: const ['Action'],
);

void main() {
  group('header widget', () {
    winTestWidgets('shows the query, the count and the chips', (t) async {
      await t.pumpWidget(
        _app(
          Builder(
            builder: (context) => DesktopResultsHeader(
              query: 'naruto',
              count: 24,
              chips: desktopSourcesFilterChips(
                context,
                state: SearchState(),
                dispatch: (_) {},
                onMoreFilters: () {},
              ),
            ),
          ),
        ),
      );
      expect(find.text('Results for “naruto”'), findsOneWidget);
      expect(find.text('24 titles'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('desktop-results-chip-type')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('desktop-results-chip-status')),
        findsOneWidget,
      );
      expect(find.text('Sort: Best match'), findsOneWidget);
      // Sources carry no year filter; no genres known yet either.
      expect(
        find.byKey(const ValueKey('desktop-results-chip-year')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('desktop-results-chip-genre')),
        findsNothing,
      );
      // Nothing active: no Clear filters.
      expect(find.byKey(const ValueKey('desktop-results-clear')), findsNothing);
    });

    winTestWidgets('installed sources still answering: never "0 titles"', (
      t,
    ) async {
      Future<String?> countLine({int? count, bool searching = false}) async {
        await t.pumpWidget(
          _app(
            DesktopResultsHeader(
              query: 'i can devour monsters',
              count: count,
              searchingSources: searching,
            ),
          ),
        );
        final f = find.byKey(const ValueKey('desktop-results-count'));
        return f.evaluate().isEmpty ? null : t.widget<Text>(f).data;
      }

      expect(
        await countLine(count: 0, searching: true),
        'Searching your sources…',
      );
      expect(
        await countLine(count: 2, searching: true),
        '2 titles · searching sources…',
      );
      expect(await countLine(count: 3), '3 titles');
      expect(await countLine(count: 1), '1 title');
      expect(await countLine(), isNull);
    });

    winTestWidgets('a Status menu pick dispatches the status event', (t) async {
      final events = <SearchEvent>[];
      await t.pumpWidget(
        _app(
          Builder(
            builder: (context) => DesktopResultsHeader(
              query: 'naruto',
              chips: desktopSourcesFilterChips(
                context,
                state: SearchState(
                  status: SearchStatus.success,
                  groups: [
                    SourceResultGroup(
                      sourceId: 'src',
                      sourceName: 'Src',
                      items: [_item('Naruto')],
                    ),
                  ],
                ),
                dispatch: events.add,
                onMoreFilters: () {},
              ),
            ),
          ),
        ),
      );
      await t.tap(find.byKey(const ValueKey('desktop-results-chip-status')));
      await t.pumpAndSettle();
      // The compact menu lists every status, the current one ticked.
      expect(find.text('Ongoing'), findsOneWidget);
      await t.tap(find.text('Ongoing'));
      await t.pumpAndSettle();
      expect(
        events.single,
        const SearchStatusFilterChanged(SearchStatusFilter.ongoing),
      );

      // Genres come from the results.
      await t.tap(find.byKey(const ValueKey('desktop-results-chip-genre')));
      await t.pumpAndSettle();
      await t.tap(find.text('Action'));
      await t.pumpAndSettle();
      expect(events.last, const SearchGenreFilterChanged('Action'));
    });

    winTestWidgets('the menu works from the keyboard', (t) async {
      final events = <SearchEvent>[];
      await t.pumpWidget(
        _app(
          Builder(
            builder: (context) => DesktopResultsHeader(
              query: 'naruto',
              chips: desktopSourcesFilterChips(
                context,
                state: SearchState(),
                dispatch: events.add,
                onMoreFilters: () {},
              ),
            ),
          ),
        ),
      );
      // Tab to the first chip (Type), Enter opens it, Down x2 + Enter picks
      // "Anime" (All, Anime, Movies & Series).
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();
      expect(
        events.single,
        const SearchContentFilterChanged(SearchContentFilter.anime),
      );
    });

    winTestWidgets('library chips edit the filters; Clear keeps NSFW', (
      t,
    ) async {
      MetaFilters? changed;
      var more = 0;
      var filters = const MetaFilters(adult: true, year: 2020);
      await t.pumpWidget(
        _app(
          StatefulBuilder(
            builder: (context, setState) => DesktopResultsHeader(
              query: 'naruto',
              count: 3,
              chips: desktopLibraryFilterChips(
                context,
                filters: filters,
                kind: ZKind.anime,
                supportsFilters: true,
                onChanged: (f) => setState(() => filters = changed = f),
                onMoreFilters: () => more++,
              ),
              onClearFilters: filters.narrowsCatalogue
                  ? () => setState(
                      () => filters = desktopClearedMetaFilters(filters),
                    )
                  : null,
            ),
          ),
        ),
      );
      expect(find.text('3 titles'), findsOneWidget);
      // The active Year chip spells its value.
      expect(find.textContaining('2020'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('desktop-results-chip-type')));
      await t.pumpAndSettle();
      await t.tap(find.text('OVA'));
      await t.pumpAndSettle();
      expect(changed!.format, MetaFormat.ova);
      expect(changed!.year, 2020, reason: 'other picks are kept');

      await t.tap(find.byKey(const ValueKey('desktop-results-chip-sort')));
      await t.pumpAndSettle();
      await t.tap(find.text('Newest').last);
      await t.pumpAndSettle();
      expect(changed!.sort, MetaSort.newest);

      await t.tap(find.byKey(const ValueKey('desktop-results-chip-more')));
      await t.pump();
      expect(more, 1);

      await t.tap(find.byKey(const ValueKey('desktop-results-clear')));
      await t.pump();
      expect(filters.narrowsCatalogue, isFalse);
      expect(filters.adult, isTrue);
      expect(find.byKey(const ValueKey('desktop-results-clear')), findsNothing);
    });

    winTestWidgets('no Format chip for manga; none at all when unsupported', (
      t,
    ) async {
      late List<DesktopFilterChipSpec> manga;
      late List<DesktopFilterChipSpec> unsupported;
      await t.pumpWidget(
        _app(
          Builder(
            builder: (context) {
              manga = desktopLibraryFilterChips(
                context,
                filters: const MetaFilters(),
                kind: ZKind.manga,
                supportsFilters: true,
                onChanged: (_) {},
                onMoreFilters: () {},
              );
              unsupported = desktopLibraryFilterChips(
                context,
                filters: const MetaFilters(),
                kind: ZKind.movie,
                supportsFilters: false,
                onChanged: (_) {},
                onMoreFilters: () {},
              );
              return const SizedBox();
            },
          ),
        ),
      );
      expect(manga.map((c) => c.id), [
        'genre',
        'year',
        'status',
        'sort',
        'more',
      ]);
      expect(unsupported.map((c) => c.id), ['more']);
    });
  });

  group('results page', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('desktop_results_header');
      Hive.init(dir.path);
      await Hive.openBox<dynamic>(SearchHistory.boxName, bytes: Uint8List(0));
      await SearchHistory.init();
      await SearchPrefs.init();
      await SearchSourcePrefs.init();
      await registerPickerDeps();
      sl.registerSingleton<SearchHistory>(SearchHistory());
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

    /// The search screen as the shell embeds it (or pushed with [showBack]).
    Widget page({required bool showBack}) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child!,
      ),
      home: BlocProvider<ActiveSourceCubit>.value(
        value: sl<ActiveSourceCubit>(),
        child: SearchScreen(
          forceSources: true,
          showBack: showBack,
          initialQuery: 'naruto',
        ),
      ),
    );

    winTestWidgets('the shell results page has no second search box', (
      t,
    ) async {
      await t.pumpWidget(page(showBack: false));
      await t.pumpAndSettle();
      // The top bar is the only box: the page shows a header instead.
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Results for “naruto”'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('desktop-results-chip-sort')),
        findsOneWidget,
      );
    });

    winTestWidgets('a pushed search keeps its own box', (t) async {
      await t.pumpWidget(page(showBack: true));
      await t.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      expect(
        find.byKey(const ValueKey('desktop-results-header')),
        findsNothing,
      );
    });

    testWidgets('phone keeps its search box', (t) async {
      await t.pumpWidget(page(showBack: false));
      await t.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      expect(
        find.byKey(const ValueKey('desktop-results-header')),
        findsNothing,
      );
    });
  });
}
