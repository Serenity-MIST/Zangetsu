import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'download_record.dart';

/// A recoverable app-generated filename carries episode identity, not an audio
/// language or a provider URL. Those must never be guessed during disk recovery.
class DesktopSavedVideo {
  DesktopSavedVideo._(this.title, this.season, this.number, this.quality, this.tag);
  final String title;
  final int? season;
  final double? number;
  final String quality;
  final String tag;

  /// Recognize only the identity-bearing Windows naming scheme, not arbitrary
  /// videos, temporary segments, merge scratch files or loosely similar titles.
  static DesktopSavedVideo? parse(String filename) {
    final match = RegExp(
      r'^(.+)_(?:S([0-9]+))?E([0-9]+(?:\.[0-9]+)?)?_(.+)_([a-f0-9]{32})\.(?:ts|mp4|mkv|m4v|webm)$',
      caseSensitive: false,
    ).firstMatch(filename);
    if (match == null) return null;
    final title = match[1]!.replaceAll(RegExp('_+'), ' ').trim();
    if (title.isEmpty) return null;
    return DesktopSavedVideo._(title, int.tryParse(match[2] ?? ''),
        double.tryParse(match[3] ?? ''), match[4]!, match[5]!.toLowerCase());
  }

  /// A local-only record makes the file available offline while preserving the
  /// fact that its original provider, spoken language and full length are unknown.
  DownloadRecord toRecord(File file, FileStat stat, String root) => DownloadRecord(
    id: 'recovered:$tag', sourceId: 'local-files',
    showId: 'local:${sha256.convert(utf8.encode(title.toLowerCase()))}',
    showTitle: title, showUrl: file.parent.uri.toString(),
    episodeId: 'file:$tag', episodeUrl: file.uri.toString(),
    episodeNumber: number, season: season,
    episodeTitle: number == null ? title : 'Episode ${number!.toString().replaceFirst(RegExp(r'\.0$'), '')}',
    category: 'unknown', quality: quality, status: DownloadStatus.done,
    progress: 1, bytesTotal: stat.size, filePath: file.path,
    downloadRoot: root, recoveredFromDisk: true,
    createdAt: stat.modified.millisecondsSinceEpoch,
  );
}

/// Finds existing Windows media without changing files or assuming a failed
/// index means the media was deleted. Publishing remains the manager's job.
class DesktopDownloadRecovery {
  DesktopDownloadRecovery({Future<bool> Function(String)? probe})
      : _probe = probe ?? inspectLocalVideo;
  final Future<bool> Function(String) _probe;

  /// Examine only Videos/show/app-named-file under explicitly supplied
  /// current/legacy roots. No recursive drive scan or symbolic-link traversal.
  Future<List<DownloadRecord>> discover({
    required Iterable<String> roots,
    required Iterable<DownloadRecord> known,
    required bool Function() canceled,
  }) async {
    final records = known.toList();
    final knownIds = records.map((r) => r.id).toSet();
    final referenced = <String>{
      for (final r in records)
        for (final value in [r.filePath, r.supersededPath, ...r.retainedMediaPaths])
          if (value != null && value.isNotEmpty) _pathKey(value),
    };
    final activeTags = <String>{
      for (final r in records.where((r) => r.isActive || r.pendingAudioFinalization))
        sha256.convert(utf8.encode(jsonEncode([
          r.sourceId, r.showId, r.episodeId, r.storageKey,
        ]))).toString().substring(0, 32),
    };
    final seenRoots = <String>{};
    final result = <DownloadRecord>[];
    for (final root in roots) {
      if (canceled()) break;
      if (!p.isAbsolute(root) || !seenRoots.add(_pathKey(root))) continue;
      final videos = Directory(p.join(root, 'Videos'));
      try {
        if (await FileSystemEntity.type(videos.path, followLinks: false) != FileSystemEntityType.directory) continue;
        await for (final folder in videos.list(followLinks: false)) {
          if (canceled()) return result;
          if (folder is! Directory) continue;
          await for (final entity in folder.list(followLinks: false)) {
            if (canceled()) return result;
            if (entity is! File || referenced.contains(_pathKey(entity.path))) continue;
            final saved = DesktopSavedVideo.parse(p.basename(entity.path));
            if (saved == null || knownIds.contains('recovered:${saved.tag}') || activeTags.contains(saved.tag)) continue;
            final before = await entity.stat();
            if (before.size <= 0 || !await _probe(entity.path) || canceled()) continue;
            final after = await entity.stat();
            // A still-growing file is not a finished offline recovery candidate.
            if (before.size != after.size || before.modified != after.modified) continue;
            final record = saved.toRecord(entity, after, root);
            result.add(record);
            knownIds.add(record.id);
            referenced.add(_pathKey(entity.path));
          }
        }
      } on FileSystemException {
        // Missing/unmounted/denied roots leave the existing index untouched.
      }
    }
    return result;
  }

  /// Compares Windows paths without treating case or separators as new files.
  static String _pathKey(String path) {
    final normalized = p.normalize(p.absolute(path));
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  /// Inspect existing local bytes with bundled FFprobe; forbid network inputs.
  /// Playability is checked, but a positive duration cannot prove full episodes.
  static Future<bool> inspectLocalVideo(String file) async {
    final engine = File(p.join(File(Platform.resolvedExecutable).parent.path,
        'engines', 'ffmpeg', 'ffprobe.exe'));
    if (!await engine.exists()) return false;
    Process? process;
    try {
      process = await Process.start(engine.path, [
        '-v', 'error', '-protocol_whitelist', 'file,pipe',
        '-show_entries', 'format=duration:stream=codec_type', '-of', 'json', file,
      ]);
      final output = process.stdout.transform(utf8.decoder).join();
      unawaited(process.stderr.drain<void>());
      final code = await process.exitCode.timeout(const Duration(seconds: 15), onTimeout: () {
        process?.kill();
        return -1;
      });
      final text = await output.timeout(const Duration(seconds: 2));
      if (code != 0 || text.length > 65536) return false;
      final data = jsonDecode(text);
      if (data is! Map || data['streams'] is! List || data['format'] is! Map) return false;
      final streams = data['streams'] as List;
      final duration = double.tryParse('${data['format']['duration']}');
      return duration != null && duration.isFinite && duration > 0 &&
          streams.any((s) => s is Map && s['codec_type'] == 'video') &&
          streams.any((s) => s is Map && s['codec_type'] == 'audio');
    } catch (_) {
      return false;
    } finally {
      process?.kill();
    }
  }
}
