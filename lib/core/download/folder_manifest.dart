import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../playback/skip_service.dart' show SkipInterval;

/// Current manifest format. Bump only for changes older readers cannot ignore;
/// adding optional fields does not need a bump because unknown keys are kept.
const int kFolderManifestVersion = 1;

/// Catalogue identifiers that let subtitles, artwork and playback match the
/// right title without guessing from a name. Every field is optional.
class ManifestIds {
  const ManifestIds({this.anilist, this.mal, this.tmdb, this.imdb});
  final int? anilist, mal, tmdb;
  final String? imdb;

  bool get isEmpty =>
      anilist == null && mal == null && tmdb == null && (imdb ?? '').isEmpty;

  Map<String, Object?> toJson() => {
    if (anilist != null) 'anilist': anilist,
    if (mal != null) 'mal': mal,
    if (tmdb != null) 'tmdb': tmdb,
    if ((imdb ?? '').isNotEmpty) 'imdb': imdb,
  };

  factory ManifestIds.fromJson(Object? raw) {
    if (raw is! Map) return const ManifestIds();
    int? number(Object? v) => v is num ? v.toInt() : int.tryParse('$v');
    final imdb = raw['imdb'];
    return ManifestIds(
      anilist: number(raw['anilist']),
      mal: number(raw['mal']),
      tmdb: number(raw['tmdb']),
      imdb: imdb is String && imdb.isNotEmpty ? imdb : null,
    );
  }

  /// Keeps what [other] knows when this value does not.
  ManifestIds merge(ManifestIds other) => ManifestIds(
    anilist: anilist ?? other.anilist,
    mal: mal ?? other.mal,
    tmdb: tmdb ?? other.tmdb,
    imdb: (imdb ?? '').isNotEmpty ? imdb : other.imdb,
  );
}

/// A subtitle file saved beside an episode. [file] is relative to the show folder.
class ManifestSubtitle {
  const ManifestSubtitle({
    required this.file,
    required this.lang,
    this.label = '',
    this.isDefault = false,
  });
  final String file, lang, label;
  final bool isDefault;

  Map<String, Object?> toJson() => {
    'file': file,
    'lang': lang,
    if (label.isNotEmpty) 'label': label,
    if (isDefault) 'default': true,
  };

  static ManifestSubtitle? fromJson(Object? raw) {
    if (raw is! Map || raw['file'] is! String || raw['lang'] is! String) {
      return null;
    }
    return ManifestSubtitle(
      file: raw['file'] as String,
      lang: raw['lang'] as String,
      label: raw['label'] is String ? raw['label'] as String : '',
      isDefault: raw['default'] == true,
    );
  }
}

/// One saved episode. Paths are relative to the show folder so the whole
/// folder can be moved or renamed.
class ManifestEpisode {
  const ManifestEpisode({
    required this.key,
    required this.file,
    required this.title,
    this.number,
    this.season,
    this.thumbnail,
    this.quality = '',
    this.category = 'unknown',
    this.bytes = 0,
    this.savedAt = 0,
    this.episodeId,
    this.subtitles = const [],
    this.skips = const [],
  });

  /// Stable identity of this episode inside the folder (the download's tag).
  final String key;
  final String file, title;
  final double? number;
  final int? season;
  final String? thumbnail;
  final String quality, category;
  final int bytes, savedAt;

  /// Provider episode id when known; used to re-link to an existing record.
  final String? episodeId;
  final List<ManifestSubtitle> subtitles;

  /// Intro/outro/recap times, saved with the episode so Skip works offline
  /// and keeps working when the folder moves to another PC.
  final List<SkipInterval> skips;

  ManifestEpisode copyWith({
    String? file,
    String? thumbnail,
    List<ManifestSubtitle>? subtitles,
    List<SkipInterval>? skips,
    int? bytes,
  }) => ManifestEpisode(
    key: key,
    file: file ?? this.file,
    title: title,
    number: number,
    season: season,
    thumbnail: thumbnail ?? this.thumbnail,
    quality: quality,
    category: category,
    bytes: bytes ?? this.bytes,
    savedAt: savedAt,
    episodeId: episodeId,
    subtitles: subtitles ?? this.subtitles,
    skips: skips ?? this.skips,
  );

