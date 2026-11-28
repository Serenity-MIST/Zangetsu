import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/desktop_row_scroller.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/ui/artwork_quality.dart';
import 'package:watch_app/core/ui/desktop_media_card.dart';
import 'package:watch_app/core/ui/poster_card.dart';
import 'package:watch_app/core/ui/progressive_artwork.dart';
import 'package:watch_app/features/home/desktop_home_page.dart';

final _windows = TargetPlatformVariant.only(TargetPlatform.windows);

/// An image whose decode the test finishes by hand, with no network.
class _ControlledImage extends ImageProvider<_ControlledImage> {
  final completion = Completer<ImageInfo>();
  @override
  Future<_ControlledImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);
  @override
  ImageStreamCompleter loadImage(
    _ControlledImage key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(completion.future);
}

MediaItem _item({
  String id = 'show',
  String title = 'The Odyssey',
  String sourceId = 'catalogue',
  String? cover,
  String? banner,
  String? landscape,
  int? malId,
}) => MediaItem(
  id: id,
  title: title,
  url: 'fixture://$id',
  sourceId: sourceId,
  type: ProviderType.anime,
  cover: cover,
  banner: banner,
  landscapePoster: landscape,
  malId: malId,
);

DesktopHomeResume _resume({
  String? still,
  String? image = 'https://cdn.example/poster.jpg',
  String? sourceId = 'player-source',
  String? showId = 'played-id',
  int? malId,
  String title = 'The Odyssey',
}) => DesktopHomeResume(
  title: title,
  subtitle: 'Episode 1',
  progress: .3,
  open: () {},
  image: image,
  headers: const {'Referer': 'https://source.example'},
  still: still,
  sourceId: sourceId,
  showId: showId,
  malId: malId,
);

