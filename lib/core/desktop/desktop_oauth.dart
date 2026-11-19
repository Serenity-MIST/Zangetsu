import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Windows helpers for returning normal-browser OAuth approvals to this app.
/// Provider services retain PKCE verifiers and validate the response state.
///
/// Windows path, end to end: the runner writes
/// `HKCU\Software\Classes\<scheme>\shell\open\command = "<exe>" "%1"` (at every
/// launch for `zangetsu`, and again here right before a sign-in). The browser
/// redirect starts a second `<exe> <uri>` process; its single-instance guard
/// (windows/runner/main.cpp) forwards the URI to the running window through
/// app_links' WM_COPYDATA, and each service's `uriLinkStream` listener
/// completes the login with its in-memory verifier/state.
class DesktopOAuth {
  /// Scheme shared by AniList, MyAnimeList, Simkl and MangaBaka redirects.
  static const String trackerScheme = 'zangetsu';

  /// Test hook: overrides the host check (tests run on Windows hosts while
  /// targeting Android, so the real check would be true there).
  @visibleForTesting
  static bool? debugIsWindowsHost;

  /// True only on a Windows host, where custom schemes live in the registry.
  static bool get usesRegisteredCallback =>
      debugIsWindowsHost ?? (!kIsWeb && Platform.isWindows);

  /// Registers the current executable as the per-user callback destination
  /// for [scheme]. Called only when starting a connection, including after
  /// moving the app.
  static Future<void> prepareBrowserCallback({String scheme = trackerScheme}) =>
      const MethodChannel(
        'com.spyou.zangetsu/window',
      ).invokeMethod<void>('registerOAuthProtocol', scheme);

  /// Windows-only preparation before opening a sign-in page. Returns null when
  /// the redirect can reach this app (or no preparation is needed), otherwise
  /// a short user-facing reason. Never throws.
  static Future<String?> ensureBrowserCallback({
    String scheme = trackerScheme,
  }) async {
    if (!usesRegisteredCallback) return null;
    try {
      await prepareBrowserCallback(scheme: scheme);
      return null;
    } on MissingPluginException {
      // Not hosted by our runner (unit tests on a Windows host): nothing to do.
      return null;
    } on PlatformException catch (e) {
      return e.message ??
          'Windows could not register the sign-in callback. Please retry.';
    }
  }

  /// Message for a sign-in whose browser approval never came back. On Windows
  /// the browser asks before opening an app, which is the usual missing step.
  static String noCallbackMessage(String provider) => usesRegisteredCallback
      ? 'No approval came back from the browser. After approving $provider, '
            'choose "Open Zangetsu" when the browser asks, then try again.'
      : 'No approval came back from the browser. Please try again.';

  /// Matches only the configured callback destination, excluding lookalike hosts.
  static bool isCallback(Uri candidate, Uri redirect) =>
      candidate.scheme == redirect.scheme &&
      candidate.host == redirect.host &&
      candidate.port == redirect.port &&
      candidate.path == redirect.path;
}
