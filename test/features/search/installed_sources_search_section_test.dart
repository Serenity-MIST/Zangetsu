// R4: a catalogue (Library) search in novel/manga mode on Windows also lists
// what the installed sources found, so a web novel the catalogue does not
// know no longer ends at "No results".
//
// Round 3: the source results are merged into one poster grid (no "From your
// sources" heading, no per-source group headers), each card carrying its
// source's name under the title, with one slim status line for sources still
// answering or failed (retry in that line's menu).
//
// Pins: results from a working source show with their source name and open
// through onOpen, a source that throws shows the slim failed status whose
// menu retries it, a newer query cancels the older one's results, history is
// not written twice, the per-run concurrency cap holds, and the gate leaves
// anime mode and phone alone.
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/playback/search_history.dart';
import 'package:watch_app/core/playback/search_prefs.dart';
import 'package:watch_app/core/playback/search_source_prefs.dart';
import 'package:watch_app/core/playback/source_health_store.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/search/title_suggestion_service.dart';
import 'package:watch_app/features/search/bloc/search_bloc.dart';
import 'package:watch_app/features/search/bloc/search_event.dart';
import 'package:watch_app/features/search/bloc/search_state.dart';
import 'package:watch_app/features/home/home_catalogue_prefs.dart';
import 'package:watch_app/features/search/desktop_quick_search.dart';
import 'package:watch_app/features/search/installed_sources_search_section.dart';

/// Remembered prefs say "current source only": the section must ignore that.
class _FakeSearchPrefs extends SearchPrefs {
  @override
  String? get contentFilterName => null;
  @override
  String? get audioFilterName => null;
  @override
  String? get statusFilterName => null;
  @override
  String? get sortName => null;
  @override
  String? get genre => null;
  @override
  int? get decade => null;
  @override
  bool get currentSourceOnly => true;
}

/// Records what would have been written to history.
class _FakeSearchHistory extends SearchHistory {
  final List<String> added = [];
  @override
  List<String> recent() => [];
  @override
  Future<void> add(String query) async => added.add(query);
}

class _FakeSuggestions extends TitleSuggestionService {
  _FakeSuggestions() : super(Dio());
  @override
  Future<List<String>> suggest(String query, {int limit = 8}) async => [];
}

class _FakeSearchSourcePrefs extends SearchSourcePrefs {
  @override
  bool isIncluded(String id) => true;
}

/// Never skips a source and never marks one dead, so every test queries all.
class _FakeHealth extends SourceHealthStore {
  @override
  SourceHealth statusOf(String id) => SourceHealth.ok;
  @override
  bool isSkippable(String id) => false;
  @override
  Future<void> record(
    String id,
    SourceOutcome outcome, {
    int? responseMs,
  }) async {}
  @override
  Future<void> clear(String id) async {}
}

/// Installed sources: novel `lnr:a` / `lnr:b`, plus an anime source the novel
/// fan-out must never query. [answer] decides each (source, query) result.
class _FakeSourceRepo implements SourceRepository {
  _FakeSourceRepo(this.installed);

  final List<({String id, String name})> installed;

  /// Per call: return a future of items, or throw to fail that source.
  Future<List<MediaItem>> Function(String sourceId, String query) answer =
      (_, _) async => const [];

  final List<String> searched = [];
  int inFlight = 0;
  int maxInFlight = 0;

  @override
  List<({String id, String name})> get loadedSources => installed;

  @override
  String displayName(String id) => installed
      .firstWhere((s) => s.id == id, orElse: () => (id: id, name: id))
      .name;

  @override
  void syncSearchCache() {}

