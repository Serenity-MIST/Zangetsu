import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../platform/app_paths.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../ui/desktop_docked_panel.dart';
import '../ui/global_messenger.dart';
import '../provider/cf_clearance_store.dart';
import '../provider/cf_solve_needed.dart';
import 'desktop_flaresolverr.dart';
import '../../l10n/l10n.dart';

/// A visible, user-operated verification browser with its own app profile.
class DesktopCloudflare {
  /// Deletes only cookies belonging to the selected site's shared profile.
  /// Other sources' cookies, browser data and account settings are untouched.
  static Future<bool> clearSiteCookies(String url) async {
    final environment = await WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(
        userDataFolder: (await writableAppSubdir('browser')).path,
      ),
    );
    try {
      final manager = CookieManager.instance(webViewEnvironment: environment);
      final cookies = await manager.getCookies(url: WebUri(url));
      for (final cookie in cookies) {
        await manager.deleteCookie(
          url: WebUri(url),
          name: cookie.name,
          domain: cookie.domain,
          path: cookie.path ?? '/',
        );
      }
      return cookies.isNotEmpty;
    } finally {
      await environment.dispose();
    }
  }

  /// Verifications currently on screen, keyed by host. A second request for
  /// the same site (e.g. several Aniyomi/Mihon calls hitting one challenge)
  /// waits for the window already open instead of stacking another one.
  static final Map<String, Future<Map<String, dynamic>?>> _inFlight = {};

  /// Test hook replacing the real browser window, so the de-dupe logic can be
  /// exercised without WebView2.
  @visibleForTesting
  static Future<Map<String, dynamic>?> Function(
    String url,
    bool requireClearance,
  )?
  debugSolveOverride;

  /// Key for the in-flight map: the lower-case host, or the raw text when
  /// the URL has no host. A sign-in browser ([requireClearance] false) gets
  /// its own key: it waits for the user, while a verification closes by
  /// itself, so the two must not be merged into one window.
  @visibleForTesting
  static String inFlightKey(String url, {bool requireClearance = true}) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    final key = host.isEmpty ? url : host;
    return requireClearance ? key : 'sign-in:$key';
  }

  /// Opens manual verification and returns cookies, current URL and the exact
  /// browser user agent. Closing with Back returns null without importing data.
  /// Concurrent calls for the same host share one window and one result.
  static Future<Map<String, dynamic>?> solve(
    String url, {
    bool requireClearance = true,
  }) {
    final key = inFlightKey(url, requireClearance: requireClearance);
    final pending = _inFlight[key];
    if (pending != null) return pending;
    final future = _solveOnce(url, requireClearance);
    _inFlight[key] = future;
    // Forget the entry once settled so a later challenge opens a new window.
    // ignore() keeps this cleanup chain from reporting the error a 2nd time.
    future.whenComplete(() {
      if (identical(_inFlight[key], future)) _inFlight.remove(key);
    }).ignore();
    return future;
  }

  /// Shows one verification window (see [solve]).
  static Future<Map<String, dynamic>?> _solveOnce(
    String url,
    bool requireClearance,
  ) async {
    final override = debugSolveOverride;
    if (override != null) return override(url, requireClearance);
    final nav = rootNavigatorKey.currentState;
    if (nav == null) throw StateError('The verification window is not ready');
    final directory = await writableAppSubdir('browser');
    final environment = await WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(userDataFolder: directory.path),
    );
    try {
      Widget page(BuildContext _) => _Verification(
        url: url,
        environment: environment,
        requireClearance: requireClearance,
      );
      // Windows: a centred dialog-sized browser so the app stays visible
      // behind it. Other platforms keep the original full page route.
      // The navigator may have gone while the browser profile was created.
      final navContext = nav.context;
      if (!navContext.mounted) return null;
      final session = defaultTargetPlatform == TargetPlatform.windows
          ? await showDialog<Map<String, dynamic>>(
              context: navContext,
              useRootNavigator: true,
              barrierDismissible: false,
              barrierColor: Colors.black54,
              builder: page,
            )
          : await nav.push<Map<String, dynamic>>(
              MaterialPageRoute(builder: page),
            );
      if (session != null && session['verified'] == true) {
        rememberVerifiedBrowserSession(url, session);
      }
      return session;
    } finally {
      // The dialog's browser is still on screen during the close animation;
      // let the route finish leaving before the environment goes away.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await environment.dispose();
    }
  }
}

