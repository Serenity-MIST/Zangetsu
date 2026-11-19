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
  static String? _key;

  /// Replays allowed to run at once. The engine gives each replay only 15s
  /// to answer, and a source home asks for popular and latest together, so a
  /// strictly one-at-a-time queue made the second request time out while it
  /// waited. A few headless views sharing one profile is safe in WebView2.
  static const int _maxParallelReplays = 3;
  static int _activeReplays = 0;
  static final List<Completer<void>> _replayWaiters = [];

  /// Upper bound for one browser replay. Kept under the engine's 15s read
  /// limit so a slow page fails here (and is logged) instead of the engine
  /// giving up first with a bare "Read timed out".
  @visibleForTesting
  static const Duration replayTimeout = Duration(seconds: 13);

  /// One WebView2 environment (browser process) shared by all replays, so
  /// each request does not pay for starting a new one. Cleared on failure.
  static Future<WebViewEnvironment>? _environment;
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
    // Wait for a free slot (see [_maxParallelReplays]).
    while (_activeReplays >= _maxParallelReplays) {
      final waiter = Completer<void>();
      _replayWaiters.add(waiter);
      await waiter.future;
    }
    _activeReplays++;
    final clock = Stopwatch()..start();
    final host = Uri.tryParse('${body['url']}')?.host ?? 'invalid';
    try {
      AppLogger.instance.log('[browser-replay] start $host');
      final response = await (browserRequestOverride ?? _solve)(body);
      AppLogger.instance.log(
        '[browser-replay] finished $host ${clock.elapsedMilliseconds}ms',
      );
      return response;
    } catch (error) {
      // Record the failure category and host without exporting page bodies,
      // cookies or full request URLs, so production failures are diagnosable.
      AppLogger.instance.log(
        '[browser-replay] failed $host ${error.runtimeType} '
        '${clock.elapsedMilliseconds}ms: ${_short(error)}',
      );
      rethrow;
    } finally {
      // Free the slot; the next waiter (if any) re-checks the count.
      _activeReplays--;
      if (_replayWaiters.isNotEmpty) _replayWaiters.removeAt(0).complete();
    }
  }

  /// First line of an error, capped, for the replay log.
  static String _short(Object error) {
    final text = '$error'.split('\n').first;
    return text.length > 160 ? '${text.substring(0, 160)}…' : text;
  }

  /// The shared replay environment, created on first use. A failed creation
  /// is forgotten so the next replay tries again.
  static Future<WebViewEnvironment> _sharedEnvironment() {
    return _environment ??= () async {
      try {
        return await WebViewEnvironment.create(
          settings: WebViewEnvironmentSettings(
            userDataFolder: (await writableAppSubdir('browser')).path,
          ),
        );
      } catch (_) {
        _environment = null;
        rethrow;
      }
    }();
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
    // True while one capture attempt runs, so the poll and onLoadStop never
    // overlap.
    var capturing = false;
    // Set when the last look at the page still showed a challenge, for a
    // clearer timeout message.
    var sawChallenge = false;
    int? navigationStatus;
    // Shared browser process instead of a new environment per request.
    final environment = await _sharedEnvironment();

    // Reads the page as soon as its document is parsed (readyState is no
    // longer "loading") instead of waiting for onLoadStop: ad-heavy sites
    // such as natomanga kept loading sub-resources past the engine's 15s
    // limit. A challenge page is not an error yet: it may pass by itself and
    // redirect, so this keeps waiting until [replayTimeout].
    Future<void> capture(InAppWebViewController controller) async {
      if (done.isCompleted || capturing) return;
      capturing = true;
      try {
        final result = await controller.callAsyncJavaScript(
          functionBody: '''
            if (document.readyState === 'loading' ||
                (location.protocol !== 'http:' && location.protocol !== 'https:')) {
              return {pending: true};
            }
            const title = (document.title || '').toLowerCase();
            if (title.includes('just a moment') || title.includes('attention required') ||
                title.includes('security verification') || window._cf_chl_opt ||
                document.querySelector('#challenge-running, #challenge-stage, #challenge-form, #cf-challenge-running')) {
              return {challenge: true};
            }
            if (method === 'GET') {
              return {status: navigationStatus || 200, url: location.href,
                headers: {'content-type': document.contentType},
                body: document.contentType.includes('html') ? document.documentElement.outerHTML : (document.body ? document.body.innerText : ''),
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
        // Nothing usable yet (e.g. a navigation swapped the document).
        if (value is! Map) return;
        if (value['pending'] == true) return;
        if (value['challenge'] == true) {
          sawChallenge = true;
          return;
        }
        if (!done.isCompleted) done.complete(Map<String, dynamic>.from(value));
      } catch (error, stack) {
        // A script error mid-navigation is retried by the poll; a failed
        // fetch for a POST is final.
        if (method != 'GET' && !done.isCompleted) {
          done.completeError(error, stack);
        }
      } finally {
        capturing = false;
      }
    }

    late final HeadlessInAppWebView browser;
    browser = HeadlessInAppWebView(
      webViewEnvironment: environment,
      initialUrlRequest: URLRequest(
        url: WebUri(method == 'GET' ? target.toString() : '${target.origin}/'),
        headers: headers,
      ),
      initialSettings: InAppWebViewSettings(javaScriptEnabled: true),
      onLoadStart: (_, _) => navigationStatus = null,
      onLoadStop: (controller, _) => capture(controller),
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
    Timer? poll;
    try {
      try {
        await browser.run();
      } catch (_) {
        // The shared browser process may have died: start a fresh one for
        // the next replay.
        _environment = null;
        rethrow;
      }
      // Poll the document so a parsed page is captured before every ad and
      // image on it has finished loading.
      poll = Timer.periodic(const Duration(milliseconds: 400), (_) {
        final controller = browser.webViewController;
        if (controller != null) capture(controller);
      });
      final Map<String, dynamic> result;
      try {
        result = await done.future.timeout(replayTimeout);
      } on TimeoutException {
        throw StateError(
          sawChallenge
              ? 'The website is still showing a verification challenge'
              : 'The website did not load in time',
        );
      }
      final status = (result['status'] as num?)?.toInt() ?? 0;
      if (status == 403 || status == 429 || status == 503 || status == 0) {
        throw StateError(
          'The website still rejected the browser request ($status)',
        );
      }
      final manager = CookieManager.instance(webViewEnvironment: environment);
      final cookies = await manager
          .getCookies(url: WebUri(target.toString()))
          .timeout(const Duration(seconds: 3), onTimeout: () => <Cookie>[]);
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
      poll?.cancel();
      // Only the headless view goes; the shared environment stays for the
      // next replay.
      await browser.dispose();
    }
  }
}
