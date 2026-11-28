import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/desktop/desktop_chrome_colors.dart';
import '../../core/desktop/desktop_context_menu.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/desktop_docked_panel.dart' show DesktopPanelColors;
import '../../l10n/l10n.dart';

/// Desktop source ranking row. The screen owns order, persistence and health;
/// this view supplies immediate pointer dragging, standard keyboard buttons,
/// Alt+Up / Alt+Down (Alt+Home / Alt+End) while the row has focus, a
/// right-click menu, a "Pinned" badge with its own Unpin, and the
/// "Use in Auto Resolve" switch.
class DesktopSourcePriorityRow extends StatefulWidget {
  const DesktopSourcePriorityRow({
    super.key,
    required this.index,
    required this.count,
    required this.name,
    required this.tried,
    required this.onMoveUp,
    required this.onMoveDown,
    this.repo,
    this.reason,
    this.health,
    this.pinned = false,
    this.onUnpin,
    this.onMoveToTop,
    this.onMoveToBottom,
    this.usedByAutoResolve = true,
    this.onUsedByAutoResolveChanged,
  });

  final int index;
  final int count;
  final String name;
  final String? repo;
  final String? reason;
  final bool tried;
  final ({String label, Color color})? health;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;

  /// True when the user placed this source by hand: it keeps its slot while
  /// the unpinned rows below it are re-ranked by what has worked.
  final bool pinned;

  /// Hands this one row back to the automatic ranking. Shown only on pinned
  /// rows.
  final VoidCallback? onUnpin;

  /// Jump straight to the top / bottom of a long list (menu and Alt+Home /
  /// Alt+End). Hidden when null.
  final VoidCallback? onMoveToTop;
  final VoidCallback? onMoveToBottom;

  /// The "Use in Auto Resolve" switch. Off means the automatic sweep skips
  /// this source; it can still be picked by hand for a title.
  final bool usedByAutoResolve;
  final ValueChanged<bool>? onUsedByAutoResolveChanged;

  @override
  State<DesktopSourcePriorityRow> createState() =>
      _DesktopSourcePriorityRowState();
}

class _DesktopSourcePriorityRowState extends State<DesktopSourcePriorityRow> {
  /// True while keyboard focus is anywhere inside this row (its buttons or
  /// the row itself), so the row can show which one Alt+arrows will move.
  bool _focused = false;

  /// The row's own focus node: clicking the row body focuses it, so Alt+Up /
  /// Alt+Down work straight after a click without tabbing to a button first.
  final FocusNode _rowFocus = FocusNode(debugLabel: 'source-priority-row');

  @override
  void dispose() {
    _rowFocus.dispose();
    super.dispose();
  }

  bool get _canMoveUp => widget.index > 0;
  bool get _canMoveDown => widget.index < widget.count - 1;

