import 'dart:io';
import '../../core/desktop/desktop_storage.dart';
import 'dart:math' as math;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/boot_network.dart';
import '../../core/download/download_folder_sync.dart';
import '../../core/download/download_prefs.dart' show isUriPath;
import '../../core/download/download_record.dart';
import '../../core/download/folder_manifest.dart';
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

/// `<folder>/.zangetsu` of a saved episode, or null when it has no file on
/// this PC (not finished yet, or a phone-style content:// link).
Directory? _savedMetaDir(DownloadRecord record) {
  final path = record.filePath;
  if (path == null || path.isEmpty || isUriPath(path)) return null;
  try {
    final folder = Directory(p.dirname(DesktopStorage.relocatedAppPath(path)));
    return FolderManifestStore.metaDir(folder);
  } catch (_) {
    return null;
  }
}

/// Windows: the pictures a saved episode keeps next to its file, best first:
/// its own still (`.zangetsu/art/ep-<key>.png`, left out with [still] false)
/// and then the show poster (`.zangetsu/art/poster.png`). Plain paths; they
/// are not checked here, a missing one simply fails to open and the next one
/// is tried. Empty when the episode has no file on this PC.
List<String> downloadSavedArtPaths(DownloadRecord record, {bool still = true}) {
  final meta = _savedMetaDir(record);
  if (meta == null) return const [];
  String inside(String relative) => p.joinAll([meta.path, ...relative.split('/')]);
  return [
    if (still)
      inside(DownloadFolderSync.episodeThumbnailPath(
          DownloadFolderSync.episodeKey(record))),
    inside(DownloadFolderSync.posterPath),
  ];
}

/// Windows: the saved show posters of [records], one per download folder
/// (seasons can sit in different folders), newest records first, at most
/// [max] so a long show never tries dozens of files. Finished episodes come
/// first because their folder is the most likely to still be there.
List<String> downloadSavedPosterPaths(Iterable<DownloadRecord> records,
    {int max = 3}) {
  final ordered = [
    ...records.where((r) => r.status == DownloadStatus.done),
    ...records.where((r) => r.status != DownloadStatus.done),
  ];
  final seen = <String>{};
  final out = <String>[];
  for (final r in ordered) {
    if (out.length >= max) break;
    final paths = downloadSavedArtPaths(r, still: false);
    if (paths.isEmpty) continue;
    if (seen.add(p.normalize(paths.single).toLowerCase())) out.add(paths.single);
  }
  return out;
}

/// The first of [paths] that opens, drawn from disk; when one is missing or
/// broken the next is tried, and [fallback] shows after the last. A file is
/// only read once the one before it failed. Works with no network at all.
class SavedArtwork extends StatelessWidget {
  const SavedArtwork({super.key, required this.paths, required this.fallback,
    this.decodeWidth, this.fitWhole = false});
  final List<String> paths;
  final Widget fallback;

  /// Width the picture is decoded at; null decodes it at its own size.
  final int? decodeWidth;

  /// Windows cards: show a picture of another shape whole (see
  /// [ProgressiveArtwork.fitWhole]).
  final bool fitWhole;

  @override
  Widget build(BuildContext context) {
    if (paths.isEmpty) return fallback;
    return ProgressiveArtwork(
      key: ValueKey('saved-art:${paths.first}'),
      preview: ResizeImage.resizeIfNeeded(decodeWidth, null, FileImage(File(paths.first))),
      full: null,
      fitWhole: fitWhole,
      fallback: SavedArtwork(paths: paths.sublist(1), fallback: fallback,
        decodeWidth: decodeWidth, fitWhole: fitWhole));
  }
}

/// True while the app knows it is offline (the title bar's Offline pill).
/// Pictures that have a saved copy then open that copy at once instead of
/// waiting for the web picture to fail.
ValueListenable<bool> get downloadArtworkOffline => BootConnectivity.instance.offline;

