// show-3: the wide Windows detail card prefers landscape art at a sane size.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/ui/mobile_hero_art.dart';

const _poster = 'https://image.tmdb.org/t/p/w500/poster.jpg';
const _backdrop = 'https://image.tmdb.org/t/p/original/backdrop.jpg';

void main() {
  test('backdrop first, resized to w1280; poster only as fallback', () {
    expect(
      desktopHeroArt(_poster, _backdrop),
      'https://image.tmdb.org/t/p/w1280/backdrop.jpg',
    );
    expect(
      desktopHeroArt(_poster, '  '),
      'https://image.tmdb.org/t/p/w780/poster.jpg',
    );
    expect(desktopHeroArt(null, null), isNull);
    // Non-TMDB art passes through untouched.
    expect(
      desktopHeroArt('https://anime/cover.jpg', 'https://anime/banner.jpg'),
      'https://anime/banner.jpg',
    );
  });

  test('mobileHeroArt uses the desktop rule only on Windows', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      expect(
        mobileHeroArt(_poster, _backdrop, sourceId: 'tmdb'),
        'https://image.tmdb.org/t/p/w1280/backdrop.jpg',
      );
      // Home banners (no sourceId) keep their existing art on Windows.
      expect(
        mobileHeroArt(_poster, _backdrop),
        'https://image.tmdb.org/t/p/original/poster.jpg',
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
    // Phones keep the original-size portrait art.
    expect(
      mobileHeroArt(_poster, _backdrop),
      'https://image.tmdb.org/t/p/original/poster.jpg',
    );
  });
}
