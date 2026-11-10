import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/file_audio_transaction.dart';

/// Durable on-disk fixtures represent each boundary where a process can stop.
void main() {
  late Directory root;
  late File target;
  late Directory scratch;
  const original = [1, 2, 3, 4];
  const selected = [5, 6, 7];

  Future<void> journal({String? backup}) =>
      File('${scratch.path}/publish.json').writeAsString(
        jsonEncode({
          'version': 1,
          'target': 'episode.mkv',
          'backup': backup ?? 'original.mkv',
          'sha256': sha256.convert(selected).toString(),
        }),
        flush: true,
      );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('audio-publish-');
    target = File('${root.path}/episode.mkv');
    await target.writeAsBytes(original, flush: true);
    scratch = await root.createTemp('.zangetsu-file-audio-');
    await File(
      '${scratch.path}/selected.mkv',
    ).writeAsBytes(selected, flush: true);
    await journal();
  });
  tearDown(() async => root.delete(recursive: true));

  test(
    'interruption before original rename retains original and is idempotent',
    () async {
      expect(await FileAudioTransaction.recover(target.path), isNull);
      expect(await target.readAsBytes(), original);
      expect(await scratch.exists(), isFalse);
      expect(await FileAudioTransaction.recover(target.path), isNull);
    },
  );

  test('interruption between renames restores original', () async {
    await target.rename('${scratch.path}/original.mkv');
    expect(await FileAudioTransaction.recover(target.path), isNull);
    expect(await target.readAsBytes(), original);
    expect(await scratch.exists(), isFalse);
  });

  test('interruption after publish keeps only verified replacement', () async {
    await target.rename('${scratch.path}/original.mkv');
    await File('${scratch.path}/selected.mkv').rename(target.path);
    expect(await FileAudioTransaction.recover(target.path), isNull);
    expect(await target.readAsBytes(), selected);
    expect(await scratch.exists(), isFalse);
  });

  test('conflicting target preserves both copies for recovery', () async {
    await target.rename('${scratch.path}/original.mkv');
    await target.writeAsBytes([99]);
    expect(
      await FileAudioTransaction.recover(target.path),
      FileAudioTransaction.recoveryError,
    );
    expect(await target.readAsBytes(), [99]);
    expect(await File('${scratch.path}/original.mkv').readAsBytes(), original);
    expect(await scratch.exists(), isTrue);
  });

  test(
    'journal path escape and malformed journal never delete media',
    () async {
      await journal(backup: '../outside.mkv');
      expect(
        await FileAudioTransaction.recover(target.path),
        FileAudioTransaction.recoveryError,
      );
      expect(await target.readAsBytes(), original);
      expect(await scratch.exists(), isTrue);
      await File('${scratch.path}/publish.json').writeAsString('{');
      expect(
        await FileAudioTransaction.recover(target.path),
        FileAudioTransaction.recoveryError,
      );
      expect(await target.readAsBytes(), original);
    },
  );

  test('unexpected files inside scratch are preserved', () async {
    final personal = File('${scratch.path}/keep-me.txt');
    await personal.writeAsString('preserve');
    expect(
      await FileAudioTransaction.recover(target.path),
      FileAudioTransaction.recoveryError,
    );
    expect(await personal.readAsString(), 'preserve');
    expect(await target.readAsBytes(), original);
  });

  test('normal publish writes replacement and cleans transaction', () async {
    expect(
      await FileAudioTransaction.publish(
        target,
        File('${scratch.path}/selected.mkv'),
        scratch,
        () => false,
      ),
      isNull,
    );
    expect(await target.readAsBytes(), selected);
    expect(await scratch.exists(), isFalse);
  });
}
