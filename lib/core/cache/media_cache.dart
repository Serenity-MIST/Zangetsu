import 'dart:io';

import 'app_image_cache.dart';
import '../desktop/desktop_reveal.dart';
import '../desktop/desktop_storage.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The app-owned Windows cache folder under [root] (DesktopStorage.root):
/// `AppData\Temp`, where path_provider's temporary directory is routed (image
/// cache, subtitle/log/update temp files). Empty when [root] is unknown —
/// Windows must then measure and clear nothing rather than fall back to the
/// shared `%TEMP%` folder, which belongs to every other program on the PC.
List<String> windowsAppCacheDirs(String? root) =>
    root == null ? const [] : [p.join(root, 'AppData', 'Temp')];

/// Sizes and clears the app's transient media caches — the CachedNetworkImage
/// disk cache plus Flutter's in-memory image cache. It NEVER touches downloads,
/// Hive boxes, or any user data: `clear()` only empties the image cache manager
/// and the in-memory image cache, so offline downloads and settings are safe.
class MediaCache {
  const MediaCache._();

  /// Test hook: forces the Windows code path regardless of the host OS.
  @visibleForTesting
  static bool? debugIsWindows;

  static bool get _isWindows => debugIsWindows ?? Platform.isWindows;

  /// The folders this cache measures and clears. Windows only ever returns the
  /// app's own AppData folders (see [windowsAppCacheDirs]); elsewhere it is
  /// the OS cache dir, which is already private to the app.
  static Future<List<Directory>> _cacheDirs() async {
    if (_isWindows) {
      return [
        for (final path in windowsAppCacheDirs(DesktopStorage.root))
          Directory(path),
      ];
    }
    return [await getTemporaryDirectory()];
  }

  /// Approximate on-disk cache size in bytes (the app's temp/cache area, where
  /// the image cache lives). Read-only — safe to call anytime.
  static Future<int> sizeBytes() async {
    try {
      var total = 0;
      for (final dir in await _cacheDirs()) {
        total += await _dirSize(dir);
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// Clears the app's disposable caches: the CachedNetworkImage store, Flutter's
  /// in-memory image cache, AND everything else in the app's cache dir (native
  /// image/HTTP caches from Aniyomi/CloudStream, temp subtitle/backup/APK files).
  /// Downloads live in the DOCUMENTS dir (or the chosen download folder on
  /// Windows), so they are never touched. Files that are in use stay put.
  static Future<void> clear() async {
    // 1. CachedNetworkImage disk cache — clears its store index cleanly first.
    try {
      await AppImageCache.manager.emptyCache();
    } catch (_) {}
    try {
      await DefaultCacheManager().emptyCache();
    } catch (_) {}
    // 2. In-memory image cache.
    try {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    } catch (_) {}
    // 3. Remaining cache-dir contents (native caches are the bulk of the size).
    await clearDirectories(await _cacheDirs());
  }

  /// Deletes the contents of each of [dirs] (the folders themselves stay).
  /// Entries that cannot be deleted — usually files open in another part of
  /// the app — are skipped instead of failing the whole clear.
  @visibleForTesting
  static Future<void> clearDirectories(List<Directory> dirs) async {
    for (final dir in dirs) {
      try {
        if (!await dir.exists()) continue;
        await for (final e in dir.list(followLinks: false)) {
          try {
            await e.delete(recursive: true);
          } catch (_) {}
        }
      } catch (_) {}
    }
  }

  /// Windows: the poster/artwork disk cache folder flutter_cache_manager uses
  /// (`<temp>\libCachedImageData`, inside the app-owned AppData\Temp), or
  /// null when the app data folder is unknown.
  static Directory? get windowsImageCacheDir {
    final dirs = windowsAppCacheDirs(DesktopStorage.root);
    if (dirs.isEmpty) return null;
    return Directory(p.join(dirs.first, DefaultCacheManager.key));
  }

  /// Windows: bytes used by the poster/artwork disk caches (0 when unknown).
  /// This counts both the shared cache folder and the larger desktop artwork
  /// cache used by the Windows cards.
  static Future<int> imageCacheBytes() async {
    var total = 0;
    for (final dir in _windowsImageCacheDirs) {
      total += await _dirSize(dir);
    }
    return total;
  }

  /// Windows: the shared artwork folder plus the desktop artwork folder
  /// (`<temp>\zangetsuDesktopImageCache`), or empty when the folder is unknown.
  static List<Directory> get _windowsImageCacheDirs {
    final shared = windowsImageCacheDir;
    if (shared == null) return const [];
    return [
      shared,
      Directory(
        p.join(shared.parent.path, AppImageCache.desktopArtworkCacheKey),
      ),
    ];
  }

  /// Clears only the poster/artwork caches (disk + memory). On Windows the
  /// cache folder is also emptied afterwards, so files the cache index no
  /// longer tracks are freed too and the size shown afterwards is accurate.
  static Future<void> clearImageCache() async {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    try {
      await AppImageCache.manager.emptyCache();
    } catch (_) {}
    if (_isWindows) {
      // The Windows cards keep their own larger artwork cache; empty it too.
      try {
        await AppImageCache.desktopArtworkManager.emptyCache();
      } catch (_) {}
      await clearDirectories(_windowsImageCacheDirs);
    }
  }

  /// Windows: the app's own data folder (AppData), or null when unknown.
  static String? get appDataFolder => DesktopStorage.root;

  /// Windows: opens the app's data folder in File Explorer. False when the
  /// folder is unknown or missing.
  static Future<bool> openAppDataFolder() async {
    final root = appDataFolder;
    if (root == null) return false;
    return revealInExplorer(root);
  }

  static Future<int> _dirSize(Directory dir) async {
    var total = 0;
    try {
      if (!await dir.exists()) return 0;
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is File) {
          try {
            total += await e.length();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return total;
  }

  /// Size of one folder's files in bytes, exposed for tests.
  @visibleForTesting
  static Future<int> directorySize(Directory dir) => _dirSize(dir);

  /// Human-readable size, e.g. "4.8 MB" / "512 KB" / "0 B".
  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
