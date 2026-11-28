import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:watch_app/core/hive/safe_box.dart';

import '../models/media_item.dart';
import '../models/provider_info.dart';
import '../zmode/zmode_ids.dart';
import 'episode_metadata_service.dart';
import 'tmdb.dart';

/// Where found (and known missing) TMDB posters are kept between launches.
/// Values are the small JSON entries [TmdbPosterService] writes.
abstract class TmdbPosterStore {
  /// Every saved entry, read once at start.
  Map<String, String> load();

  /// Saves one entry. Best-effort: a failure only means it is looked up again
  /// on a later launch.
  Future<void> put(String key, String value);

  /// Forgets one entry (an answer so old it is no longer used). Best-effort.
  Future<void> remove(String key);
}

/// A store that keeps everything in memory only (tests, or when the disk box
/// could not be opened).
class MemoryTmdbPosterStore implements TmdbPosterStore {
  MemoryTmdbPosterStore([Map<String, String>? entries])
    : entries = entries ?? {};
  final Map<String, String> entries;
  @override
  Map<String, String> load() => Map.of(entries);
  @override
  Future<void> put(String key, String value) async => entries[key] = value;
  @override
  Future<void> remove(String key) async => entries.remove(key);
}

class _HiveTmdbPosterStore implements TmdbPosterStore {
  @override
  Map<String, String> load() {
    if (!Hive.isBoxOpen(TmdbPosterService.boxName)) return {};
    final box = Hive.box<String>(TmdbPosterService.boxName);
    return {
      for (final key in box.keys)
        if (box.get(key) case final String value) '$key': value,
    };
  }

  @override
  Future<void> put(String key, String value) async {
    if (!Hive.isBoxOpen(TmdbPosterService.boxName)) return;
    try {
      await Hive.box<String>(TmdbPosterService.boxName).put(key, value);
    } catch (_) {
      // The poster cache is disposable.
    }
  }

  @override
  Future<void> remove(String key) async {
    if (!Hive.isBoxOpen(TmdbPosterService.boxName)) return;
    try {
      await Hive.box<String>(TmdbPosterService.boxName).delete(key);
    } catch (_) {
      // The poster cache is disposable.
    }
  }
}

/// A lookup that failed because of the network (or TMDB was busy), as
/// opposed to a real "this title has no poster". It is never saved.
class _NetworkTrouble implements Exception {
  const _NetworkTrouble();
}

/// Windows: finds the TMDB poster for a catalogue card, because TMDB posters
/// are sharper than the AniList covers (about 230 px) most anime cards had.
///
/// Cards never wait for it. [cachedPosterPath] only reads memory, so it is
/// safe while a card builds; when nothing is known yet the card keeps its
/// usual picture and [request] queues a lookup in the background. Lookups run
/// one at a time, with a short pause between network calls, and stop while
/// the app is offline.
///
/// Anime are matched by id only: AniZip maps the MAL (or AniList) id to the
/// TMDB id and the TMDB season, and the TMDB name is checked against the
/// title. There is no title search, because remakes, sequels and split
/// seasons would match the wrong entry. A later season only ever gets that
/// season's own poster, never the series or season 1 poster.
///
/// Results are kept in memory and in a small Hive box: a found poster for 30
/// days (then refreshed in the background, keeping the old one meanwhile), a
/// "none" for 7 days. Network errors are never saved.
class TmdbPosterService {
  TmdbPosterService(
    this._dio, {
    TmdbPosterStore? store,
    this.episodeMeta,
    ValueListenable<bool>? offline,
    this.gap = const Duration(milliseconds: 250),
    this.timeout = const Duration(seconds: 20),
    this.maxWaiting = 300,
    DateTime Function()? now,
  }) : _store = store ?? _HiveTmdbPosterStore(),
       _offline = offline,
       _now = now ?? DateTime.now {
    // Answers far past their use are dropped as the cache loads, so it
    // does not keep growing with every title ever seen in search or browse.
    final stale = <String>[];
    _store.load().forEach((key, raw) {
      final entry = _parse(raw);
      if (entry == null || _tooOld(key, entry)) {
        stale.add(key);
      } else {
        _mem[key] = entry;
      }
    });
    for (final key in stale) {
      unawaited(_store.remove(key));
    }
    _offline?.addListener(_offlineChanged);
  }

  final Dio _dio;
  final TmdbPosterStore _store;

  /// Gives AniZip payloads that the episode list already saved, so a title
  /// whose episodes were opened before needs no AniZip call.
  final EpisodeMetadataService? episodeMeta;
  final ValueListenable<bool>? _offline;
  final DateTime Function() _now;

