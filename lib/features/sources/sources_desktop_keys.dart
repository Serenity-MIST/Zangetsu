import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Windows keyboard layer for the provider screens (src-13 Option A):
/// Ctrl+F focuses the search box, F5 / Ctrl+R refreshes repositories and Esc
/// first clears the search before falling through to the app's normal Esc
/// (unfocus, then back). Off Windows the child is returned untouched, so
/// phone and TV keep today's behaviour.
class SourcesDesktopKeys extends StatelessWidget {
  const SourcesDesktopKeys({
    super.key,
    required this.child,
    this.onFind,
    this.onRefresh,
    this.onEscape,
  });

  final Widget child;

  /// Ctrl+F. Null leaves the key to the rest of the app.
  final VoidCallback? onFind;

  /// F5 / Ctrl+R.
  final VoidCallback? onRefresh;

  /// Esc. Return true when it did something (e.g. cleared the search); false
  /// lets the app-wide Esc run (unfocus the field, then go back).
  final bool Function()? onEscape;

  /// Whether the Windows key layer is active.
  static bool get enabled => defaultTargetPlatform == TargetPlatform.windows;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return Focus(
      // Takes focus when the screen opens so the keys work before anything
      // is clicked; skipped by Tab so it never shows a focus ring.
      autofocus: true,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final key = event.logicalKey;
        final ctrl = HardwareKeyboard.instance.isControlPressed;
        if (ctrl && key == LogicalKeyboardKey.keyF && onFind != null) {
          onFind!();
          return KeyEventResult.handled;
        }
        final refresh =
            key == LogicalKeyboardKey.f5 ||
            (ctrl && key == LogicalKeyboardKey.keyR);
        if (refresh && onRefresh != null) {
          onRefresh!();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.escape && onEscape != null) {
          return onEscape!() ? KeyEventResult.handled : KeyEventResult.ignored;
        }
        return KeyEventResult.ignored;
      },
      child: child,
    );
  }
}

/// Focuses the first focusable widget inside [scope] (the search field the
/// screen wrapped in that scope). Used for Ctrl+F because the shared
/// `SourcesSearchField` does not take a FocusNode.
void focusFirstIn(FocusScopeNode scope) {
  for (final node in scope.traversalDescendants) {
    if (node.canRequestFocus) {
      node.requestFocus();
      return;
    }
  }
}
