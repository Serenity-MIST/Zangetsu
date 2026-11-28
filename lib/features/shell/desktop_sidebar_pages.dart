import 'package:flutter/material.dart';

import '../../core/desktop/desktop_memory.dart';

/// Keeps visited Windows sidebar pages inside the desktop frame, retaining
/// their scroll/form state without pushing another application-level route.
/// A profile key on this host discards retained pages when the viewer changes.
class DesktopSidebarPages extends StatefulWidget {
  const DesktopSidebarPages({
    super.key,
    required this.selected,
    required this.builders,
    required this.fallback,
  });
  final String? selected;
  final Map<String, WidgetBuilder> builders;
  final Widget fallback;
  @override
  State<DesktopSidebarPages> createState() => _DesktopSidebarPagesState();

  /// How many sidebar pages stay open in the background, counting the one on
  /// screen; 0 means no limit. Each kept page holds its decoded posters and
  /// keeps its timers running, so an 8 GB PC keeps only the current page and
  /// the last one. Every other PC (and one whose memory size is unknown)
  /// keeps every visited page, as before. A page dropped this way is built
  /// again (from its cache) when it is opened next.
  static int get retainedLimit =>
      debugRetainedLimit ?? (DesktopMemory.isLowMemory ? 2 : 0);

  /// Tests set this to check the limit without a real memory reading.
  @visibleForTesting
  static int? debugRetainedLimit;
}

class _DesktopSidebarPagesState extends State<DesktopSidebarPages> {
  /// Visited pages, least recently shown first.
  final _visited = <String>[];
  @override
  Widget build(BuildContext context) {
    final keys = widget.builders.keys.toList();
    final selected = widget.selected;
    if (selected != null && widget.builders.containsKey(selected)) {
      // Move the shown page to the most recent end, then forget the oldest
      // pages beyond the limit so their memory can be released.
      _visited
        ..remove(selected)
        ..add(selected);
      final limit = DesktopSidebarPages.retainedLimit;
      while (_visited.length > limit && limit > 0) {
        _visited.removeAt(0);
      }
    }
    final index = selected == null ? -1 : keys.indexOf(selected);
    // Each child is wrapped in TooltipVisibility as well as TickerMode. A
    // tooltip's label lives in the app Overlay, not inside the page, and it
    // fades out with an animation driven by the page's tickers. When a click
    // switches pages (Profile's History button, Settings' Back arrow), the old
    // page's tickers are muted mid-fade and its label stayed painted forever
    // ('Back' / 'History' stuck on the History screen). TooltipVisibility
    // (false) removes the tooltip machinery of hidden pages, so any label they
    // were showing disappears at once and hidden pages cannot show new ones.
    return IndexedStack(
      index: index + 1,
      children: [
        TooltipVisibility(
          visible: index < 0,
          child: TickerMode(enabled: index < 0, child: widget.fallback),
        ),
        for (final key in keys)
          TooltipVisibility(
            key: ValueKey(key),
            visible: selected == key,
            child: TickerMode(
              enabled: selected == key,
              child: _visited.contains(key)
                  ? Builder(builder: widget.builders[key]!)
                  : const SizedBox.shrink(),
            ),
          ),
      ],
    );
  }
}
