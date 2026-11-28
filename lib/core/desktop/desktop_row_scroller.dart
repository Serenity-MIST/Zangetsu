import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';
import '../ui/desktop_docked_panel.dart';
import 'desktop_smooth_scroll.dart';

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
    this.stride,
  });

  /// Distance from one card's start to the next (card width plus gap). When
  /// set, an arrow click moves by whole cards and stops on a card edge, so
  /// the row never rests on a half card. Null keeps the plain page scroll.
  final double? stride;

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

  /// Where the mouse really is. [_hovered] follows it, but waits while the
  /// page scrolls, so rows passing under the mouse do not fade arrows in and
  /// out (and rebuild) in the middle of a scroll.
  bool _pointerInside = false;

  /// The page whose scroll [_hovered] is waiting for, if any.
  ValueListenable<bool>? _waitingFor;
  Timer? _hoverDelay;

  /// How long after the page stopped the arrows follow the mouse again.
  static const _hoverSettle = Duration(milliseconds: 100);

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
    _stopWaiting();
    super.dispose();
  }

  /// The mouse came in or left: shown at once, or once the page is still.
  void _setPointerInside(bool inside) {
    _pointerInside = inside;
    // Already waiting for the page to come to rest.
    if (_hoverDelay != null) return;
    final moving = _movingPage();
    if (moving != null && identical(moving, _waitingFor)) return;
    _stopWaiting();
    if (moving == null) {
      _applyHover();
      return;
    }
    _waitingFor = moving..addListener(_pageMoved);
  }

  /// The scroll signal of the vertical page around this row, if it is moving.
  ValueListenable<bool>? _movingPage() {
    var page = context.findAncestorStateOfType<ScrollableState>();
    while (page != null) {
      if (axisDirectionToAxis(page.axisDirection) == Axis.vertical) {
        final scrolling = page.position.isScrollingNotifier;
        if (scrolling.value) return scrolling;
      }
      page = page.context.findAncestorStateOfType<ScrollableState>();
    }
    return null;
  }

  void _pageMoved() {
    _hoverDelay?.cancel();
    _hoverDelay = null;
    if (_waitingFor?.value ?? false) return;
    _hoverDelay = Timer(_hoverSettle, () {
      _stopWaiting();
      _applyHover();
    });
  }

  void _stopWaiting() {
    _hoverDelay?.cancel();
    _hoverDelay = null;
    _waitingFor?.removeListener(_pageMoved);
    _waitingFor = null;
  }

  void _applyHover() {
    if (!mounted) return;
    if (_pointerInside) _sync();
    if (_hovered != _pointerInside) {
      setState(() => _hovered = _pointerInside);
    }
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
    final stride = widget.stride;
    final double target;
    if (stride != null && stride > 0) {
      // Whole cards per click (at least one), starting from the card edge
      // nearest to where the row is now.
      final cards = math.max(
        1,
        (p.viewportDimension * widget.pageFraction / stride).floor(),
      );
      final from = (p.pixels / stride).round() * stride;
      target = (from + direction * cards * stride).clamp(
        p.minScrollExtent,
        p.maxScrollExtent,
      );
    } else {
      target =
          (p.pixels + direction * p.viewportDimension * widget.pageFraction)
              .clamp(p.minScrollExtent, p.maxScrollExtent);
    }
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
      // Touchpad and fine-step wheels already move smoothly: apply as is.
      if (!desktopWheelIsNotch(event, MediaQuery.devicePixelRatioOf(context))) {
        c.position.pointerScroll(delta);
        return;
      }
      // Glides like the page wheel instead of jumping a whole notch.
      desktopSmoothScrollBy(
        c.position,
        delta,
        reduceMotion: MediaQuery.disableAnimationsOf(context),
      );
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
        onEnter: (_) => _setPointerInside(true),
        onExit: (_) => _setPointerInside(false),
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
  Widget _arrow({
    required bool back,
    required bool visible,
  }) => PositionedDirectional(
    start: back ? 6 : null,
    end: back ? null : 6,
    top: 0,
    bottom: 0,
    child: Center(
      child: _FadingArrow(
        visible: visible,
        builder: (_) => Material(
          color: DesktopPanelColors.surface.withValues(alpha: .92),
          shape: CircleBorder(side: BorderSide(color: DesktopPanelColors.edge)),
          elevation: 6,
          shadowColor: Colors.black,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => _page(back ? -1 : 1),
            child: SizedBox.square(
              dimension: widget.arrowSize,
              child: Icon(
                back ? Icons.chevron_left_rounded : Icons.chevron_right_rounded,
                color: AppColors.textPrimary,
                size: widget.arrowSize * .62,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Fades an arrow in and out. While it is hidden and fully faded nothing is
/// built at all, so a page full of rows carries no invisible buttons.
class _FadingArrow extends StatefulWidget {
  const _FadingArrow({required this.visible, required this.builder});
  final bool visible;
  final WidgetBuilder builder;

  @override
  State<_FadingArrow> createState() => _FadingArrowState();
}

class _FadingArrowState extends State<_FadingArrow> {
  /// The arrow is in the tree (shown, or still fading out).
  late bool _built = widget.visible;

  /// The opacity it is fading to. A new arrow starts see-through for one
  /// frame, so it fades in instead of popping up.
  late double _opacity = widget.visible ? 1 : 0;

  @override
  void didUpdateWidget(_FadingArrow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible == widget.visible) return;
    if (!widget.visible) {
      _opacity = 0;
      return;
    }
    if (_built) {
      _opacity = 1;
      return;
    }
    _built = true;
    _opacity = 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.visible) {
        setState(() => _opacity = 1);
      } else if (_opacity == 0) {
        // Hidden again before it ever showed: no fade-out will end it.
        setState(() => _built = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_built) return const SizedBox.shrink();
    return IgnorePointer(
      ignoring: !widget.visible,
      child: AnimatedOpacity(
        opacity: _opacity,
        duration: const Duration(milliseconds: 140),
        onEnd: () {
          if (mounted && !widget.visible) setState(() => _built = false);
        },
        child: widget.builder(context),
      ),
    );
  }
}
