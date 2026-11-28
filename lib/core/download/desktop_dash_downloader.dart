import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import 'dash_manifest.dart';

/// Windows only: saves one DASH (`.mpd`) stream as a single MP4 file.
///
/// The app has its own HLS segment downloader but none for DASH, so DASH
/// links (MovieBox "DASH" servers) used to be skipped. The bundled ffmpeg
/// (the same engine the audio merge uses) already reads DASH: it is told
/// which video rendition (the height the viewer picked) and which audio
/// rendition to keep, and copies them into one file without re-encoding.
///
/// ffmpeg copying a DASH stream cannot carry on from a half-saved file, so a
/// network drop cannot be resumed here. The next best is done instead: a
/// run that ended because of the network is started again (after the
/// network is back) up to [networkRetries] times before the save fails, and
/// time spent offline never counts as a stall.
class DesktopDashDownloader {
  DesktopDashDownloader({
    String? executablePath,
    Dio? dio,
    this.networkDown,
    this.waitForNetwork,
    this.stallLimit = defaultStallLimit,
  }) : executablePath =
           executablePath ??
           '${File(Platform.resolvedExecutable).parent.path}/engines/ffmpeg/ffmpeg.exe',
       _dio = dio;

  /// Path to ffmpeg.exe (bundled beside the app in production).
  final String executablePath;
  final Dio? _dio;

  /// True while the app knows the network is down. Optional.
  final bool Function()? networkDown;

  /// Completes when the network is back (at once when it is up). Optional.
  final Future<void> Function()? waitForNetwork;

  /// True only on Windows with the bundled engine present.
  bool get available => Platform.isWindows && File(executablePath).existsSync();

  /// When the saved time and size stop growing for this long, the transfer
  /// is stuck (repeated progress lines with the same values do not count).
  static const Duration defaultStallLimit = Duration(minutes: 2);

  /// See [defaultStallLimit]. Only time with the network up counts.
  final Duration stallLimit;

  /// How many times a run that the network ended is started again.
  static const int networkRetries = 5;

  /// Downloads [url] into [outputPath] (MP4). [quality] is the picked label
  /// ("720p", or "best"); an episode without that height gets the nearest
  /// lower one. Returns null on success, 'canceled' when [canceled] stopped
  /// it, or a short plain-text reason (never a signed URL) on failure.
  Future<String?> download({
    required String url,
    required Map<String, String> headers,
    required String outputPath,
    required String quality,
    String? audioLanguage,
    required bool Function() canceled,
    required void Function(double progress) onProgress,
  }) async {
    if (!available) return 'The bundled download engine is unavailable';
    if (canceled()) return 'canceled';
    // Read the manifest first: it names the renditions and their order,
    // which is how the picked height becomes an ffmpeg stream number.
    var manifest = await fetchDashManifest(url, headers, dio: _dio);
    // Offline when the manifest was asked for: wait for the network once
    // and ask again, instead of calling the stream unreadable.
    if (manifest == null && networkDown?.call() == true) {
      await _untilOnline(canceled);
      if (canceled()) return 'canceled';
      manifest = await fetchDashManifest(url, headers, dio: _dio);
    }
    if (canceled()) return 'canceled';
    if (manifest == null) return 'The stream manifest could not be read';
    final videoIndex = manifest.videoIndexFor(dashWantedHeight(quality));
    if (videoIndex == null) return 'The stream lists no video';
    // Audio language is a hard rule for a batch (same as the Windows HLS
    // path): a stream without the asked language fails with the same fixed
    // message, so the manager tries the next mirror instead of saving
    // another language.
    if (manifest.audioLanguageMissing(audioLanguage)) {
      return 'The selected audio language '
          '(${audioLanguage!.trim().toLowerCase()}) is unavailable in this stream';
    }
    final audioIndex = manifest.audioIndexFor(audioLanguage);
    for (var attempt = 0; ; attempt++) {
      final run = await _runOnce(
        url: url,
        headers: headers,
        outputPath: outputPath,
        videoIndex: videoIndex,
        audioIndex: audioIndex,
        total: manifest.duration,
        canceled: canceled,
        onProgress: onProgress,
      );
      if (!run.network || attempt >= networkRetries || canceled()) {
        return run.result;
      }
      // The network ended this run: wait for it, then start over.
      await _untilOnline(canceled);
      if (canceled()) return 'canceled';
    }
  }

