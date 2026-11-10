import 'download_server_preference.dart';

/// Retain the index when a Windows media path is temporarily missing.
const missingSavedDownloadMessage = 'The saved file is unavailable at its recorded location. Choose its download folder to recover local files.';

/// Lifecycle of one downloaded episode/movie.
enum DownloadStatus {
  queued, // accepted, waiting to resolve a source
  resolving, // calling the provider to find a direct-file stream
  downloading,
  // Bytes are all fetched; the file is still being joined, remuxed and moved.
  // Its own state because that work rewrites the whole file — a minute or more
  // on a big episode — and showing 100% through it reads as a stuck download.
  finalizing,
  paused,
  done,
  failed,
  unsupported, // no direct-file (e.g. HLS-only) source — phase 2
  canceled,
}

DownloadStatus _statusFromName(String? n) => DownloadStatus.values.firstWhere(
  (s) => s.name == n,
  orElse: () => DownloadStatus.queued,
);

/// A subtitle track saved to disk alongside a download, so soft-subbed sources
/// (e.g. HiAnime — the video stream carries no burned-in text) still have
/// subtitles offline. [path] is a local file the player loads via
/// `SubtitleTrack.uri`.
class OfflineSubtitle {
  const OfflineSubtitle({
    required this.lang,
    this.label,
    required this.path,
    this.publicPath,
    this.isDefault = false,
  });

  final String lang;
  final String? label;
  final String path;

  /// Public sidecar copy, discoverable by players that scan the video folder.
  /// Null for older records or when publication has not succeeded.
  final String? publicPath;
  final bool isDefault;

  Map<String, dynamic> toMap() => {
    'lang': lang,
    'label': label,
    'path': path,
    'publicPath': publicPath,
    'default': isDefault,
  };

  factory OfflineSubtitle.fromMap(Map raw) {
    final m = Map<String, dynamic>.from(raw);
    return OfflineSubtitle(
      lang: m['lang'] as String? ?? 'Sub',
      label: m['label'] as String?,
      path: m['path'] as String? ?? '',
      publicPath: m['publicPath'] as String?,
      isDefault: m['default'] == true,
    );
  }

  OfflineSubtitle copyWith({String? publicPath}) => OfflineSubtitle(
    lang: lang,
    label: label,
    path: path,
    publicPath: publicPath ?? this.publicPath,
    isDefault: isDefault,
  );
}

/// A single download, persisted in the Hive `downloads` box (as a Map) so the
/// library survives restarts. [id] doubles as the background_downloader task id
/// and is deterministic per (source, episode) so re-downloads are idempotent.
class DownloadRecord {
  const DownloadRecord({
    required this.id,
    required this.sourceId,
    required this.showId,
    required this.showTitle,
    this.cover,
    this.coverHeaders,
    required this.showUrl,
    required this.episodeId,
    required this.episodeUrl,
    this.episodeNumber,
    this.episodeThumbnail,
    this.season,
    this.storageKey = '',
    this.downloadRoot,
    required this.episodeTitle,
    required this.category,
    required this.quality,
    this.serverPreference,
    this.pendingAudioFinalization = false,
    this.status = DownloadStatus.queued,
    this.progress = 0,
    this.bytesTotal = 0,
    this.filePath,
    this.supersededPath,
    this.retainedMediaPaths = const [],
    this.error,
    this.subtitles = const [],
    this.malId,
    this.isTorrent = false,
    this.recoveredFromDisk = false,
    this.retryAt,
    this.retryHost,
    this.retryCount = 0,
    this.autoResumePending = false,
    required this.createdAt,
  });

  final String id;
  final String sourceId;
  final String showId;
  final String showTitle;
  final String? cover;
  final Map<String, String>? coverHeaders;
  final String showUrl;
  final String episodeId;
  final String episodeUrl;
  final double? episodeNumber;

  /// Optional source episode artwork; null preserves older offline records.
  final String? episodeThumbnail;
  final int? season;

  /// Device-local file generation. Automatic mirrors/resume keep it; explicit
  /// fresh downloads get a new key so retained media is never overwritten.
  final String storageKey;

