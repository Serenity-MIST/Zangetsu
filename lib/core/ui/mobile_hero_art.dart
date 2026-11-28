import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

// TMDB image paths look like https://image.tmdb.org/t/p/<size>/<file>.
final RegExp _tmdbSizeSegment = RegExp(r'/t/p/[^/]+/');
const String _tmdbImageBase = 'https://image.tmdb.org/t/p/';

/// Portrait TMDB artwork suits a tall phone hero; keep other catalogues' art.
///
/// On Windows the hero is a short, wide card, so [desktopHeroArt] is used
/// instead: it prefers the landscape banner/backdrop and asks TMDB for a
/// sensible size rather than the multi-MB original.
String? mobileHeroArt(String? cover, String? banner, {String? sourceId}) {
  // Windows desktop: landscape card -> landscape art (show-3). Only the
  // detail hero and its loading skeleton pass [sourceId]; the Home banners
  // call without it and keep their existing art choice on Windows.
  if (defaultTargetPlatform == TargetPlatform.windows && sourceId != null) {
    return desktopHeroArt(cover, banner);
  }
  if (sourceId == 'stremio') {
    if (banner?.trim().isNotEmpty == true) return banner;
    return cover?.trim().isNotEmpty == true ? cover : null;
  }
  if (cover != null && cover.startsWith(_tmdbImageBase)) {
    return cover.replaceFirst(_tmdbSizeSegment, '/t/p/original/');
  }
  return banner ?? cover;
}

/// Hero art for the wide Windows header card: the banner/backdrop first, the
/// poster only as a fallback. TMDB images are requested at a size that fits a
/// desktop card (w1280 for backdrops, w780 for a fallback poster) instead of
/// `/original/`, which is often several MB.
String? desktopHeroArt(String? cover, String? banner) {
  final wide = banner?.trim();
  if (wide != null && wide.isNotEmpty) return _tmdbSized(wide, 'w1280');
  final tall = cover?.trim();
  if (tall != null && tall.isNotEmpty) return _tmdbSized(tall, 'w780');
  return null;
}

/// Rewrites a TMDB image URL to the given size; other hosts pass through.
String _tmdbSized(String url, String size) {
  if (!url.startsWith(_tmdbImageBase)) return url;
  return url.replaceFirst(_tmdbSizeSegment, '/t/p/$size/');
}

/// Detail backgrounds sample the poster first, falling back to the backdrop.
String? adaptiveArtUrl(String? poster, String? backdrop) {
  if (poster != null && poster.trim().isNotEmpty) return poster;
  return backdrop != null && backdrop.trim().isNotEmpty ? backdrop : null;
}

/// Wide Stremio backdrops need their detail preserved before a tall hero crops them.
int mobileHeroDecodeWidth(String sourceId, int screenWidth) =>
    sourceId == 'stremio' && screenWidth < 1920 ? 1920 : screenWidth;

/// The hero's artwork, on Home and in Detail: the plain wide backdrop when there
/// is one, so the title is not printed into the picture (the logo or name is
/// drawn on top), and the poster only when there is no backdrop.
///
/// A TMDB backdrop comes as w780 in the catalogues, far too small for a tall
/// card, so it is asked for at full size, as the poster fallback already is.
String? homeHeroArt(String? cover, String? banner) {
  if (banner == null || banner.trim().isEmpty) {
    return mobileHeroArt(cover, null);
  }
  return banner.startsWith('https://image.tmdb.org/t/p/')
      ? banner.replaceFirst(RegExp(r'/t/p/[^/]+/'), '/t/p/original/')
      : banner;
}

/// The widest a hero picture is decoded. A wide backdrop needs about 2400 px to
/// fill a tall card without being stretched, so it is decoded at that size on
/// every phone rather than at a smaller size and then enlarged.
const int heroDecodeMaxWidth = 2400;

/// Hero art decoded to fit a tall card: a wide backdrop keeps enough pixels to
/// fill the card, a tall poster is not blown up to the same width. The fit is
/// bounded in both directions, so neither can cost more than about 13 MB.
ImageProvider heroImage(
  ImageProvider provider, {
  required int screenWidth,
  required int cardHeight,
}) => ResizeImage(
  provider,
  width: screenWidth < heroDecodeMaxWidth ? heroDecodeMaxWidth : screenWidth,
  height: cardHeight,
  policy: ResizeImagePolicy.fit,
);

/// The card's height in pixels, with a little room to crop into.
int heroCardDecodeHeight(double screenHeightDp, double pixelRatio) =>
    ((screenHeightDp * 0.62).clamp(380.0, 560.0) * pixelRatio * 1.15).round();
