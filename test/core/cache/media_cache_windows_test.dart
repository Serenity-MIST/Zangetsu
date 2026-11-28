// Windows cache rules: only the app-owned AppData\Temp folder is ever
// measured or cleared — never the shared %TEMP% folder, even when the app
// data folder is unknown — and the poster cache size is reported accurately.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:watch_app/core/cache/media_cache.dart';
import 'package:watch_app/core/desktop/desktop_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Directory sharedTemp;

  setUp(() {
    root = Directory.systemTemp.createTempSync('media_cache_root_');
    sharedTemp = Directory.systemTemp.createTempSync('media_cache_shared_');
    // path_provider would answer with the shared temp folder.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => sharedTemp.path,
        );
    MediaCache.debugIsWindows = true;
  });

  tearDown(() {
    MediaCache.debugIsWindows = null;
    DesktopStorage.root = null;
    for (final d in [root, sharedTemp]) {
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
  });

  void write(String path, int bytes) =>
      (File(path)..createSync(recursive: true)).writeAsBytesSync(
        List.filled(bytes, 1),
      );

  test('the Windows cache folder is AppData\\Temp under the app root', () {
    expect(windowsAppCacheDirs(null), isEmpty);
    expect(windowsAppCacheDirs(r'C:\Data'), [
      p.join(r'C:\Data', 'AppData', 'Temp'),
    ]);
  });

  test('unknown app root: measures 0 and never deletes shared temp', () async {
    DesktopStorage.root = null;
    final foreign = p.join(sharedTemp.path, 'other-program.tmp');
    write(foreign, 2048);
    expect(await MediaCache.sizeBytes(), 0);
    await MediaCache.clearDirectories(
      windowsAppCacheDirs(DesktopStorage.root).map(Directory.new).toList(),
    );
    expect(File(foreign).existsSync(), isTrue);
  });

  test('measures and clears only the app-owned temp folder', () async {
    DesktopStorage.root = root.path;
    final temp = windowsAppCacheDirs(root.path).single;
    write(p.join(temp, 'libCachedImageData', 'poster.jpg'), 3000);
    write(p.join(temp, 'subs', 'a.srt'), 1000);
    final foreign = p.join(sharedTemp.path, 'other-program.tmp');
    write(foreign, 5000);
    // Data next to the cache (settings, database) must survive.
    final database = p.join(root.path, 'AppData', 'database', 'box.hive');
    write(database, 700);

    expect(await MediaCache.sizeBytes(), 4000);
    expect(await MediaCache.imageCacheBytes(), 3000);

    await MediaCache.clearDirectories([Directory(temp)]);
    expect(await MediaCache.sizeBytes(), 0);
    expect(Directory(temp).existsSync(), isTrue);
    expect(File(foreign).existsSync(), isTrue);
    expect(File(database).existsSync(), isTrue);
  });

  test('clearImageCache empties only the poster folder', () async {
    DesktopStorage.root = root.path;
    final temp = windowsAppCacheDirs(root.path).single;
    write(p.join(temp, 'libCachedImageData', 'poster.jpg'), 3000);
    write(p.join(temp, 'subs', 'a.srt'), 1000);
    await MediaCache.clearImageCache();
    expect(await MediaCache.imageCacheBytes(), 0);
    expect(File(p.join(temp, 'subs', 'a.srt')).existsSync(), isTrue);
  });

  test('formatBytes reads naturally from bytes to gigabytes', () {
    expect(MediaCache.formatBytes(0), '0 B');
    expect(MediaCache.formatBytes(2048), '2 KB');
    expect(MediaCache.formatBytes(5 * 1024 * 1024), '5.0 MB');
    expect(MediaCache.formatBytes(3 * 1024 * 1024 * 1024), '3.00 GB');
  });
}
