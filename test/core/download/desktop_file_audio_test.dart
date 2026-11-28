import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/desktop_file_audio.dart';

/// Real codec fixtures prove file track selection rather than trusting labels.
void main() {
  final engine = Platform.environment['ZANGETSU_TEST_FFMPEG'];
  final enabled = Platform.isWindows && engine != null;
  late Directory root;
  late String source;
  late DesktopFileAudio selector;

  Future<ProcessResult> run(List<String> args, {bool binary = false}) =>
      Process.run(engine!, [
        '-nostdin',
        '-hide_banner',
        '-loglevel',
        'error',
        ...args,
      ], stdoutEncoding: binary ? null : utf8);

  Future<List<dynamic>> audio(String path) async {
    final result =
        await Process.run('${File(engine!).parent.path}/ffprobe.exe', [
          '-v',
          'error',
          '-select_streams',
          'a',
          '-show_streams',
          '-of',
          'json',
          path,
        ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    return (jsonDecode(result.stdout as String) as Map)['streams'] as List;
  }

  setUp(() async {
    if (!enabled) return;
    root = await Directory.systemTemp.createTemp('direct-audio-media-');
    source = '${root.path}/original.mkv';
    selector = DesktopFileAudio(engineDirectory: File(engine).parent.path);
    final generated = await run([
      '-f',
      'lavfi',
      '-i',
      'color=c=blue:s=160x96:r=24:d=1',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=880:duration=1',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=440:duration=1',
      '-map',
      '0:v',
      '-map',
      '1:a',
      '-map',
      '2:a',
      '-c:v',
      'libx264',
      '-pix_fmt',
      'yuv420p',
      '-c:a',
      'aac',
      '-metadata:s:a:0',
      'language=jpn',
      '-metadata:s:a:1',
      'language=eng',
      '-disposition:a:0',
      'default',
      '-disposition:a:1',
      '0',
      source,
    ]);
    expect(generated.exitCode, 0, reason: '${generated.stderr}');
  });
  tearDown(() async {
    if (enabled) await root.delete(recursive: true);
  });

  for (final extension in ['mkv', 'mp4']) {
    for (final selection in [('en', 'eng', 440), ('ja', 'jpn', 880)]) {
      test(
        'selects ${selection.$1} from Japanese-default $extension file',
        () async {
          if (extension == 'mp4') {
            final mp4 = '${root.path}/input.mp4';
            final converted = await run([
              '-i',
              source,
              '-map',
              '0',
              '-c',
              'copy',
              mp4,
            ]);
            expect(converted.exitCode, 0, reason: '${converted.stderr}');
            source = mp4;
          }
          expect(
            await selector.finalize(source, selection.$1, () => false),
            isNull,
          );
          final streams = await audio(source);
          expect(streams, hasLength(1));
          expect((streams.single['tags'] as Map)['language'], selection.$2);
          expect((streams.single['disposition'] as Map)['default'], 1);
          final decoded = await run([
            '-i',
            source,
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
          ], binary: true);
          expect(decoded.exitCode, 0, reason: '${decoded.stderr}');
          final data = ByteData.sublistView(
            Uint8List.fromList(decoded.stdout as List<int>),
          );
          var crossings = 0;
          for (var offset = 2; offset < data.lengthInBytes; offset += 2) {
            final before = data.getInt16(offset - 2, Endian.little);
            final after = data.getInt16(offset, Endian.little);
            if ((before < 0 && after >= 0) || (before >= 0 && after < 0)) {
              crossings++;
            }
          }
          expect(
            crossings * 8000 / data.lengthInBytes,
            closeTo(selection.$3, 12),
          );
          expect(root.listSync().whereType<Directory>(), isEmpty);
        },
        skip: !enabled
            ? 'Explicit Windows FFmpeg+ffprobe media fixture required'
            : false,
      );
    }
  }

  test('unavailable language preserves the original bytes', () async {
    final before = await File(source).readAsBytes();
    expect(
      await selector.finalize(source, 'fr', () => false),
      contains('(fr) is unavailable'),
    );
    expect(await File(source).readAsBytes(), before);
    expect(await audio(source), hasLength(2));
  }, skip: !enabled);

  test('cancel and unset language preserve the original bytes', () async {
    final before = await File(source).readAsBytes();
    expect(await selector.finalize(source, 'en', () => true), 'canceled');
    expect(await selector.finalize(source, null, () => false), isNull);
    expect(await File(source).readAsBytes(), before);
    expect(root.listSync().whereType<Directory>(), isEmpty);
  }, skip: !enabled);

  test('missing engine is explicit and leaves original intact', () async {
    final before = await File(source).readAsBytes();
    final missing = DesktopFileAudio(engineDirectory: '${root.path}/absent');
    expect(
      await missing.finalize(source, 'en', () => false),
      contains('engine is unavailable'),
    );
    expect(await File(source).readAsBytes(), before);
  }, skip: !enabled);
}
