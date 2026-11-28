import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../playback/subtitle_language.dart';
import 'file_audio_transaction.dart';

/// Verifies the requested spoken language in downloaded local media and makes
/// that track the sole/default audio without re-encoding video. Originals remain
/// intact until both the remux and a second probe have succeeded.
class DesktopFileAudio {
  DesktopFileAudio({String? engineDirectory})
    : engineDirectory =
          engineDirectory ??
          '${File(Platform.resolvedExecutable).parent.path}/engines/ffmpeg';

  final String engineDirectory;

  /// Null language keeps source audio untouched. Untagged audio is not evidence
  /// of a requested language, even when a provider called its stream "English".
  Future<String?> finalize(
    String path,
    String? language,
    bool Function() canceled,
  ) async {
    if (language == null || language.isEmpty) return null;
    final wanted = languageByPref(language);
    if (wanted == null) return 'The selected audio language is not supported';
    if (canceled()) return 'canceled';
    final input = File(path);
    final recovery = await FileAudioTransaction.recover(path);
    if (recovery != null) return recovery;
    Directory? scratch;
    try {
      if (!await File('$engineDirectory/ffprobe.exe').exists() ||
          !await File('$engineDirectory/ffmpeg.exe').exists()) {
        return 'The bundled audio selection engine is unavailable';
      }
      final streams = await _probe(path, canceled);
      if (streams == null) {
        return canceled()
            ? 'canceled'
            : 'The downloaded audio could not be inspected';
      }
      final audios = streams.where((s) => s['codec_type'] == 'audio').toList();
      final matching = audios.where((s) {
        final tags = s['tags'];
        return tags is Map &&
            matchesSourceLang('${tags['language'] ?? ''}', wanted);
      }).toList();
      if (matching.isEmpty) {
        return 'The selected audio language (${wanted.iso1}) is unavailable in this file';
      }
      // Preserve the source's default only among tracks in the requested language.
      final selected = matching.firstWhere(
        (s) => s['disposition'] is Map && s['disposition']['default'] == 1,
        orElse: () => matching.first,
      );
      final index = selected['index'];
      if (index is! int) return 'The downloaded audio could not be inspected';
      if (audios.length == 1) return null;
      scratch = await input.parent.createTemp('.zangetsu-file-audio-');
      final extension = path.split('.').last.toLowerCase();
      if (!const {'mp4', 'mkv', 'webm', 'mov', 'm4v'}.contains(extension)) {
        return 'The downloaded container does not support audio selection';
      }
      final output = '${scratch.path}/selected.$extension';
      final result = await _run('ffmpeg.exe', [
        '-nostdin',
        '-hide_banner',
        '-loglevel',
        'error',
        '-y',
        '-protocol_whitelist',
        'file,pipe,crypto,data',
        '-i',
        path,
        '-map',
        '0:v?',
        '-map',
        '0:$index',
        '-map',
        '0:s?',
        '-map',
        '0:t?',
        '-map_metadata',
        '0',
        '-map_chapters',
        '0',
        '-c',
        'copy',
        '-metadata:s:a:0',
        'language=${wanted.iso2t}',
        '-disposition:a:0',
        'default',
        output,
      ], canceled);
      if (canceled()) return 'canceled';
      if (result == null || result.exit != 0) {
        return 'The selected audio could not be saved';
      }
      final verified = await _probe(output, canceled);
      if (canceled()) return 'canceled';
      final verifiedAudio = verified
          ?.where((s) => s['codec_type'] == 'audio')
          .toList();
      if (verifiedAudio == null ||
          verifiedAudio.length != 1 ||
          !matchesSourceLang(
            '${(verifiedAudio.single['tags'] as Map?)?['language'] ?? ''}',
            wanted,
          ) ||
          (verifiedAudio.single['disposition'] as Map?)?['default'] != 1) {
        return 'The selected audio could not be verified';
      }
      return await FileAudioTransaction.publish(
        input,
        File(output),
        scratch,
        canceled,
      );
    } catch (_) {
      return canceled() ? 'canceled' : 'The selected audio could not be saved';
    } finally {
      // Do not erase a rollback copy if restoration itself failed. This rare
      // storage error leaves a recoverable original instead of deleting data.
      if (scratch != null &&
          await scratch.exists() &&
          !await File(
            '${scratch.path}/${FileAudioTransaction.journalName}',
          ).exists()) {
        final backups = await scratch
            .list()
            .where((f) => f.uri.pathSegments.last.startsWith('original.'))
            .toList();
        if (await input.exists() || backups.isEmpty) {
          await scratch.delete(recursive: true);
        }
      }
    }
  }

  /// Restrict probing to local-file protocols and request structured metadata.
  Future<List<Map<String, dynamic>>?> _probe(
    String path,
    bool Function() canceled,
  ) async {
    final result = await _run(
      'ffprobe.exe',
      [
        '-v',
        'error',
        '-protocol_whitelist',
        'file,pipe,crypto,data',
        '-show_streams',
        '-of',
        'json',
        path,
      ],
      canceled,
      capture: true,
    );
    if (result == null || result.exit != 0) return null;
    final decoded = jsonDecode(result.output);
    if (decoded is! Map || decoded['streams'] is! List) return null;
    return (decoded['streams'] as List)
        .whereType<Map>()
        .map((s) => Map<String, dynamic>.from(s))
        .toList();
  }

  /// Drain child pipes and terminate on cancel/deadline; never log file metadata
  /// or raw process diagnostics, which may contain private paths or source URLs.
  Future<({int exit, String output})?> _run(
    String executable,
    List<String> args,
    bool Function() canceled, {
    bool capture = false,
  }) async {
    Process? process;
    Timer? monitor;
    final watch = Stopwatch()..start();
    var interrupted = false;
    try {
      if (canceled()) return null;
      process = await Process.start(
        '$engineDirectory/$executable',
        args,
        runInShell: false,
      );
      final child = process;
      final output = capture
          ? child.stdout.transform(utf8.decoder).join()
          : child.stdout.drain<void>().then((_) => '');
      final errors = child.stderr.drain<void>();
      monitor = Timer.periodic(const Duration(milliseconds: 100), (_) {
        interrupted =
            interrupted ||
            canceled() ||
            watch.elapsed > const Duration(minutes: 5);
        if (interrupted) child.kill();
      });
      final exit = await child.exitCode;
      await errors;
      final text = await output;
      return interrupted || canceled() ? null : (exit: exit, output: text);
    } finally {
      monitor?.cancel();
      process?.kill();
      watch.stop();
    }
  }
}
