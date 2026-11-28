import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../platform/app_paths.dart';
import '../platform/apple_tv.dart';

/// Image disk cache for [CachedNetworkImage].
///
/// On physical Apple TV, [DefaultCacheManager] uses sqflite under Application
/// Support (read-only on device) — poster art never loads and path_provider
/// logs errors. We store cache metadata in Caches via [JsonCacheInfoRepository].
class AppImageCache {
  AppImageCache._();

  static CacheManager? _tvManager;

  /// Windows desktop artwork disk cache, made on first use.
  static CacheManager? _desktopArtwork;

  /// Folder / index name of the Windows desktop artwork cache.
  static const desktopArtworkCacheKey = 'zangetsuDesktopImageCache';

  /// How many artwork files the Windows desktop artwork cache keeps. The
  /// shared default keeps only 200, which a Home page of preview plus
  /// full-size cards fills, so scrolling back downloaded the same art again.
  static const desktopArtworkMaxObjects = 1500;

  /// Call once during boot on Apple TV before any [CachedNetworkImage] mounts.
  static Future<void> init() async {
    if (!isAppleTv || _tvManager != null) return;
    final dir = await writableAppSubdir('image_cache');
    final index = File('${dir.path}/cache_index.json');
    _tvManager = CacheManager(
      Config(
        'zangetsuTvImageCache',
        stalePeriod: const Duration(days: 14),
        maxNrOfCacheObjects: 400,
        repo: JsonCacheInfoRepository.withFile(index),
      ),
    );
  }

  static CacheManager get manager {
    if (!isAppleTv) return DefaultCacheManager();
    final manager = _tvManager;
    if (manager == null) {
      throw StateError(
        'AppImageCache.init() must complete before TV UI mounts',
      );
    }
    return manager;
  }

  /// Disk cache for the Windows desktop artwork widgets only (desktop media
  /// cards, the Home banner and the desktop download library). It keeps
  /// [desktopArtworkMaxObjects] files for 30 days. Phone and TV never use it.
  static CacheManager get desktopArtworkManager =>
      _desktopArtwork ??= _DesktopArtworkCache();

  /// Pass to [CachedNetworkImage.cacheManager] / [CachedNetworkImageProvider].
  /// On Apple TV the default sqflite-backed cache is read-only — callers that
  /// omit this get empty/error images on device.
  static CacheManager? get cacheManagerOrDefault => isAppleTv ? manager : null;

  /// [ImageProvider] for network covers when not using [CachedNetworkImage].
  static CachedNetworkImageProvider imageProvider(
    String url, {
    Map<String, String>? headers,
    int? maxWidth,
    int? maxHeight,
  }) {
    return CachedNetworkImageProvider(
      url,
      headers: headers,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      cacheManager: cacheManagerOrDefault,
    );
  }
}

/// The Windows desktop artwork disk cache. It mixes in [ImageCacheManager] so
/// callers may still ask for resized files.
class _DesktopArtworkCache extends CacheManager with ImageCacheManager {
  _DesktopArtworkCache()
    : super(
        Config(
          AppImageCache.desktopArtworkCacheKey,
          stalePeriod: const Duration(days: 30),
          maxNrOfCacheObjects: AppImageCache.desktopArtworkMaxObjects,
        ),
      );
}
