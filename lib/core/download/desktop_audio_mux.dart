import 'dart:async';
import 'dart:io';
import '../playback/subtitle_language.dart';

/// Copies one downloaded video and one selected audio track into a local TS.
/// Production resolves only the portable engine bundled beside the app; tests
/// can explicitly inject an installed engine without changing user settings.
class DesktopAudioMux {
  DesktopAudioMux({String? executablePath})
    : executablePath =
          executablePath ??
          '${File(Platform.resolvedExecutable).parent.path}/engines/ffmpeg/ffmpeg.exe';
  final String executablePath;
  bool get available => Platform.isWindows && File(executablePath).existsSync();

  Future<String?> merge(
    String video,
    String audio,
    String output,
    String? language,
    bool Function() canceled,
  ) async {
    if (!available) return 'The bundled audio merge engine is unavailable';
    if (canceled()) return 'canceled';
    if (output == video || output == audio) {
      return 'Invalid audio merge destination';
    }
    final wanted = language == null ? null : languageByPref(language);
    Process? process;
    Timer? monitor;
    var interrupted = false;
    var timedOut = false;
    final elapsed = Stopwatch()..start();
    try {
      process = await Process.start(executablePath, [
        '-nostdin',
        '-hide_banner',
        '-loglevel',
        'error',
        '-y',
        '-protocol_whitelist',
        'file,pipe,crypto,data',
        '-i',
        video,
        '-protocol_whitelist',
        'file,pipe,crypto,data',
        '-i',
        audio,
        '-map',
        '0:v:0',
        '-map',
        '1:a:0',
        '-c',
        'copy',
        '-map_metadata:s:a:0',
        '1:s:a:0',
        if (wanted != null) ...['-metadata:s:a:0', 'language=${wanted.iso2t}'],
        '-disposition:a:0',
        'default',
        '-f',
        'mpegts',
        output,
      ], runInShell: false);
      final child = process;
      final stdout = child.stdout.drain<void>();
      final stderr = child.stderr.drain<void>();
      monitor = Timer.periodic(const Duration(milliseconds: 100), (_) {
        interrupted = interrupted || canceled();
        timedOut = elapsed.elapsed > const Duration(minutes: 5);
        if (interrupted || timedOut) child.kill();
      });
      final exit = await child.exitCode;
      await Future.wait([stdout, stderr]);
      if (interrupted || canceled()) return 'canceled';
      if (timedOut) return 'Audio merge timed out';
      if (exit != 0 ||
          !await File(output).exists() ||
          await File(output).length() == 0) {
        return 'The selected audio could not be merged with this video';
      }
      return null;
    } catch (_) {
      return 'The audio merge engine could not finish';
    } finally {
      monitor?.cancel();
      process?.kill();
      elapsed.stop();
    }
  }
}