  /// Shortest pause between two network calls.
  final Duration gap;

  /// Longest wait for one network call. It is longer than the shared Dio's
  /// own 8 s connect limit plus TMDB's retry on its other host, so a network
  /// that blocks the usual TMDB host still gets its answer from the other
  /// one. A call that runs past it is cancelled, never left running.
  final Duration timeout;

  /// Most lookups kept waiting; the oldest is dropped beyond this.
  final int maxWaiting;

  static const String boxName = 'tmdb_posters';

  /// How long a "no poster" answer and a found poster are trusted.
  static const int noneDays = 7;
  static const int foundDays = 30;

  /// Found posters are refreshed after [foundDays] plus up to this many more
  /// days, spread by title, so they do not all come due on the same launch.
  static const int refreshSpreadDays = 10;

  /// A found poster not refreshed for this long (the title was not seen
  /// again) is dropped when the cache loads.
  static const int forgetDays = 90;

  /// After a network error the same title is not tried again for this long
  /// in this session (it is not saved, so the next launch tries again).
  static const Duration retryAfterError = Duration(minutes: 5);

  /// Saved answers, already decoded, so a card build only does a map read.
  final Map<String, ({String path, int day})> _mem = {};
  final LinkedHashMap<String, MediaItem> _waiting = LinkedHashMap();
  final Map<String, DateTime> _failedAt = {};
  String? _running;
  bool _pumping = false;
  DateTime? _lastCall;

  /// Opens the disk cache. Call once in initDependencies before use. Like
  /// the title-logo cache, a box that fails (or hangs) to open is wiped and
  /// opened fresh, because it is only a cache.
  static Future<void> init() async {
    try {
      await openBoxSafely<String>(boxName).timeout(const Duration(seconds: 6));
    } catch (_) {
      try {
        await Hive.deleteBoxFromDisk(boxName);
      } catch (_) {}
      try {
        await openBoxSafely<String>(boxName);
      } catch (_) {}
    }
  }

  /// The cache key for [item], or null when it should keep its own picture
  /// (adult, manga and novels, Stremio, protected source covers, no ids).
  static String? keyFor(MediaItem item, {Map<String, String>? headers}) {
    if (item.isAdult) return null;
    if (item.sourceId == 'stremio') return null;
    final sent = headers ?? item.coverHeaders;
    if (sent?['x-ani-src'] != null || sent?['x-mihon-src'] != null) {
      return null;
    }
    switch (item.type) {
      case ProviderType.manga:
      case ProviderType.novel:
        return null;
      case ProviderType.movie:
        final id = item.tmdbId;
        if (id == null) return null;
        return '${item.tmdbIsTv ? 'tv' : 'movie'}:$id';
      case ProviderType.anime:
        final ids = _animeIds(item);
        if (ids.mal != null) return 'anime:mal:${ids.mal}';
        if (ids.al != null) return 'anime:al:${ids.al}';
        return null;
    }
  }

  /// MAL and AniList ids from the item's fields, or from its catalogue url
  /// (`zm://anime/al:<n>` or `zm://anime/mal:<n>`).
  static ({int? mal, int? al}) _animeIds(MediaItem item) {
    var mal = item.malId;
    var al = item.anilistId;
    final c = ZmodeIds.parseShow(item.url);
    if (c != null && c.kind == ZKind.anime) {
      if (c.id.startsWith('mal:')) mal ??= int.tryParse(c.id.substring(4));
      if (c.id.startsWith('al:')) al ??= int.tryParse(c.id.substring(3));
    }
    return (mal: mal, al: al);
  }

  int get _today => _now().toUtc().millisecondsSinceEpoch ~/ 86400000;

  ({String path, int day})? _entry(String key) => _mem[key];

  static ({String path, int day})? _parse(String raw) {
    try {
      final map = jsonDecode(raw);
      if (map is! Map) return null;
      final path = map['p'];
      final day = map['d'];
      if (path is! String || day is! num) return null;
      return (path: path, day: day.toInt());
    } catch (_) {
      return null;
    }
  }

  bool _fresh(String key, ({String path, int day}) entry) =>
      _today - entry.day <
      (entry.path.isEmpty ? noneDays : foundDays + _spread(key));

  bool _tooOld(String key, ({String path, int day}) entry) =>
      _today - entry.day >= (entry.path.isEmpty ? noneDays : forgetDays);

