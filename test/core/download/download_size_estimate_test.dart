import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/download_size_estimate.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/l10n/app_localizations_en.dart';

const master =
    '#EXTM3U\n'
    '#EXT-X-STREAM-INF:BANDWIDTH=8000000,RESOLUTION=1920x1080\nhigh.m3u8\n'
    '#EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1280x720\nlow.m3u8\n';

// Windows DownloadSizeEstimator coverage, run from the shared main below.
void _desktopEstimatorTests() {
  test(
    'HLS arithmetic follows nearest selected quality, not always fastest',
    () {
      final high = estimateDownloadPlaylist(
        master,
        'https://fixture/master.m3u8',
        quality: 'best',
        runtimeMinutes: 20,
      );
      final low = estimateDownloadPlaylist(
        master,
        'https://fixture/master.m3u8',
        quality: '800p',
        runtimeMinutes: 20,
      );
      expect(high, (bytes: 1200000000, solid: true));
      expect(low, (bytes: 600000000, solid: true));
      expect(
        estimateDownloadPlaylist(
          master,
          'https://fixture/master.m3u8',
          quality: '720p',
        ),
        isNull,
      );
    },
  );
  test(
    'VOD assumed bitrate is low-confidence; live/html/malformed stay unknown',
    () {
      const vod = '#EXTM3U\n#EXTINF:10.5,\na.ts\n#EXT-X-ENDLIST';
      expect(
        estimateDownloadPlaylist(vod, 'https://fixture/a', quality: '720p'),
        (bytes: 5250000, solid: false),
      );
      for (final body in [
        '<html>429</html>',
        vod.replaceAll('#EXT-X-ENDLIST', ''),
        vod.replaceAll('10.5', 'NaN'),
        '#EXTM3U\n#EXT-X-ENDLIST',
      ]) {
        expect(
          estimateDownloadPlaylist(body, 'https://fixture/a', quality: '720p'),
          isNull,
        );
      }
      expect(
        estimateDownloadPlaylist(vod, 'https://fixture/a', quality: 'auto'),
        isNull,
      );
      expect(
        estimateDownloadPlaylist(
          master,
          'https://fixture/a',
          quality: 'best',
          runtimeMinutes: 1 << 60,
        ),
        isNull,
      );
    },
  );

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
    requests = [];
    cooldowns = {};
    limits = [];
    handler = null;
    server.listen((request) async {
      requests.add(request);
      if (handler != null) {
        await handler!(request);
      } else {
        request.response.contentLength = 4096;
        await request.response.close();
      }
    });
    estimator = DownloadSizeEstimator(
      cooldownUntil: (uri) => cooldowns[uri.host],
      onRateLimited: (uri, hint) async {
        limits.add((uri, hint));
      },
    );
  });
  tearDown(() async {
    estimator.dispose();
    await server.close(force: true);
  });

  test('direct size uses one authenticated HEAD, not a body GET', () async {
    final estimate = await estimator.estimate(
      VideoSource(
        url: '$base/file.mp4',
        headers: const {
          'Cookie': 'fixture=1',
          'Authorization': 'fixture',
          'Referer': 'https://source.test',
        },
      ),
    );
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
    expect(
      await estimator.estimate(VideoSource(url: '$base/file.mp4')),
      isNull,
    );
    expect(requests.single.method, 'HEAD');
  });
  test('existing host cooldown sends no requests', () async {
    cooldowns[base.host] = DateTime.now().add(const Duration(minutes: 2));
    expect(
      await estimator.estimate(VideoSource(url: '$base/file.mp4')),
      isNull,
    );
    expect(requests, isEmpty);
  });
  test(
    '429 records actual host hint with no retry or mirror attempt',
    () async {
      handler = (req) async {
        req.response.statusCode = 429;
        req.response.headers.set('retry-after', '120');
        await req.response.close();
      };
      expect(
        await estimator.estimate(VideoSource(url: '$base/file.mp4')),
        isNull,
      );
      expect(requests, hasLength(1));
      expect(limits, [(base.resolve('/file.mp4'), '120')]);
    },
  );
  test('redirect destination cooldown is checked before connection', () async {
    handler = (req) async {
      req.response.statusCode = 302;
      req.response.headers.set(
        'location',
        'http://localhost:${server.port}/target',
      );
      await req.response.close();
    };
    cooldowns['localhost'] = DateTime.now().add(const Duration(minutes: 2));
    expect(
      await estimator.estimate(VideoSource(url: '$base/file.mp4')),
      isNull,
    );
    expect(requests, hasLength(1));
  });
  test(
    'cross-origin redirect strips cookie/auth but keeps source referer',
    () async {
      final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      HttpRequest? received;
      target.listen((req) async {
        received = req;
        req.response.contentLength = 512;
        await req.response.close();
      });
      handler = (req) async {
        req.response.statusCode = 302;
        req.response.headers.set(
          'location',
          'http://127.0.0.1:${target.port}/target',
        );
        await req.response.close();
      };
      try {
        expect(
          await estimator.estimate(
            VideoSource(
              url: '$base/file.mp4',
              headers: const {
                'Cookie': 'fixture=1',
                'Authorization': 'fixture',
                'Referer': 'https://source.test',
              },
            ),
          ),
          (bytes: 512, solid: true),
        );
        expect(received!.headers.value('cookie'), isNull);
        expect(received!.headers.value('authorization'), isNull);
        expect(received!.headers.value('referer'), 'https://source.test');
      } finally {
        await target.close(force: true);
      }
    },
  );
  test('redirect loops are bounded to four metadata requests', () async {
    handler = (req) async {
      req.response.statusCode = 302;
      req.response.headers.set('location', '/loop');
      await req.response.close();
    };
    expect(
      await estimator.estimate(VideoSource(url: '$base/file.mp4')),
      isNull,
    );
    expect(requests, hasLength(4));
  });
  test(
    'HLS reads only selected manifest, no variant or segment request',
    () async {
      handler = (req) async {
        req.response.write(master);
        await req.response.close();
      };
      expect(
        await estimator.estimate(
          VideoSource(url: '$base/master.m3u8', quality: '720p'),
          runtimeMinutes: 20,
        ),
        (bytes: 600000000, solid: true),
      );
      expect(requests.single.method, 'GET');
    },
  );
  test(
    'oversized playlist and direct length failure do not cause fallback GET',
    () async {
      estimator.dispose();
      estimator = DownloadSizeEstimator(
        cooldownUntil: (_) => null,
        onRateLimited: (_, _) async {},
        maxPlaylistBytes: 10,
      );
      handler = (req) async {
        req.response.write(master);
        await req.response.close();
      };
      expect(
        await estimator.estimate(VideoSource(url: '$base/master.m3u8')),
        isNull,
      );
      handler = (req) async {
        req.response.statusCode = 405;
        await req.response.close();
      };
      expect(
        await estimator.estimate(VideoSource(url: '$base/file.mp4')),
        isNull,
      );
      expect(requests.map((r) => r.method), ['GET', 'HEAD']);
    },
  );
  test(
    'dispose and timeout end held requests without publishing a size',
    () async {
      final entered = Completer<void>();
      handler = (_) async {
        if (!entered.isCompleted) entered.complete();
      };
      final pending = estimator.estimate(VideoSource(url: '$base/file.mp4'));
      await entered.future.timeout(const Duration(seconds: 2));
      estimator.dispose();
      expect(await pending.timeout(const Duration(seconds: 2)), isNull);
      estimator = DownloadSizeEstimator(
        cooldownUntil: (_) => null,
        onRateLimited: (_, _) async {},
        timeout: const Duration(milliseconds: 40),
      );
      expect(
        await estimator.estimate(VideoSource(url: '$base/file.mp4')),
        isNull,
      );
    },
  );
  test(
    'DASH, torrents and non-http locations do not request anything',
    () async {
      for (final source in [
        VideoSource(url: '$base/manifest.mpd'),
        const VideoSource(url: 'file:///fixture.mp4'),
        const VideoSource(url: 'magnet:?xt=fixture'),
        VideoSource(url: '$base/file', container: SourceContainer.torrent),
      ]) {
        expect(await estimator.estimate(source), isNull);
      }
      expect(requests, isEmpty);
    },
  );
}

