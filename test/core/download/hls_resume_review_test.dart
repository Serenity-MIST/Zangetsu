import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/hls_downloader.dart';

/// A real HTTP server on 127.0.0.1 with a master playlist: video qualities
/// (`/v1080/`, `/v720/`) and audio languages (`/a_en/`, `/a_ja/`) that all
/// share one segment layout, the way a real quality ladder does. Every
/// segment says which track and which number it is, so a file that mixes
/// two qualities or two languages shows it at once.
class _LadderHls {
  _LadderHls._(this._server);

  final HttpServer _server;
  int segments = 12;

  /// Video qualities the master lists, highest first.
  List<int> qualities = [1080, 720];

  /// Audio languages the master lists; empty for none.
  List<String> languages = const [];

  /// `track/segment` names in the order they were asked for.
  final requests = <String>[];

  /// Media playlist paths in the order they were asked for.
  final playlists = <String>[];

  /// Answer 200 with a web page instead of this segment.
  bool Function(String track, int i)? webPage;

  /// HTTP status to answer instead of this segment.
  int? Function(String track, int i)? status;

  /// When set, the answer for this segment waits for the future.
  Future<void>? Function(String track, int i)? hold;

  static Future<_LadderHls> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final host = _LadderHls._(server);
    server.listen(host._handle);
    return host;
  }

  String get master => 'http://127.0.0.1:${_server.port}/master.m3u8';

  static int _code(String track) => switch (track) {
    'v1080' => 1,
    'v720' => 2,
    'a_en' => 3,
    'a_ja' => 4,
    _ => 9,
  };

  static Uint8List segment(String track, int i) => Uint8List.fromList(
    List<int>.generate(300, (k) => k == 0 ? _code(track) : (k == 1 ? i : k % 50)),
  );

  static List<int> whole(String track, int count) => [
    for (var i = 0; i < count; i++) ...segment(track, i),
  ];

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    if (path == '/master.m3u8') {
      final audio = languages.isNotEmpty;
      request.response.write(
        [
          '#EXTM3U',
          for (final (n, lang) in languages.indexed)
            '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",LANGUAGE="$lang",'
                'NAME="$lang",DEFAULT=${n == 0 ? 'YES' : 'NO'},'
                'AUTOSELECT=YES,URI="a_$lang/index.m3u8"',
          for (final q in qualities) ...[
            '#EXT-X-STREAM-INF:BANDWIDTH=${q * 1000},'
                'RESOLUTION=${q * 16 ~/ 9}x$q${audio ? ',AUDIO="aud"' : ''}',
            'v$q/index.m3u8',
          ],
        ].join('\n'),
      );
      await request.response.close();
      return;
    }
    final parts = path.split('/');
    final track = parts[1];
    if (path.endsWith('.m3u8')) {
      playlists.add(track);
      request.response.write(
        [
          '#EXTM3U',
          '#EXT-X-TARGETDURATION:1',
          for (var i = 0; i < segments; i++) ...['#EXTINF:1.0,', 's$i.ts'],
          '#EXT-X-ENDLIST',
        ].join('\n'),
      );
      await request.response.close();
      return;
    }
    final name = parts.last;
    final i = int.parse(name.substring(1, name.length - 3));
    requests.add('$track/$i');
    final wait = hold?.call(track, i);
    if (wait != null) await wait;
    final code = status?.call(track, i);
    if (code != null) {
      request.response.statusCode = code;
      await request.response.close();
      return;
    }
    if (webPage?.call(track, i) == true) {
      request.response.headers.contentType = ContentType.html;
      request.response.write('<!DOCTYPE html><html><body>Sign in</body></html>');
      await request.response.close();
      return;
    }
    request.response.add(segment(track, i));
    await request.response.close();
  }

  Future<void> close() => _server.close(force: true);
}