  /// Windows destination captured when this generation is accepted. A default
  /// folder change applies to future jobs, never splits current media/sidecars.
  /// Null preserves legacy/mobile records without migrating their saved files.
  final String? downloadRoot;
  final String episodeTitle;
  final String category; // sub/dub — kept for re-resolution + offline history
  final String quality; // requested quality label (e.g. '1080p' / 'best')
  /// Batch server choice survives retries/restarts without storing a stream URL.
  final DownloadServerPreference? serverPreference;

  /// Complete local media awaits Windows audio selection, not another transfer.
  /// Old records default false so partial files are never promoted by inference.
  final bool pendingAudioFinalization;
  final DownloadStatus status;
  final double progress; // 0..1
  final int bytesTotal; // expected file size in bytes (0 when unknown)
  // Final media path, or a complete Windows file awaiting audio finalization.
  final String? filePath;

  /// File left behind by the download this one replaced, deleted once this one
  /// lands. Persisted rather than held in memory: a re-download killed halfway
  /// would otherwise forget the old file and strand it for good, which is the
  /// leak this whole thing exists to stop.
  final String? supersededPath;

  /// Earlier complete files retained across retries until a verified replacement
  /// succeeds or the user deletes this download. Never contains stream URLs.
  final List<String> retainedMediaPaths;
  final String? error;
  final List<OfflineSubtitle> subtitles; // soft-sub files saved for offline use
  final int? malId; // anime MAL id → AniList auto-scrobble on offline playback
  final bool
  isTorrent; // downloaded via the torrent engine (not background_downloader)
  /// Local media recovered without its original provider/audio metadata.
  /// Availability does not certify its original language or full episode length.
  final bool recoveredFromDisk;

  /// Windows host cooldown metadata; never contains signed stream URLs.
  final int? retryAt;
  final String? retryHost;
  final int retryCount;

  /// Explicit pending intent; legacy/mobile records retain manual recovery.
  final bool autoResumePending;
  final int createdAt;

  bool get isActive =>
      status == DownloadStatus.queued ||
      status == DownloadStatus.resolving ||
      status == DownloadStatus.downloading ||
      status == DownloadStatus.finalizing ||
      status == DownloadStatus.paused;

  DownloadRecord copyWith({
    String? episodeThumbnail,
    DownloadStatus? status,
    String? storageKey,
    String? downloadRoot,
    double? progress,
    int? bytesTotal,
    String? Function()? filePath,
    String? Function()? supersededPath,
    List<String>? retainedMediaPaths,
    String? Function()? error,
    List<OfflineSubtitle>? subtitles,
    bool? isTorrent,
    bool? pendingAudioFinalization,
    int? Function()? retryAt,
    String? Function()? retryHost,
    int? retryCount,
    bool? autoResumePending,
  }) => DownloadRecord(
    id: id,
    sourceId: sourceId,
    showId: showId,
    showTitle: showTitle,
    cover: cover,
    coverHeaders: coverHeaders,
    showUrl: showUrl,
    episodeId: episodeId,
    episodeUrl: episodeUrl,
    episodeNumber: episodeNumber,
    episodeThumbnail: episodeThumbnail ?? this.episodeThumbnail,
    season: season,
    storageKey: storageKey ?? this.storageKey,
    downloadRoot: downloadRoot ?? this.downloadRoot,
    episodeTitle: episodeTitle,
    category: category,
    quality: quality,
    serverPreference: serverPreference,
    pendingAudioFinalization:
        pendingAudioFinalization ?? this.pendingAudioFinalization,
    status: status ?? this.status,
    progress: progress ?? this.progress,
    bytesTotal: bytesTotal ?? this.bytesTotal,
    filePath: filePath != null ? filePath() : this.filePath,
    supersededPath: supersededPath != null
        ? supersededPath()
        : this.supersededPath,
    retainedMediaPaths: retainedMediaPaths ?? this.retainedMediaPaths,
    error: error != null ? error() : this.error,
    subtitles: subtitles ?? this.subtitles,
    malId: malId,
    isTorrent: isTorrent ?? this.isTorrent,
    recoveredFromDisk: recoveredFromDisk,
    retryAt: retryAt != null ? retryAt() : this.retryAt,
    retryHost: retryHost != null ? retryHost() : this.retryHost,
    retryCount: retryCount ?? this.retryCount,
    autoResumePending: autoResumePending ?? this.autoResumePending,
    createdAt: createdAt,
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'sourceId': sourceId,
    'showId': showId,
    'showTitle': showTitle,
    'cover': cover,
    'coverHeaders': coverHeaders,
    'showUrl': showUrl,
    'episodeId': episodeId,
    'episodeUrl': episodeUrl,
    'episodeNumber': episodeNumber,
    'episodeThumbnail': episodeThumbnail,
    'season': season,
    'storageKey': storageKey,
    'downloadRoot': downloadRoot,
    'episodeTitle': episodeTitle,
    'category': category,
    'quality': quality,
    'serverPreference': serverPreference?.toMap(),
    'pendingAudioFinalization': pendingAudioFinalization,
    'status': status.name,
    'progress': progress,
    'bytesTotal': bytesTotal,
    'filePath': filePath,
    'supersededPath': supersededPath,
    'retainedMediaPaths': retainedMediaPaths,
    'error': error,
    'subtitles': subtitles.map((s) => s.toMap()).toList(),
    'malId': malId,
    'isTorrent': isTorrent,
    'recoveredFromDisk': recoveredFromDisk,
    'retryAt': retryAt,
    'retryHost': retryHost,
    'retryCount': retryCount,
    'autoResumePending': autoResumePending,
    'createdAt': createdAt,
  };