  @override
  Future<({List<MediaItem> items, SourceOutcome outcome})> searchStatus(
    String query, {
    String category = 'sub',
    String? sourceId,
    String? filtersJson,
    bool cache = false,
    int page = 1,
  }) async {
    searched.add('$sourceId|$query');
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      final items = await answer(sourceId!, query);
      return (
        items: items,
        outcome: items.isEmpty ? SourceOutcome.empty : SourceOutcome.ok,
      );
    } finally {
      inFlight--;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

MediaItem _novel(String sourceId, String title) => MediaItem(
  id: '$sourceId-$title',
  title: title,
  url: 'https://example.test/$sourceId/$title',
  type: ProviderType.novel,
  sourceId: sourceId,
);

void main() {
  late Directory dir;
  late _FakeSourceRepo repo;
  late _FakeSearchHistory history;

  SearchBloc buildBloc(ContentMode mode, {int? cap = 4}) => SearchBloc(
    repo: repo,
    history: history,
    prefs: _FakeSearchPrefs(),
    suggestions: _FakeSuggestions(),
    forceMode: mode,
    maxConcurrent: cap,
    recordHistory: false,
    forceAllSources: true,
  );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('installed_sources_section');
    Hive.init(dir.path);
    history = _FakeSearchHistory();
    repo = _FakeSourceRepo(const [
      (id: 'lnr:a', name: 'Novel Source A'),
      (id: 'lnr:b', name: 'Novel Source B'),
      (id: 'ani:1', name: 'Anime Source'),
    ]);
    sl.registerSingleton<SearchSourcePrefs>(_FakeSearchSourcePrefs());
    sl.registerSingleton<SourceHealthStore>(_FakeHealth());
    sl.registerSingleton<SourceRepository>(repo);
  });

