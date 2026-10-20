import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../platform/app_paths.dart';
import 'desktop_cloudflare.dart';
import '../provider/cf_clearance_store.dart';
import '../logging/app_logger.dart';

/// Small loopback FlareSolverr-compatible bridge for the desktop extension
/// engine. It replays a blocked request inside the verified WebView2 profile,
/// so sites which allow the browser without issuing `cf_clearance` still work.
class DesktopFlareSolverr {
  DesktopFlareSolverr._();

  static HttpServer? _server;
  static Future<Uri>? _starting;
  static Future<void> _queue = Future.value();
  static String? _key;
  static final Set<String> _verifiedHosts = {};

  /// Allows retries only for a host the user has manually verified.
  static void rememberVerifiedUrl(String url) {
    final host = Uri.tryParse(url)?.host;
    if (host != null && host.isNotEmpty) _verifiedHosts.add(host);
  }

  /// Revokes this host's in-memory replay permission after a source reset.
  static void forgetVerifiedUrl(String url) {
    _verifiedHosts.remove(Uri.tryParse(url)?.host);
  }

  /// Allows browser replay only after the user verified this exact host.
  static bool hasVerifiedUrl(String url) {
    final host = Uri.tryParse(url)?.host;
    return host != null &&
        (_verifiedHosts.contains(host) ||
            CfClearanceStore().browserVerifiedFor(host));
  }

  /// Reuses a manually verified browser profile for a normal GET/POST. This
  /// never opens or automatically solves a verification challenge, and the
  /// shared queue prevents multiple WebView2 instances racing over one profile.
  static Future<Map<String, dynamic>> requestVerified(
    Map<String, dynamic> body,
  ) async {
    if (!hasVerifiedUrl('${body['url']}')) {
      throw StateError('Visible verification is required');
    }
    final result = Completer<Map<String, dynamic>>();
    final previous = _queue;
    _queue = () async {
      try {
        await previous;
      } catch (_) {
        /* Retry remains usable after a failed site. */
      }
      try {
        final clock = Stopwatch()..start();
        final host = Uri.tryParse('${body['url']}')?.host ?? 'invalid';
        AppLogger.instance.log('[browser-replay] start $host');
        final response = await (browserRequestOverride ?? _solve)(body);
        AppLogger.instance.log(
          '[browser-replay] finished $host ${clock.elapsedMilliseconds}ms',
        );
        result.complete(response);
      } catch (error, stack) {
        // Record the failure category without exporting page bodies, cookies
        // or request URLs, so production verification failures are diagnosable.
        AppLogger.instance.log('[browser-replay] failed ${error.runtimeType}');
        result.completeError(error, stack);
      }
    }();
    return result.future;
  }

  @visibleForTesting
  static Future<Map<String, dynamic>> Function(Map<String, dynamic>)?
  browserRequestOverride;

  /// Resets server authorization between loopback protocol tests.
  @visibleForTesting
  static Future<void> close() async {
    await _server?.close(force: true);
    _server = null;
    _key = null;
    _verifiedHosts.clear();
    browserRequestOverride = null;
  }

  /// Returns the shared loopback endpoint including its per-process secret.
  static Future<Uri> ensureStarted() {
    final server = _server;
    if (server != null) {
      return Future.value(
        Uri.parse('http://${server.address.address}:${server.port}/$_key'),
      );
    }
    return _starting ??= _start().whenComplete(() => _starting = null);
  }

