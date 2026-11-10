import 'dart:io';
import '../../core/desktop/desktop_storage.dart';
import 'dart:math' as math;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/ui/artwork_quality.dart';
import '../../core/ui/progressive_artwork.dart';

/// Artwork can be hosted elsewhere than a provider's cover. Never forward its
/// cookies/authorization to a different origin, including a different port.
Map<String, String>? downloadArtworkHeaders(String imageUrl, String? coverUrl,
    Map<String, String>? headers) {
  if (headers == null) return null;
  final image = Uri.tryParse(imageUrl), cover = Uri.tryParse(coverUrl ?? '');
  final same = image != null && cover != null && image.host.isNotEmpty &&
      image.host == cover.host && image.scheme == cover.scheme && image.port == cover.port;
  return Map.fromEntries(headers.entries.where((e) => same ||
      !const ['cookie', 'authorization', 'proxy-authorization'].contains(e.key.toLowerCase())));
}

/// Persisted thumbnail first, then its poster/icon fallback. Known CDNs load a
/// small variant before the full artwork; decode size follows actual DPI.
class DownloadThumbnail extends StatelessWidget {
  const DownloadThumbnail({super.key, this.thumbnail, this.cover, this.headers,
    required this.fallback});
  final String? thumbnail;
  final String? cover;
  final Map<String, String>? headers;
  final Widget fallback;

  @override Widget build(BuildContext context) {
    final image = thumbnail?.isNotEmpty == true ? thumbnail : cover;
    if (image == null || image.isEmpty) return fallback;
    return ClipRRect(borderRadius: BorderRadius.circular(8), child: LayoutBuilder(
      builder: (context, box) {
        final decode = artworkDecodeWidth(box.maxWidth, MediaQuery.devicePixelRatioOf(context));
        Widget poster = fallback;
        if (cover?.isNotEmpty == true && image != cover) {
          poster = CachedNetworkImage(imageUrl: cover!, httpHeaders: headers, fit: BoxFit.cover,
            memCacheWidth: decode, placeholder: (_, _) => fallback, errorWidget: (_, _, _) => fallback);
        }
        final local=Uri.tryParse(image);
        if (local?.scheme=='file') {
          return Image.file(File(DesktopStorage.relocatedAppPath(File.fromUri(local!).path)),
            fit:BoxFit.cover,cacheWidth:decode,errorBuilder:(_,_,_)=>poster);
        }
        final scoped = downloadArtworkHeaders(image, cover, headers);
        return ProgressiveArtwork(
          preview: ResizeImage(CachedNetworkImageProvider(artworkPreviewUrl(image), headers: scoped),
            width: math.min(96, decode)),
          full: ResizeImage(CachedNetworkImageProvider(image, headers: scoped), width: decode),
          fallback: poster);
      }));
  }
}
