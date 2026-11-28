import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/metadata/tmdb_poster_service.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/ui/artwork_quality.dart';
import 'package:watch_app/core/ui/desktop_media_card.dart';
import 'package:watch_app/core/ui/poster_card.dart';
import 'package:watch_app/core/ui/progressive_artwork.dart';

final _windows = TargetPlatformVariant.only(TargetPlatform.windows);

const _aniList =
    'https://s4.anilist.co/file/anilistcdn/media/anime/cover/medium/b25777.jpg';
const _tmdbW342 = 'https://image.tmdb.org/t/p/w342/s2.jpg';

/// Fails every call, so a test that should make none can tell if it did.
class _NoNetwork implements HttpClientAdapter {
  int calls = 0;
  @override
  Future<ResponseBody> fetch(RequestOptions options, _, _) async {
    calls++;
    throw DioException.connectionError(
      requestOptions: options,
      reason: 'no network in tests',
    );
  }

  @override
  void close({bool force = false}) {}
}

MediaItem _anime({String? cover = _aniList, int malId = 25777}) => MediaItem(
  id: 'mal:$malId',
  title: 'Shingeki no Kyojin Season 2',
  url: 'zm://anime/mal:$malId',
  type: ProviderType.anime,
  sourceId: 'zm',
  malId: malId,
  cover: cover,
);

String _urlOf(ImageProvider image) =>
    ((image as ResizeImage).imageProvider as CachedNetworkImageProvider).url;

