/// Picks a sharper artwork URL for a Windows desktop surface.
///
/// Only known artwork CDNs are rewritten (TMDB, AniList, MyAnimeList, Kitsu,
/// Simkl, Stremio's Cinemeta images on metahub and MangaDex), and only to
/// sizes that were checked to exist on that CDN; arbitrary extension URLs,
/// signed query strings and source-specific filenames stay intact. A size
/// that fails to load still leaves the first (preview) picture on screen.
///
/// [targetWidth] is the number of real screen pixels the image is drawn at
/// (logical width x display scale). When it is given the smallest CDN size
/// that still covers it is chosen, so a card on a 4K screen gets enough pixels
/// to stay sharp but a small thumbnail does not download and decode a
/// several-megabyte original. A TMDB size is never swapped for a smaller one
/// than the URL already had. Without it TMDB keeps the old behaviour and
/// returns the original file.
///
/// [backdrop] says the image is a wide TMDB backdrop or banner rather than a
/// poster; TMDB offers different sizes for the two.
String desktopArtworkUrl(
  String url, {
  int? targetWidth,
  bool backdrop = false,
}) {
  final uri = Uri.tryParse(url);
  if (uri == null) return url;
  if (uri.host == 'image.tmdb.org' && uri.path.startsWith('/t/p/')) {
    return _tmdbUrl(uri, targetWidth, backdrop) ?? url;
  }
  if (uri.host.endsWith('.anilist.co') &&
      uri.path.startsWith('/file/anilistcdn/')) {
    return _aniListUrl(uri, targetWidth) ?? url;
  }
  if ((uri.host == 'cdn.myanimelist.net' ||
      uri.host == 'api-cdn.myanimelist.net')) {
    return _malUrl(uri, targetWidth) ?? url;
  }
  if (uri.host == 'media.kitsu.app') {
    return _kitsuUrl(uri, targetWidth) ?? url;
  }
  if (uri.host == 'simkl.in') {
    return _simklUrl(uri, targetWidth) ?? url;
  }
  if (uri.host == 'images.metahub.space') {
    return _metahubUrl(uri, targetWidth) ?? url;
  }
  if (uri.host == 'uploads.mangadex.org') {
    return _mangaDexUrl(uri, targetWidth) ?? url;
  }
  return url;
}

/// Picks the first size in [ladder] (name and pixel width, smallest first)
/// that covers [targetWidth], or the largest one when nothing does or no
/// target is known.
String _pickSize(List<(String, int)> ladder, int? targetWidth) {
  if (targetWidth != null) {
    for (final (name, width) in ladder) {
      if (width >= targetWidth) return name;
    }
  }
  return ladder.last.$1;
}

/// Index of [name] in [ladder], or -1 when it is not one of its sizes.
int _ladderIndex(List<(String, int)> ladder, String name) =>
    ladder.indexWhere((size) => size.$1 == name);

/// Kitsu poster sizes and their widths, measured on a real poster
/// (media.kitsu.app/anime/poster_images/1/...): tiny 110, small 284,
/// medium 390, large 550. "original" is left alone because it can be smaller
/// than "large" (484 px on the same poster).
const _kitsuPosterSizes = [
  ('tiny', 110),
  ('small', 284),
  ('medium', 390),
  ('large', 550),
];

/// Kitsu: posters (anime or manga poster_images) move up the poster ladder,
/// never down. Cover images (the wide banner) only come as cropped strips in
/// tiny/small/large (840x200, 1680x400, 3360x800), while "original" is the
/// whole picture (1400x875 on the same title), so tiny and small covers move
/// to the original. Returns null when nothing should change.
String? _kitsuUrl(Uri uri, int? targetWidth) {
  final match = RegExp(
    r'^/(anime|manga)/(poster_images|cover_images)/(\d+)/(\w+)\.(jpg|png|jpeg|webp)$',
  ).firstMatch(uri.path);
  if (match == null) return null;
  final kind = match.group(2)!, current = match.group(4)!;
  String wanted;
  if (kind == 'cover_images') {
    if (current != 'tiny' && current != 'small') return null;
    wanted = 'original';
  } else {
    final at = _ladderIndex(_kitsuPosterSizes, current);
    if (at < 0) return null;
    wanted = _pickSize(_kitsuPosterSizes, targetWidth);
    // Only ever sharper than what the source gave.
    if (_ladderIndex(_kitsuPosterSizes, wanted) <= at) return null;
  }
  final path =
      '/${match.group(1)}/$kind/${match.group(3)}/$wanted.${match.group(5)}';
  return uri.replace(path: path).toString();
}

/// Simkl poster sizes and widths, measured on real posters: _c 170, _m 340
/// and _0 680 (the full poster; simkl.in answers it with a redirect to its
/// own simkl.net host, which image loading follows). "_w" is left out: it is
/// a 600x338 wide crop, not a poster.
const _simklPosterSizes = [('c', 170), ('m', 340), ('0', 680)];

