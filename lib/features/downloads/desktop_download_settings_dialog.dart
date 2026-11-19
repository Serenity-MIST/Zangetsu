import 'package:flutter/material.dart';

import '../../core/desktop/desktop_prefs.dart';
import '../../core/download/download_prefs.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/desktop_settings_surface.dart';
import '../settings/desktop_settings_slider.dart';
import '../../l10n/l10n.dart';

/// Windows "Download settings": a centered, bounded graphite dialog in the
/// style of the desktop settings dialogs. The caller owns the values and
/// persistence; this widget only reports slider moves and releases.
class DesktopDownloadSettingsDialog extends StatelessWidget {
  const DesktopDownloadSettingsDialog({
    super.key,
    required this.parallel,
    required this.connections,
    required this.onParallelChanged,
    required this.onParallelCommit,
    required this.onConnectionsChanged,
    required this.onConnectionsCommit,
  });

  final int parallel;
  final int connections;
  final ValueChanged<int> onParallelChanged;
  final ValueChanged<int> onParallelCommit;
  final ValueChanged<int> onConnectionsChanged;
  final ValueChanged<int> onConnectionsCommit;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Dialog(
      key: const ValueKey('desktop-download-settings'),
      // set-9: themed graphite colours (stock greys by default).
      backgroundColor: GraphiteSettingsColors.dialog,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: GraphiteSettingsColors.dialogEdge),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 520,
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 20, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.downloadSettings,
                      style: AppText.headline.copyWith(
                        fontSize: 22,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                    color: AppColors.textSecondary,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Divider(height: 1, color: GraphiteSettingsColors.dialogEdge),
              const SizedBox(height: 16),
              _SliderRow(
                key: const ValueKey('desktop-parallel-downloads'),
                icon: Icons.download_rounded,
                title: l10n.parallelDownloads,
                subtitle:
                    '${l10n.parallelDownloadsSubtitle} Applies right away: '
                    'raising it starts queued episodes now.',
                value: parallel,
                min: DownloadPrefs.parallelMin,
                max: DownloadPrefs.parallelMax,
                unit: (_) => 'at once',
                // DownloadPrefs.parallelDownloads' stored default.
                defaultValue: 3,
                onChanged: onParallelChanged,
                onCommit: onParallelCommit,
              ),
              const SizedBox(height: 8),
              _SliderRow(
                key: const ValueKey('desktop-connections-per-download'),
                icon: Icons.lan_outlined,
                title: l10n.connectionsPerDownload,
                subtitle:
                    '${l10n.connectionsPerDownloadSubtitle} Applies to '
                    'downloads that start after the change.',
                value: connections,
                min: DownloadPrefs.connectionsMin,
                max: DownloadPrefs.connectionsMax,
                unit: (n) => n == 1 ? 'connection' : 'connections',
                // DownloadPrefs.connectionsPerDownload' stored default.
                defaultValue: 4,
                onChanged: onConnectionsChanged,
                onCommit: onConnectionsCommit,
              ),
              // dl-11: Windows notification + taskbar progress switches.
              // Stored straight in DesktopPrefs (no caller plumbing); the
              // download manager reads them when a batch updates.
              const SizedBox(height: 16),
              Divider(height: 1, color: GraphiteSettingsColors.dialogEdge),
              const SizedBox(height: 8),
              ListenableBuilder(
                listenable: DesktopPrefs.changes,
                builder: (context, _) => Column(
                  children: [
                    _ToggleRow(
                      key: const ValueKey('desktop-download-notifications'),
                      title: context.l10n.notifyDownloadsFinishOrFail,
                      subtitle: context.l10n.notifyDownloadsSubtitle,
                      value: DesktopPrefs.downloadNotifications,
                      onChanged: DesktopPrefs.setDownloadNotifications,
                    ),
                    _ToggleRow(
                      key: const ValueKey('desktop-taskbar-progress'),
                      title: context.l10n.taskbarProgressTitle,
                      subtitle: context.l10n.taskbarProgressSubtitle,
                      value: DesktopPrefs.taskbarProgress,
                      onChanged: DesktopPrefs.setTaskbarProgress,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One labelled switch in the dialog's style: title and explanation on the
/// left, the switch on the right; tapping the row flips it too.
class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    super.key,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(12),
    onTap: () => onChanged(!value),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: AppText.body.copyWith(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: AppText.caption.copyWith(
                    color: AppColors.textSecondary,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Switch.adaptive(
            value: value,
            activeThumbColor: AppColors.accent,
            onChanged: onChanged,
          ),
        ],
      ),
    ),
  );
}

/// One download slider in the shared Windows settings slider style: icon,
/// title, "3 at once · Default: 3" and a compact stepped slider. Values are
/// owned by the caller; moves report live and the release commits.
class _SliderRow extends StatelessWidget {
  const _SliderRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.min,
    required this.max,
    required this.unit,
    required this.defaultValue,
    required this.onChanged,
    required this.onCommit,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final int value;
  final int min;
  final int max;

  /// Unit after the number ("at once", "connections").
  final String Function(int value) unit;

  /// Shipped default, shown so the scale is clear.
  final int defaultValue;
  final ValueChanged<int> onChanged;
  final ValueChanged<int> onCommit;

  @override
  Widget build(BuildContext context) => DesktopSettingsSlider(
    icon: icon,
    title: title,
    description: subtitle,
    value: value.toDouble(),
    min: min.toDouble(),
    max: max.toDouble(),
    divisions: max - min,
    format: (v) => '${v.round()}',
    unit: (v) => unit(v.round()),
    defaultValue: defaultValue.toDouble(),
    // Narrower than on a settings page: the dialog is at most 520 wide.
    sliderWidth: 180,
    onChanged: (v) => onChanged(v.round()),
    onChangeEnd: (v) => onCommit(v.round()),
  );
}
