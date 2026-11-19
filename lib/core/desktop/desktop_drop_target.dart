import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'desktop_native.dart';

/// Receives files / links dragged onto the window from Explorer or a
/// browser, but only when they are dropped inside this widget's own box.
/// On every platform other than Windows it simply shows [child].
class DesktopDropTarget extends StatefulWidget {
  const DesktopDropTarget({
    super.key,
    required this.child,
    required this.onDrop,
    this.onHoverChanged,
    this.acceptFiles = true,
    this.acceptText = false,
  });

  final Widget child;

  /// Called with drops inside this widget that carry accepted content.
  final void Function(DesktopDropEvent event) onDrop;

  /// true while a drag hovers over this widget, false when it leaves.
  final ValueChanged<bool>? onHoverChanged;

  /// Accept dropped files (Explorer).
  final bool acceptFiles;

  /// Accept dropped text / links (browsers).
  final bool acceptText;

  @override
  State<DesktopDropTarget> createState() => _DesktopDropTargetState();

  /// True when [event] carries content this target accepts.
  @visibleForTesting
  static bool accepts(
    DesktopDropEvent event, {
    required bool acceptFiles,
    required bool acceptText,
  }) =>
      (acceptFiles && event.paths.isNotEmpty) ||
      (acceptText && (event.text?.isNotEmpty ?? false));
}

class _DesktopDropTargetState extends State<DesktopDropTarget> {
  StreamSubscription<DesktopDropEvent>? _drops;
  bool _hovering = false;
  // Remembers whether listeners were added, even if the platform override
  // changes before dispose (tests).
  bool _listening = false;

  // UI behaviour is Windows-only; tests switch it on with
  // debugDefaultTargetPlatformOverride.
  bool get _enabled => defaultTargetPlatform == TargetPlatform.windows;

  @override
  void initState() {
    super.initState();
    if (!_enabled) return;
    _listening = true;
    _drops = DesktopNative.drops.listen(_onDrop);
    DesktopNative.dragPosition.addListener(_onDrag);
  }

  @override
  void dispose() {
    _drops?.cancel();
    if (_listening) DesktopNative.dragPosition.removeListener(_onDrag);
    super.dispose();
  }

  // Whether a window position (logical px) lies inside this widget.
  bool _contains(Offset position) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return false;
    return (Offset.zero & box.size).contains(box.globalToLocal(position));
  }

  void _onDrag() {
    final position = DesktopNative.dragPosition.value;
    final inside = position != null && mounted && _contains(position);
    if (inside == _hovering) return;
    _hovering = inside;
    widget.onHoverChanged?.call(inside);
  }

  void _onDrop(DesktopDropEvent event) {
    if (!mounted) return;
    // The drop also ends the hover.
    if (_hovering) {
      _hovering = false;
      widget.onHoverChanged?.call(false);
    }
    if (!_contains(event.position)) return;
    if (!DesktopDropTarget.accepts(
      event,
      acceptFiles: widget.acceptFiles,
      acceptText: widget.acceptText,
    )) {
      return;
    }
    widget.onDrop(event);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
