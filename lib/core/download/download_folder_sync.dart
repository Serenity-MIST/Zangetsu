import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../logging/app_logger.dart';
import 'download_record.dart';
import '../playback/skip_service.dart' show SkipInterval;
import 'folder_manifest.dart';
import 'subtitle_sidecars.dart';

/// Fetches an image and returns its raw bytes, or null on any failure.
typedef ArtworkFetcher =
    Future<Uint8List?> Function(Uri url, Map<String, String>? headers);

/// Returns a `file:` URI (or path) of a frame taken from a saved video, or null.
typedef FrameExtractor = Future<String?> Function(String mediaPath);

/// Keeps each downloaded show folder's portable identity up to date.
///
/// After a download finishes it records the show, the episode, its subtitles
/// and the catalogue ids in `<show folder>/.zangetsu/metadata.json`, and saves
/// the poster and episode thumbnail as PNG files beside it. Because everything
/// lives inside the folder, moving the folder keeps its metadata and deleting
/// it removes the metadata with it.
///
/// This class only ever adds files inside `.zangetsu`. It never moves, renames
/// or deletes media, and every failure is logged and swallowed so a metadata
/// problem can never break a download.
class DownloadFolderSync {
  DownloadFolderSync({
    FolderManifestStore? store,
    ArtworkFetcher? fetchArtwork,
    this.extractFrame,
    this.lookupSkips,
    this.maxArtworkSide = 1280,
    bool Function()? canceled,
  }) : _store = store ?? FolderManifestStore(),
       _fetch = fetchArtwork ?? _httpFetch,
       _canceled = canceled ?? _never;

  final FolderManifestStore _store;
  final ArtworkFetcher _fetch;

  /// True once the owner (the download manager) has been disposed. Checked
  /// before every disk step so no new file in a show folder is opened after
  /// shutdown; otherwise a late write could keep the folder locked on Windows.
  final bool Function() _canceled;
  static bool _never() => false;

  /// Optional video-frame extractor used when no artwork URL is available.
  final FrameExtractor? extractFrame;

  /// Optional intro/outro lookup (title, episode) saved into the manifest so
  /// Skip works offline. Null in tests: no network.
  final Future<List<SkipInterval>> Function(String title, int episode)?
  lookupSkips;

  /// Longest side, in pixels, that saved artwork is scaled down to.
  final int maxArtworkSide;

  /// Folder-relative locations inside `.zangetsu`, always with forward slashes.
  static const posterPath = 'art/poster.png';
  static String episodeThumbnailPath(String key) => 'art/ep-$key.png';

  /// The folder a finished video lives in, or null when [record] has no file.
  static Directory? folderOf(DownloadRecord record) {
    final path = record.filePath;
    if (path == null || path.isEmpty) return null;
    return Directory(p.dirname(path));
  }

  /// Stable identity of a saved episode: the download tag embedded in the app's
  /// file names, or a hash of the record id for files named some other way.
  static String episodeKey(DownloadRecord record) {
    final name = p.basename(record.filePath ?? '');
    final tag = RegExp(r'_([a-f0-9]{32})\.[A-Za-z0-9]+$').firstMatch(name);
    if (tag != null) return tag.group(1)!;
    return sha256.convert(utf8.encode(record.id)).toString().substring(0, 32);
  }

  /// Records a finished download in its folder's manifest and saves artwork.
  /// Safe to call without awaiting: it never throws.
  Future<void> onDone(DownloadRecord record) async {
    try {
      if (record.status != DownloadStatus.done || _canceled()) return;
      final folder = folderOf(record);
      if (folder == null || !await File(record.filePath!).exists()) return;
      if (_canceled()) return;
      await _writeManifest(folder, record);
      // Artwork can take a while (network, frame extraction): stop if the
      // owner shut down meanwhile.
      if (_canceled()) return;
      await _ensureArtwork(folder, record);
    } catch (e) {
      AppLogger.instance.log('[folder-manifest] ${record.showTitle}: $e');
    }
  }

