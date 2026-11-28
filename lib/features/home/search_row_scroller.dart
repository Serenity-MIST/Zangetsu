import 'package:flutter/material.dart';

import '../../core/desktop/desktop_row_scroller.dart';
import '../../core/ui/desktop_docked_panel.dart';

/// Gives one horizontal row on the Search screen (a source's posters or a
/// chip strip) mouse support on Windows (search-3): click-drag, Shift+wheel
/// and hover arrows at both ends, via the shared [DesktopRowScroller].
///
/// [builder] receives the controller to put on the row's ListView. Off
/// Windows it receives null and the row is returned untouched, so phone
/// rows behave exactly as before.
class SearchRowScroller extends StatefulWidget {
  const SearchRowScroller({
    super.key,
    required this.builder,
    this.arrowSize = 36,
  });

  /// Builds the horizontal list; pass the controller to its `controller`.
  final Widget Function(ScrollController? controller) builder;

  /// Diameter of the hover arrows (smaller for short chip strips).
  final double arrowSize;

  @override
  State<SearchRowScroller> createState() => _SearchRowScrollerState();
}

class _SearchRowScrollerState extends State<SearchRowScroller> {
  // Only created on Windows, where the arrows need to read and move it.
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
