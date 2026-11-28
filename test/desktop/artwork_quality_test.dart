import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/ui/artwork_quality.dart';

/// Protects desktop image sharpness without rewriting extension-owned URLs.
void main() {
  test('uses original TMDB pixels while preserving query parameters', () {
    expect(
      desktopArtworkUrl('https://image.tmdb.org/t/p/w780/banner.jpg?x=1'),
      'https://image.tmdb.org/t/p/original/banner.jpg?x=1',
    );
    expect(
      desktopArtworkUrl('https://image.tmdb.org/t/p/h632/a.jpg'),
      'https://image.tmdb.org/t/p/original/a.jpg',
    );
  });

  test('does not rewrite signed extension images or lookalike domains', () {
    for (final url in [
      'https://source.example/t/p/w780/a.jpg?signature=abc',
      'https://image.tmdb.org.example/t/p/w780/a.jpg',
      'https://image.tmdb.org/t/p/original/a.jpg',
    ]) {
      expect(desktopArtworkUrl(url), url);
    }
  });

  test('decode width follows painted size and display scale with a cap', () {
    expect(artworkDecodeWidth(600, 2), 1320);
    expect(artworkDecodeWidth(4000, 2), 3840);
    expect(artworkDecodeWidth(600, 2, maximum: 1024), 1024);
    expect(artworkDecodeWidth(1, 1), 64);
  });
  sizedArtworkTests();
}

