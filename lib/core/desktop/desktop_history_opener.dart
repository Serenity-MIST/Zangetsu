import 'package:flutter/foundation.dart';

/// Lets screens inside the Windows shell (the Profile page) open the shell's
/// in-frame History page. History left the Windows sidebar, so this, the
/// Profile page button and Ctrl+H are how it is reached on Windows.
abstract final class DesktopHistoryOpener {
  /// Set by the Windows shell while it is mounted (opens its 'history'
  /// page); null elsewhere, e.g. on phones or before the shell exists.
  static VoidCallback? handler;

  /// Opens the in-frame History. Returns false when no shell handler is
  /// installed, so the caller can fall back to pushing a History route.
  static bool open() {
    final open = handler;
    if (open == null) return false;
    open();
    return true;
  }
}