  Map<String, Object?> toJson() => {
    'key': key,
    'file': file,
    'title': title,
    if (number != null) 'number': number,
    if (season != null) 'season': season,
    if (thumbnail != null) 'thumbnail': thumbnail,
    if (quality.isNotEmpty) 'quality': quality,
    'category': category,
    if (bytes > 0) 'bytes': bytes,
    if (savedAt > 0) 'saved_at': savedAt,
    if (episodeId != null) 'episode_id': episodeId,
    if (subtitles.isNotEmpty)
      'subtitles': [for (final s in subtitles) s.toJson()],
    if (skips.isNotEmpty) 'skips': [for (final s in skips) s.toJson()],
  };

  static ManifestEpisode? fromJson(Object? raw) {
    if (raw is! Map || raw['key'] is! String || raw['file'] is! String) {
      return null;
    }
    return ManifestEpisode(
      key: raw['key'] as String,
      file: raw['file'] as String,
      title: raw['title'] is String ? raw['title'] as String : '',
      number: raw['number'] is num ? (raw['number'] as num).toDouble() : null,
      season: raw['season'] is num ? (raw['season'] as num).toInt() : null,
      thumbnail: raw['thumbnail'] is String ? raw['thumbnail'] as String : null,
      quality: raw['quality'] is String ? raw['quality'] as String : '',
      category: raw['category'] is String
          ? raw['category'] as String
          : 'unknown',
      bytes: raw['bytes'] is num ? (raw['bytes'] as num).toInt() : 0,
      savedAt: raw['saved_at'] is num ? (raw['saved_at'] as num).toInt() : 0,
      episodeId: raw['episode_id'] is String
          ? raw['episode_id'] as String
          : null,
      subtitles: [
        if (raw['subtitles'] is List)
          for (final s in raw['subtitles'] as List)
            ?ManifestSubtitle.fromJson(s),
      ],
      skips: [
        if (raw['skips'] is List)
          for (final s in raw['skips'] as List) ?SkipInterval.fromJson(s),
      ],
    );
  }
}

/// The identity card of one downloaded show folder.
///
/// It lives in `<show folder>/.zangetsu/metadata.json` next to PNG artwork, so
/// deleting the folder deletes all of it, and moving the folder keeps it.
/// Everything inside is data to be validated, never trusted: a folder from
/// another PC or an old backup can contain anything.
class FolderManifest {
  FolderManifest({
    required this.folderId,
    required this.title,
    this.mediaType = 'video',
    this.altTitles = const [],
    this.ids = const ManifestIds(),
    this.sourceId,
    this.showId,
    this.poster,
    this.banner,
    this.episodes = const [],
    this.updatedAt = 0,
    this.schemaVersion = kFolderManifestVersion,
    Map<String, Object?>? extra,
  }) : extra = extra ?? const {};

  /// Permanent random id, created once. It survives moving and renaming so the
  /// app can tell "the same download, now somewhere else".
  final String folderId;
  final int schemaVersion;
  final String mediaType, title;
  final List<String> altTitles;
  final ManifestIds ids;

  /// Provider identity at download time. May be absent for recovered folders.
  final String? sourceId, showId;

  /// Relative paths inside `.zangetsu`, such as `art/poster.png`.
  final String? poster, banner;
  final List<ManifestEpisode> episodes;
  final int updatedAt;

  /// Unknown top-level keys from a newer app, kept so saving does not erase them.
  final Map<String, Object?> extra;

  /// True when written by a newer format: readable, but writes are skipped so
  /// an older app never downgrades a newer manifest.
  bool get isNewerThanApp => schemaVersion > kFolderManifestVersion;

  FolderManifest copyWith({
    String? title,
    List<String>? altTitles,
    ManifestIds? ids,
    String? sourceId,
    String? showId,
    String? poster,
    String? banner,
    List<ManifestEpisode>? episodes,
    int? updatedAt,
  }) => FolderManifest(
    folderId: folderId,
    schemaVersion: schemaVersion,
    mediaType: mediaType,
    title: title ?? this.title,
    altTitles: altTitles ?? this.altTitles,
    ids: ids ?? this.ids,
    sourceId: sourceId ?? this.sourceId,
    showId: showId ?? this.showId,
    poster: poster ?? this.poster,
    banner: banner ?? this.banner,
    episodes: episodes ?? this.episodes,
    updatedAt: updatedAt ?? this.updatedAt,
    extra: extra,
  );

