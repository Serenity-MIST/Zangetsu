import 'dart:io';
import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/settings_widgets.dart';
import '../../core/ui/desktop_settings_surface.dart';
import '../../l10n/l10n.dart';
import '../player/player_controls_config.dart';

/// Arrange the player's controls: which bar each one sits on, in what order,
/// and which are put away.
///
/// Hidden controls stay reachable in the player's ⋮ More sheet, so nothing
/// here can make a feature unavailable — it only decides what's one tap away.
class PlayerControlsScreen extends StatefulWidget {
  const PlayerControlsScreen({super.key});

  @override
  State<PlayerControlsScreen> createState() => _PlayerControlsScreenState();
}

class _PlayerControlsScreenState extends State<PlayerControlsScreen> {
  final PlaybackPrefs _prefs = sl<PlaybackPrefs>();
  late List<String> _top;
  late List<String> _left;
  late List<String> _right;

  @override
  void initState() {
    super.initState();
    final cfg = PlayerControlsConfig(
      top: _prefs.playerBarTop ?? PlayerControlsConfig.defaultTop,
      left: _prefs.playerBarLeft ?? PlayerControlsConfig.defaultLeft,
      right: _prefs.playerBarRight ?? PlayerControlsConfig.defaultRight,
    ).sanitised();
    _top = [...cfg.top];
    _left = [...cfg.left];
    _right = [...cfg.right];
  }

  PlayerControlsConfig get _cfg =>
      PlayerControlsConfig(top: _top, left: _left, right: _right);

  void _apply(VoidCallback change) {
    setState(change);
    _prefs.setPlayerBar(_top, _left, _right);
  }

  // onReorderItem (not the deprecated onReorder) already accounts for the
  // dragged row being lifted out, so `to` needs no off-by-one correction.
  void _reorder(List<String> list, int from, int to) =>
      _apply(() => list.insert(to, list.removeAt(from)));

  void _moveTo(String id, ControlSlot slot) => _apply(() {
    // Enforced here as well as in the menu — the menu greys the option out,
    // but the cap shouldn't depend on the UI being the only way in.
    if (slot == ControlSlot.top &&
        !_top.contains(id) &&
        _top.length >= PlayerControlsConfig.maxTop) {
      return;
    }
    _top.remove(id);
    _left.remove(id);
    _right.remove(id);
    switch (slot) {
      case ControlSlot.top:
        _top.add(id);
      case ControlSlot.left:
        _left.add(id);
      case ControlSlot.right:
        _right.add(id);
      case ControlSlot.hidden:
        break; // hidden is "in no list"
    }
  });

