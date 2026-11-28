import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/desktop_image_clipboard.dart';

/// The CF_DIB payload behind the reader's Windows 'Copy image' (reader-1).
void main() {
  test('builds a bottom-up 32-bit BGRA bitmap with a 40-byte header', () {
    // 2x2 image, top row red, green; bottom row blue, white (straight RGBA).
    final rgba = Uint8List.fromList([
      255, 0, 0, 255, 0, 255, 0, 255, //
      0, 0, 255, 255, 255, 255, 255, 128,
    ]);
    final dib = buildClipboardDib(rgba, 2, 2);
    final header = ByteData.sublistView(dib, 0, 40);

    expect(dib.length, 40 + 2 * 2 * 4);
    expect(header.getUint32(0, Endian.little), 40); // biSize
    expect(header.getInt32(4, Endian.little), 2); // width
    expect(header.getInt32(8, Endian.little), 2); // positive = bottom-up
    expect(header.getUint16(12, Endian.little), 1); // planes
    expect(header.getUint16(14, Endian.little), 32); // bits per pixel
    expect(header.getUint32(16, Endian.little), 0); // BI_RGB
    expect(header.getUint32(20, Endian.little), 16); // image size

    // First bitmap row is the image's BOTTOM row: blue, then white.
    expect(dib.sublist(40, 48), [255, 0, 0, 255, 255, 255, 255, 128]);
    // Second bitmap row is the top row: red, then green (as B, G, R, A).
    expect(dib.sublist(48, 56), [0, 0, 255, 255, 0, 255, 0, 255]);
  });

  test('the test hook receives the bytes instead of the clipboard', () async {
    Uint8List? got;
    debugImageClipboardOverride = (bytes) async {
      got = bytes;
      return true;
    };
    addTearDown(() => debugImageClipboardOverride = null);
    final bytes = Uint8List.fromList([1, 2, 3]);
    expect(await copyImageToClipboard(bytes), isTrue);
    expect(got, bytes);
  });
}
