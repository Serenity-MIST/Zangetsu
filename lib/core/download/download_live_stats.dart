import '../../l10n/l10n.dart';

/// Live transfer numbers for one download (dl-5): kept in memory only, never
/// saved, because they are stale the moment the app restarts.
class DownloadLiveStats {
  const DownloadLiveStats({this.bytesPerSecond, this.timeLeft});

  /// Current transfer rate, or null when it is not known yet (for example
  /// an HLS stream whose total size is unknown).
  final double? bytesPerSecond;

  /// Estimated time until the download finishes, or null when unknown.
  final Duration? timeLeft;
}

/// Turns a stream of 0..1 progress samples into a rate (dl-5).
///
/// The HLS downloader only reports a fraction, so speed and time left are
/// derived here: fraction-per-second, smoothed so one slow segment does not
/// make the estimate jump around.
class ProgressRateEstimator {
  double? _lastProgress;
  int? _lastMs;

  /// Smoothed fraction of the whole file per second.
  double? _fractionPerSecond;

  /// Adds a sample taken at [nowMs]. [bytesTotal] (when above 0) converts the
  /// fraction rate into bytes per second.
  DownloadLiveStats add(double progress, int nowMs, {int bytesTotal = 0}) {
    final lastProgress = _lastProgress;
    final lastMs = _lastMs;
    // A restart from 0 (retry, mirror switch) begins a fresh estimate.
    if (lastProgress == null || lastMs == null || progress < lastProgress) {
      _lastProgress = progress;
      _lastMs = nowMs;
      _fractionPerSecond = null;
      return const DownloadLiveStats();
    }
    final elapsed = nowMs - lastMs;
    // Too-close samples carry no reliable rate; keep the previous one.
    if (elapsed >= 200) {
      final sample = (progress - lastProgress) * 1000 / elapsed;
      final previous = _fractionPerSecond;
      // Same weighting background_downloader uses for its own speed.
      _fractionPerSecond = previous == null
          ? sample
          : (previous * 3 + sample) / 4;
      _lastProgress = progress;
      _lastMs = nowMs;
    }
    final rate = _fractionPerSecond;
    if (rate == null || rate <= 0) return const DownloadLiveStats();
    final seconds = (1 - progress).clamp(0.0, 1.0) / rate;
    return DownloadLiveStats(
      bytesPerSecond: bytesTotal > 0 ? rate * bytesTotal : null,
      // Cap silly estimates (a stalled stream) at a day.
      timeLeft: seconds.isFinite && seconds < 86400
          ? Duration(milliseconds: (seconds * 1000).round())
          : null,
    );
  }
}

/// '4.2 MB/s' style text for a transfer rate.
String formatTransferRate(double bytesPerSecond) {
  const units = ['B/s', 'KB/s', 'MB/s', 'GB/s'];
  var value = bytesPerSecond;
  var unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  final digits = value >= 100 || unit == 0 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

/// Short 'time left' text: '45 s left', '12 min left', '1 h 5 min left'.
String formatTimeLeft(Duration left) {
  // Called from row builders and the taskbar alike, so it uses appL10n.
  final l10n = appL10n;
  final seconds = left.inSeconds;
  if (seconds < 60) return l10n.timeLeftSeconds(seconds < 1 ? 1 : seconds);
  final minutes = left.inMinutes;
  if (minutes < 60) return l10n.timeLeftMinutes(minutes);
  final hours = left.inHours;
  final rest = minutes - hours * 60;
  return rest == 0
      ? l10n.timeLeftHours(hours)
      : l10n.timeLeftHoursMinutes(hours, rest);
}