/// Simkl: posters (/posters/<path>_<size>.jpg) move up to the size that
/// covers the target; fanart (/fanart/<path>_<size>.jpg) in the smaller
/// "_w" (600 px) or "_mobile" (960 px) variants moves to "_medium", which is
/// the full 1920x1080 picture. Returns null when nothing should change.
String? _simklUrl(Uri uri, int? targetWidth) {
  final poster = RegExp(
    r'^(/posters/\w+/\w+)_(c|m)\.(jpg|webp)$',
  ).firstMatch(uri.path);
  if (poster != null) {
    final at = _ladderIndex(_simklPosterSizes, poster.group(2)!);
    final wanted = _pickSize(_simklPosterSizes, targetWidth);
    if (_ladderIndex(_simklPosterSizes, wanted) <= at) return null;
    return uri
        .replace(path: '${poster.group(1)}_$wanted.${poster.group(3)}')
        .toString();
  }
  final fanart = RegExp(
    r'^(/fanart/\w+/\w+)_(w|mobile)\.(jpg|webp)$',
  ).firstMatch(uri.path);
  if (fanart == null) return null;
  if (targetWidth != null && targetWidth <= 600 && fanart.group(2) == 'w') {
    return null;
  }
  return uri
      .replace(path: '${fanart.group(1)}_medium.${fanart.group(3)}')
      .toString();
}

/// Stremio's Cinemeta artwork host. Widths measured on a real title
/// (tt0944947): posters small 300, medium 500, large 780; backgrounds small
/// 480 and medium 1920 ("large" is the same file as medium). Logos are left
/// alone.
const _metahubPosterSizes = [('small', 300), ('medium', 500), ('large', 780)];
const _metahubBackgroundSizes = [('small', 480), ('medium', 1920)];

/// Metahub: /poster/<size>/<imdb id>/img and /background/<size>/<imdb id>/img
/// move up to the size that covers the target, never down. Returns null when
/// nothing should change.
String? _metahubUrl(Uri uri, int? targetWidth) {
  final match = RegExp(
    r'^/(poster|background)/(small|medium|large)/(tt\d+)/img$',
  ).firstMatch(uri.path);
  if (match == null) return null;
  final ladder = match.group(1) == 'poster'
      ? _metahubPosterSizes
      : _metahubBackgroundSizes;
  final at = _ladderIndex(ladder, match.group(2)!);
  if (at < 0) return null;
  final wanted = _pickSize(ladder, targetWidth);
  if (_ladderIndex(ladder, wanted) <= at) return null;
  return uri
      .replace(path: '/${match.group(1)}/$wanted/${match.group(3)}/img')
      .toString();
}

/// MangaDex covers come as /covers/<manga id>/<file> (the full upload, about
/// 2000 px wide) with .256.jpg and .512.jpg thumbnails added after the file
/// name. A thumbnail moves to the 512 one or to the full file, whichever
/// covers the target. Returns null when nothing should change.
String? _mangaDexUrl(Uri uri, int? targetWidth) {
  final match = RegExp(
    r'^(/covers/[0-9a-f-]+/[0-9a-f-]+\.(?:jpg|jpeg|png|gif|webp))\.(256|512)\.jpg$',
  ).firstMatch(uri.path);
  if (match == null) return null;
  final full = match.group(1)!;
  if (targetWidth != null && targetWidth <= 512) {
    if (match.group(2) == '512') return null;
    return uri.replace(path: '$full.512.jpg').toString();
  }
  return uri.replace(path: full).toString();
}

/// TMDB widths that exist for each kind of image, smallest first. Anything
/// wider than the last entry uses the original file, except posters: w780
/// is already sharp on the largest poster card, while the original is a
/// several-megabyte file, so posters stop at w780.
const _tmdbPosterWidths = [185, 342, 500, 780];
const _tmdbBackdropWidths = [185, 780, 1280];
const _tmdbStillWidths = [185, 300];
const _tmdbProfileWidths = [185];

/// Swaps TMDB's size folder (w185, w780, h632, original...) for the one that
/// fits [targetWidth]. Returns null when nothing should change.
String? _tmdbUrl(Uri uri, int? targetWidth, bool backdrop) {
  final size = RegExp(r'^/t/p/(original|w\d+|h\d+)/').firstMatch(uri.path);
  if (size == null) return null;
  String wanted;
  if (targetWidth == null) {
    wanted = 'original';
  } else {
    // The size already in the URL tells what kind of image it is when the
    // caller did not: h632 is a cast photo and w300 an episode still.
    final current = size.group(1)!;
    final ladder = backdrop
        ? _tmdbBackdropWidths
        : current.startsWith('h')
        ? _tmdbProfileWidths
        : current == 'w300'
        ? _tmdbStillWidths
        : _tmdbPosterWidths;
    wanted = identical(ladder, _tmdbPosterWidths) ? 'w780' : 'original';
    for (final w in ladder) {
      if (w >= targetWidth) {
        wanted = 'w$w';
        break;
      }
    }
  }
  // Only ever move up: a URL that already has the original, or a size at
  // least as wide as the one picked, is kept as the source gave it.
  if (!_tmdbIsLarger(wanted, size.group(1)!)) return null;
  final path = uri.path.replaceFirst(size.group(0)!, '/t/p/$wanted/');
  return path == uri.path ? null : uri.replace(path: path).toString();
}

