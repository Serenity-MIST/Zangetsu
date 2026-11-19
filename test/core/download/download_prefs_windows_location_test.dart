// Windows download-location rules: Reset goes straight to the real default
// folder, the default is detected regardless of slash/case, and folders that
// can't be written are refused with a reason instead of being saved.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/desktop/desktop_storage.dart';
import 'package:watch_app/core/download/download_prefs.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('dl_prefs_win_');
    Hive.init(dir.path);
    await Hive.openBox(DownloadPrefs.boxName);
  });

  tearDown(() async {
    DesktopStorage.downloadsRoot = null;
    DownloadPrefs.debugPickDirectory = null;
    await Hive.deleteFromDisk();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('Reset on Windows applies Downloads\\Zangetsu immediately', () async {
    if (!Platform.isWindows) return;
    final fallback = '${dir.path}\\Downloads\\Zangetsu';
    DesktopStorage.downloadsRoot = fallback;
    final prefs = DownloadPrefs();
    await prefs.setLocation('D:\\Anime', 'D:\\Anime');
    expect(prefs.isDefaultLocation, isFalse);

    await prefs.resetToDefault();

    // Never null: the next download must not ask for a folder.
    expect(prefs.locationUri, fallback);
    expect(prefs.locationLabel, fallback);
    expect(prefs.isDefaultLocation, isTrue);
    expect(await prefs.ensureDesktopFolder(), isTrue);
  });

  test(
    'default detection ignores slash style, case and trailing slash',
    () async {
      if (!Platform.isWindows) return;
      DesktopStorage.downloadsRoot = r'C:\Users\Me\Downloads\Zangetsu';
      final prefs = DownloadPrefs();
      await prefs.setLocation('c:/users/me/downloads/zangetsu/', 'x');
      expect(prefs.isDefaultLocation, isTrue);
      await prefs.setLocation(r'C:\Users\Me\Downloads\Zangetsu2', 'x');
      expect(prefs.isDefaultLocation, isFalse);
    },
  );

  test('choosing a writable folder saves it and clears private mode', () async {
    final chosen = '${dir.path}${Platform.pathSeparator}picked';
    DownloadPrefs.debugPickDirectory = () async => chosen;
    final prefs = DownloadPrefs();
    expect(await prefs.chooseDesktopFolder(), isTrue);
    expect(prefs.lastFolderError, isNull);
    expect(prefs.locationUri, chosen);
    expect(Directory(chosen).existsSync(), isTrue);
    // The write probe leaves nothing behind.
    expect(Directory(chosen).listSync(), isEmpty);
  });

  test('an unwritable folder is refused with a reason', () async {
    // A path "inside" a regular file can never be created or written.
    final file = File('${dir.path}${Platform.pathSeparator}not-a-folder')
      ..writeAsStringSync('x');
    final bad = '${file.path}${Platform.pathSeparator}sub';
    DownloadPrefs.debugPickDirectory = () async => bad;
    final prefs = DownloadPrefs();
    await prefs.setLocation('D:\\Keep', 'D:\\Keep');
    expect(await prefs.chooseDesktopFolder(), isFalse);
    expect(prefs.lastFolderError, contains(bad));
    expect(prefs.locationUri, 'D:\\Keep');
  });

  test('cancelling the picker changes nothing and reports no error', () async {
    DownloadPrefs.debugPickDirectory = () async => null;
    final prefs = DownloadPrefs();
    await prefs.setLocation('D:\\Keep', 'D:\\Keep');
    expect(await prefs.chooseDesktopFolder(), isFalse);
    expect(prefs.lastFolderError, isNull);
    expect(prefs.locationUri, 'D:\\Keep');
  });
}
