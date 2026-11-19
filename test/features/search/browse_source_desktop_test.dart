// Windows-only behaviour of a single source's page (search-browse group):
// search-2 (keep paging until the window can scroll, plus 'Load more'),
// search-8 (failures show the EmptyState panel with Retry, and a failed next
// page is recorded instead of silently stopping), search-11 ('Search all
// sources' under an empty result) and search-1 / shell-7 (Esc clears, then
// closes the in-page search; Ctrl+F opens it).

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/desktop/desktop_shortcut_catalog.dart';
import 'package:watch_app/core/desktop/desktop_shortcuts.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/playback/source_health_store.dart';
import 'package:watch_app/core/provider/base_provider.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/repository/catalogue_repository.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/features/search/browse_source_screen.dart';
import 'package:watch_app/features/search/cubit/browse_source_cubit.dart';

MediaItem _item(String id) => MediaItem(
  id: id,
  title: id,
  url: 'https://x.test/$id',
  type: ProviderType.anime,
  sourceId: 'cs:Src',
);

/// A source whose search and paging answers are scripted per test.
class _Repo implements SourceRepository, CatalogueRepository {
  bool searchThrows = false;
  List<MediaItem> first = const [];

  /// Next pages by number; a missing page answers empty (= the end).
  final Map<int, List<MediaItem>> nextPages = {};

  /// Pages that throw instead of answering.
  final Set<int> failingPages = {};
  final List<int> pageCalls = [];
  final List<String> searches = [];

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  bool hasSource(String id) => true;

  @override
  Future<bool> ensureSourceLoaded(String sourceId) async => true;

  @override
  Future<List<HomeSection>> home({
    String category = 'sub',
    String? sourceId,
  }) async => [
    HomeSection(title: 'Popular', items: [_item('home')]),
  ];

  @override
  Future<List<MediaItem>> search(
    String query, {
    String category = 'sub',
    String? sourceId,
  }) async {
    searches.add(query);
    if (searchThrows) throw StateError('offline');
    return first;
  }

  @override
  Future<({List<MediaItem> items, SourceOutcome outcome})> searchStatus(
    String query, {
    String category = 'sub',
    String? sourceId,
    String? filtersJson,
    bool cache = false,
    int page = 1,
  }) async {
    pageCalls.add(page);
    if (failingPages.contains(page)) throw StateError('page failed');
    return (items: nextPages[page] ?? const <MediaItem>[], outcome: SourceOutcome.ok);
  }

  @override
  String baseUrlFor(String sourceId) => '';

  @override
  Future<String?> cfSolveTargetFor(String sourceId) async => null;

  @override
  String displayName(String sourceId) => sourceId;

  @override
  String? languageFor(String sourceId) => null;
}

class _FakeCloudStreamManager extends ChangeNotifier
    implements CloudStreamManager {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  BaseProvider? get(String sourceId) => null;
  @override
  BaseProvider? resolveCompatible(String sourceId) => get(sourceId);
  @override
  String? repoNameForSourceId(String sourceId) => null;
}

void main() {
  late _Repo repo;

  setUp(() {
    cloudStreamHostOverride = (method, args) async => false;
    repo = _Repo();
    DesktopShortcuts.debugReset();
    registerDefaultDesktopShortcuts();
    sl.registerSingleton<ActiveSourceCubit>(
      ActiveSourceCubit(fallback: 'cs:1'),
    );
    sl.registerSingleton<CloudStreamManager>(_FakeCloudStreamManager());
    sl.registerSingleton<SourceRepository>(repo);
    sl.registerSingleton<AppMode>(const AppMode(isTv: false));
  });

  tearDown(() async {
    cloudStreamHostOverride = null;
    debugDefaultTargetPlatformOverride = null;
    await sl<ActiveSourceCubit>().close();
    await sl.reset();
  });

  Future<void> open(WidgetTester t) async {
    await t.pumpWidget(
      const MaterialApp(
        home: BrowseSourceScreen(sourceId: 'cs:Src', title: 'Src'),
      ),
    );
    await t.pumpAndSettle();
  }

  Future<void> searchFor(WidgetTester t, String q) async {
    await t.tap(find.byIcon(Icons.search));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), q);
    await t.testTextInput.receiveAction(TextInputAction.search);
    await t.pumpAndSettle();
  }

  group('cubit', () {
    test('a failed next page is recorded, and cleared by the next try', () async {
      final r = _Repo()
        ..first = [_item('a')]
        ..failingPages.add(2);
      final c = BrowseSourceCubit(repo: r, sourceId: 'cs:Src');
      await c.search('q');
      await c.loadMore();
      expect(c.state.loadMoreFailed, isTrue);
      expect(c.state.atEnd, isFalse);
      r.failingPages.clear();
      r.nextPages[2] = [_item('b')];
      await c.loadMore();
      expect(c.state.loadMoreFailed, isFalse);
      expect(c.state.searchResults!.map((m) => m.id), ['a', 'b']);
      await c.close();
    });
  });

  testWidgets('failed search shows the error panel and Retry re-runs it', (
    t,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    repo.searchThrows = true;
    await open(t);
    await searchFor(t, 'naruto');
    expect(find.byKey(const ValueKey('browse-source-failed')), findsOneWidget);
    repo
      ..searchThrows = false
      ..first = [_item('found')];
    await t.tap(find.text('Retry'));
    await t.pumpAndSettle();
    expect(repo.searches, ['naruto', 'naruto']);
    expect(find.byKey(const ValueKey('browse-source-failed')), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a first page that fits keeps loading until the end', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    repo
      ..first = [_item('a')]
      ..nextPages[2] = [_item('b')]
      ..nextPages[3] = [_item('c')];
    await open(t);
    await searchFor(t, 'q');
    // Page 4 answers empty, which ends paging; no scroll was needed.
    expect(repo.pageCalls, [2, 3, 4]);
    expect(find.byKey(const ValueKey('browse-source-load-more')), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a failed next page shows Retry in the footer', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    repo
      ..first = [_item('a')]
      ..failingPages.add(2);
    await open(t);
    await searchFor(t, 'q');
    final panel = find.byKey(const ValueKey('browse-source-more-failed'));
    expect(panel, findsOneWidget);
    // Auto-fill stops on the failure instead of hammering the source.
    expect(repo.pageCalls, [2]);
    repo
      ..failingPages.clear()
      ..nextPages[2] = [_item('b')];
    await t.tap(find.descendant(of: panel, matching: find.text('Retry')));
    await t.pumpAndSettle();
    expect(repo.pageCalls, [2, 2, 3]);
    expect(panel, findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('no titles offers searching all sources for the query', (
    t,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await open(t);
    await searchFor(t, 'zzz');
    expect(find.text('Search all sources for "zzz"'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Esc clears the field first, then closes the search', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await open(t);
    await t.tap(find.byIcon(Icons.search));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'abc');
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(t.widget<TextField>(find.byType(TextField)).controller!.text, '');
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    // Still on the source page: nothing popped it.
    expect(find.byType(BrowseSourceScreen), findsOneWidget);
    // The page keys still hear Ctrl+F after the field went away.
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyF);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Ctrl+F opens this source\'s search', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await open(t);
    expect(find.byType(TextField), findsNothing);
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyF);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('phone keeps the plain failure text', (t) async {
    repo.searchThrows = true;
    await open(t);
    await searchFor(t, 'naruto');
    expect(find.byKey(const ValueKey('browse-source-failed')), findsNothing);
    expect(find.text('Something went wrong'), findsOneWidget);
  });
}
