// Windows "Wrong title?" search (ar-5 / ar-6) and the store support behind
// its Undo and the Manual matches page (ar-7).
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/playback/source_health_store.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/zmode/match_store.dart';
import 'package:watch_app/core/zmode/source_matcher.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/core/zmode/zmode_source_prefs.dart';
import 'package:watch_app/features/detail/cubit/wrong_title_cubit.dart';
import 'package:watch_app/features/settings/manual_matches_screen.dart';

/// A result named [id] on source 'src'.
MediaItem _item(String id) => MediaItem(
  id: id,
  title: 'Show $id',
  url: 'https://src/$id',
  type: ProviderType.anime,
  sourceId: 'src',
);

/// Fake source answering the status-aware search page by page.
class _StatusSrc implements SourceRepository {
  _StatusSrc(this.answer);

  /// What each (query, page) returns; a never-completing future simulates a
  /// hung source.
  final Future<({List<MediaItem> items, SourceOutcome outcome})> Function(
    String query,
    int page,
  )
  answer;
  final askedPages = <int>[];
  int plainSearches = 0;

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  Future<({List<MediaItem> items, SourceOutcome outcome})> searchStatus(
    String query, {
    String category = 'sub',
    String? sourceId,
    String? filtersJson,
    bool cache = false,
    int page = 1,
  }) {
    askedPages.add(page);
    return answer(query, page);
  }

  @override
  Future<List<MediaItem>> search(
    String q, {
    String category = 'sub',
    String? sourceId,
  }) async {
    plainSearches++;
    return [_item('plain')];
  }
}

