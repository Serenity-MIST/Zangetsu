import 'package:flutter/material.dart';

/// Shared desktop hover/focus motion without changing surrounding layout.
///
/// A transform keeps neighboring controls stationary. Focus mirrors hover so
/// keyboard users get the same feedback; reduced-motion users get no movement.
class DesktopSettingsMotion extends StatefulWidget {
  const DesktopSettingsMotion({super.key, required this.child});

  final Widget child;

  @override
  State<DesktopSettingsMotion> createState() => _DesktopSettingsMotionState();
}

/// Tracks pointer and descendant focus independently to avoid a hover exit
/// removing the feedback while the control still has keyboard focus.
class _DesktopSettingsMotionState extends State<DesktopSettingsMotion> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    final highlighted = !reduced && (_hovered || _focused);
    final duration = reduced
        ? Duration.zero
        : const Duration(milliseconds: 180);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (value) => setState(() => _focused = value),
        child: AnimatedSlide(
          offset: highlighted ? const Offset(0, -0.015) : Offset.zero,
          duration: duration,
          curve: Curves.easeOutCubic,
          child: AnimatedScale(
            scale: highlighted ? 1.015 : 1,
            duration: duration,
            curve: Curves.easeOutCubic,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
