import 'package:flutter/gestures.dart' show kBackMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/desktop/desktop_back_navigation.dart'
    show DesktopMouseBackOwner;
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../l10n/l10n.dart';

/// The player's top-left back arrow, drawn the same way as the controls
/// overlay's (white rounded arrow, "Back" tooltip). Used on the player's
/// loading and error states, where the overlay is not built.
class PlayerBackButton extends StatelessWidget {
  const PlayerBackButton({super.key, required this.onPressed});

  /// Leaves the player (or whatever the caller decides "back" means).
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    // Same top padding / inset as the overlay's top bar (32 + IconButton's
    // own 12px), so the arrow lands where the viewer expects it.
    return SafeArea(
      bottom: false,
      left: false,
      right: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 4),
        child: IconButton(
          key: const ValueKey('player-state-back'),
          icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
          tooltip: context.l10n.back,
          onPressed: onPressed,
        ),
      ),
    );
  }
}

/// Esc / browser-back key (and optionally the mouse back button) leave a
/// player state that has no controls overlay.
///
/// The Focus autofocuses only when nothing else in the route holds focus, so
/// it never steals keys from the player's own key node; when it does hold
/// focus, every key it does not use still bubbles up to that node.
class PlayerBackScope extends StatelessWidget {
  const PlayerBackScope({
    super.key,
    required this.onBack,
    required this.child,
    this.handleMouseBack = true,
    this.onEscape,
  });

  final VoidCallback onBack;
  final Widget child;

  /// What Esc / the browser-back key do; null uses [onBack]. The player
  /// passes "leave fullscreen first, then back", like its own Esc.
  final VoidCallback? onEscape;

  /// Off where an ancestor (DesktopPlayerInput) already maps the mouse back
  /// button to back: two handlers would pop twice and close the page below.
  final bool handleMouseBack;

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    // Act on the press only; repeats / releases are ignored.
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.browserBack) {
      (onEscape ?? onBack)();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    Widget body = Focus(
      autofocus: true,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: child,
    );
    if (handleMouseBack) {
      // Mouse button 4 ("back" thumb button) leaves too. The owner marker
      // makes the app-wide mouse Back handler (DesktopWindow) stand aside;
      // without it that handler popped the route a second time (and in the
      // mini player closed it instead of restoring the window).
      body = DesktopMouseBackOwner(
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (e) {
            if (e.buttons & kBackMouseButton != 0) onBack();
          },
          child: body,
        ),
      );
    }
    return body;
  }
}

/// The player's full error state: icon, headline (first line of [message]),
/// detail (the remaining lines) and "Try again".
///
/// With [onBack] set (Windows), a top-left back arrow is drawn and Esc /
/// the mouse back button leave too; without it the view is exactly the old
/// phone layout.
class PlayerErrorView extends StatelessWidget {
  const PlayerErrorView({
    super.key,
    required this.message,
    required this.onRetry,
    this.onBack,
    this.handleMouseBack = true,
    this.onEscape,
  });

  /// See [PlayerBackScope.onEscape].
  final VoidCallback? onEscape;

  /// Headline, optionally followed by '\n' and the detail lines.
  final String message;
  final VoidCallback onRetry;

  /// Null keeps the view without a back affordance (phone).
  final VoidCallback? onBack;

  /// See [PlayerBackScope.handleMouseBack].
  final bool handleMouseBack;

  @override
  Widget build(BuildContext context) {
    final content = Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline,
              size: 40,
              color: AppColors.textTertiary,
            ),
            const SizedBox(height: 12),
            // First line is the headline, the rest is what actually
            // happened. Kept as one string in the state and split here
            // so the controller stays free of presentation — and so a
            // message with no second line still renders fine.
            Text(
              message.split('\n').first,
              style: AppText.title.copyWith(fontSize: 17),
              textAlign: TextAlign.center,
            ),
            if (message.contains('\n')) ...[
              const SizedBox(height: 6),
              Text(
                message.split('\n').skip(1).join('\n'),
                style: AppText.body.copyWith(color: AppColors.textSecondary),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 16),
            TextButton(
              onPressed: onRetry,
              child: Text(
                'Try again',
                style: AppText.body.copyWith(color: AppColors.accent),
              ),
            ),
          ],
        ),
      ),
    );
    final back = onBack;
    if (back == null) return content;
    // Windows: the back arrow sits top-left over the centred message.
    return PlayerBackScope(
      onBack: back,
      handleMouseBack: handleMouseBack,
      onEscape: onEscape,
      child: Stack(
        fit: StackFit.expand,
        children: [
          content,
          Positioned(top: 0, left: 0, child: PlayerBackButton(onPressed: back)),
        ],
      ),
    );
  }
}
