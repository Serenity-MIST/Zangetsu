import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/di/injector.dart';
import '../../core/models/media_detail.dart';
import '../../core/models/media_item.dart';
import '../../core/ui/featured_hero.dart' show HeroMeta;
import '../../core/zmode/anilist_catalogue.dart';
import 'home_banner_anilist.dart';
import 'home_known_artwork.dart';

/// Loads a show's detail for the Home banner. Same shape as Home's own
/// `_detailOf`: it swallows errors and answers null instead.
typedef HomeBannerDetailLoader =
    Future<MediaDetail?> Function(
      String url,
      String sourceId, {
      void Function(MediaDetail partial)? onPartial,
      bool Function()? abandoned,
    });

/// The extra text the Home banner shows under a title (genres, description,
/// episode count, year), one answer per show, kept for the life of Home.
///
/// Phone: unchanged. The first time a slide is shown its detail is loaded
/// (catalogue first; the source match is dropped as soon as the catalogue has
/// answered) and the answer is reused on every later rotation.
///
/// Windows: never loads a show's detail. A show's details and its source
/// matching only load when the user opens it (Details, Watch now, or the
/// card). The banner rotates every few seconds, so loading a detail per slide
/// meant a catalogue request and a source search every 8 seconds, even while
/// the user was just scrolling. The banner therefore shows what the Home rows
/// already carry: title, art, genres, score, and the short description a
/// catalogue list answer includes (TMDB always, AniList on the banner row).
/// A source catalogue title without one borrows the description of the same
/// show from catalogue rows already in memory ([known]).
///
/// One exception, for source catalogue titles (Aniyomi extension rows:
/// anime, manga, novels) that still have no description after that: the
/// slide that is ON SCREEN may ask AniList once for its synopsis
/// ([HomeBannerAniList]). It is one tiny GraphQL search by title (perPage 1,
/// names and description only), never a source search, a detail load or an
/// episode list. It is only sent once the slide has stayed on screen for
/// [lookupDelay] (a slide the user skips past asks nothing), only used when
/// AniList's names match the title closely, kept per title so it is never
/// asked twice, and silent on errors and rate limits (the banner then just
/// shows the genres). Other slides are never looked up ahead of time.
class HomeBannerMeta {
  HomeBannerMeta({
    required this.loadDetail,
    this.known,
    @visibleForTesting this.windows,
    @visibleForTesting HomeBannerAniList? aniList,
    this.lookupDelay = const Duration(seconds: 1),
  }) : _givenAniList = aniList;

  final HomeBannerDetailLoader loadDetail;

  /// Windows: catalogue titles the app already holds, searched for the same
  /// show when the banner title has no description of its own. Null skips
  /// the search.
  final HomeKnownTitles Function()? known;

  /// Tests force the platform; null reads it from the running platform.
  final bool? windows;

  /// Windows: how long a slide must stay on screen before its AniList
  /// look-up is sent.
  final Duration lookupDelay;

  /// The AniList look-up tests hand in; null builds the real one.
  final HomeBannerAniList? _givenAniList;

  /// Windows: the AniList look-up for source catalogue slides. Built on
  /// first use from the app's shared HTTP client; null when there is none
  /// (tests without the app's services), which simply skips the look-up.
  late final HomeBannerAniList? _aniList = _givenAniList ?? _defaultAniList();

  static HomeBannerAniList? _defaultAniList() {
    if (!sl.isRegistered<Dio>()) return null;
    final catalogue = AniListCatalogue(AniListCatalogue.dioGql(sl<Dio>()));
    return HomeBannerAniList(catalogue.bannerLookup);
  }

  bool get _windows =>
      windows ?? defaultTargetPlatform == TargetPlatform.windows;

  /// Futures, not results, so a slide that comes round again never loads twice.
  final Map<String, Future<HeroMeta?>> _cache = {};

  /// Windows: the slide last asked for, which is the one on screen (the
  /// banner only asks for the slide it shows). A waiting look-up checks it
  /// after [lookupDelay] and drops out when the slide has changed.
  String? _onScreen;

  /// Windows: look-ups waiting or in flight, per slide, so rebuilds of the
  /// same slide hand the banner the same future.
  final Map<String, Future<HeroMeta?>> _waiting = {};

  /// Windows: slides AniList has already answered "no match" for; they are
  /// not asked again.
  final Set<String> _missed = {};

  /// Bumped by [clear], so a look-up started before it does not write into
  /// the fresh cache.
  int _generation = 0;

