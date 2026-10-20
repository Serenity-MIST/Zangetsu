import 'package:flutter/services.dart';

/// Windows helpers for returning normal-browser OAuth approvals to this app.
/// Provider services retain PKCE verifiers and validate the response state.
class DesktopOAuth {
  /// Registers the current executable as the per-user callback destination.
  /// Called only when starting a connection, including after moving the app.
  static Future<void> prepareBrowserCallback() => const MethodChannel(
    'com.spyou.zangetsu/window',
  ).invokeMethod<void>('registerOAuthProtocol');

  /// Matches only the configured callback destination, excluding lookalike hosts.
  static bool isCallback(Uri candidate, Uri redirect) =>
      candidate.scheme == redirect.scheme &&
      candidate.host == redirect.host &&
      candidate.port == redirect.port &&
      candidate.path == redirect.path;
}
