import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/download_size_estimate.dart';
import 'package:watch_app/core/models/video_source.dart';

const master = '#EXTM3U\n'
    '#EXT-X-STREAM-INF:BANDWIDTH=8000000,RESOLUTION=1920x1080\nhigh.m3u8\n'
    '#EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1280x720\nlow.m3u8\n';

void main() {
  test('HLS arithmetic follows nearest selected quality, not always fastest', () {
    final high = estimateDownloadPlaylist(master, 'https://fixture/master.m3u8', quality: 'best', runtimeMinutes: 20);
    final low = estimateDownloadPlaylist(master, 'https://fixture/master.m3u8', quality: '800p', runtimeMinutes: 20);
    expect(high, (bytes: 1200000000, solid: true));
    expect(low, (bytes: 600000000, solid: true));
    expect(estimateDownloadPlaylist(master, 'https://fixture/master.m3u8', quality: '720p'), isNull);
  });
  test('VOD assumed bitrate is low-confidence; live/html/malformed stay unknown', () {
    const vod = '#EXTM3U\n#EXTINF:10.5,\na.ts\n#EXT-X-ENDLIST';
    expect(estimateDownloadPlaylist(vod, 'https://fixture/a', quality: '720p'),
      (bytes: 5250000, solid: false));
    for (final body in ['<html>429</html>', vod.replaceAll('#EXT-X-ENDLIST', ''),
      vod.replaceAll('10.5', 'NaN'), '#EXTM3U\n#EXT-X-ENDLIST']) {
      expect(estimateDownloadPlaylist(body, 'https://fixture/a', quality: '720p'), isNull);
    }
    expect(estimateDownloadPlaylist(vod, 'https://fixture/a', quality: 'auto'), isNull);
    expect(estimateDownloadPlaylist(master, 'https://fixture/a', quality: 'best', runtimeMinutes: 1 << 60), isNull);
  });

  late HttpServer server;
  late Uri base;
  late List<HttpRequest> requests;
  late Map<String, DateTime> cooldowns;
  late List<(Uri, String?)> limits;
  late DownloadSizeEstimator estimator;
  Future<void> Function(HttpRequest)? handler;
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://127.0.0.1:${server.port}');
    requests = []; cooldowns = {}; limits = [];
    handler = null;
    server.listen((request) async {
      requests.add(request);
      if (handler != null) { await handler!(request); }
      else { request.response.contentLength = 4096; await request.response.close(); }
    });
    estimator = DownloadSizeEstimator(cooldownUntil: (uri) => cooldowns[uri.host],
      onRateLimited: (uri, hint) async { limits.add((uri, hint)); });
  });
  tearDown(() async { estimator.dispose(); await server.close(force: true); });

  test('direct size uses one authenticated HEAD, not a body GET', () async {
    final estimate = await estimator.estimate(VideoSource(url: '$base/file.mp4',
      headers: const {'Cookie': 'fixture=1', 'Authorization': 'fixture', 'Referer': 'https://source.test'}));
    expect(estimate, (bytes: 4096, solid: true));
    expect(requests.single.method, 'HEAD');
    expect(requests.single.headers.value('cookie'), 'fixture=1');
    expect(requests.single.headers.value('authorization'), 'fixture');
  });
  test('HTML error page with200 does not masquerade as a video size', () async {
    handler = (req) async {
      req.response.headers.contentType = ContentType.html;
      req.response.contentLength = 4096;
      await req.response.close();
    };
    expect(await estimator.estimate(VideoSource(url: '$base/file.mp4')), isNull);
    expect(requests.single.method, 'HEAD');
  });
  test('existing host cooldown sends no requests', () async {
    cooldowns[base.host] = DateTime.now().add(const Duration(minutes: 2));
    expect(await estimator.estimate(VideoSource(url: '$base/file.mp4')), isNull);
    expect(requests, isEmpty);
  });
  test('429 records actual host hint with no retry or mirror attempt', () async {
    handler = (req) async {
      req.response.statusCode = 429;
      req.response.headers.set('retry-after', '120');
      await req.response.close();
    };
    expect(await estimator.estimate(VideoSource(url: '$base/file.mp4')), isNull);
    expect(requests, hasLength(1)); expect(limits, [(base.resolve('/file.mp4'), '120')]);
  });
  test('redirect destination cooldown is checked before connection', () async {
    handler = (req) async {
      req.response.statusCode = 302;
      req.response.headers.set('location', 'http://localhost:${server.port}/target');
      await req.response.close();
    };
    cooldowns['localhost'] = DateTime.now().add(const Duration(minutes: 2));
    expect(await estimator.estimate(VideoSource(url: '$base/file.mp4')), isNull);
    expect(requests, hasLength(1));
  });
  test('cross-origin redirect strips cookie/auth but keeps source referer', () async {
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    HttpRequest? received;
    target.listen((req) async { received = req; req.response.contentLength = 512; await req.response.close(); });
    handler = (req) async {
      req.response.statusCode = 302;
      req.response.headers.set('location', 'http://127.0.0.1:${target.port}/target');
      await req.response.close();
    };
    try {
      expect(await estimator.estimate(VideoSource(url: '$base/file.mp4', headers: const {
        'Cookie': 'fixture=1', 'Authorization': 'fixture', 'Referer': 'https://source.test'})),
        (bytes: 512, solid: true));
      expect(received!.headers.value('cookie'), isNull);
      expect(received!.headers.value('authorization'), isNull);
      expect(received!.headers.value('referer'), 'https://source.test');
    } finally { await target.close(force: true); }
  });
  test('redirect loops are bounded to four metadata requests', () async {
    handler = (req) async {
      req.response.statusCode = 302; req.response.headers.set('location', '/loop');
      await req.response.close();
    };
    expect(await estimator.estimate(VideoSource(url: '$base/file.mp4')), isNull);
    expect(requests, hasLength(4));
  });
  test('HLS reads only selected manifest, no variant or segment request', () async {
    handler = (req) async { req.response.write(master); await req.response.close(); };
    expect(await estimator.estimate(VideoSource(url: '$base/master.m3u8', quality: '720p'), runtimeMinutes: 20),
      (bytes: 600000000, solid: true));
    expect(requests.single.method, 'GET');
  });
  test('oversized playlist and direct length failure do not cause fallback GET', () async {
    estimator.dispose(); estimator = DownloadSizeEstimator(cooldownUntil: (_) => null,
      onRateLimited: (_, _) async {}, maxPlaylistBytes: 10);
    handler = (req) async { req.response.write(master); await req.response.close(); };
    expect(await estimator.estimate(VideoSource(url: '$base/master.m3u8')), isNull);
    handler = (req) async { req.response.statusCode = 405; await req.response.close(); };
    expect(await estimator.estimate(VideoSource(url: '$base/file.mp4')), isNull);
    expect(requests.map((r) => r.method), ['GET', 'HEAD']);
  });
  test('dispose and timeout end held requests without publishing a size', () async {
    final entered = Completer<void>();
    handler = (_) async { if (!entered.isCompleted) entered.complete(); };
    final pending = estimator.estimate(VideoSource(url: '$base/file.mp4'));
    await entered.future.timeout(const Duration(seconds: 2));
    estimator.dispose();
    expect(await pending.timeout(const Duration(seconds: 2)), isNull);
    estimator = DownloadSizeEstimator(cooldownUntil: (_) => null,
      onRateLimited: (_, _) async {}, timeout: const Duration(milliseconds: 40));
    expect(await estimator.estimate(VideoSource(url: '$base/file.mp4')), isNull);
  });
  test('DASH, torrents and non-http locations do not request anything', () async {
    for (final source in [VideoSource(url: '$base/manifest.mpd'),
      const VideoSource(url: 'file:///fixture.mp4'), const VideoSource(url: 'magnet:?xt=fixture'),
      VideoSource(url: '$base/file', container: SourceContainer.torrent)]) {
      expect(await estimator.estimate(source), isNull);
    }
    expect(requests, isEmpty);
  });
}
