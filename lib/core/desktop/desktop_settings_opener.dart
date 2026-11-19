import 'package:flutter/foundation.dart';

/// shell-1: lets screens inside the Windows shell open Settings through the
/// shell, so every entry point (Profile page button, Ctrl+,) opens the same
/// full-page Settings that covers the rail, and only one copy at a time.
abstract final class DesktopSettingsOpener {
  /// Set by the Windows shell while it is mounted (pushes the full-page
  /// Settings); null elsewhere, e.g. on phones or before the shell exists.
  static VoidCallback? handler;

  /// Opens Settings through the shell. Returns false when no shell handler is
  /// installed, so the caller can fall back to pushing a Settings route.
  static bool open() {
    final open = handler;
    if (open == null) return false;
    open();
    return true;
  }
}