void main() {
  group('item 11: sharper artwork URLs per host', () {
    test('Kitsu posters move up the poster sizes, covers to original', () {
      const poster = 'https://media.kitsu.app/anime/poster_images/1/small.jpg';
      expect(
        desktopArtworkUrl(poster, targetWidth: 500),
        'https://media.kitsu.app/anime/poster_images/1/large.jpg',
      );
      expect(
        desktopArtworkUrl(poster, targetWidth: 350),
        'https://media.kitsu.app/anime/poster_images/1/medium.jpg',
      );
      // Never smaller than what the source gave.
      expect(desktopArtworkUrl(poster, targetWidth: 100), poster);
      expect(
        desktopArtworkUrl(
          'https://media.kitsu.app/anime/cover_images/7/small.jpg',
          targetWidth: 800,
        ),
        'https://media.kitsu.app/anime/cover_images/7/original.jpg',
      );
      // Unknown size names are left alone.
      const odd = 'https://media.kitsu.app/anime/poster_images/1/odd.jpg';
      expect(desktopArtworkUrl(odd, targetWidth: 500), odd);
    });

    test('Simkl posters move up, small fanart moves to the full one', () {
      expect(
        desktopArtworkUrl(
          'https://simkl.in/posters/12/123456_m.jpg',
          targetWidth: 600,
        ),
        'https://simkl.in/posters/12/123456_0.jpg',
      );
      expect(
        desktopArtworkUrl(
          'https://simkl.in/posters/12/123456_c.jpg',
          targetWidth: 300,
        ),
        'https://simkl.in/posters/12/123456_m.jpg',
      );
      expect(
        desktopArtworkUrl(
          'https://simkl.in/fanart/12/123456_w.jpg',
          targetWidth: 1200,
        ),
        'https://simkl.in/fanart/12/123456_medium.jpg',
      );
      const small = 'https://simkl.in/fanart/12/123456_w.jpg';
      expect(desktopArtworkUrl(small, targetWidth: 500), small);
    });

    test('Cinemeta images on metahub move up to the size that covers', () {
      expect(
        desktopArtworkUrl(
          'https://images.metahub.space/poster/small/tt0944947/img',
          targetWidth: 700,
        ),
        'https://images.metahub.space/poster/large/tt0944947/img',
      );
      expect(
        desktopArtworkUrl(
          'https://images.metahub.space/background/small/tt0944947/img',
          targetWidth: 900,
        ),
        'https://images.metahub.space/background/medium/tt0944947/img',
      );
      const logo = 'https://images.metahub.space/logo/medium/tt0944947/img';
      expect(desktopArtworkUrl(logo, targetWidth: 900), logo);
    });

    test('MangaDex thumbnails move to the 512 copy or the full file', () {
      const base =
          'https://uploads.mangadex.org/covers/'
          '0a1b2c3d-1111-2222-3333-444455556666/'
          'aaaabbbb-cccc-dddd-eeee-ffff00001111.jpg';
      expect(
        desktopArtworkUrl('$base.256.jpg', targetWidth: 400),
        '$base.512.jpg',
      );
      expect(desktopArtworkUrl('$base.256.jpg', targetWidth: 900), base);
      expect(
        desktopArtworkUrl('$base.512.jpg', targetWidth: 400),
        '$base.512.jpg',
      );
    });

    test('AniList covers and character pictures use the larger files', () {
      expect(
        desktopArtworkUrl(
          'https://s4.anilist.co/file/anilistcdn/media/anime/cover/medium/bx1.jpg',
          targetWidth: 400,
        ),
        'https://s4.anilist.co/file/anilistcdn/media/anime/cover/large/bx1.jpg',
      );
      expect(
        desktopArtworkUrl(
          'https://s4.anilist.co/file/anilistcdn/character/medium/b1.png',
          targetWidth: 200,
        ),
        'https://s4.anilist.co/file/anilistcdn/character/large/b1.png',
      );
      const banner =
          'https://s4.anilist.co/file/anilistcdn/media/anime/banner/1.jpg';
      expect(desktopArtworkUrl(banner, targetWidth: 1920), banner);
    });

    test('MyAnimeList resize copies drop to the plain or large cover', () {
      expect(
        desktopArtworkUrl(
          'https://cdn.myanimelist.net/r/50x70/images/anime/1015/138006.jpg?s=abc',
          targetWidth: 400,
        ),
        'https://cdn.myanimelist.net/images/anime/1015/138006l.jpg',
      );
    });

    test('unknown hosts and lookalikes are never rewritten', () {
      for (final url in [
        'https://cdn.example/poster/small/tt1/img',
        'https://images.metahub.space.evil.example/poster/small/tt1/img',
        'https://media.kitsu.app.example/anime/poster_images/1/small.jpg',
      ]) {
        expect(desktopArtworkUrl(url, targetWidth: 900), url);
      }
    });

    test('decode width is never smaller than the real screen pixels', () {
      expect(desktopArtworkDecodeWidth(200, 1.5), 300);
      expect(desktopArtworkDecodeWidth(201.2, 2), 403);
    });
  });

  group('item 1: the picture shape follows the card shape', () {
    test('wide cards take the landscape poster, then the banner', () {
      final both = _item(cover: 'p.jpg', banner: 'b.jpg', landscape: 'l.jpg');
      expect(desktopShapedArt(both, wide: true, chosen: 'p.jpg'), 'l.jpg');
      final banner = _item(cover: 'p.jpg', banner: 'b.jpg');
      expect(desktopShapedArt(banner, wide: true, chosen: 'p.jpg'), 'b.jpg');
      // Only a poster: it stays (shown whole over the soft fill).
      final poster = _item(cover: 'p.jpg');
      expect(desktopShapedArt(poster, wide: true, chosen: 'p.jpg'), 'p.jpg');
    });

    test('poster cards keep the poster; landscape only when none exists', () {
      final both = _item(cover: 'p.jpg', banner: 'b.jpg');
      expect(desktopShapedArt(both, wide: false, chosen: 'p.jpg'), 'p.jpg');
      final noPoster = _item(banner: 'b.jpg');
      expect(desktopShapedArt(noPoster, wide: false), 'b.jpg');
    });

    test('Stremio items and unknown items keep the chosen picture', () {
      final stremio = _item(sourceId: 'stremio', banner: 'b.jpg');
      expect(desktopShapedArt(stremio, wide: true, chosen: 's.jpg'), 's.jpg');
      expect(desktopShapedArt(null, wide: true, chosen: 's.jpg'), 's.jpg');
    });

    test('Continue cards prefer the episode still', () {
      final art = desktopResumeArtwork(_resume(still: 'https://e/still.jpg'), [
        _item(banner: 'https://e/banner.jpg'),
      ]);
      expect(art.url, 'https://e/still.jpg');
      expect(art.headers, isNotNull);
    });

    test('Continue cards then borrow the show backdrop Home already has', () {
      // Same source and id wins over a title match.
      final known = [
        _item(id: 'other', banner: 'https://e/by-title.jpg'),
        _item(
          id: 'played-id',
          sourceId: 'player-source',
          title: 'Something else',
          landscape: 'https://e/by-id.jpg',
        ),
      ];
      final byId = desktopResumeArtwork(_resume(), known);
      expect(byId.url, 'https://e/by-id.jpg');
      // Backdrop headers are not the source cover's headers.
      expect(byId.headers, isNull);
      // MyAnimeList id, then the title (ignoring case and punctuation).
      expect(
        desktopResumeArtwork(_resume(malId: 9), [
          _item(id: 'a', title: 'the odyssey!', banner: 'https://e/t.jpg'),
          _item(id: 'b', title: 'X', malId: 9, banner: 'https://e/m.jpg'),
        ]).url,
        'https://e/m.jpg',
      );
      expect(
        desktopResumeArtwork(_resume(), [
          _item(id: 'a', title: 'the odyssey!', banner: 'https://e/t.jpg'),
        ]).url,
        'https://e/t.jpg',
      );
    });

    test(
      'a same-name show with a different MyAnimeList id is not borrowed',
      () {
        // The movie of a series: same title, another source, its own id.
        expect(
          desktopResumeArtwork(_resume(malId: 9), [
            _item(
              id: 'm',
              title: 'The Odyssey',
              malId: 77,
              banner: 'https://e/x',
            ),
          ]).url,
          'https://cdn.example/poster.jpg',
        );
        // Only one side has an id: still not trusted across sources.
        expect(
          desktopResumeArtwork(_resume(), [
            _item(
              id: 'm',
              title: 'The Odyssey',
              malId: 77,
              banner: 'https://e/x',
            ),
          ]).url,
          'https://cdn.example/poster.jpg',
        );
        // From the same source a title match is still used.
        expect(
          desktopResumeArtwork(_resume(malId: 9), [
            _item(
              id: 'm',
              title: 'The Odyssey',
              sourceId: 'player-source',
              banner: 'https://e/same-source.jpg',
            ),
          ]).url,
          'https://e/same-source.jpg',
        );
      },
    );

    test('Continue cards fall back to the poster when nothing wide exists', () {
      final art = desktopResumeArtwork(_resume(), [_item(cover: 'p.jpg')]);
      expect(art.url, 'https://cdn.example/poster.jpg');
      expect(art.headers, isNotNull);
    });
  });

  group('item 8: poster card corners and hover ring', () {
    testWidgets(
      'a picture shown whole has the card corners',
      variant: _windows,
      (tester) async {
        final preview = _ControlledImage();
        final image = await tester.runAsync(() async {
          final recorder = ui.PictureRecorder();
          Canvas(recorder).drawColor(Colors.red, BlendMode.src);
          return recorder.endRecording().toImage(16, 9);
        });
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox(
                width: 100,
                height: 150,
                child: ProgressiveArtwork(
                  preview: preview,
                  fitWhole: true,
                  wholeRadius: 9,
                ),
              ),
            ),
          ),
        );
        preview.completion.complete(ImageInfo(image: image!));
        await tester.pump();
        await tester.pump();
        final whole = find.byKey(const ValueKey('progressive-whole-picture'));
        expect(whole, findsOneWidget);
        final clip = tester.widget<ClipRRect>(
          find.descendant(of: whole, matching: find.byType(ClipRRect)),
        );
        expect(clip.borderRadius, BorderRadius.circular(9));
      },
    );

    Widget surface() => const MaterialApp(
      home: Center(
        child: SizedBox(
          width: 120,
          height: 180,
          child: DesktopMediaSurface(child: ColoredBox(color: Colors.blue)),
        ),
      ),
    );

    testWidgets('Windows draws the ring above the picture', variant: _windows, (
      tester,
    ) async {
      await tester.pumpWidget(surface());
      final box = tester.widget<AnimatedContainer>(
        find.byType(AnimatedContainer),
      );
      final ring = box.foregroundDecoration as BoxDecoration?;
      expect(ring?.border, isNotNull);
      expect((box.decoration as BoxDecoration?)?.border, isNull);
    });

    testWidgets(
      'Android keeps the ring behind the content',
      variant: TargetPlatformVariant.only(TargetPlatform.android),
      (tester) async {
        await tester.pumpWidget(surface());
        final box = tester.widget<AnimatedContainer>(
          find.byType(AnimatedContainer),
        );
        expect(box.foregroundDecoration, isNull);
        expect((box.decoration as BoxDecoration?)?.border, isNotNull);
      },
    );
  });

  group('item 9: rows stop on whole cards', () {
    testWidgets(
      'arrow paging with a stride moves by whole cards',
      variant: _windows,
      (tester) async {
        final c = ScrollController();
        addTearDown(c.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                height: 100,
                width: 400,
                child: DesktopRowScroller(
                  controller: c,
                  stride: 112,
                  child: ListView.separated(
                    controller: c,
                    scrollDirection: Axis.horizontal,
                    itemCount: 30,
                    separatorBuilder: (_, _) => const SizedBox(width: 12),
                    itemBuilder: (_, i) =>
                        SizedBox(width: 100, child: Text('$i')),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        c.jumpTo(40);
        await tester.pump();
        final centre = tester.getCenter(find.byType(ListView));
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        addTearDown(mouse.removePointer);
        await mouse.addPointer(location: centre);
        await mouse.moveTo(centre);
        await tester.pump();
        await tester.tap(find.byIcon(Icons.chevron_right_rounded));
        await tester.pumpAndSettle();
        // From the nearest card edge (0), three whole cards (340 / 112).
        expect(c.offset, 336);
      },
    );

    Future<ScrollPosition> continueRow(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DesktopHomePage(
              featured: const [],
              sections: const [],
              resume: [
                for (var i = 0; i < 6; i++)
                  _resume(image: null, title: 'Show $i'),
              ],
              releases: [
                DesktopHomeRelease(
                  title: 'Release fixture',
                  subtitle: 'Episode 7 available',
                  open: () {},
                ),
              ],
              reading: false,
              meta: (_) async => null,
              onPlay: (_) {},
              onOpen: (_) {},
              onMenu: (_) {},
              onSection: (_) {},
              onHistory: () {},
              onReleases: () {},
              onRefresh: () async {},
              playLabel: (_) => 'Play',
            ),
          ),
        ),
      );
      await tester.pump();
      final block = find.byKey(const ValueKey('desktop-home-continue'));
      return tester
          .state<ScrollableState>(
            find.descendant(of: block, matching: find.byType(Scrollable)).first,
          )
          .position;
    }

    for (final width in [1000.0, 1366.0, 1920.0]) {
      testWidgets(
        'the Continue row ends before the side panel at $width px',
        variant: _windows,
        (tester) async {
          tester.view.physicalSize = Size(width, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await continueRow(tester);
          final block = find.byKey(const ValueKey('desktop-home-continue'));
          final row = tester.getRect(
            find.descendant(of: block, matching: find.byType(ListView)).first,
          );
          final panel = tester.getRect(find.text('Release fixture'));
          expect(row.right, lessThanOrEqualTo(panel.left));
          // The visible cards are all whole: three of them with gaps.
          final card = tester.getRect(
            find.byKey(const ValueKey('desktop-home-resume-0')),
          );
          expect(card.width * 3 + 24, moreOrLessEquals(row.width, epsilon: 1));
        },
      );
    }

    testWidgets(
      'the Continue row settles on a card edge after scrolling',
      variant: _windows,
      (tester) async {
        tester.view.physicalSize = const Size(1366, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final position = await continueRow(tester);
        final stride =
            tester
                .getSize(find.byKey(const ValueKey('desktop-home-resume-0')))
                .width +
            12;
        position.jumpTo(stride * 1.3);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        expect(position.pixels, moreOrLessEquals(stride, epsilon: .5));
      },
    );

    testWidgets(
      'Android leaves the Continue row where it was scrolled',
      variant: TargetPlatformVariant.only(TargetPlatform.android),
      (tester) async {
        tester.view.physicalSize = const Size(1366, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final position = await continueRow(tester);
        position.jumpTo(130);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        expect(position.pixels, 130);
      },
    );
  });
}
