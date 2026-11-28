import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/ui/progressive_artwork.dart';
import 'package:watch_app/core/ui/artwork_quality.dart';
import 'package:watch_app/core/ui/desktop_media_card.dart';
import 'package:cached_network_image/cached_network_image.dart';

/// Controlled decode completion verifies request order without using HTTP.
class _ControlledImage extends ImageProvider<_ControlledImage> {
  final completion = Completer<ImageInfo>();
  int loads = 0;
  @override
  Future<_ControlledImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);
  @override
  ImageStreamCompleter loadImage(
    _ControlledImage key,
    ImageDecoderCallback decode,
  ) {
    loads++;
    return OneFrameImageStreamCompleter(completion.future);
  }
}

Widget _view(_ControlledImage preview, _ControlledImage full) => MaterialApp(
  home: Center(
    child: SizedBox(
      width: 100,
      height: 100,
      child: ProgressiveArtwork(preview: preview, full: full),
    ),
  ),
);

void main() {
  test('small variants preserve unrelated signed extension URLs', () {
    expect(
      artworkPreviewUrl('https://image.tmdb.org/t/p/original/a.jpg'),
      'https://image.tmdb.org/t/p/w185/a.jpg',
    );
    const signed = 'https://images.example/cover.jpg?signature=keep';
    expect(artworkPreviewUrl(signed), signed);
  });
  testWidgets('full waits for preview and failure keeps preview', (
    tester,
  ) async {
    final preview = _ControlledImage(), full = _ControlledImage();
    final image = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(Colors.red, BlendMode.src);
      return recorder.endRecording().toImage(2, 2);
    });
    await tester.pumpWidget(_view(preview, full));
    expect(preview.loads, 1);
    expect(full.loads, 0);
    preview.completion.complete(ImageInfo(image: image!));
    await tester.pump();
    await tester.pump();
    expect(full.loads, 1);
    full.completion.completeError(StateError('full quality unavailable'));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate((w) => w is Image && w.image == preview),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('failed thumbnail stages retain the explicit offline fallback', (
    tester,
  ) async {
    final preview = _ControlledImage(), full = _ControlledImage();
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 80,
          height: 48,
          child: ProgressiveArtwork(
            preview: preview,
            full: full,
            fallback: const Text('Offline poster'),
          ),
        ),
      ),
    );
    preview.completion.completeError(StateError('thumbnail unavailable'));
    await tester.pump();
    await tester.pump();
    full.completion.completeError(StateError('full unavailable'));
    await tester.pumpAndSettle();
    expect(find.text('Offline poster'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('changed cards do not start the old full request', (
    tester,
  ) async {
    final oldPreview = _ControlledImage(), oldFull = _ControlledImage();
    final nextPreview = _ControlledImage(), nextFull = _ControlledImage();
    await tester.pumpWidget(_view(oldPreview, oldFull));
    await tester.pumpWidget(_view(nextPreview, nextFull));
    expect(oldFull.loads, 0);
    expect(nextPreview.loads, 1);
    expect(nextFull.loads, 0);
    expect(tester.takeException(), isNull);
  });
  // Windows keeps one decoded image per card: once the full art has faded in
  // the preview underneath is no longer built. Other platforms keep both.
  Future<void> showBoth(
    WidgetTester tester,
    _ControlledImage preview,
    _ControlledImage full,
  ) async {
    final image = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(Colors.red, BlendMode.src);
      return recorder.endRecording().toImage(2, 2);
    });
    await tester.pumpWidget(_view(preview, full));
    preview.completion.complete(ImageInfo(image: image!));
    await tester.pump();
    await tester.pump();
    full.completion.complete(ImageInfo(image: image.clone()));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Windows drops the preview once the full art is shown',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      final preview = _ControlledImage(), full = _ControlledImage();
      await showBoth(tester, preview, full);
      expect(
        find.byWidgetPredicate((w) => w is Image && w.image == preview),
        findsNothing,
      );
      expect(
        find.byWidgetPredicate((w) => w is Image && w.image == full),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Windows fades late pictures in without an opacity layer',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      final preview = _ControlledImage(), full = _ControlledImage();
      final image = await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(Colors.red, BlendMode.src);
        return recorder.endRecording().toImage(2, 2);
      });
      await tester.pumpWidget(_view(preview, full));
      preview.completion.complete(ImageInfo(image: image!));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      // Mid-fade: the picture draws itself part see-through.
      final shown = tester.widget<Image>(
        find.byKey(const ValueKey('progressive-preview')),
      );
      expect(shown.opacity, isNotNull);
      expect(shown.opacity!.value, inExclusiveRange(0, 1));
      expect(find.byType(AnimatedOpacity), findsNothing);
      expect(find.byType(Opacity), findsNothing);
      full.completion.complete(ImageInfo(image: image.clone()));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Image>(find.byKey(const ValueKey('progressive-full')))
            .opacity!
            .value,
        1,
      );
      expect(find.byType(AnimatedOpacity), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  // Windows scrolling cost on built-in laptop graphics (Home lower rows).
  group('Windows scrolling cost', () {
    final windows = TargetPlatformVariant.only(TargetPlatform.windows);

    /// A tiny red picture for the controlled images.
    Future<ui.Image> picture(WidgetTester tester) async =>
        (await tester.runAsync(() async {
          final recorder = ui.PictureRecorder();
          Canvas(recorder).drawColor(Colors.red, BlendMode.src);
          return recorder.endRecording().toImage(2, 2);
        }))!;

    testWidgets(
      'a full picture already in memory is shown without the preview',
      variant: windows,
      (tester) async {
        PaintingBinding.instance.imageCache.clear();
        final preview = _ControlledImage(), full = _ControlledImage();
        full.completion.complete(ImageInfo(image: await picture(tester)));
        // Decode the full picture once, as an earlier visit to the row did.
        final stream = full.resolve(ImageConfiguration.empty);
        final listener = ImageStreamListener((_, _) {});
        stream.addListener(listener);
        await tester.pump();
        stream.removeListener(listener);
        await tester.pumpWidget(_view(preview, full));
        await tester.pumpAndSettle();
        expect(preview.loads, 0);
        expect(
          find.byWidgetPredicate((w) => w is Image && w.image == full),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'cover pictures use plain smoothing and the preview leaves memory',
      variant: windows,
      (tester) async {
        PaintingBinding.instance.imageCache.clear();
        final preview = _ControlledImage(), full = _ControlledImage();
        await showBoth(tester, preview, full);
        expect(
          tester
              .widget<Image>(find.byKey(const ValueKey('progressive-full')))
              .filterQuality,
          FilterQuality.low,
        );
        final cache = PaintingBinding.instance.imageCache;
        expect(cache.statusForKey(preview).tracked, isFalse);
        expect(cache.statusForKey(full).tracked, isTrue);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'only a few full pictures start in the same frame',
      variant: windows,
      (tester) async {
        PaintingBinding.instance.imageCache.clear();
        final image = await picture(tester);
        final previews = List.generate(5, (_) => _ControlledImage());
        final fulls = List.generate(5, (_) => _ControlledImage());
        for (final p in previews) {
          p.completion.complete(ImageInfo(image: image.clone()));
        }
        await tester.pumpWidget(
          MaterialApp(
            home: Column(
              children: [
                for (var i = 0; i < 5; i++)
                  SizedBox(
                    width: 40,
                    height: 40,
                    child: ProgressiveArtwork(
                      preview: previews[i],
                      full: fulls[i],
                    ),
                  ),
              ],
            ),
          ),
        );
        int started() => fulls.fold(0, (sum, f) => sum + f.loads);
        var before = started();
        for (var frame = 0; frame < 12; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          final now = started();
          expect(now - before, lessThanOrEqualTo(kDesktopFullStartsPerFrame));
          before = now;
        }
        expect(started(), 5);
        expect(tester.takeException(), isNull);
      },
    );
  });

  testWidgets(
    'phone still fades the full art with an animated opacity',
    variant: TargetPlatformVariant.only(TargetPlatform.android),
    (tester) async {
      final preview = _ControlledImage(), full = _ControlledImage();
      await showBoth(tester, preview, full);
      expect(find.byType(AnimatedOpacity), findsOneWidget);
      expect(
        tester
            .widget<Image>(find.byKey(const ValueKey('progressive-full')))
            .opacity,
        isNull,
      );
    },
  );

  testWidgets(
    'phone keeps the preview under the full art',
    variant: TargetPlatformVariant.only(TargetPlatform.android),
    (tester) async {
      final preview = _ControlledImage(), full = _ControlledImage();
      await showBoth(tester, preview, full);
      expect(
        find.byWidgetPredicate((w) => w is Image && w.image == preview),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate((w) => w is Image && w.image == full),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  // Windows cards never crop: a picture whose shape differs from the box is
  // shown whole over a blurred copy; a matching picture still fills the box.
  group('fit whole', () {
    Future<void> showShape(
      WidgetTester tester,
      _ControlledImage preview,
      int w,
      int h,
    ) async {
      final image = await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(Colors.red, BlendMode.src);
        return recorder.endRecording().toImage(w, h);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 100,
              height: 150,
              child: ProgressiveArtwork(preview: preview, fitWhole: true),
            ),
          ),
        ),
      );
      preview.completion.complete(ImageInfo(image: image!));
      await tester.pump();
      await tester.pump();
    }

    BoxFit? fitOf(WidgetTester tester, _ControlledImage preview) => tester
        .widget<Image>(find.byKey(const ValueKey('progressive-preview')))
        .fit;

    testWidgets(
      'landscape art in a poster box is shown whole with a blurred fill',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
        final preview = _ControlledImage();
        await showShape(tester, preview, 16, 9);
        expect(fitOf(tester, preview), BoxFit.contain);
        expect(
          find.byKey(const ValueKey('progressive-blur-fill')),
          findsOneWidget,
        );
        // The shape is read through the shared cache, so it adds no load.
        // The one extra load is the tiny copy used as the soft fill.
        expect(preview.loads, 2);
        final fill = tester
            .widget<Image>(
              find.byKey(const ValueKey('progressive-soft-fill-image')),
            )
            .image;
        expect(fill, isA<ResizeImage>());
        expect((fill as ResizeImage).imageProvider, same(preview));
        expect(fill.width, kArtworkFillDecodeWidth);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'the soft fill uses no blur filter and no layers of its own',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
        final preview = _ControlledImage();
        await showShape(tester, preview, 16, 9);
        final fill = find.byKey(const ValueKey('progressive-blur-fill'));
        expect(fill, findsOneWidget);
        for (final costly in [ImageFiltered, BackdropFilter, RepaintBoundary]) {
          expect(
            find.descendant(of: fill, matching: find.byType(costly)),
            findsNothing,
          );
        }
        expect(
          tester
              .widget<Image>(
                find.byKey(const ValueKey('progressive-soft-fill-image')),
              )
              .filterQuality,
          FilterQuality.low,
        );
      },
    );

    test('the fill copy is decoded from the original, not the resized one', () {
      final original = _ControlledImage();
      final fill = artworkFillProvider(ResizeImage(original, width: 320));
      expect(fill, isA<ResizeImage>());
      expect((fill as ResizeImage).imageProvider, same(original));
      expect(fill.width, kArtworkFillDecodeWidth);
    });

    testWidgets(
      'a poster in a poster box fills it with no blurred fill',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
        final preview = _ControlledImage();
        await showShape(tester, preview, 2, 3);
        expect(fitOf(tester, preview), BoxFit.cover);
        expect(
          find.byKey(const ValueKey('progressive-blur-fill')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );

    test('shape tolerance', () {
      expect(artworkNeedsWholeFit(2 / 3, 2 / 3), isFalse);
      expect(artworkNeedsWholeFit(.68, 2 / 3), isFalse);
      expect(artworkNeedsWholeFit(16 / 9, 2 / 3), isTrue);
      expect(artworkNeedsWholeFit(2 / 3, 16 / 9), isTrue);
    });
  });

  testWidgets(
    'phone artwork keeps the plain cover fit',
    variant: TargetPlatformVariant.only(TargetPlatform.android),
    (tester) async {
      final preview = _ControlledImage();
      await tester.pumpWidget(_view(preview, _ControlledImage()));
      expect(
        tester
            .widget<Image>(find.byKey(const ValueKey('progressive-preview')))
            .fit,
        BoxFit.cover,
      );
      expect(find.byKey(const ValueKey('progressive-blur-fill')), findsNothing);
    },
  );

  group('Windows one-step card pictures', () {
    // A Home poster sized URL: TMDB, so the preview and sharp sizes differ.
    const tmdb = 'https://image.tmdb.org/t/p/original/poster.jpg';

    /// The CDN URL behind a card picture provider (a resized network image).
    String urlOf(ImageProvider image) =>
        ((image as ResizeImage).imageProvider as CachedNetworkImageProvider)
            .url;

    testWidgets(
      'small cards load only the sharp picture, at the card size',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
        final art = desktopArtworkFor(
          url: tmdb,
          width: 160,
          devicePixelRatio: 1.5,
        );
        final target = desktopArtworkDecodeWidth(
          160 * (1 + kArtworkFitWholeTolerance),
          1.5,
        );
        expect(target, lessThanOrEqualTo(kDesktopArtworkSingleStageWidth));
        expect(art.full, isNull);
        expect(
          urlOf(art.preview),
          desktopArtworkUrl(tmdb, targetWidth: target),
        );
        expect((art.preview as ResizeImage).width, target);
        expect(art.fitWhole, isTrue);
        // The fallback is the source's own picture, laid out the same way
        // (whole over the soft fill when its shape differs), not cropped.
        final fallback = art.fallback! as ProgressiveArtwork;
        expect(fallback.key, const ValueKey('desktop-artwork-fallback'));
        expect(fallback.full, isNull);
        expect(fallback.fitWhole, isTrue);
        expect(fallback.wholeRadius, art.wholeRadius);
        // The source's own URL, or the small CDN size when the sharp size is
        // the source URL itself; never the sharp URL that just failed.
        final sharp = desktopArtworkUrl(tmdb, targetWidth: target);
        expect(
          urlOf(fallback.preview),
          sharp != tmdb ? tmdb : artworkPreviewUrl(tmdb),
        );
        expect(urlOf(fallback.preview), isNot(sharp));
        expect((fallback.preview as ResizeImage).width, target);
      },
    );

    testWidgets(
      'large cards keep the preview first, then the sharp picture',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
        final art = desktopArtworkFor(
          url: tmdb,
          width: 900,
          devicePixelRatio: 1,
        );
        final target = desktopArtworkDecodeWidth(
          900 * (1 + kArtworkFitWholeTolerance),
          1,
        );
        expect(target, greaterThan(kDesktopArtworkSingleStageWidth));
        expect(urlOf(art.preview), artworkPreviewUrl(tmdb));
        expect((art.preview as ResizeImage).width, 320);
        expect(art.full, isNotNull);
        expect(urlOf(art.full!), desktopArtworkUrl(tmdb, targetWidth: target));
        expect(art.fallback, isNull);
      },
    );

    testWidgets(
      'Android keeps the two-step pictures',
      variant: TargetPlatformVariant.only(TargetPlatform.android),
      (tester) async {
        final art = desktopArtworkFor(
          url: tmdb,
          width: 160,
          devicePixelRatio: 1.5,
        );
        final target = desktopArtworkDecodeWidth(160, 1.5);
        expect(art.full, isNotNull);
        expect(art.fallback, isNull);
        expect(art.fitWhole, isFalse);
        expect((art.preview as ResizeImage).width, math.min(target, 320));
        expect((art.full! as ResizeImage).width, target);
      },
    );

    testWidgets(
      'a row of one-step pictures arriving together is drawn a few per frame',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
        final images = [for (var i = 0; i < 5; i++) _ControlledImage()];
        // Pictures actually drawn (a picture still loading has no image).
        Finder drawn() =>
            find.byWidgetPredicate((w) => w is RawImage && w.image != null);
        final picture = await tester.runAsync(() async {
          final recorder = ui.PictureRecorder();
          Canvas(recorder).drawColor(Colors.red, BlendMode.src);
          return recorder.endRecording().toImage(2, 2);
        });
        await tester.pumpWidget(
          MaterialApp(
            home: Row(
              children: [
                for (final image in images)
                  SizedBox(
                    width: 60,
                    height: 90,
                    child: ProgressiveArtwork(preview: image),
                  ),
              ],
            ),
          ),
        );
        // Let any earlier frame's budget run out before the row lands.
        await tester.pump();
        for (final image in images) {
          image.completion.complete(ImageInfo(image: picture!.clone()));
        }
        // Frame by frame, no more than the per-frame budget's worth of new
        // pictures is drawn, and the row is not all drawn in one frame.
        var shown = 0, frames = 0;
        while (shown < images.length && frames < 20) {
          await tester.pump();
          frames++;
          final now = drawn().evaluate().length;
          expect(now - shown, lessThanOrEqualTo(kDesktopFullStartsPerFrame));
          shown = now;
        }
        expect(shown, images.length);
        await tester.pumpAndSettle();
        expect(drawn(), findsNWidgets(images.length));
        expect(tester.takeException(), isNull);
      },
    );
  });
}