  /// Adds or replaces the episode with the same [ManifestEpisode.key].
  FolderManifest withEpisode(ManifestEpisode episode) {
    final next = [
      for (final e in episodes)
        if (e.key != episode.key) e,
      episode,
    ];
    return copyWith(episodes: next);
  }

  static const _known = {
    'created_by',
    'schema_version',
    'folder_id',
    'media_type',
    'title',
    'alt_titles',
    'ids',
    'source_id',
    'show_id',
    'artwork',
    'episodes',
    'updated_at',
  };

  Map<String, Object?> toJson() => {
    ...extra,
    'created_by': 'Zangetsu',
    'schema_version': schemaVersion,
    'folder_id': folderId,
    'media_type': mediaType,
    'title': title,
    if (altTitles.isNotEmpty) 'alt_titles': altTitles,
    if (!ids.isEmpty) 'ids': ids.toJson(),
    if (sourceId != null) 'source_id': sourceId,
    if (showId != null) 'show_id': showId,
    if (poster != null || banner != null)
      'artwork': {
        if (poster != null) 'poster': poster,
        if (banner != null) 'banner': banner,
      },
    'episodes': [for (final e in episodes) e.toJson()],
    'updated_at': updatedAt,
  };

  /// Parses a manifest, returning null for anything that is not a Zangetsu
  /// manifest (wrong marker, no id, no title, wrong types). Never throws.
  static FolderManifest? tryParse(String source) {
    try {
      final raw = jsonDecode(source);
      if (raw is! Map ||
          raw['created_by'] != 'Zangetsu' ||
          raw['schema_version'] is! int ||
          (raw['schema_version'] as int) < 1 ||
          raw['folder_id'] is! String ||
          !_validId(raw['folder_id'] as String) ||
          raw['title'] is! String) {
        return null;
      }
      final artwork = raw['artwork'];
      return FolderManifest(
        folderId: raw['folder_id'] as String,
        schemaVersion: raw['schema_version'] as int,
        mediaType: raw['media_type'] is String
            ? raw['media_type'] as String
            : 'video',
        title: raw['title'] as String,
        altTitles: [
          if (raw['alt_titles'] is List)
            for (final t in raw['alt_titles'] as List)
              if (t is String) t,
        ],
        ids: ManifestIds.fromJson(raw['ids']),
        sourceId: raw['source_id'] is String
            ? raw['source_id'] as String
            : null,
        showId: raw['show_id'] is String ? raw['show_id'] as String : null,
        poster: artwork is Map && artwork['poster'] is String
            ? artwork['poster'] as String
            : null,
        banner: artwork is Map && artwork['banner'] is String
            ? artwork['banner'] as String
            : null,
        episodes: [
          if (raw['episodes'] is List)
            for (final e in raw['episodes'] as List)
              ?ManifestEpisode.fromJson(e),
        ],
        updatedAt: raw['updated_at'] is num
            ? (raw['updated_at'] as num).toInt()
            : 0,
        extra: {
          for (final entry in raw.entries)
            if (entry.key is String && !_known.contains(entry.key))
              entry.key as String: entry.value,
        },
      );
    } catch (_) {
      return null;
    }
  }

  static bool _validId(String id) => RegExp(r'^[a-f0-9]{16,64}$').hasMatch(id);

  /// A fresh random folder id.
  static String newFolderId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
}

/// Reads and writes manifests. Writes are atomic (temp file, then rename) and
/// serialised per folder, so a crash or two quick completions cannot corrupt
/// or lose entries. Nothing here ever deletes or moves a user's media.
class FolderManifestStore {
  FolderManifestStore({bool? hideOnWindows}) : _hide = hideOnWindows ?? true;
  final bool _hide;
  final Map<String, Future<void>> _locks = {};

  static const dirName = '.zangetsu';

  /// The list of downloaded episodes. Named metadata.json; the show page
  /// details sit beside it in details.json.
  static const fileName = 'metadata.json';

