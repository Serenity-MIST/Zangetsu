import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../core/desktop/desktop_context_menu.dart';
import '../../core/desktop/desktop_dialogs.dart';
import '../../core/desktop/desktop_reveal.dart';
import '../../core/di/injector.dart';
import '../../core/download/download_manager.dart';
import '../../core/download/download_record.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/app_toast.dart';
import '../../core/ui/desktop_docked_panel.dart';
import '../../l10n/l10n.dart';
import 'downloads_screen.dart' show launchDownloadedEpisode;

class EpisodeDownloadIcon extends StatelessWidget {
  const EpisodeDownloadIcon({
    super.key,
    required this.sourceId,
    required this.showId,
    required this.episodeId,
    required this.onTap,
    this.finishedMenu = false,
  });

  final String sourceId;
  final String showId;
  final String episodeId;
  final VoidCallback onTap;

  /// Windows (show-1): when true, clicking a finished download's tick opens
  /// [showFinishedMenu] instead of [onTap]. Off by default so the player's
  /// episode panel keeps today's behaviour.
  final bool finishedMenu;

  @override
  Widget build(BuildContext context) {
    final manager = sl<DownloadManager>();
    return ListenableBuilder(
      listenable: manager,
      builder: (context, _) {
        final rec = manager.recordFor(sourceId, showId, episodeId);
        final s = rec?.status;
        // While a download is live (or paused/queued/resolving), tapping the ring
        // opens a Pause/Cancel menu instead of re-opening the server picker.
        final inProgress =
            rec != null &&
            (s == DownloadStatus.downloading ||
                s == DownloadStatus.paused ||
                s == DownloadStatus.queued ||
                s == DownloadStatus.resolving);
        // Windows (show-1): a finished tick opens the file menu.
        final finished =
            finishedMenu &&
            rec != null &&
            s == DownloadStatus.done &&
            defaultTargetPlatform == TargetPlatform.windows;
        return Builder(
          // Builder: the menu anchors to the icon itself.
          builder: (iconContext) => _glyph(
            context.l10n,
            s,
            rec?.progress ?? 0,
            onPressed: inProgress
                ? () => showDownloadMenu(context, manager, rec)
                : finished
                ? () => unawaited(
                    showFinishedMenu(
                      iconContext,
                      manager,
                      rec,
                      onDownloadAgain: onTap,
                    ),
                  )
                : onTap,
          ),
        );
      },
    );
  }

  /// Windows (show-1): the small menu a finished episode's tick opens, in
  /// place of a fresh source search: Play offline, Show in folder, Delete
  /// download (after a confirm; the manager recycles the file on Windows)
  /// and Download again (another cut or quality, through [onDownloadAgain]).
  /// Opens under [context]'s box, dropdown style.
  static Future<void> showFinishedMenu(
    BuildContext context,
    DownloadManager manager,
    DownloadRecord rec, {
    required VoidCallback onDownloadAgain,
  }) async {
    // Follow-up toasts, the confirm and the player use the tick's own context
    // (it stays in the page after the menu closes). Not the navigator's own
    // context: that sits above the navigator's Overlay, so a toast from it
    // finds no overlay and throws.
    final host = context;
    final label = rec.episodeTitle.trim().isNotEmpty
        ? rec.episodeTitle
        : rec.showTitle;
    await showDesktopContextMenu<void>(
      context,
      anchor: context,
      items: [
        DesktopMenuItem(
          label: host.l10n.playOffline,
          icon: Icons.play_arrow_rounded,
          onTap: () {
            if (host.mounted) unawaited(launchDownloadedEpisode(host, rec));
          },
        ),
        DesktopMenuItem(
          label: host.l10n.showInFolder,
          icon: Icons.folder_open_rounded,
          onTap: () async {
            final path = rec.filePath;
            final shown = path != null && await revealInExplorer(path);
            if (!shown && host.mounted) {
              showAppToast(host, host.l10n.couldntFindDownloadedFile);
            }
          },
        ),
        DesktopMenuItem(
          label: host.l10n.deleteDownload,
          icon: Icons.delete_outline_rounded,
          destructive: true,
          onTap: () async {
            if (!host.mounted) return;
            final ok = await showDesktopConfirm(
              host,
              title: host.l10n.deleteDownloadQuestion,
              message: host.l10n.downloadedFileWillBeDeleted(label),
              confirmLabel: host.l10n.delete,
              destructive: true,
            );
            if (!ok) return;
            await manager.delete(rec);
            if (host.mounted) showAppToast(host, host.l10n.downloadDeleted);
          },
        ),
        const DesktopMenuItem<void>.divider(),
        // Another cut or quality: the normal picker, which still says when
        // the same cut is already saved.
        DesktopMenuItem(
          label: host.l10n.downloadAgain,
          icon: Icons.download_rounded,
          onTap: onDownloadAgain,
        ),
      ],
    );
  }

