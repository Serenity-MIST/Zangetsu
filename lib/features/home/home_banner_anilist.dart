import 'dart:async';
import 'dart:collection';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

// The app's shared AniList description cleaner, reused for banner text.
import '../../core/metadata/synopsis.dart';
import '../../core/models/media_item.dart';
import '../../core/models/provider_info.dart';
import '../../core/zmode/zmode_ids.dart';
import 'home_known_artwork.dart' show homeIsReading;

/// Asks AniList for the single best hit for a title; same shape as
/// `AniListCatalogue.bannerLookup`. It may throw; [HomeBannerAniList] handles
/// that.
typedef HomeBannerAniListSearch =
    Future<Map<String, dynamic>?> Function(String title, {required bool manga});

/// Windows Home banner: a short description for a source catalogue title
/// (an Aniyomi extension row) that came without one, from one small AniList
/// search by title.
///
/// The rules that keep it cheap and safe:
/// * One request per title, ever: the answer (including "AniList has no
///   such show") is kept as a future per title, so a slide that comes round
///   again, or a rebuild, never asks twice. At most [capacity] titles are
///   kept; the least recently used one is dropped first.
/// * The answer is only used when AniList's names match the slide's title
///   closely ([bannerTitleMatches]), so a loose search hit never puts the
///   wrong show's story under a title.
/// * Errors answer null without a word and are not kept, so a later
///   rotation can try again. After an error (HTTP 429 rate limit above all)
///   nothing is asked for a while ([quietAfterError] / [quietAfterLimit]).
/// * Only source titles that are anime, manga or novels are looked up:
///   metadata catalogue titles (`zm`) already carry their own text, and a
///   film or series from another source is not on AniList.
class HomeBannerAniList {
  HomeBannerAniList(
    this.search, {
    this.capacity = 64,
    this.quietAfterError = const Duration(seconds: 30),
    this.quietAfterLimit = const Duration(minutes: 2),
    @visibleForTesting DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// The AniList transport.
  final HomeBannerAniListSearch search;

  /// Most titles whose answers are kept.
  final int capacity;

  /// How long nothing is asked after a failed request.
  final Duration quietAfterError;

  /// How long nothing is asked after AniList said "too many requests".
  final Duration quietAfterLimit;

  final DateTime Function() _now;

  /// Answers per title key (see [_keyOf]), oldest first. A [LinkedHashMap]
  /// keeps insertion order, so re-inserting on use makes it least recently
  /// used first.
  final LinkedHashMap<String, Future<String?>> _cache = LinkedHashMap();

  /// No request is sent before this moment (set after an error).
  DateTime? _quietUntil;

  /// How many titles currently have a kept answer (tests read it).
  @visibleForTesting
  int get cachedCount => _cache.length;

  /// Whether [item] is a title this lookup may describe at all.
  static bool eligible(MediaItem item) =>
      item.sourceId != ZmodeIds.sourceId &&
      item.type != ProviderType.movie &&
      bannerSearchTitle(item.title).isNotEmpty;

  /// Whether an answer for [item] is already kept (finished or on its way).
  bool holds(MediaItem item) => _cache.containsKey(_keyOf(item));

  /// The kept answer for [item] without asking anything, or null when there
  /// is none.
  Future<String?>? peek(MediaItem item) => _cache[_keyOf(item)];

  /// Cache key: what is searched (anime or book) plus the normalized title.
  static String _keyOf(MediaItem item) =>
      '${homeIsReading(item.type) ? 'M' : 'A'}:'
      '${normalizeBannerTitle(item.title)}';

  /// The AniList description for [item], HTML stripped, or null when
  /// AniList has no close match, the title is not [eligible], the lookup is
  /// resting after an error, or the request failed.
  Future<String?> description(MediaItem item) {
    if (!eligible(item)) return Future<String?>.value();
    final key = _keyOf(item);
    final hit = _cache.remove(key);
    if (hit != null) {
      // Used again: move it to the newest end.
      _cache[key] = hit;
      return hit;
    }
    final quiet = _quietUntil;
    if (quiet != null && _now().isBefore(quiet)) return Future<String?>.value();
    final future = _ask(item, key);
    _cache[key] = future;
    while (_cache.length > capacity) {
      _cache.remove(_cache.keys.first);
    }
    return future;
  }

  /// Sends the one request for [item] and checks the answer's names.
  Future<String?> _ask(MediaItem item, String key) async {
    try {
      final media = await search(
        bannerSearchTitle(item.title),
        manga: homeIsReading(item.type),
      );
      if (media == null) return null;
      final names = [item.title, ?item.englishTitle];
      if (!names.any((n) => bannerTitleMatches(n, media))) return null;
      return cleanBannerDescription(media['description'] as String?);
    } catch (e) {
      // Not kept: a later rotation may try again once the rest is over.
      _cache.remove(key);
      final limited = e is DioException && e.response?.statusCode == 429;
      _quietUntil = _now().add(limited ? quietAfterLimit : quietAfterError);
      return null;
    }
  }
}

/// Bracketed notes source sites add to a title: "[Uncensored]", "(Dub)",
/// "(TV)", "{Raw}".
final _bracketed = RegExp(r'[\[(（【{][^\])）】}]*[\])）】}]');

/// Language / release notes some sources append without brackets.
final _releaseNotes = RegExp(
  r'\b(dub(bed)?|sub(bed)?|uncensored|raw|english dub|eng dub)\s*$',
  caseSensitive: false,
);

/// [title] as sent to AniList's search: without bracketed notes or a
/// trailing "Dub" / "Sub", spaces tidied. Season words stay, they help
/// AniList pick the right season.
String bannerSearchTitle(String title) => title
    .replaceAll(_bracketed, ' ')
    .replaceAll(_releaseNotes, ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Season / part words, removed before titles are compared so "Title
/// Season 2" or "Title 2nd Season" matches AniList's "Title".
final _seasonWords = RegExp(
  // "The Final Season" first, so its "the" goes with it.
  r'\b(the\s+)?final\s+(season|part|cour)\b'
  r'|\b(season|part|cour|series)\s*\d+\b'
  r'|\b\d+(st|nd|rd|th)\s+(season|part|cour)\b'
  r'|\b(first|second|third|fourth|fifth)\s+(season|part|cour)\b'
  r'|\bs\d+\b',
  caseSensitive: false,
);

/// [title] reduced for comparison: notes and season words removed, then
/// lowercased with accents folded and every space / punctuation mark
/// dropped (the app's [normalizeTitle]).
String normalizeBannerTitle(String title) =>
    normalizeTitle(bannerSearchTitle(title).replaceAll(_seasonWords, ' '));

/// Whether AniList's [media] answer (its romaji, English and native titles
/// and synonyms) names the same show as [title], compared with
/// [normalizeBannerTitle]. An empty title never matches.
bool bannerTitleMatches(String title, Map<String, dynamic> media) {
  final want = normalizeBannerTitle(title);
  if (want.isEmpty) return false;
  final names = <String>[];
  final t = media['title'];
  if (t is Map) {
    for (final k in const ['romaji', 'english', 'native']) {
      final v = t[k];
      if (v is String) names.add(v);
    }
  }
  final synonyms = media['synonyms'];
  if (synonyms is List) names.addAll(synonyms.whereType<String>());
  return names.any((n) => normalizeBannerTitle(n) == want);
}

/// Turns an AniList description into one line of banner text.
///
/// The app's shared cleaner [cleanSynopsis] does the real work: it removes
/// HTML tags, decodes entities (`&mdash;`, `&nbsp;`, `&hellip;` and the
/// rest) and drops AniList's own markup (`~!spoiler!~` markers and
/// `__bold__`). The banner then needs two small extras on top:
/// - a trailing "(Source: ...)" credit note is removed, because it is not
///   part of the story and wastes the banner's few lines;
/// - all whitespace, including the paragraph breaks [cleanSynopsis] keeps,
///   is collapsed to single spaces so the text reads as one line.
/// Null or empty answers null.
String? cleanBannerDescription(String? raw) {
  final cleaned = cleanSynopsis(raw);
  if (cleaned == null) return null;
  final text = cleaned
      // The credit note AniList puts at the very end, e.g.
      // "(Source: Crunchyroll)". Only a trailing one is removed so a
      // bracket in the middle of the story is never touched.
      .replaceAll(
        RegExp(r'\(\s*Source:[^)]*\)\s*$', caseSensitive: false),
        '',
      )
      // One line for the banner.
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return text.isEmpty ? null : text;
}
