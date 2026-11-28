import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:path/path.dart' as p;

import 'download_folder_sync.dart';
import 'download_record.dart';
import 'folder_manifest.dart';
import 'subtitle_sidecars.dart';

/// What a library scan did, for showing to the user.
class FolderScanResult {
  const FolderScanResult({
    this.folders = 0,
    this.added = 0,
    this.relinked = 0,
    this.skipped = 0,
  });

  /// Show folders with a manifest that were found.
  final int folders;

  /// Episodes added to the library that it did not know about.
  final int added;

  /// Episodes whose record was pointed at their new location after a move.
  final int relinked;

  /// Episodes already in the library (or copies of one), left untouched.
  final int skipped;

  bool get changedLibrary => added + relinked > 0;
}

/// A show folder that carries a Zangetsu manifest.
class ScannedShow {
  const ScannedShow(this.folder, this.manifest);

  /// Where the folder is now (it may have been moved or renamed).
  final Directory folder;
  final FolderManifest manifest;
}

/// Finds show folders by their `.zangetsu/metadata.json`.
///
/// It only looks inside the roots it is given, never follows links, skips
/// system folders, stops at [maxDepth], and can be cancelled, so pointing it at
/// a big drive stays bounded. Reading is the only thing it does: it never
/// changes or deletes anything it finds.
class FolderManifestScanner {
  FolderManifestScanner({FolderManifestStore? store})
    : _store = store ?? FolderManifestStore();

  final FolderManifestStore _store;

  /// Folder names that are never worth entering.
  static const _skipped = {r'$recycle.bin', 'system volume information'};

  /// Returns every show folder under [root] (or [root] itself) that has a valid
  /// manifest. A folder with a manifest is not searched further.
  Future<List<ScannedShow>> scan(
    Directory root, {
    int maxDepth = 3,
    int maxFolders = 5000,
    bool Function()? canceled,
  }) async {
    final found = <ScannedShow>[];
    var visited = 0;
    final queue = <(Directory, int)>[(root, 0)];
    while (queue.isNotEmpty) {
      if (canceled?.call() == true) break;
      final (dir, depth) = queue.removeAt(0);
      if (++visited > maxFolders) break;
      final manifest = await _store.read(dir);
      if (manifest != null) {
        found.add(ScannedShow(dir, manifest));
        continue;
      }
      if (depth >= maxDepth) continue;
      try {
        await for (final entity in dir.list(followLinks: false)) {
          if (entity is! Directory) continue;
          final name = p.basename(entity.path);
          if (name.startsWith('.') || _skipped.contains(name.toLowerCase())) {
            continue;
          }
          queue.add((entity, depth + 1));
        }
      } on FileSystemException {
        // Unreadable folder (permissions, drive removed): skip it.
      }
    }
    return found;
  }

  /// Builds a download record for each episode of [show] whose file exists.
  /// Episode files and artwork named in the manifest are only used when they
  /// resolve inside the show folder, so a hostile manifest cannot point at
  /// other files on the PC.
  static Future<List<DownloadRecord>> recordsFor(
    ScannedShow show, {
    required String downloadRoot,
  }) async {
    final folder = show.folder;
    final manifest = show.manifest;
    final meta = FolderManifestStore.metaDir(folder).path;
    final poster = await _artworkUri(meta, manifest.poster);
    final records = <DownloadRecord>[];
    for (final episode in manifest.episodes) {
      final path = FolderManifestStore.resolveInside(folder.path, episode.file);
      if (path == null) continue;
      final file = File(path);
      if (!await file.exists()) continue;
      final stat = await file.stat();
      // Windows only: also skip files cut short (see looksFinished).
      if (!looksFinished(
        actualBytes: stat.size,
        manifestBytes: episode.bytes,
        sizeCheck: defaultTargetPlatform == TargetPlatform.windows,
      )) {
        continue;
      }
      final listed = <OfflineSubtitle>[
        for (final s in episode.subtitles)
          if (FolderManifestStore.resolveInside(folder.path, s.file)
              case final sp?)
            if (await File(sp).exists())
              OfflineSubtitle(
                path: sp,
                lang: s.lang,
                label: s.label.isEmpty ? null : s.label,
                isDefault: s.isDefault,
              ),
      ];
      // A manifest written without subtitles still gets the files saved next
      // to the video, matched strictly to this episode's file name.
      final subtitles = listed.isNotEmpty
          ? listed
          : discoverSubtitleSidecars(file.path);
      final known = manifest.sourceId != null && manifest.showId != null;
      records.add(
        DownloadRecord(
          id: 'manifest:${manifest.folderId}:${episode.key}',
          sourceId: manifest.sourceId ?? 'local-files',
          showId: manifest.showId ?? 'local:${manifest.folderId}',
          showTitle: manifest.title,
          cover: poster,
          showUrl: folder.uri.toString(),
          episodeId: episode.episodeId ?? 'file:${episode.key}',
          episodeUrl: file.uri.toString(),
          episodeNumber: episode.number,
          season: episode.season,
          episodeThumbnail: await _artworkUri(meta, episode.thumbnail),
          episodeTitle: episode.title.isEmpty ? manifest.title : episode.title,
          category: episode.category,
          quality: episode.quality,
          status: DownloadStatus.done,
          progress: 1,
          bytesTotal: stat.size,
          filePath: file.path,
          downloadRoot: downloadRoot,
          subtitles: subtitles,
          malId: manifest.ids.mal,
          anilistId: manifest.ids.anilist,
          tmdbId: manifest.ids.tmdb,
          imdbId: manifest.ids.imdb,
          // Without a known provider the original audio language and source
          // are not certain, which is what this flag already means elsewhere.
          recoveredFromDisk: !known,
          createdAt: episode.savedAt > 0
              ? episode.savedAt
              : stat.modified.millisecondsSinceEpoch,
        ),
      );
    }
    return records;
  }

  /// Sanity check before a scanned file is recorded as a finished download.
  /// An empty file never counts. When the manifest wrote down the download's
  /// size, a file less than half of it was cut short after the manifest was
  /// written and is left out, so the show page offers to download it again.
  /// Half, not "equal": the recorded size can be an estimate for streamed
  /// (HLS) downloads, and a real file must never be hidden. Manifests without
  /// a size (0) keep the old rule (non-empty only).
  ///
  /// This does NOT catch a stub that was already marked done (the Frieren E9
  /// 788 KB file): its manifest size is the stub's own size. The Windows show
  /// page skips such stubs itself (see savedEpisodeSizeLooksReal in
  /// desktop_existing_downloads.dart).
  ///
  /// [sizeCheck] turns the "half the recorded size" rule on. The scanner
  /// passes true only on Windows, so phones and TV keep the old rule.
  static bool looksFinished({
    required int actualBytes,
    required int manifestBytes,
    bool sizeCheck = true,
  }) {
    if (actualBytes <= 0) return false;
    if (sizeCheck && manifestBytes > 0 && actualBytes * 2 < manifestBytes) {
      return false;
    }
    return true;
  }

  /// `file:` URI of artwork inside `.zangetsu`, or null if missing or unsafe.
  static Future<String?> _artworkUri(String meta, String? relative) async {
    if (relative == null) return null;
    final path = FolderManifestStore.resolveInside(meta, relative);
    if (path == null || !await File(path).exists()) return null;
    return File(path).uri.toString();
  }

  /// The stable tag identifying [record]'s media file (see
  /// [DownloadFolderSync.episodeKey]), used to recognise the same download
  /// after its folder has moved.
  static String keyOf(DownloadRecord record) =>
      DownloadFolderSync.episodeKey(record);
}
