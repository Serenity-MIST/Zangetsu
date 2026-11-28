// Icon actions and the tab-bar header.
part of 'detail_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Muted credit line: "Starring: a, b, c… more" / "Creators: …" / "Genres: …".
// The label is slightly dimmer than the value, matching Netflix's hierarchy.
// ─────────────────────────────────────────────────────────────────────────────

/// A muted "Label: value" credit line used by the Windows desktop detail
/// layout (Starring / Genres / Creators).
class _CreditLine extends StatelessWidget {
  const _CreditLine({
    required this.label,
    required this.value,
    this.more = false,
    this.onMore,
  });

  final String label;
  final String value;

  /// When true, append a "… more" affordance. When [onMore] is also set, the
  /// whole line is tappable and jumps to the relevant tab (Cast).
  final bool more;

  /// Tapping the line (or its "… more") jumps to the related tab. Null = inert.
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final base = AppText.caption.copyWith(color: AppColors.textSecondary);
    // `highlighted` is only ever true on Windows (hover / keyboard focus):
    // the "… more" then turns a brighter accent and gets underlined.
    Widget line(bool highlighted) => Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$label: ',
              style: base.copyWith(color: AppColors.textTertiary),
            ),
            TextSpan(text: value, style: base),
            if (more)
              TextSpan(
                text: '… more',
                style: base.copyWith(
                  color: highlighted
                      ? DesktopHoverLink.highlightColor()
                      : AppColors.accent,
                  fontWeight: FontWeight.w600,
                  decoration: highlighted ? TextDecoration.underline : null,
                  decorationColor: highlighted
                      ? DesktopHoverLink.highlightColor()
                      : null,
                ),
              ),
          ],
        ),
        maxLines: _windowsDesktopUi ? 1 : 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
    final onMore = this.onMore;
    if (onMore == null) return line(false);
    // Plain tap area off Windows; hand cursor, hover highlight and keyboard
    // focus on Windows.
    return DesktopHoverLink(
      key: const ValueKey('detail-credit-more-link'),
      onTap: onMore,
      builder: (context, highlighted) => line(highlighted),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Description: synopsis clamped to 3 lines + a red "Read more" that opens the
// Details tab (which shows the full synopsis). No inline expand.
// ─────────────────────────────────────────────────────────────────────────────

/// The clamped synopsis with a "Read more" link, used by the Windows desktop
/// detail layout.
class _Description extends StatelessWidget {
  const _Description({required this.text, required this.onReadMore});

  final String text;

  /// Jumps to the Details tab (full synopsis) — no inline expansion.
  final VoidCallback onReadMore;

  @override
  Widget build(BuildContext context) {
    // Plain tap area off Windows. On Windows the block gets the hand cursor
    // and keyboard focus, and "Read more" brightens and underlines while the
    // block is hovered or focused (`highlighted` is never true elsewhere).
    return DesktopHoverLink(
      key: const ValueKey('detail-read-more-link'),
      onTap: onReadMore,
      builder: (context, highlighted) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text,
            style: AppText.body,
            maxLines: _windowsDesktopUi ? 2 : 3,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          Text(
            context.l10n.readMore,
            style: AppText.caption.copyWith(
              color: highlighted
                  ? DesktopHoverLink.highlightColor()
                  : AppColors.accent,
              fontWeight: FontWeight.w700,
              decoration: highlighted ? TextDecoration.underline : null,
              decorationColor: highlighted
                  ? DesktopHoverLink.highlightColor()
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// One of the 5 outlined icon actions.
// ─────────────────────────────────────────────────────────────────────────────

class _IconAction extends StatelessWidget {
  const _IconAction({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;

  /// Small caption shown under the icon (Netflix-style icon-over-label).
  final String label;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active ? AppColors.accent : AppColors.textPrimary;
    if (_windowsDesktopUi) {
      return Tooltip(
        message: tooltip,
        child: Material(
          color: active
              ? AppColors.accent.withValues(alpha: 0.1)
              : AppColors.surface2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(
              color: active
                  ? AppColors.accent.withValues(alpha: 0.25)
                  : AppColors.hairline,
            ),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 17, color: color),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: AppText.caption.copyWith(color: color, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: 34,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 24, color: color),
              const SizedBox(height: 6),
              Text(
                label,
                style: AppText.caption.copyWith(
                  color: active ? AppColors.accent : AppColors.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Wraps compact desktop actions while retaining evenly spaced mobile actions.
class _DetailActionRow extends StatelessWidget {
  const _DetailActionRow({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => _windowsDesktopUi
      ? Wrap(spacing: 8, runSpacing: 8, children: children)
      : Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: children,
        );
}

// ─────────────────────────────────────────────────────────────────────────────
// Pinned tab-bar delegate.
// ─────────────────────────────────────────────────────────────────────────────

class _TabBarDelegate extends SliverPersistentHeaderDelegate {
  _TabBarDelegate(this.tabBar, {this.tint});
  final Widget tabBar;
  static const double height = 56;
  final ValueListenable<Color?>? tint;

  /// Phone: the bar as is. Tablet: centred at a readable width, or on a wide
  /// tablet left-aligned to the same edge as the title and buttons.
  Widget _barFor(BuildContext context) {
    if (isWideTabletLayout(context)) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: EdgeInsets.only(left: wideSideInset(context) - 16),
          child: tabBar,
        ),
      );
    }
    return tabletColumn(context, tabBar);
  }

  @override
  double get minExtent => height;
  @override
  double get maxExtent => height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    // No divider line under the bar — just the left-aligned tabs (Sozo Read).
    final t = tint;
    if (t == null) {
      return Material(
        color: AppColors.bg,
        elevation: 0,
        child: _barFor(context),
      );
    }
    return ValueListenableBuilder<Color?>(
      valueListenable: t,
      builder: (context, c, _) => Material(
        color: c ?? AppColors.bg,
        elevation: 0,
        child: _barFor(context),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _TabBarDelegate oldDelegate) =>
      tabBar != oldDelegate.tabBar || tint != oldDelegate.tint;
}

// ─────────────────────────────────────────────────────────────────────────────
// Chip tabs: Overview / Episodes on the left, Comments pushed to the right.
// ─────────────────────────────────────────────────────────────────────────────

class _ChipTabs extends StatelessWidget {
  const _ChipTabs({
    required this.controller,
    required this.labels,
    required this.trailingLabel,
    required this.trailingIcon,
  });

  final TabController controller;

  /// The leading chips, in tab order.
  final List<String> labels;

  /// The last tab, shown on the right edge.
  final String trailingLabel;
  final IconData trailingIcon;

  @override
  Widget build(BuildContext context) {
    // The controller's index changes the instant a tap starts, and again when
    // a swipe passes halfway — so the highlight never waits on the page slide.
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final current = controller.index;
        return LayoutBuilder(
          builder: (context, box) => SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const ClampingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            // Comments sits on the right edge when there is room. On a very
            // narrow screen the row scrolls sideways instead of overflowing.
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: box.maxWidth - 32),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < labels.length; i++) ...[
                        if (i > 0) const SizedBox(width: 8),
                        _TabChip(
                          label: labels[i],
                          selected: current == i,
                          onTap: () => controller.animateTo(i),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(width: 8),
                  _TabChip(
                    label: trailingLabel,
                    icon: trailingIcon,
                    selected: current == labels.length,
                    onTap: () => controller.animateTo(labels.length),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// One chip: switches colour at once and squeezes slightly while pressed, so a
/// tap is felt before the page below has finished sliding.
class _TabChip extends StatefulWidget {
  const _TabChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  State<_TabChip> createState() => _TabChipState();
}

class _TabChipState extends State<_TabChip> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final on = widget.selected;
    final fg = on ? AppColors.accent : AppColors.textSecondary;
    return Semantics(
      button: true,
      selected: on,
      label: widget.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _down = true),
        onTapUp: (_) => setState(() => _down = false),
        onTapCancel: () => setState(() => _down = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _down ? 0.94 : 1.0,
          duration: const Duration(milliseconds: 90),
          curve: Curves.easeOut,
          child: Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: on ? AppColors.accentSoft : AppColors.surface2,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.icon != null) ...[
                  Icon(widget.icon, size: 16, color: fg),
                  const SizedBox(width: 6),
                ],
                Text(
                  widget.label,
                  style: AppText.caption.copyWith(
                    color: fg,
                    fontSize: 13.5,
                    fontWeight: on ? FontWeight.w700 : FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// The page under the chips: the old page fades out, then the new one fades in.
// Only one page is on screen at a time, so the two never overlap or fight over
// the scroll position.
// ─────────────────────────────────────────────────────────────────────────────

class _FadePages extends StatelessWidget {
  const _FadePages({required this.controller, required this.children});

  final TabController controller;
  final List<Widget> children;

  /// A flick this fast, sideways, moves to the neighbouring page.
  static const double _flick = 350;

  static const Duration _duration = Duration(milliseconds: 240);

  void _go(int delta) {
    final next = (controller.index + delta).clamp(0, controller.length - 1);
    if (next != controller.index) controller.animateTo(next);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final i = controller.index;
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          // Left flick = next page, right flick = previous. A row that scrolls
          // sideways on its own (cast, relations) keeps its own drag.
          onHorizontalDragEnd: (d) {
            final v = d.primaryVelocity ?? 0;
            if (v <= -_flick) _go(1);
            if (v >= _flick) _go(-1);
          },
          child: AnimatedSwitcher(
            duration: _duration,
            reverseDuration: _duration,
            // Both pages fill the area; the leaving one is already gone (see
            // the intervals below) by the time the new one shows.
            layoutBuilder: (current, previous) =>
                Stack(fit: StackFit.expand, children: [...previous, ?current]),
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: CurvedAnimation(
                parent: animation,
                // Arriving: waits for the first 40%, then fades in.
                curve: const Interval(0.4, 1.0, curve: Curves.easeOut),
                // Leaving: fades out in the first 40%, then is gone.
                reverseCurve: const Interval(0.6, 1.0, curve: Curves.easeIn),
              ),
              child: child,
            ),
            // PageStorageKey: coming back to a page restores where you were.
            child: KeyedSubtree(
              key: PageStorageKey<int>(i),
              child: children[i],
            ),
          ),
        );
      },
    );
  }
}
