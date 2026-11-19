import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/download/download_live_stats.dart';
import '../../core/download/download_manager.dart';
import '../../core/download/download_record.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/desktop_docked_panel.dart';
import '../../l10n/l10n.dart';

/// The Windows download queue (dl-5): one panel at the top of the Downloads
/// library listing every running, waiting, paused and failed episode across
/// all shows, with speed and time left, plus Pause all / Resume all /
/// Retry failed. Per-row actions include Pause on waiting items and
/// 'Download next' (dl-6).
///
/// Renders nothing when the queue is empty, so the library can always embed
/// it. Only the row list follows the manager (about once a second while just
/// progress moves); each progress bar follows its own record (dl-7).
class DesktopActiveDownloadsPanel extends StatelessWidget {
  const DesktopActiveDownloadsPanel({super.key, required this.manager});

  /// The video download manager whose queue is shown.
  final DownloadManager manager;

  /// Rows visible before the list scrolls, so a long queue never pushes
  /// the library itself off screen.
  static const double _maxListHeight = 320;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: manager,
      builder: (context, _) {
        final items = manager.queueItems;
        if (items.isEmpty) return const SizedBox.shrink();
        return _panel(context, items);
      },
    );
  }

  Widget _panel(BuildContext context, List<DownloadRecord> items) {
    final running = items
        .where((r) =>
            r.status == DownloadStatus.downloading ||
            r.status == DownloadStatus.finalizing)
        .length;
    final waiting = items
        .where((r) =>
            r.status == DownloadStatus.queued ||
            r.status == DownloadStatus.resolving)
        .length;
    final paused = items.where((r) => r.status == DownloadStatus.paused).length;
    final failed = items.where((r) => r.status == DownloadStatus.failed).length;
    // Combined rate of everything moving right now.
    var totalRate = 0.0;
    for (final r in items) {
      totalRate += manager.speedOf(r.id) ?? 0;
    }

    final l10n = context.l10n;
    final summary = [
      if (running > 0) l10n.queueCountDownloading(running),
      if (waiting > 0) l10n.queueCountWaiting(waiting),
      if (paused > 0) l10n.queueCountPaused(paused),
      if (failed > 0) l10n.queueCountFailed(failed),
      if (totalRate > 0) formatTransferRate(totalRate),
    ].join(' · ');

    return Container(
      key: const ValueKey('desktop-active-downloads'),
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      decoration: BoxDecoration(
        color: DesktopPanelColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: DesktopPanelColors.edge),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header: title, counts and the bulk actions.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
            child: Row(
              children: [
                const Icon(
                  Icons.downloading_rounded,
                  size: 20,
                  color: AppColors.textSecondary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.downloadQueue,
                        style: AppText.body.copyWith(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        summary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.caption,
                      ),
                    ],
                  ),
                ),
                if (running + waiting > 0)
                  _HeaderAction(
                    key: const ValueKey('queue-pause-all'),
                    icon: Icons.pause_rounded,
                    label: l10n.pauseAll,
                    onPressed: () => unawaited(manager.pauseAll()),
                  ),
                if (paused > 0)
                  _HeaderAction(
                    key: const ValueKey('queue-resume-all'),
                    icon: Icons.play_arrow_rounded,
                    label: l10n.resumeAll,
                    onPressed: () => unawaited(manager.resumeAll()),
                  ),
                if (failed > 0)
                  _HeaderAction(
                    key: const ValueKey('queue-retry-failed'),
                    icon: Icons.refresh_rounded,
                    label: l10n.retryFailed,
                    onPressed: () => unawaited(manager.retryFailed()),
                  ),
              ],
            ),
          ),
          Divider(height: 1, thickness: 1, color: DesktopPanelColors.edge),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: _maxListHeight),
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: items.length,
              itemBuilder: (context, i) => _QueueRow(
                key: ValueKey('queue-row-${items[i].id}'),
                record: items[i],
                manager: manager,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A compact text button in the panel header.
class _HeaderAction extends StatelessWidget {
  const _HeaderAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: TextButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 18, color: AppColors.textPrimary),
        label: Text(
          label,
          style: AppText.caption.copyWith(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }
}

/// One queued / running / paused / failed episode.
class _QueueRow extends StatelessWidget {
  const _QueueRow({super.key, required this.record, required this.manager});

  final DownloadRecord record;
  final DownloadManager manager;

  /// 'Show · E3' (or the episode title when it has no number).
  static String titleOf(DownloadRecord r) {
    final n = r.episodeNumber;
    final episode = n == null
        ? r.episodeTitle
        : appL10n.episodeShort('${n == n.roundToDouble() ? n.toInt() : n}');
    return episode.isEmpty ? r.showTitle : '${r.showTitle} · $episode';
  }

  /// Status line under the title; progress text is filled in live below.
  String _status(DownloadRecord r) {
    switch (r.status) {
      case DownloadStatus.downloading:
        final parts = <String>[];
        final rate = manager.speedOf(r.id);
        final left = manager.timeLeftOf(r.id);
        if (rate != null && rate > 0) parts.add(formatTransferRate(rate));
        if (left != null) parts.add(formatTimeLeft(left));
        return parts.join(' · ');
      case DownloadStatus.finalizing:
        return appL10n.finishingUp;
      case DownloadStatus.resolving:
        return appL10n.findingASource;
      case DownloadStatus.queued:
        return r.retryAt != null
            ? appL10n.waitingToRetry
            : appL10n.waitingForFreeSlot;
      case DownloadStatus.paused:
        return appL10n.statusPaused;
      case DownloadStatus.failed:
        return r.error?.isNotEmpty == true
            ? r.error!
            : appL10n.downloadFailed;
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final r = record;
    final failed = r.status == DownloadStatus.failed;
    final showsBar = r.status == DownloadStatus.downloading ||
        r.status == DownloadStatus.finalizing ||
        r.status == DownloadStatus.paused;
    final status = _status(r);

    final actions = <Widget>[
      if (r.status == DownloadStatus.downloading ||
          r.status == DownloadStatus.queued ||
          r.status == DownloadStatus.resolving)
        _RowAction(
          icon: Icons.pause_rounded,
          tooltip: l10n.pause,
          onPressed: () => unawaited(manager.pause(r)),
        ),
      if (r.status == DownloadStatus.paused)
        _RowAction(
          icon: Icons.play_arrow_rounded,
          tooltip: l10n.resume,
          onPressed: () => unawaited(manager.resume(r)),
        ),
      if (failed && !r.isTorrent)
        _RowAction(
          icon: Icons.refresh_rounded,
          tooltip: l10n.retry,
          onPressed: () => unawaited(manager.retry(r)),
        ),
      // dl-6: jump the queue (failed rows already offer Retry).
      if (r.status != DownloadStatus.downloading &&
          r.status != DownloadStatus.finalizing &&
          !failed &&
          manager.canMoveToFront(r))
        _RowAction(
          icon: Icons.vertical_align_top_rounded,
          tooltip: appL10n.downloadNext,
          onPressed: () => unawaited(manager.moveToFront(r)),
        ),
      // Cancel / remove drops the record, like the tile menu's Cancel.
      _RowAction(
        icon: Icons.close_rounded,
        tooltip: failed ? l10n.delete : l10n.cancel,
        onPressed: () => unawaited(manager.delete(r)),
      ),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
      child: Row(
        children: [
          Icon(
            failed
                ? Icons.error_outline_rounded
                : r.status == DownloadStatus.paused
                ? Icons.pause_circle_outline_rounded
                : r.status == DownloadStatus.downloading
                ? Icons.download_rounded
                : Icons.schedule_rounded,
            size: 18,
            color: failed ? AppColors.accent : AppColors.textSecondary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  titleOf(r),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.body.copyWith(
                    color: AppColors.textPrimary,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 3),
                if (showsBar)
                  // Only this row repaints on each progress tick (dl-7).
                  ValueListenableBuilder<double>(
                    valueListenable: manager.progressListenable(r.id),
                    builder: (context, progress, _) => _ProgressLine(
                      progress: progress,
                      status: status,
                      paused: r.status == DownloadStatus.paused,
                      finalizing: r.status == DownloadStatus.finalizing,
                    ),
                  )
                else
                  Text(
                    status,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption.copyWith(
                      color: failed ? AppColors.accent : null,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          ...actions,
        ],
      ),
    );
  }
}

/// Percentage, speed / time left and a thin bar for a moving row.
class _ProgressLine extends StatelessWidget {
  const _ProgressLine({
    required this.progress,
    required this.status,
    required this.paused,
    required this.finalizing,
  });

  final double progress;
  final String status;
  final bool paused;
  final bool finalizing;

  @override
  Widget build(BuildContext context) {
    final value = progress.clamp(0.0, 1.0);
    final percent = '${(value * 100).floor()}%';
    final text = [
      if (!finalizing) percent,
      if (status.isNotEmpty) status,
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppText.caption,
        ),
        const SizedBox(height: 5),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            // Finalizing has no measurable progress: show it as busy.
            value: finalizing ? null : value,
            minHeight: 3,
            color: paused ? AppColors.textTertiary : AppColors.accent,
            backgroundColor: AppColors.surface2,
          ),
        ),
      ],
    );
  }
}

/// Small icon button used for per-row actions.
class _RowAction extends StatelessWidget {
  const _RowAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      visualDensity: VisualDensity.compact,
      iconSize: 18,
      tooltip: tooltip,
      icon: Icon(icon, color: AppColors.textSecondary),
      onPressed: onPressed,
    );
  }
}

/// Test hook: the row title format, shared with the notifications wording.
@visibleForTesting
String desktopQueueRowTitle(DownloadRecord r) => _QueueRow.titleOf(r);
