import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/playback/subtitle_search_service.dart';

void main() {
  group('SubtitleSearchService.buildSearchParams', () {
    test('a series episode with ids is searched by parent id, season and episode', () {
      final params = SubtitleSearchService.buildSearchParams(
        'Frieren',
        imdbId: 'tt22248376',
        tmdbId: 209867,
        isTv: true,
        season: 2,
        episode: 5,
      );
      expect(params['parent_imdb_id'], 'tt22248376');
      expect(params['parent_tmdb_id'], 209867);
      expect(params['season_number'], 2);
      expect(params['episode_number'], 5);
      // Whole-show ids would match arbitrary episodes.
      expect(params.containsKey('imdb_id'), isFalse);
      expect(params.containsKey('tmdb_id'), isFalse);
      // A localised or alternate title would only exclude correct results.
      expect(params.containsKey('query'), isFalse);
      expect(params['languages'], 'en');
    });

    test('a movie keeps its own id and the title', () {
      final params = SubtitleSearchService.buildSearchParams(
        'Spirited Away',
        imdbId: 'tt0245429',
        tmdbId: 129,
        language: 'fr',
      );
      expect(params['imdb_id'], 'tt0245429');
      expect(params['tmdb_id'], 129);
      expect(params['query'], 'Spirited Away');
      expect(params['languages'], 'fr');
      expect(params.containsKey('season_number'), isFalse);
    });

    test('a series without any id falls back to the title only', () {
      final params = SubtitleSearchService.buildSearchParams(
        'Frieren',
        isTv: true,
        season: 1,
        episode: 3,
      );
      expect(params['query'], 'Frieren');
      expect(params.containsKey('season_number'), isFalse);
      expect(params.containsKey('parent_imdb_id'), isFalse);
    });

    test('a series with ids but no exact episode does not pretend to be one', () {
      final params = SubtitleSearchService.buildSearchParams(
        'Frieren',
        imdbId: 'tt22248376',
        isTv: true,
        season: 1,
      );
      expect(params['imdb_id'], 'tt22248376');
      expect(params['query'], 'Frieren');
      expect(params.containsKey('episode_number'), isFalse);
    });

    test('blank values are not sent and the language can be left open', () {
      final params = SubtitleSearchService.buildSearchParams(
        '  Frieren  ',
        imdbId: '   ',
        language: '',
      );
      expect(params, {'query': 'Frieren'});
    });
  });
}
