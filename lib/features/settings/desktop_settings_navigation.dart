import 'package:flutter/foundation.dart';

/// Lets the Windows shell ask the settings workspace where it stands and
/// leave it (shell-1: Esc at the Settings root returns to the previous page
/// instead of reaching the app's exit logic).
///
/// Settings writes [atRoot]; the shell reads it and sets [onLeave]. Nothing
/// here runs off Windows: only the Windows settings workspace updates it.
abstract final class DesktopSettingsNavigation {
  /// True while the Windows settings workspace has nothing of its own to
  /// close: no page open above the section, no search text. Back / Esc then
  /// means "leave Settings". Also true when Settings is not shown at all.
  static final ValueNotifier<bool> atRoot = ValueNotifier<bool>(true);

  /// Set by the shell to leave Settings for the page shown before it. When
  /// null, Settings falls back to popping its route (the old behaviour).
  static VoidCallback? onLeave;

  /// Leaves Settings through [onLeave]. Returns false when no shell handler
  /// is installed, so the caller can fall back to a plain route pop.
  static bool leave() {
    final handler = onLeave;
    if (handler == null) return false;
    handler();
    return true;
  }
}
