import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/hls_downloader.dart';

/// Holds the first wave of actual segment requests to expose worker capacity.
class _Segments implements HttpClientAdapter {
  _Segments(this.expected);
  final int expected;
  final ready = Completer<void>();
  final release = Completer<void>();
  int active = 0;
  int peak = 0;
  int fetched = 0;
  @override
  Future<ResponseBody> fetch(RequestOptions options, _, _) async {
    if (options.path.endsWith('.m3u8')) {
      return ResponseBody.fromString(
        [
          '#EXTM3U',
          '#EXT-X-TARGETDURATION:1',
          for (var i = 0; i < 16; i++) ...[
            '#EXTINF:1,',
            'https://fixture.test/$i.ts',
          ],
          '#EXT-X-ENDLIST',
        ].join('\n'),
        200,
      );
    }
    active++;
    fetched++;
    if (active > peak) peak = active;
    if (active == expected && !ready.isCompleted) ready.complete();
    await release.future;
    active--;
    return ResponseBody.fromBytes(List.filled(188, 0x47), 200);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  for (final count in [1, 8]) {
    test('HLS uses at most $count selected segment connections', () async {
      final root = await Directory.systemTemp.createTemp('hls-connections-');
      final host = _Segments(count);
      final client = Dio()..httpClientAdapter = host;
      try {
        final transfer = HlsDownloader(client).download(
          url: 'https://fixture.test/index.m3u8',
          outputPath: '${root.path}/video.ts',
          headers: {},
          preferredQuality: 'best',
          connections: count,
          onProgress: (_) {},
          canceled: () => false,
        );
        await host.ready.future.timeout(const Duration(seconds: 5));
        expect(host.active, count);
        expect(host.fetched, count);
        host.release.complete();
        expect(await transfer, isNull);
        expect(host.peak, count);
        expect(host.fetched, 16);
      } finally {
        client.close(force: true);
        await root.delete(recursive: true);
      }
    });
  }
}
