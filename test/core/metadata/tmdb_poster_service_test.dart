import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:watch_app/core/metadata/episode_metadata_service.dart';
import 'package:watch_app/core/metadata/tmdb_poster_service.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';

/// Answers TMDB and AniZip calls from a table, with no network. A route
/// whose answer is [_fail] throws a connection error instead.
class _Adapter implements HttpClientAdapter {
  _Adapter(this.routes);
  final Map<String, Object?> routes;
  final requests = <Uri>[];
  final times = <DateTime>[];
  int cancelled = 0;

  /// Runs as each call arrives (for example, the connection dropping).
  void Function()? onFetch;

  @override
  Future<ResponseBody> fetch(RequestOptions options, _, _) async {
    requests.add(options.uri);
    times.add(DateTime.now());
    onFetch?.call();
    final path = options.uri.path;
    final route =
        routes['${options.uri.host}$path?${options.uri.query}'] ??
        routes['${options.uri.host}$path'];
    if (identical(route, _hang)) {
      // Never answers; only a cancel ends it.
      await options.cancelToken?.whenCancel;
      cancelled++;
      throw DioException.requestCancelled(
        requestOptions: options,
        reason: 'cancelled',
      );
    }
    if (identical(route, _fail)) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'offline in test',
      );
    }
    if (route == null) {
      return ResponseBody.fromString('{"status_code":34}', 404, headers: _json);
    }
    return ResponseBody.fromString(jsonEncode(route), 200, headers: _json);
  }

  bool asked(String pathPart) =>
      requests.any((u) => '${u.host}${u.path}'.contains(pathPart));

  @override
  void close({bool force = false}) {}
}

const _json = {
  'content-type': ['application/json'],
};
const _fail = Object();
const _hang = 'hang';

const _tmdb = 'api.themoviedb.org/3';
const _aniZip = 'api.ani.zip/mappings';

/// An AniZip payload shaped like the real one (checked on api.ani.zip):
/// the TMDB id is a string and every episode carries its TMDB season.
Map<String, Object?> _aniZipPayload({
  Object? tmdbId = '1429',
  String type = 'TV',
  List<int?> seasons = const [2, 2],
  Map<String, String> titles = const {'en': 'Attack on Titan Season 2'},
  String? airdate = '2017-04-01',
}) => {
  'titles': titles,
  'episodes': {
    for (var i = 0; i < seasons.length; i++)
      '${i + 1}': {
        'episode': '${i + 1}',
        'seasonNumber': seasons[i],
        'airdate': ?airdate,
      },
  },
  'mappings': {'type': type, 'themoviedb_id': tmdbId, 'mal_id': 25777},
};

Map<String, Object?> _posters(List<(String path, String? lang, num vote)> p) =>
    {
      'posters': [
        for (final (path, lang, vote) in p)
          {'file_path': path, 'iso_639_1': lang, 'vote_average': vote},
      ],
    };

MediaItem _anime({
  int? malId = 25777,
  String url = 'zm://anime/mal:25777',
  String title = 'Shingeki no Kyojin Season 2',
  String? english = 'Attack on Titan Season 2',
  bool adult = false,
  ProviderType type = ProviderType.anime,
  String sourceId = 'zm',
  Map<String, String>? headers,
}) => MediaItem(
  id: url,
  title: title,
  englishTitle: english,
  url: url,
  type: type,
  sourceId: sourceId,
  malId: malId,
  cover:
      'https://s4.anilist.co/file/anilistcdn/media/anime/cover/medium/b1.jpg',
  coverHeaders: headers,
  isAdult: adult,
);

/// TMDB's details answer naming the [_video] show [id].
Map<String, Object?> _named(int id) => {'name': 'Show $id'};

MediaItem _video(int id, {bool tv = true}) => MediaItem(
  id: 'tmdb:$id',
  title: 'Show $id',
  url: 'simkl://$id',
  type: ProviderType.movie,
  sourceId: 'simkl',
  tmdbId: id,
  tmdbIsTv: tv,
  cover: 'https://simkl.in/posters/12/345_m.jpg',
);

