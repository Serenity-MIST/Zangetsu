// Right pane of the Windows Sources manager when a SOURCE is selected:
// big icon, name, health line, the action buttons (Browse / Settings /
// Pin to top / Update / Remove), a '⋯' overflow for everything else, the
// 'Popular on <source>' poster row and the footer line.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/desktop/desktop_context_menu.dart';
import '../../core/playback/pinned_sources.dart';
import '../../core/playback/source_health_store.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/source_icon_tile.dart';
import '../../l10n/l10n.dart';
import 'desktop_source_popular_row.dart';
import 'desktop_sources_actions.dart';
import 'desktop_sources_model.dart';

/// Colour of the health dot for [status] (null = never checked).
Color _healthColor(SourceHealth? status) => switch (status) {
  SourceHealth.ok => const Color(0xFF3DDC84),
  SourceHealth.slow => const Color(0xFFFFB74D),
  SourceHealth.dead => AppColors.accent,
  null => AppColors.textTertiary,
};

/// The overflow ('⋯') items for [entry], shared by the button and the list's
/// right-click menu so both offer the same extras.
List<DesktopMenuItem<Object?>> desktopSourceOverflowItems(
  BuildContext context,
  DesktopSourceEntry entry,
) {
  final l10n = context.l10n;
  return [
    if (DesktopSourceActions.canActivate(entry))
      DesktopMenuItem<Object?>(
        label: l10n.makeActiveSource,
        icon: Icons.radio_button_checked_rounded,
        enabled: !DesktopSourceActions.isActive(entry),
        onTap: () => DesktopSourceActions.makeActive(context, entry),
      ),
    if (entry.canDisable)
      DesktopMenuItem<Object?>(
        label: l10n.enabled,
        icon: Icons.power_settings_new_rounded,
        checked: entry.enabled,
        onTap: () =>
            unawaited(DesktopSourceActions.setEnabled(entry, !entry.enabled)),
      ),
    if (DesktopSourceActions.canOpenSite(entry))
      DesktopMenuItem<Object?>(
        label: l10n.signInToSource,
        icon: Icons.open_in_browser_rounded,
        onTap: () => unawaited(DesktopSourceActions.openSite(entry)),
      ),
    if (DesktopSourceActions.canResetData(entry))
      DesktopMenuItem<Object?>(
        label: '${l10n.reset}…',
        icon: Icons.restart_alt_rounded,
        onTap: () => unawaited(DesktopSourceActions.resetData(context, entry)),
      ),
    if (DesktopSourceActions.hasLanguages(entry.ecosystem))
      DesktopMenuItem<Object?>(
        label: '${l10n.languages}…',
        icon: Icons.language_rounded,
        onTap: () => unawaited(
          DesktopSourceActions.pickLanguages(context, entry.ecosystem),
        ),
      ),
    DesktopMenuItem<Object?>(
      label: '${l10n.sourceHealth}…',
      icon: Icons.monitor_heart_outlined,
      onTap: () => unawaited(DesktopSourceActions.openHealth(context)),
    ),
    const DesktopMenuItem<Object?>.divider(),
    DesktopMenuItem<Object?>(
      // Translated "Open <ecosystem> manager…".
      label: l10n.desktopOpenEcosystemManagerMenu(entry.ecosystem.label),
      icon: Icons.open_in_new_rounded,
      onTap: () => unawaited(
        DesktopSourceActions.openEcosystemManager(context, entry.ecosystem),
      ),
    ),
    DesktopMenuItem<Object?>(
      // Translated menu entry.
      label: l10n.desktopAllEcosystemsMenu,
      icon: Icons.tune_rounded,
      onTap: () => unawaited(DesktopSourceActions.openAllEcosystems(context)),
    ),
  ];
}

/// The details pane for one source. Keyed by the source id by the manager,
/// so its settings check and poster row restart for every new selection.
class DesktopSourceDetailPane extends StatefulWidget {
  const DesktopSourceDetailPane({
    super.key,
    required this.entry,
    required this.onRemoved,
  });

