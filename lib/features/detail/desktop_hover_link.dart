import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// A tappable text link on the detail page ("Read more", "… more").
///
/// On Windows it behaves like the other desktop links and buttons: a hand
/// cursor, a highlight while the mouse is over it, and it can be reached with
/// Tab and pressed with Enter / Space (with a thin accent ring while it has
/// keyboard focus). [builder] gets `highlighted = true` while hovered or
/// keyboard focused, so the caller can underline / brighten its link text.
///
/// On every other platform it is exactly the old plain tap area: a
/// [GestureDetector] that never highlights and is not focusable.
class DesktopHoverLink extends StatefulWidget {
  const DesktopHoverLink({
    super.key,
    required this.onTap,
    required this.builder,
    this.semanticLabel,
  });

  /// Runs on click, tap, Enter or Space.
  final VoidCallback onTap;

  /// Builds the link content; `highlighted` is true while hovered/focused.
  final Widget Function(BuildContext context, bool highlighted) builder;

  /// Screen-reader name for the link (Windows only); null = read the text.
  final String? semanticLabel;

  /// The link colour while highlighted: the accent, a touch brighter, like
  /// the hover colour of the other desktop links.
  static Color highlightColor() =>
      Color.lerp(AppColors.accent, Colors.white, .25) ?? AppColors.accent;

  @override
  State<DesktopHoverLink> createState() => _DesktopHoverLinkState();
}

class _DesktopHoverLinkState extends State<DesktopHoverLink> {
  /// Mouse is over the link.
  bool _hover = false;

  /// The link has focus that came from the keyboard (no ring for clicks).
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    // Not Windows: unchanged plain tap area, no hover and no focus.
    if (defaultTargetPlatform != TargetPlatform.windows) {
      return GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: widget.builder(context, false),
      );
    }
    final highlighted = _hover || _focus;
    return Semantics(
      button: true,
      label: widget.semanticLabel,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        // Enter / Space reach this as ActivateIntent through the app's
        // default shortcuts.
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap();
              return null;
            },
          ),
        },
        onShowHoverHighlight: (v) => setState(() => _hover = v),
        onShowFocusHighlight: (v) => setState(() => _focus = v),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 120),
            // Keyboard focus ring drawn on top so it never moves the text.
            foregroundDecoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: _focus ? AppColors.accent : Colors.transparent,
                width: 1.5,
              ),
            ),
            child: widget.builder(context, highlighted),
          ),
        ),
      ),
    );
  }
}
