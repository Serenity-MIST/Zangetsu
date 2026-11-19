import 'package:flutter/foundation.dart';

import 'desktop_native.dart';

/// The media-key actions a single physical key press can trigger.
enum DesktopMediaKeyAction { playPause, next, previous, stop }

/// Windows can deliver ONE media-key press twice: once as a Flutter key event
/// (the player has focus) and once through the system media overlay or
/// WM_APPCOMMAND ([DesktopNative.mediaCommands]). Both paths ask [claim]
/// first, and only the first one within [window] acts, so Play/Pause never
/// toggles twice (= nothing happens) for a single press.
abstract final class DesktopMediaKeyDedupe {
  /// How long a handled action blocks the same action from the other path.
  static const window = Duration(milliseconds: 300);

  // Last time (ms since epoch) each action was handled.
  static final Map<DesktopMediaKeyAction, int> _last = {};

  /// Clock used for the window; tests swap it for a fake.
  @visibleForTesting
  static int Function() clock = () => DateTime.now().millisecondsSinceEpoch;

  /// True when [action] may run now (and records it); false when the same
  /// action already ran within [window] from the other path.
  static bool claim(DesktopMediaKeyAction action) {
    final now = clock();
    final last = _last[action];
    if (last != null && now - last < window.inMilliseconds) return false;
    _last[action] = now;
    return true;
  }

  /// The de-duplication bucket for a native command; null for commands that
  /// never come from a key (seek).
  static DesktopMediaKeyAction? actionFor(DesktopMediaCommandKind kind) =>
      switch (kind) {
        // Play, pause and toggle all come from the same Play/Pause key.
        DesktopMediaCommandKind.play ||
        DesktopMediaCommandKind.pause ||
        DesktopMediaCommandKind.toggle => DesktopMediaKeyAction.playPause,
        DesktopMediaCommandKind.next => DesktopMediaKeyAction.next,
        DesktopMediaCommandKind.previous => DesktopMediaKeyAction.previous,
        DesktopMediaCommandKind.stop => DesktopMediaKeyAction.stop,
        DesktopMediaCommandKind.seek => null,
      };

  /// Forgets every recorded press (tests).
  @visibleForTesting
  static void debugReset() {
    _last.clear();
    clock = () => DateTime.now().millisecondsSinceEpoch;
  }
}
