import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/error/exceptions.dart';
import 'package:watch_app/core/provider/cf_solve_needed.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/playback/source_health_store.dart';
import 'package:watch_app/core/repository/catalogue_repository.dart';
import 'package:watch_app/features/search/cubit/browse_source_cubit.dart';

class _Repo implements CatalogueRepository {
  _Repo(
    this.sections, {
    this.throws = false,
    this.searchResults = const [],
    this.searchThrows = false,
    this.challenge,
  });
  final List<HomeSection> sections;
  final bool throws;
  final List<MediaItem> searchResults;
  final bool searchThrows;
  final String? challenge;
  String? askedFor;
  String? lastFiltersJson;
  int? lastPage;
  Map<int, List<MediaItem>>? pages;
  String? filteredQuery;
  int homeCalls = 0;
  String? searchAskedFor;
  String? lastQuery;

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  Future<List<HomeSection>> home({
    String category = 'sub',
    String? sourceId,
  }) async {
    homeCalls++;
    askedFor = sourceId;
    if (challenge != null) throw CloudflareRequiredException(challenge!);
    if (throws) throw StateError('boom');
    return sections;
  }

  @override
  Future<List<MediaItem>> search(
    String query, {
    String category = 'sub',
    String? sourceId,
  }) async {
    lastQuery = query;
    searchAskedFor = sourceId;
    if (challenge != null) throw CloudflareRequiredException(challenge!);
    if (searchThrows) throw StateError('boom');
    return searchResults;
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
    filteredQuery = query;
    lastFiltersJson = filtersJson;
    searchAskedFor = sourceId;
    lastPage = page;
    if (searchThrows) throw StateError('boom');
    // Per-page answers when a test supplies them, so paging can be exercised.
    if (pages != null) {
      return (items: pages![page] ?? const [], outcome: SourceOutcome.ok);
    }
    return (items: searchResults, outcome: SourceOutcome.ok);
  }
}

/// Holds selected requests so completion order is controlled independently.
class _HeldRepo extends _Repo {
  _HeldRepo() : super(const []);
  final searches=<String,Completer<List<MediaItem>>>{};
  final homeReply=Completer<List<HomeSection>>();
  @override
  Future<List<HomeSection>> home({String category='sub',String? sourceId}) => homeReply.future;
  final page=Completer<({List<MediaItem> items, SourceOutcome outcome})>();
  @override
  Future<List<MediaItem>> search(String query,{String category='sub',String? sourceId}) =>
    (searches[query] ??= Completer<List<MediaItem>>()).future;
  @override
  Future<({List<MediaItem> items, SourceOutcome outcome})> searchStatus(
    String query,{String category='sub',String? sourceId,String? filtersJson,
    bool cache=false,int page=1}) {
    lastQuery=query;
    return this.page.future;
  }
}

HomeSection _section(String title) =>
    HomeSection(title: title, items: [_item('1', 'A show')]);

MediaItem _item(String id, String title) => MediaItem(
  id: id,
  title: title,
  url: 'https://x/$id',
  type: ProviderType.anime,
  sourceId: 'ani:1',
);