void main() {
  late _NoNetwork network;
  late ValueNotifier<bool> offline;

  /// Registers a poster service whose cache already knows [known].
  TmdbPosterService register(Map<String, String> known) {
    network = _NoNetwork();
    offline = ValueNotifier(true);
    final today = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 86400000;
    final service = TmdbPosterService(
      Dio()..httpClientAdapter = network,
      store: MemoryTmdbPosterStore({
        for (final MapEntry(:key, :value) in known.entries)
          key: jsonEncode({'p': value, 'd': today}),
      }),
      offline: offline,
      gap: Duration.zero,
    );
    if (sl.isRegistered<TmdbPosterService>()) {
      sl.unregister<TmdbPosterService>();
    }
    sl.registerSingleton<TmdbPosterService>(service);
    return service;
  }

  setUp(DesktopArtPins.clear);

  tearDown(() {
    DesktopArtPins.clear();
    if (sl.isRegistered<TmdbPosterService>()) {
      sl.unregister<TmdbPosterService>();
    }
  });

  group('the chooser', () {
    testWidgets(
      'a saved TMDB poster replaces the AniList cover',
      variant: _windows,
      (tester) async {
        register({'anime:mal:25777': '/s2.jpg'});
        final art = desktopShapedArtChoice(
          _anime(),
          wide: false,
          chosen: _aniList,
        );
        expect(art.url, _tmdbW342);
        expect(art.fallback, _aniList);
        // Wide cards keep their landscape art.
        expect(
          desktopShapedArt(_anime(), wide: true, chosen: _aniList),
          _aniList,
        );
      },
    );

    testWidgets(
      'nothing known yet keeps the cover and queues a lookup',
      variant: _windows,
      (tester) async {
        final service = register({});
        expect(
          desktopShapedArt(_anime(), wide: false, chosen: _aniList),
          _aniList,
        );
        expect(service.waiting, 1);
        // Offline: nothing went to the network.
        expect(network.calls, 0);
      },
    );

    testWidgets(
      'a TMDB cover only moves to the w342 folder',
      variant: _windows,
      (tester) async {
        final service = register({});
        final movie = MediaItem(
          id: 'tmdb:1',
          title: 'Movie',
          url: 'zm://movie/tmdb:1',
          type: ProviderType.movie,
          sourceId: 'zm',
          tmdbId: 1,
          cover: 'https://image.tmdb.org/t/p/w500/m.jpg',
        );
        final art = desktopShapedArtChoice(
          movie,
          wide: false,
          chosen: movie.cover,
        );
        expect(art.url, 'https://image.tmdb.org/t/p/w342/m.jpg');
        expect(art.fallback, movie.cover);
        expect(service.waiting, 0);
        // Stills and cast photos are not posters.
        expect(
          tmdbPosterAtW342('https://image.tmdb.org/t/p/w300/s.jpg'),
          isNull,
        );
        expect(
          tmdbPosterAtW342('https://image.tmdb.org/t/p/h632/c.jpg'),
          isNull,
        );
      },
    );

    testWidgets('downloaded covers stay', variant: _windows, (tester) async {
      final service = register({'anime:mal:25777': '/s2.jpg'});
      const local = 'file:///C:/Downloads/cover.jpg';
      expect(
        desktopShapedArt(_anime(cover: local), wide: false, chosen: local),
        local,
      );
      expect(service.waiting, 0);
    });

    testWidgets(
      'phone and TV keep their pictures',
      variant: TargetPlatformVariant.only(TargetPlatform.android),
      (tester) async {
        final service = register({'anime:mal:25777': '/s2.jpg'});
        expect(desktopTmdbPoster(_anime(), chosen: _aniList), isNull);
        expect(service.waiting, 0);
      },
    );
  });

  group('sizes', () {
    test('a w342 poster moves up the ladder and stops at w780', () {
      expect(desktopArtworkUrl(_tmdbW342, targetWidth: 290), _tmdbW342);
      expect(
        desktopArtworkUrl(_tmdbW342, targetWidth: 400),
        'https://image.tmdb.org/t/p/w500/s2.jpg',
      );
      expect(
        desktopArtworkUrl(_tmdbW342, targetWidth: 700),
        'https://image.tmdb.org/t/p/w780/s2.jpg',
      );
      expect(
        desktopArtworkUrl(_tmdbW342, targetWidth: 2048),
        'https://image.tmdb.org/t/p/w780/s2.jpg',
      );
    });

    testWidgets('a 290 px card decodes the w342 file', variant: _windows, (
      tester,
    ) async {
      // About 190 logical px at 1.4x: 290 real pixels with the fit margin.
      final art = desktopArtworkFor(
        url: _tmdbW342,
        width: 190,
        devicePixelRatio: 1.4,
      );
      expect(_urlOf(art.preview), _tmdbW342);
    });
  });

  group('fallback', () {
    testWidgets(
      'a failed TMDB file shows the AniList cover',
      variant: _windows,
      (tester) async {
        final art = desktopArtworkFor(
          url: _tmdbW342,
          width: 190,
          devicePixelRatio: 1.4,
          fallbackUrl: _aniList,
        );
        final fallback = art.fallback! as ProgressiveArtwork;
        final target = desktopArtworkDecodeWidth(
          190 * (1 + kArtworkFitWholeTolerance),
          1.4,
        );
        expect(
          _urlOf(fallback.preview),
          desktopArtworkUrl(_aniList, targetWidth: target),
        );
        // The picture drawn (and preloaded) is unchanged by the fallback.
        final plain = desktopArtworkFor(
          url: _tmdbW342,
          width: 190,
          devicePixelRatio: 1.4,
        );
        expect(_urlOf(art.preview), _urlOf(plain.preview));
        expect(art.full, plain.full);
      },
    );

    testWidgets('large cards get the fallback too', variant: _windows, (
      tester,
    ) async {
      final art = desktopArtworkFor(
        url: _tmdbW342,
        width: 900,
        devicePixelRatio: 1,
        fallbackUrl: _aniList,
      );
      final fallback = art.fallback! as ProgressiveArtwork;
      expect(_urlOf(fallback.preview), contains('/cover/large/'));
    });
  });

  group('preload and drawn card', () {
    testWidgets(
      'Home preloads the same picture the card draws',
      variant: _windows,
      (tester) async {
        register({'anime:mal:25777': '/s2.jpg'});
        final item = _anime();
        final preload = desktopPosterArtForItem(item, wide: false);
        expect(preload.url, _tmdbW342);
        expect(preload.headers, isNull);
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox(
                width: 180,
                height: 330,
                child: Builder(
                  builder: (context) =>
                      desktopPosterCardForItem(context, item, cellWidth: 180),
                ),
              ),
            ),
          ),
        );
        final drawn = tester.widget<DesktopMediaArtwork>(
          find.byType(DesktopMediaArtwork),
        );
        expect(drawn.url, preload.url);
        expect(drawn.fallbackUrl, _aniList);
        // The same provider keys, so the preloaded decode is reused.
        final mq = MediaQuery.of(
          tester.element(find.byType(DesktopMediaArtwork)),
        );
        final box = tester.getSize(find.byType(DesktopMediaArtwork));
        final shown = desktopArtworkFor(
          url: drawn.url!,
          width: box.width,
          devicePixelRatio: mq.devicePixelRatio,
        );
        final warmed = desktopArtworkFor(
          url: preload.url!,
          width: box.width,
          devicePixelRatio: mq.devicePixelRatio,
        );
        expect(shown.full ?? shown.preview, warmed.full ?? warmed.preview);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'a lookup finishing after the preload keeps the preloaded picture',
      variant: _windows,
      (tester) async {
        register({});
        final item = _anime();
        // Home preloads the next screen before the lookup has an answer.
        final preload = desktopPosterArtForItem(item, wide: false);
        expect(preload.url, _aniList);
        // The lookup finishes before the card is first built.
        register({'anime:mal:25777': '/s2.jpg'});
        Widget page() => MaterialApp(
          home: Center(
            child: SizedBox(
              width: 180,
              height: 330,
              child: Builder(
                builder: (context) =>
                    desktopPosterCardForItem(context, item, cellWidth: 180),
              ),
            ),
          ),
        );
        await tester.pumpWidget(page());
        DesktopMediaArtwork drawn() => tester.widget<DesktopMediaArtwork>(
          find.byType(DesktopMediaArtwork),
        );
        // The card draws what was preloaded, not a picture never loaded.
        expect(drawn().url, preload.url);
        // A later preload of the card on screen asks for that same picture.
        expect(desktopPosterArtForItem(item, wide: false).url, _aniList);
        // Once the card goes away, its next build takes the TMDB poster.
        await tester.pumpWidget(const SizedBox());
        expect(DesktopArtPins.length, 0);
        await tester.pumpWidget(page());
        expect(drawn().url, _tmdbW342);
        expect(desktopPosterArtForItem(item, wide: false).url, _tmdbW342);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets('PosterCard uses the same chooser', variant: _windows, (
      tester,
    ) async {
      register({'anime:mal:25777': '/s2.jpg'});
      final item = _anime();
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 180,
              height: 330,
              child: PosterCard(
                title: item.title,
                imageUrl: item.cover,
                logoItem: item,
                cellWidth: 180,
              ),
            ),
          ),
        ),
      );
      final drawn = tester.widget<DesktopMediaArtwork>(
        find.byType(DesktopMediaArtwork),
      );
      expect(drawn.url, desktopPosterArtForItem(item, wide: false).url);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('no swap on screen', () {
    Widget card(String url, Object key) => MaterialApp(
      home: Center(
        child: SizedBox(
          width: 180,
          height: 270,
          child: DesktopMediaArtwork(url: url, width: 180, latchKey: key),
        ),
      ),
    );

    String shownUrl(WidgetTester tester) => _urlOf(
      tester
          .widget<ProgressiveArtwork>(find.byType(ProgressiveArtwork).first)
          .preview,
    );

    testWidgets(
      'a lookup finishing keeps the first picture',
      variant: _windows,
      (tester) async {
        await tester.pumpWidget(card(_aniList, 'show|cover'));
        final first = shownUrl(tester);
        expect(first, contains('anilist'));
        // Same card, a TMDB poster now known: the picture stays.
        await tester.pumpWidget(card(_tmdbW342, 'show|cover'));
        expect(shownUrl(tester), first);
        // Another item (new key) takes its own picture.
        await tester.pumpWidget(card(_tmdbW342, 'other|cover'));
        expect(shownUrl(tester), contains('image.tmdb.org'));
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'without a key the picture follows the url',
      variant: _windows,
      (tester) async {
        Widget plain(String url) => MaterialApp(
          home: Center(
            child: SizedBox(
              width: 180,
              height: 270,
              child: DesktopMediaArtwork(url: url, width: 180),
            ),
          ),
        );
        await tester.pumpWidget(plain(_aniList));
        await tester.pumpWidget(plain(_tmdbW342));
        expect(shownUrl(tester), contains('image.tmdb.org'));
        await tester.pumpWidget(const SizedBox());
      },
    );
  });
}
