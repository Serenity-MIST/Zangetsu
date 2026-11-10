import 'package:flutter/material.dart';

/// Keeps visited Windows sidebar pages inside the desktop frame, retaining
/// their scroll/form state without pushing another application-level route.
/// A profile key on this host discards retained pages when the viewer changes.
class DesktopSidebarPages extends StatefulWidget {
  const DesktopSidebarPages({super.key, required this.selected,
    required this.builders, required this.fallback});
  final String? selected;
  final Map<String, WidgetBuilder> builders;
  final Widget fallback;
  @override State<DesktopSidebarPages> createState() => _DesktopSidebarPagesState();
}

class _DesktopSidebarPagesState extends State<DesktopSidebarPages> {
  final _visited = <String>{};
  @override Widget build(BuildContext context) {
    final keys = widget.builders.keys.toList();
    final selected = widget.selected;
    if (selected != null && widget.builders.containsKey(selected)) _visited.add(selected);
    final index = selected == null ? -1 : keys.indexOf(selected);
    return IndexedStack(index: index + 1, children: [
      TickerMode(enabled: index < 0, child: widget.fallback),
      for (final key in keys) TickerMode(key: ValueKey(key), enabled: selected == key,
        child: _visited.contains(key) ? Builder(builder: widget.builders[key]!)
            : const SizedBox.shrink()),
    ]);
  }
}
