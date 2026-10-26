import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:watch_app/core/theme/app_colors.dart';
import 'package:watch_app/core/ui/poster_palette.dart';

/// 1x1 red pixel PNG, so palette extraction has real colour data to read.
final Uint8List _redPng = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlE'
    'QVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  ),
);

/// 1x1 blue pixel PNG, a distinct image so the cache test can prove the
/// second call never even reaches the decoder. (Handcrafted: the base64
/// fixture first suggested for this failed to decode in this environment.)
final Uint8List _bluePng = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYPgPAAEDAQAIicLsAAAAAElFTkSuQmCC',
  ),
);

/// MemoryImage that counts how many times the decoder actually ran, so the
/// cache test can prove a second call never re-decodes the same URL.
// ignore: must_be_immutable — mutable decode counter is the point of this class.
class _CountingImage extends MemoryImage {
  _CountingImage(super.bytes);
  int loads = 0;

  @override
  ImageStreamCompleter loadImage(MemoryImage key, ImageDecoderCallback decode) {
    loads++;
    return super.loadImage(key, decode);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('tintFromDominant keeps hue, drops lightness and saturation', () {
    final tint = tintFromDominant(const Color(0xFFFF0000));
    final hsl = HSLColor.fromColor(tint);
    expect(hsl.hue, closeTo(0, 0.01));
    expect(hsl.saturation, closeTo(0.32, 0.01));
    expect(hsl.lightness, closeTo(0.15, 0.01));
  });

  test('tintFromDominant maps greys to a flat dark surface', () {
    final tint = tintFromDominant(const Color(0xFF808080));
    final hsl = HSLColor.fromColor(tint);
    expect(hsl.saturation, 0);
    expect(hsl.lightness, closeTo(0.15, 0.01));
  });

  testWidgets('extractDominantColorFrom caches per key', (tester) async {
    final red = _CountingImage(_redPng);
    final blue = _CountingImage(_bluePng);
    // runAsync: palette extraction decodes via the real engine image pipeline,
    // which never delivers inside the test's fake-async zone.
    final a = await tester.runAsync(
      () => extractDominantColorFrom(red, cacheKey: 'red-blue'),
    );
    // Same cache key, DIFFERENT image: our cache must hand back red's colour
    // without ever decoding the blue artwork. Distinct providers also keep
    // the framework ImageCache out of the picture — it cannot serve red's
    // completer for blue's bytes, so `blue` never loading and `b == a` can
    // only be explained by our own cache.
    final b = await tester.runAsync(
      () => extractDominantColorFrom(blue, cacheKey: 'red-blue'),
    );
    expect(a, isNotNull);
    expect(b, a);
    expect(blue.loads, 0);
    expect(red.loads, 1);

    // Sanity-check the blue fixture really decodes blue (hue ~240) under its
    // own key, so "b == a" above means blue was genuinely ignored, not that
    // the fixture silently failed to decode.
    final blueCheck = await tester.runAsync(
      () => extractDominantColorFrom(blue, cacheKey: 'blue-fixture'),
    );
    expect(blueCheck, isNotNull);
    expect(HSLColor.fromColor(blueCheck!).hue, closeTo(240, 20));
  });

  testWidgets(
    'extractDominantColorFrom returns null on a bad provider and retries',
    (tester) async {
      final bad = _CountingImage(Uint8List.fromList([1, 2, 3]));
      // The expected decode failure is reported through FlutterError by the
      // image resource service; swallow just those, keep everything else.
      final previousOnError = FlutterError.onError;
      FlutterError.onError = (details) {
        if (details.library != 'image resource service') {
          previousOnError?.call(details);
        }
      };
      final a = await tester.runAsync(
        () => extractDominantColorFrom(bad, cacheKey: 'bad-retry'),
      );
      // Evict the framework ImageCache's entry for the failed completer, so the
      // second resolve genuinely re-attempts the decode instead of being served
      // the same failed completer (the framework never stores nulls either, so
      // only our cache could have prevented the retry).
      PaintingBinding.instance.imageCache.evict(bad);
      final b = await tester.runAsync(
        () => extractDominantColorFrom(bad, cacheKey: 'bad-retry'),
      );
      FlutterError.onError = previousOnError;
      expect(a, isNull);
      expect(b, isNull);
      expect(bad.loads, 2);
    },
  );

  testWidgets('PosterTintLayer paints theme bg when null, tint when set', (
    tester,
  ) async {
    final notifier = ValueNotifier<Color?>(null);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(children: [PosterTintLayer(notifier: notifier)]),
      ),
    );
    var box = tester.widget<AnimatedContainer>(find.byType(AnimatedContainer));
    Color? layerColor() => (box.decoration as BoxDecoration?)?.color;
    expect(layerColor(), AppColors.bg);

    notifier.value = const Color(0xFF241A33);
    await tester.pumpAndSettle();
    box = tester.widget<AnimatedContainer>(find.byType(AnimatedContainer));
    expect(layerColor(), const Color(0xFF241A33));

    notifier.dispose();
  });
}
