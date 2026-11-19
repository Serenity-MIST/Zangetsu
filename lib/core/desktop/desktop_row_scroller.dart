import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';
import '../ui/desktop_docked_panel.dart';

/// Scroll behaviour that also lets a mouse drag a horizontal row, as a
/// finger would on phone (Flutter leaves mouse out of drag devices).
class DesktopDragScrollBehavior extends MaterialScrollBehavior {
  const DesktopDragScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
    ...super.dragDevices,
    PointerDeviceKind.mouse,
  };
}

/// Wraps a horizontal row (ListView with [controller]) for mouse users.
///
/// Windows: arrow buttons fade in at both ends on hover (each hidden when
/// the row is already at that end) and scroll one page; Shift+wheel and a
/// horizontal trackpad/tilt wheel scroll the row; the mouse can drag it.
/// Elsewhere the child is returned untouched.
class DesktopRowScroller extends StatefulWidget {
  const DesktopRowScroller({
    super.key,
    required this.controller,
    required this.child,
    this.pageFraction = .85,
    this.arrowSize = 36,
  });

  /// The controller of the row's horizontal scroll view.
  final ScrollController controller;
  final Widget child;

  /// Share of the visible width one arrow click scrolls.
  final double pageFraction;

  /// Diameter of the round arrow buttons.
  final double arrowSize;

  @override
  State<DesktopRowScroller> createState() => _DesktopRowScrollerState();
}

class _DesktopRowScrollerState extends State<DesktopRowScroller> {
  bool _hovered = false;
  bool _canBack = false;
  bool _canForward = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_sync);
    // Metrics only exist after the first layout.
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void didUpdateWidget(DesktopRowScroller oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_sync);
      widget.controller.addListener(_sync);
      WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_sync);
    super.dispose();
  }

  /// Recomputes which arrows make sense from the row's scroll position.
  void _sync() {
    if (!mounted) return;
    final c = widget.controller;
    var back = false;
    var forward = false;
    if (c.hasClients && c.positions.length == 1) {
      final p = c.position;
      if (p.hasContentDimensions && p.hasPixels) {
        // A pixel of slack avoids an arrow flickering at the very end.
        back = p.pixels > p.minScrollExtent + 1;
        forward = p.pixels < p.maxScrollExtent - 1;
      }
    }
    if (back != _canBack || forward != _canForward) {
      setState(() {
        _canBack = back;
        _canForward = forward;
      });
    }
  }

  /// Animates one page back (-1) or forward (+1).
  void _page(int direction) {
    final c = widget.controller;
    if (!c.hasClients) return;
    final p = c.position;
    final target =
        (p.pixels + direction * p.viewportDimension * widget.pageFraction)
            .clamp(p.minScrollExtent, p.maxScrollExtent);
    c.animateTo(
      target,
      duration: MediaQuery.disableAnimationsOf(context)
          ? const Duration(milliseconds: 1)
          : const Duration(milliseconds: 380),
      curve: Curves.easeOutCubic,
    );
  }

  /// Shift+wheel (and a horizontal wheel delta) scrolls the row, claimed
  /// through the pointer-signal resolver so the page does not also scroll.
  void _onSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final c = widget.controller;
    if (!c.hasClients) return;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final delta = shift && event.scrollDelta.dx == 0
        ? event.scrollDelta.dy
        : event.scrollDelta.dx;
    if (delta == 0) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (e) {
      final p = c.position;
      c.jumpTo((p.pixels + delta).clamp(p.minScrollExtent, p.maxScrollExtent));
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!desktopPanelsEnabled) return widget.child;
    return NotificationListener<ScrollMetricsNotification>(
      // Content width changes (items loaded) can toggle the forward arrow.
      onNotification: (_) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
        return false;
      },
      child: MouseRegion(
        onEnter: (_) {
          _sync();
          setState(() => _hovered = true);
        },
        onExit: (_) => setState(() => _hovered = false),
        child: Listener(
          onPointerSignal: _onSignal,
          child: Stack(
            children: [
              ScrollConfiguration(
                behavior: const DesktopDragScrollBehavior(),
                child: widget.child,
              ),
              _arrow(back: true, visible: _hovered && _canBack),
              _arrow(back: false, visible: _hovered && _canForward),
            ],
          ),
        ),
      ),
    );
  }

  /// One round arrow button, vertically centred on its edge.
  Widget _arrow({required bool back, required bool visible}) =>
      PositionedDirectional(
        start: back ? 6 : null,
        end: back ? null : 6,
        top: 0,
        bottom: 0,
        child: Center(
          child: IgnorePointer(
            ignoring: !visible,
            child: AnimatedOpacity(
              opacity: visible ? 1 : 0,
              duration: const Duration(milliseconds: 140),
              child: Material(
                color: DesktopPanelColors.surface.withValues(alpha: .92),
                shape: CircleBorder(
                  side: BorderSide(color: DesktopPanelColors.edge),
                ),
                elevation: 6,
                shadowColor: Colors.black,
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => _page(back ? -1 : 1),
                  child: SizedBox.square(
                    dimension: widget.arrowSize,
                    child: Icon(
                      back
                          ? Icons.chevron_left_rounded
                          : Icons.chevron_right_rounded,
                      color: AppColors.textPrimary,
                      size: widget.arrowSize * .62,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}
