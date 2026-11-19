// Windows: the downloaded show's full metadata and images kept inside each
// download folder (`<show folder>/.zangetsu/details.json` + `art/`), so the
// downloaded show page renders like the online page with no network.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../logging/app_logger.dart';
import '../models/episode.dart';
import '../models/media_detail.dart';
import 'download_folder_sync.dart';
import 'download_record.dart';
import 'downloaded_show_details.dart';
import 'folder_manifest.dart';

/// Writes and reads `.zangetsu/details.json` and the images it points to.
///
/// `details.json` holds `{created_by, version, source_id, show_id, detail, art}`
/// where `detail` is [DownloadedShowDetails.encode] (every Details field and
/// every episode of the show) and `art` lists the saved images relative to
/// `.zangetsu`: the cover (`art/poster.png`, shared with the folder
/// manifest), the banner (`art/banner.png`) and one JPEG per episode
/// thumbnail (`art/meta/<hash>.jpg`).
///
/// Only folders that already have a manifest are written to: the manifest's
/// cleanup (DownloadFolderSync.onFileDeleted) removes the whole `.zangetsu`
/// folder with the last episode, so nothing written here is left behind.
/// Images that already exist are never fetched again, so re-runs are cheap.
/// Nothing here throws; every failure is logged and skipped.
class DownloadedShowArtwork {
  DownloadedShowArtwork({
    DownloadFolderSync? sync,
    this.episodeSide = 480,
    this.bannerSide = 1280,
    this.parallel = 3,
    this.maxEpisodeImages = 2000,
  }) : _sync = sync ?? DownloadFolderSync();

  /// Image fetch + resize + atomic write, shared with the folder manifest.
  final DownloadFolderSync _sync;

  /// Longest side of a saved episode thumbnail (rows are 116-320 px wide).
  final int episodeSide;

  /// Longest side of the saved banner (the wide header card).
  final int bannerSide;

  /// Episode thumbnails fetched at the same time, at most.
  final int parallel;

  /// Upper bound of episode thumbnails saved per folder (very long shows).
  final int maxEpisodeImages;

  /// File name inside `.zangetsu`.
  static const fileName = 'details.json';

  /// The name earlier builds used. Still read, and replaced by [fileName]
  /// the next time the folder's details are saved.
  static const legacyFileName = 'show.json';

  /// Format version written; files from a newer version are not read.
  static const version = 1;

  /// Marker that the file is ours.
  static const createdBy = 'Zangetsu';

  /// Saved image locations, relative to `.zangetsu`, forward slashes.
  static const coverPath = DownloadFolderSync.posterPath;
  static const bannerPath = 'art/banner.png';
  static const episodeDir = 'art/meta';

  /// Stable per-episode image name (season + id hashed: ids can be URLs).
  static String episodeArtPath(Episode e) =>
      '$episodeDir/${sha1.convert(utf8.encode('${e.season ?? 0}:${e.id}'))}.jpg';

  /// Key of an episode inside the `art.episodes` map.
  static String episodeKey(Episode e) => '${e.season ?? 0}:${e.id}';

  /// `<folder>/.zangetsu/details.json`.
  static File showFile(Directory folder) =>
      File(p.join(FolderManifestStore.metaDir(folder).path, fileName));

  /// `<folder>/.zangetsu/show.json` from earlier builds.
  static File legacyShowFile(Directory folder) =>
      File(p.join(FolderManifestStore.metaDir(folder).path, legacyFileName));

  /// The folder's details text: details.json, else the older show.json.
  static Future<String?> _readCurrentOrLegacy(Directory folder) async =>
      await _readText(showFile(folder)) ??
      await _readText(legacyShowFile(folder));

  /// Per-folder write chain, so two saves never write the same folder at once.
  static final Map<String, Future<void>> _locks = {};

  /// Remote images that failed this session; not retried until restart.
  static final Set<String> _failed = {};

  /// The distinct folders of the finished, on-disk downloads in [records].
  static List<Directory> foldersOf(Iterable<DownloadRecord> records) {
    final seen = <String>{};
    final out = <Directory>[];
    for (final r in records) {
      if (r.status != DownloadStatus.done) continue;
      final folder = DownloadFolderSync.folderOf(r);
      if (folder == null) continue;
      if (seen.add(p.normalize(folder.path).toLowerCase())) out.add(folder);
    }
    return out;
  }

  // ── Write ────────────────────────────────────────────────────────────────

  /// Writes [detail] and its images into every folder of [records]. A folder
  /// whose `details.json` belongs to another show is left alone.
  Future<void> mirror(
    MediaDetail detail, {
    required String sourceId,
    required String showId,
    required Iterable<DownloadRecord> records,
    bool Function()? canceled,
  }) async {
    for (final folder in foldersOf(records)) {
      // [canceled] (the download manager shut down) stops before the next
      // folder, so no new file is opened in a folder after shutdown.
      if (canceled?.call() ?? false) return;
      await _serial(
        folder.path,
        () => _mirrorInto(folder, detail, sourceId, showId),
      );
    }
  }

