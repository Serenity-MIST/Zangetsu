// Windows ambient glow (player-16): the tiny BMP built from a raw mpv frame
// must decode with the engine's own image codec, because the watch page
// feeds it straight to instantiateImageCodec like the old JPEG.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/player/desktop_ambient_frame.dart';

void main() {
  testWidgets('the downscaled BMP decodes to the expected size and colour', (
    tester,
  ) async {
    // A 64x36 BGRA frame of one colour (B=10, G=120, R=200, padding 0).
    const w = 64, h = 36;
    final raw = Uint8List(w * h * 4);
    for (var i = 0; i < raw.length; i += 4) {
      raw[i] = 10;
      raw[i + 1] = 120;
      raw[i + 2] = 200;
    }
    final bmp = downscaleBgraToBmp(raw, w, h)!;

    // Real image decoding needs runAsync in widget tests.
    final pixels = await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(bmp);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      expect(image.width, 32);
      expect(image.height, 18);
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return data!.buffer.asUint8List();
    });

    // Top-left pixel: RGBA, opaque, same colour as the source frame.
    expect(pixels!.sublist(0, 4), [200, 120, 10, 255]);
  });
}
