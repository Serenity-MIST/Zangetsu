import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:watch_app/core/download/desktop_download_recovery.dart';
import 'package:watch_app/core/download/download_record.dart';

const name = 'The_Four_of_Us_S1E10_best_30251cdca76184b5769de3203112c7d2.ts';
void main() {
  test('identity-bearing filename preserves season and fractional episode', () {
    final parsed = DesktopSavedVideo.parse(name)!;
    expect(parsed.title, 'The Four of Us');
    expect(parsed.season, 1);
    expect(parsed.number, 10);
    expect(parsed.quality, 'best');
    expect(DesktopSavedVideo.parse(name.replaceFirst('E10_', 'E10.5_'))!.number, 10.5);
    expect(DesktopSavedVideo.parse(name.replaceFirst('S1E10_', 'E_'))!.number, isNull);
  });
  test('unowned names, scratch files and manifests cannot be imported', () {
    for (final value in ['movie.mp4', '$name.part', name.replaceAll('.ts', '.m3u8'),
      name.replaceFirst('30251cdca76184b5769de3203112c7d2', 'guess')]) {
      expect(DesktopSavedVideo.parse(value), isNull);
    }
  });
  test('local record never invents provider or language; flag survives storage/copy', () {
    final record = DesktopSavedVideo.parse(name)!.toRecord(
      File('/fixture/$name'), FileStat.statSync(Platform.resolvedExecutable), '/fixture');
    expect(record.sourceId, 'local-files');
    expect(record.category, 'unknown');
    expect(record.serverPreference, isNull);
    expect(record.recoveredFromDisk, isTrue);
    expect(DownloadRecord.fromMap(record.toMap()).copyWith().recoveredFromDisk, isTrue);
    final legacy = record.toMap()..remove('recoveredFromDisk');
    expect(DownloadRecord.fromMap(legacy).recoveredFromDisk, isFalse);
  });
  test('scan is idempotent, skips referenced media and preserves all bytes', () async {
    final root = await Directory.systemTemp.createTemp('recovery-scan-');
    try {
      final dir = Directory('${root.path}/Videos/The_Four_of_Us');
      await dir.create(recursive: true);
      final file = File('${dir.path}/$name');
      await file.writeAsBytes([1, 2, 3]);
      await File('${dir.path}/random.mp4').writeAsBytes([4]);
      var probes = 0;
      final scanner = DesktopDownloadRecovery(probe: (_) async { probes++; return true; });
      final first = await scanner.discover(roots: [root.path, root.path], known: [], canceled: () => false);
      expect(first, hasLength(1));
      expect(probes, 1);
      expect(p.equals(first.single.filePath!, file.path), isTrue);
      expect(first.single.bytesTotal, 3);
      final again = await scanner.discover(roots: [root.path], known: first, canceled: () => false);
      expect(again, isEmpty);
      expect(probes, 1);
      expect(await file.readAsBytes(), [1, 2, 3]);
    } finally { await root.delete(recursive: true); }
  });
  test('failed probe and cancellation never publish or modify a file', () async {
    final root = await Directory.systemTemp.createTemp('recovery-reject-');
    try {
      final dir = Directory('${root.path}/Videos/Show');
      await dir.create(recursive: true);
      final file = File('${dir.path}/$name');
      await file.writeAsBytes([1]);
      final scanner = DesktopDownloadRecovery(probe: (_) async => false);
      expect(await scanner.discover(roots: [root.path], known: [], canceled: () => false), isEmpty);
      expect(await scanner.discover(roots: [root.path], known: [], canceled: () => true), isEmpty);
      expect(await file.readAsBytes(), [1]);
    } finally { await root.delete(recursive: true); }
  });
}
