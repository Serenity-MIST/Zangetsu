import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Desktop reading input and independent, transient edge controls.
/// Direction is supplied on every build so preference changes apply immediately.
class DesktopReaderInput extends StatefulWidget {
  const DesktopReaderInput({
    super.key,
    required this.direction,
    required this.onVerticalScroll,
    required this.onPageStep,
    required this.builder,
  });

  final String direction;
  final ValueChanged<double> onVerticalScroll;
  final ValueChanged<bool> onPageStep;
  final Widget Function(bool topVisible, bool bottomVisible) builder;

  @override
  State<DesktopReaderInput> createState() => _DesktopReaderInputState();
}

/// Keeps mouse hover changes local and lets child scrollables claim wheel input.
class _DesktopReaderInputState extends State<DesktopReaderInput> {
  Timer? _hide;
  bool _top = false;
  bool _bottom = false;
  Duration? _lastWheel;
  double _wheelDelta = 0;

  @override
  void didUpdateWidget(DesktopReaderInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.direction != oldWidget.direction) {
      _wheelDelta = 0;
      _lastWheel = null;
    }
  }

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  /// Only rebuilds when an edge changes, rather than on every mouse movement.
  void _show(bool top, bool bottom) {
    if (_top == top && _bottom == bottom) return;
    setState(() {
      _top = top;
      _bottom = bottom;
    });
  }

  /// Gives the pointer a short grace period while leaving the floating controls.
  void _leaveEdges() {
    _hide?.cancel();
    _hide = Timer(const Duration(milliseconds: 600), () {
      if (mounted) _show(false, false);
    });
  }

  /// Uses the rendered direction, including chapter and per-series overrides.
  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (ModalRoute.of(context)?.isCurrent == false) {
      return KeyEventResult.ignored;
    }
    if (HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (widget.direction == 'vertical') {
      if (key == LogicalKeyboardKey.arrowDown ||
          key == LogicalKeyboardKey.pageDown) {
        widget.onVerticalScroll(
          0.85 * (context.size?.height ?? MediaQuery.sizeOf(context).height),
        );
      } else if (key == LogicalKeyboardKey.arrowUp ||
          key == LogicalKeyboardKey.pageUp) {
        widget.onVerticalScroll(
          -0.85 * (context.size?.height ?? MediaQuery.sizeOf(context).height),
        );
      } else {
        return KeyEventResult.ignored;
      }
    } else {
      if (key == LogicalKeyboardKey.pageDown ||
          key == LogicalKeyboardKey.pageUp) {
        widget.onPageStep(key == LogicalKeyboardKey.pageDown);
      } else if (key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.arrowRight) {
        widget.onPageStep(
          (key == LogicalKeyboardKey.arrowRight) == (widget.direction != 'rtl'),
        );
      } else {
        return KeyEventResult.ignored;
      }
    }
    return KeyEventResult.handled;
  }

  /// Vertical wheels advance reading order; horizontal wheels follow page layout.
  void _wheel(PointerSignalEvent signal) {
    if (signal is! PointerScrollEvent ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(signal, (event) {
      final wheel = event as PointerScrollEvent;
      if (widget.direction == 'vertical') {
        widget.onVerticalScroll(wheel.scrollDelta.dy);
        return;
      }
      final horizontal =
          wheel.scrollDelta.dx.abs() > wheel.scrollDelta.dy.abs();
      final amount = horizontal ? wheel.scrollDelta.dx : wheel.scrollDelta.dy;
      _wheelDelta += amount;
      if (_wheelDelta.abs() < 32) return;
      if (_lastWheel != null &&
          wheel.timeStamp - _lastWheel! < const Duration(milliseconds: 150)) {
        return;
      }
      var forward = _wheelDelta > 0;
      if (horizontal && widget.direction == 'rtl') forward = !forward;
      _wheelDelta = 0;
      _lastWheel = wheel.timeStamp;
      widget.onPageStep(forward);
    });
  }

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    onKeyEvent: _key,
    child: LayoutBuilder(
      builder: (context, constraints) => MouseRegion(
        onHover: (event) {
          final top = event.localPosition.dy < 96;
          final bottom = event.localPosition.dy > constraints.maxHeight - 96;
          if (top || bottom) {
            _hide?.cancel();
            _show(top, bottom);
          } else {
            _leaveEdges();
          }
        },
        onExit: (_) => _leaveEdges(),
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerSignal: _wheel,
          child: widget.builder(_top, _bottom),
        ),
      ),
    ),
  );
}
