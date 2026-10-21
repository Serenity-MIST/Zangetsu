import 'dart:io';
import 'package:hive/hive.dart';
import 'package:watch_app/core/desktop/desktop_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/download_prefs.dart';

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp();
    Hive.init(dir.path);
    await Hive.openBox(DownloadPrefs.boxName);
  });
  tearDown(() async {
    await Hive.deleteFromDisk();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('defaults to null, round-trips a set, and clears', () async {
    final p = DownloadPrefs();
    expect(p.locationUri, isNull);
    expect(p.locationLabel, isNull);
    await p.setLocation('content://tree/primary%3ADownloads/x', 'Movies');
    expect(p.locationUri, 'content://tree/primary%3ADownloads/x');
    expect(p.locationLabel, 'Movies');
    await p.setLocation(null, null);
    expect(p.locationUri, isNull);
    expect(p.locationLabel, isNull);
  });

  test('isUriPath detects content:// paths only', () {
    expect(isUriPath('content://tree/x/doc/y'), isTrue);
    expect(isUriPath('/storage/emulated/0/Download/x.mp4'), isFalse);
  });

  test(
    'keepPrivate is mobile-only and desktop uses the chosen folder',
    () async {
      final p = DownloadPrefs();
      expect(p.keepPrivate, isFalse);
      await p.setKeepPrivate(true);
      expect(p.keepPrivate, !Platform.isWindows);
      await p.setKeepPrivate(false);
      expect(p.keepPrivate, isFalse);
    },
  );
  test(
    'AppData migration preserves the existing explicit download folder',
    () async {
      if (!Platform.isWindows) return;
      await DownloadPrefs().setLocation('D:/MyDownloads', 'My downloads');
      await Hive.box(
        DownloadPrefs.boxName,
      ).put('storageRoot', 'old-selected-root');
      await Hive.close();
      DesktopStorage.root = '${dir.path}/system';
      DesktopStorage.downloadsRoot = '${dir.path}/default-downloads';
      try {
        await DownloadPrefs.init();
        expect(DownloadPrefs().locationUri, 'D:/MyDownloads');
        expect(DownloadPrefs().locationLabel, 'My downloads');
      } finally {
        DesktopStorage.root = null;
        DesktopStorage.downloadsRoot = null;
      }
    },
  );
}