/// Windows sizing: the CDN size follows the real screen pixels, so cards stay
/// sharp on high-DPI monitors without fetching several-megabyte originals.
void sizedArtworkTests() {
  test('TMDB posters pick the smallest size that covers the target', () {
    const poster = 'https://image.tmdb.org/t/p/w342/p.jpg?x=1';
    // Never smaller than the size the URL already had.
    expect(desktopArtworkUrl(poster, targetWidth: 40), poster);
    expect(
      desktopArtworkUrl(poster, targetWidth: 440),
      'https://image.tmdb.org/t/p/w500/p.jpg?x=1',
    );
    expect(
      desktopArtworkUrl(poster, targetWidth: 780),
      'https://image.tmdb.org/t/p/w780/p.jpg?x=1',
    );
    // Posters stop at w780 (the original is several megabytes).
    expect(
      desktopArtworkUrl(poster, targetWidth: 1100),
      'https://image.tmdb.org/t/p/w780/p.jpg?x=1',
    );
    // An original stays the original even on a small card.
    const original = 'https://image.tmdb.org/t/p/original/p.jpg';
    expect(desktopArtworkUrl(original, targetWidth: 300), original);
    // A w780 poster is not brought down to w500.
    const wide = 'https://image.tmdb.org/t/p/w780/p.jpg';
    expect(desktopArtworkUrl(wide, targetWidth: 450), wide);
  });

  test('TMDB backdrops, stills and profiles use their own sizes', () {
    const backdrop = 'https://image.tmdb.org/t/p/w300/b.jpg';
    expect(
      desktopArtworkUrl(backdrop, targetWidth: 700, backdrop: true),
      'https://image.tmdb.org/t/p/w780/b.jpg',
    );
    expect(
      desktopArtworkUrl(backdrop, targetWidth: 1200, backdrop: true),
      'https://image.tmdb.org/t/p/w1280/b.jpg',
    );
    // An original backdrop is kept whatever the card size.
    const originalBackdrop = 'https://image.tmdb.org/t/p/original/b.jpg';
    expect(
      desktopArtworkUrl(originalBackdrop, targetWidth: 700, backdrop: true),
      originalBackdrop,
    );
    expect(
      desktopArtworkUrl(backdrop, targetWidth: 3600, backdrop: true),
      'https://image.tmdb.org/t/p/original/b.jpg',
    );
    // A w300 episode still only goes to original when more is needed.
    const still = 'https://image.tmdb.org/t/p/w300/s.jpg';
    expect(desktopArtworkUrl(still, targetWidth: 280), still);
    expect(
      desktopArtworkUrl(still, targetWidth: 420),
      'https://image.tmdb.org/t/p/original/s.jpg',
    );
    // h632 cast photos never get a poster-only width.
    expect(
      desktopArtworkUrl(
        'https://image.tmdb.org/t/p/h632/c.jpg',
        targetWidth: 300,
      ),
      'https://image.tmdb.org/t/p/original/c.jpg',
    );
    // Landscape cards (continue watching, episode tiles) pass backdrop, so a
    // still or a poster shown wide gets a wide-image size, not the original.
    expect(
      desktopArtworkUrl(still, targetWidth: 600, backdrop: true),
      'https://image.tmdb.org/t/p/w780/s.jpg',
    );
    expect(
      desktopArtworkUrl(
        'https://image.tmdb.org/t/p/w500/p.jpg',
        targetWidth: 900,
        backdrop: true,
      ),
      'https://image.tmdb.org/t/p/w1280/p.jpg',
    );
  });

  test('AniList covers move up to the extra-large file, banners stay', () {
    const cover =
        'https://s4.anilist.co/file/anilistcdn/media/anime/cover/medium/bx1-a.jpg';
    expect(
      desktopArtworkUrl(cover, targetWidth: 484),
      'https://s4.anilist.co/file/anilistcdn/media/anime/cover/large/bx1-a.jpg',
    );
    // Small thumbnails keep the normal file, which is also the preview.
    expect(desktopArtworkUrl(cover, targetWidth: 200), cover);
    expect(
      artworkPreviewUrl(desktopArtworkUrl(cover, targetWidth: 484)),
      cover,
    );
    const banner =
        'https://s4.anilist.co/file/anilistcdn/media/anime/banner/1-a.jpg';
    expect(desktopArtworkUrl(banner, targetWidth: 2000), banner);
    const lookalike =
        'https://anilist.co.example/file/anilistcdn/media/anime/cover/medium/a.jpg';
    expect(desktopArtworkUrl(lookalike, targetWidth: 484), lookalike);
  });

  test('MyAnimeList covers use the large variant only when needed', () {
    // A real cover, checked live on 2026-11-21: 138006.jpg (56 KB) and its
    // large variant 138006l.jpg (177 KB) both answer 200 image/jpeg on
    // cdn.myanimelist.net and api-cdn.myanimelist.net, and 138006l.webp
    // exists too.
    const cover = 'https://cdn.myanimelist.net/images/anime/1015/138006.jpg';
    expect(
      desktopArtworkUrl(cover, targetWidth: 440),
      'https://cdn.myanimelist.net/images/anime/1015/138006l.jpg',
    );
    expect(
      desktopArtworkUrl(
        'https://api-cdn.myanimelist.net/images/anime/1015/138006.jpg',
        targetWidth: 440,
      ),
      'https://api-cdn.myanimelist.net/images/anime/1015/138006l.jpg',
    );
    expect(desktopArtworkUrl(cover, targetWidth: 200), cover);
    for (final url in [
      'https://cdn.myanimelist.net/images/anime/1015/138006l.jpg',
      'https://cdn.myanimelist.net/images/anime/1015/138006t.jpg',
      'https://cdn.myanimelist.net/images/characters/1/2.jpg',
      'https://cdn.myanimelist.net.example/images/anime/1/2.jpg',
    ]) {
      expect(desktopArtworkUrl(url, targetWidth: 440), url);
    }
  });

  test('Windows decode width is the exact screen pixels with a cap', () {
    expect(desktopArtworkDecodeWidth(220, 2), 440);
    expect(desktopArtworkDecodeWidth(220, 1.25), 275);
    expect(desktopArtworkDecodeWidth(4000, 2), 2048);
    expect(desktopArtworkDecodeWidth(1900, 2, maximum: 3840), 3800);
    expect(desktopArtworkDecodeWidth(1, 1), 64);
    // The shared helper used by phone poster cards is unchanged.
    expect(artworkDecodeWidth(600, 2), 1320);
  });
}