void main() {
  late Directory root;
  late _LadderHls host;
  late Dio dio;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('hls-review-');
    dio = Dio();
    host = await _LadderHls.start();
  });

  tearDown(() async {
    dio.close(force: true);
    await host.close();
    for (var i = 0; i < 20; i++) {
      try {
        await root.delete(recursive: true);
        break;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  HlsDownloader downloader({
    HlsAudioMux? mux,
    Duration patience = const Duration(seconds: 20),
  }) => HlsDownloader(
    dio,
    muxAudio: mux,
    resilient: true,
    networkPatience: patience,
    retryDelays: const [Duration(milliseconds: 20), Duration(milliseconds: 50)],
  );

  Future<String?> run(
    HlsDownloader hls,
    String output, {
    String quality = '1080p',
    String? language,
    String source = 'server|1080p',
    bool Function()? paused,
    void Function(double)? onProgress,
    bool discardStaleOutput = false,
  }) => hls.download(
    url: host.master,
    headers: const {},
    outputPath: output,
    preferredQuality: quality,
    preferredAudioLanguage: language,
    connections: 1,
    onProgress: onProgress ?? (_) {},
    canceled: () => false,
    paused: paused,
    resumeKey: 'job-1',
    sourceTag: source,
    discardStaleOutput: discardStaleOutput,
  );

  /// Runs until [stopAt] of the video is saved, then pauses.
  Future<void> pauseAt(String output, double stopAt, {String? language, HlsAudioMux? mux}) async {
    var pause = false;
    final result = await run(
      downloader(mux: mux),
      output,
      language: language,
      paused: () => pause,
      onProgress: (p) {
        if (p >= stopAt) pause = true;
      },
    );
    expect(result, HlsDownloader.pausedResult);
  }

  test('another quality with the same segment layout is never joined on', () async {
    final output = '${root.path}/ladder.ts';
    await pauseAt(output, 5 / 12);
    // The master now offers 720p only: same count, sequence and lengths.
    host
      ..qualities = [720]
      ..requests.clear();

    expect(await run(downloader(), output), isNull);
    // Started over on 720p; the 1080p bytes are gone.
    expect(host.requests.first, 'v720/0');
    expect(await File(output).readAsBytes(), _LadderHls.whole('v720', 12));
  });

  test('another server name starts fresh too', () async {
    final output = '${root.path}/server.ts';
    await pauseAt(output, 4 / 12);
    host.requests.clear();
    expect(await run(downloader(), output, source: 'other|1080p'), isNull);
    expect(host.requests.first, 'v1080/0');
    expect(await File(output).readAsBytes(), _LadderHls.whole('v1080', 12));
  });

  test('the saved server is readable for the manager', () async {
    final output = '${root.path}/tag.ts';
    await pauseAt(output, 3 / 12);
    expect(await HlsDownloader.readSourceTag(output), 'server|1080p');
    expect(await HlsDownloader.readSourceTag('${root.path}/none.ts'), isNull);
  });

  test('an old partial stays until the new playlist delivers bytes', () async {
    final output = '${root.path}/kept.ts';
    await pauseAt(output, 6 / 12);
    final before = jsonDecode(await File('$output.part.json').readAsString());
    expect(before['next'], 6);

    // Another quality is offered, but its very first segment never comes.
    host
      ..qualities = [720]
      ..status = (track, i) => track == 'v720' ? 503 : null;
    final failed = await run(
      downloader(patience: const Duration(milliseconds: 300)),
      output,
      quality: '720p',
    );
    expect(failed, HlsDownloader.networkResult);
    // The 1080p progress is untouched, so going back to it carries on.
    final after = jsonDecode(await File('$output.part.json').readAsString());
    expect(after['next'], 6);

    host
      ..qualities = [1080, 720]
      ..status = null
      ..requests.clear();
    expect(await run(downloader(), output), isNull);
    expect(host.requests.first, 'v1080/6');
    expect(await File(output).readAsBytes(), _LadderHls.whole('v1080', 12));
  });

  test('a finished audio track in another language is not merged in', () async {
    host.languages = ['en', 'ja'];
    final output = '${root.path}/audio.ts';
    final merges = <List<int>>[];
    var failMerge = true;
    Future<String?> mux(
      String video,
      String audio,
      String out,
      String? language,
      bool Function() canceled,
    ) async {
      final audioBytes = await File(audio).readAsBytes();
      merges.add(audioBytes);
      if (failMerge) return 'merge failed';
      await File(out).writeAsBytes([...await File(video).readAsBytes(), ...audioBytes]);
      return null;
    }

    // English audio saved, then the merge fails: the .audio file stays.
    expect(await run(downloader(mux: mux), output, language: 'en'), 'merge failed');
    expect(await File('$output.audio').exists(), isTrue);
    expect(merges.single, _LadderHls.whole('a_en', 12));

    // The viewer now wants Japanese: the English file must not be reused.
    failMerge = false;
    host.requests.clear();
    expect(await run(downloader(mux: mux), output, language: 'ja'), isNull);
    expect(host.requests.where((r) => r.startsWith('a_ja/')), hasLength(12));
    expect(merges.last, _LadderHls.whole('a_ja', 12));
    expect(
      await File(output).readAsBytes(),
      [..._LadderHls.whole('v1080', 12), ..._LadderHls.whole('a_ja', 12)],
    );
  });

  test('the same language reuses its finished audio file', () async {
    host.languages = ['en', 'ja'];
    final output = '${root.path}/reuse.ts';
    var failMerge = true;
    Future<String?> mux(String video, String audio, String out, String? l, bool Function() c) async {
      if (failMerge) return 'merge failed';
      await File(out).writeAsBytes([...await File(video).readAsBytes(), ...await File(audio).readAsBytes()]);
      return null;
    }

    expect(await run(downloader(mux: mux), output, language: 'en'), 'merge failed');
    failMerge = false;
    host.requests.clear();
    expect(await run(downloader(mux: mux), output, language: 'en'), isNull);
    expect(host.requests, isEmpty);
  });

  test('a web page in place of a segment is fetched again, never saved', () async {
    final output = '${root.path}/portal.ts';
    var pages = 0;
    host.webPage = (track, i) => i == 4 && pages++ < 2;
    expect(await run(downloader(), output), isNull);
    expect(pages, 3);
    expect(await File(output).readAsBytes(), _LadderHls.whole('v1080', 12));
  });

  test('a 204 answer fails the segment instead of spinning', () async {
    final output = '${root.path}/empty.ts';
    host.status = (track, i) => i == 3 ? 204 : null;
    final clock = Stopwatch()..start();
    expect(await run(downloader(), output), 'segment 4/12 unreachable');
    expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
  });

  test('pause ends a request stuck on a dead link at once', () async {
    final output = '${root.path}/stuck.ts';
    final never = Completer<void>();
    host.hold = (track, i) => i == 5 ? never.future : null;
    var pause = false;
    final transfer = run(downloader(), output, paused: () => pause);
    while (!host.requests.contains('v1080/5')) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final clock = Stopwatch()..start();
    pause = true;
    expect(await transfer, HlsDownloader.pausedResult);
    // The test Dio has no timeouts: only the pause can end that request.
    expect(clock.elapsed, lessThan(const Duration(seconds: 3)));
    expect(jsonDecode(await File('$output.part.json').readAsString())['next'], 5);
  });

  test('a finished file that cannot take its name yet is kept for later', () async {
    final output = '${root.path}/locked.ts';
    // An older copy is open (a player), so the rename cannot replace it.
    await File(output).writeAsBytes([1, 2, 3]);
    final open = await File(output).open();
    String? first;
    try {
      first = await run(downloader(), output);
    } finally {
      await open.close();
    }
    if (first == null) {
      // This system lets a rename replace an open file: nothing to keep.
      expect(await File(output).readAsBytes(), _LadderHls.whole('v1080', 12));
      return;
    }
    expect(first, HlsDownloader.finishLaterResult);
    expect(await HlsDownloader.hasResumableProgress(output), isTrue);

    host.requests.clear();
    expect(await run(downloader(), output), isNull);
    expect(host.requests, isEmpty); // only renamed, nothing fetched again
    expect(await File(output).readAsBytes(), _LadderHls.whole('v1080', 12));
  });

  test('a half file from the old app version goes once new bytes arrive', () async {
    final output = '${root.path}/legacy.ts';
    await File(output).writeAsBytes(List<int>.filled(5000, 7));
    var pause = false;
    final result = await run(
      downloader(),
      output,
      discardStaleOutput: true,
      paused: () => pause,
      onProgress: (p) {
        if (p >= 3 / 12) pause = true;
      },
    );
    expect(result, HlsDownloader.pausedResult);
    // Not left looking like a finished episode next to the new partial.
    expect(await File(output).exists(), isFalse);
    expect(await File('$output.part').exists(), isTrue);
  });

  test('without the flag a file at the final name is left alone', () async {
    final output = '${root.path}/owned.ts';
    await File(output).writeAsBytes(List<int>.filled(50, 7));
    var pause = false;
    await run(
      downloader(),
      output,
      paused: () => pause,
      onProgress: (p) {
        if (p >= 3 / 12) pause = true;
      },
    );
    expect(await File(output).readAsBytes(), List<int>.filled(50, 7));
  });
}