class _CachedMeta extends EpisodeMetadataService {
  _CachedMeta(this.payload) : super(Dio());
  final Object? payload;
  final remembered = <int, Object?>{};
  @override
  Future<Object?> cachedAniZip(int malId) async => payload;
  @override
  Future<void> rememberAniZip(int malId, Object? payload) async =>
      remembered[malId] = payload;
}

void main() {
  late _Adapter adapter;
  late MemoryTmdbPosterStore store;
  late DateTime clock;

  TmdbPosterService service({
    ValueListenable<bool>? offline,
    EpisodeMetadataService? meta,
    Duration gap = Duration.zero,
    Duration timeout = const Duration(seconds: 20),
    int maxWaiting = 300,
  }) => TmdbPosterService(
    Dio()..httpClientAdapter = adapter,
    store: store,
    episodeMeta: meta,
    offline: offline,
    gap: gap,
    timeout: timeout,
    maxWaiting: maxWaiting,
    now: () => clock,
  );

  setUp(() {
    store = MemoryTmdbPosterStore();
    clock = DateTime.utc(2026, 11, 26, 12);
  });

  group('later seasons', () {
    test('season 2 uses only its own season poster', () async {
      adapter = _Adapter({
        _aniZip: _aniZipPayload(),
        '$_tmdb/tv/1429': {'name': 'Attack on Titan', 'original_name': '進撃の巨人'},
        '$_tmdb/tv/1429/season/2': {
          'air_date': '2017-04-01',
          'images': _posters([('/s2.jpg', 'en', 5)]),
        },
        '$_tmdb/tv/1429/images': _posters([('/series.jpg', 'en', 9)]),
      });
      final s = service();
      s.request(_anime());
      await s.idle();
      expect(s.cachedPosterPath(_anime()), '/s2.jpg');
      expect(adapter.asked('/tv/1429/images'), isFalse);
      // Looked up by MAL id; the AniList id would use anilist_id.
      expect(
        adapter.requests.first.queryParameters,
        containsPair('mal_id', '25777'),
      );
    });

    test('no season poster keeps AniList, never the series poster', () async {
      adapter = _Adapter({
        _aniZip: _aniZipPayload(),
        '$_tmdb/tv/1429': {'name': 'Attack on Titan'},
        '$_tmdb/tv/1429/season/2': {
          'air_date': '2017-04-01',
          'images': _posters([]),
        },
        '$_tmdb/tv/1429/images': _posters([('/series.jpg', 'en', 9)]),
      });
      final s = service();
      s.request(_anime());
      await s.idle();
      expect(s.cachedPosterPath(_anime()), isNull);
      expect(adapter.asked('/tv/1429/images'), isFalse);
      // A real "none" is saved.
      expect(jsonDecode(store.entries['anime:mal:25777']!)['p'], '');
    });

    test('season 1 takes the series poster', () async {
      adapter = _Adapter({
        _aniZip: _aniZipPayload(
          seasons: [1, 1, 0],
          titles: {'en': 'Attack on Titan'},
          airdate: '2013-04-07',
        ),
        '$_tmdb/tv/1429': {
          'name': 'Attack on Titan',
          'first_air_date': '2013-04-07',
        },
        '$_tmdb/tv/1429/images': _posters([('/series.jpg', 'en', 9)]),
      });
      final s = service();
      final item = _anime(title: 'Shingeki no Kyojin', english: null);
      s.request(item);
      await s.idle();
      expect(s.cachedPosterPath(item), '/series.jpg');
    });

    test('specials, music and season-0-only entries get none', () {
      expect(
        TmdbPosterService.aniZipPosterPlan(_aniZipPayload(type: 'SPECIAL')),
        isNull,
      );
      expect(
        TmdbPosterService.aniZipPosterPlan(_aniZipPayload(type: 'MUSIC')),
        isNull,
      );
      expect(
        TmdbPosterService.aniZipPosterPlan(_aniZipPayload(seasons: [0, 0])),
        isNull,
      );
      expect(
        TmdbPosterService.aniZipPosterPlan(_aniZipPayload(tmdbId: null)),
        isNull,
      );
    });

    test('an OVA with no known season gets none', () async {
      adapter = _Adapter({
        _aniZip: _aniZipPayload(type: 'OVA', seasons: [null]),
        '$_tmdb/tv/1429': {'name': 'Attack on Titan'},
        '$_tmdb/tv/1429/images': _posters([('/series.jpg', 'en', 9)]),
      });
      final s = service();
      s.request(_anime());
      await s.idle();
      expect(s.cachedPosterPath(_anime()), isNull);
      expect(adapter.asked('/tv/1429'), isFalse);
    });
  });

  test('an anime film asks TMDB for the movie first', () async {
    adapter = _Adapter({
      _aniZip: _aniZipPayload(
        tmdbId: '129',
        type: 'MOVIE',
        seasons: [null],
        titles: {'en': 'Spirited Away', 'ja': '千と千尋の神隠し'},
        airdate: '2001-07-20',
      ),
      '$_tmdb/movie/129': {
        'title': 'Spirited Away',
        'original_title': '千と千尋の神隠し',
        'release_date': '2001-07-20',
      },
      '$_tmdb/movie/129/images': _posters([('/chihiro.jpg', 'en', 6)]),
    });
    final s = service();
    final film = _anime(
      malId: 199,
      url: 'zm://anime/mal:199',
      title: 'Sen to Chihiro no Kamikakushi',
      english: null,
    );
    s.request(film);
    await s.idle();
    expect(s.cachedPosterPath(film), '/chihiro.jpg');
    expect(adapter.asked('/tv/'), isFalse);
  });

  test('an AniList-only item is looked up with anilist_id', () async {
    adapter = _Adapter({});
    final s = service();
    s.request(_anime(malId: null, url: 'zm://anime/al:20958'));
    await s.idle();
    expect(
      adapter.requests.single.queryParameters,
      containsPair('anilist_id', '20958'),
    );
  });

  test('a TMDB name that does not match gives none', () async {
    adapter = _Adapter({
      _aniZip: _aniZipPayload(),
      '$_tmdb/tv/1429': {'name': 'Some Other Show', 'original_name': '別の番組'},
      '$_tmdb/tv/1429/season/2': {
        'air_date': '2017-04-01',
        'images': _posters([('/s2.jpg', 'en', 5)]),
      },
    });
    final s = service();
    s.request(_anime());
    await s.idle();
    expect(s.cachedPosterPath(_anime()), isNull);
    expect(adapter.asked('/season/'), isFalse);
  });

  test('a saved AniZip payload means no AniZip call', () async {
    adapter = _Adapter({
      '$_tmdb/tv/1429': {'name': 'Attack on Titan'},
      '$_tmdb/tv/1429/season/2': {
        'air_date': '2017-04-01',
        'images': _posters([('/s2.jpg', 'en', 5)]),
      },
    });
    final s = service(meta: _CachedMeta(_aniZipPayload()));
    s.request(_anime());
    await s.idle();
    expect(s.cachedPosterPath(_anime()), '/s2.jpg');
    expect(adapter.asked('ani.zip'), isFalse);
  });

  group('language', () {
    test('English first, then textless, never another language', () {
      expect(
        TmdbPosterService.pickPoster(
          _posters([
            ('/ja.jpg', 'ja', 9),
            ('/en.jpg', 'en', 2),
            ('/none.jpg', null, 7),
          ]),
        ),
        '/en.jpg',
      );
      expect(
        TmdbPosterService.pickPoster(
          _posters([('/ja.jpg', 'ja', 9), ('/none.jpg', null, 7)]),
        ),
        '/none.jpg',
      );
      expect(
        TmdbPosterService.pickPoster(_posters([('/ja.jpg', 'ja', 9)])),
        isNull,
      );
      // The best rated English poster wins.
      expect(
        TmdbPosterService.pickPoster(
          _posters([('/a.jpg', 'en', 3), ('/b.jpg', 'en', 6)]),
        ),
        '/b.jpg',
      );
    });

    test('images are asked for in English and textless only', () async {
      adapter = _Adapter({
        '$_tmdb/tv/7': _named(7),
        '$_tmdb/tv/7/images': _posters([('/en.jpg', 'en', 1)]),
      });
      final s = service();
      s.request(_video(7));
      await s.idle();
      expect(s.cachedPosterPath(_video(7)), '/en.jpg');
      expect(
        adapter.requests.last.queryParameters['include_image_language'],
        'en,null',
      );
    });
  });

  test(
    'adult, manga, Stremio, protected and id-less items are skipped',
    () async {
      adapter = _Adapter({});
      final s = service();
      final skipped = [
        _anime(adult: true),
        _anime(type: ProviderType.manga, url: 'zm://manga/mal:1'),
        _anime(type: ProviderType.novel, url: 'zm://novel/mal:1'),
        _anime(sourceId: 'stremio'),
        _anime(headers: {'x-ani-src': '12'}),
        _anime(headers: {'x-mihon-src': '12'}),
        _anime(malId: null, url: 'source://show/1'),
      ];
      for (final item in skipped) {
        expect(TmdbPosterService.keyFor(item), isNull, reason: item.url);
        s.request(item);
      }
      await s.idle();
      expect(adapter.requests, isEmpty);
    },
  );

  test(
    'nothing is asked while offline; it runs when the flag clears',
    () async {
      adapter = _Adapter({
        '$_tmdb/tv/7': _named(7),
        '$_tmdb/tv/7/images': _posters([('/p.jpg', 'en', 1)]),
      });
      final offline = ValueNotifier(true);
      final s = service(offline: offline);
      s.request(_video(7));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(adapter.requests, isEmpty);
      expect(s.waiting, 1);
      offline.value = false;
      await Future<void>.delayed(Duration.zero);
      await s.idle();
      expect(adapter.requests, hasLength(2));
      expect(s.cachedPosterPath(_video(7)), '/p.jpg');
      s.dispose();
    },
  );

  test('a lookup cut off by going offline waits for the network', () async {
    final offline = ValueNotifier(false);
    adapter = _Adapter({'$_tmdb/tv/7': _fail});
    final s = service(offline: offline);
    // The call fails because the connection drops while it runs.
    final realFetch = adapter.routes;
    adapter.onFetch = () => offline.value = true;
    s.request(_video(7));
    await s.idle();
    expect(adapter.requests, hasLength(1));
    adapter.onFetch = null;
    expect(store.entries, isEmpty);
    expect(s.waiting, 1);
    // Back online: tried again at once, not after the error pause.
    realFetch['$_tmdb/tv/7'] = _named(7);
    realFetch['$_tmdb/tv/7/images'] = _posters([('/p.jpg', 'en', 1)]);
    offline.value = false;
    await Future<void>.delayed(Duration.zero);
    await s.idle();
    expect(s.cachedPosterPath(_video(7)), '/p.jpg');
    s.dispose();
  });

  group('cache', () {
    test('a network error is not saved and is retried later', () async {
      adapter = _Adapter({
        '$_tmdb/tv/7': _named(7),
        '$_tmdb/tv/7/images': _fail,
      });
      final s = service();
      s.request(_video(7));
      await s.idle();
      expect(s.cachedPosterPath(_video(7)), isNull);
      expect(store.entries, isEmpty);
      // Not hammered again straight away...
      s.request(_video(7));
      await s.idle();
      expect(adapter.requests, hasLength(2));
      // ...but tried again after a while.
      adapter.routes['$_tmdb/tv/7/images'] = _posters([('/p.jpg', 'en', 1)]);
      clock = clock.add(const Duration(minutes: 6));
      s.request(_video(7));
      await s.idle();
      expect(s.cachedPosterPath(_video(7)), '/p.jpg');
    });

    test('a "none" is saved and asked again after 7 days', () async {
      adapter = _Adapter({
        '$_tmdb/tv/7': _named(7),
        '$_tmdb/tv/7/images': _posters([]),
      });
      final s = service();
      s.request(_video(7));
      await s.idle();
      expect(jsonDecode(store.entries['tv:7']!)['p'], '');
      clock = clock.add(const Duration(days: 6));
      s.request(_video(7));
      await s.idle();
      expect(adapter.requests, hasLength(2));
      clock = clock.add(const Duration(days: 2));
      s.request(_video(7));
      await s.idle();
      expect(adapter.requests, hasLength(4));
    });

    test(
      'a found poster survives a restart and is refreshed after 30 days',
      () async {
        adapter = _Adapter({
          '$_tmdb/tv/7': _named(7),
          '$_tmdb/tv/7/images': _posters([('/old.jpg', 'en', 1)]),
        });
        final first = service();
        first.request(_video(7));
        await first.idle();
        // A new launch reads the saved poster with no network call.
        adapter.requests.clear();
        final second = service();
        expect(second.cachedPosterPath(_video(7)), '/old.jpg');
        second.request(_video(7));
        await second.idle();
        expect(adapter.requests, isEmpty);
        // Still trusted at 29 days, whatever the title's spread.
        clock = clock.add(const Duration(days: 29));
        second.request(_video(7));
        await second.idle();
        expect(adapter.requests, isEmpty);
        // Past 30 days plus the spread (at most 9 more), the old poster
        // stays until the refresh finds a new one.
        clock = clock.add(const Duration(days: 11));
        adapter.routes['$_tmdb/tv/7/images'] = _fail;
        expect(second.posterPathFor(_video(7)), '/old.jpg');
        await second.idle();
        expect(second.cachedPosterPath(_video(7)), '/old.jpg');
        clock = clock.add(const Duration(minutes: 6));
        adapter.routes['$_tmdb/tv/7/images'] = _posters([
          ('/new.jpg', 'en', 1),
        ]);
        second.request(_video(7));
        await second.idle();
        expect(second.cachedPosterPath(_video(7)), '/new.jpg');
      },
    );
  });

  group('rate limit and queue', () {
    test('network calls are spaced out and run one at a time', () async {
      adapter = _Adapter({
        for (final id in [1, 2, 3]) ...{
          '$_tmdb/tv/$id': _named(id),
          '$_tmdb/tv/$id/images': _posters([('/$id.jpg', 'en', 1)]),
        },
      });
      clock = DateTime.now();
      final s = TmdbPosterService(
        Dio()..httpClientAdapter = adapter,
        store: store,
        gap: const Duration(milliseconds: 80),
      );
      for (final id in [1, 2, 3]) {
        s.request(_video(id));
        // Asking twice does not queue twice.
        s.request(_video(id));
      }
      await s.idle();
      expect(adapter.requests, hasLength(6));
      for (var i = 1; i < adapter.times.length; i++) {
        expect(
          adapter.times[i].difference(adapter.times[i - 1]).inMilliseconds,
          greaterThanOrEqualTo(70),
        );
      }
      // The newest ask (the card just built) is looked up first.
      expect(adapter.requests.first.path, endsWith('/tv/3'));
    });

    test('asking again moves a waiting lookup to the front', () async {
      adapter = _Adapter({});
      final offline = ValueNotifier(true);
      final s = service(offline: offline);
      for (final id in [1, 2, 3]) {
        s.request(_video(id));
      }
      // Card 1 scrolls back into view.
      s.request(_video(1));
      expect(s.waiting, 3);
      offline.value = false;
      await Future<void>.delayed(Duration.zero);
      await s.idle();
      expect(adapter.requests.first.path, endsWith('/tv/1'));
      s.dispose();
    });

    test('the oldest waiting lookup is dropped past the limit', () async {
      adapter = _Adapter({});
      final s = service(offline: ValueNotifier(true), maxWaiting: 2);
      for (final id in [1, 2, 3]) {
        s.request(_video(id));
      }
      expect(s.waiting, 2);
    });
  });

  group('movies and shows with a TMDB id', () {
    test('a Simkl show filed as a movie gets the show poster', () async {
      // Simkl's show rows carry the show's TMDB id on a "movie" item.
      final item = _video(1399, tv: false);
      adapter = _Adapter({
        '$_tmdb/movie/1399': {'title': 'Some Film From 1994'},
        '$_tmdb/movie/1399/images': _posters([('/film.jpg', 'en', 9)]),
        '$_tmdb/tv/1399': _named(1399),
        '$_tmdb/tv/1399/images': _posters([('/show.jpg', 'en', 5)]),
      });
      final s = service();
      s.request(item);
      await s.idle();
      expect(s.cachedPosterPath(item), '/show.jpg');
      expect(adapter.asked('/movie/1399/images'), isFalse);
    });

    test('a name that matches neither kind gives none', () async {
      final item = _video(1399, tv: false);
      adapter = _Adapter({
        '$_tmdb/movie/1399': {'title': 'Some Film'},
        '$_tmdb/movie/1399/images': _posters([('/film.jpg', 'en', 9)]),
        '$_tmdb/tv/1399': {'name': 'Show 13990 Reboot'},
        '$_tmdb/tv/1399/images': _posters([('/show.jpg', 'en', 5)]),
      });
      final s = service();
      s.request(item);
      await s.idle();
      expect(s.cachedPosterPath(item), isNull);
      expect(adapter.asked('/images'), isFalse);
    });
  });

  group('wrong posters stay out', () {
    test('a sequel with no known season keeps its cover', () async {
      // Not aired yet: no episodes, but the id already points at the show.
      adapter = _Adapter({
        _aniZip: _aniZipPayload(seasons: const []),
        '$_tmdb/tv/1429': {'name': 'Attack on Titan'},
        '$_tmdb/tv/1429/images': _posters([('/series.jpg', 'en', 9)]),
      });
      final s = service();
      s.request(_anime());
      await s.idle();
      expect(s.cachedPosterPath(_anime()), isNull);
      expect(adapter.asked(_tmdb), isFalse);
    });

    test(
      'a film TMDB does not know as a movie never takes the TV poster',
      () async {
        adapter = _Adapter({
          _aniZip: _aniZipPayload(
            type: 'MOVIE',
            seasons: [1],
            titles: {'en': 'Attack on Titan: The Movie'},
          ),
          '$_tmdb/tv/1429': {'name': 'Attack on Titan'},
          '$_tmdb/tv/1429/images': _posters([('/series.jpg', 'en', 9)]),
        });
        final s = service();
        s.request(_anime());
        await s.idle();
        expect(s.cachedPosterPath(_anime()), isNull);
        expect(adapter.asked('/tv/'), isFalse);
      },
    );

    test('a TMDB season that starts in another year gives none', () async {
      // TVDB's season 2 is a different TMDB season 2 (split differently).
      adapter = _Adapter({
        _aniZip: _aniZipPayload(),
        '$_tmdb/tv/1429': {'name': 'Attack on Titan'},
        '$_tmdb/tv/1429/season/2': {
          'air_date': '2019-04-29',
          'images': _posters([('/other.jpg', 'en', 5)]),
        },
      });
      final s = service();
      s.request(_anime());
      await s.idle();
      expect(s.cachedPosterPath(_anime()), isNull);
    });

    test('a later season with no air date gives none', () async {
      adapter = _Adapter({
        _aniZip: _aniZipPayload(airdate: null),
        '$_tmdb/tv/1429': {'name': 'Attack on Titan'},
        '$_tmdb/tv/1429/season/2': {
          'air_date': '2017-04-01',
          'images': _posters([('/s2.jpg', 'en', 5)]),
        },
      });
      final s = service();
      s.request(_anime());
      await s.idle();
      expect(s.cachedPosterPath(_anime()), isNull);
      expect(adapter.asked('/season/'), isFalse);
    });

    test('a remake filed under the older show gives none', () async {
      adapter = _Adapter({
        _aniZip: _aniZipPayload(
          seasons: [1, 1],
          titles: {'en': 'Fruits Basket'},
          airdate: '2019-04-06',
        ),
        '$_tmdb/tv/1429': {
          'name': 'Fruits Basket',
          'first_air_date': '2001-07-05',
        },
        '$_tmdb/tv/1429/images': _posters([('/2001.jpg', 'en', 9)]),
      });
      final s = service();
      final item = _anime(title: 'Fruits Basket (2019)', english: null);
      s.request(item);
      await s.idle();
      expect(s.cachedPosterPath(item), isNull);
      expect(adapter.asked('/images'), isFalse);
    });

    test('dates agree within the slack, unknown dates agree', () {
      expect(
        TmdbPosterService.yearAgrees('2001-07-20', 2001, slack: 0),
        isTrue,
      );
      expect(
        TmdbPosterService.yearAgrees('2002-01-01', 2001, slack: 1),
        isTrue,
      );
      expect(
        TmdbPosterService.yearAgrees('2003-01-01', 2001, slack: 1),
        isFalse,
      );
      expect(TmdbPosterService.yearAgrees(null, 2001, slack: 0), isTrue);
      expect(TmdbPosterService.yearAgrees('2001', null, slack: 0), isTrue);
    });
  });

  test('a fetched AniZip payload is kept for the episode list', () async {
    adapter = _Adapter({_aniZip: _aniZipPayload()});
    final meta = _CachedMeta(null);
    final s = service(meta: meta);
    s.request(_anime());
    await s.idle();
    expect(meta.remembered[25777], isA<Map<dynamic, dynamic>>());
  });

  test('a call that runs too long is cancelled and not saved', () async {
    adapter = _Adapter({'$_tmdb/tv/7': _hang});
    final s = service(timeout: const Duration(milliseconds: 50));
    s.request(_video(7));
    await s.idle();
    // Cancelled, not left running beside the next lookup.
    expect(adapter.cancelled, 1);
    expect(store.entries, isEmpty);
    expect(s.cachedPosterPath(_video(7)), isNull);
  });

  test('answers far past their use are dropped as the cache loads', () {
    final today = clock.millisecondsSinceEpoch ~/ 86400000;
    String entry(String path, int age) =>
        jsonEncode({'p': path, 'd': today - age});
    store = MemoryTmdbPosterStore({
      'tv:1': entry('', 8),
      'tv:2': entry('/old.jpg', 100),
      'tv:3': entry('/kept.jpg', 40),
      'tv:4': entry('', 1),
    });
    adapter = _Adapter({});
    final s = service();
    expect(store.entries.keys, unorderedEquals(['tv:3', 'tv:4']));
    expect(s.cachedPosterPath(_video(3)), '/kept.jpg');
    expect(s.cachedPosterPath(_video(2)), isNull);
  });

  group('saved AniZip payloads', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('tmdb_poster_anizip_');
      Hive.init(dir.path);
    });
    tearDown(() async {
      await Hive.close();
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    test('a large one is read back whole', () async {
      final meta = EpisodeMetadataService(Dio());
      final big = _aniZipPayload(seasons: List.filled(1200, 1));
      (big['episodes']! as Map)['1'] = {
        'seasonNumber': 1,
        'overview': 'x' * 80000,
      };
      await meta.rememberAniZip(21, big);
      final back = await meta.cachedAniZip(21);
      expect(back, isA<Map<dynamic, dynamic>>());
      expect(((back! as Map)['episodes'] as Map).length, 1200);
      expect(TmdbPosterService.aniZipPosterPlan(back)?.tmdbId, 1429);
    });

    test(
      'only payloads with episodes are kept, never over one saved',
      () async {
        final meta = EpisodeMetadataService(Dio());
        await meta.rememberAniZip(1, _aniZipPayload(seasons: const []));
        expect(await meta.cachedAniZip(1), isNull);
        await meta.rememberAniZip(2, _aniZipPayload(tmdbId: '1'));
        await meta.rememberAniZip(2, _aniZipPayload(tmdbId: '2'));
        final saved = await meta.cachedAniZip(2);
        expect(EpisodeMetadataService.parseAniZipTmdbId(saved), 1);
      },
    );
  });

  test('titles agree on sequels and original names', () {
    expect(
      TmdbPosterService.tmdbNameAgrees(
        {'name': 'Demon Slayer: Kimetsu no Yaiba', 'original_name': '鬼滅の刃'},
        ['Kimetsu no Yaiba: Yuukaku-hen', '鬼滅の刃 遊郭編'],
      ),
      isTrue,
    );
    expect(
      TmdbPosterService.tmdbNameAgrees(
        {'name': 'Attack on Titan'},
        ['Attack on Titan Season 3'],
      ),
      isTrue,
    );
    expect(
      TmdbPosterService.tmdbNameAgrees({'name': 'Naruto'}, ['Bleach']),
      isFalse,
    );
  });
}
