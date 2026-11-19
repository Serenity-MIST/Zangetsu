import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// Test hook: when set, [copyImageToClipboard] hands the encoded bytes here
/// instead of touching the Windows clipboard.
@visibleForTesting
Future<bool> Function(Uint8List encoded)? debugImageClipboardOverride;

/// Puts an image on the Windows clipboard so it can be pasted into chat
/// apps, Paint, Word and so on (reader-1 'Copy image').
///
/// [encoded] is any format Flutter can decode (JPEG, PNG, WebP, GIF...). The
/// clipboard gets two formats: CF_DIB (a 32-bit bitmap every Windows app
/// understands) and registered "PNG" (lossless, kept by Office and browsers).
/// Plain dart:ffi against user32/kernel32, so no plugin or native runner code
/// is needed. Returns false off Windows or when anything fails.
Future<bool> copyImageToClipboard(Uint8List encoded) async {
  final override = debugImageClipboardOverride;
  if (override != null) return override(encoded);
  if (!Platform.isWindows || encoded.isEmpty) return false;
  try {
    // Decode with the engine's codecs, the same ones the reader draws with.
    final codec = await ui.instantiateImageCodec(encoded);
    final frame = await codec.getNextFrame();
    codec.dispose();
    final image = frame.image;
    final width = image.width;
    final height = image.height;
    final rgba = await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (rgba == null) return false;
    // Reordering a big page's pixels takes a moment; keep it off the UI.
    final pixels = rgba.buffer.asUint8List();
    final dib = await Isolate.run(
      () => buildClipboardDib(pixels, width, height),
    );
    return _setClipboard(dib, png?.buffer.asUint8List());
  } catch (_) {
    return false;
  }
}

/// Builds a CF_DIB payload: a 40-byte BITMAPINFOHEADER followed by 32-bit
/// BGRA rows, bottom row first (a positive height means bottom-up).
/// [rgba] is straight RGBA, top row first, as Flutter's rawRgba gives it.
@visibleForTesting
Uint8List buildClipboardDib(Uint8List rgba, int width, int height) {
  const header = 40;
  final stride = width * 4;
  final out = Uint8List(header + stride * height);
  final h = ByteData.sublistView(out, 0, header)
    ..setUint32(0, header, Endian.little) // biSize
    ..setInt32(4, width, Endian.little) // biWidth
    ..setInt32(8, height, Endian.little) // biHeight (bottom-up)
    ..setUint16(12, 1, Endian.little) // biPlanes
    ..setUint16(14, 32, Endian.little) // biBitCount
    ..setUint32(16, 0, Endian.little) // biCompression = BI_RGB
    ..setUint32(20, stride * height, Endian.little); // biSizeImage
  assert(h.lengthInBytes == header);
  for (var y = 0; y < height; y++) {
    final src = y * stride;
    // Row y of the image lands at row (height - 1 - y) of the bitmap.
    final dst = header + (height - 1 - y) * stride;
    for (var x = 0; x < stride; x += 4) {
      out[dst + x] = rgba[src + x + 2]; // B
      out[dst + x + 1] = rgba[src + x + 1]; // G
      out[dst + x + 2] = rgba[src + x]; // R
      out[dst + x + 3] = rgba[src + x + 3]; // A
    }
  }
  return out;
}

// Win32 signatures used below.
typedef _OpenClipboardC = Int32 Function(Pointer<Void> hwnd);
typedef _OpenClipboardDart = int Function(Pointer<Void> hwnd);
typedef _VoidBoolC = Int32 Function();
typedef _VoidBoolDart = int Function();
typedef _SetClipboardDataC = Pointer<Void> Function(Uint32, Pointer<Void>);
typedef _SetClipboardDataDart = Pointer<Void> Function(int, Pointer<Void>);
typedef _RegisterFormatC = Uint32 Function(Pointer<Uint16>);
typedef _RegisterFormatDart = int Function(Pointer<Uint16>);
typedef _GlobalAllocC = Pointer<Void> Function(Uint32, IntPtr);
typedef _GlobalAllocDart = Pointer<Void> Function(int, int);
typedef _GlobalPtrC = Pointer<Void> Function(Pointer<Void>);
typedef _GlobalPtrDart = Pointer<Void> Function(Pointer<Void>);
typedef _GlobalUnlockC = Int32 Function(Pointer<Void>);
typedef _GlobalUnlockDart = int Function(Pointer<Void>);
typedef _HwndC = Pointer<Void> Function();
typedef _HwndDart = Pointer<Void> Function();
typedef _WindowPidC = Uint32 Function(Pointer<Void>, Pointer<Uint32>);
typedef _WindowPidDart = int Function(Pointer<Void>, Pointer<Uint32>);
typedef _CurrentPidC = Uint32 Function();
typedef _CurrentPidDart = int Function();