  /// Adds manifests to downloads made before this feature existed. Purely
  /// additive: it writes only inside `.zangetsu` and skips episodes already
  /// listed. Returns how many episodes were added.
  Future<int> upgradeExisting(Iterable<DownloadRecord> records) async {
    var added = 0;
    for (final record in records) {
      // Owner disposed: leave the remaining folders for the next session.
      if (_canceled()) break;
      try {
        if (record.status != DownloadStatus.done || record.isTorrent) continue;
        final folder = folderOf(record);
        if (folder == null || !await File(record.filePath!).exists()) continue;
        final current = await _store.read(folder);
        final key = episodeKey(record);
        // Already described: leave it. Artwork that could not be fetched then
        // is not retried on every launch (that would hit the network each time).
        final listed = current?.episodes.where((e) => e.key == key).firstOrNull;
        if (listed != null) {
          // The one exception: an entry written without subtitles while
          // subtitle files exist in this folder. Rewrite only the manifest,
          // never artwork, so the repair cannot reach the network. Only when it
          // would really add something, so it cannot repeat every launch.
          final repairable =
              listed.subtitles.isEmpty &&
              playableSubtitlesFor(
                record,
              ).any((s) => _relativeInside(folder, s.path) != null);
          if (!repairable) continue;
          await _writeManifest(folder, record);
          added++;
          continue;
        }
        await onDone(record);
        added++;
      } catch (e) {
        AppLogger.instance.log('[folder-manifest] upgrade failed: $e');
      }
    }
    return added;
  }

  /// Call after a saved video was deleted. Drops that episode (and its
  /// thumbnail) from the manifest, and when no listed episode file remains on
  /// disk, deletes the whole `.zangetsu` folder so the now-empty show folder can
  /// be removed and no stale metadata is left behind. A manifest from a newer
  /// format is never modified. Never throws.
  Future<void> onFileDeleted(File deleted) async {
    try {
      final folder = deleted.parent;
      final name = p.basename(deleted.path);
      await _store.update(folder, (current) {
        if (current == null || current.isNewerThanApp) return null;
        final gone = current.episodes.where((e) => e.file == name).toList();
        for (final episode in gone) {
          final path = episode.thumbnail == null
              ? null
              : FolderManifestStore.resolveInside(
                  FolderManifestStore.metaDir(folder).path,
                  episode.thumbnail!,
                );
          if (path != null) {
            try {
              File(path).deleteSync();
            } catch (_) {}
          }
        }
        return current.copyWith(
          episodes: [
            for (final e in current.episodes)
              if (e.file != name) e,
          ],
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        );
      });
      final after = await _store.read(folder);
      if (after == null || after.isNewerThanApp) return;
      var anyLeft = false;
      for (final episode in after.episodes) {
        final path = FolderManifestStore.resolveInside(
          folder.path,
          episode.file,
        );
        if (path != null && await File(path).exists()) {
          anyLeft = true;
          break;
        }
      }
      if (!anyLeft) {
        final meta = FolderManifestStore.metaDir(folder);
        if (await meta.exists()) await meta.delete(recursive: true);
      }
    } catch (e) {
      AppLogger.instance.log('[folder-manifest] cleanup failed: $e');
    }
  }

  Future<void> _writeManifest(Directory folder, DownloadRecord record) async {
    final key = episodeKey(record);
    final ids = ManifestIds(
      anilist: record.anilistId,
      mal: record.malId,
      tmdb: record.tmdbId,
      imdb: record.imdbId,
    );
    final subtitles = <ManifestSubtitle>[
      // The record's list, or the files found next to the video when the
      // record's list is empty (see playableSubtitlesFor).
      for (final s in playableSubtitlesFor(record))
        if (_relativeInside(folder, s.path) case final rel?)
          ManifestSubtitle(
            file: rel,
            lang: s.lang,
            label: s.label ?? '',
            isDefault: s.isDefault,
          ),
    ];
    // Intro/outro times travel with the episode so Skip works offline. Only
    // looked up once per episode (the manifest keeps them afterwards).
    final before = (await _store.read(
      folder,
    ))?.episodes.where((e) => e.key == key).firstOrNull;
    final skips = before != null && before.skips.isNotEmpty
        ? before.skips
        : await _lookupSkips(record);
    // The skip lookup may wait on the network; never write after shutdown.
    if (_canceled()) return;
    await _store.update(folder, (current) {
      final existing = current?.episodes.where((e) => e.key == key).firstOrNull;
      final episode = ManifestEpisode(
        key: key,
        file: p.basename(record.filePath!),
        title: record.episodeTitle,
        number: record.episodeNumber,
        season: record.season,
        // Keep a thumbnail that is already saved; artwork is added afterwards.
        thumbnail: existing?.thumbnail,
        quality: record.quality,
        category: record.category,
        bytes: record.bytesTotal,
        savedAt: record.createdAt,
        episodeId: record.episodeId,
        // Never wipe subtitles the entry already lists because this write
        // found none (for example, a stale record arriving late).
        subtitles: subtitles.isNotEmpty
            ? subtitles
            : (existing?.subtitles ?? const []),
        skips: skips.isNotEmpty ? skips : (existing?.skips ?? const []),
      );
      final base =
          current ??
          FolderManifest(
            folderId: FolderManifest.newFolderId(),
            title: record.showTitle,
            sourceId: record.sourceId == 'local-files' ? null : record.sourceId,
            showId: record.showId.startsWith('local:') ? null : record.showId,
          );
      final alt = {
        ...base.altTitles,
        if (base.title.toLowerCase() != record.showTitle.toLowerCase())
          record.showTitle,
      }.toList();
      return base
          .copyWith(
            ids: base.ids.merge(ids),
            altTitles: alt,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          )
          .withEpisode(episode);
    });
  }

