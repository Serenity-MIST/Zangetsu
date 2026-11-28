// The Windows top-bar quick search lookup: stale answers are dropped, the
// list is capped, failures are reported, and the row subtitles read right.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/playback/list_status_store.dart';
import 'package:watch_app/core/playback/my_list.dart';
import 'package:watch_app/features/search/desktop_quick_search.dart';
import 'package:watch_app/features/search/desktop_search_dropdown.dart';

/// A plain anime title.
MediaItem _item(String title, {ProviderType type = ProviderType.anime}) =>
    MediaItem(
      id: title,
      title: title,
      url: '/$title',
      type: type,
      sourceId: 'src',
    );

/// My List that holds exactly the titles in [saved].
class _FakeMyList implements MyListStore {
  _FakeMyList(this.saved);
  final Set<String> saved;

  @override
  bool contains(MediaItem m) => saved.contains(m.id);

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// Every saved title is being watched.
class _FakeStatus implements ListStatusStore {
  @override
  WatchStatus? statusOf(MediaItem m) => WatchStatus.watching;

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  tearDown(() async => sl.reset());

  test('a slow early answer is dropped once a newer lookup started', () async {
    final pending = <String, Completer<List<MediaItem>>>{};
    final quick = DesktopQuickSearch(
      search: (q) => (pending[q] = Completer<List<MediaItem>>()).future,
    );
    final first = quick.run('na');
    final second = quick.run('naruto');
    // The newer one answers first, then the stale one arrives late.
    pending['naruto']!.complete([_item('Naruto')]);
    pending['na']!.complete([_item('Nana')]);
    expect(await first, isNull);
    final fresh = await second;
    expect(fresh, isNotNull);
    expect(fresh!.items.single.title, 'Naruto');
  });

  test('cancel drops the lookup in flight', () async {
    final done = Completer<List<MediaItem>>();
    final quick = DesktopQuickSearch(search: (_) => done.future);
    final run = quick.run('naruto');
    quick.cancel();
    done.complete([_item('Naruto')]);
    expect(await run, isNull);
  });

  test('caps the matches at the limit (4)', () async {
    final quick = DesktopQuickSearch(
      search: (_) async => [for (var i = 0; i < 9; i++) _item('T$i')],
    );
    final result = await quick.run('t');
    expect(result!.items.map((i) => i.title), ['T0', 'T1', 'T2', 'T3']);
    expect(result.failed, isFalse);
  });

  test('a failure is reported, a stale failure is dropped', () async {
    final quick = DesktopQuickSearch(search: (_) async => throw Exception());
    final result = await quick.run('x');
    expect(result!.failed, isTrue);
    expect(result.items, isEmpty);

    final late = Completer<List<MediaItem>>();
    final slow = DesktopQuickSearch(search: (_) => late.future);
    final stale = slow.run('x');
    slow.cancel();
    late.completeError(Exception());
    expect(await stale, isNull);
  });

  test('row subtitle: type and year, or the My List status', () {
    expect(quickSearchSubtitle(_item('Naruto (2002)')), 'Anime · 2002');
    // No year in the data: the type alone.
    expect(
      quickSearchSubtitle(_item('Berserk', type: ProviderType.manga)),
      'Manga',
    );
    expect(
      quickSearchTypeLabel(
        const MediaItem(
          id: 'm',
          title: 'Dune',
          url: '/m',
          type: ProviderType.movie,
          sourceId: 'tmdb',
          tmdbId: 1,
        ),
      ),
      'Movie',
    );

    sl.registerSingleton<MyListStore>(_FakeMyList({'Boruto'}));
    sl.registerSingleton<ListStatusStore>(_FakeStatus());
    expect(quickSearchSubtitle(_item('Boruto')), 'In your My List · Watching');
    // Reading kinds use the reading word.
    expect(
      quickSearchSubtitle(_item('Boruto', type: ProviderType.manga)),
      'In your My List · Reading',
    );
  });

  // Novel "Browse" / source catalogues: watch() asks the installed sources
  // instead of the catalogue, and passes partial answers straight through.
  test('watch: sources lookup when there is no tracker catalogue', () async {
    var catalogueAsked = false;
    final quick = DesktopQuickSearch(
      useSources: () => true,
      search: (_) async {
        catalogueAsked = true;
        return const [];
      },
      sourcesSearch: (q, limit) => Stream.fromIterable([
        QuickSearchResult(
          [_item(q, type: ProviderType.novel)],
          sourceNames: const ['Novel Ping'],
          searching: true,
          pendingSources: 2,
        ),
        QuickSearchResult(
          [for (var i = 0; i < 6; i++) _item('$q $i')],
          sourceNames: [for (var i = 0; i < 6; i++) 'S$i'],
        ),
      ]),
    );
    final results = await quick.watch('devour').toList();
    expect(catalogueAsked, isFalse);
    expect(results.first.searching, isTrue);
    expect(results.first.sourceNameAt(0), 'Novel Ping');
    // Capped at the limit, names kept in step with the titles.
    expect(results.last.items, hasLength(4));
    expect(results.last.sourceNames, hasLength(4));
    expect(results.last.searching, isFalse);
  });

  test('watch: tracker catalogue keeps the catalogue lookup', () async {
    var sourcesAsked = false;
    final quick = DesktopQuickSearch(
      useSources: () => false,
      search: (q) async => [_item('$q hit')],
      sourcesSearch: (q, limit) {
        sourcesAsked = true;
        return const Stream.empty();
      },
    );
    final results = await quick.watch('naruto').toList();
    expect(sourcesAsked, isFalse);
    expect(results.single.items.single.title, 'naruto hit');
    expect(results.single.sourceNameAt(0), isNull);
  });

  test('row subtitle leads with the source that found the title', () {
    final novel = _item('Devour', type: ProviderType.novel);
    expect(quickSearchRowSubtitle(novel), 'Novel');
    expect(
      quickSearchRowSubtitle(novel, sourceName: 'Novel Ping'),
      'Novel Ping · Novel',
    );
  });
}
