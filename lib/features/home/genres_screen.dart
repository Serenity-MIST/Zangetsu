import '../../core/mode/content_mode.dart';
import 'dart:async';

import 'package:dio/dio.dart';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../../core/di/injector.dart';
import '../../core/mode/content_mode_cubit.dart';
import '../../core/models/home_section.dart';
import '../../core/models/media_item.dart';
import '../../core/models/provider_info.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/profiles/viewer_profile.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/app_toast.dart';
import '../../core/zmode/anilist_catalogue.dart';
import '../../core/zmode/genre_catalog.dart';
import '../../core/zmode/metadata_filters.dart';
import '../../core/zmode/metadata_repository.dart';
import '../../core/zmode/zmode_ids.dart';
import '../../core/zmode/zmode_module.dart';
import '../../core/zmode/zmode_prefs.dart';
import '../../l10n/l10n.dart';
import 'cubit/home_cubit.dart';
import 'search_screen.dart';

/// A cover to stand behind a genre tile.
typedef GenreArt = ({String url, Map<String, String>? headers});

/// One cover per genre, picked out of rows that are already on screen.
///
/// Every catalogue that can filter also returns `genres` on its media, so a
/// representative image costs nothing — no request per tile, and no hand-kept
/// table of genre artwork to rot. Two rules make it look deliberate rather
/// than arbitrary:
///
/// * first match wins, so the order Home loaded its rows in decides, and the
///   grid does not reshuffle between visits;
/// * an image is used once. One popular cover carries five or six genres, and
///   without this the same poster sits under half the grid.
///
/// Genres nothing on screen happens to carry are simply absent, and their
/// tile falls back to its own tint.
Map<String, GenreArt> genreArtFrom(List<HomeSection> sections, {ZKind? kind}) {
  final out = <String, GenreArt>{};
  final used = <String>{};
  for (final s in sections) {
    for (final MediaItem m in s.items) {
      // Home can retain the previous catalogue while its replacement loads.
      // Canonical identity is stronger than a provider's generic video type.
      if (kind != null) {
        final mediaKind = ZmodeIds.parseShow(m.url)?.kind ?? switch (m.type) {
          ProviderType.anime => ZKind.anime,
          ProviderType.movie => ZKind.movie,
          ProviderType.manga => ZKind.manga,
          ProviderType.novel => ZKind.novel,
        };
        final video = kind == ZKind.movie || kind == ZKind.tv;
        if (video ? mediaKind != ZKind.movie && mediaKind != ZKind.tv
            : mediaKind != kind) continue;
      }
      final url = m.cover;
      if (url == null || url.isEmpty || m.genres.isEmpty) continue;
      for (final g in m.genres) {
        if (out.containsKey(g)) continue;
        if (!used.add(url)) break; // this artwork is already spoken for
        out[g] = (url: url, headers: m.coverHeaders);
        break;
      }
    }
  }
  return out;
}

/// The Search filters a genre tile opens with.
///
/// [kAdultGenre] only exists behind `isAdult:false`, so opening it without
/// [MetaFilters.adult] returns an empty grid every time. Every other genre
/// keeps Search's own default, where 18+ stays a toggle the user reaches for
/// rather than something a tap turns on behind their back.
MetaFilters genreFilters(String genre) =>
    MetaFilters(genres: [genre], adult: genre == kAdultGenre);

