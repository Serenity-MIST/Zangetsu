// Windows: keeps the Skip / Skip recap pill reliably clickable.
//
// Why this exists: the pill used to sit UNDER the watch page's transport bar
// (it came earlier in the Stack and the bar is ~120px tall, the pill sat at
// 72px), so while the bar was showing a click on the pill landed on the seek
// bar instead. It only worked once the bar had faded out, which read as "the
// button works sometimes". In theatre mode the pill jumps up when the
// controls show and back down when they hide, so it could slide out from
// under a parked mouse right before the click. The host below keeps the
// pill still while the mouse is over it, and the callers now put it on top
// of the bar in the Stack.
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Places the skip pill in a [Stack] at [right] / [bottom] (animated when
/// [bottom] changes) and freezes that spot while the mouse is over it, so
/// the controls showing or hiding never move the pill away from the
/// pointer between hover and click. Must be a direct child of a [Stack]
/// (builders in between are fine), like [Positioned].
class DesktopSkipPillHost extends StatefulWidget {
  const DesktopSkipPillHost({
    super.key,
    required this.right,
    required this.bottom,
    required this.child,
  });

  /// Gap from the Stack's right edge.
  final double right;

  /// Wanted gap from the Stack's bottom edge (follows the controls).
  final double bottom;

  /// The pill itself.
  final Widget child;

  @override
  State<DesktopSkipPillHost> createState() => _DesktopSkipPillHostState();
}

class _DesktopSkipPillHostState extends State<DesktopSkipPillHost> {
  /// The bottom gap held while the mouse is over the pill; null otherwise.
  double? _frozenBottom;

  @override
  Widget build(BuildContext context) {
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      right: widget.right,
      // Hovered: stay where the mouse found it. Otherwise follow the bar.
      bottom: _frozenBottom ?? widget.bottom,
      child: MouseRegion(
        // Enter fires in the same pointer event that may show the controls,
        // before the rebuild, so the spot taken here is the old one.
        onEnter: (_) => setState(() => _frozenBottom = widget.bottom),
        onExit: (_) => setState(() => _frozenBottom = null),
        child: widget.child,
      ),
    );
  }
}

/// Reports its child's laid-out height to [height] (after layout, on the
/// next frame), so the skip pill can sit just above a bar of any height.
class DesktopHeightReporter extends SingleChildRenderObjectWidget {
  const DesktopHeightReporter({
    super.key,
    required this.height,
    required super.child,
  });

  /// Receives the child's height whenever it changes.
  final ValueNotifier<double> height;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderHeightReporter(height);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderObject renderObject,
  ) {
    // A new notifier (rare): report into that one from now on.
    (renderObject as _RenderHeightReporter).target = height;
  }
}

/// Render side of [DesktopHeightReporter]: a plain proxy that only reads
/// its own height after layout.
class _RenderHeightReporter extends RenderProxyBox {
  _RenderHeightReporter(this.target);

  /// Where the height goes.
  ValueNotifier<double> target;

  @override
  void performLayout() {
    super.performLayout();
    final h = size.height;
    if ((h - target.value).abs() > 0.5) {
      // Never change a notifier during layout; listeners rebuild next frame.
      final into = target;
      // Skipped once this box left the tree (its page, and the notifier
      // with it, may be disposed by then).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (attached) into.value = h;
      });
    }
  }
}