void main() {
  late Directory dir;
  late MatchStore store;
  late ZSourcePrefs prefs;
  const fma = ZCanonical(ZKind.anime, 'mal:5114');

  WrongTitleCubit build(_StatusSrc src, {bool statusAware = true}) =>
      WrongTitleCubit(
        sources: src,
        matcher: SourceMatcher(
          sources: src,
          store: store,
          prefs: prefs,
          candidates: (_) => const [],
        ),
        canonical: fma,
        sourceId: 'src',
        statusAware: statusAware,
        searchTimeout: const Duration(milliseconds: 50),
      );

  ({List<MediaItem> items, SourceOutcome outcome}) ok(List<MediaItem> i) =>
      (items: i, outcome: i.isEmpty ? SourceOutcome.empty : SourceOutcome.ok);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('wrongtitle_desktop');
    Hive.init(dir.path);
    store = await MatchStore.open();
    prefs = await ZSourcePrefs.open();
  });
  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  group('status-aware search (ar-5)', () {
    test('a hung source turns into a timeout instead of spinning', () async {
      final c = build(
        _StatusSrc(
          (_, _) =>
              Completer<({List<MediaItem> items, SourceOutcome outcome})>()
                  .future,
        ),
      );
      await c.search('fma');
      expect(c.state.loading, isFalse);
      expect(c.state.failure, SourceOutcome.timeout);
      expect(c.state.results, isEmpty);
    });

    test(
      'a Cloudflare block and an error each keep their own outcome',
      () async {
        for (final o in [SourceOutcome.blocked, SourceOutcome.error]) {
          final c = build(
            _StatusSrc(
              (_, _) async => (items: const <MediaItem>[], outcome: o),
            ),
          );
          await c.search('fma');
          expect(c.state.failure, o);
          expect(c.state.hasMore, isFalse);
        }
      },
    );

    test('a real empty answer is not a failure', () async {
      final c = build(_StatusSrc((_, _) async => ok(const [])));
      await c.search('fma');
      expect(c.state.failure, isNull);
      expect(c.state.results, isEmpty);
    });

    test('retry runs the same query again and clears the failure', () async {
      var calls = 0;
      final src = _StatusSrc((_, _) async {
        calls++;
        return calls == 1
            ? (items: const <MediaItem>[], outcome: SourceOutcome.error)
            : ok([_item('a')]);
      });
      final c = build(src);
      await c.search('fma');
      expect(c.state.failure, SourceOutcome.error);
      await c.retry();
      expect(c.state.failure, isNull);
      expect(c.state.results.single.id, 'a');
      expect(c.state.query, 'fma');
    });

    test('a failed first search skips the alias retries', () async {
      final src = _StatusSrc(
        (_, _) async =>
            (items: const <MediaItem>[], outcome: SourceOutcome.timeout),
      );
      final c = build(src);
      await c.search(
        'fma',
        retryWithMetadataAliases: true,
        metadataAliases: const ['alias one', 'alias two'],
      );
      expect(src.askedPages, [1], reason: 'only the primary query was asked');
    });

    test('phone keeps the plain search and never reports a failure', () async {
      final src = _StatusSrc((_, _) async => ok(const []));
      final c = build(src, statusAware: false);
      await c.search('fma');
      expect(src.plainSearches, 1);
      expect(src.askedPages, isEmpty);
      expect(c.state.failure, isNull);
      expect(c.state.hasMore, isFalse);
    });
  });

  group('paging (ar-6)', () {
    test('load more asks for the next page and appends it', () async {
      final src = _StatusSrc(
        (_, page) async => ok([_item('p${page}a'), _item('p${page}b')]),
      );
      final c = build(src);
      await c.search('fma');
      expect(c.state.hasMore, isTrue);
      await c.loadMore();
      expect(src.askedPages, [1, 2]);
      expect(c.state.results.map((r) => r.id), ['p1a', 'p1b', 'p2a', 'p2b']);
      expect(c.state.hasMore, isTrue);
      expect(c.state.loadingMore, isFalse);
    });

    test('a page that adds nothing new ends paging', () async {
      // Some sources answer every page number with page 1 again.
      final src = _StatusSrc((_, _) async => ok([_item('same')]));
      final c = build(src);
      await c.search('fma');
      await c.loadMore();
      expect(c.state.results, hasLength(1));
      expect(c.state.hasMore, isFalse);
    });

    test('a failed page keeps the results and offers a retry', () async {
      final src = _StatusSrc(
        (_, page) async => page == 1
            ? ok([_item('a')])
            : (items: const <MediaItem>[], outcome: SourceOutcome.error),
      );
      final c = build(src);
      await c.search('fma');
      await c.loadMore();
      expect(c.state.results.single.id, 'a');
      expect(c.state.loadMoreFailed, isTrue);
      expect(c.state.hasMore, isTrue);
    });

    test('an empty first page offers no more', () async {
      final c = build(_StatusSrc((_, _) async => ok(const [])));
      await c.search('fma');
      expect(c.state.hasMore, isFalse);
    });
  });

  group('match store (ar-7)', () {
    SourceMatch m(String src, String id, {bool pinned = false}) => SourceMatch(
      sourceId: src,
      showUrl: '/show/$id',
      showId: id,
      showTitle: 'Show $id',
      pinned: pinned,
    );

    test('restore undoes a pin exactly, previous pin included', () async {
      await store.pin(fma, m('a', 'old'));
      await store.save(fma, m('b', 'guess'));
      final before = store.snapshot(fma);

      await store.pin(fma, m('b', 'new'));
      await store.pin(fma, m('c', 'other'));
      expect(store.pinnedFor(fma)?.sourceId, 'c');

      await store.restore(fma, before);
      expect(store.pinnedFor(fma)?.sourceId, 'a');
      expect(store.get(fma, 'b')?.showId, 'guess');
      expect(store.get(fma, 'b')?.pinned, isFalse);
      expect(store.get(fma, 'c'), isNull, reason: 'added after the snapshot');
    });

    test('restore leaves other titles alone', () async {
      const other = ZCanonical(ZKind.anime, 'mal:1');
      await store.pin(other, m('a', 'x'));
      final before = store.snapshot(fma);
      await store.pin(fma, m('a', 'y'));
      await store.restore(fma, before);
      expect(store.pinnedFor(fma), isNull);
      expect(store.pinnedFor(other)?.showId, 'x');
    });

    test('pinnedMatches lists one row per hand-fixed title', () async {
      const manga = ZCanonical(ZKind.manga, 'al:9');
      await store.pin(fma, m('ani:1', 'fma'));
      await store.save(manga, m('mihon:2', 'guess'));
      await store.rememberLastPlayed(fma, 'ani:1');
      await store.rememberTitle(fma, 'Fullmetal Alchemist');
      final rows = store.pinnedMatches();
      expect(rows, hasLength(1));
      expect(rows.single.canonical, fma);
      expect(rows.single.match.sourceId, 'ani:1');
      expect(store.titleFor(fma), 'Fullmetal Alchemist');
    });

    test('canonicalFromKey reads match keys and skips the others', () {
      expect(
        MatchStore.canonicalFromKey('anime:mal:5114@ani:1'),
        const ZCanonical(ZKind.anime, 'mal:5114'),
      );
      expect(MatchStore.canonicalFromKey('last:anime:mal:5114'), isNull);
      expect(MatchStore.canonicalFromKey('label:anime:mal:5114'), isNull);
      expect(MatchStore.canonicalFromKey('nonsense@x'), isNull);
    });

    test('manual matches page rows: names, sort and search', () async {
      const b = ZCanonical(ZKind.anime, 'mal:2');
      await store.pin(fma, m('ani:1', 'fma'));
      await store.rememberTitle(fma, 'Fullmetal Alchemist');
      await store.pin(b, m('ani:2', 'bleach'));
      final rows = manualMatchRows(
        store,
        sourceName: (id) => id == 'ani:1' ? 'AllAnime' : 'HiAnime',
      );
      // The remembered title wins; an older pin falls back to the show name.
      expect(rows.map((r) => r.title), ['Fullmetal Alchemist', 'Show bleach']);
      expect(
        manualMatchRows(
          store,
          query: 'hianime',
          sourceName: (id) => id == 'ani:1' ? 'AllAnime' : 'HiAnime',
        ).single.canonical,
        b,
      );
    });

    test('source page url joins relative paths to the base url', () {
      expect(
        manualMatchPageUrl(m('a', 'x'), 'https://site.test/'),
        'https://site.test/show/x',
      );
      expect(
        manualMatchPageUrl(
          const SourceMatch(
            sourceId: 'a',
            showUrl: 'https://abs.test/s',
            showId: 's',
            showTitle: '',
            pinned: true,
          ),
          '',
        ),
        'https://abs.test/s',
      );
      expect(
        manualMatchPageUrl(
          const SourceMatch(
            sourceId: 'a',
            showUrl: '',
            showId: '',
            showTitle: '',
            pinned: true,
          ),
          'https://site.test',
        ),
        isNull,
      );
    });
  });
}