  /// 0 to [refreshSpreadDays] - 1, the same for a title on every launch.
  static int _spread(String key) {
    var h = 0;
    for (final c in key.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return h % refreshSpreadDays;
  }

  /// The saved TMDB poster path (for example `/abc.jpg`) for [item], or null
  /// when none is known. Memory only, so it is safe while a card builds. A
  /// poster past its 30 days is still returned until a refresh replaces it.
  String? cachedPosterPath(MediaItem item, {Map<String, String>? headers}) {
    final key = keyFor(item, headers: headers);
    if (key == null) return null;
    final entry = _entry(key);
    return entry == null || entry.path.isEmpty ? null : entry.path;
  }

  /// [cachedPosterPath], and a background lookup when nothing fresh is known.
  String? posterPathFor(MediaItem item, {Map<String, String>? headers}) {
    final path = cachedPosterPath(item, headers: headers);
    request(item, headers: headers);
    return path;
  }

  /// Queues a background lookup for [item] unless a fresh answer is known,
  /// it is already waiting or running, or it just failed. Never waits and
  /// never throws. The newest ask is looked up first, so cards that just came
  /// on screen do not wait behind ones the viewer has scrolled past.
  void request(MediaItem item, {Map<String, String>? headers}) {
    final key = keyFor(item, headers: headers);
    if (key == null) return;
    final entry = _entry(key);
    if (entry != null && _fresh(key, entry)) return;
    if (_running == key) return;
    final failed = _failedAt[key];
    if (failed != null && _now().difference(failed) < retryAfterError) return;
    // Asked again: moved to the newest place, because the newest asks are
    // the cards being built now (on screen), and those are looked up first.
    _waiting.remove(key);
    _waiting[key] = item;
    while (_waiting.length > maxWaiting) {
      _waiting.remove(_waiting.keys.first);
    }
    // Started outside the caller (often a widget build).
    scheduleMicrotask(_pump);
  }

  /// Lookups still waiting (tests).
  @visibleForTesting
  int get waiting => _waiting.length;

  /// Completes when the queue is empty and nothing is running (tests).
  @visibleForTesting
  Future<void> idle() async {
    while (_pumping || (_waiting.isNotEmpty && !_isOffline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  bool get _isOffline => _offline?.value ?? false;

  void _offlineChanged() {
    if (!_isOffline) scheduleMicrotask(_pump);
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_waiting.isNotEmpty && !_isOffline) {
        final key = _waiting.keys.last;
        final item = _waiting.remove(key)!;
        _running = key;
        try {
          final path = await _lookup(item);
          await _save(key, path ?? '');
          _failedAt.remove(key);
        } catch (_) {
          // Network trouble (or anything unexpected) is never saved. When
          // the app just went offline the title waits for the network to
          // come back; otherwise it is left alone for a few minutes.
          if (_isOffline) {
            _waiting[key] = item;
          } else {
            _failedAt[key] = _now();
          }
        } finally {
          _running = null;
        }
      }
    } finally {
      _pumping = false;
    }
  }

  Future<void> _save(String key, String path) async {
    final day = _today;
    _mem[key] = (path: path, day: day);
    await _store.put(key, jsonEncode({'p': path, 'd': day}));
  }

  /// One network call, at least [gap] after the previous one. Returns the
  /// JSON body, or null for a real "not found". Throws [_NetworkTrouble] for
  /// network errors, time-outs, a busy TMDB (429) and server errors.
  Future<Object?> _get(String url, [Map<String, dynamic>? query]) async {
    if (_isOffline) throw const _NetworkTrouble();
    final last = _lastCall;
    if (last != null) {
      final wait = gap - _now().difference(last);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
    }
    _lastCall = _now();
    final Response<dynamic> res;
    final cancel = CancelToken();
    // Cancelled (not abandoned) when it runs too long, so it cannot go on in
    // the background beside the next lookup.
    final limit = Timer(timeout, () => cancel.cancel('poster lookup timeout'));
    try {
      res = await _dio.get<dynamic>(
        url,
        queryParameters: query,
        cancelToken: cancel,
        options: Options(validateStatus: (c) => c != null && c < 500),
      );
    } catch (_) {
      throw const _NetworkTrouble();
    } finally {
      limit.cancel();
    }
    final status = res.statusCode ?? 0;
    if (status == 429 || status >= 500) throw const _NetworkTrouble();
    if (status == 401 || status == 403) throw const _NetworkTrouble();
    if (status >= 400) return null;
    final data = res.data;
    if (data is String) {
      try {
        return jsonDecode(data);
      } catch (_) {
        return null;
      }
    }
    return data;
  }

  /// The poster path for [item], or null for "none".
  Future<String?> _lookup(MediaItem item) async {
    if (item.type == ProviderType.movie) return _videoLookup(item);
    return _animeLookup(item);
  }

  static const Map<String, dynamic> _imageQuery = {
    'include_image_language': 'en,null',
  };

  /// A movie or show that came with a TMDB id but not a TMDB cover (Simkl,
  /// trackers, sources). TMDB movie and show ids overlap, and some lists do
  /// not say which kind they hold (a Simkl show is filed as a movie with its
  /// show id), so the kind the item says is tried first and the other one
  /// after it, and a poster is only taken when TMDB's name is the item's.
  Future<String?> _videoLookup(MediaItem item) async {
    final id = item.tmdbId!;
    final names = <String>[item.title, ?item.englishTitle];
    final kinds = item.tmdbIsTv ? const ['tv', 'movie'] : const ['movie', 'tv'];
    for (final kind in kinds) {
      final details = await _get('${Tmdb.base}/$kind/$id');
      if (details == null || !tmdbNameAgrees(details, names, exact: true)) {
        continue;
      }
      return pickPoster(
        await _get('${Tmdb.base}/$kind/$id/images', _imageQuery),
      );
    }
    return null;
  }

  Future<String?> _animeLookup(MediaItem item) async {
    final ids = _animeIds(item);
    Object? payload;
    if (ids.mal != null && episodeMeta != null) {
      payload = await episodeMeta!.cachedAniZip(ids.mal!);
    }
    if (payload == null) {
      payload = await _get('https://api.ani.zip/mappings', {
        if (ids.mal != null) 'mal_id': ids.mal else 'anilist_id': ids.al,
      });
      // Kept where the episode list looks first, so opening this show later
      // (or refreshing its poster) needs no second AniZip download.
      final mal = ids.mal;
      if (mal != null && payload != null) {
        unawaited(episodeMeta?.rememberAniZip(mal, payload));
      }
    }
    final plan = aniZipPosterPlan(payload);
    if (plan == null) return null;
    final names = <String>[item.title, ?item.englishTitle, ...plan.titles];
    if (plan.film) {
      // A film only ever takes its own movie poster. When TMDB does not know
      // the id as a movie with this name, it keeps its cover rather than
      // taking the poster of the TV series it belongs to.
      final movie = await _get('${Tmdb.base}/movie/${plan.tmdbId}');
      if (movie is! Map || !tmdbNameAgrees(movie, names)) return null;
      if (!yearAgrees(movie['release_date'], plan.year, slack: 1)) return null;
      return pickPoster(
        await _get('${Tmdb.base}/movie/${plan.tmdbId}/images', _imageQuery),
      );
    }
    // With no known season it cannot be told apart from a sequel (unaired
    // sequels often have no episodes yet but already point at the parent
    // show), so it keeps its cover.
    final season = plan.season;
    if (season == null) return null;
    final show = await _get('${Tmdb.base}/tv/${plan.tmdbId}');
    if (show is! Map || !tmdbNameAgrees(show, names)) return null;
    if (season == 1) {
      // A remake filed under the older show started in another year.
      if (!yearAgrees(show['first_air_date'], plan.year, slack: 1)) {
        return null;
      }
      return pickPoster(
        await _get('${Tmdb.base}/tv/${plan.tmdbId}/images', _imageQuery),
      );
    }
    // A later season only takes its own poster. With none, the card keeps
    // its AniList cover rather than borrowing the series poster. AniZip's
    // season numbers come from TVDB, which splits some shows differently
    // from TMDB, so the TMDB season must also start in the same year.
    if (plan.year == null) return null;
    final details = await _get(
      '${Tmdb.base}/tv/${plan.tmdbId}/season/$season',
      {..._imageQuery, 'append_to_response': 'images'},
    );
    if (details is! Map || _yearOf(details['air_date']) != plan.year) {
      return null;
    }
    return pickPoster(details['images']);
  }

  /// Whether a TMDB date (`2019-04-06`) falls within [slack] years of
  /// [year]. Unknown on either side counts as agreeing.
  static bool yearAgrees(Object? date, int? year, {required int slack}) {
    if (year == null) return true;
    final tmdbYear = _yearOf(date);
    if (tmdbYear == null) return true;
    return (tmdbYear - year).abs() <= slack;
  }

  static int? _yearOf(Object? date) {
    if (date is! String || date.length < 4) return null;
    return int.tryParse(date.substring(0, 4));
  }

  /// What an AniZip payload says about finding the TMDB poster, or null when
  /// it rules one out (no TMDB id, a special or music video, or only season 0
  /// episodes).
  ///
  /// Checked on real payloads: `themoviedb_id` comes as a string, the type
  /// is MOVIE / TV / OVA / ONA / SPECIAL / MUSIC, and for an anime film
  /// (Spirited Away, MAL 199) the id is a TMDB movie id (129). [year] is the
  /// year the entry's first episode of [season] aired.
  static ({int tmdbId, int? season, int? year, bool film, List<String> titles})?
  aniZipPosterPlan(Object? payload) {
    if (payload is! Map) return null;
    final tmdbId = EpisodeMetadataService.parseAniZipTmdbId(payload);
    if (tmdbId == null || tmdbId <= 0) return null;
    final mappings = payload['mappings'];
    final type = mappings is Map
        ? '${mappings['type'] ?? ''}'.toUpperCase()
        : '';
    if (type == 'SPECIAL' || type == 'MUSIC') return null;
    // Episodes that are all season 0 are specials on TMDB.
    final episodes = payload['episodes'];
    if (episodes is Map && episodes.isNotEmpty) {
      final seasons = [
        for (final e in episodes.values)
          if (e is Map && e['seasonNumber'] is num)
            (e['seasonNumber'] as num).toInt(),
      ];
      if (seasons.isNotEmpty && seasons.every((s) => s <= 0)) return null;
    }
    final season = EpisodeMetadataService.parseAniZipSeason(payload);
    int? year;
    if (episodes is Map) {
      for (final e in episodes.values) {
        if (e is! Map) continue;
        final n = (e['seasonNumber'] as num?)?.toInt();
        // Specials air at other times, so only the entry's own season counts.
        if (season != null ? n != season : (n != null && n <= 0)) continue;
        final y = _yearOf(e['airdate'] ?? e['airDate'] ?? e['airDateUtc']);
        if (y != null && (year == null || y < year)) year = y;
      }
    }
    final titles = payload['titles'];
    return (
      tmdbId: tmdbId,
      season: season,
      year: year,
      film: type == 'MOVIE',
      titles: [
        if (titles is Map)
          for (final lang in const ['en', 'x-jat', 'ja'])
            if (titles[lang] case final String t when t.trim().isNotEmpty) t,
      ],
    );
  }

  /// Whether a TMDB movie or show answer names the same title as one of
  /// [names]: equal once season and year markers are stripped, or one name
  /// starting with the other (a sequel's "Demon Slayer: Kimetsu no Yaiba
  /// Entertainment District Arc" is TMDB's "Demon Slayer: Kimetsu no Yaiba").
  /// With [exact] only equal names count (a movie or show whose id may be
  /// the other kind's, where a shared first word proves nothing).
  static bool tmdbNameAgrees(
    Object? details,
    List<String> names, {
    bool exact = false,
  }) {
    if (details is! Map) return false;
    final tmdbNames = <String>[
      for (final field in const [
        'name',
        'original_name',
        'title',
        'original_title',
      ])
        if (details[field] case final String n when n.trim().isNotEmpty) n,
    ];
    if (tmdbNames.isEmpty) return false;
    for (final tmdbName in tmdbNames) {
      final probe = MediaItem(
        id: '',
        title: tmdbName,
        url: '',
        type: ProviderType.anime,
        sourceId: '',
      );
      final a = normalizeTitle(tmdbName);
      for (final name in names) {
        if (titleMatches(probe, name)) return true;
        if (exact) continue;
        final b = normalizeTitle(name);
        if (a.length < 4 || b.length < 4) continue;
        if (a.startsWith(b) || b.startsWith(a)) return true;
      }
    }
    return false;
  }

  /// The best poster in a TMDB images answer: the English one with the best
  /// rating, else the best one with no text language (textless art). Never a
  /// poster in another language. Null when there is none.
  static String? pickPoster(Object? data) {
    if (data is! Map) return null;
    final posters = data['posters'];
    if (posters is! List) return null;
    String? best(bool Function(Object?) language) {
      String? path;
      var score = -1.0;
      var votes = -1;
      for (final p in posters) {
        if (p is! Map || !language(p['iso_639_1'])) continue;
        final file = p['file_path'];
        if (file is! String || !file.startsWith('/')) continue;
        final s = (p['vote_average'] as num?)?.toDouble() ?? 0;
        final v = (p['vote_count'] as num?)?.toInt() ?? 0;
        if (s > score || (s == score && v > votes)) {
          path = file;
          score = s;
          votes = v;
        }
      }
      return path;
    }

    return best((l) => l == 'en') ??
        best((l) => l == null || (l is String && l.isEmpty));
  }

  /// Stops listening for the offline flag.
  void dispose() => _offline?.removeListener(_offlineChanged);
}