  factory DownloadRecord.fromMap(Map raw) {
    final m = Map<String, dynamic>.from(raw);
    return DownloadRecord(
      id: m['id'] as String,
      sourceId: m['sourceId'] as String? ?? '',
      showId: m['showId'] as String? ?? '',
      showTitle: m['showTitle'] as String? ?? '',
      cover: m['cover'] as String?,
      coverHeaders: (m['coverHeaders'] as Map?)?.map(
        (k, v) => MapEntry('$k', '$v'),
      ),
      showUrl: m['showUrl'] as String? ?? '',
      episodeId: m['episodeId'] as String? ?? '',
      episodeUrl: m['episodeUrl'] as String? ?? '',
      episodeNumber: (m['episodeNumber'] as num?)?.toDouble(),
      episodeThumbnail: m['episodeThumbnail'] is String ? m['episodeThumbnail'] as String : null,
      season: (m['season'] as num?)?.toInt(),
      storageKey: m['storageKey'] as String? ?? '',
      downloadRoot: m['downloadRoot'] as String?,
      episodeTitle: m['episodeTitle'] as String? ?? '',
      category: m['category'] as String? ?? 'sub',
      quality: m['quality'] as String? ?? 'best',
      serverPreference: m['serverPreference'] is Map
          ? DownloadServerPreference.fromMap(m['serverPreference'] as Map)
          : null,
      pendingAudioFinalization: m['pendingAudioFinalization'] == true,
      status: _statusFromName(m['status'] as String?),
      progress: (m['progress'] as num?)?.toDouble() ?? 0,
      bytesTotal: (m['bytesTotal'] as num?)?.toInt() ?? 0,
      filePath: m['filePath'] as String?,
      supersededPath: m['supersededPath'] as String?,
      retainedMediaPaths: ((m['retainedMediaPaths'] as List?) ?? const [])
          .whereType<String>()
          .where((path) => path.isNotEmpty)
          .toSet()
          .toList(),
      error: m['error'] as String?,
      subtitles: ((m['subtitles'] as List?) ?? const [])
          .whereType<Map>()
          .map(OfflineSubtitle.fromMap)
          .where((s) => s.path.isNotEmpty)
          .toList(),
      malId: (m['malId'] as num?)?.toInt(),
      isTorrent: (m['isTorrent'] as bool?) ?? false,
      recoveredFromDisk: m['recoveredFromDisk'] == true,
      retryAt: (m['retryAt'] as num?)?.toInt(),
      retryHost: m['retryHost'] is String ? m['retryHost'] as String : null,
      retryCount: (m['retryCount'] as num?)?.toInt() ?? 0,
      autoResumePending: m['autoResumePending'] == true,
      createdAt: (m['createdAt'] as num?)?.toInt() ?? 0,
    );
  }
}
