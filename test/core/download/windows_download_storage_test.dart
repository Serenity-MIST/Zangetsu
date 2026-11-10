import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/windows_download_storage.dart';

void main() {
  test('only known capacity and meaningful estimate warn', () {
    expect(downloadEstimateExceedsSpace(freeBytes: 100, estimatedBytes: 101, solid: true), isTrue);
    expect(downloadEstimateExceedsSpace(freeBytes: 0, estimatedBytes: 1, solid: true), isTrue);
    for (final free in <int?>[null, -1, 1000]) {
      expect(downloadEstimateExceedsSpace(freeBytes: free, estimatedBytes: 100, solid: true), isFalse);
    }
    expect(downloadEstimateExceedsSpace(freeBytes: 10, estimatedBytes: null, solid: true), isFalse);
    expect(downloadEstimateExceedsSpace(freeBytes: 10, estimatedBytes: 100, solid: false), isFalse);
  });
  test('native64bit volume query is read-only and handles missing child directory', () async {
    final root = await Directory.systemTemp.createTemp('zangetsu-capacity-');
    try {
      final before = root.listSync().length;
      final free = await windowsDownloadFreeBytes(root.path);
      expect(free, isNotNull);
      expect(free!, greaterThanOrEqualTo(0));
      print('Native available bytes: $free');
      final missing = Directory('${root.path}/not-created/child');
      final childFree = await windowsDownloadFreeBytes(missing.path);
      expect(childFree, isNotNull); expect(childFree!, greaterThanOrEqualTo(0));
      expect(await missing.exists(), isFalse);
      expect(root.listSync().length, before);
    } finally { await root.delete(); }
  }, skip: !Platform.isWindows);
  test('relative, URI and empty locations remain unknown', () async {
    for (final value in <String?>[null, '', 'relative/folder', 'content://fixture/tree', 'https://fixture/path']) {
      expect(await windowsDownloadFreeBytes(value), isNull);
    }
  });
}
