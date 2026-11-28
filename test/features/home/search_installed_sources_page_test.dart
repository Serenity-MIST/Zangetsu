// Windows results page, novel mode on the "Browse" catalogue: the metadata
// catalogue has no web novels, so a search like "i can devour monsters"
// came back empty and the page said "No results" / "0 titles" right above
// the installed sources' results. The page now counts the source titles in
// its header and shows "No results" only when the catalogue AND every
// installed source came up empty.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/mode/content_mode.dart';
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
import 'package:watch_app/core/zmode/metadata_repository.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/core/zmode/zmode_prefs.dart';
import 'package:watch_app/features/home/search_screen.dart';
import 'package:watch_app/l10n/app_localizations.dart';

import '../../support/picker_deps.dart';

/// The novel metadata catalogue ("Browse"): never knows the web novel.
class _EmptyCatalogue implements MetadataRepository {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  String get sourceId => ZmodeIds.sourceId;

  @override
  List<({String id, String name})> get loadedSources => const [
    (id: ZmodeIds.sourceId, name: 'AniList'),
  ];

  @override
  String displayName(String id) => 'AniList';

  @override
  bool hasSource(String id) => id == ZmodeIds.sourceId;

  @override
  bool get supportsFilters => false;

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

/// Installed novel sources; [hits] decides what each one finds.
class _NovelSources implements SourceRepository {
  _NovelSources(this.hits);

  /// Source id -> titles it returns for any query.
  final Map<String, List<String>> hits;

  static const _names = {
    'lnr:ping': 'Novel Ping',
    'lnr:phoenix': 'Novel Phoenix',
  };

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  List<({String id, String name})> get pickableSources => loadedSources;

  @override
  List<({String id, String name})> get loadedSources => [
    for (final e in _names.entries) (id: e.key, name: e.value),
  ];

  @override
  String get sourceId => 'lnr:ping';

  @override
  String displayName(String id) => _names[id] ?? id;

  @override
  bool hasSource(String id) => _names.containsKey(id);

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
  }) async {
    final titles = hits[sourceId] ?? const <String>[];
    return (
      items: [
        for (final t in titles)
          MediaItem(
            id: '$sourceId-$t',
            title: t,
            url: '/$sourceId/$t',
            type: ProviderType.novel,
            sourceId: sourceId!,
          ),
      ],
      outcome: titles.isEmpty ? SourceOutcome.empty : SourceOutcome.ok,
    );
  }
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

/// A widget test run as Windows; the variant resets the platform override.
void winTestWidgets(String description, WidgetTesterCallback body) =>
    testWidgets(
      description,
      body,
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

void main() {
  late Directory dir;

  /// Registers everything with [hits] as the installed sources' answers.
  Future<void> setUpWith(WidgetTester t, Map<String, List<String>> hits) async {
    await t.runAsync(() async {
      await ZModePrefs.init();
      await ZModePrefs.setEnabled(true);
    });
    final sources = _NovelSources(hits);
    sl.registerSingleton<SourceRepository>(sources);
    final catalogue = _EmptyCatalogue();
    sl.registerSingleton<MetadataRepository>(catalogue);
    sl.registerSingleton<CatalogueRepository>(catalogue);
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('search_installed_sources');
    Hive.init(dir.path);
    await Hive.openBox<dynamic>(SearchHistory.boxName, bytes: Uint8List(0));
    await SearchHistory.init();
    await SearchPrefs.init();
    await SearchSourcePrefs.init();
    await registerPickerDeps(mode: ContentMode.novel);
    sl.registerSingleton<SearchHistory>(SearchHistory());
    sl.registerSingleton<SearchPrefs>(SearchPrefs());
    sl.registerSingleton<SearchSourcePrefs>(SearchSourcePrefs());
    sl.registerSingleton<SourceHealthStore>(_FakeHealth());
    sl.registerSingleton<MyListStore>(_FakeMyListStore());
    sl.registerSingleton<TitleSuggestionService>(_NoLiveSuggestions());
  });

  tearDown(() async {
    await disposePickerDeps();
    await sl.reset();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  /// The results page as the shell's top-bar search opens it.
  Widget page(String query) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: child!,
    ),
    home: BlocProvider<ActiveSourceCubit>.value(
      value: sl<ActiveSourceCubit>(),
      child: SearchScreen(showBack: false, initialQuery: query),
    ),
  );

  const query = 'i can devour monsters';
  const count = ValueKey('desktop-results-count');

  winTestWidgets('source hits: no "No results", header counts them', (t) async {
    await setUpWith(t, {
      'lnr:ping': ['I Can Devour Monsters'],
      'lnr:phoenix': ['I Can Devour Monsters', 'Devour Everything'],
    });
    await t.pumpWidget(page(query));
    await t.pump();
    await t.pump();
    // Catalogue answered empty, sources not asked yet (debounce): the page
    // must not jump to "No results" or "0 titles".
    expect(find.textContaining('No results for'), findsNothing);
    expect(find.text('0 titles'), findsNothing);

    // The installed sources answer.
    await t.pump(const Duration(milliseconds: 450));
    await t.pumpAndSettle();
    expect(find.textContaining('No results for'), findsNothing);
    expect(find.text('Devour Everything'), findsOneWidget);
    expect(find.text('Novel Ping'), findsOneWidget);
    // Header: the three source titles, not "0 titles".
    expect(t.widget<Text>(find.byKey(count)).data, '3 titles');
  });

  winTestWidgets('catalogue and every source empty: one "No results"', (
    t,
  ) async {
    await setUpWith(t, const {});
    await t.pumpWidget(page(query));
    await t.pump(const Duration(milliseconds: 450));
    await t.pumpAndSettle();
    expect(find.textContaining('No results for'), findsOneWidget);
    expect(t.widget<Text>(find.byKey(count)).data, '0 titles');
    // No second empty line from the sources section under it.
    expect(
      find.text('None of your installed sources found it either.'),
      findsNothing,
    );
  });
}