/// Whether TMDB size [wanted] is wider than [current]. "original" is the
/// widest; an h size (a height) is read as a 2:3 portrait, so h632 counts
/// as about 421 px wide.
bool _tmdbIsLarger(String wanted, String current) {
  int width(String size) {
    if (size == 'original') return 1 << 30;
    final n = int.tryParse(size.substring(1)) ?? 0;
    return size.startsWith('h') ? n * 2 ~/ 3 : n;
  }

  return width(wanted) > width(current);
}

/// AniList serves covers from /cover/small/ (about 100 px wide), /medium/
/// (about 230 px, the API's "large") and /large/ (about 460 px, the API's
/// "extraLarge"). Covers are moved up to the size that fits. Banners come in
/// one size only and are left alone. Character pictures come as /medium/ and
/// /large/ (both answer on the CDN); medium is only a list thumbnail, so it
/// always moves to large. Returns null when nothing should change.
String? _aniListUrl(Uri uri, int? targetWidth) {
  final character = RegExp(
    r'^/file/anilistcdn/character/medium/',
  ).firstMatch(uri.path);
  if (character != null) {
    // Medium is the small list thumbnail, so any card gets the large one.
    return uri
        .replace(
          path: uri.path.replaceFirst(
            '/character/medium/',
            '/character/large/',
          ),
        )
        .toString();
  }
  final size = RegExp(r'/cover/(small|medium)/').firstMatch(uri.path);
  if (size == null) return null;
  final wanted = targetWidth != null && targetWidth <= 100
      ? size.group(1)!
      : targetWidth != null && targetWidth <= 230
      ? 'medium'
      : 'large';
  final path = uri.path.replaceFirst(size.group(0)!, '/cover/$wanted/');
  return path == uri.path ? null : uri.replace(path: path).toString();
}

/// MyAnimeList's normal cover (about 225 px wide) has a large variant (about
/// 425 px) with an "l" before the extension, for example 12345.jpg becomes
/// 12345l.jpg. Only plain anime/manga cover paths are changed, never ones
/// that already carry a size letter.
///
/// MyAnimeList also hands out shrunken copies through its resize path, for
/// example /r/50x70/images/anime/1015/138006.jpg?s=<signature> (50x70
/// pixels). When the box is wider than that copy, the resize part and its
/// signature are dropped so the normal (or large) cover is used instead; the
/// signature only belongs to the resize. Returns null when nothing should
/// change.
String? _malUrl(Uri uri, int? targetWidth) {
  final resized = RegExp(r'^/r/(\d+)x\d+(/images/.*)$').firstMatch(uri.path);
  if (resized != null &&
      targetWidth != null &&
      targetWidth <= int.parse(resized.group(1)!)) {
    return null;
  }
  final path = resized?.group(2) ?? uri.path;
  final cover = RegExp(
    r'^(/images/(?:anime|manga)/\d+/\d+)\.(jpg|webp)$',
  ).firstMatch(path);
  if (cover == null) return null;
  final large = targetWidth == null || targetWidth > 225;
  if (!large && resized == null) return null;
  final newPath = large ? '${cover.group(1)}l.${cover.group(2)}' : path;
  if (resized == null) return uri.replace(path: newPath).toString();
  // The resize signature goes; any other query parameter stays.
  final query = {...uri.queryParameters}..remove('s');
  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    path: newPath,
    queryParameters: query.isEmpty ? null : query,
  ).toString();
}

/// Decodes for the actual painted width and display scale, with a small margin
/// for hover scaling. The cap bounds memory on ultrawide/high-DPI monitors.
int artworkDecodeWidth(
  double width,
  double devicePixelRatio, {
  int maximum = 3840,
}) => (width * devicePixelRatio * 1.1).ceil().clamp(64, maximum);

/// Windows desktop decode width: exactly the real screen pixels the image is
/// drawn at (logical width x display scale), with no extra margin because
/// Windows cards do not grow on hover. Cards cap at 2048 pixels; the Home
/// banner passes a higher cap so a full-width 4K banner stays sharp.
int desktopArtworkDecodeWidth(
  double width,
  double devicePixelRatio, {
  int maximum = 2048,
}) => (width * devicePixelRatio).ceil().clamp(64, maximum);

/// Small first-paint variants on known artwork CDNs only. Never rewrite a
/// signed extension URL or invent a thumbnail path for an unknown image host.
String artworkPreviewUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return url;
  if (uri.host == 'image.tmdb.org' && uri.path.startsWith('/t/p/')) {
    return uri
        .replace(
          path: uri.path.replaceFirst(
            RegExp(r'^/t/p/(?:original|w\d+|h\d+)/'),
            '/t/p/w185/',
          ),
        )
        .toString();
  }
  if (uri.host.endsWith('.anilist.co') &&
      uri.path.startsWith('/file/anilistcdn/media/')) {
    return uri
        .replace(
          path: uri.path.replaceFirst(
            RegExp(r'/cover/(?:extraLarge|large)/'),
            '/cover/medium/',
          ),
        )
        .toString();
  }
  return url;
}