  /// Binds a random local port and authenticates requests with a random path.
  static Future<Uri> _start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final random = Random.secure();
    _key = base64UrlEncode(List.generate(32, (_) => random.nextInt(256)));
    _server = server;
    unawaited(server.forEach(_handle));
    return Uri.parse('http://${server.address.address}:${server.port}/$_key');
  }

  /// Implements the companion's FlareSolverr calls after checking the secret
  /// and manual-host authorization; failures return an error response.
  static Future<void> _handle(HttpRequest request) async {
    request.response.headers.contentType = ContentType.json;
    try {
      if (request.method != 'POST' ||
          request.uri.path != '/$_key/v1' ||
          request.headers.value('origin') != null) {
        request.response.statusCode = HttpStatus.notFound;
        request.response.write(jsonEncode({'status': 'error'}));
        await request.response.close();
        return;
      }
      final raw = await utf8.decoder.bind(request).join();
      final body = jsonDecode(raw) as Map<String, dynamic>;
      final command = '${body['cmd'] ?? ''}';
      if (command == 'sessions.create') {
        request.response.write(
          jsonEncode({'status': 'ok', 'session': 'webview'}),
        );
      } else if (command == 'sessions.destroy') {
        request.response.write(jsonEncode({'status': 'ok'}));
      } else if (command == 'request.get' || command == 'request.post') {
        request.response.write(jsonEncode(await requestVerified(body)));
      } else {
        request.response.statusCode = HttpStatus.badRequest;
        request.response.write(
          jsonEncode({'status': 'error', 'message': 'Unsupported command'}),
        );
      }
    } catch (error) {
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write(
        jsonEncode({'status': 'error', 'message': '$error'}),
      );
    }
    await request.response.close();
  }

  /// Replays GET navigation or a same-origin POST in the verified profile.
  /// Returns the actual response/cookies; blocked responses remain failures.
  static Future<Map<String, dynamic>> _solve(
    Map<String, dynamic> request,
  ) async {
    final target = Uri.parse('${request['url']}');
    if (target.scheme != 'http' && target.scheme != 'https') {
      throw const FormatException('Only HTTP requests are supported');
    }
    final method = '${request['cmd']}' == 'request.post' ? 'POST' : 'GET';
    final supplied = Map<String, dynamic>.from(
      request['headers'] as Map? ?? const {},
    );
    const forbidden = {
      'connection',
      'content-length',
      'cookie',
      'host',
      'origin',
      'referer',
      'user-agent',
    };
    final headers = <String, String>{
      for (final entry in supplied.entries)
        if (!forbidden.contains(entry.key.toLowerCase()))
          entry.key: '${entry.value}',
    };
    final done = Completer<Map<String, dynamic>>();
    var loading = false;
    int? navigationStatus;
    final environment = await WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(
        userDataFolder: (await writableAppSubdir('browser')).path,
      ),
    );
    late final HeadlessInAppWebView browser;
    browser = HeadlessInAppWebView(
      webViewEnvironment: environment,
      initialUrlRequest: URLRequest(
        url: WebUri(method == 'GET' ? target.toString() : '${target.origin}/'),
        headers: headers,
      ),
      initialSettings: InAppWebViewSettings(javaScriptEnabled: true),
      onLoadStart: (_, _) => navigationStatus = null,
      onLoadStop: (controller, _) async {
        if (done.isCompleted || loading) return;
        loading = true;
        try {
          final result = await controller.callAsyncJavaScript(
            functionBody: '''
              if (method === 'GET') {
                const title = document.title.toLowerCase();
                if (title.includes('just a moment') || title.includes('attention required') ||
                    document.querySelector('#challenge-running, #challenge-stage')) {
                  throw new Error('The website is still showing a verification challenge');
                }
                return {status: navigationStatus || 200, url: location.href,
                  headers: {'content-type': document.contentType},
                  body: document.contentType.includes('html') ? document.documentElement.outerHTML : document.body.innerText,
                  userAgent: navigator.userAgent};
              }
              const options = {method, headers, credentials: 'include'};
              if (body != null && method !== 'GET' && method !== 'HEAD') options.body = body;
              const response = await fetch(url, options);
              return {status: response.status, url: response.url,
                headers: Object.fromEntries(response.headers.entries()),
                body: await response.text(), userAgent: navigator.userAgent};
            ''',
            arguments: {
              'url': target.toString(),
              'method': method,
              'headers': headers,
              'body': request['postData'],
              'navigationStatus': navigationStatus,
            },
          );
          final value = result?.value;
          if (value is Map) {
            done.complete(Map<String, dynamic>.from(value));
          } else {
            throw StateError('The browser returned no response');
          }
        } catch (error, stack) {
          if (!done.isCompleted) done.completeError(error, stack);
        }
      },
      onReceivedError: (_, webRequest, error) {
        if (webRequest.isForMainFrame == true && !done.isCompleted) {
          done.completeError(StateError(error.description));
        }
      },
      onReceivedHttpError: (_, webRequest, response) {
        if (webRequest.isForMainFrame == true) {
          navigationStatus = response.statusCode;
        }
      },
    );
    try {
      await browser.run();
      final result = await done.future.timeout(const Duration(seconds: 18));
      final status = (result['status'] as num?)?.toInt() ?? 0;
      if (status == 403 || status == 429 || status == 503 || status == 0) {
        throw StateError(
          'The website still rejected the browser request ($status)',
        );
      }
      final manager = CookieManager.instance(webViewEnvironment: environment);
      final cookies = await manager.getCookies(url: WebUri(target.toString()));
      return {
        'status': 'ok',
        'message': 'Challenge solved',
        'solution': {
          'url': result['url'] ?? target.toString(),
          'status': result['status'] ?? 200,
          'headers': result['headers'] ?? const <String, String>{},
          'response': result['body'] ?? '',
          'userAgent': result['userAgent'] ?? '',
          'cookies': [
            for (final cookie in cookies)
              {
                'name': cookie.name,
                'value': cookie.value,
                'domain': cookie.domain,
                'path': cookie.path ?? '/',
                'expires': browserCookieExpiryMillis(cookie.expiresDate) == null
                    ? null
                    : browserCookieExpiryMillis(cookie.expiresDate)! ~/ 1000,
                'httpOnly': cookie.isHttpOnly,
                'secure': cookie.isSecure,
              },
          ],
        },
      };
    } finally {
      await browser.dispose();
      await environment.dispose();
    }
  }
}
