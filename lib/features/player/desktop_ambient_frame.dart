// Windows: cheap frames for the theater page's ambient glow.
//
// The glow only needs a ~32px wide picture, but the sampler used to grab a
// full-resolution JPEG (mpv screenshot, then a pure-Dart JPEG encode of a
// 1440p/4K frame) and decode it again on the page. Here the raw BGRA frame is
// point-sampled straight down to a tiny image and wrapped in an uncompressed
// BMP, so there is no full-frame encode or decode at all; the page's existing
// image decode handles the 32px BMP for free.
import 'dart:typed_data';

/// Row stride (bytes) of a raw BGRA frame of [width] x [height] held in
/// [length] bytes, or null when the buffer cannot be that frame. mpv pads
/// rows on some sizes, so the stride may be larger than `width * 4`.
int? bgraStride(int length, int width, int height) {
  if (width <= 0 || height <= 0) return null;
  if (length == width * height * 4) return width * 4;
  if (length % height != 0) return null;
  final stride = length ~/ height;
  return stride >= width * 4 ? stride : null;
}

/// Downscales a raw BGRA (or BGR0) frame to [targetWidth] pixels wide and
/// returns it as a 32-bit top-down BMP, or null when the size does not fit
/// the buffer. Each output pixel averages a small 2x2 block of source pixels
/// so a single bright speck does not tint the whole glow. Alpha is forced
/// opaque: mpv's raw frames carry a zero padding byte there.
Uint8List? downscaleBgraToBmp(
  Uint8List bgra,
  int width,
  int height, {
  int targetWidth = 32,
}) {
  final stride = bgraStride(bgra.length, width, height);
  if (stride == null) return null;
  final tw = targetWidth.clamp(1, width);
  final th = (height * tw / width).round().clamp(1, height);
  final pixels = Uint8List(tw * th * 4);
  for (var y = 0; y < th; y++) {
    // Centre of this output row in source rows; a 2-row block below it.
    final sy = ((y + 0.5) * height / th).floor().clamp(0, height - 1);
    final sy2 = (sy + 1).clamp(0, height - 1);
    for (var x = 0; x < tw; x++) {
      final sx = ((x + 0.5) * width / tw).floor().clamp(0, width - 1);
      final sx2 = (sx + 1).clamp(0, width - 1);
      var b = 0, g = 0, r = 0;
      for (final row in [sy, sy2]) {
        for (final col in [sx, sx2]) {
          final i = row * stride + col * 4;
          b += bgra[i];
          g += bgra[i + 1];
          r += bgra[i + 2];
        }
      }
      final o = (y * tw + x) * 4;
      // BMP stores BGRA as well.
      pixels[o] = b ~/ 4;
      pixels[o + 1] = g ~/ 4;
      pixels[o + 2] = r ~/ 4;
      pixels[o + 3] = 255;
    }
  }
  return encodeBgraBmp(pixels, tw, th);
}

/// Wraps tightly packed BGRA [pixels] in a BITMAPV4 header (needed for the
/// alpha channel mask) as a top-down 32-bit BMP.
Uint8List encodeBgraBmp(Uint8List pixels, int width, int height) {
  const fileHeader = 14, infoHeader = 108;
  const offset = fileHeader + infoHeader;
  final size = offset + pixels.length;
  final out = Uint8List(size);
  final d = ByteData.sublistView(out);
  // BITMAPFILEHEADER.
  d.setUint8(0, 0x42); // 'B'
  d.setUint8(1, 0x4D); // 'M'
  d.setUint32(2, size, Endian.little);
  d.setUint32(10, offset, Endian.little);
  // BITMAPV4HEADER.
  d.setUint32(14, infoHeader, Endian.little);
  d.setInt32(18, width, Endian.little);
  d.setInt32(22, -height, Endian.little); // negative = top-down rows
  d.setUint16(26, 1, Endian.little); // planes
  d.setUint16(28, 32, Endian.little); // bits per pixel
  d.setUint32(30, 3, Endian.little); // BI_BITFIELDS
  d.setUint32(34, pixels.length, Endian.little);
  d.setUint32(38, 2835, Endian.little); // ~72 dpi
  d.setUint32(42, 2835, Endian.little);
  d.setUint32(54, 0x00FF0000, Endian.little); // red mask
  d.setUint32(58, 0x0000FF00, Endian.little); // green mask
  d.setUint32(62, 0x000000FF, Endian.little); // blue mask
  d.setUint32(66, 0xFF000000, Endian.little); // alpha mask
  d.setUint32(70, 0x73524742, Endian.little); // 'sRGB' colour space
  out.setRange(offset, size, pixels);
  return out;
}