/// Shares one manually verified browser session with the source transports.
/// Original and redirected hosts retain the browser user agent and only cookies
/// belonging to their respective domains;
/// CloudStream must not depend on a separate Mihon JVM being started first.
void rememberVerifiedBrowserSession(
  String original,
  Map<String, dynamic> session,
) {
  if (session['verified'] != true) return;
  final cookie = session['cookie'] as String? ?? '';
  final ua = session['userAgent'] as String?;
  for (final address in {original, '${session['url'] ?? original}'}) {
    final uri = Uri.tryParse(address);
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty) {
      continue;
    }
    final rawCookies = session['cookies'];
    // Export cookies only to their matching domain after a redirected login.
    // Without structured cookies, legacy responses remain scoped to the
    // originally requested host instead of leaking them to another domain.
    final scopedCookie = rawCookies is List
        ? rawCookies
              .whereType<Map>()
              .where((entry) {
                final domain =
                    '${entry['domain'] ?? Uri.tryParse(original)?.host ?? ''}'
                        .replaceFirst(RegExp(r'^\.'), '');
                return uri.host == domain || uri.host.endsWith('.$domain');
              })
              .map((entry) => '${entry['name']}=${entry['value']}')
              .join('; ')
        : uri.host == Uri.tryParse(original)?.host
        ? cookie
        : '';
    CfClearanceStore().remember(
      uri.host,
      scopedCookie,
      ua,
      browserVerified: true,
    );
    DesktopFlareSolverr.rememberVerifiedUrl(address);
    CfSolveNeeded.clear(uri.host);
  }
}

/// WebView2's cookie API returns epoch seconds, while the engine expects
/// milliseconds. Accept either unit so a plugin update also remains valid.
int? browserCookieExpiryMillis(int? expiry) {
  if (expiry == null || expiry <= 0) return null; // Session cookie.
  return expiry < 100000000000 ? expiry * 1000 : expiry;
}

/// A solved challenge can open the requested site without setting a
/// cf_clearance cookie. Only the actual page state can tell us that happened.
bool verificationPageReady(Object? value) {
  if (value is! Map) return false;
  if (value['ready'] != true || value['body'] != true) return false;
  final title = '${value['title'] ?? ''}'.toLowerCase();
  final text = '${value['text'] ?? ''}'.toLowerCase();
  final host = '${value['host'] ?? ''}'.toLowerCase();
  if (host.isEmpty || title.isEmpty) return false;
  const blockers = [
    'just a moment',
    'attention required',
    'checking your browser',
    'verify you are human',
    // Newer Cloudflare interstitial wording.
    'verifying you are human',
    'performing security verification',
    'security verification',
    'access denied',
    'website verification',
    'site can’t be reached',
    "site can't be reached",
    'site cannot be reached',
  ];
  if (blockers.any(title.contains)) {
    return false;
  }
  if (text.contains('checking if the site connection is secure') ||
      text.contains('verify you are human') ||
      // Newer Cloudflare interstitial body text.
      text.contains('verifying you are human') ||
      text.contains('performing security verification') ||
      text.contains('needs to review the security of your connection')) {
    return false;
  }
  return true;
}

/// Visible browser route for completing a site's verification or sign-in.
class _Verification extends StatefulWidget {
  const _Verification({
    required this.url,
    required this.environment,
    required this.requireClearance,
  });
  final String url;
  final WebViewEnvironment environment;
  final bool requireClearance;
  @override
  State<_Verification> createState() => _VerificationState();
}

/// Checks the document before exporting the browser session on Continue.
class _VerificationState extends State<_Verification> {
  InAppWebViewController? _controller;
  String? _error;
  bool _checking = false;

