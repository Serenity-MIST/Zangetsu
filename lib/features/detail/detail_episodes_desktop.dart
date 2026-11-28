// Windows-only building blocks for the show page's Episodes tab (show-6,
// show-7): the inline episode filter, the multi-select toolbar and the hover
// checkbox wrapper. Kept in their own library so detail_episodes.dart (a part
// of detail_screen.dart) can use them without touching that file's imports;
// episode_filter.dart re-exports this library.
import 'package:flutter/material.dart';

import '../../core/desktop/desktop_chrome_colors.dart';
import '../../core/desktop/desktop_multi_select.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/desktop_docked_panel.dart';
import '../search/search_page_keys.dart';
import '../../l10n/l10n.dart';

// Re-exported for the Episodes tab: the shared desktop sheet and the
// Explorer-style selection model (both from the desktop UI kit).
export '../../core/desktop/desktop_multi_select.dart'
    show DesktopSelection, DesktopSelectionShortcuts, DesktopSelectionCheckbox;
export '../../core/desktop/desktop_sheet.dart'
    show showAdaptiveSheet, DesktopSheetStyle, DesktopSheetScope;

/// Compact search box for the Episodes header (show-7). Matches episode
/// number or title through [filterEpisodes]; Esc clears the text first and
/// then leaves the box (via [onClose]), so Esc never pops the page from here.
class EpisodeFilterField extends StatelessWidget {
  const EpisodeFilterField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onClose,
    this.hint,
    this.width = 220,
  });

  /// Shared key so tests (and the page) can find the box.
  static const fieldKey = ValueKey('episode-filter-field');

  /// Default placeholder. Users found "Filter episodes" odd, so it reads
  /// "Search"; hardcoded like the other Windows-only labels.
  static const episodeHint = 'Search episodes';

  /// Placeholder on a manga / novel page.
  static const chapterHint = 'Search chapters';

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;

  /// Second Esc (box already empty): give focus back to the list.
  final VoidCallback onClose;

  /// Placeholder text; null shows [episodeHint] ("Search episodes").
  final String? hint;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: 36,
      child: SearchFieldEscape(
        controller: controller,
        onClose: onClose,
        child: ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (context, value, _) => TextField(
            key: fieldKey,
            controller: controller,
            focusNode: focusNode,
            onChanged: onChanged,
            style: AppText.body.copyWith(color: AppColors.textPrimary),
            cursorColor: AppColors.accent,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              isDense: true,
              hintText: hint ?? episodeHint,
              hintStyle: AppText.body.copyWith(color: AppColors.textTertiary),
              filled: true,
              // Same pill fill as the round header buttons beside it.
              fillColor: AppColors.surface2,
              contentPadding: const EdgeInsets.symmetric(vertical: 9),
              prefixIcon: const Icon(
                Icons.search_rounded,
                size: 18,
                color: AppColors.textTertiary,
              ),
              prefixIconConstraints: const BoxConstraints(minWidth: 36),
              // A clear button only while there is something to clear.
              suffixIcon: value.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: context.l10n.clearFilter,
                      visualDensity: VisualDensity.compact,
                      iconSize: 16,
                      onPressed: () {
                        controller.clear();
                        onChanged('');
                      },
                      icon: const Icon(
                        Icons.close_rounded,
                        color: AppColors.textSecondary,
                      ),
                    ),
              suffixIconConstraints: const BoxConstraints(minWidth: 32),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(
                  color: AppColors.accent.withValues(alpha: .6),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact "Select" button that sits right before the search box in the
/// Episodes header (show-6) and starts selection mode. It replaces the old
/// "Select episodes" entry in the header's more menu.
class EpisodeSelectButton extends StatelessWidget {
  const EpisodeSelectButton({
    super.key,
    required this.onPressed,
    this.isReading = false,
  });

  /// Lets tests (and the page) find the button.
  static const buttonKey = ValueKey('episode-select-button');

  final VoidCallback onPressed;

  /// Reading titles say "chapters" in the tooltip.
  final bool isReading;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Tooltip(
      // The full name plus the shortcut that does the same per row.
      message:
          '${isReading ? l10n.selectChapters : l10n.selectEpisodes} '
          '(Ctrl+Click)',
      child: TextButton.icon(
        key: buttonKey,
        onPressed: onPressed,
        style: TextButton.styleFrom(
          // Same pill fill and height as the search box beside it.
          backgroundColor: AppColors.surface2,
          foregroundColor: AppColors.textPrimary,
          minimumSize: const Size(0, 36),
          fixedSize: const Size.fromHeight(36),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        icon: const Icon(Icons.checklist_rounded, size: 18),
        // Short translated label (the tooltip carries the full hint).
        label: Text(
          l10n.selectShort,
          style: AppText.body.copyWith(fontSize: 13),
        ),
      ),
    );
  }
}

/// Toolbar shown while episodes are selected (show-6):
/// "N selected · Mark watched · Mark unwatched · Download", plus Select all
/// and a close button that clears the selection (same as Esc).
class EpisodeSelectionBar extends StatelessWidget {
  const EpisodeSelectionBar({
    super.key,
    required this.count,
    required this.onMarkWatched,
    required this.onMarkUnwatched,
    required this.onSelectAll,
    required this.onClear,
    this.onDownload,
    this.onDelete,
    this.isReading = false,
  });

  static const barKey = ValueKey('episode-selection-bar');

  /// Downloaded show page: deletes the selected episodes' files. Null hides
  /// Delete (the normal page).
  final VoidCallback? onDelete;

  final int count;
  final VoidCallback onMarkWatched;
  final VoidCallback onMarkUnwatched;
  final VoidCallback onSelectAll;
  final VoidCallback onClear;

  /// Null hides Download (nothing downloadable for this title).
  final VoidCallback? onDownload;

  /// Reading titles say "read" instead of "watched".
  final bool isReading;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accent;
    // Text buttons in the graphite style. The actions on the picked
    // episodes are disabled while nothing is picked; Select all is not,
    // because that is exactly when it is needed.
    Widget action(
      String label,
      IconData icon,
      VoidCallback onTap, {
      bool needsSelection = true,
    }) => TextButton.icon(
      onPressed: needsSelection && count == 0 ? null : onTap,
      style: TextButton.styleFrom(
        foregroundColor: AppColors.textPrimary,
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      icon: Icon(icon, size: 18),
      label: Text(label, style: AppText.body.copyWith(fontSize: 13)),
    );

    return Container(
      key: barKey,
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        // Graphite surface with an accent wash, like a selected sidebar row.
        color: Color.alphaBlend(
          DesktopChrome.selectedFill(accent),
          DesktopPanelColors.surface,
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: DesktopPanelColors.edge),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: context.l10n.clearSelectionEsc,
            visualDensity: VisualDensity.compact,
            onPressed: onClear,
            icon: const Icon(Icons.close_rounded, size: 18),
            color: AppColors.textSecondary,
          ),
          const SizedBox(width: 2),
          Text(
            context.l10n.countSelected(count),
            style: AppText.body.copyWith(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 8),
          // The actions scroll sideways rather than overflow on a narrow
          // window.
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: Row(
                children: [
                  action(
                    context.l10n.selectAll,
                    Icons.select_all_rounded,
                    onSelectAll,
                    needsSelection: false,
                  ),
                  action(
                    isReading
                        ? context.l10n.markRead
                        : context.l10n.markWatched,
                    Icons.check_circle_outline_rounded,
                    onMarkWatched,
                  ),
                  action(
                    isReading
                        ? context.l10n.markUnread
                        : context.l10n.markUnwatched,
                    Icons.radio_button_unchecked_rounded,
                    onMarkUnwatched,
                  ),
                  if (onDownload != null)
                    action(
                      context.l10n.download,
                      Icons.download_rounded,
                      onDownload!,
                    ),
                  if (onDelete != null)
                    action(
                      context.l10n.delete,
                      Icons.delete_outline_rounded,
                      onDelete!,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Wraps one episode row or grid tile with the Windows selection look
/// (show-6): an accent wash while selected and a small checkbox that fades in
/// on hover (always shown in selection mode). The child keeps its own taps.
class EpisodeSelectableTile extends StatefulWidget {
  const EpisodeSelectableTile({
    super.key,
    required this.selected,
    required this.selectionActive,
    required this.onCheckbox,
    required this.child,
    this.checkboxOffset = const Offset(6, 6),
    this.checkboxSize = 20,
    this.radius = 10,
  });

  final bool selected;

  /// Selection mode is on, so every checkbox stays visible.
  final bool selectionActive;

  /// Checkbox clicked: toggles this episode.
  final VoidCallback onCheckbox;
  final Widget child;

  /// Top-left position of the checkbox inside the tile.
  final Offset checkboxOffset;
  final double checkboxSize;
  final double radius;

  @override
  State<EpisodeSelectableTile> createState() => _EpisodeSelectableTileState();
}

class _EpisodeSelectableTileState extends State<EpisodeSelectableTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Stack(
        children: [
          // Selected: the same accent wash the desktop chrome uses.
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                decoration: BoxDecoration(
                  color: widget.selected
                      ? DesktopChrome.selectedFill(AppColors.accent)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(widget.radius),
                ),
              ),
            ),
          ),
          widget.child,
          Positioned(
            left: widget.checkboxOffset.dx,
            top: widget.checkboxOffset.dy,
            child: DesktopSelectionCheckbox(
              selected: widget.selected,
              visible: _hover || widget.selectionActive,
              size: widget.checkboxSize,
              onChanged: (_) => widget.onCheckbox(),
            ),
          ),
        ],
      ),
    );
  }
}

/// Fixed-height pinned sliver header, used to keep the selection toolbar in
/// view while the episode list scrolls under it.
class PinnedBoxDelegate extends SliverPersistentHeaderDelegate {
  PinnedBoxDelegate({required this.height, required this.child});

  final double height;
  final Widget child;

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) =>
      SizedBox.expand(child: child);

  @override
  bool shouldRebuild(PinnedBoxDelegate old) =>
      old.height != height || old.child != child;
}
