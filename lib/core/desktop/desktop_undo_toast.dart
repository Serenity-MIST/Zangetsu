import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../ui/desktop_docked_panel.dart';
import '../../l10n/l10n.dart';

/// The toast currently on screen (Windows); only one is shown at a time.
_UndoToastHandle? _activeToast;

/// Shows the message with an Undo button after a reversible action (delete, remove...).
///
/// Windows: a floating graphite toast at the bottom centre with an Undo
/// button; Ctrl+Z also undoes while it is visible. A new toast replaces the
/// old one, which counts as expired (its [onExpired] fires). Elsewhere: a
/// SnackBar with an Undo action.
///
/// [onExpired] fires when the toast goes away without Undo, so callers can
/// commit a deferred delete at that point.
void showUndoToast(
  BuildContext context, {
  required String message,
  required VoidCallback onUndo,
  String? undoLabel,
  Duration duration = const Duration(seconds: 6),
  VoidCallback? onExpired,
}) {
  // Default button text follows the app language.
  final undoText = undoLabel ?? context.l10n.undo;
  if (!desktopPanelsEnabled) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) {
      // No messenger to show in: treat as expired so deferred work commits.
      onExpired?.call();
      return;
    }
    final controller = messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: duration,
        action: SnackBarAction(label: undoText, onPressed: onUndo),
      ),
    );
    unawaited(
      controller.closed.then((reason) {
        if (reason != SnackBarClosedReason.action) onExpired?.call();
      }),
    );
    return;
  }

  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) {
    onExpired?.call();
    return;
  }
  // Replace the previous toast; it did not get undone, so it expires.
  _activeToast?.finish(undo: false);
  _activeToast = _UndoToastHandle(
    overlay: overlay,
    message: message,
    undoLabel: undoText,
    duration: duration,
    onUndo: onUndo,
    onExpired: onExpired,
  );
}

/// Owns one toast's overlay entry, timer and Ctrl+Z handler.
class _UndoToastHandle {
  _UndoToastHandle({
    required OverlayState overlay,
    required String message,
    required String undoLabel,
    required Duration duration,
    required this.onUndo,
    required this.onExpired,
  }) {
    _entry = OverlayEntry(
      builder: (_) => _UndoToastView(
        message: message,
        undoLabel: undoLabel,
        onUndo: () => finish(undo: true),
        onClose: () => finish(undo: false),
      ),
    );
    overlay.insert(_entry);
    _timer = Timer(duration, () => finish(undo: false));
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  final VoidCallback onUndo;
  final VoidCallback? onExpired;
  late final OverlayEntry _entry;
  late final Timer _timer;
  bool _done = false;

  /// Ctrl+Z undoes while visible, except when a text field has focus (that
  /// Ctrl+Z belongs to the field's own text undo).
  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.keyZ ||
        !HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isShiftPressed) {
      return false;
    }
    final focus = FocusManager.instance.primaryFocus?.context;
    if (focus != null &&
        (focus.widget is EditableText ||
            focus.findAncestorWidgetOfExactType<EditableText>() != null)) {
      return false;
    }
    finish(undo: true);
    return true;
  }

  /// Removes the toast once, then runs Undo or the expiry callback.
  void finish({required bool undo}) {
    if (_done) return;
    _done = true;
    _timer.cancel();
    HardwareKeyboard.instance.removeHandler(_onKey);
    // Always remove: the entry was inserted in the constructor, and
    // `mounted` is still false when a toast is replaced before its first
    // frame, which would leave it in the overlay and make dispose assert.
    _entry.remove();
    _entry.dispose();
    if (identical(_activeToast, this)) _activeToast = null;
    if (undo) {
      onUndo();
    } else {
      onExpired?.call();
    }
  }
}

/// The graphite pill itself, sliding up from the bottom centre.
class _UndoToastView extends StatelessWidget {
  const _UndoToastView({
    required this.message,
    required this.undoLabel,
    required this.onUndo,
    required this.onClose,
  });

  final String message;
  final String undoLabel;
  final VoidCallback onUndo;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Positioned(
    left: 24,
    right: 24,
    bottom: 28,
    child: Center(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        builder: (context, t, child) => Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * 16),
            child: child,
          ),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Material(
            key: const ValueKey('desktop-undo-toast'),
            color: DesktopPanelColors.surface,
            elevation: 12,
            shadowColor: Colors.black,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: DesktopPanelColors.edge),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 6, 6, 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      message,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.body.copyWith(
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  TextButton(
                    onPressed: onUndo,
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.accent,
                      textStyle: AppText.body.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    child: Text(undoLabel),
                  ),
                  IconButton(
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    onPressed: onClose,
                    iconSize: 18,
                    color: AppColors.textSecondary,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
