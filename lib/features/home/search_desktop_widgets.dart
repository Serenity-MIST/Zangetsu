import 'package:flutter/material.dart';

import '../../core/desktop/desktop_row_scroller.dart';
import '../../core/ui/desktop_docked_panel.dart';
import '../../l10n/l10n.dart';

/// Small Windows-only helpers used by the main Search screen.
///
/// Everything here passes straight through off Windows (and on TV), so the
/// phone layout of Search is unchanged.

/// A horizontal strip (result row or chip strip) that a mouse can scroll.
///
/// On Windows the strip gets its own [ScrollController] and is wrapped in
/// [DesktopRowScroller]: mouse drag, Shift+wheel and hover arrows at both
/// ends (search-3). Elsewhere [builder] is called with a null controller and
/// returned untouched, exactly as the strip was built before.
class SearchDesktopRow extends StatefulWidget {
  const SearchDesktopRow({
    super.key,
    required this.builder,
    this.arrowSize = 36,
  });

  /// Builds the horizontal list; it must use the controller it is given.
  final Widget Function(ScrollController? controller) builder;

  /// Diameter of the hover arrows (smaller for short chip strips).
  final double arrowSize;

  @override
  State<SearchDesktopRow> createState() => _SearchDesktopRowState();
}

class _SearchDesktopRowState extends State<SearchDesktopRow> {
  // Only created on Windows; phone keeps the list's own default controller.
  ScrollController? _controller;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!desktopPanelsEnabled) return widget.builder(null);
    final controller = _controller ??= ScrollController();
    return DesktopRowScroller(
      controller: controller,
      arrowSize: widget.arrowSize,
      child: widget.builder(controller),
    );
  }
}

/// Rebuilds [builder] with whether the mouse is over it.
///
/// Used for hover-only controls such as the remove x on a recent search
/// chip on Windows (search-9).
class SearchHoverBuilder extends StatefulWidget {
  const SearchHoverBuilder({super.key, required this.builder});

  final Widget Function(BuildContext context, bool hovered) builder;

  @override
  State<SearchHoverBuilder> createState() => _SearchHoverBuilderState();
}

class _SearchHoverBuilderState extends State<SearchHoverBuilder> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: widget.builder(context, _hovered),
  );
}

/// The 'Load more' fallback button at the end of a paged list on Windows.
///
/// Paging normally happens on its own (scrolling near the end, or the
/// post-frame check when the first page does not fill the window); this
/// button is the backup so a list never silently stops (search-2).
class SearchLoadMoreButton extends StatelessWidget {
  const SearchLoadMoreButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 16),
    child: Center(
      child: OutlinedButton.icon(
        key: const ValueKey('search-load-more'),
        onPressed: onPressed,
        icon: const Icon(Icons.expand_more_rounded, size: 18),
        label: Text(context.l10n.loadMore),
      ),
    ),
  );
}

/// True when the scroll view behind [controller] cannot scroll far enough to
/// trigger its own 'near the end' paging, i.e. less than [threshold] pixels
/// of content remain below the viewport (including a list that does not
/// scroll at all because the first page fits).
bool searchListNeedsMore(ScrollController controller, {double threshold = 600}) {
  if (!controller.hasClients || controller.positions.length != 1) return false;
  final p = controller.position;
  if (!p.hasContentDimensions || !p.hasPixels) return false;
  return p.extentAfter < threshold;
}
