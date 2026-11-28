import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/hls_downloader.dart';

/// A real HTTP server on 127.0.0.1 serving one HLS playlist. Each segment is
/// a block of bytes that names its own number, so a joined file shows at
/// once whether anything was lost, repeated or put in the wrong order.
class _LoopbackHls {
  _LoopbackHls._(this._server, this.segments);

  final HttpServer _server;
  int segments;

  /// Segment numbers in the order they were asked for.
  final requests = <int>[];

  /// Returns true to cut the connection for this request of segment `i`
  /// (no answer at all, like a Wi-Fi extender restarting).
  bool Function(int i)? drop;

  /// HTTP status to answer instead of the segment, or null for the segment.
  int? Function(int i)? status;

  /// Changes the playlist's segment lengths, so it is "another playlist".
  String extinf = '1.0';

  static Future<_LoopbackHls> start(int segments) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final host = _LoopbackHls._(server, segments);
    server.listen(host._handle);
    return host;
  }

  String get url => 'http://127.0.0.1:${_server.port}/index.m3u8';

  static Uint8List segment(int i) => Uint8List.fromList(
    List<int>.generate(400, (k) => k < 4 ? (i >> (8 * k)) & 0xff : i % 251),
  );

  /// What one uninterrupted download of [count] segments produces.
  static List<int> whole(int count) => [
    for (var i = 0; i < count; i++) ...segment(i),
  ];

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    if (path.endsWith('.m3u8')) {
      request.response.write(
        [
          '#EXTM3U',
          '#EXT-X-TARGETDURATION:1',
          for (var i = 0; i < segments; i++) ...['#EXTINF:$extinf,', 's$i.ts'],
          '#EXT-X-ENDLIST',
        ].join('\n'),
      );
      await request.response.close();
      return;
    }
    final i = int.parse(path.substring(2, path.length - 3));
    requests.add(i);
    if (drop?.call(i) == true) {
      final socket = await request.response.detachSocket(writeHeaders: false);
      socket.destroy();
      return;
    }
    final code = status?.call(i);
    if (code != null) {
      request.response.statusCode = code;
      await request.response.close();
      return;
    }
    request.response.add(segment(i));
    await request.response.close();
  }

  Future<void> close() => _server.close(force: true);
}

