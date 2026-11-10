import '../../core/download/windows_download_storage.dart';
import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/download/download_prefs.dart';
import '../../core/download/download_size_estimate.dart';
import '../../core/models/video_source.dart';
import '../../core/theme/app_colors.dart';

/// One selected-stream preview, not one request per mirror or batch episode.
/// Batch totals extrapolate from one sample and stay explicitly approximate.
class DownloadSizePreview extends StatefulWidget {
  const DownloadSizePreview({super.key, required this.source,
    this.runtimeMinutes, this.quality, this.count = 1, this.createEstimator, this.readFreeBytes});
  final VideoSource source;
  final int? runtimeMinutes;
  final String? quality;
  final int count;
  final DownloadSizeEstimator Function()? createEstimator;
  final Future<int?> Function()? readFreeBytes;
  @override State<DownloadSizePreview> createState() => _DownloadSizePreviewState();
}

class _DownloadSizePreviewState extends State<DownloadSizePreview> {
  late DownloadSizeEstimator _estimator;
  DownloadSizeEstimate? _estimate;
  bool _loading = true;
  int _generation = 0;
  int? _freeBytes;
  @override void initState() { super.initState(); _load(); _loadCapacity(); }
  @override void didUpdateWidget(DownloadSizePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source || oldWidget.runtimeMinutes != widget.runtimeMinutes ||
        oldWidget.quality != widget.quality) {
      _estimator.dispose(); _load();
    }
  }

  /// Capacity failure is unknown, not zero; reads never change the folder.
  Future<void> _loadCapacity() async {
    try {
      final read = widget.readFreeBytes;
      final bytes = read != null ? await read() : widget.createEstimator == null
          ? await windowsDownloadFreeBytes(sl<DownloadPrefs>().locationUri) : null;
      if (mounted) setState(() => _freeBytes = bytes);
    } catch (_) { /* Unavailable drives do not fabricate a low-space warning. */ }
  }

  /// Request identity prevents an old server/quality response replacing new UI.
  void _load() {
    _estimate = null; _loading = true;
    final generation = ++_generation;
    final prefs = widget.createEstimator == null ? sl<DownloadPrefs>() : null;
    _estimator = widget.createEstimator?.call() ?? DownloadSizeEstimator(
      cooldownUntil: (uri) => prefs!.hostCooldownUntil(uri),
      onRateLimited: (uri, hint) async { await prefs!.rememberHostCooldown(uri, hint); });
    _estimator.estimate(widget.source, runtimeMinutes: widget.runtimeMinutes,
      quality: widget.quality).then((value) {
        if (!mounted || generation != _generation) return;
        setState(() { _estimate = value; _loading = false; });
      });
  }

  @override void dispose() { _generation++; _estimator.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) {
    final estimate = _estimate;
    final text = _loading ? 'Estimating download size...' : estimate == null
      ? 'Download size unavailable' : widget.count > 1
        ? '${formatDownloadEstimate(estimate.bytes * widget.count)} total - based on one episode'
        : '${formatDownloadEstimate(estimate.bytes)} - approximate${estimate.solid ? '' : ' (assumed bitrate)'}';
    final low = downloadEstimateExceedsSpace(freeBytes: _freeBytes,
      estimatedBytes: estimate == null ? null : estimate.bytes * widget.count,
      solid: estimate?.solid ?? false);
    return Padding(padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(text, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        if (_freeBytes != null) Text('${formatDownloadEstimate(_freeBytes!).replaceFirst('~', '')} available in download location',
          style: const TextStyle(fontSize: 12, color: AppColors.textTertiary)),
        if (low) Text('Low storage: this estimate exceeds the available space. Free space or choose another download folder.',
          style: TextStyle(fontSize: 12, color: AppColors.accent)),
      ]));
  }
}
