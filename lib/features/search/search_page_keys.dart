import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/desktop/desktop_focus_repair.dart';
import '../../core/desktop/desktop_shortcuts.dart';

/// Windows-only keyboard handling shared by the pages that carry their own
/// in-page search (See all, a single source's catalogue).
///
/// * The `app.search` shortcut (Ctrl+F by default) opens THIS page's search
///   instead of jumping to the shell's global search box (shell-7).
/// * Esc first gives the page a chance to close its own search ([onEscape]
///   returns true when it consumed the key); only then does the app-wide Esc
///   go back (search-1 Option A).
///
/// Off Windows the child is returned untouched, so phone/TV keep today's
/// behaviour exactly.
class SearchPageKeys extends StatelessWidget {
  const SearchPageKeys({
    super.key,
    required this.child,
    this.onSearch,
    this.onEscape,
  });

  final Widget child;

  /// Opens / focuses the page's own search. Null = page has no search, the
  /// shortcut then falls through to the shell.
  final VoidCallback? onSearch;

  /// Called for Esc that nothing deeper handled. Return true to consume it.
  final bool Function()? onEscape;

  /// True while a text field (or anything editable) owns the keyboard.
  static bool _typing() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    return ctx.widget is EditableText ||
        ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final search = onSearch;
    if (search != null && DesktopShortcuts.matches('app.search', event)) {
      // A bare key like '/' must stay typeable inside the search field, so
      // only modifier shortcuts (Ctrl+F) fire while typing.
      final keyboard = HardwareKeyboard.instance;
      final modified = keyboard.isControlPressed || keyboard.isAltPressed;
      if (_typing() && !modified) return KeyEventResult.ignored;
      search();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape && event is KeyDownEvent) {
      final handler = onEscape;
      if (handler != null && handler()) return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.windows) return child;
    // Autofocus so a freshly pushed page receives keys even before the user
    // clicks anything; skipTraversal keeps Tab order unchanged. R1: the
    // node is registered with the focus repair, so a lost focus comes back.
    return DesktopRepairFocus(
      autofocus: true,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: child,
    );
  }
}

/// Windows-only Esc handling for an in-page search field (search-1 Option A):
/// the first Esc clears the typed text, the next one closes the in-page
/// search via [onClose]. Wraps the field so it runs before the app-wide Esc
/// (which would otherwise pop the whole page). Pass-through off Windows.
class SearchFieldEscape extends StatelessWidget {
  const SearchFieldEscape({
    super.key,
    required this.controller,
    required this.onClose,
    required this.child,
  });

  final TextEditingController controller;
  final VoidCallback onClose;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.windows) return child;
    return Focus(
      // Only listens; the TextField keeps its own focus node.
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent ||
            event.logicalKey != LogicalKeyboardKey.escape) {
          return KeyEventResult.ignored;
        }
        if (controller.text.isNotEmpty) {
          controller.clear();
        } else {
          onClose();
        }
        return KeyEventResult.handled;
      },
      child: child,
    );
  }
}