  /// Set once this window has returned its session, so the auto timer or a
  /// late onLoadStop cannot pop a second route during the close animation.
  bool _done = false;

  /// True only while a check the user asked for (Continue) runs, so the
  /// silent automatic checks never flicker the button label.
  bool _manualCheck = false;

  /// True between a page load starting and finishing (drives the status).
  bool _loading = true;

  /// Re-checks the page every few seconds: some challenges finish through
  /// script without a new page load, so onLoadStop alone can miss them.
  Timer? _autoTimer;

  /// Only a verification closes by itself. A sign-in page (no clearance
  /// required) waits for the user, who may still need to log in.
  /// Windows only, so any other platform keeps the manual Continue flow.
  bool get _autoComplete =>
      widget.requireClearance &&
      defaultTargetPlatform == TargetPlatform.windows;

  @override
  void initState() {
    super.initState();
    if (_autoComplete) {
      // Also checks while the page still loads: ad-heavy sites (natomanga)
      // can keep loading sub-resources for a long time after the document is
      // usable, so waiting for onLoadStop kept the window open. The check
      // itself only passes once the document is parsed and no challenge
      // wording is left (see verificationPageReady).
      _autoTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        _complete();
      });
    }
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    super.dispose();
  }

  /// Reads original/redirected cookies while preventing concurrent checks.
  /// A loaded site can succeed without a clearance cookie; challenges cannot.
  /// [manual] is false for the automatic checks after each page load.
  Future<void> _complete({bool manual = false}) async {
    if (_done || _checking || _controller == null || !mounted) return;
    setState(() {
      _checking = true;
      _manualCheck = manual;
    });
    try {
      final currentUrl =
          (await _controller!.getUrl().timeout(
            const Duration(seconds: 5),
          ))?.toString() ??
          widget.url;
      final manager = CookieManager.instance(
        webViewEnvironment: widget.environment,
      );
      final cookies = await manager
          .getCookies(url: WebUri(currentUrl))
          .timeout(const Duration(seconds: 5));
      if (currentUrl != widget.url) {
        final original = await manager
            .getCookies(url: WebUri(widget.url))
            .timeout(const Duration(seconds: 5));
        for (final cookie in original) {
          if (!cookies.any(
            (existing) =>
                existing.name == cookie.name &&
                existing.domain == cookie.domain,
          )) {
            cookies.add(cookie);
          }
        }
      }
      final pageState = await _controller!
          .evaluateJavascript(
            source: '''
        ({ready: document.readyState !== 'loading',
          body: !!document.body && document.body.innerText.trim().length > 80,
          title: document.title, host: location.hostname,
          text: document.body?.innerText.slice(0, 1000) || ''})
      ''',
          )
          .timeout(const Duration(seconds: 5));
      // A stale clearance cookie can remain while the site is challenging.
      // Confirm the loaded document, rather than accepting the cookie alone.
      if (widget.requireClearance && !verificationPageReady(pageState)) {
        if (manual && mounted) {
          setState(
            () => _error =
                'Wait for the website to finish loading, then continue.',
          );
        }
        return;
      }
      final ua = await _controller!
          .evaluateJavascript(source: 'navigator.userAgent')
          .timeout(const Duration(seconds: 5));
      if (!mounted || _done) {
        return;
      }
      // An automatic check must only close this window while it is the top
      // route; otherwise the pop would close whatever sits above it.
      if (!manual && ModalRoute.of(context)?.isCurrent == false) return;
      // Close exactly once: stop the timer before the close animation, during
      // which this state is still mounted and could otherwise pop again.
      _done = true;
      _autoTimer?.cancel();

      Navigator.of(context).pop(<String, dynamic>{
        'verified': verificationPageReady(pageState),
        'url': currentUrl,
        'userAgent': '$ua',
        'cookie': cookies
            .map((cookie) => '${cookie.name}=${cookie.value}')
            .join('; '),
        'cookies': [
          for (final cookie in cookies)
            {
              'name': cookie.name,
              'value': cookie.value,
              'domain': cookie.domain,
              'path': cookie.path,
              'secure': cookie.isSecure,
              'httpOnly': cookie.isHttpOnly,
              'expires': browserCookieExpiryMillis(cookie.expiresDate),
            },
        ],
      });
    } catch (error) {
      if (manual && mounted) {
        setState(
          () => _error = 'Could not read the verification session: $error',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _checking = false;
          _manualCheck = false;
        });
      }
    }
  }

  /// The embedded browser, shared by the phone page and the Windows dialog.
  Widget _browser() => InAppWebView(
    webViewEnvironment: widget.environment,
    initialUrlRequest: URLRequest(url: WebUri(widget.url)),
    initialSettings: InAppWebViewSettings(javaScriptEnabled: true),
    onWebViewCreated: (controller) => _controller = controller,
    onLoadStart: (_, _) {
      if (mounted) setState(() => _loading = true);
    },
    onLoadStop: (_, _) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = null;
      });
      // Close by itself once the site is reachable; Continue stays as the
      // fallback. A short pause lets challenge redirects start first.
      if (_autoComplete) {
        Future<void>.delayed(const Duration(milliseconds: 600), () {
          if (mounted && !_loading) _complete();
        });
      }
    },
  );

  /// Short status shown under the Windows dialog title.
  String get _status {
    final l10n = context.l10n;
    if (_checking && _manualCheck) return l10n.verifyCheckingWebsite;
    if (_loading) return l10n.verifyLoadingWebsite;
    return _autoComplete
        ? l10n.verifyCompleteCheckBelow
        : l10n.verifySignInBelow;
  }

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform == TargetPlatform.windows) {
      return _desktopDialog(context);
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.verifyHost(Uri.parse(widget.url).host)),
        actions: [
          TextButton(
            onPressed: _checking ? null : () => _complete(manual: true),
            child: Text(
              _checking
                  ? context.l10n.checkingEllipsis
                  : context.l10n.continueLabel,
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_error != null)
            Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
          Expanded(child: _browser()),
        ],
      ),
    );
  }

  /// Windows: a centred graphite window (not a full page) with Reload,
  /// Continue, close and a status line. Esc cancels like the close button.
  Widget _desktopDialog(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final host = Uri.tryParse(widget.url)?.host ?? widget.url;
    return Dialog(
      key: const ValueKey('desktop-verification-dialog'),
      backgroundColor: DesktopPanelColors.surface,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: DesktopPanelColors.edge),
      ),
      clipBehavior: Clip.antiAlias,
      child: DesktopEscCloses(
        child: SizedBox(
          // Large enough for a challenge or sign-in form, never full screen.
          width: (size.width * .9).clamp(320.0, 1000.0),
          height: (size.height * .85).clamp(320.0, 760.0),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              context.l10n.verifyHost(host),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.headline.copyWith(
                                fontSize: 20,
                                color: AppColors.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _error ?? _status,
                              key: const ValueKey('verification-status'),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.caption.copyWith(
                                color: _error != null
                                    ? AppColors.accent
                                    : AppColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: context.l10n.reload,
                        onPressed: _controller == null
                            ? null
                            : () => _controller!.reload(),
                        icon: const Icon(Icons.refresh_rounded),
                        color: AppColors.textSecondary,
                      ),
                      const SizedBox(width: 4),
                      FilledButton(
                        onPressed: _checking && _manualCheck
                            ? null
                            : () => _complete(manual: true),
                        child: Text(
                          _checking && _manualCheck
                              ? context.l10n.checkingEllipsis
                              : context.l10n.continueLabel,
                        ),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        tooltip: MaterialLocalizations.of(
                          context,
                        ).closeButtonTooltip,
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const Icon(Icons.close_rounded),
                        color: AppColors.textSecondary,
                      ),
                    ],
                  ),
                ),
                // Thin progress bar while a page loads.
                SizedBox(
                  height: 2,
                  child: _loading
                      ? LinearProgressIndicator(
                          minHeight: 2,
                          color: AppColors.accent,
                          backgroundColor: DesktopPanelColors.edge,
                        )
                      : ColoredBox(color: DesktopPanelColors.edge),
                ),
                Expanded(child: _browser()),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