/// A stable colour for [genre] when there is no cover to show.
///
/// Hashed from the name rather than random, so a genre keeps the same tile
/// between visits and the grid does not reshuffle its palette every build.
/// The adult tile is pinned instead: the hash lands it on hue 323, a hot pink
/// that shouts across the grid — a cool blue lets it sit among the rest
/// rather than advertising itself.
Color genreTint(String genre) {
  if (genre == kAdultGenre) {
    return HSLColor.fromAHSL(1, 212, 0.42, 0.32).toColor();
  }
  var h = 0;
  for (final c in genre.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return HSLColor.fromAHSL(1, (h % 360).toDouble(), 0.42, 0.32).toColor();
}

/// Every genre the current catalogue can filter by, as a way in to Search.
///
/// The genre list is the mode's, not the provider's: [metaGenresFor] already
/// keeps one list for anime/manga/novel and TMDB's own for movie/TV, so this
/// screen never has to know which provider is answering — only that it CAN
/// filter, which Home checks before offering the card at all.
class GenresScreen extends StatefulWidget {
  const GenresScreen({super.key});

  @override
  State<GenresScreen> createState() => _GenresScreenState();
}

class _GenresScreenState extends State<GenresScreen> {
  /// Cover for the adult tile, which cannot come from Home.
  ///
  /// Home never asks for adult titles, so nothing on screen carries that
  /// genre and [genreArtFrom] can never fill it — it was the one permanently
  /// blank tile in the grid. This is the only request the screen makes, it
  /// only runs when the tile is actually shown, and a failure just leaves the
  /// tint behind.
  GenreArt? _adultArt;
  late ZKind _kind;
  late StreamSubscription<ContentMode> _modeSubscription;
  int _artRequest = 0;
  StreamSubscription<HomeState>? _homeSubscription;

  ZKind get _currentKind => browseKindFor(
      sl<ContentModeCubit>().state, ZModePrefs.streamKind);

  /// Const retained pages need their own subscriptions; parent rebuilds alone
  /// do not update an existing catalogue or retire its outstanding artwork.
  void _catalogueChanged() {
    final kind = _currentKind;
    if (!mounted || kind == _kind) return;
    _artRequest++;
    setState(() { _kind = kind; _adultArt = null; });
    if (_adultAllowed) unawaited(_loadAdultArt());
  }

  @override void dispose() {
    _artRequest++;
    unawaited(_modeSubscription.cancel());
    unawaited(_homeSubscription?.cancel());
    ZModePrefs.revision.removeListener(_catalogueChanged);
    super.dispose();
  }

  /// One cover per genre, from rows Home has ALREADY loaded.
  ///
  /// Nothing is registered in some shells and Home may not have loaded yet,
  /// and neither is worth failing over — the tiles fall back to their tint.
  static Map<String, GenreArt> _artByGenre(ZKind kind) {
    if (!sl.isRegistered<HomeCubit>()) return const {};
    return genreArtFrom(sl<HomeCubit>().state.sections ?? const [], kind: kind);
  }

  bool get _adultAllowed =>
      sl.isRegistered<PlaybackPrefs>() &&
      sl<PlaybackPrefs>().adultMetadata &&
      (!sl.isRegistered<ViewerProfileStore>() ||
          sl<ViewerProfileStore>().adultMetadataAllowed);

  @override
  void initState() {
    super.initState();
    _kind = _currentKind;
    _modeSubscription = sl<ContentModeCubit>().stream.listen((_) => _catalogueChanged());
    ZModePrefs.revision.addListener(_catalogueChanged);
    if (sl.isRegistered<HomeCubit>()) {
      // Only new rows affect genre artwork; loading/progress emissions do not.
      final home = sl<HomeCubit>();
      var sections = home.state.sections;
      _homeSubscription = home.stream.listen((state) {
        if (!mounted || identical(sections, state.sections)) return;
        sections = state.sections;
        setState(() {});
      });
    }
    if (_adultAllowed) unawaited(_loadAdultArt());
    unawaited(_refreshGenres());
  }

  /// Top up AniList's genre list when the cache is stale.
  ///
  /// The screen has already drawn from [GenreCatalog] by the time this lands,
  /// so a slow or failed fetch costs nothing — worst case you keep the list
  /// you already had. Only AniList is asked; TMDB's genres are a different
  /// vocabulary with their own ids and stay built in.
  Future<void> _refreshGenres() async {
    if (!GenreCatalog.isStale) return;
    if (!sl.isRegistered<Dio>()) return;
    // Built here rather than pulled from GetIt: the catalogue is a thin
    // wrapper over one function and is not registered, and this is a single
    // token-less query that does not belong in the module's wiring.
    final anilist = AniListCatalogue(AniListCatalogue.dioGql(sl<Dio>()));
    final fetched = await anilist.genreCollection();
    if (fetched.isEmpty) return;
    await GenreCatalog.save(fetched);
    if (mounted) setState(() {});
  }

  Future<void> _loadAdultArt() async {
    final kind = _kind;
    final request = ++_artRequest;
    if (kind == ZKind.movie || kind == ZKind.tv) return; // no such genre there
    if (!sl.isRegistered<MetadataRepository>()) return;
    final repo = sl<MetadataRepository>();
    if (!repo.supportsFilters) return;
    try {
      final res = await repo.searchFiltered(
        '',
        filters: genreFilters(kAdultGenre),
      );
      final withCover = res.where((m) => m.cover?.isNotEmpty ?? false);
      if (withCover.isEmpty || !mounted || request != _artRequest ||
          kind != _kind || !_adultAllowed) return;
      final hit = withCover.first;
      setState(() => _adultArt = (url: hit.cover!, headers: hit.coverHeaders));
    } catch (_) {
      // A blank tile is a fine outcome; the grid must not fail over artwork.
    }
  }

  @override
  Widget build(BuildContext context) {
    final kind = _kind;
    // Settings → Privacy. Read here only to decide whether the adult tile is
    // OFFERED; the repository re-checks the same switch on every request, so
    // this cannot leak results on its own.
    final genres = GenreCatalog.genresFor(kind, adult: _adultAllowed);
    final art = {..._artByGenre(kind), kAdultGenre: ?_adultArt};
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: Text(context.l10n.genres, style: AppText.barTitle),
      ),
      body: GridView.builder(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
        itemCount: genres.length,
        // Genres stay short, readable tiles instead of two enormous banners.
        gridDelegate: defaultTargetPlatform == TargetPlatform.windows
            ? const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 300,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 2.9,
              )
            : const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 2.9,
              ),
        itemBuilder: (_, i) {
          final g = genres[i];
          return _GenreTile(genre: g, kind: kind, art: art[g]);
        },
      ),
    );
  }
}

