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
///
/// Every row is a standard Windows settings row (the shared slider and
/// [GraphiteSettingsControl]), so the two sliders and the two switches share
/// one left edge, one icon column and one right edge.
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

  /// Widest the dialog gets. Wide enough that "8 connections · Default: 4
  /// connections" fits on the value line beside the slider.
  static const double maxWidth = 560;

  /// Slider width inside the dialog (a settings page uses 240).
  static const double sliderWidth = 150;

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
          maxWidth: maxWidth,
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: SingleChildScrollView(
          // Rows bring their own inner padding (as on a settings page), so
          // the dialog edge is narrow and the header adds its own.
          padding: const EdgeInsets.fromLTRB(12, 20, 12, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 12, end: 8),
                child: Row(
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
              ),
              const SizedBox(height: 12),
              Divider(height: 1, color: GraphiteSettingsColors.dialogEdge),
              const SizedBox(height: 8),
              _SliderRow(
                key: const ValueKey('desktop-parallel-downloads'),
                icon: Icons.download_rounded,
                title: l10n.parallelDownloads,
                // The shared, translated sentence first, then the Windows-only
                // note, so other languages keep their own first sentence
                // until the note is translated.
                subtitle:
                    '${l10n.parallelDownloadsSubtitle} '
                    '${l10n.desktopParallelDownloadsNote}',
                value: parallel,
                min: DownloadPrefs.parallelMin,
                max: DownloadPrefs.parallelMax,
                unit: (_) => l10n.desktopDownloadsAtOnceUnit,
                // DownloadPrefs.parallelDownloads' stored default.
                defaultValue: 3,
                onChanged: onParallelChanged,
                onCommit: onParallelCommit,
              ),
              _SliderRow(
                key: const ValueKey('desktop-connections-per-download'),
                icon: Icons.lan_outlined,
                title: l10n.connectionsPerDownload,
                subtitle:
                    '${l10n.connectionsPerDownloadSubtitle} '
                    '${l10n.desktopConnectionsPerDownloadNote}',
                value: connections,
                min: DownloadPrefs.connectionsMin,
                max: DownloadPrefs.connectionsMax,
                unit: l10n.desktopConnectionsUnit,
                // DownloadPrefs.connectionsPerDownload' stored default.
                defaultValue: 4,
                onChanged: onConnectionsChanged,
                onCommit: onConnectionsCommit,
              ),
              // dl-11: Windows notification + taskbar progress switches.
              // Stored straight in DesktopPrefs (no caller plumbing); the
              // download manager reads them when a batch updates.
              const SizedBox(height: 8),
              Divider(height: 1, color: GraphiteSettingsColors.dialogEdge),
              const SizedBox(height: 8),
              ListenableBuilder(
                listenable: DesktopPrefs.changes,
                builder: (context, _) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _ToggleRow(
                      key: const ValueKey('desktop-download-notifications'),
                      icon: Icons.notifications_none_rounded,
                      title: context.l10n.notifyDownloadsFinishOrFail,
                      subtitle: context.l10n.notifyDownloadsSubtitle,
                      value: DesktopPrefs.downloadNotifications,
                      onChanged: DesktopPrefs.setDownloadNotifications,
                    ),
                    _ToggleRow(
                      key: const ValueKey('desktop-taskbar-progress'),
                      icon: Icons.web_asset_rounded,
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

/// One labelled switch as a standard Windows settings row: icon, title and
/// explanation on the left, the switch on the right; tapping the row flips
/// it too.
class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => GraphiteSettingsControl(
    icon: icon,
    title: title,
    subtitle: subtitle,
    onTap: () => onChanged(!value),
    trailing: Switch.adaptive(
      value: value,
      activeThumbColor: AppColors.accent,
      onChanged: onChanged,
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
    // Narrower than on a settings page, so the value line keeps its
    // "Default" text beside the number.
    sliderWidth: DesktopDownloadSettingsDialog.sliderWidth,
    onChanged: (v) => onChanged(v.round()),
    onChangeEnd: (v) => onCommit(v.round()),
  );
}
