import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/hls_downloader.dart';
import 'package:watch_app/core/download/desktop_audio_mux.dart';

const _master = '''#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="main",NAME="Japanese",LANGUAGE="ja",DEFAULT=YES,URI="jp.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="main",NAME="English",LANGUAGE="en",DEFAULT=NO,URI="en.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=160x90,AUDIO="main"
video.m3u8
''';

/// Fixture transport records actual requested audio while keeping auth headers.
class _Media implements HttpClientAdapter {
  final payloads = <String, List<int>>{};
  final requested = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(RequestOptions options, _, _) async {
    requested.add(options);
    final name = options.uri.pathSegments.last;
    if (name == 'master.m3u8') return ResponseBody.fromString(_master, 200);
    if (name.endsWith('.m3u8')) {
      return ResponseBody.fromString(
        '#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:1,\n${name.replaceAll('.m3u8', '.ts')}\n#EXT-X-ENDLIST',
        200,
      );
    }
    return ResponseBody.fromBytes(
      payloads[name] ?? List.filled(188, 0x47),
      200,
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory root;
  late _Media host;
  late Dio client;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('hls-audio-download-');
    host = _Media();
    client = Dio()..httpClientAdapter = host;
  });
  tearDown(() async {
    client.close(force: true);
    await root.delete(recursive: true);
  });
  Future<String?> download(HlsAudioMux? mux, {bool Function()? canceled}) =>
      HlsDownloader(client, muxAudio: mux).download(
        url: 'https://fixture.test/master.m3u8',
        headers: {'Referer': 'fixture'},
        outputPath: '${root.path}/result.ts',
        preferredQuality: 'best',
        preferredAudioLanguage: 'en',
        onProgress: (_) {},
        canceled: canceled ?? () => false,
      );

  test(
    'downloads English rendition only and merges with authenticated headers',
    () async {
      var merges = 0;
      final error = await download((
        video,
        audio,
        output,
        language,
        canceled,
      ) async {
        merges++;
        expect(await File(video).length(), greaterThan(0));
        expect(await File(audio).length(), greaterThan(0));
        expect(language, 'en');
        await File(output).writeAsBytes([1, 2, 3]);
        return null;
      });
      expect(error, isNull);
      expect(merges, 1);
      expect(host.requested.any((r) => r.path.endsWith('/en.ts')), isTrue);
      expect(host.requested.any((r) => r.path.contains('/jp')), isFalse);
      expect(
        host.requested.every((r) => r.headers['Referer'] == 'fixture'),
        isTrue,
      );
      expect(await File('${root.path}/result.ts').readAsBytes(), [1, 2, 3]);
      expect(root.listSync().whereType<Directory>(), isEmpty);
    },
  );
  test('missing merge capability fails before saving silent video', () async {
    expect(await download(null), contains('merge engine'));
    expect(await File('${root.path}/result.ts').exists(), isFalse);
    expect(host.requested.any((r) => r.path.endsWith('.ts')), isFalse);
  });
  test('merge cancellation cleans video and temporary audio', () async {
    var canceled = false;
    final error = await download((video, audio, output, language, check) async {
      canceled = true;
      return 'canceled';
    }, canceled: () => canceled);
    expect(error, 'canceled');
    expect(root.listSync(), isEmpty);
  });

  final executable = Platform.environment['ZANGETSU_TEST_FFMPEG'];
  test(
    'actual merged media contains selected English tone and no Japanese track',
    () async {
      Future<void> generate(List<String> args) async {
        final result = await Process.run(executable!, [
          '-nostdin',
          '-hide_banner',
          '-loglevel',
          'error',
          '-y',
          ...args,
        ]);
        expect(result.exitCode, 0, reason: '${result.stderr}');
      }

      final video = '${root.path}/video.ts';
      final english = '${root.path}/en.ts';
      final japanese = '${root.path}/jp.ts';
      await generate([
        '-f',
        'lavfi',
        '-i',
        'color=c=black:s=160x90:r=10:d=1',
        '-an',
        '-c:v',
        'libx264',
        '-f',
        'mpegts',
        video,
      ]);
      await generate([
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=440:duration=1',
        '-c:a',
        'aac',
        '-metadata:s:a:0',
        'language=eng',
        '-f',
        'mpegts',
        english,
      ]);
      await generate([
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=880:duration=1',
        '-c:a',
        'aac',
        '-metadata:s:a:0',
        'language=jpn',
        '-f',
        'mpegts',
        japanese,
      ]);
      host.payloads['video.ts'] = await File(video).readAsBytes();
      host.payloads['en.ts'] = await File(english).readAsBytes();
      host.payloads['jp.ts'] = await File(japanese).readAsBytes();
      expect(
        await download(DesktopAudioMux(executablePath: executable).merge),
        isNull,
      );
      final output = '${root.path}/result.ts';
      final decoded = await Process.run(executable!, [
        '-nostdin',
        '-hide_banner',
        '-loglevel',
        'error',
        '-i',
        output,
        '-ss',
        '0.1',
        '-t',
        '0.5',
        '-map',
        '0:a:0',
        '-f',
        's16le',
        '-ar',
        '8000',
        '-ac',
        '1',
        'pipe:1',
      ], stdoutEncoding: null);
      expect(decoded.exitCode, 0, reason: '${decoded.stderr}');
      final data = ByteData.sublistView(
        Uint8List.fromList(decoded.stdout as List<int>),
      );
      var crossings = 0;
      for (var offset = 2; offset < data.lengthInBytes; offset += 2) {
        final before = data.getInt16(offset - 2, Endian.little);
        final after = data.getInt16(offset, Endian.little);
        if ((before < 0 && after >= 0) || (before >= 0 && after < 0))
          crossings++;
      }
      final frequency = crossings * 8000 / data.lengthInBytes;
      expect(frequency, closeTo(440, 12));
      final inspect = await Process.run(executable!, [
        '-nostdin',
        '-hide_banner',
        '-i',
        output,
        '-map',
        '0',
        '-c',
        'copy',
        '-f',
        'null',
        '-',
      ]);
      expect(inspect.stderr.toString(), contains('(eng): Audio'));
      final extra = await Process.run(executable!, [
        '-nostdin',
        '-hide_banner',
        '-i',
        output,
        '-map',
        '0:a:1',
        '-f',
        'null',
        '-',
      ]);
      expect(extra.exitCode, isNot(0));
      expect(extra.stderr.toString(), contains('matches no streams'));
    },
    skip: executable == null || !Platform.isWindows
        ? 'Explicit Windows FFmpeg media fixture required'
        : false,
  );
}
