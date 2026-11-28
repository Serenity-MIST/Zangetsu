// Windows: pictures loaded ahead one at a time, paused while the page moves,
// and never filling the image cache. Also the minimise timer of that cache.
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/desktop_image_cache.dart';
import 'package:watch_app/core/desktop/desktop_picture_warmer.dart';

/// A picture that arrives when the test says so.
class _Slow extends ImageProvider<_Slow> {
  _Slow(this.name);
  final String name;
  final completer = Completer<ImageInfo>();
  int loads = 0;
  @override
  Future<_Slow> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);
  @override
  ImageStreamCompleter loadImage(_Slow key, ImageDecoderCallback decode) {
    loads++;
    return OneFrameImageStreamCompleter(completer.future);
  }
}

void main() {
  late ui.Image image;
  late ImageCache cache;
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    image = await createTestImage(width: 10, height: 10, cache: false);
    cache = PaintingBinding.instance.imageCache;
    cache.clear();
    cache.clearLiveImages();
  });

  testWidgets('one at a time, and held pictures are skipped', (tester) async {
    final warmer = DesktopPictureWarmer(ready: () => true);
    final a = _Slow('a'), b = _Slow('b');
    warmer.load([a, a, b]);
    await tester.pump(const Duration(milliseconds: 100));
    expect((a.loads, b.loads), (1, 0));
    await tester.pump(const Duration(seconds: 1));
    expect(b.loads, 0, reason: 'waits for the first picture');
    a.completer.complete(ImageInfo(image: image.clone()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect((a.loads, b.loads), (1, 1));
    expect(cache.statusForKey(a).keepAlive, isTrue);
    warmer.dispose();
  });

  testWidgets('waits while not ready; a stuck picture gives way', (
    tester,
  ) async {
    var ready = false;
    final warmer = DesktopPictureWarmer(ready: () => ready);
    final a = _Slow('a'), b = _Slow('b');
    warmer.load([a, b]);
    await tester.pump(const Duration(seconds: 3));
    expect(a.loads, 0);
    ready = true;
    await tester.pump(const Duration(seconds: 1));
    expect((a.loads, b.loads), (1, 0));
    await tester.pump(DesktopPictureWarmer.timeout);
    await tester.pump(const Duration(milliseconds: 100));
    expect(b.loads, 1);
    warmer.dispose();
  });

  testWidgets('the newest urgent pictures replace the earlier ones', (
    tester,
  ) async {
    final warmer = DesktopPictureWarmer(ready: () => false);
    final rest = [_Slow('r1'), _Slow('r2')];
    final banners = [for (var i = 0; i < 5; i++) _Slow('b$i')];
    warmer.load(rest, first: [banners[0]]);
    for (var i = 0; i < 400; i++) {
      warmer.loadFirst([banners[i % 5]]);
    }
    expect(warmer.waiting, 3);
    // One that was waiting anyway only moves to the front.
    warmer.loadFirst([rest.last]);
    expect(warmer.waiting, 2);
    warmer.dispose();
  });

  testWidgets('covered: nothing is retried until it may run again', (
    tester,
  ) async {
    var may = false, asked = 0;
    final warmer = DesktopPictureWarmer(
      ready: () => true,
      mayRun: () {
        asked++;
        return may;
      },
    );
    final a = _Slow('a');
    warmer.load([a]);
    await tester.pump(const Duration(minutes: 5));
    expect((a.loads, asked), (0, 1));
    may = true;
    warmer.resume();
    await tester.pump(const Duration(milliseconds: 100));
    expect(a.loads, 1);
    warmer.dispose();
  });

  testWidgets('stops for good once the cache is 60 percent full', (
    tester,
  ) async {
    final limit = cache.maximumSizeBytes;
    addTearDown(() => cache.maximumSizeBytes = limit);
    cache.maximumSizeBytes = 600; // one 10 x 10 picture is 400 bytes
    final warmer = DesktopPictureWarmer(ready: () => true);
    final a = _Slow('a'), b = _Slow('b');
    a.completer.complete(ImageInfo(image: image.clone()));
    warmer.load([a, b]);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect((a.loads, b.loads), (1, 0));
    expect(warmer.stoppedForGood, isTrue);
    warmer.load([b]);
    await tester.pump(const Duration(seconds: 1));
    expect(b.loads, 0);
    warmer.dispose();
  });

  group('minimised window', () {
    Future<_Slow> held(WidgetTester tester) async {
      final a = _Slow('a');
      a.completer.complete(ImageInfo(image: image.clone()));
      a.resolve(ImageConfiguration.empty);
      await tester.pump();
      expect(cache.statusForKey(a).keepAlive, isTrue);
      return a;
    }

    testWidgets('8 GB PCs empty the cache at once', (tester) async {
      final a = await held(tester);
      DesktopMinimisedImageClearer(roomy: false).hidden();
      expect(cache.statusForKey(a).keepAlive, isFalse);
    });

    testWidgets('roomier PCs only after ten minutes away', (tester) async {
      final a = await held(tester);
      final clearer = DesktopMinimisedImageClearer(roomy: true)..hidden();
      await tester.pump(const Duration(minutes: 9));
      expect(cache.statusForKey(a).keepAlive, isTrue);
      clearer.shown();
      await tester.pump(const Duration(minutes: 30));
      expect(cache.statusForKey(a).keepAlive, isTrue);
      clearer.hidden();
      await tester.pump(const Duration(minutes: 10));
      expect(cache.statusForKey(a).keepAlive, isFalse);
    });
  });
}
