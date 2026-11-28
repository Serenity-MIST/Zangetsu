import '../../core/models/media_item.dart';
import '../../core/models/provider_info.dart';
import '../../core/zmode/zmode_ids.dart';

/// Windows Home: catalogue titles the app already holds (metadata Home rows
/// of any kind, in memory or saved on disk), indexed so the banner and the
/// Continue cards can borrow the same show's wide picture or short
/// description without asking any server. Nothing here loads anything.
///
/// A title matches on the same show URL first, then on a shared AniList,
/// MyAnimeList or TMDB id, and last on the same title (ignoring case,
/// accents and punctuation). Only titles that actually carry what is wanted
/// are considered, so a twin without the picture never hides one that has
/// it. The index is built once; look-ups are map reads.
class HomeKnownTitles {
  HomeKnownTitles(Iterable<MediaItem> items) {
    for (final item in items) {
      void add<K>(Map<K, List<MediaItem>> map, K? key) {
        if (key == null) return;
        (map[key] ??= []).add(item);
      }

      if (item.url.isNotEmpty) add(_byUrl, item.url);
      add(_byMal, item.malId);
      add(_byAniList, item.anilistId);
      add(_byTmdb, item.tmdbId);
      for (final title in {item.title, ?item.englishTitle}) {
        final key = normalizeTitle(title);
        if (key.isNotEmpty) add(_byTitle, key);
      }
    }
  }

  /// No titles at all.
  static final empty = HomeKnownTitles(const []);

  final Map<String, List<MediaItem>> _byUrl = {}, _byTitle = {};
  final Map<int, List<MediaItem>> _byMal = {}, _byAniList = {}, _byTmdb = {};

  /// The same show as described, among titles for which [wanted] is true
  /// and that are read ([reading]) or watched like it.
  ///
  /// The last step, a match on the title alone, can name a different show
  /// (a film and a series of the same name, or a remake such as Hunter x
  /// Hunter 1999 and 2011). So a title match is skipped when the two are of
  /// a different kind (film, series, anime: read from `zm://` show urls) or
  /// carry different AniList, MyAnimeList or TMDB ids. With
  /// [titleNeedsKind] it is also skipped unless both kinds are known and the
  /// same (used for Continue cards, where a wrong picture is worse than the
  /// poster).
  MediaItem? twin({
    required String title,
    String? englishTitle,
    String? url,
    int? malId,
    int? anilistId,
    int? tmdbId,
    required bool reading,
    required bool Function(MediaItem item) wanted,
    bool titleNeedsKind = false,
  }) {
    MediaItem? first(List<MediaItem>? list, {bool byTitle = false}) {
      if (list == null) return null;
      for (final item in list) {
        // A show to watch never borrows from a book of the same name (the
        // manga of an anime), and the other way round.
        if (homeIsReading(item.type) != reading || !wanted(item)) continue;
        if (byTitle &&
            !_titleTwinAllowed(
              item,
              url: url,
              malId: malId,
              anilistId: anilistId,
              tmdbId: tmdbId,
              needKind: titleNeedsKind,
            )) {
          continue;
        }
        return item;
      }
      return null;
    }

    return first(_byUrl[url]) ??
        first(_byMal[malId]) ??
        first(_byAniList[anilistId]) ??
        first(_byTmdb[tmdbId]) ??
        first(_byTitle[normalizeTitle(title)], byTitle: true) ??
        (englishTitle == null
            ? null
            : first(_byTitle[normalizeTitle(englishTitle)], byTitle: true));
  }

  /// Whether [item], found by title only, may stand in for the described
  /// show (see [twin]).
  static bool _titleTwinAllowed(
    MediaItem item, {
    String? url,
    int? malId,
    int? anilistId,
    int? tmdbId,
    required bool needKind,
  }) {
    bool differ(int? a, int? b) => a != null && b != null && a != b;
    if (differ(malId, item.malId) ||
        differ(anilistId, item.anilistId) ||
        differ(tmdbId, item.tmdbId)) {
      return false;
    }
    final wantKind = url == null ? null : ZmodeIds.parseShow(url)?.kind;
    final itemKind = ZmodeIds.parseShow(item.url)?.kind;
    if (wantKind != null && itemKind != null) return wantKind == itemKind;
    return !needKind;
  }

  MediaItem? _twinOf(MediaItem item, bool Function(MediaItem) wanted) => twin(
    title: item.title,
    englishTitle: item.englishTitle,
    url: item.url,
    malId: item.malId,
    anilistId: item.anilistId,
    tmdbId: item.tmdbId,
    reading: homeIsReading(item.type),
    wanted: wanted,
  );

  /// A wide picture for [item]: its own, else the same show's from these
  /// titles. Null when neither exists.
  String? wideArtFor(MediaItem item) {
    final own = homeWideArtOf(item);
    if (own != null) return own;
    final twin = _twinOf(item, (i) => homeWideArtOf(i) != null);
    return twin == null ? null : homeWideArtOf(twin);
  }

  /// A short description for [item]: its own, else the same show's from
  /// these titles. Null when neither exists.
  String? descriptionFor(MediaItem item) {
    final own = homeDescriptionOf(item);
    if (own != null) return own;
    final twin = _twinOf(item, (i) => homeDescriptionOf(i) != null);
    return twin == null ? null : homeDescriptionOf(twin);
  }
}

/// The widest picture [item] carries itself: its banner / backdrop, then a
/// landscape poster. Null when it only has a portrait cover.
String? homeWideArtOf(MediaItem item) {
  for (final url in [item.banner, item.landscapePoster]) {
    final trimmed = url?.trim();
    if (trimmed != null && trimmed.isNotEmpty) return trimmed;
  }
  return null;
}

/// [item]'s own short description, or null when it has none.
String? homeDescriptionOf(MediaItem item) {
  final text = item.description?.trim();
  return text == null || text.isEmpty ? null : text;
}

/// True for titles that are read (manga, novels) rather than watched.
bool homeIsReading(ProviderType type) =>
    type == ProviderType.manga || type == ProviderType.novel;
