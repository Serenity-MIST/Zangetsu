import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// What an image-like Windows clipboard holds: files copied in Explorer
/// ([paths]) and/or a picture copied from an app or browser ([imageBytes],
/// PNG or BMP bytes ready for package:image).
///
/// Flutter's Clipboard API only reads text, so pasting a picture (acct-6:
/// Ctrl+V onto a profile avatar) reads the Windows clipboard directly.
class DesktopClipboardImage {
  const DesktopClipboardImage({this.paths = const [], this.imageBytes});

  /// Files copied in Explorer (CF_HDROP), in clipboard order.
  final List<String> paths;

  /// A copied picture: the app's "PNG" format when offered, else the
  /// CF_DIB bitmap wrapped as a .bmp file.
  final Uint8List? imageBytes;

  bool get isEmpty => paths.isEmpty && imageBytes == null;
}

/// Test hook: when set, [readDesktopClipboardImage] returns this instead of
/// reading the real clipboard.
@visibleForTesting
Future<DesktopClipboardImage?> Function()? debugClipboardImageOverride;

/// Reads files or a picture from the Windows clipboard. Returns null off
/// Windows, when the clipboard is busy, or when it holds neither.
///
/// Runs on a background isolate: a large screenshot can take a moment to
/// copy and convert, and the UI must not stutter meanwhile.
Future<DesktopClipboardImage?> readDesktopClipboardImage() async {
  final override = debugClipboardImageOverride;
  if (override != null) return override();
  if (!Platform.isWindows) return null;
  try {
    final result = await Isolate.run(_readClipboard);
    return result == null || result.isEmpty ? null : result;
  } catch (_) {
    return null;
  }
}

/// Clipboard format ids (winuser.h).
const int _cfDib = 8;
const int _cfHdrop = 15;

/// Isolate side of [readDesktopClipboardImage].
DesktopClipboardImage? _readClipboard() {
  final user32 = DynamicLibrary.open('user32.dll');
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final shell32 = DynamicLibrary.open('shell32.dll');
  final ole32 = DynamicLibrary.open('ole32.dll');

  final openClipboard = user32
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('OpenClipboard');
  final closeClipboard = user32
      .lookupFunction<Int32 Function(), int Function()>('CloseClipboard');
  final isAvailable = user32
      .lookupFunction<Int32 Function(Uint32), int Function(int)>(
        'IsClipboardFormatAvailable',
      );
  final getData = user32
      .lookupFunction<
        Pointer<Void> Function(Uint32),
        Pointer<Void> Function(int)
      >('GetClipboardData');
  final registerFormat = user32
      .lookupFunction<
        Uint32 Function(Pointer<Uint16>),
        int Function(Pointer<Uint16>)
      >('RegisterClipboardFormatW');
  final globalLock = kernel32
      .lookupFunction<
        Pointer<Uint8> Function(Pointer<Void>),
        Pointer<Uint8> Function(Pointer<Void>)
      >('GlobalLock');
  final globalUnlock = kernel32
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('GlobalUnlock');
  final globalSize = kernel32
      .lookupFunction<
        IntPtr Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('GlobalSize');
  final dragQueryFile = shell32
      .lookupFunction<
        Uint32 Function(Pointer<Void>, Uint32, Pointer<Uint16>, Uint32),
        int Function(Pointer<Void>, int, Pointer<Uint16>, int)
      >('DragQueryFileW');
  final allocate = ole32
      .lookupFunction<
        Pointer<Void> Function(IntPtr),
        Pointer<Void> Function(int)
      >('CoTaskMemAlloc');
  final free = ole32
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('CoTaskMemFree');

  // Copies a clipboard memory handle into Dart-owned bytes.
  Uint8List? copyHandle(Pointer<Void> handle) {
    if (handle == nullptr) return null;
    final size = globalSize(handle);
    if (size <= 0) return null;
    final data = globalLock(handle);
    if (data == nullptr) return null;
    try {
      return Uint8List.fromList(data.asTypedList(size));
    } finally {
      globalUnlock(handle);
    }
  }

  // Another app may hold the clipboard for a moment; retry briefly.
  var opened = false;
  for (var attempt = 0; attempt < 5 && !opened; attempt++) {
    opened = openClipboard(nullptr) != 0;
    if (!opened) sleep(const Duration(milliseconds: 20));
  }
  if (!opened) return null;
  try {
    // 1) Files copied in Explorer.
    final paths = <String>[];
    if (isAvailable(_cfHdrop) != 0) {
      final drop = getData(_cfHdrop);
      if (drop != nullptr) {
        final count = dragQueryFile(drop, 0xFFFFFFFF, nullptr, 0);
        for (var i = 0; i < count; i++) {
          final length = dragQueryFile(drop, i, nullptr, 0);
          if (length <= 0) continue;
          final buffer = allocate((length + 1) * 2).cast<Uint16>();
          if (buffer == nullptr) continue;
          try {
            dragQueryFile(drop, i, buffer, length + 1);
            paths.add(String.fromCharCodes(buffer.asTypedList(length)));
          } finally {
            free(buffer.cast());
          }
        }
      }
    }

    // 2) A copied picture: browsers and many apps also offer "PNG", which
    // keeps transparency; otherwise use the device-independent bitmap.
    Uint8List? imageBytes;
    final name = 'PNG'.codeUnits;
    final nameBuffer = allocate((name.length + 1) * 2).cast<Uint16>();
    var pngFormat = 0;
    if (nameBuffer != nullptr) {
      try {
        nameBuffer.asTypedList(name.length + 1)
          ..setAll(0, name)
          ..[name.length] = 0;
        pngFormat = registerFormat(nameBuffer);
      } finally {
        free(nameBuffer.cast());
      }
    }
    if (pngFormat != 0 && isAvailable(pngFormat) != 0) {
      imageBytes = copyHandle(getData(pngFormat));
    }
    if (imageBytes == null && isAvailable(_cfDib) != 0) {
      final dib = copyHandle(getData(_cfDib));
      if (dib != null) imageBytes = normalizeClipboardBitmap(dibToBmp(dib));
    }
    return DesktopClipboardImage(paths: paths, imageBytes: imageBytes);
  } finally {
    closeClipboard();
  }
}