void main() {
  late Directory root;
  late _LoopbackHls host;
  late Dio dio;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('hls-resume-');
    dio = Dio();
  });

  tearDown(() async {
    dio.close(force: true);
    await host.close();
    await root.delete(recursive: true);
  });

  HlsDownloader downloader({
    Future<void> Function()? waitForNetwork,
    Duration patience = const Duration(seconds: 20),
  }) => HlsDownloader(
    dio,
    resilient: true,
    waitForNetwork: waitForNetwork,
    networkPatience: patience,
    retryDelays: const [Duration(milliseconds: 20), Duration(milliseconds: 50)],
  );

  Future<String?> run(
    HlsDownloader hls,
    String output, {
    bool Function()? paused,
    bool Function()? canceled,
    void Function(double)? onProgress,
    String job = 'job-1',
  }) => hls.download(
    url: host.url,
    headers: const {},
    outputPath: output,
    preferredQuality: 'best',
    connections: 1,
    onProgress: onProgress ?? (_) {},
    canceled: canceled ?? () => false,
    paused: paused,
    resumeKey: job,
  );

  test('a dropped connection mid-download is ridden out, not failed', () async {
    host = await _LoopbackHls.start(30);
    // Segment 12 gets no answer for its first 4 tries (about a short outage).
    var cuts = 0;
    host.drop = (i) => i == 12 && cuts++ < 4;
    final output = '${root.path}/E19.ts';

    final result = await run(downloader(), output);

    expect(result, isNull);
    expect(await File(output).readAsBytes(), _LoopbackHls.whole(30));
    // Nothing after the dropped segment was asked for twice.
    final after = host.requests.where((i) => i > 12).toList();
    expect(after.toSet().length, after.length);
    expect(host.requests.where((i) => i == 12).length, 5);
    expect(await File('$output.part').exists(), isFalse);
    expect(await File('$output.part.json').exists(), isFalse);
  });

  test('time spent offline is not counted against the patience', () async {
    host = await _LoopbackHls.start(20);
    var offline = true;
    final back = Completer<void>();
    host.drop = (i) => i == 5 && offline;
    var parked = 0;
    final hls = downloader(
      patience: const Duration(milliseconds: 150),
      waitForNetwork: () {
        if (!offline) return Future.value();
        parked++;
        return back.future;
      },
    );
    final output = '${root.path}/offline.ts';
    final transfer = run(hls, output);
    // Offline far longer than the patience; the job must still be waiting.
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(parked, greaterThan(0));
    offline = false;
    back.complete();

    expect(await transfer, isNull);
    expect(await File(output).readAsBytes(), _LoopbackHls.whole(20));
  });

  test('pause keeps the partial file and the next run carries on', () async {
    host = await _LoopbackHls.start(40);
    final output = '${root.path}/paused.ts';
    var pause = false;
    final first = await run(
      downloader(),
      output,
      paused: () => pause,
      onProgress: (p) {
        if (p >= 20 / 40) pause = true;
      },
    );
    expect(first, HlsDownloader.pausedResult);
    expect(await File('$output.part').exists(), isTrue);
    final saved = jsonDecode(await File('$output.part.json').readAsString());
    expect(saved['next'], 20);
    expect(await File(output).exists(), isFalse);

    host.requests.clear();
    final progress = <double>[];
    final second = await run(downloader(), output, onProgress: progress.add);

    expect(second, isNull);
    expect(host.requests.first, 20);
    expect(host.requests, List<int>.generate(20, (i) => i + 20));
    // The row shows the saved progress at once, not 0.
    expect(progress.first, closeTo(.5, 1e-9));
    expect(await File(output).readAsBytes(), _LoopbackHls.whole(40));
  });

  test('extra bytes written after the last save are cut back', () async {
    host = await _LoopbackHls.start(16);
    final output = '${root.path}/torn.ts';
    var pause = false;
    await run(
      downloader(),
      output,
      paused: () => pause,
      onProgress: (p) {
        if (p >= 8 / 16) pause = true;
      },
    );
    // A crash after data reached the disk but before its position was saved.
    await File('$output.part').writeAsBytes([1, 2, 3, 4, 5], mode: FileMode.append);

    expect(await run(downloader(), output), isNull);
    expect(await File(output).readAsBytes(), _LoopbackHls.whole(16));
  });

  test('a changed playlist starts over and drops the old partial', () async {
    host = await _LoopbackHls.start(30);
    final output = '${root.path}/changed.ts';
    var pause = false;
    await run(
      downloader(),
      output,
      paused: () => pause,
      onProgress: (p) {
        if (p >= 10 / 30) pause = true;
      },
    );
    expect(await File('$output.part').exists(), isTrue);

    host
      ..segments = 25
      ..extinf = '2.0'
      ..requests.clear();
    expect(await run(downloader(), output), isNull);
    expect(host.requests.first, 0);
    expect(await File(output).readAsBytes(), _LoopbackHls.whole(25));
  });

  test('another job never joins this job\'s partial file', () async {
    host = await _LoopbackHls.start(20);
    final output = '${root.path}/owned.ts';
    var pause = false;
    await run(
      downloader(),
      output,
      paused: () => pause,
      onProgress: (p) {
        if (p >= 10 / 20) pause = true;
      },
    );
    host.requests.clear();
    expect(await run(downloader(), output, job: 'job-2'), isNull);
    expect(host.requests.first, 0);
  });

  test('403 on a segment reports an expired link and keeps the partial', () async {
    host = await _LoopbackHls.start(20);
    var expired = true;
    host.status = (i) => i == 9 && expired ? 403 : null;
    final output = '${root.path}/expired.ts';

    expect(await run(downloader(), output), HlsDownloader.expiredResult);
    expect(await File('$output.part').exists(), isTrue);
    final saved = jsonDecode(await File('$output.part.json').readAsString());
    expect(saved['next'], 9);

    // A fresh link (same playlist) carries on from segment 9.
    expired = false;
    host.requests.clear();
    expect(await run(downloader(), output), isNull);
    expect(host.requests.first, 9);
    expect(await File(output).readAsBytes(), _LoopbackHls.whole(20));
  });

  test('a 404 segment is still a real failure', () async {
    host = await _LoopbackHls.start(10);
    host.status = (i) => i == 3 ? 404 : null;
    final output = '${root.path}/missing.ts';
    expect(await run(downloader(), output), 'segment 4/10 unreachable');
    // The partial stays for a later Retry of the same stream.
    expect(await File('$output.part').exists(), isTrue);
  });

  test('a long outage while online gives up as network and resumes later', () async {
    host = await _LoopbackHls.start(24);
    var down = true;
    host.drop = (i) => i >= 14 && down;
    final output = '${root.path}/gaveup.ts';

    final first = await run(
      downloader(patience: const Duration(milliseconds: 300)),
      output,
    );
    expect(first, HlsDownloader.networkResult);
    expect(await HlsDownloader.hasResumableProgress(output), isTrue);

    down = false;
    host.requests.clear();
    expect(await run(downloader(), output), isNull);
    expect(host.requests.first, 14);
    expect(await File(output).readAsBytes(), _LoopbackHls.whole(24));
  });

  test('cancel removes the partial file and its progress file', () async {
    host = await _LoopbackHls.start(30);
    final output = '${root.path}/canceled.ts';
    var cancel = false;
    final result = await run(
      downloader(),
      output,
      canceled: () => cancel,
      onProgress: (p) {
        if (p >= 5 / 30) cancel = true;
      },
    );
    expect(result, HlsDownloader.canceledResult);
    expect(await File('$output.part').exists(), isFalse);
    expect(await File('$output.part.json').exists(), isFalse);
    expect(await File(output).exists(), isFalse);
  });

  test('two jobs can never write the same partial file at once', () async {
    host = await _LoopbackHls.start(20);
    final gate = Completer<void>();
    host.drop = (i) => i == 2 && !gate.isCompleted;
    final output = '${root.path}/busy.ts';
    final first = run(
      downloader(waitForNetwork: () => gate.future),
      output,
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(await run(downloader(), output), HlsDownloader.busyResult);
    gate.complete();
    expect(await first, isNull);
    expect(await File(output).readAsBytes(), _LoopbackHls.whole(20));
  });

  test('without resilient mode a short drop still fails as before', () async {
    host = await _LoopbackHls.start(10);
    host.drop = (i) => i == 4;
    final output = '${root.path}/legacy.ts';
    final result = await HlsDownloader(dio).download(
      url: host.url,
      headers: const {},
      outputPath: output,
      preferredQuality: 'best',
      connections: 1,
      onProgress: (_) {},
      canceled: () => false,
    );
    expect(result, 'segment 5/10 unreachable');
    expect(await File(output).exists(), isFalse);
    expect(await File('$output.part').exists(), isFalse);
  });
}
