import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/direct_file_connections.dart';

/// Exercises capability decisions without fetching external media.
class _Host implements HttpClientAdapter {
  String? limitedMethod;
  bool headFails = false;
  bool ranges = true;
  bool ignoresRange = false;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(RequestOptions options, _, _) async {
    requests.add(options);
    if (options.method == limitedMethod) {
      return ResponseBody.fromString('<html>private error</html>', 429,
          headers: {'retry-after': ['60']});
    }
    if (options.method == 'HEAD') {
      return ResponseBody.fromString(
        '',
        headFails ? 405 : 200,
        headers: {
          'content-length': ['8000'],
          if (ranges) 'accept-ranges': ['bytes'],
        },
      );
    }
    return ResponseBody.fromBytes(
      [1],
      ignoresRange ? 200 : 206,
      headers: {
        'content-length': ['1'],
        'content-range': ['bytes 0-0/8000'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test(
    'range host gets requested connections with original auth headers',
    () async {
      final host = _Host();
      final client = Dio()..httpClientAdapter = host;
      expect(
        await directFileConnections(client, 'https://fixture.test/video', {
          'Referer': 'https://fixture.test/',
        }, 8),
        8,
      );
      expect(host.requests, hasLength(2));
      expect(host.requests.last.headers['Referer'], 'https://fixture.test/');
      expect(host.requests.last.headers['Range'], 'bytes=0-0');
    },
  );
  test('unsupported HEAD and non-range hosts retain single stream', () async {
    for (final host in [
      _Host()..headFails = true,
      _Host()..ranges = false,
      _Host()..ignoresRange = true,
    ]) {
      expect(
        await directFileConnections(
          Dio()..httpClientAdapter = host,
          'https://fixture.test/video',
          {},
          8,
        ),
        1,
      );
    }
  });
  for (final method in ['HEAD', 'GET']) {
    test('${method}429 stops capability probing and preserves server deadline', () async {
      final host = _Host()..limitedMethod = method;
      final client = Dio()..httpClientAdapter = host;
      final hints = <(Uri, String?)>[];
      expect(await directFileConnections(client, 'https://fixture.test/video', {}, 8,
          onRateLimited: (uri, hint) async { hints.add((uri, hint)); }), 0);
      expect(host.requests, hasLength(method == 'HEAD' ? 1 : 2));
      expect(hints.single.$1.host, 'fixture.test');
      expect(hints.single.$2, '60');
      client.close(force: true);
    });
  }
  test('no-policy429 retains legacy single-stream fallback', () async {
    final host = _Host()..limitedMethod = 'HEAD';
    final client = Dio()..httpClientAdapter = host;
    expect(await directFileConnections(client, 'https://fixture.test/video', {}, 8), 1);
    client.close(force: true);
  });
  test('one connection or provider Range skips capability requests', () async {
    final host = _Host();
    final client = Dio()..httpClientAdapter = host;
    expect(
      await directFileConnections(client, 'https://fixture.test/video', {}, 1),
      1,
    );
    expect(
      await directFileConnections(client, 'https://fixture.test/video', {
        'range': 'bytes=2-',
      }, 8),
      1,
    );
    expect(host.requests, isEmpty);
  });
}