  /// One ffmpeg run. `network` is true when the run most likely ended
  /// because the connection did (a stall, or a failed exit while the network
  /// was down at some point during the run).
  Future<({String? result, bool network})> _runOnce({
    required String url,
    required Map<String, String> headers,
    required String outputPath,
    required int videoIndex,
    required int? audioIndex,
    required Duration? total,
    required bool Function() canceled,
    required void Function(double progress) onProgress,
  }) async {
    // Written beside the final name and renamed at the end, so a half
    // download never looks like a finished episode.
    final partial = '$outputPath.part';
    Process? process;
    Timer? monitor;
    var interrupted = false;
    var stalled = false;
    var sawOffline = false;
    var lastTick = DateTime.now();
    // Furthest output time and size ffmpeg has reported. ffmpeg prints a
    // progress block about every half second even while nothing arrives,
    // so only a value that GROWS counts as "data is still coming".
    var lastOutUs = -1;
    var lastSize = -1;
    try {
      await _deleteQuietly(partial);
      process = await Process.start(executablePath, [
        '-nostdin',
        '-hide_banner',
        '-loglevel',
        'error',
        '-y',
        // Same headers the player sends (Referer, cookies, user agent);
        // ffmpeg's DASH reader passes them on to every segment request.
        if (headers.isNotEmpty) ...['-headers', _headerBlock(headers)],
        // Give up on a dead connection instead of waiting forever. Two
        // minutes, so a Wi-Fi extender restarting does not end the run.
        '-rw_timeout',
        '120000000',
        '-i',
        url,
        '-map',
        '0:v:$videoIndex',
        if (audioIndex != null) ...['-map', '0:a:$audioIndex?'],
        '-c',
        'copy',
        // Moves the index to the front so the saved file seeks at once.
        '-movflags',
        '+faststart',
        '-progress',
        'pipe:1',
        '-nostats',
        '-f',
        'mp4',
        partial,
      ], runInShell: false);
      final child = process;
      // Completes when ffmpeg's progress output ends. Set up here, before
      // the output can finish: `asFuture()` asked for AFTER the output had
      // already ended (ffmpeg closes it just before it exits) never
      // completes, which left a finished episode stuck at 99% as a .part.
      final progressDone = Completer<void>();
      // ffmpeg's progress block: "out_time_us=12345678" per update.
      child.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) {
              // Saved bytes growing also proves the transfer is alive (the
              // time can sit still briefly while a large fragment lands).
              if (line.startsWith('total_size=')) {
                final size = int.tryParse(line.substring('total_size='.length));
                if (size != null && size > lastSize) {
                  lastSize = size;
                  lastTick = DateTime.now();
                }
                return;
              }
              if (!line.startsWith('out_time_us=')) return;
              final us = int.tryParse(line.substring('out_time_us='.length));
              if (us == null || us < 0) return;
              // A repeated time (the same block printed again) is no progress.
              if (us <= lastOutUs) return;
              lastOutUs = us;
              lastTick = DateTime.now();
              if (total == null) return;
              final f = us / total.inMicroseconds;
              onProgress(f.clamp(0.0, 0.99));
            },
            onDone: () {
              if (!progressDone.isCompleted) progressDone.complete();
            },
            // A broken pipe only ends the progress, never the download.
            onError: (Object _) {
              if (!progressDone.isCompleted) progressDone.complete();
            },
            cancelOnError: true,
          );
      final stderr = child.stderr.drain<void>();
      monitor = Timer.periodic(const Duration(milliseconds: 200), (_) {
        interrupted = interrupted || canceled();
        // Offline time is not a stall: the clock restarts while it lasts.
        if (networkDown?.call() == true) {
          sawOffline = true;
          lastTick = DateTime.now();
        }
        stalled = DateTime.now().difference(lastTick) > stallLimit;
        if (interrupted || stalled) child.kill();
      });
      final exit = await child.exitCode;
      // ffmpeg has exited, so its output is closed or about to be; the
      // short timeout only guards a pipe that never reports its end.
      await progressDone.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {},
      );
      await stderr
          .timeout(const Duration(seconds: 5), onTimeout: () {})
          .catchError((_) {});
      if (interrupted || canceled()) {
        await _deleteQuietly(partial);
        return (result: 'canceled', network: false);
      }
      if (stalled) {
        await _deleteQuietly(partial);
        return (result: 'The download stopped receiving data', network: true);
      }
      final file = File(partial);
      if (exit != 0 ||
          !await file.exists() ||
          await file.length() == 0 ||
          !savedWhole(lastOutUs, total)) {
        // ffmpeg's DASH reader skips fragments it cannot open and still
        // exits 0, so a short file is a failed save too: the manager then
        // tries the next mirror or offers Retry instead of keeping a gap.
        await _deleteQuietly(partial);
        return (
          result: 'This DASH stream could not be saved',
          network: sawOffline || networkDown?.call() == true,
        );
      }
      await _deleteQuietly(outputPath);
      await file.rename(outputPath);
      onProgress(1);
      return (result: null, network: false);
    } catch (_) {
      await _deleteQuietly(partial);
      return (result: 'The download engine could not finish', network: false);
    } finally {
      monitor?.cancel();
      process?.kill();
    }
  }

  /// Waits for [waitForNetwork], waking every quarter second for a cancel.
  Future<void> _untilOnline(bool Function() canceled) async {
    final wait = waitForNetwork;
    if (wait == null) return;
    var settled = false;
    final gate = wait()
        .catchError((Object _) {})
        .whenComplete(() => settled = true);
    while (!settled && !canceled()) {
      await Future.any([
        gate,
        Future<void>.delayed(const Duration(milliseconds: 250)),
      ]);
    }
  }

  /// Share of the episode length a save must reach to count as whole. A
  /// little under 100% because the manifest length and the last fragment's
  /// end time rarely agree to the frame.
  static const double wholeShare = 0.97;

  /// True when the furthest output time ffmpeg reported ([outUs], in
  /// microseconds; -1 when none came) covers at least [wholeShare] of the
  /// manifest's [total] length. Unknown length cannot be checked, so it
  /// passes (exit code and file size still guard it).
  static bool savedWhole(int outUs, Duration? total) {
    if (total == null || total.inMicroseconds <= 0) return true;
    return outUs >= total.inMicroseconds * wholeShare;
  }

  /// Headers as ffmpeg wants them: one "Name: value" per line, CRLF ended.
  static String _headerBlock(Map<String, String> headers) => headers.entries
      .where((e) => e.key.trim().isNotEmpty)
      // A stray line break inside a value would start a fake header.
      .map(
        (e) =>
            '${e.key.trim()}: ${e.value.replaceAll(RegExp(r'[\r\n]'), '')}\r\n',
      )
      .join();

  static Future<void> _deleteQuietly(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
