import 'dart:async';
import 'dart:convert';
import 'package:cs3_engine/cs3_engine.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../platform/app_paths.dart';
import 'cloudstream_catalog.dart';

/// Supplies the browser callbacks used by CloudStream WebViewResolver and
/// browser-only HTTP requests. Verification remains a visible user action.
Future<void> cloudStreamBrowserRequest(
  Cs3Engine engine,
  Map<String, dynamic> event,
) async {
  final rid = (event['rid'] as num).toInt();
  final uri = CloudStreamCatalog.httpUri(event['url'] as String);
  final fetch = event['op'] == 'fetch';
  final finished = Completer<void>();
  final headers = <String, String>{
    for (final entry in (event['headers'] as Map? ?? {}).entries)
      '${entry.key}': '${entry.value}',
  };
  final environment = await WebViewEnvironment.create(
    settings: WebViewEnvironmentSettings(
      userDataFolder: (await writableAppSubdir('browser')).path,
    ),
  );
  Map<String, Object?> answer = {};
  var loaded = false;

  /// Completes only once when capture, navigation or an error ends the request.
  void finish() {
    if (!finished.isCompleted) finished.complete();
  }

  final browser = HeadlessInAppWebView(
    webViewEnvironment: environment,
    initialUrlRequest: URLRequest(
      url: WebUri(fetch ? '${uri.origin}/' : uri.toString()),
      headers: headers,
    ),
    initialSettings: InAppWebViewSettings(
      javaScriptEnabled: true,
      useShouldInterceptRequest: !fetch,
      mediaPlaybackRequiresUserGesture: false,
      userAgent: headers['User-Agent'],
    ),
    shouldInterceptRequest: (_, request) async {
      if (!finished.isCompleted) {
        try {
          if (await engine.webCaptured(
            rid,
            request.url.toString(),
            method: request.method,
          ))
            finish();
        } catch (_) {
          finish();
        }
      }
      return null;
    },
    onLoadStop: (controller, _) async {
      if (loaded || finished.isCompleted) return;
      loaded = true;
      try {
        if (fetch) {
          final result = await controller.callAsyncJavaScript(
            functionBody: '''
            const options = {method, headers, credentials: 'include'};
            if (body != null && method !== 'GET' && method !== 'HEAD') options.body = body;
            const response = await fetch(url, options);
            return {status: response.status, url: response.url,
              headers: Object.fromEntries(response.headers.entries()), body: await response.text()};
          ''',
            arguments: {
              'url': uri.toString(),
              'method': event['method'] ?? 'GET',
              'headers': headers,
              'body': event['body'],
            },
          );
          if (result?.value is Map)
            answer = Map<String, Object?>.from(result!.value as Map);
          finish();
        } else if (event['script'] is String &&
            (event['script'] as String).isNotEmpty) {
          final result = await controller.evaluateJavascript(
            source: event['script'] as String,
          );
          await engine.webScript(rid, jsonEncode(result));
        }
      } catch (_) {
        finish();
      }
    },
    onReceivedError: (_, request, error) {
      if (request.isForMainFrame == true) finish();
    },
  );
  try {
    await browser.run();
    final timeout = ((event['timeoutMs'] as num?)?.toInt() ?? 25000).clamp(
      1000,
      45000,
    );
    await finished.future.timeout(
      Duration(milliseconds: timeout),
      onTimeout: () {},
    );
  } finally {
    await browser.dispose();
    await environment.dispose();
    await engine.webAnswer(rid, answer);
  }
}