  final DesktopSourceEntry entry;

  /// Called after the source was removed (the manager moves the selection).
  final VoidCallback onRemoved;

  @override
  State<DesktopSourceDetailPane> createState() =>
      _DesktopSourceDetailPaneState();
}

class _DesktopSourceDetailPaneState extends State<DesktopSourceDetailPane> {
  /// Whether the source has a settings page (asked once per selection, and
  /// only once the page is on screen: the check can call into an extension
  /// runtime, which a hidden page must not do).
  Future<bool>? _hasSettings;

  /// True while Update runs.
  bool _updating = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_hasSettings == null && TickerMode.valuesOf(context).enabled) {
      _hasSettings = DesktopSourceActions.hasSettings(widget.entry);
    }
  }

  @override
  void didUpdateWidget(DesktopSourceDetailPane old) {
    super.didUpdateWidget(old);
    if (old.entry.id != widget.entry.id) {
      _hasSettings = TickerMode.valuesOf(context).enabled
          ? DesktopSourceActions.hasSettings(widget.entry)
          : null;
    }
  }

  Future<void> _update() async {
    setState(() => _updating = true);
    await DesktopSourceActions.update(context, widget.entry);
    if (mounted) setState(() => _updating = false);
  }

  Future<void> _remove() async {
    final removed = await DesktopSourceActions.remove(context, widget.entry);
    if (removed && mounted) widget.onRemoved();
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final record = desktopHealthRecordOf(entry.id);
    final status = desktopHealthOf(entry.id);
    return LayoutBuilder(
      builder: (context, c) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: c.maxHeight),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _header(context, entry, status),
              const SizedBox(height: 22),
              _buttons(context, entry),
              const SizedBox(height: 28),
              _body(context, entry),
              const SizedBox(height: 22),
              Text(
                desktopFooterLine(entry, checkedAt: record?.checkedAt),
                key: const ValueKey('desktop-source-footer'),
                style: AppText.caption,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Icon, name and the '● Working · Aniyomi · v14 · English' line.
  Widget _header(
    BuildContext context,
    DesktopSourceEntry entry,
    SourceHealth? status,
  ) {
    final word = desktopHealthWord(status, working: context.l10n.working);
    final parts = desktopHealthParts(entry, statusWord: word);
    final active = DesktopSourceActions.isActive(entry);
    return Row(
      children: [
        SourceIconTile(name: entry.name, icon: entry.iconUrl, size: 64),
        const SizedBox(width: 18),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      entry.name,
                      key: const ValueKey('desktop-source-name'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.headline.copyWith(fontSize: 22),
                    ),
                  ),
                  if (active) ...[
                    const SizedBox(width: 10),
                    const _Tag('ACTIVE'),
                  ],
                  if (entry.nsfw) ...[
                    const SizedBox(width: 8),
                    const _Tag('18+'),
                  ],
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  if (word != null || !entry.enabled) ...[
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: entry.enabled
                            ? _healthColor(status)
                            : AppColors.textTertiary,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Flexible(
                    child: Text(
                      parts.join(' · '),
                      key: const ValueKey('desktop-source-health'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.body.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Browse (primary, white), Settings, Pin to top, Update, Remove, '⋯'.
  Widget _buttons(BuildContext context, DesktopSourceEntry entry) {
    final l10n = context.l10n;
    // The settings check decides whether the Settings button exists at all,
    // so the whole row waits on it (no empty slot leaving a double gap).
    return FutureBuilder<bool>(
      future: _hasSettings,
      builder: (context, settingsSnap) => Wrap(
        spacing: 10,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Tooltip(
            message: entry.browsable
                ? 'Open ${entry.name} (Enter)'
                : 'Open the Stremio manager',
            child: FilledButton.icon(
              key: const ValueKey('desktop-source-browse'),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: () =>
                  unawaited(DesktopSourceActions.browse(context, entry)),
              icon: Icon(
                entry.browsable ? Icons.play_arrow_rounded : Icons.tune_rounded,
                size: 20,
              ),
              label: Text(entry.browsable ? 'Browse' : 'Configure'),
            ),
          ),
          if (settingsSnap.data == true)
            _PaneButton(
              key: const ValueKey('desktop-source-settings'),
              // Shared translated "Settings" word.
              label: l10n.settingsTitle,
              tooltip: l10n.sourceSettings,
              onPressed: () =>
                  unawaited(DesktopSourceActions.openSettings(context, entry)),
            ),
          if (entry.pinnable)
            ValueListenableBuilder<List<String>>(
              valueListenable: PinnedSources.notifier,
              builder: (context, pinned, _) {
                final isPinned = pinned.contains(entry.id);
                return _PaneButton(
                  key: const ValueKey('desktop-source-pin'),
                  label: isPinned ? 'Unpin' : 'Pin to top',
                  tooltip: isPinned ? l10n.unpinSource : l10n.pinSource,
                  onPressed: () =>
                      unawaited(DesktopSourceActions.togglePin(entry)),
                );
              },
            ),
          if (entry.hasUpdate)
            _PaneButton(
              key: const ValueKey('desktop-source-update'),
              label: _updating ? 'Updating…' : l10n.update,
              tooltip: entry.updateLabel == null
                  ? l10n.update
                  : '${l10n.update} to ${entry.updateLabel}',
              onPressed: _updating ? null : () => unawaited(_update()),
            ),
          _PaneButton(
            key: const ValueKey('desktop-source-remove'),
            label: l10n.remove,
            tooltip: l10n.uninstall,
            destructive: true,
            onPressed: () => unawaited(_remove()),
          ),
          Builder(
            builder: (anchor) => IconButton(
              key: const ValueKey('desktop-source-more'),
              tooltip: l10n.moreActions,
              onPressed: () => showDesktopContextMenu<Object?>(
                anchor,
                anchor: anchor,
                items: desktopSourceOverflowItems(context, entry),
              ),
              icon: const Icon(Icons.more_horiz_rounded),
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  /// The poster row, or why there is none.
  Widget _body(BuildContext context, DesktopSourceEntry entry) {
    if (!entry.browsable) {
      return const _Note(
        text:
            'Stremio add-ons feed catalogues, links and subtitles into the '
            'app. Configure, reorder and choose catalogues in the Stremio '
            'manager.',
      );
    }
    if (!entry.enabled) {
      return const _Note(
        text:
            'This source is switched off. Turn it back on from ⋯ to see '
            'its titles.',
      );
    }
    return DesktopSourcePopularRow(
      key: ValueKey('popular-${entry.id}'),
      sourceId: entry.id,
      sourceName: entry.name,
    );
  }
}

/// Outlined pane button in the app's desktop style (graphite, hairline).
class _PaneButton extends StatelessWidget {
  const _PaneButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.tooltip,
    this.destructive = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final String? tooltip;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final button = OutlinedButton(
      style: OutlinedButton.styleFrom(
        foregroundColor: destructive ? AppColors.accent : AppColors.textPrimary,
        backgroundColor: AppColors.surface2,
        side: const BorderSide(color: Color(0x29FFFFFF)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      onPressed: onPressed,
      child: Text(label),
    );
    final tip = tooltip;
    return tip == null ? button : Tooltip(message: tip, child: button);
  }
}

/// Small uppercase tag next to the name.
class _Tag extends StatelessWidget {
  const _Tag(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: AppColors.accentSoft,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: AppText.overline.copyWith(
        color: AppColors.accent,
        fontWeight: FontWeight.w700,
        fontSize: 10,
      ),
    ),
  );
}

/// A calm explanatory block in place of the poster row.
class _Note extends StatelessWidget {
  const _Note({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: AppColors.surface2,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(text, style: AppText.body),
  );
}