class _GenreTile extends StatelessWidget {
  const _GenreTile({required this.genre, required this.kind, this.art});

  final String genre;
  final ZKind kind;
  final GenreArt? art;

  /// Open Search on this genre.
  ///
  /// Home only shows the Genres card when the catalogue can filter, but the
  /// provider can be switched in Settings while this screen is open — so the
  /// same guard the detail page's genre chips use is repeated here rather than
  /// trusting the state Home saw. MAL answers a `genres` parameter with the
  /// same unfiltered list and Simkl ignores its own `genre`, so without this
  /// the tap would look like it worked and quietly show the wrong titles.
  void _open(BuildContext context) {
    if (!sl<MetadataRepository>().supportsFilters) {
      final needed = (kind == ZKind.movie || kind == ZKind.tv)
          ? 'TMDB'
          : 'AniList';
      showAppToast(context, context.l10n.filtersNeedProvider(needed));
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SearchScreen(initialFilters: genreFilters(genre)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final a = art;
    return ClipRRect(
      key: ValueKey('genre_$genre'),
      borderRadius: BorderRadius.circular(14),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (a != null)
            CachedNetworkImage(
              imageUrl: a.url,
              httpHeaders: a.headers,
              fit: BoxFit.cover,
              // Tile is ~500px wide: decode at display size, not full source.
              memCacheWidth: 540,
              // Neutral while loading, coloured only if it never arrives.
              // Showing the tint here meant a tile that HAS artwork flashed a
              // colour and then swapped, which reads as a glitch — grey says
              // "loading", the tint says "this is all you're getting".
              placeholder: (_, _) => ColoredBox(color: AppColors.surface2),
              errorWidget: (_, _, _) => ColoredBox(color: genreTint(genre)),
            )
          else
            ColoredBox(color: genreTint(genre)),
          // Centred text needs the middle darkened, not one edge: a
          // left-weighted scrim left the label sitting on whatever the poster
          // happened to have there. Darkest in the centre, lifting at the
          // corners so the artwork still reads as artwork.
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                radius: 0.9,
                colors: [
                  Colors.black.withValues(alpha: 0.72),
                  Colors.black.withValues(alpha: 0.46),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Center(
              child: Text(
                genre,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.body.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  letterSpacing: 0.2,
                  shadows: const [Shadow(color: Colors.black, blurRadius: 8)],
                ),
              ),
            ),
          ),
          // Above the artwork so the whole tile is the target, and so the
          // ripple is not clipped away by the image.
          Material(
            color: Colors.transparent,
            child: InkWell(onTap: () => _open(context)),
          ),
        ],
      ),
    );
  }
}
