import 'package:flutter/foundation.dart';

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

// Rewrites a TMDB image URL to the given size; other hosts pass through.
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