/// Persisted thumbnail first, then its poster/icon fallback. Known CDNs load a
/// small variant before the full artwork; decode size follows actual DPI.
///
/// Windows: [saved] lists the pictures kept next to the downloaded file (see
/// [downloadSavedArtPaths]). They show when the web picture fails, and at
/// once while the app is offline. Once a row was drawn offline it keeps the
/// saved picture, so the network coming back never swaps it under the user.
class DownloadThumbnail extends StatefulWidget {
  const DownloadThumbnail({super.key, this.thumbnail, this.cover, this.headers,
    this.saved = const [], required this.fallback});
  final String? thumbnail;
  final String? cover;
  final Map<String, String>? headers;
  final List<String> saved;
  final Widget fallback;

  @override
  State<DownloadThumbnail> createState() => _DownloadThumbnailState();
}

class _DownloadThumbnailState extends State<DownloadThumbnail> {
  /// Set once this row was drawn while offline (see the class comment).
  bool _preferSaved = false;

  @override
  Widget build(BuildContext context) {
    final saved = widget.saved;
    if (saved.isEmpty) return _picture(context, preferSaved: false);
    return ValueListenableBuilder<bool>(
      valueListenable: downloadArtworkOffline,
      builder: (context, offline, _) {
        if (offline) _preferSaved = true;
        return _picture(context, preferSaved: _preferSaved);
      });
  }

  Widget _picture(BuildContext context, {required bool preferSaved}) {
    final cover = widget.cover, headers = widget.headers, saved = widget.saved;
    final image = widget.thumbnail?.isNotEmpty == true ? widget.thumbnail : cover;
    if (image == null || image.isEmpty) {
      if (saved.isEmpty) return widget.fallback;
      return ClipRRect(borderRadius: BorderRadius.circular(8),
        child: SavedArtwork(paths: saved, fallback: widget.fallback));
    }
    return ClipRRect(borderRadius: BorderRadius.circular(8), child: LayoutBuilder(
      builder: (context, box) {
        // Windows decodes at exactly the real screen pixels (no extra margin,
        // these tiles never grow on hover); other platforms keep their width.
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final decode = defaultTargetPlatform == TargetPlatform.windows
            ? desktopArtworkDecodeWidth(box.maxWidth, dpr)
            : artworkDecodeWidth(box.maxWidth, dpr);
        // Each picture shows [next] when it cannot be loaded.
        Widget coverOr(Widget next) => cover?.isNotEmpty == true && image != cover
            ? CachedNetworkImage(imageUrl: cover!, httpHeaders: headers, fit: BoxFit.cover,
                memCacheWidth: decode, placeholder: (_, _) => widget.fallback,
                errorWidget: (_, _, _) => next)
            : next;
        Widget savedOr(Widget next) =>
            SavedArtwork(paths: saved, fallback: next, decodeWidth: decode);
        // Online: thumbnail, cover, saved pictures, icon. Offline (or drawn
        // offline before): the saved pictures come before any web picture,
        // which may still be in the image cache, so they are kept after.
        final local = Uri.tryParse(image);
        if (local?.scheme == 'file') {
          final next = preferSaved ? savedOr(coverOr(widget.fallback))
              : coverOr(savedOr(widget.fallback));
          return Image.file(File(DesktopStorage.relocatedAppPath(File.fromUri(local!).path)),
            fit:BoxFit.cover,cacheWidth:decode,errorBuilder:(_,_,_)=>next);
        }
        final scoped = downloadArtworkHeaders(image, cover, headers);
        Widget webOr(Widget next) => ProgressiveArtwork(
          preview: ResizeImage(CachedNetworkImageProvider(artworkPreviewUrl(image), headers: scoped),
            width: math.min(96, decode)),
          full: ResizeImage(CachedNetworkImageProvider(image, headers: scoped), width: decode),
          fallback: next);
        return preferSaved ? savedOr(webOr(coverOr(widget.fallback)))
            : webOr(coverOr(savedOr(widget.fallback)));
      }));
  }
}