  /// Banner text for [m]. Pass this (as a tear-off) wherever a banner asks
  /// for its `meta`.
  ///
  /// Windows answers right away from data already held: the title's own
  /// description (or the same show's from [known]) with the row's genres,
  /// or "nothing extra" so the banner falls back to the genres. A found
  /// answer is kept per show, so a rebuild hands the banner the same future
  /// and it does not flicker. "Nothing" is not kept: the catalogue rows can
  /// arrive later and the next rotation should then find the description.
  /// A source catalogue slide with nothing held starts the delayed AniList
  /// look-up described on the class instead.
  Future<HeroMeta?> call(MediaItem m) {
    final key = '${m.sourceId}:${m.id}';
    // Windows: remember which slide is on screen, cache hit or not.
    if (_windows) _onScreen = key;
    final hit = _cache[key];
    if (hit != null) return hit;
    if (!_windows) return _cache[key] = _load(m);
    final description = (known?.call() ?? HomeKnownTitles.empty).descriptionFor(
      m,
    );
    if (description != null) {
      return _cache[key] = Future<HeroMeta?>.value(
        HeroMeta(genres: m.genres, description: description),
      );
    }
    final aniList = _aniList;
    if (aniList == null ||
        !HomeBannerAniList.eligible(m) ||
        _missed.contains(key)) {
      return _nothing;
    }
    return _waiting[key] ??= _lookUpWhenSettled(m, key, aniList);
  }

  /// Windows: waits [lookupDelay], then (if [m] is still the slide on
  /// screen) asks [aniList] for its description. A title AniList already
  /// answered for needs no wait. Answers null when the slide changed, there
  /// is no close match, or the request failed.
  Future<HeroMeta?> _lookUpWhenSettled(
    MediaItem m,
    String key,
    HomeBannerAniList aniList,
  ) async {
    final generation = _generation;
    if (!aniList.holds(m)) {
      await Future<void>.delayed(lookupDelay);
      if (generation != _generation) return null;
      if (_onScreen != key) {
        // Skipped past: ask nothing; the slide starts over when it is back.
        _waiting.remove(key);
        return null;
      }
    }
    final text = await aniList.description(m);
    if (generation != _generation) return null;
    _waiting.remove(key);
    if (text == null) {
      // A kept answer means AniList really had no match: never ask again.
      // Otherwise (an error, or resting after one) a later rotation retries.
      if (aniList.holds(m)) _missed.add(key);
      return null;
    }
    final meta = HeroMeta(genres: m.genres, description: text);
    _cache[key] = Future<HeroMeta?>.value(meta);
    return meta;
  }

  /// One shared "nothing extra" answer, so repeated rebuilds of a title
  /// without a description keep handing the banner the same future.
  late final Future<HeroMeta?> _nothing = Future<HeroMeta?>.value();

  /// Forget every answer, for example after the active source changed.
  /// (AniList answers per title stay in [HomeBannerAniList]; they do not
  /// depend on the source.)
  void clear() {
    _cache.clear();
    _waiting.clear();
    _missed.clear();
    _generation++;
  }

  /// Settles on the FIRST of two answers: the partial a metadata title hands
  /// over once its catalogue has replied, or the finished detail. A metadata
  /// title's `detail()` also pairs the title with an installed source before
  /// it returns, and that pairing searches every installed source in turn —
  /// one report spent 18 seconds on a title no source carried, with the
  /// banner's caption blank the whole time and the carousel rotating on. The
  /// caption is genres, a count and a year; the catalogue supplies all three
  /// up front, and the source is only needed for episode *urls*, which the
  /// banner never reads. Once that partial result arrives, the unused source
  /// match is abandoned so Home cannot keep provider work running underneath
  /// a detail screen.
  ///
  /// A source-backed title never calls `onPartial` — it has nothing to search
  /// for — and completes on the second branch exactly as it always did.
  Future<HeroMeta?> _load(MediaItem m) async {
    final first = Completer<MediaDetail?>();
    void settle(MediaDetail? d) {
      if (!first.isCompleted) first.complete(d);
    }

    // The loader swallows its errors, so this always settles.
    unawaited(
      loadDetail(
        m.url,
        m.sourceId,
        onPartial: settle,
        abandoned: () => first.isCompleted,
      ).then(settle),
    );
    final d = await first.future;
    if (d == null) return null;
    return HeroMeta(
      genres: d.genres,
      description: d.description,
      episodeCount: d.episodes.length,
      year: d.year,
    );
  }
}
