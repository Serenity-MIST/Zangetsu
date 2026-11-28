import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/desktop/cloudstream_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('cs-storage-migration');
    Hive.init(dir.path);
  });
  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test(
    'migrated plugin record and uninstall use new AppData, preserve old backup',
    () async {
      final old = File('${dir.path}/old/AppData/cloudstream/plugins/a.cs3');
      final moved = File('${dir.path}/new/AppData/cloudstream/plugins/a.cs3');
      await old.parent.create(recursive: true);
      await moved.parent.create(recursive: true);
      await old.writeAsString('old backup');
      await moved.writeAsString('active archive');
      final box = await Hive.openBox<dynamic>('desktop_cs_plugins');
      await box.put('a', {
        'id': 'a',
        'internalName': 'a',
        'repoUrl': 'repo',
        'path': old.path,
        'providers': [
          {'name': 'Test'},
        ],
      });
      final runtime = DesktopCloudStream(
        dataDirectory: dir,
        relocatePluginPath: (path) => path == old.path ? moved.path : path,
      );
      expect(await runtime.call('listSources'), hasLength(1));
      expect((box.get('a') as Map)['path'], moved.path);
      await runtime.call('uninstallPlugin', {
        'internalName': 'a',
        'repoUrl': 'repo',
      });
      expect(await moved.exists(), isFalse);
      expect(await old.readAsString(), 'old backup');
      expect(box.containsKey('a'), isFalse);
      await runtime.dispose();
    },
  );

  test(
    'missing migration target retains recoverable original plugin record',
    () async {
      final old = File('${dir.path}/old.cs3');
      await old.writeAsString('original');
      final box = await Hive.openBox<dynamic>('desktop_cs_plugins');
      await box.put('a', {'id': 'a', 'path': old.path, 'providers': []});
      final runtime = DesktopCloudStream(
        dataDirectory: dir,
        relocatePluginPath: (_) => '${dir.path}/not-copied.cs3',
      );
      await runtime.call('listSources');
      expect((box.get('a') as Map)['path'], old.path);
      expect(await old.exists(), isTrue);
      await runtime.dispose();
    },
  );
}
