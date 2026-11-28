import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'desktop_memory.dart';

/// Decoded-image budget for 8 GB (or unknown) Windows PCs: a little above the
/// shared 80 MB so a Home page of sharp high-DPI cards fits, while still
/// keeping a low-memory laptop away from paging.
const desktopImageCacheBytesLowMemory = 96 << 20;

/// Decoded-image budget for Windows PCs with more than 8 GB.
const desktopImageCacheBytesHighMemory = 192 << 20;

/// How many decoded images the Windows cache may hold. The shared 300 ran out
/// after roughly one Home page of cards, so going back up a page decoded
/// every poster again.
const desktopImageCacheCountLowMemory = 500;
const desktopImageCacheCountHighMemory = 800;

/// Keeps the minimise listener alive for the whole session.
AppLifecycleListener? _minimiseListener;

/// Windows only (called from main behind Platform.isWindows): sizes the image
/// cache from the installed memory and empties the reusable part of it while
/// the window is minimised, so a minimised app gives memory back. With more
/// than 8 GB that only happens after ten minutes, so a quick look at another
/// window does not mean every poster is decoded again on return. Images that
/// are on screen are never thrown away by this.
Future<void> applyDesktopImageCacheBudget() async {
  final memory = await DesktopMemory.load();
  final cache = PaintingBinding.instance.imageCache;
  final roomy = memory > DesktopMemory.lowMemoryLimitMb;
  cache.maximumSizeBytes = roomy
      ? desktopImageCacheBytesHighMemory
      : desktopImageCacheBytesLowMemory;
  cache.maximumSize = roomy
      ? desktopImageCacheCountHighMemory
      : desktopImageCacheCountLowMemory;
  final clearer = DesktopMinimisedImageClearer(roomy: roomy);
  _minimiseListener ??= AppLifecycleListener(
    // Windows reports "hidden" when the window is minimised.
    onHide: clearer.hidden,
    onShow: clearer.shown,
    onResume: clearer.shown,
  );
}

/// Empties the image cache for a minimised window: at once on PCs with 8 GB
/// (or unknown) memory, and only after [delay] on roomier ones.
class DesktopMinimisedImageClearer {
  DesktopMinimisedImageClearer({
    required this.roomy,
    this.delay = const Duration(minutes: 10),
  });

  final bool roomy;
  final Duration delay;
  Timer? _timer;

  void hidden() {
    if (!roomy) return _clear();
    _timer?.cancel();
    _timer = Timer(delay, _clear);
  }

  void shown() {
    _timer?.cancel();
    _timer = null;
  }

  // clear() only drops images nothing is showing; live ones stay.
  void _clear() => PaintingBinding.instance.imageCache.clear();
}

/// Widest the full-width Home banner is decoded, in pixels.
///
/// A 3840 px 16:9 backdrop takes about 33 MB once decoded, a third of the
/// 96 MB budget an 8 GB (or unknown-size) Windows PC gets, so every banner
/// rotation would push several shelves of posters out of the cache and they
/// would be decoded again (a stutter) on the way back. Those PCs decode the
/// banner at 2560 px instead (about 15 MB): still sharp on 1440p and only
/// slightly softer on a full-screen 4K window. PCs with more memory, and
/// every other platform, keep 3840.
int desktopBannerDecodeWidth() {
  final lighter =
      defaultTargetPlatform == TargetPlatform.windows &&
      DesktopMemory.systemMemoryMb <= DesktopMemory.lowMemoryLimitMb;
  return lighter ? 2560 : 3840;
}
