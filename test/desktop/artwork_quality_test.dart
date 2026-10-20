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
}
