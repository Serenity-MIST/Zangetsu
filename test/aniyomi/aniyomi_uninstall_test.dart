import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/aniyomi/aniyomi_extension_service.dart';
import 'package:watch_app/core/desktop/desktop_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('aniyomi-uninstall');
    Hive.init(dir.path);
    await Hive.openBox<dynamic>(AniyomiExtensionService.installedBoxName);
  });
  tearDown(() async {
    DesktopStorage.root = null;
    DesktopStorage.previousRoot = null;
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test(
    'uninstall removes APK and metadata so cold start cannot resurrect it',
    () async {
      final apk = File('${dir.path}/example.apk')..writeAsStringSync('archive');
      final box = Hive.box<dynamic>(AniyomiExtensionService.installedBoxName);
      await box.put('example', apk.path);
      expect(await AniyomiExtensionService.uninstall('example'), isNull);
      expect(await apk.exists(), isFalse);
      expect(box.containsKey('example'), isFalse);
    },
  );

  test('missing metadata falls back to the conventional APK', () async {
    final apk = File('${dir.path}/example.apk')..writeAsStringSync('archive');
    expect(
      await AniyomiExtensionService.uninstall('example', aniyomiDir: dir),
      isNull,
    );
    expect(await apk.exists(), isFalse);
  });

  test('migrated uninstall keeps old recovery APK intact', () async {
    DesktopStorage.root = '${dir.path}/new';
    DesktopStorage.previousRoot = '${dir.path}/old';
    final old = File('${dir.path}/old/AppData/aniyomi/example.apk');
    final moved = File('${dir.path}/new/AppData/aniyomi/example.apk');
    await old.parent.create(recursive: true);
    await moved.parent.create(recursive: true);
    await old.writeAsString('backup');
    await moved.writeAsString('active');
    await Hive.box<dynamic>(
      AniyomiExtensionService.installedBoxName,
    ).put('example', old.path);
    expect(await AniyomiExtensionService.uninstall('example'), isNull);
    expect(await moved.exists(), isFalse);
    expect(await old.readAsString(), 'backup');
  }, skip: !Platform.isWindows);
}