  Future<void> _mirrorInto(
    Directory folder,
    MediaDetail detail,
    String sourceId,
    String showId,
  ) async {
    try {
      // Only folders the manifest owns (see the class comment).
      if (!await FolderManifestStore.hasManifest(folder)) return;
      final file = showFile(folder);
      final legacy = legacyShowFile(folder);
      // An older folder only has show.json: compare against it, so the
      // first save writes details.json and then removes the old name.
      final before = await _readCurrentOrLegacy(folder);
      final hasCurrent = await file.exists();
      final existing = before == null ? null : _parse(before);
      if (existing != null && !_sameShow(existing, sourceId, showId)) return;

      final headers = detail.coverHeaders;
      final cover = _remote(detail.cover);
      final banner = _remote(detail.banner);
      final art = <String, Object>{};
      if (await _ensure(folder, coverPath, cover, cover, headers, null)) {
        art['cover'] = coverPath;
      }
      if (await _ensure(
        folder,
        bannerPath,
        banner,
        cover,
        headers,
        bannerSide,
      )) {
        art['banner'] = bannerPath;
      }

      // Every episode's thumbnail (not just the downloaded ones), a few at a
      // time. Skips thumbnails that are only the show's cover/banner.
      final episodes = <String, String>{};
      final wanted = [
        for (final e in detail.episodes)
          if (_remote(e.thumbnail) case final url?)
            if (url != detail.cover && url != detail.banner) (e, url),
      ].take(maxEpisodeImages).toList();
      for (var i = 0; i < wanted.length; i += parallel) {
        final batch = wanted.skip(i).take(parallel).toList();
        final saved = await Future.wait([
          for (final (e, url) in batch)
            _ensure(
              folder,
              episodeArtPath(e),
              url,
              cover,
              headers,
              episodeSide,
              jpeg: true,
            ),
        ]);
        for (var j = 0; j < batch.length; j++) {
          if (saved[j]) {
            episodes[episodeKey(batch[j].$1)] = episodeArtPath(batch[j].$1);
          }
        }
      }
      if (episodes.isNotEmpty) art['episodes'] = episodes;

      final text = const JsonEncoder.withIndent('  ').convert({
        'created_by': createdBy,
        'version': version,
        'source_id': sourceId,
        'show_id': showId,
        'detail': DownloadedShowDetails.encode(detail),
        'art': art,
      });
      // Nothing new and already under the current name: no write.
      if (text == before && hasCurrent) return;
      await file.parent.create(recursive: true);
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(text, flush: true);
      await temp.rename(file.path);
      // details.json is in place: drop the old show.json so the folder
      // keeps one details file.
      if (await legacy.exists()) await legacy.delete();
    } catch (e) {
      AppLogger.instance.log('[show-meta] ${folder.path}: $e');
    }
  }

  /// True when [relative] is saved (fetching [url] first when it is not).
  Future<bool> _ensure(
    Directory folder,
    String relative,
    String? url,
    String? coverUrl,
    Map<String, String>? headers,
    int? maxSide, {
    bool jpeg = false,
  }) async {
    if (await _sync.hasImage(folder, relative)) return true;
    if (url == null || _failed.contains(url)) return false;
    final ok = await _sync.saveImage(
      folder,
      relative,
      url,
      coverUrl: coverUrl,
      coverHeaders: headers,
      maxSide: maxSide,
      jpeg: jpeg,
    );
    if (!ok) _failed.add(url);
    return ok;
  }

  // ── Read ─────────────────────────────────────────────────────────────────

  /// The detail saved in the first folder of [records] with a valid
  /// `details.json` for this show, or null. Remote image URLs are kept; call
  /// [localize] to point them at the saved files.
  Future<MediaDetail?> readSaved(
    Iterable<DownloadRecord> records, {
    required String sourceId,
    required String showId,
  }) async {
    for (final folder in foldersOf(records)) {
      final json = await _readJson(folder);
      if (json == null || !_sameShow(json, sourceId, showId)) continue;
      final detail = DownloadedShowDetails.decode(json['detail']);
      if (detail != null) return detail;
    }
    return null;
  }

