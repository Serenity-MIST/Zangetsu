import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Extracts offline artwork from app-owned saved videos. Only cache files are
/// written; source videos are read-only and network protocols are disallowed.
class DesktopDownloadThumbnails {
  DesktopDownloadThumbnails({String? engine})
    : engine =
          engine ??
          p.join(
            File(Platform.resolvedExecutable).parent.path,
            'engines',
            'ffmpeg',
            'ffmpeg.exe',
          );
  final String engine;

  /// Cache identity includes file size/modification time, so replacement media
  /// cannot inherit another video's frame. Short clips retry from the start.
  Future<String?> ensure(String mediaPath, Directory cache) async {
    try {
      final media = File(mediaPath);
      final stat = await media.stat();
      if (stat.type != FileSystemEntityType.file ||
          stat.size == 0 ||
          !await File(engine).exists())
        return null;
      final key = sha256.convert(
        utf8.encode(
          '${p.normalize(media.absolute.path)}|${stat.size}|${stat.modified.microsecondsSinceEpoch}',
        ),
      );
      await cache.create(recursive: true);
      final output = File(p.join(cache.path, '$key.jpg'));
      if (await output.exists() && await output.length() > 0)
        return output.uri.toString();
      final temporary = File('${output.path}.partial.jpg');
      for (final second in [5, 0]) {
        Process? process;
        try {
          process = await Process.start(engine, [
            '-nostdin',
            '-hide_banner',
            '-loglevel',
            'error',
            '-y',
            '-protocol_whitelist',
            'file,pipe',
            '-ss',
            '$second',
            '-i',
            media.path,
            '-map',
            '0:v:0',
            '-frames:v',
            '1',
            '-vf',
            'scale=480:-2',
            '-q:v',
            '4',
            temporary.path,
          ]);
          unawaited(process.stdout.drain<void>());
          unawaited(process.stderr.drain<void>());
          final code = await process.exitCode.timeout(
            const Duration(seconds: 12),
            onTimeout: () {
              process?.kill();
              return -1;
            },
          );
          if (code == 0 &&
              await temporary.exists() &&
              await temporary.length() > 0) {
            await temporary.rename(output.path);
            return output.uri.toString();
          }
        } finally {
          process?.kill();
        }
      }
      if (await temporary.exists()) await temporary.delete();
    } catch (_) {
      /* Missing/corrupt media keeps the existing offline fallback. */
    }
    return null;
  }
}