  Future<void> _reset() async {
    await _prefs.resetPlayerBar();
    if (!mounted) return;
    setState(() {
      _top = [...PlayerControlsConfig.defaultTop];
      _left = [...PlayerControlsConfig.defaultLeft];
      _right = [...PlayerControlsConfig.defaultRight];
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar(
        context.l10n.playerControls,
        actions: [
          TextButton(
            onPressed: _reset,
            child: Text(
              context.l10n.reset,
              style: AppText.body.copyWith(color: AppColors.accent),
            ),
          ),
        ],
      ),
      body: DesktopSettingsScope.contains(context)
          ? _desktopBody()
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 32),
              children: [
                _preview(),
                const SizedBox(height: 4),
                for (final slot in ControlSlot.values) ...[
                  SettingsSectionLabel(
                    slot == ControlSlot.top
                        // Shown so the limit is visible before you hit it, rather
                        // than discovered as a greyed-out menu item.
                        ? '${slot.label} · ${_top.length}/${PlayerControlsConfig.maxTop}'
                        : slot.label,
                  ),
                  _card(slot),
                ],
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 14, 8, 0),
                  child: Text(
                    context.l10n.playerControlsHelp,
                    style: AppText.caption.copyWith(
                      color: AppColors.textTertiary,
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  /// Desktop editor uses responsive slot panels instead of a stretched phone
  /// list. The same configuration objects feed both this preview and playback.
  Widget _desktopBody() => SingleChildScrollView(
    padding: const EdgeInsets.all(22),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GraphiteSettingsPanel(
          margin: EdgeInsets.zero,
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Player layout preview', style: AppText.headline),
                  const SizedBox(height: 16),
                  _desktopPreviewGroup(ControlSlot.top, _top),
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 18),
                    child: Center(
                      child: Icon(Icons.play_circle_outline_rounded, size: 40),
                    ),
                  ),
                  _desktopPreviewGroup(ControlSlot.left, _left),
                  const SizedBox(height: 12),
                  _desktopPreviewGroup(ControlSlot.right, _right),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 1000 ? 2 : 1;
            final width = (constraints.maxWidth - (columns - 1) * 16) / columns;
            return Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                for (final slot in ControlSlot.values)
                  SizedBox(width: width, child: _desktopSlot(slot)),
              ],
            );
          },
        ),
        const SizedBox(height: 16),
        Text(context.l10n.playerControlsHelp, style: AppText.caption),
      ],
    ),
  );

  /// Preview controls wrap at narrow widths without shrinking their glyphs.
  Widget _desktopPreviewGroup(ControlSlot slot, List<String> ids) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(slot.label, style: AppText.caption),
      const SizedBox(height: 8),
      Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final id in ids)
            Tooltip(
              message: _desktopLabel(id),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF101114),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  _desktopIcon(id),
                  size: 23,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
        ],
      ),
    ],
  );

  /// Stable rotate ID maps to fullscreen in the Windows player.
  String _desktopLabel(String id) =>
      id == 'rotate' ? 'Fullscreen' : controlById(id)!.label;
  IconData _desktopIcon(String id) =>
      id == 'rotate' ? Icons.fullscreen_rounded : controlById(id)!.icon;

  /// Slot groups own no preferences: moving, ordering and reset still use the
  /// screen's existing handlers and canonical PlayerControlsConfig invariants.
  Widget _desktopSlot(ControlSlot slot) {
    final ids = _cfg.forSlot(slot);
    return GraphiteSettingsPanel(
      margin: EdgeInsets.zero,
      children: [
        Padding(
          padding: const EdgeInsets.all(20),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              slot == ControlSlot.top
                  ? '${slot.label} · ${ids.length}/${PlayerControlsConfig.maxTop}'
                  : slot.label,
              style: AppText.headline,
            ),
          ),
        ),
        if (ids.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Text(
              slot == ControlSlot.hidden
                  ? context.l10n.everyControlIsOnABar
                  : context.l10n.nothingHereMoveControl,
              style: AppText.caption,
            ),
          )
        else if (slot == ControlSlot.hidden)
          Column(children: [for (final id in ids) _desktopRow(id, slot, null)])
        else
          ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            onReorderItem: (from, to) => _reorder(ids, from, to),
            children: [
              for (var i = 0; i < ids.length; i++) _desktopRow(ids[i], slot, i),
            ],
          ),
      ],
    );
  }

  /// Direct slot selector replaces the phone move menu. The pinned More route
  /// cannot disappear, and a full top bar remains visible but disabled.
  Widget _desktopRow(String id, ControlSlot slot, int? index) {
    final pinned = controlById(id)!.pinned;
    final ids = _cfg.forSlot(slot);
    return Padding(
      key: ValueKey('${slot.name}_$id'),
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (index != null)
                MouseRegion(
                  cursor: SystemMouseCursors.grab,
                  child: ReorderableDragStartListener(
                    index: index,
                    child: const Padding(
                      padding: EdgeInsets.all(8),
                      child: Icon(Icons.drag_indicator_rounded, size: 22),
                    ),
                  ),
                ),
              Icon(_desktopIcon(id), size: 23, color: AppColors.textSecondary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_desktopLabel(id), style: AppText.body),
                    if (pinned)
                      Text(context.l10n.pinned, style: AppText.caption),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<ControlSlot>(
                  key: ValueKey('player-slot-$id'),
                  initialValue: slot,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: context.l10n.move,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                  items: [
                    for (final destination in ControlSlot.values)
                      DropdownMenuItem(
                        value: destination,
                        enabled:
                            !(pinned && destination == ControlSlot.hidden) &&
                            !(destination == ControlSlot.top &&
                                slot != ControlSlot.top &&
                                _top.length >= PlayerControlsConfig.maxTop),
                        child: Text(
                          destination == ControlSlot.top &&
                                  slot != ControlSlot.top &&
                                  _top.length >= PlayerControlsConfig.maxTop
                              ? context.l10n.topBarFull(destination.label)
                              : destination.label,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (next) {
                    if (next != null && next != slot) _moveTo(id, next);
                  },
                ),
              ),
              if (index != null) ...[
                const SizedBox(width: 4),
                IconButton(
                  key: ValueKey('player-up-$id'),
                  tooltip: 'Move ${_desktopLabel(id)} up',
                  onPressed: index > 0
                      ? () => _reorder(ids, index, index - 1)
                      : null,
                  icon: const Icon(Icons.arrow_upward_rounded, size: 20),
                ),
                IconButton(
                  key: ValueKey('player-down-$id'),
                  tooltip: 'Move ${_desktopLabel(id)} down',
                  onPressed: index < ids.length - 1
                      ? () => _reorder(ids, index, index + 1)
                      : null,
                  icon: const Icon(Icons.arrow_downward_rounded, size: 20),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// A miniature of both bars. Without it you're editing lists and guessing
  /// what the player ends up looking like — and it's the only way to see the
  /// title being squeezed as controls pile into the top bar.
  Widget _preview() {
    Widget icons(List<String> ids) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final id in ids)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Icon(
              Platform.isWindows && id == 'rotate'
                  ? Icons.fullscreen_rounded
                  : controlById(id)?.icon ?? Icons.help_outline,
              size: 16,
              color: Colors.white,
            ),
          ),
      ],
    );

    Widget group(List<String> ids) => DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(19),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
        child: icons(ids),
      ),
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        height: 116,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF2B3350), Color(0xFF4A3450), Color(0xFF233042)],
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
            child: Column(
              children: [
                // Top bar: back, the title, then whatever's been put up here,
                // then the fixed lock + settings.
                Row(
                  children: [
                    const Icon(
                      Icons.arrow_back_rounded,
                      size: 16,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        context.l10n.showTitleE2,
                        style: AppText.caption.copyWith(
                          color: Colors.white,
                          fontSize: 11,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    icons(_top),
                    const SizedBox(width: 4),
                    const Icon(
                      Icons.lock_open_rounded,
                      size: 16,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 8),
                    const Icon(
                      Icons.settings_rounded,
                      size: 16,
                      color: Colors.white,
                    ),
                  ],
                ),
                const Spacer(),
                Row(
                  children: [
                    if (_left.isNotEmpty) group(_left),
                    const Spacer(),
                    if (_right.isNotEmpty) group(_right),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _card(ControlSlot slot) {
    final ids = _cfg.forSlot(slot);
    if (ids.isEmpty) {
      return SettingsCard(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Center(
              child: Text(
                slot == ControlSlot.hidden
                    ? context.l10n.everyControlIsOnABar
                    : context.l10n.nothingHereMoveControl,
                textAlign: TextAlign.center,
                style: AppText.caption.copyWith(color: AppColors.textTertiary),
              ),
            ),
          ),
        ],
      );
    }
    // Hidden has no meaningful order, so it doesn't get drag handles.
    if (slot == ControlSlot.hidden) {
      return SettingsCard(
        children: [for (final id in ids) _row(id, slot, null)],
      );
    }
    return SettingsCard(
      children: [
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          onReorderItem: (f, t) => _reorder(ids, f, t),
          children: [
            for (var i = 0; i < ids.length; i++) _row(ids[i], slot, i),
          ],
        ),
      ],
    );
  }

  Widget _row(String id, ControlSlot slot, int? index) {
    final c = controlById(id)!;
    final hidden = slot == ControlSlot.hidden;
    final tint = hidden ? AppColors.textTertiary : AppColors.textPrimary;
    return Padding(
      key: ValueKey('${slot.name}_$id'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      child: Row(
        children: [
          if (index != null)
            ReorderableDragStartListener(
              index: index,
              child: const Padding(
                padding: EdgeInsetsDirectional.only(end: 10),
                child: Icon(
                  Icons.drag_indicator_rounded,
                  size: 19,
                  color: AppColors.textTertiary,
                ),
              ),
            )
          else
            const SizedBox(width: 29),
          // Keep the stable stored id, but name the action the PC player uses.
          Icon(
            Platform.isWindows && id == 'rotate'
                ? Icons.fullscreen_rounded
                : c.icon,
            size: 20,
            color: tint,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              Platform.isWindows && id == 'rotate' ? 'Fullscreen' : c.label,
              style: AppText.body.copyWith(color: tint, fontSize: 14.5),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (c.pinned)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: Text(
                context.l10n.pinned,
                style: AppText.caption.copyWith(
                  color: AppColors.textTertiary,
                  fontSize: 11.5,
                ),
              ),
            ),
          _moveMenu(id, slot, c.pinned),
        ],
      ),
    );
  }

  /// Four destinations means the old "send it to the other side" arrow no
  /// longer says enough, so each row picks its slot explicitly.
  Widget _moveMenu(String id, ControlSlot from, bool pinned) {
    // A pinned control can go anywhere except away — it's the route back to
    // everything in Hidden.
    final options = [
      for (final s in ControlSlot.values)
        if (s != from && !(pinned && s == ControlSlot.hidden)) s,
    ];
    final topFull = _top.length >= PlayerControlsConfig.maxTop;
    return PopupMenuButton<ControlSlot>(
      tooltip: context.l10n.move,
      color: AppColors.surface2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
      onSelected: (s) => _moveTo(id, s),
      itemBuilder: (c) => [
        for (final s in options)
          // A full top bar is offered greyed out rather than dropped from the
          // menu — "Top bar (full)" explains itself; a missing row doesn't.
          PopupMenuItem<ControlSlot>(
            value: s,
            height: 42,
            enabled: !(s == ControlSlot.top && topFull),
            child: Text(
              s == ControlSlot.top && topFull
                  ? context.l10n.topBarFull(s.label)
                  : s.label,
              style: AppText.caption.copyWith(
                color: s == ControlSlot.top && topFull
                    ? AppColors.textTertiary
                    : AppColors.textSecondary,
                fontSize: 13,
              ),
            ),
          ),
      ],
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                context.l10n.move,
                style: AppText.caption.copyWith(
                  color: AppColors.textSecondary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Icon(
                Icons.expand_more_rounded,
                size: 16,
                color: AppColors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