  /// The name earlier builds used. Still read, and replaced by [fileName]
  /// the next time the folder's manifest is written.
  static const legacyFileName = 'manifest.json';

  static Directory metaDir(Directory folder) =>
      Directory(p.join(folder.path, dirName));
  static File manifestFile(Directory folder) =>
      File(p.join(metaDir(folder).path, fileName));

  /// `manifest.json` from earlier builds.
  static File legacyManifestFile(Directory folder) =>
      File(p.join(metaDir(folder).path, legacyFileName));

  /// True when [folder] has a manifest under the current or the old name.
  static Future<bool> hasManifest(Directory folder) async =>
      await manifestFile(folder).exists() ||
      await legacyManifestFile(folder).exists();

  /// Resolves [relative] (a path from a manifest) under [base], or null when it
  /// is absolute, has a drive letter, or climbs out of [base] with `..`.
  /// This is the single guard that keeps a hostile manifest from pointing at
  /// files elsewhere on the machine.
  static String? resolveInside(String base, String relative) {
    // Characters Windows forbids in file names. A colon matters most: on NTFS
    // "name:stream" addresses a hidden data stream and "C:name" is a path
    // relative to another drive's current folder, so neither may come from a
    // manifest.
    if (relative.isEmpty ||
        relative.contains(RegExp(r'[<>:"|?*\x00-\x1f]')) ||
        p.isAbsolute(relative) ||
        p.windows.isAbsolute(relative) ||
        relative.startsWith('/') ||
        relative.startsWith(r'\')) {
      return null;
    }
    final joined = p.normalize(p.join(base, relative));
    return p.isWithin(base, joined) ? joined : null;
  }

  /// Reads the manifest of [folder], or null when there is none or it is not a
  /// valid Zangetsu manifest.
  Future<FolderManifest?> read(Directory folder) async {
    try {
      // metadata.json first; a folder from an earlier build has manifest.json.
      var file = manifestFile(folder);
      if (!await file.exists()) file = legacyManifestFile(folder);
      if (!await file.exists()) return null;
      // A manifest is small; refuse absurd files instead of loading them.
      if (await file.length() > 8 * 1024 * 1024) return null;
      return FolderManifest.tryParse(await file.readAsString());
    } catch (_) {
      return null;
    }
  }

  /// Writes [manifest] atomically. Skipped for manifests from a newer format.
  Future<void> write(Directory folder, FolderManifest manifest) =>
      _serial(folder.path, () => _write(folder, manifest));

  Future<void> _write(Directory folder, FolderManifest manifest) async {
    if (manifest.isNewerThanApp) return;
    final dir = metaDir(folder);
    final fresh = !await dir.exists();
    await dir.create(recursive: true);
    if (fresh) await _hideDir(dir);
    final target = manifestFile(folder);
    final temp = File('${target.path}.tmp');
    await temp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(manifest.toJson()),
      flush: true,
    );
    await temp.rename(target.path);
    // metadata.json is in place: remove the old manifest.json so the folder
    // keeps one episodes file. Its media files are never touched.
    final legacy = legacyManifestFile(folder);
    if (await legacy.exists()) await legacy.delete();
  }

  /// Read-modify-write under the folder lock. [update] receives the current
  /// manifest (or null when none exists) and returns the new one; returning
  /// null leaves the folder untouched.
  Future<FolderManifest?> update(
    Directory folder,
    FolderManifest? Function(FolderManifest? current) update,
  ) => _serial<FolderManifest?>(folder.path, () async {
    final next = update(await read(folder));
    if (next != null) await _write(folder, next);
    return next;
  });

  Future<T> _serial<T>(String key, Future<T> Function() job) {
    final previous = _locks[key] ?? Future<void>.value();
    final result = previous.then((_) => job());
    final tail = result.then<void>((_) {}, onError: (Object _) {});
    _locks[key] = tail;
    tail.then((_) {
      if (identical(_locks[key], tail)) _locks.remove(key);
    });
    return result;
  }

  /// Marks `.zangetsu` hidden in Explorer. Cosmetic: failure is ignored.
  Future<void> _hideDir(Directory dir) async {
    if (!_hide || !Platform.isWindows) return;
    try {
      await Process.run('attrib', ['+h', dir.path]);
    } catch (_) {}
  }
}