/// Wraps a CF_DIB block (BITMAPINFOHEADER + optional masks/palette +
/// pixels) in the 14-byte BITMAPFILEHEADER that makes it a .bmp file.
/// Returns null when the header is not one Windows writes.
@visibleForTesting
Uint8List? dibToBmp(Uint8List dib) {
  if (dib.length < 40) return null;
  final header = ByteData.sublistView(dib);
  final headerSize = header.getUint32(0, Endian.little);
  if (headerSize < 40 || headerSize > dib.length) return null;
  final bitCount = header.getUint16(14, Endian.little);
  final compression = header.getUint32(16, Endian.little);
  final colorsUsed = header.getUint32(32, Endian.little);
  // A plain BITMAPINFOHEADER is followed by the colour masks for
  // BI_BITFIELDS (3 masks) and BI_ALPHABITFIELDS (4 masks).
  var masks = 0;
  if (headerSize == 40) {
    if (compression == 3) masks = 12;
    if (compression == 6) masks = 16;
  }
  // Palettised bitmaps carry a colour table of RGBQUADs.
  final palette = bitCount <= 8
      ? (colorsUsed == 0 ? 1 << bitCount : colorsUsed) * 4
      : colorsUsed * 4;
  final pixelOffset = 14 + headerSize + masks + palette;
  final out = Uint8List(14 + dib.length);
  final file = ByteData.sublistView(out);
  out[0] = 0x42; // 'B'
  out[1] = 0x4D; // 'M'
  file.setUint32(2, out.length, Endian.little);
  file.setUint32(10, pixelOffset, Endian.little);
  out.setRange(14, out.length, dib);
  return out;
}

/// Re-encodes a clipboard bitmap as PNG. Many apps put 32-bit bitmaps on the
/// clipboard with every alpha byte 0, which would read as fully
/// transparent; such pictures are made opaque. Returns [bmp] unchanged when
/// it cannot be decoded (the uploader then reports the failure).
@visibleForTesting
Uint8List? normalizeClipboardBitmap(Uint8List? bmp) {
  if (bmp == null) return null;
  final decoded = img.decodeBmp(bmp);
  if (decoded == null) return bmp;
  final image = decoded;
  if (image.numChannels == 4) {
    var anyAlpha = false;
    for (final pixel in image) {
      if (pixel.a != 0) {
        anyAlpha = true;
        break;
      }
    }
    if (!anyAlpha) {
      for (final pixel in image) {
        pixel.a = pixel.maxChannelValue;
      }
    }
  }
  return img.encodePng(image);
}