  /// [detail] with its cover, banner and episode thumbnails pointing at the
  /// images saved in the folders of [records] (`file:` URIs), wherever such a
  /// file exists. Also uses the thumbnail the folder manifest saved for each
  /// downloaded episode. Paths from `details.json` go through
  /// [FolderManifestStore.resolveInside], so a hostile file cannot point
  /// outside its `.zangetsu` folder.
  Future<MediaDetail> localize(
    MediaDetail detail,
    Iterable<DownloadRecord> records, {
    required String sourceId,
    required String showId,
  }) async {
    try {
      String? cover, banner;
      final thumbs = <String, String>{};
      final folders = foldersOf(records);
      for (final folder in folders) {
        final meta = FolderManifestStore.metaDir(folder).path;
        if (!await Directory(meta).exists()) continue;
        final files = await _listFiles(meta);
        // A local path for [relative], or null when missing or unsafe.
        String? local(Object? relative) {
          if (relative is! String) return null;
          final path = FolderManifestStore.resolveInside(meta, relative);
          if (path == null || !files.contains(_norm(path))) return null;
          return Uri.file(path).toString();
        }

        final json = await _readJson(folder);
        final art = json != null && _sameShow(json, sourceId, showId)
            ? json['art']
            : null;
        final map = art is Map ? art : const {};
        cover ??= local(map['cover']) ?? local(coverPath);
        banner ??= local(map['banner']) ?? local(bannerPath);
        final listed = map['episodes'];
        for (final e in detail.episodes) {
          final key = episodeKey(e);
          if (thumbs.containsKey(key)) continue;
          final path =
              (listed is Map ? local(listed[key]) : null) ??
              local(episodeArtPath(e));
          if (path != null) thumbs[key] = path;
        }
        // Downloaded episodes: the thumbnail (or video frame) the folder
        // manifest saved, when no metadata image exists for them.
        for (final r in records) {
          if (DownloadFolderSync.folderOf(r)?.path != folder.path) continue;
          final key = '${r.season ?? 0}:${r.episodeId}';
          if (thumbs.containsKey(key)) continue;
          final path = local(
            DownloadFolderSync.episodeThumbnailPath(
              DownloadFolderSync.episodeKey(r),
            ),
          );
          if (path != null) thumbs[key] = path;
        }
      }
      if (cover == null && banner == null && thumbs.isEmpty) return detail;
      // Local image for one episode: its own saved thumbnail, else the local
      // cover/banner when the source only reused the show art as thumbnail.
      String? thumbFor(Episode e) {
        final own = thumbs[episodeKey(e)];
        if (own != null) return own;
        final t = e.thumbnail;
        if (t == null) return null;
        if (t == detail.cover) return cover;
        if (t == detail.banner) return banner;
        return null;
      }

      return detail.copyWith(
        cover: cover,
        banner: banner,
        episodes: [
          for (final e in detail.episodes)
            if (thumbFor(e) case final local?)
              e.copyWith(thumbnail: local)
            else
              e,
        ],
      );
    } catch (e) {
      AppLogger.instance.log('[show-meta] localize failed: $e');
      return detail;
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  /// The parsed `details.json` (or older `show.json`) of [folder] when it
  /// is a valid one of ours.
  Future<Map<String, dynamic>?> _readJson(Directory folder) async {
    final text = await _readCurrentOrLegacy(folder);
    return text == null ? null : _parse(text);
  }

  /// [file]'s text, or null when missing, unreadable or absurdly large.
  static Future<String?> _readText(File file) async {
    try {
      if (!await file.exists()) return null;
      if (await file.length() > 32 * 1024 * 1024) return null;
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  /// Validates the header of a `details.json` text.
  static Map<String, dynamic>? _parse(String text) {
    try {
      final json = jsonDecode(text);
      if (json is! Map) return null;
      final map = json.cast<String, dynamic>();
      final v = map['version'];
      if (map['created_by'] != createdBy || v is! int || v > version) {
        return null;
      }
      return map;
    } catch (_) {
      return null;
    }
  }

  /// True when the file describes [sourceId] / [showId].
  static bool _sameShow(
    Map<String, dynamic> json,
    String sourceId,
    String showId,
  ) => json['source_id'] == sourceId && json['show_id'] == showId;

  /// [url] when it is a remote http(s) image, else null.
  static String? _remote(String? url) {
    final v = url?.trim();
    if (v == null || v.isEmpty) return null;
    final scheme = Uri.tryParse(v)?.scheme;
    return scheme == 'http' || scheme == 'https' ? v : null;
  }

  /// Every file under [dir] (normalised, lower-case), so many existence
  /// checks cost one directory walk.
  static Future<Set<String>> _listFiles(String dir) async {
    final out = <String>{};
    try {
      await for (final entity in Directory(dir).list(recursive: true)) {
        if (entity is File) out.add(_norm(entity.path));
      }
    } catch (_) {}
    return out;
  }

  static String _norm(String path) => p.normalize(path).toLowerCase();

  /// Runs [job] after the previous job for the same [key] finished.
  static Future<void> _serial(String key, Future<void> Function() job) {
    final previous = _locks[key] ?? Future<void>.value();
    final result = previous.then((_) => job());
    final tail = result.then<void>((_) {}, onError: (Object _) {});
    _locks[key] = tail;
    tail.then((_) {
      if (identical(_locks[key], tail)) _locks.remove(key);
    });
    return result;
  }
}