  Widget _glyph(
    AppLocalizations l10n,
    DownloadStatus? status,
    double progress, {
    required VoidCallback onPressed,
  }) {
    final child = switch (status) {
      DownloadStatus.done => Icon(
        Icons.download_done_rounded,
        color: AppColors.accent,
        size: 24,
      ),
      DownloadStatus.downloading || DownloadStatus.paused => SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(
          value: progress > 0 ? progress : null,
          strokeWidth: 2.4,
          color: AppColors.accent,
          backgroundColor: AppColors.surface2,
        ),
      ),
      DownloadStatus.queued || DownloadStatus.resolving => const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: AppColors.textSecondary,
        ),
      ),
      DownloadStatus.unsupported => const Icon(
        Icons.cloud_off_outlined,
        color: AppColors.textTertiary,
        size: 22,
      ),
      DownloadStatus.failed => Icon(
        Icons.refresh_rounded,
        color: AppColors.accent,
        size: 24,
      ),
      // null (never downloaded) or canceled → offer to download.
      _ => const Icon(
        Icons.file_download_outlined,
        color: AppColors.textPrimary,
        size: 24,
      ),
    };
    final label = switch (status) {
      DownloadStatus.done => l10n.downloaded,
      DownloadStatus.downloading || DownloadStatus.paused => l10n.downloading,
      DownloadStatus.queued || DownloadStatus.resolving => l10n.downloading,
      DownloadStatus.unsupported => l10n.downloadUnsupported,
      DownloadStatus.failed => l10n.retryDownload,
      _ => l10n.downloadEpisode,
    };
    return IconButton(
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      splashRadius: 22,
      tooltip: label,
      icon: child,
    );
  }

  // Tap on a live download's ring → a small Pause/Resume + Cancel sheet, rather
  // than the server picker (which only makes sense before a download starts).
  static void showDownloadMenu(
    BuildContext context,
    DownloadManager manager,
    DownloadRecord rec,
  ) {
    final l10n = context.l10n;
    final paused = rec.status == DownloadStatus.paused;
    // Pause/Resume + Cancel rows, shared by the phone sheet and the Windows
    // dialog.
    List<Widget> actions(BuildContext sheetContext) => [
      ListTile(
        leading: Icon(
          paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
          color: AppColors.textPrimary,
        ),
        title: Text(
          paused ? l10n.resumeDownload : l10n.pauseDownload,
          style: AppText.body.copyWith(color: AppColors.textPrimary),
        ),
        onTap: () {
          Navigator.pop(sheetContext);
          if (paused) {
            manager.resume(rec);
          } else {
            manager.pause(rec);
          }
        },
      ),
      ListTile(
        leading: Icon(Icons.close_rounded, color: AppColors.accent),
        title: Text(
          l10n.cancelDownload,
          style: AppText.body.copyWith(color: AppColors.accent),
        ),
        onTap: () {
          Navigator.pop(sheetContext);
          manager.cancel(rec);
        },
      ),
    ];
    // Windows: a small centred graphite dialog (title + close, Esc and
    // click-outside close) instead of a phone bottom sheet.
    if (desktopPanelsEnabled) {
      showDesktopDockedPanel<void>(
        context,
        centred: true,
        width: 380,
        dialogKey: const ValueKey('download-menu-desktop-dialog'),
        builder: (dialogContext) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DesktopPanelTitleBar(
              title: rec.episodeTitle.trim().isNotEmpty
                  ? rec.episodeTitle
                  : l10n.downloading,
              subtitle: rec.showTitle,
            ),
            Divider(height: 1, color: DesktopPanelColors.edge),
            const SizedBox(height: 6),
            ...actions(dialogContext),
            const SizedBox(height: 10),
          ],
        ),
      );
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      barrierColor: Colors.black54,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: actions(sheetContext),
        ),
      ),
    );
  }
}