void main() {
  test('captured title intent expires on same-ID inventory replacement', () async {
    final events=StreamController<void>(sync:true);
    final c=BrowseSourceCubit(repo:_Repo(const []),sourceId:'fixture',
      sourceAvailable:()=>true,inventoryChanges:events.stream);
    final accepts=c.retainSourceIntent(); expect(accepts(),isTrue);
    events.add(null); expect(accepts(),isFalse);
    final replacement=c.retainSourceIntent(); expect(replacement(),isTrue);
    await c.close(); expect(replacement(),isFalse); await events.close();
  });

  test('inventory event retires old plugin after same-ID reinstall', () async {
    final events=StreamController<void>(sync:true); final repo=_HeldRepo();
    final c=BrowseSourceCubit(repo:repo,sourceId:'fixture',sourceAvailable:()=>true,
      inventoryChanges:events.stream);
    final old=c.search('old'); events.add(null); events.add(null);
    expect(c.state.failed,isTrue);
    final fresh=c.search('fresh');
    repo.searches['fresh']!.complete([_item('fresh','Fresh')]); await fresh;
    repo.searches['old']!.complete([_item('stale','Stale')]); await old;
    expect(c.state.searchResults!.single.id,'fresh');
    await c.close(); expect(events.hasListener,isFalse);
    events.add(null); await events.close();
  });

  test('source removal retires replies and reinstall permits retry', () async {
    var available=true; final repo=_HeldRepo();
    final c=BrowseSourceCubit(repo:repo,sourceId:'fixture',sourceAvailable:()=>available);
    final searching=c.search('before'); available=false;
    repo.searches['before']!.complete([_item('stale','Stale')]); await searching;
    expect(c.state.failed,isTrue); expect(c.state.searchResults,isNull);
    await c.search('removed'); expect(repo.searches.containsKey('removed'),isFalse);
    available=true; final retry=c.search('retry');
    repo.searches['retry']!.complete([_item('fresh','Fresh')]); await retry;
    expect(c.state.searchResults!.single.id,'fresh'); await c.close();
  });

  test('current background catalogue challenge survives Clear without replacing search', () async {
    const host='background-fixture.example';
    const target='https://background-fixture.example/catalogue';
    final repo=_HeldRepo(); final c=BrowseSourceCubit(repo:repo,sourceId:'mihon:background');
    try {
      final loading=c.load(); final searching=c.search('title');
      repo.homeReply.completeError(CloudflareRequiredException(target)); await loading;
      expect(c.state.searching,isTrue);
      expect(CfSolveNeeded.urlFor('mihon:background'),target);
      repo.searches['title']!.complete([_item('result','Result')]); await searching;
      expect(c.state.searchResults!.single.title,'Result');
      c.clearSearch();
      expect(c.state.failed,isTrue);
      expect(CfSolveNeeded.urlFor('mihon:background'),target);
    } finally { CfSolveNeeded.clear(host); await c.close(); }
  });

  test('retired search cannot publish a stale verification target', () async {
    const host='retired-fixture.example';
    final repo=_HeldRepo(); final c=BrowseSourceCubit(repo:repo,sourceId:'mihon:retired');
    try {
      final searching=c.search('old'); c.clearSearch();
      repo.searches['old']!.completeError(CloudflareRequiredException('https://$host/search'));
      await searching;
      expect(CfSolveNeeded.sourceFlagged('mihon:retired'),isFalse);
      expect(c.state.isSearchActive,isFalse);
    } finally { CfSolveNeeded.clear(host); await c.close(); }
  });

  test('hanging pagination releases busy state and keeps the current query', () async {
    final repo=_HeldRepo();
    final c=BrowseSourceCubit(repo:repo,sourceId:'fixture',timeout:const Duration(milliseconds:60));
    final search=c.search('kept');
    repo.searches['kept']!.complete([_item('kept','Kept')]); await search;
    await c.loadMore();
    expect(c.state.loadingMore,isFalse);
    expect(c.state.atEnd,isFalse);
    expect(c.state.query,'kept');
    expect(c.state.searchResults!.single.id,'kept');
    repo.page.complete((items:<MediaItem>[],outcome:SourceOutcome.ok));
    await c.close();
  });

  test('clearing a search restores pending base catalogue', () async {
    final repo=_HeldRepo(); final c=BrowseSourceCubit(repo:repo,sourceId:'fixture');
    final loading=c.load(); final searching=c.search('title'); c.clearSearch();
    expect(c.state.loading,isTrue);
    repo.homeReply.complete([_section('Catalogue')]); await loading;
    expect(c.state.sections.single.title,'Catalogue');
    expect(c.state.loading,isFalse);
    repo.searches['title']!.complete([]); await searching;
    expect(c.state.sections.single.title,'Catalogue');
    await c.close();
  });

  test('background catalogue cannot replace active search but Clear restores it', () async {
    final repo=_HeldRepo(); final c=BrowseSourceCubit(repo:repo,sourceId:'fixture');
    final loading=c.load(); final searching=c.search('title');
    repo.homeReply.complete([_section('Catalogue')]); await loading;
    expect(c.state.searching,isTrue);
    repo.searches['title']!.complete([_item('result','Result')]); await searching;
    expect(c.state.searchResults!.single.title,'Result');
    c.clearSearch(); expect(c.state.sections.single.title,'Catalogue');
    await c.close();
  });

  test('new search and clear retire old replies; paging keeps query', () async {
    final repo=_HeldRepo();
    final c=BrowseSourceCubit(repo:repo,sourceId:'fixture');
    final old=c.search('old'); final fresh=c.search('fresh');
    repo.searches['fresh']!.complete([_item('new','New')]); await fresh;
    repo.searches['old']!.complete([_item('old','Old')]); await old;
    expect(c.state.searchResults!.single.id,'new');
    expect(c.state.query,'fresh');
    final more=c.loadMore(); expect(repo.lastQuery,'fresh');
    final next=c.search('next');
    repo.searches['next']!.complete([_item('next','Next')]); await next;
    repo.page.complete((items:[_item('late','Late')],outcome:SourceOutcome.ok));
    await more;
    expect(c.state.searchResults!.single.id,'next');
    final cleared=c.search('clear'); c.clearSearch();
    repo.searches['clear']!.complete([_item('clear','Clear')]); await cleared;
    expect(c.state.isSearchActive,isFalse);
    final disposed=c.search('dispose'); await c.close();
    repo.searches['dispose']!.complete([]); await disposed;
  });

  test(
    'native browse and search challenges retain their source and target',
    () async {
      const target = 'https://native.example/search?q=title';
      final cubit = BrowseSourceCubit(
        repo: _Repo(const [], challenge: target),
        sourceId: 'mihon:123',
      );
      try {
        await cubit.load();
        expect(cubit.state.failed, isTrue);
        expect(CfSolveNeeded.urlFor('mihon:123'), target);
        CfSolveNeeded.clear('native.example');
        await cubit.search('title');
        expect(cubit.state.searchFailed, isTrue);
        expect(CfSolveNeeded.urlFor('mihon:123'), target);
      } finally {
        CfSolveNeeded.clear('native.example');
        await cubit.close();
      }
    },
  );
  test('loads the named source, not the active one', () async {
    final repo = _Repo([_section('Latest')]);
    final cubit = BrowseSourceCubit(repo: repo, sourceId: 'ani:1');

    await cubit.load();

    expect(repo.askedFor, 'ani:1');
    expect(cubit.state.sections.single.title, 'Latest');
    expect(cubit.state.loading, isFalse);
    expect(cubit.state.failed, isFalse);
    await cubit.close();
  });

  test('an empty catalogue is empty, not an error', () async {
    final cubit = BrowseSourceCubit(repo: _Repo(const []), sourceId: 'ani:1');
    await cubit.load();
    expect(cubit.state.sections, isEmpty);
    expect(cubit.state.failed, isFalse);
    await cubit.close();
  });

  test('a throwing source surfaces as failed, without crashing', () async {
    final cubit = BrowseSourceCubit(
      repo: _Repo(const [], throws: true),
      sourceId: 'ani:1',
    );
    await cubit.load();
    expect(cubit.state.failed, isTrue);
    expect(cubit.state.loading, isFalse);
    await cubit.close();
  });

  test('a search returns results and they replace the sections', () async {
    final repo = _Repo(
      [_section('Latest')],
      searchResults: [_item('2', 'Found it')],
    );
    final cubit = BrowseSourceCubit(repo: repo, sourceId: 'ani:1');
    await cubit.load();

    await cubit.search('found');

    expect(repo.lastQuery, 'found');
    expect(repo.searchAskedFor, 'ani:1');
    expect(cubit.state.searchResults, hasLength(1));
    expect(cubit.state.searchResults!.single.title, 'Found it');
    expect(cubit.state.searching, isFalse);
    expect(cubit.state.searchFailed, isFalse);
    expect(cubit.state.isSearchActive, isTrue);
    await cubit.close();
  });

  test('a search returning nothing is empty, not failed', () async {
    final repo = _Repo([_section('Latest')]);
    final cubit = BrowseSourceCubit(repo: repo, sourceId: 'ani:1');
    await cubit.load();

    await cubit.search('nothing here');

    expect(cubit.state.searchResults, isEmpty);
    expect(cubit.state.searchFailed, isFalse);
    expect(cubit.state.isSearchActive, isTrue);
    await cubit.close();
  });

  test('a throwing search surfaces as failed', () async {
    final repo = _Repo([_section('Latest')], searchThrows: true);
    final cubit = BrowseSourceCubit(repo: repo, sourceId: 'ani:1');
    await cubit.load();

    await cubit.search('boom');

    expect(cubit.state.searchFailed, isTrue);
    expect(cubit.state.searchResults, isNull);
    expect(cubit.state.searching, isFalse);
    expect(cubit.state.isSearchActive, isTrue);
    await cubit.close();
  });

  test(
    'clearing the query restores the sections without re-fetching home',
    () async {
      final repo = _Repo(
        [_section('Latest')],
        searchResults: [_item('2', 'Found it')],
      );
      final cubit = BrowseSourceCubit(repo: repo, sourceId: 'ani:1');
      await cubit.load();
      expect(repo.homeCalls, 1);

      await cubit.search('found');
      expect(cubit.state.isSearchActive, isTrue);

      cubit.clearSearch();

      expect(cubit.state.isSearchActive, isFalse);
      expect(cubit.state.sections.single.title, 'Latest');
      expect(repo.homeCalls, 1);
      await cubit.close();
    },
  );

  test('searching a blank query clears back to the catalogue', () async {
    final repo = _Repo(
      [_section('Latest')],
      searchResults: [_item('2', 'Found it')],
    );
    final cubit = BrowseSourceCubit(repo: repo, sourceId: 'ani:1');
    await cubit.load();
    await cubit.search('found');

    await cubit.search('   ');

    expect(cubit.state.isSearchActive, isFalse);
    expect(cubit.state.sections.single.title, 'Latest');
    expect(repo.homeCalls, 1);
    await cubit.close();
  });

  test('filters browse with no query, the way extensions expect', () async {
    final repo = _Repo([_section('Latest')], searchResults: [_item('2', 'B')]);
    final cubit = BrowseSourceCubit(repo: repo, sourceId: 'ani:1');
    await cubit.load();

    await cubit.applyFilters('{"genre":"action"}');

    // home() takes no filters, so a filtered browse has to be a search with an
    // empty query — otherwise the selection is stored and silently ignored.
    expect(repo.filteredQuery, '');
    expect(repo.lastFiltersJson, '{"genre":"action"}');
    expect(repo.searchAskedFor, 'ani:1');
    expect(cubit.state.searchResults!.single.title, 'B');
    expect(cubit.state.filtersJson, '{"genre":"action"}');
    // The catalogue stays behind the results so clearing returns to it.
    expect(cubit.state.sections.single.title, 'Latest');
    await cubit.close();
  });

  test('clearing filters goes back to the catalogue', () async {
    final repo = _Repo([_section('Latest')], searchResults: [_item('2', 'B')]);
    final cubit = BrowseSourceCubit(repo: repo, sourceId: 'ani:1');
    await cubit.load();
    await cubit.applyFilters('{"genre":"action"}');

    await cubit.applyFilters('');

    expect(cubit.state.filtersJson, isEmpty);
    expect(cubit.state.searchResults, isNull);
    expect(cubit.state.sections.single.title, 'Latest');
    expect(repo.homeCalls, 1, reason: 'must not re-fetch the catalogue');
    await cubit.close();
  });

  test('a filtered browse that throws is a failure, not empty', () async {
    final repo = _Repo([_section('Latest')], searchThrows: true);
    final cubit = BrowseSourceCubit(repo: repo, sourceId: 'ani:1');
    await cubit.load();

    await cubit.applyFilters('{"genre":"action"}');

    expect(cubit.state.searchFailed, isTrue);
    expect(cubit.state.searchResults, isNull);
    await cubit.close();
  });

  test('scrolling asks for the next page and appends it', () async {
    final repo = _Repo([_section('Latest')], searchResults: [_item('1', 'One')])
      ..pages = {
        1: [_item('1', 'One')],
        2: [_item('2', 'Two')],
      };
    final cubit = BrowseSourceCubit(repo: repo, sourceId: 'ani:1');
    await cubit.load();
    await cubit.applyFilters('{"g":1}');

    await cubit.loadMore();

    expect(repo.lastPage, 2);
    expect(cubit.state.searchResults!.map((i) => i.title), ['One', 'Two']);
  });

  test('an empty page ends it', () async {
    final repo = _Repo([_section('Latest')])
      ..pages = {
        1: [_item('1', 'One')],
        2: const [],
      };
    final cubit = BrowseSourceCubit(repo: repo, sourceId: 'ani:1');
    await cubit.load();
    await cubit.applyFilters('{"g":1}');

    await cubit.loadMore();
    expect(cubit.state.atEnd, isTrue);

    // And it stops asking.
    await cubit.loadMore();
    expect(repo.lastPage, 2);
  });

  test('a page that repeats itself ends it too', () async {
    // Plenty of sources answer an out-of-range page with the first one again,
    // which would scroll forever and duplicate every card.
    final repo = _Repo([_section('Latest')])
      ..pages = {
        1: [_item('1', 'One')],
        2: [_item('1', 'One')],
      };
    final cubit = BrowseSourceCubit(repo: repo, sourceId: 'ani:1');
    await cubit.load();
    await cubit.applyFilters('{"g":1}');

    await cubit.loadMore();

    expect(cubit.state.atEnd, isTrue);
    expect(cubit.state.searchResults!.length, 1, reason: 'no duplicate card');
  });

  test('the catalogue rows do not page', () async {
    // Nothing is searched or filtered, so there is no page 2 to ask for.
    final repo = _Repo([_section('Latest')]);
    final cubit = BrowseSourceCubit(repo: repo, sourceId: 'ani:1');
    await cubit.load();

    await cubit.loadMore();

    expect(repo.lastPage, isNull);
  });
}
