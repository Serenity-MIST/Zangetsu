import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../logging/app_logger.dart';

/// Name of the environment variable that turns the frame-time log on.
const desktopFrameLogVariable = 'ZANGETSU_FRAME_LOG';

/// How often a summary line is written while frames are being drawn.
const desktopFrameLogInterval = Duration(seconds: 2);

/// Windows-only diagnostic: when the app is started with the environment
/// variable ZANGETSU_FRAME_LOG=1, every 2 seconds in which frames were drawn
/// adds one line to the in-app log, for example
///
///   [frames] n=118 build avg/p90/max 2.1/3.4/9.8ms raster avg/p90/max
///   5.0/8.1/22.3ms over16ms=3 over33ms=1
///
/// so scrolling smoothness can be measured in the real release app on the
/// user's own PC. "build" is the time the app spent preparing a frame and
/// "raster" the time the graphics side spent drawing it. A frame counts as
/// over 16 ms (or 33 ms) when either part took longer than that, because
/// either one alone makes it miss a 60 Hz (or 30 Hz) screen refresh.
///
/// Off by default. When off nothing is registered at all, so it costs
/// nothing. Phone and TV never turn it on.
class DesktopFrameLog {
  DesktopFrameLog._(this._write);

  static DesktopFrameLog? _running;

  /// The running log, if it was turned on (for tests).
  @visibleForTesting
  static DesktopFrameLog? get running => _running;

  /// Turns the log on when this is Windows and the variable is set to 1.
  /// [environment] and [windows] are for tests; the app passes neither.
  /// Returns true when the log is now running.
  static bool startIfAsked({
    Map<String, String>? environment,
    bool? windows,
    void Function(String line)? write,
  }) {
    final onWindows =
        windows ??
        (!kIsWeb &&
            Platform.isWindows &&
            defaultTargetPlatform == TargetPlatform.windows);
    if (!onWindows || _running != null) return _running != null;
    final env = environment ?? Platform.environment;
    if (env[desktopFrameLogVariable]?.trim() != '1') return false;
    final log = DesktopFrameLog._(write ?? AppLogger.instance.log);
    _running = log;
    SchedulerBinding.instance.addTimingsCallback(log._onTimings);
    log._write(
      '[frames] frame-time log on ($desktopFrameLogVariable=1), one line '
      'every ${desktopFrameLogInterval.inSeconds} s while drawing',
    );
    return true;
  }

  /// Turns the log off again (for tests).
  @visibleForTesting
  static void stop() {
    final log = _running;
    if (log == null) return;
    _running = null;
    SchedulerBinding.instance.removeTimingsCallback(log._onTimings);
    log._timer?.cancel();
    log._frames.clear();
  }

  final void Function(String line) _write;

  /// Build and raster times (microseconds) of the frames in this window.
  final List<(int, int)> _frames = [];

  /// Runs while frames are arriving; none while the app is idle.
  Timer? _timer;

  void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      _frames.add((
        t.buildDuration.inMicroseconds,
        t.rasterDuration.inMicroseconds,
      ));
    }
    // The first frames after a quiet spell start a new 2 second window.
    _timer ??= Timer(desktopFrameLogInterval, _flush);
  }

  void _flush() {
    _timer = null;
    if (_frames.isEmpty) return;
    final line = desktopFrameSummary(_frames);
    _frames.clear();
    _write(line);
  }

  /// Writes what was collected so far straight away (for tests).
  @visibleForTesting
  void flushNow() {
    _timer?.cancel();
    _flush();
  }
}

/// One summary line for [frames], each a pair of (build, raster) times in
/// microseconds.
String desktopFrameSummary(List<(int, int)> frames) {
  final build = [for (final f in frames) f.$1]..sort();
  final raster = [for (final f in frames) f.$2]..sort();
  var over16 = 0, over33 = 0;
  for (final (b, r) in frames) {
    final worst = b > r ? b : r;
    if (worst > 16667) over16++;
    if (worst > 33333) over33++;
  }
  return '[frames] n=${frames.length} '
      'build avg/p90/max ${_stats(build)} '
      'raster avg/p90/max ${_stats(raster)} '
      'over16ms=$over16 over33ms=$over33';
}

/// "avg/p90/max" in milliseconds with one decimal, from [sorted] times in
/// microseconds (sorted from fastest to slowest).
String _stats(List<int> sorted) {
  if (sorted.isEmpty) return '0.0/0.0/0.0ms';
  final total = sorted.fold<int>(0, (sum, v) => sum + v);
  final avg = total / sorted.length;
  // 90th percentile: the time that 90 percent of frames were faster than.
  final index = ((sorted.length * 9 + 9) ~/ 10) - 1;
  final p90 = sorted[index.clamp(0, sorted.length - 1)];
  String ms(num micros) => (micros / 1000).toStringAsFixed(1);
  return '${ms(avg)}/${ms(p90)}/${ms(sorted.last)}ms';
}