  /// Alt+Up / Alt+Down move one slot; Alt+Home / Alt+End jump to the ends.
  /// Plain arrows are left alone so normal focus traversal keeps working.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (!HardwareKeyboard.instance.isAltPressed) return KeyEventResult.ignored;
    final key = event.logicalKey;
    VoidCallback? action;
    if (key == LogicalKeyboardKey.arrowUp && _canMoveUp) {
      action = widget.onMoveUp;
    } else if (key == LogicalKeyboardKey.arrowDown && _canMoveDown) {
      action = widget.onMoveDown;
    } else if (key == LogicalKeyboardKey.home && _canMoveUp) {
      action = widget.onMoveToTop;
    } else if (key == LogicalKeyboardKey.end && _canMoveDown) {
      action = widget.onMoveToBottom;
    }
    if (action == null) {
      // Swallow Alt+arrows at the ends too, so they never fall through to a
      // window-level shortcut (Alt+Left is Back).
      final arrow =
          key == LogicalKeyboardKey.arrowUp ||
          key == LogicalKeyboardKey.arrowDown ||
          key == LogicalKeyboardKey.home ||
          key == LogicalKeyboardKey.end;
      return arrow ? KeyEventResult.handled : KeyEventResult.ignored;
    }
    action();
    return KeyEventResult.handled;
  }

  /// The right-click / Menu-key items, built when the menu opens.
  // Key names in `shortcut` stay as printed on the keyboard.
  List<DesktopMenuItem<Object?>> _menuItems() => [
    if (widget.onMoveToTop != null)
      DesktopMenuItem(
        label: context.l10n.moveToTop,
        icon: Icons.vertical_align_top_rounded,
        enabled: _canMoveUp,
        shortcut: 'Alt+Home',
        onTap: widget.onMoveToTop,
      ),
    DesktopMenuItem(
      label: context.l10n.moveUp,
      icon: Icons.arrow_upward_rounded,
      enabled: _canMoveUp,
      shortcut: 'Alt+Up',
      onTap: widget.onMoveUp,
    ),
    DesktopMenuItem(
      label: context.l10n.moveDown,
      icon: Icons.arrow_downward_rounded,
      enabled: _canMoveDown,
      shortcut: 'Alt+Down',
      onTap: widget.onMoveDown,
    ),
    if (widget.onMoveToBottom != null)
      DesktopMenuItem(
        label: context.l10n.moveToBottom,
        icon: Icons.vertical_align_bottom_rounded,
        enabled: _canMoveDown,
        shortcut: 'Alt+End',
        onTap: widget.onMoveToBottom,
      ),
    if (widget.pinned && widget.onUnpin != null) ...[
      const DesktopMenuItem.divider(),
      DesktopMenuItem(
        label: context.l10n.unpinHomeRow,
        icon: Icons.push_pin_outlined,
        onTap: widget.onUnpin,
      ),
    ],
    if (widget.onUsedByAutoResolveChanged != null) ...[
      const DesktopMenuItem.divider(),
      DesktopMenuItem(
        label: context.l10n.useInAutoResolve,
        checked: widget.usedByAutoResolve,
        onTap: () =>
            widget.onUsedByAutoResolveChanged!(!widget.usedByAutoResolve),
      ),
    ],
  ];

  @override
  Widget build(BuildContext context) {
    final name = widget.name;
    final accent = AppColors.accent;
    final off = !widget.usedByAutoResolve;
    // Theme-following fills instead of fixed greys: tried rows sit on the
    // panel surface, rows past the cut (or switched off) one step darker,
    // toward the window frame — the same pair the stock greys came from.
    final fill = widget.tried
        ? DesktopPanelColors.surface
        : Color.lerp(DesktopChrome.frame, DesktopPanelColors.surface, .45)!;
    final border = _focused ? accent : DesktopPanelColors.edge;

    final moves = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.pinned && widget.onUnpin != null)
          IconButton(
            tooltip: context.l10n.unpinNamed(name),
            onPressed: widget.onUnpin,
            icon: const Icon(Icons.push_pin_outlined, size: 18),
          ),
        IconButton(
          tooltip: context.l10n.moveNamedUp(name),
          onPressed: _canMoveUp ? widget.onMoveUp : null,
          icon: const Icon(Icons.arrow_upward_rounded, size: 20),
        ),
        IconButton(
          tooltip: context.l10n.moveNamedDown(name),
          onPressed: _canMoveDown ? widget.onMoveDown : null,
          icon: const Icon(Icons.arrow_downward_rounded, size: 20),
        ),
      ],
    );

    // "Use in Auto Resolve" switch with its label, so the control says what
    // it does without a tooltip.
    final autoSwitch = widget.onUsedByAutoResolveChanged == null
        ? null
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                context.l10n.useInAutoResolve,
                style: AppText.caption.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(width: 6),
              Tooltip(
                message: widget.usedByAutoResolve
                    ? context.l10n.autoResolveSearchesNamed(name)
                    : context.l10n.autoResolveSkipsNamed(name),
                child: Switch(
                  value: widget.usedByAutoResolve,
                  activeThumbColor: accent,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: widget.onUsedByAutoResolveChanged,
                ),
              ),
            ],
          );

    final row = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: border),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < 460;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MouseRegion(
                    cursor: SystemMouseCursors.grab,
                    child: Tooltip(
                      message: context.l10n.dragToReorderNamed(name),
                      child: ReorderableDragStartListener(
                        index: widget.index,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(0, 8, 12, 8),
                          child: Icon(
                            Icons.drag_indicator_rounded,
                            color: AppColors.textSecondary,
                            size: 22,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    // A switched-off source is dimmed like one past the cut:
                    // Auto Resolve will not reach it either way.
                    child: Opacity(
                      opacity: off ? .55 : 1,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                '${widget.index + 1}. $name',
                                style: AppText.body.copyWith(
                                  color: AppColors.textPrimary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (widget.pinned) _PinnedBadge(accent: accent),
                            ],
                          ),
                          if (widget.repo != null) ...[
                            const SizedBox(height: 4),
                            Text(widget.repo!, style: AppText.caption),
                          ],
                          if (widget.reason != null) ...[
                            const SizedBox(height: 4),
                            Text(widget.reason!, style: AppText.caption),
                          ],
                          if (widget.health case final status?) ...[
                            const SizedBox(height: 6),
                            Text(
                              status.label,
                              style: AppText.caption.copyWith(
                                color: status.color,
                              ),
                            ),
                          ],
                          if (off) ...[
                            const SizedBox(height: 6),
                            Text(
                              context.l10n.skippedByAutoResolve,
                              style: AppText.caption.copyWith(
                                color: AppColors.textTertiary,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  if (!narrow) ...[const SizedBox(width: 12), moves],
                ],
              ),
              if (narrow)
                Align(alignment: AlignmentDirectional.centerEnd, child: moves),
              if (autoSwitch != null)
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: autoSwitch,
                ),
            ],
          );
        },
      ),
    );

    return DesktopContextMenuRegion(
      items: _menuItems,
      // Watches focus anywhere inside the row (row itself or its buttons)
      // and sees the Alt+arrow keys bubbling up from whichever has it.
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (has) {
          if (mounted && has != _focused) setState(() => _focused = has);
        },
        onKeyEvent: _onKey,
        child: Focus(
          focusNode: _rowFocus,
          // Clicks focus the row, but Tab skips it and lands on the row's
          // buttons as before (which also take Alt+arrows): an extra tab stop
          // per row would double the keyboard walk through a long list.
          skipTraversal: true,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            // A click on the row body gives it focus for the keyboard moves.
            onTap: _rowFocus.requestFocus,
            child: Semantics(
              label: widget.pinned
                  ? context.l10n.namePinned(name)
                  : name,
              child: row,
            ),
          ),
        ),
      ),
    );
  }
}

/// The small "Pinned" marker: says this row stays where it was put while
/// the unpinned rows re-rank around it.
class _PinnedBadge extends StatelessWidget {
  const _PinnedBadge({required this.accent});

  final Color accent;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: context.l10n.pinnedStaysHereTooltip,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: DesktopChrome.selectedFill(accent),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: accent.withValues(alpha: .45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.push_pin_rounded, size: 12, color: accent),
          const SizedBox(width: 4),
          Text(
            context.l10n.pinned,
            style: AppText.caption.copyWith(color: accent, fontSize: 11),
          ),
        ],
      ),
    ),
  );
}
