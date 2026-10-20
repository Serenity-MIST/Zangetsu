import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/hive/safe_box.dart';

void main() {
  test(
    'moving a requested database preserves bytes and leaves unrelated files',
    () async {
      final root = await Directory.systemTemp.createTemp('zangetsu-migration-');
      addTearDown(() => root.delete(recursive: true));
      final old = Directory('${root.path}/documents')..createSync();
      final target = Directory('${root.path}/appdata')..createSync();
      await File('${old.path}/my_list.hive').writeAsString('library contents');
      await File('${old.path}/another_app.hive').writeAsString('other app');
      await migrateLegacyBox('my_list', old.path, target.path);
      expect(
        await File('${target.path}/my_list.hive').readAsString(),
        'library contents',
      );
      expect(await File('${old.path}/my_list.hive').exists(), isFalse);
      expect(
        await File('${old.path}/another_app.hive').readAsString(),
        'other app',
      );
    },
  );
  test(
    'existing library is preserved and legacy data becomes a backup',
    () async {
      final root = await Directory.systemTemp.createTemp('zangetsu-migration-');
      addTearDown(() => root.delete(recursive: true));
      final old = Directory('${root.path}/documents')..createSync();
      final target = Directory('${root.path}/appdata')..createSync();
      await File('${old.path}/my_list.hive').writeAsString('legacy');
      await File('${target.path}/my_list.hive').writeAsString('current');
      await migrateLegacyBox('my_list', old.path, target.path);
      expect(
        await File('${target.path}/my_list.hive').readAsString(),
        'current',
      );
      final backup =
          (await Directory(
                '${target.path}/legacy-backup',
              ).list().toList()).single
              as File;
      expect(await backup.readAsString(), 'legacy');
    },
  );
}