  /// Skip times for [record]'s episode: online (AniSkip) when possible, else
  /// whatever this PC already saved. Never blocks the manifest for long.
  Future<List<SkipInterval>> _lookupSkips(DownloadRecord record) async {
    final n = record.episodeNumber;
    final lookup = lookupSkips;
    if (lookup == null || n == null || n != n.truncateToDouble()) {
      return const [];
    }
    try {
      return await lookup(
        record.showTitle,
        n.toInt(),
      ).timeout(const Duration(seconds: 12));
    } catch (_) {
      return const [];
    }
  }

  /// Saves the poster and this episode's thumbnail as PNG if they are missing.
  Future<void> _ensureArtwork(Directory folder, DownloadRecord record) async {
    final manifest = await _store.read(folder);
    if (manifest == null || manifest.isNewerThanApp) return;
    final key = episodeKey(record);
    final episode = manifest.episodes.where((e) => e.key == key).firstOrNull;
    String? poster, thumbnail;

    if (!await _exists(folder, manifest.poster) &&
        (record.cover ?? '').isNotEmpty) {
      final bytes = await _bytes(
        record.cover!,
        coverUrl: record.cover,
        coverHeaders: record.coverHeaders,
      );
      if (bytes != null && await _savePng(folder, posterPath, bytes)) {
        poster = posterPath;
      }
    }

    if (episode != null && !await _exists(folder, episode.thumbnail)) {
      final path = episodeThumbnailPath(key);
      Uint8List? bytes;
      final remote = record.episodeThumbnail;
      if (remote != null && remote.isNotEmpty) {
        bytes = await _bytes(
          remote,
          coverUrl: record.cover,
          coverHeaders: record.coverHeaders,
        );
      }
      // No usable artwork URL: take a frame from the saved video itself
      // (skipped after shutdown: the extractor opens the video file).
      if (bytes == null && extractFrame != null && !_canceled()) {
        final frame = await extractFrame!(record.filePath!);
        if (frame != null) bytes = await _bytes(frame);
      }
      if (bytes != null && await _savePng(folder, path, bytes)) {
        thumbnail = path;
      }
    }

    if ((poster == null && thumbnail == null) || _canceled()) return;
    await _store.update(folder, (current) {
      if (current == null) return null;
      var next = poster == null ? current : current.copyWith(poster: poster);
      final target = next.episodes.where((e) => e.key == key).firstOrNull;
      if (thumbnail != null && target != null) {
        next = next.withEpisode(target.copyWith(thumbnail: thumbnail));
      }
      return next;
    });
  }

  /// Loads [source] (an http(s) URL, a `file:` URI or a plain path) as bytes.
  Future<Uint8List?> _bytes(
    String source, {
    String? coverUrl,
    Map<String, String>? coverHeaders,
  }) async {
    try {
      final uri = Uri.tryParse(source);
      if (uri == null) return null;
      if (uri.scheme == 'file') {
        final file = File.fromUri(uri);
        return await file.length() > 12 * 1024 * 1024
            ? null
            : await file.readAsBytes();
      }
      if (uri.scheme != 'http' && uri.scheme != 'https') {
        // A bare Windows path such as C:\x.jpg parses as scheme "c".
        final file = File(source);
        return await file.exists() ? await file.readAsBytes() : null;
      }
      // Headers meant for the cover host are never sent to another host.
      final sameHost =
          coverUrl != null && Uri.tryParse(coverUrl)?.host == uri.host;
      return await _fetch(uri, sameHost ? coverHeaders : null);
    } catch (_) {
      return null;
    }
  }

  /// Converts [bytes] to a size-limited PNG and writes it inside `.zangetsu`.
  Future<bool> _savePng(Directory folder, String relative, Uint8List bytes) =>
      _saveEncoded(folder, relative, bytes, maxArtworkSide, jpeg: false);

