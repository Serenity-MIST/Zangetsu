import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../platform/app_paths.dart';
import '../ui/global_messenger.dart';
import '../provider/cf_clearance_store.dart';
import '../provider/cf_solve_needed.dart';
import 'desktop_flaresolverr.dart';

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
        await manager.deleteCookie(url: WebUri(url), name: cookie.name,
            domain: cookie.domain, path: cookie.path ?? '/');
      }
      return cookies.isNotEmpty;
    } finally {
      await environment.dispose();
    }
  }

  /// Opens manual verification and returns cookies, current URL and the exact
  /// browser user agent. Closing with Back returns null without importing data.
  static Future<Map<String, dynamic>?> solve(
    String url, {
    bool requireClearance = true,
  }) async {
    final nav = rootNavigatorKey.currentState;
    if (nav == null) throw StateError('The verification window is not ready');
    final directory = await writableAppSubdir('browser');
    final environment = await WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(userDataFolder: directory.path),
    );
    try {
      final session = await nav.push<Map<String, dynamic>>(
        MaterialPageRoute(
          builder: (_) => _Verification(
            url: url,
            environment: environment,
            requireClearance: requireClearance,
          ),
        ),
      );
      if (session != null && session['verified'] == true) {
        rememberVerifiedBrowserSession(url, session);
      }
      return session;
    } finally {
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
        uri.host.isEmpty)
      continue;
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
      text.contains('verify you are human')) {
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

  /// Reads original/redirected cookies while preventing concurrent checks.
  /// A loaded site can succeed without a clearance cookie; challenges cannot.
  Future<void> _complete({bool manual = false}) async {
    if (_checking || _controller == null || !mounted) return;
    setState(() => _checking = true);
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
        ({ready: document.readyState === 'complete',
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
      if (!mounted) {
        return;
      }

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
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text('Verify ${Uri.parse(widget.url).host}'),
      actions: [
        TextButton(
          onPressed: _checking ? null : () => _complete(manual: true),
          child: Text(_checking ? 'Checking…' : 'Continue'),
        ),
      ],
    ),
    body: Column(
      children: [
        if (_error != null)
          Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
        Expanded(
          child: InAppWebView(
            webViewEnvironment: widget.environment,
            initialUrlRequest: URLRequest(url: WebUri(widget.url)),
            initialSettings: InAppWebViewSettings(javaScriptEnabled: true),
            onWebViewCreated: (controller) => _controller = controller,
            onLoadStop: (_, _) {
              if (_error != null && mounted) setState(() => _error = null);
            },
          ),
        ),
      ],
    ),
  );
}
