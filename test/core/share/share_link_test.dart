import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/share/share_link.dart';

void main() {
  group('ShareLink.watchUrl', () {
    test('builds the https open link for the Discord button', () {
      final url = ShareLink.watchUrl(
        sourceId: 'cs:hiAnime',
        url: 'https://hianime.to/watch/one-piece-100',
        title: 'One Piece',
        type: ProviderType.anime,
      );
      expect(url, startsWith('https://zangetsu.online/open/'));
      expect(url, contains('s=cs%3AhiAnime'));
      expect(url, contains('One+Piece'));
    });

    test('Windows: a file path on this PC never goes into the link', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        for (final local in [
          'file:///C:/Users/Someone/Downloads/poster.png',
          r'C:\Users\Someone\poster.png',
          r'\\nas\share\poster.png',
        ]) {
          final link = ShareLink.watchUrl(
            sourceId: 'zm',
            url: 'zm://anime/mal:1',
            title: 'X',
            type: ProviderType.anime,
            cover: local,
          );
          expect(Uri.parse(link!).queryParameters.containsKey('c'), isFalse);
          // A show that is only a folder on this PC has no link at all.
          expect(
            ShareLink.watchUrl(
              sourceId: 'zm',
              url: local,
              title: 'X',
              type: ProviderType.anime,
            ),
            isNull,
          );
        }
        // Web covers are still carried.
        final web = ShareLink.watchUrl(
          sourceId: 'zm',
          url: 'zm://anime/mal:1',
          title: 'X',
          type: ProviderType.anime,
          cover: 'https://example.test/p.jpg',
        );
        expect(
          Uri.parse(web!).queryParameters['c'],
          'https://example.test/p.jpg',
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    test('null when the title identity is incomplete', () {
      expect(
        ShareLink.watchUrl(
          sourceId: '',
          url: 'https://hianime.to/watch/x',
          title: 'X',
          type: ProviderType.anime,
        ),
        isNull,
      );
      expect(
        ShareLink.watchUrl(
          sourceId: 'cs:hiAnime',
          url: null,
          title: 'X',
          type: ProviderType.anime,
        ),
        isNull,
      );
      expect(
        ShareLink.watchUrl(
          sourceId: 'cs:hiAnime',
          url: '',
          title: 'X',
          type: ProviderType.anime,
        ),
        isNull,
      );
    });
  });
}
