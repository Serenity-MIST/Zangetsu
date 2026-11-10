import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/hls_downloader.dart';

/// Deterministic HTTP fixtures preserve headers and never contact a real host.
class _LimitedMedia implements HttpClientAdapter {
  _LimitedMedia(this.stage);
  final String stage;
  final requested = <RequestOptions>[];
  String get limitedPath => switch (stage) {
    'playlist' => '/master.m3u8',
    'key' => '/key.bin',
    'init' => '/init.mp4',
    'audio' => '/en0.ts',
    _ => '/video0.ts',
  };
  @override
  Future<ResponseBody> fetch(RequestOptions options, _, _) async {
    requested.add(options);
    final path = options.uri.path;
    if (path == limitedPath) {
      return ResponseBody.fromString('<html><body>429 secret-response</body></html>', 429,
          headers: {'retry-after': ['90']});
    }
    if (path.endsWith('.m3u8')) {
      if (path == '/master.m3u8' && stage == 'audio') {
        return ResponseBody.fromString('#EXTM3U\n'
          '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="main",NAME="English",LANGUAGE="en",URI="en.m3u8"\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=1000000,AUDIO="main"\nvideo.m3u8\n', 200);
      }
      final prefix = path == '/en.m3u8' ? 'en' : 'video';
      return ResponseBody.fromString('#EXTM3U\n#EXT-X-TARGETDURATION:1\n'
          '${stage == 'key' ? '#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n' : ''}'
          '${stage == 'init' ? '#EXT-X-MAP:URI="init.mp4"\n' : ''}'
          '#EXTINF:1,\n${prefix}0.ts\n#EXTINF:1,\n${prefix}1.ts\n#EXT-X-ENDLIST\n', 200);
    }
    return ResponseBody.fromBytes(List<int>.filled(188, 0x47), 200);
  }
  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory root;
  setUp(() async { root = await Directory.systemTemp.createTemp('hls-rate-limit-'); });
  tearDown(() async { await root.delete(recursive: true); });

  for (final stage in ['playlist', 'key', 'init', 'segment', 'audio']) {
    test('HLS429 propagates from $stage without exposing response or retrying', () async {
      final host = _LimitedMedia(stage);
      final client = Dio()..httpClientAdapter = host;
      final observed = <(Uri, String?)>[];
      var merges = 0;
      final downloader = HlsDownloader(client,
        muxAudio: (video, audio, output, language, canceled) async {
          merges++;
          return 'must not merge a failed download';
        },
        onRateLimited: (uri, hint) async { observed.add((uri, hint)); },
      );
      final file = File('${root.path}/result.ts');
      final error = await downloader.download(
        url: 'https://fixture.test/master.m3u8?token=private',
        headers: {'Referer': 'fixture'},
        outputPath: file.path,
        preferredQuality: 'best',
        preferredAudioLanguage: 'en',
        connections: 1,
        canceled: () => false,
        onProgress: (_) {},
      );
      expect(downloader.rateLimited, isTrue);
      expect(downloader.receivedRateLimitResponse, isTrue);
      expect(error, contains('(429)'));
      expect(error, isNot(contains('secret-response')));
      expect(error, isNot(contains('private')));
      expect(observed, hasLength(1));
      expect(observed.single.$1.host, 'fixture.test');
      expect(observed.single.$2, '90');
      expect(host.requested.where((r) => r.uri.path == host.limitedPath), hasLength(1));
      expect(host.requested.every((r) => r.headers['Referer'] == 'fixture'), isTrue);
      expect(host.requested.any((r) => r.uri.path == (stage == 'audio' ? '/en1.ts' : '/video1.ts')), isFalse);
      expect(merges, 0);
      expect(await file.exists(), isFalse);
      client.close(force: true);
    });
  }

  test('existing cooldown prevents any HLS request without extending it', () async {
    final host = _LimitedMedia('playlist');
    final client = Dio()..httpClientAdapter = host;
    var writes = 0;
    final downloader = HlsDownloader(client,
      isHostCoolingDown: (uri) => uri.host == 'fixture.test',
      onRateLimited: (uri, hint) async { writes++; },
    );
    final error = await downloader.download(
      url: 'https://fixture.test/master.m3u8', headers: {},
      outputPath: '${root.path}/none.ts', preferredQuality: 'best',
      canceled: () => false, onProgress: (_) {},
    );
    expect(error, contains('(429)'));
    expect(host.requested, isEmpty);
    expect(downloader.receivedRateLimitResponse, isFalse);
    expect(writes, 0);
    client.close(force: true);
  });

  test('caller without desktop policy retains existing failure contract', () async {
    final host = _LimitedMedia('playlist');
    final client = Dio()..httpClientAdapter = host;
    final downloader = HlsDownloader(client);
    final error = await downloader.download(
      url: 'https://fixture.test/master.m3u8', headers: {},
      outputPath: '${root.path}/legacy.ts', preferredQuality: 'best',
      canceled: () => false, onProgress: (_) {},
    );
    expect(error, 'playlist unreachable');
    expect(downloader.rateLimited, isFalse);
    client.close(force: true);
  });
}