  tearDown(() async {
    await sl.reset();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  Widget harness(String query, {required ValueChanged<MediaItem> onOpen}) =>
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              InstalledSourcesSearchSection(
                query: query,
                mode: ContentMode.novel,
                catalogueEmpty: true,
                onOpen: onOpen,
                createBloc: buildBloc,
              ),
            ],
          ),
        ),
      );

  testWidgets(
    'merged grid: source name under the title, slim failed status, opens',
    (t) async {
      var failB = true;
      repo.answer = (id, q) async {
        if (id == 'lnr:b' && failB) throw StateError('source down');
        return [_novel(id, 'Global Rebirth $id')];
      };
      MediaItem? opened;
      await t.pumpWidget(
        harness(
          'Global Rebirth: Awakening the Godly Power Again',
          onOpen: (i) => opened = i,
        ),
      );
      // Debounced: nothing searched before the wait is over; only the slim
      // "searching" status shows meanwhile.
      expect(repo.searched, isEmpty);
      expect(find.text('Searching your sources…'), findsOneWidget);

      await t.pump(const Duration(milliseconds: 450));
      await t.pump();
      await t.pump();

      // No section heading, explainer or per-source group header any more.
      expect(find.text('From your sources'), findsNothing);
      expect(find.textContaining('catalogue had no match'), findsNothing);
      expect(find.text('Novel Source A  1'), findsNothing);
      // One merged grid; the card carries its source's name as a line.
      expect(
        find.byKey(const ValueKey('installed_sources_grid')),
        findsOneWidget,
      );
      final sourceLine = find.byKey(
        const ValueKey('installed_sources_source_lnr:a-Global Rebirth lnr:a'),
      );
      expect(sourceLine, findsOneWidget);
      expect(t.widget<Text>(sourceLine).data, 'Novel Source A');
      // The source line sits below the card's title.
      expect(
        t.getTopLeft(sourceLine).dy,
        greaterThan(t.getTopLeft(find.text('Global Rebirth lnr:a')).dy),
      );
      // B failed: one compact status, not a full line per source.
      expect(find.text('1 source failed'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('installed_sources_failed_menu')),
        findsOneWidget,
      );
      // Novel mode never queries the anime source.
      expect(repo.searched.any((s) => s.startsWith('ani:1')), isFalse);
      // The catalogue search already wrote history; the section must not.
      expect(history.added, isEmpty);

      await t.tap(find.text('Global Rebirth lnr:a'));
      expect(opened?.sourceId, 'lnr:a');

      // Retry B from the status menu: its result joins the same grid.
      failB = false;
      await t.tap(find.byKey(const ValueKey('installed_sources_failed_menu')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('installed_sources_retry_lnr:b')));
      await t.pumpAndSettle();
      expect(find.text('Global Rebirth lnr:b'), findsOneWidget);
      expect(find.text('Novel Source B'), findsOneWidget);
      expect(find.text('1 source failed'), findsNothing);
    },
    // The section only ships on Windows: lay out with the desktop grid.
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('pending sources show one slim "Searching N sources" line', (
    t,
  ) async {
    final slow = Completer<List<MediaItem>>();
    repo.answer = (id, q) =>
        id == 'lnr:b' ? slow.future : Future.value([_novel(id, 'Fast $id')]);
    await t.pumpWidget(harness('q', onOpen: (_) {}));
    await t.pump(const Duration(milliseconds: 450));
    await t.pump();
    await t.pump();
    // A already landed in the grid while B is still answering.
    expect(find.text('Fast lnr:a'), findsOneWidget);
    expect(find.text('Searching 1 source…'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('installed_sources_status')),
      findsOneWidget,
    );

    slow.complete(const []);
    await t.pump();
    await t.pump();
    // Everything answered: the status line goes away entirely.
    expect(
      find.byKey(const ValueKey('installed_sources_status')),
      findsNothing,
    );
  });

  testWidgets('a new query cancels the older one', (t) async {
    final oldA = Completer<List<MediaItem>>();
    repo.answer = (id, q) {
      if (q == 'old' && id == 'lnr:a') return oldA.future;
      if (q == 'new') return Future.value([_novel(id, 'New hit $id')]);
      return Future.value(const <MediaItem>[]);
    };
    await t.pumpWidget(harness('old', onOpen: (_) {}));
    await t.pump(const Duration(milliseconds: 450));
    await t.pump();
    // Source A is still answering the old query: the slim searching status,
    // not results.
    expect(find.text('Searching 1 source…'), findsOneWidget);

    await t.pumpWidget(harness('new', onOpen: (_) {}));
    await t.pump(const Duration(milliseconds: 450));
    await t.pump();
    // The old run finishes late; its result must not land on screen.
    oldA.complete([_novel('lnr:a', 'Old hit')]);
    await t.pump();
    await t.pump();

    expect(find.text('Old hit'), findsNothing);
    expect(find.text('New hit lnr:a'), findsOneWidget);
    expect(find.text('New hit lnr:b'), findsOneWidget);
  });

  test('maxConcurrent caps how many sources are queried at once', () async {
    repo = _FakeSourceRepo([
      for (var i = 0; i < 6; i++) (id: 'lnr:$i', name: 'Novel $i'),
    ]);
    repo.answer = (id, q) async {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return [_novel(id, 'Hit $id')];
    };
    final bloc = buildBloc(ContentMode.novel, cap: 2);
    bloc.add(const SearchRunRequested('q'));
    await bloc.stream.firstWhere(
      (s) => s.status == SearchStatus.success && s.groups.length == 6,
    );
    expect(repo.maxInFlight, 2);
    expect(bloc.state.currentSourceOnly, isFalse);
    await bloc.close();
  });

  test('gate: Windows catalogue search in novel/manga only', () {
    const win = TargetPlatform.windows;
    expect(
      installedSourcesFallbackApplies(
        libraryScope: true,
        mode: ContentMode.novel,
        platform: win,
      ),
      isTrue,
    );
    expect(
      installedSourcesFallbackApplies(
        libraryScope: true,
        mode: ContentMode.manga,
        platform: win,
      ),
      isTrue,
    );
    // Anime/movies: catalogue only, as before.
    expect(
      installedSourcesFallbackApplies(
        libraryScope: true,
        mode: ContentMode.anime,
        platform: win,
      ),
      isFalse,
    );
    // Sources scope already searches installed sources.
    expect(
      installedSourcesFallbackApplies(
        libraryScope: false,
        mode: ContentMode.novel,
        platform: win,
      ),
      isFalse,
    );
    // Phone unchanged.
    expect(
      installedSourcesFallbackApplies(
        libraryScope: true,
        mode: ContentMode.novel,
        platform: TargetPlatform.android,
      ),
      isFalse,
    );
  });

  // Novel "Browse" / source catalogues: searching means the installed
  // sources, and the page and dropdown read the fan-out the same way.
  group('no tracker catalogue', () {
    test('gate: anime with a source catalogue also asks the sources', () {
      const win = TargetPlatform.windows;
      expect(
        installedSourcesFallbackApplies(
          libraryScope: true,
          mode: ContentMode.anime,
          platform: win,
          catalogueKind: HomeCatalogueKind.source,
        ),
        isTrue,
      );
      // Tracker (AniList / TMDB ...) and Stremio keep the catalogue only.
      for (final kind in [
        HomeCatalogueKind.metadata,
        HomeCatalogueKind.stremio,
      ]) {
        expect(
          installedSourcesFallbackApplies(
            libraryScope: true,
            mode: ContentMode.anime,
            platform: win,
            catalogueKind: kind,
          ),
          isFalse,
        );
      }
      // Phone never.
      expect(
        installedSourcesFallbackApplies(
          libraryScope: true,
          mode: ContentMode.anime,
          platform: TargetPlatform.android,
          catalogueKind: HomeCatalogueKind.source,
        ),
        isFalse,
      );
    });

    test('novel Browse and source catalogues have no tracker', () {
      bool noTracker(ContentMode m, HomeCatalogueKind k) =>
          desktopCatalogueHasNoTracker(m, catalogueKind: k);
      expect(noTracker(ContentMode.novel, HomeCatalogueKind.metadata), isTrue);
      expect(noTracker(ContentMode.manga, HomeCatalogueKind.metadata), isFalse);
      expect(noTracker(ContentMode.anime, HomeCatalogueKind.metadata), isFalse);
      for (final m in ContentMode.values) {
        expect(noTracker(m, HomeCatalogueKind.source), isTrue);
        expect(noTracker(m, HomeCatalogueKind.stremio), isFalse);
      }
    });

    test('"No results" waits for the sources; count includes them', () {
      const q = 'i can devour monsters';
      // Nothing published for this query yet: treated as still searching.
      expect(
        installedSourcesMayHaveResults(const InstalledSourcesProgress(), q),
        isTrue,
      );
      expect(
        installedSourcesMayHaveResults(
          const InstalledSourcesProgress(query: q, searching: true),
          q,
        ),
        isTrue,
      );
      expect(
        installedSourcesMayHaveResults(
          const InstalledSourcesProgress(query: q, resultCount: 3),
          q,
        ),
        isTrue,
      );
      // Every source answered, none had it: now "No results" is true.
      expect(
        installedSourcesMayHaveResults(
          const InstalledSourcesProgress(query: q),
          q,
        ),
        isFalse,
      );

      // Header: 0 catalogue titles + 3 source titles reads 3, not 0.
      final done = desktopResultsCountWithSources(
        catalogueCount: 0,
        progress: const InstalledSourcesProgress(
          query: q,
          resultCount: 3,
          sourceCount: 2,
        ),
        query: q,
      );
      expect(done.count, 3);
      expect(done.searching, isFalse);
      // Still answering: flagged, so the header never says "0 titles".
      final busy = desktopResultsCountWithSources(
        catalogueCount: 0,
        progress: const InstalledSourcesProgress(query: q, searching: true),
        query: q,
      );
      expect(busy.searching, isTrue);
      // Catalogue still loading: no count line at all.
      expect(
        desktopResultsCountWithSources(
          catalogueCount: null,
          progress: const InstalledSourcesProgress(query: q, resultCount: 3),
          query: q,
        ).count,
        isNull,
      );
      // Another query's progress never leaks into this count.
      expect(
        desktopResultsCountWithSources(
          catalogueCount: 2,
          progress: const InstalledSourcesProgress(
            query: 'old',
            resultCount: 9,
          ),
          query: q,
        ).count,
        2,
      );
    });

    testWidgets('section publishes progress: searching, then the count', (
      t,
    ) async {
      final slow = Completer<List<MediaItem>>();
      repo.answer = (id, q) => id == 'lnr:b'
          ? slow.future
          : Future.value([_novel(id, 'Devour $id'), _novel(id, 'Devour 2')]);
      final progress = ValueNotifier(const InstalledSourcesProgress());
      addTearDown(progress.dispose);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                InstalledSourcesSearchSection(
                  query: 'devour',
                  mode: ContentMode.novel,
                  onOpen: (_) {},
                  createBloc: buildBloc,
                  progress: progress,
                ),
              ],
            ),
          ),
        ),
      );
      await t.pump();
      // Debounce pending: already "searching" for this query.
      expect(progress.value.isFor('devour'), isTrue);
      expect(progress.value.searching, isTrue);

      await t.pump(const Duration(milliseconds: 450));
      await t.pump();
      await t.pump();
      // A answered with two titles; B is still answering.
      expect(progress.value.resultCount, 2);
      expect(progress.value.sourceCount, 1);
      expect(progress.value.searching, isTrue);

      slow.complete([_novel('lnr:b', 'Devour B')]);
      await t.pump();
      await t.pump();
      expect(progress.value.resultCount, 3);
      expect(progress.value.sourceCount, 2);
      expect(progress.value.searching, isFalse);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    test('quick fan-out streams first titles with source names', () async {
      final slow = Completer<List<MediaItem>>();
      repo.answer = (id, q) => id == 'lnr:b'
          ? slow.future
          : Future.value([_novel(id, 'I Can Devour Monsters')]);
      final results = <QuickSearchResult>[];
      final done = Completer<void>();
      final sub = quickSourcesSearch(
        'i can devour monsters',
        limit: 4,
        createBloc: () => buildBloc(ContentMode.novel),
      ).listen(results.add, onDone: done.complete);
      // Wait for A's partial answer while B is still out.
      while (!results.any((r) => r.items.isNotEmpty)) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      final partial = results.lastWhere((r) => r.items.isNotEmpty);
      expect(partial.items.single.title, 'I Can Devour Monsters');
      expect(partial.sourceNames.single, 'Novel Source A');
      expect(partial.searching, isTrue);
      expect(partial.pendingSources, 1);

      slow.complete(const []);
      await done.future;
      final last = results.last;
      expect(last.searching, isFalse);
      expect(last.items, hasLength(1));
      expect(last.failed, isFalse);
      // Novel fan-out never queries the anime source.
      expect(repo.searched.any((s) => s.startsWith('ani:1')), isFalse);
      await sub.cancel();
    });

    test('quick fan-out stops once the limit is in', () async {
      repo = _FakeSourceRepo([
        for (var i = 0; i < 6; i++) (id: 'lnr:$i', name: 'Novel $i'),
      ]);
      sl.unregister<SourceRepository>();
      sl.registerSingleton<SourceRepository>(repo);
      final never = Completer<List<MediaItem>>();
      repo.answer = (id, q) => id == 'lnr:0' || id == 'lnr:1'
          ? Future.value([_novel(id, 'Hit $id'), _novel(id, 'Hit2 $id')])
          : never.future;
      final results = await quickSourcesSearch(
        'q',
        limit: 4,
        createBloc: () => buildBloc(ContentMode.novel, cap: 6),
      ).toList();
      // Ended without waiting for the four sources that never answer.
      expect(results.last.searching, isFalse);
      expect(results.last.items, hasLength(4));
    });

    test('quick fan-out with no installed source says so', () async {
      repo = _FakeSourceRepo(const [(id: 'ani:1', name: 'Anime Source')]);
      sl.unregister<SourceRepository>();
      sl.registerSingleton<SourceRepository>(repo);
      final results = await quickSourcesSearch(
        'q',
        limit: 4,
        createBloc: () => buildBloc(ContentMode.novel),
      ).toList();
      expect(results.last.items, isEmpty);
      expect(results.last.noSources, isTrue);
      expect(results.last.searching, isFalse);
    });

    test('quick fan-out: every source failing is a failure', () async {
      repo.answer = (id, q) async => throw StateError('down');
      final results = await quickSourcesSearch(
        'q',
        limit: 4,
        createBloc: () => buildBloc(ContentMode.novel),
      ).toList();
      expect(results.last.items, isEmpty);
      expect(results.last.failed, isTrue);
    });
  });
}