/// GMEM_MOVEABLE: clipboard data must be a moveable global handle.
const int _gmemMoveable = 0x0002;

/// CF_DIB standard clipboard format.
const int _cfDib = 8;

/// Opens the clipboard, replaces its contents with the bitmap (and PNG when
/// given) and closes it. Once SetClipboardData succeeds Windows owns the
/// memory, so only handles it refused are freed here.
bool _setClipboard(Uint8List dib, Uint8List? png) {
  final user32 = DynamicLibrary.open('user32.dll');
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final openClipboard = user32
      .lookupFunction<_OpenClipboardC, _OpenClipboardDart>('OpenClipboard');
  final emptyClipboard = user32.lookupFunction<_VoidBoolC, _VoidBoolDart>(
    'EmptyClipboard',
  );
  final closeClipboard = user32.lookupFunction<_VoidBoolC, _VoidBoolDart>(
    'CloseClipboard',
  );
  final setClipboardData = user32
      .lookupFunction<_SetClipboardDataC, _SetClipboardDataDart>(
        'SetClipboardData',
      );
  final registerFormat = user32
      .lookupFunction<_RegisterFormatC, _RegisterFormatDart>(
        'RegisterClipboardFormatW',
      );
  final globalAlloc = kernel32.lookupFunction<_GlobalAllocC, _GlobalAllocDart>(
    'GlobalAlloc',
  );
  final globalLock = kernel32.lookupFunction<_GlobalPtrC, _GlobalPtrDart>(
    'GlobalLock',
  );
  final globalUnlock = kernel32
      .lookupFunction<_GlobalUnlockC, _GlobalUnlockDart>('GlobalUnlock');
  final globalFree = kernel32.lookupFunction<_GlobalPtrC, _GlobalPtrDart>(
    'GlobalFree',
  );

  /// Copies [bytes] into a new moveable global block, or nullptr.
  Pointer<Void> toGlobal(Uint8List bytes) {
    final handle = globalAlloc(_gmemMoveable, bytes.length);
    if (handle == nullptr) return nullptr;
    final ptr = globalLock(handle);
    if (ptr == nullptr) {
      globalFree(handle);
      return nullptr;
    }
    ptr.cast<Uint8>().asTypedList(bytes.length).setAll(0, bytes);
    globalUnlock(handle);
    return handle;
  }

  // The clipboard owner: our own window when it is in front (it is, right
  // after a right-click in the reader). Win32 documents that EmptyClipboard
  // after OpenClipboard(NULL) leaves no owner and SetClipboardData may then
  // fail, so a real window is passed whenever one can be found.
  Pointer<Void> owner = nullptr;
  try {
    final foreground = user32.lookupFunction<_HwndC, _HwndDart>(
      'GetForegroundWindow',
    )();
    final windowPid = user32.lookupFunction<_WindowPidC, _WindowPidDart>(
      'GetWindowThreadProcessId',
    );
    final currentPid = kernel32.lookupFunction<_CurrentPidC, _CurrentPidDart>(
      'GetCurrentProcessId',
    );
    if (foreground != nullptr) {
      // GMEM_FIXED (0) returns a plain pointer for the out parameter.
      final pid = globalAlloc(0, 4);
      if (pid != nullptr) {
        windowPid(foreground, pid.cast<Uint32>());
        // Never hand another app's window to the clipboard as its owner.
        if (pid.cast<Uint32>().value == currentPid()) owner = foreground;
        globalFree(pid);
      }
    }
  } catch (_) {
    owner = nullptr;
  }

  // Another app may hold the clipboard for a moment; try a few times.
  var opened = false;
  for (var i = 0; i < 5 && !opened; i++) {
    opened = openClipboard(owner) != 0;
    if (!opened) sleep(const Duration(milliseconds: 20));
  }
  if (!opened) return false;
  try {
    if (emptyClipboard() == 0) return false;
    final dibHandle = toGlobal(dib);
    if (dibHandle == nullptr) return false;
    if (setClipboardData(_cfDib, dibHandle) == nullptr) {
      globalFree(dibHandle);
      return false;
    }
    if (png != null && png.isNotEmpty) {
      // "PNG" as a NUL-terminated UTF-16 string for RegisterClipboardFormatW.
      final name = toGlobal(
        Uint8List.fromList(const [0x50, 0, 0x4E, 0, 0x47, 0, 0, 0]),
      );
      if (name != nullptr) {
        final namePtr = globalLock(name).cast<Uint16>();
        final format = namePtr == nullptr ? 0 : registerFormat(namePtr);
        globalUnlock(name);
        globalFree(name);
        if (format != 0) {
          final pngHandle = toGlobal(png);
          if (pngHandle != nullptr &&
              setClipboardData(format, pngHandle) == nullptr) {
            globalFree(pngHandle);
          }
        }
      }
    }
    return true;
  } finally {
    closeClipboard();
  }
}