  /// Saves the image at [source] (http(s) URL, `file:` URI or plain path) to
  /// [relative] inside `<folder>/.zangetsu`, scaled to [maxSide] (default
  /// [maxArtworkSide]). Same fetch rules as the poster: cover headers are only
  /// sent to the cover's own host. [jpeg] writes a small JPEG instead of a
  /// PNG (used for the many episode thumbnails). Returns false on any
  /// failure; never throws. Used by the downloaded show page's artwork.
  Future<bool> saveImage(
    Directory folder,
    String relative,
    String source, {
    String? coverUrl,
    Map<String, String>? coverHeaders,
    int? maxSide,
    bool jpeg = false,
  }) async {
    try {
      final bytes = await _bytes(
        source,
        coverUrl: coverUrl,
        coverHeaders: coverHeaders,
      );
      if (bytes == null) return false;
      return await _saveEncoded(
        folder,
        relative,
        bytes,
        maxSide ?? maxArtworkSide,
        jpeg: jpeg,
      );
    } catch (_) {
      return false;
    }
  }

  /// True when [relative] (inside `<folder>/.zangetsu`) is already saved.
  Future<bool> hasImage(Directory folder, String relative) =>
      _exists(folder, relative);

  /// Re-encodes [bytes] off the UI isolate (PNG, or JPEG when [jpeg]) no
  /// larger than [maxSide] and writes it atomically under `.zangetsu`.
  Future<bool> _saveEncoded(
    Directory folder,
    String relative,
    Uint8List bytes,
    int maxSide, {
    required bool jpeg,
  }) async {
    final png = await Isolate.run(
      () => jpeg ? _toJpg(bytes, maxSide) : _toPng(bytes, maxSide),
    );
    // Encoding runs on another isolate; the owner may have shut down since.
    if (png == null || _canceled()) return false;
    final target = FolderManifestStore.resolveInside(
      FolderManifestStore.metaDir(folder).path,
      relative,
    );
    if (target == null) return false;
    await Directory(p.dirname(target)).create(recursive: true);
    final temp = File('$target.tmp');
    await temp.writeAsBytes(png, flush: true);
    await temp.rename(target);
    return true;
  }

  Future<bool> _exists(Directory folder, String? relative) async {
    if (relative == null) return false;
    final path = FolderManifestStore.resolveInside(
      FolderManifestStore.metaDir(folder).path,
      relative,
    );
    return path != null && await File(path).exists();
  }

  /// A forward-slash path of [absolute] relative to [folder], or null when the
  /// file is not inside the folder (so a manifest never points outside it).
  static String? _relativeInside(Directory folder, String absolute) {
    if (absolute.isEmpty || !p.isWithin(folder.path, absolute)) return null;
    return p.relative(absolute, from: folder.path).replaceAll(r'\', '/');
  }

  /// Decodes any supported image and re-encodes it as a PNG no larger than
  /// [maxSide] pixels on its longest edge. Runs off the UI isolate.
  static Uint8List? _toPng(Uint8List bytes, int maxSide) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;
    var out = decoded;
    if (math.max(decoded.width, decoded.height) > maxSide) {
      out = decoded.width >= decoded.height
          ? img.copyResize(decoded, width: maxSide)
          : img.copyResize(decoded, height: maxSide);
    }
    return Uint8List.fromList(img.encodePng(out));
  }

  /// Like [_toPng] but writes a JPEG (quality 85): episode thumbnails are
  /// photos, so this keeps a full season's worth down to a few MB.
  static Uint8List? _toJpg(Uint8List bytes, int maxSide) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;
    var out = decoded;
    if (math.max(decoded.width, decoded.height) > maxSide) {
      out = decoded.width >= decoded.height
          ? img.copyResize(decoded, width: maxSide)
          : img.copyResize(decoded, height: maxSide);
    }
    return Uint8List.fromList(img.encodeJpg(out, quality: 85));
  }

  /// Plain HTTP(S) download with a timeout and a size cap.
  static Future<Uint8List?> _httpFetch(
    Uri url,
    Map<String, String>? headers,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final request = await client
          .getUrl(url)
          .timeout(const Duration(seconds: 15));
      headers?.forEach(request.headers.set);
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode != 200) return null;
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 20))) {
        builder.add(chunk);
        if (builder.length > 12 * 1024 * 1024) return null;
      }
      return builder.takeBytes();
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}
