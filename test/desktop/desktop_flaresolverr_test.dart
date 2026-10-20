import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/desktop_flaresolverr.dart';

void main() {
  late HttpClient client;
  late Uri endpoint;
  setUp(() async {
    client = HttpClient();
    final base = await DesktopFlareSolverr.ensureStarted();
    endpoint = Uri.parse('$base/v1');
  });
  tearDown(() async {
    client.close(force: true);
    await DesktopFlareSolverr.close();
  });

  Future<({int status, Map response})> post(Map body, {Uri? url}) async {
    final request = await client.postUrl(url ?? endpoint);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
    final response = await request.close();
    final data = jsonDecode(await utf8.decoder.bind(response).join()) as Map;
    return (status: response.statusCode, response: data);
  }

  test('engine session uses a secret loopback endpoint', () async {
    final created = await post({'cmd': 'sessions.create'});
    expect(created.status, 200);
    expect(created.response['session'], 'webview');
    final denied = await post({
      'cmd': 'sessions.create',
    }, url: endpoint.replace(path: '/v1'));
    expect(denied.status, 404);
  });

  test('unverified sites cannot invoke the browser', () async {
    var called = false;
    DesktopFlareSolverr.browserRequestOverride = (_) async {
      called = true;
      return {'status': 'ok'};
    };
    final result = await post({
      'cmd': 'request.get',
      'url': 'https://www.natomanga.com/search/story/solo_leveling',
    });
    expect(result.status, 500);
    expect(called, isFalse);
  });

  test(
    'verified request reaches the browser and returns its real body',
    () async {
      DesktopFlareSolverr.rememberVerifiedUrl('https://www.natomanga.com/');
      DesktopFlareSolverr.browserRequestOverride = (request) async {
        expect(request['cmd'], 'request.get');
        expect(request['url'], 'https://www.natomanga.com/manga/solo_leveling');
        return {
          'status': 'ok',
          'solution': {'status': 200, 'response': '<h1>Solo Leveling</h1>'},
        };
      };
      final result = await post({
        'cmd': 'request.get',
        'url': 'https://www.natomanga.com/manga/solo_leveling',
      });
      expect(result.status, 200);
      expect(result.response['solution']['response'], '<h1>Solo Leveling</h1>');
    },
  );

  test('a failed browser request does not break the next retry', () async {
    DesktopFlareSolverr.rememberVerifiedUrl('https://www.natomanga.com/');
    var calls = 0;
    DesktopFlareSolverr.browserRequestOverride = (_) async {
      if (calls++ == 0) throw StateError('Browser request rejected');
      return {
        'status': 'ok',
        'solution': {'status': 200},
      };
    };
    final body = {'cmd': 'request.get', 'url': 'https://www.natomanga.com/'};
    expect((await post(body)).status, 500);
    expect((await post(body)).status, 200);
  });
}