VideoSource src(String url, {String? quality}) =>
    VideoSource(url: url, quality: quality, container: SourceContainer.mp4);

void main() {
  _desktopEstimatorTests();

  group('parseHlsVariants', () {
    test('reads bandwidth and height, fastest first', () {
      const manifest = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
low.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
high.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720
mid.m3u8
''';
      final variants = parseHlsVariants(manifest);

      expect(variants.map((v) => v.bandwidth), [5000000, 2000000, 800000]);
      expect(variants.map((v) => v.height), [1080, 720, 360]);
    });

    test('media playlists yield nothing', () {
      const manifest = '''
#EXTM3U
#EXT-X-TARGETDURATION:6
#EXTINF:6.0,
seg0.ts
''';
      expect(parseHlsVariants(manifest), isEmpty);
    });

    test('average bandwidth does not shadow the variant bandwidth', () {
      expect(
        parseHlsVariants(
          '#EXTM3U\n#EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=1000000,BANDWIDTH=2000000\na.m3u8',
        ).single.bandwidth,
        2000000,
      );
    });

    test('variants without bandwidth are skipped, height optional', () {
      const manifest = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1000000
audio.m3u8
#EXT-X-STREAM-INF:RESOLUTION=640x360
novariant.m3u8
''';
      final variants = parseHlsVariants(manifest);

      expect(variants, hasLength(1));
      expect(variants.single.height, isNull);
    });
  });

  group('hlsVariantBytes', () {
    const variants = [
      (bandwidth: 5000000, height: 1080),
      (bandwidth: 2000000, height: 720),
    ];

    test('matches the wanted height', () {
      expect(
        hlsVariantBytes(variants, wantedHeight: 720, runtimeSec: 1200),
        2000000 ~/ 8 * 1200,
      );
    });

    test('falls back to the fastest without a match', () {
      expect(
        hlsVariantBytes(variants, wantedHeight: 480, runtimeSec: 1200),
        5000000 ~/ 8 * 1200,
      );
    });

    test('needs variants and a runtime', () {
      expect(hlsVariantBytes(const [], runtimeSec: 1200), isNull);
      expect(hlsVariantBytes(variants, runtimeSec: 0), isNull);
    });
  });

  test('qualityHeight parses labels, null otherwise', () {
    expect(qualityHeight('1080p'), 1080);
    expect(qualityHeight('720p60'), 720);
    expect(qualityHeight('best'), isNull);
    expect(qualityHeight(null), isNull);
  });

  test('formatApproxBytes always wears its tilde', () {
    expect(formatApproxBytes(2 * (1 << 30)), '~2.0 GB');
    expect(formatApproxBytes(90 * (1 << 20)), '~90 MB');
    expect(formatApproxBytes(512), '~512 B');
    expect(
      AppLocalizationsEn().downloadSizeEstimate('~90 MB', '~180 MB'),
      '~90 MB / episode · ~180 MB total',
    );
  });

  test('parseHlsMediaDurationSec sums segments, rejects non-playlists', () {
    const media = '#EXTM3U\n#EXTINF:6.0,\na.ts\n#EXTINF:4.5,\nb.ts\n';
    expect(parseHlsMediaDurationSec(media), 11);
    expect(parseHlsMediaDurationSec('not a playlist'), isNull);
    expect(
      parseHlsMediaDurationSec('#EXTM3U\n#EXT-X-TARGETDURATION:6\n'),
      isNull,
    );
  });

  test('assumedBitrateForHeight is coarse and null-safe', () {
    expect(assumedBitrateForHeight(1080), 8000000);
    expect(assumedBitrateForHeight(480), 2000000);
    expect(assumedBitrateForHeight(null), isNull);
  });

  group('estimateEpisodeBytes against a local server', () {
    late HttpServer server;
    late Uri base;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = Uri(scheme: 'http', host: '127.0.0.1', port: server.port);
      server.listen((req) async {
        if (req.uri.path == '/video.mp4') {
          req.response.headers.contentLength = 42 * (1 << 20);
          await req.response.close();
        } else if (req.uri.path == '/nolength.mp4') {
          req.response.headers.chunkedTransferEncoding = true;
          await req.response.close();
        } else if (req.uri.path == '/master.m3u8') {
          req.response.headers.contentType = ContentType.text;
          req.response.write(
            '#EXTM3U\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x1080\n'
            'hi.m3u8\n',
          );
          await req.response.close();
        } else if (req.uri.path == '/error.mp4') {
          req.response.statusCode = HttpStatus.forbidden;
          req.response.headers.contentLength = 128;
          await req.response.close();
        } else {
          req.response.statusCode = HttpStatus.notFound;
          await req.response.close();
        }
      });
    });

    tearDown(() => server.close(force: true));

    test('direct file reads content-length, solid', () async {
      final est = await estimateEpisodeBytes(
        src('${base.replace(path: '/video.mp4')}'),
      );

      expect(est?.bytes, 42 * (1 << 20));
      expect(est?.solid, isTrue);
    });

    test('missing length is unknown, not zero', () async {
      expect(
        await estimateEpisodeBytes(
          src('${base.replace(path: '/nolength.mp4')}'),
        ),
        isNull,
      );
    });

    test('an error response length is not a video size', () async {
      expect(
        await estimateEpisodeBytes(src('${base.replace(path: '/error.mp4')}')),
        isNull,
      );
    });

    test('hls master math is solid; without runtime it is unknown', () async {
      final url = '${base.replace(path: '/master.m3u8')}';
      final est = await estimateEpisodeBytes(
        src(url, quality: '1080p'),
        runtimeMinutes: 20,
      );

      expect(est?.bytes, 4000000 ~/ 8 * 20 * 60);
      expect(est?.solid, isTrue);
      expect(await estimateEpisodeBytes(src(url, quality: '1080p')), isNull);
    });

    test('media playlist falls back to assumed bitrate, not solid', () async {
      // Separate server serving a media playlist (no variants stated).
      final media = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      try {
        media.listen((req) async {
          req.response.headers.contentType = ContentType.text;
          req.response.write(
            '#EXTM3U\n#EXT-X-TARGETDURATION:6\n'
            '#EXTINF:6.0,\na.ts\n#EXTINF:6.0,\nb.ts\n',
          );
          await req.response.close();
        });
        final url = 'http://127.0.0.1:${media.port}/media.m3u8';
        final est = await estimateEpisodeBytes(src(url, quality: '1080p'));

        // 12s at assumed 8 Mbps → 12 MB, flagged low-confidence.
        expect(est?.bytes, 8000000 ~/ 8 * 12);
        expect(est?.solid, isFalse);
      } finally {
        await media.close(force: true);
      }
    });

    test('garbage in, null out', () async {
      expect(await estimateEpisodeBytes(src('')), isNull);
      expect(await estimateEpisodeBytes(src('not a url')), isNull);
      expect(
        await estimateEpisodeBytes(src('${base.replace(path: '/missing')}')),
        isNull,
      );
    });

    test('dash is skipped without fetching', () async {
      expect(
        await estimateEpisodeBytes(src('${base.replace(path: '/x.mpd')}')),
        isNull,
      );
    });
  });
}
