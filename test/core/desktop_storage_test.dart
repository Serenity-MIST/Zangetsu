import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/desktop_storage.dart';

void main() {
  test(
    'chosen-folder migration preserves library and encrypted account bytes without deleting originals',
    () async {
      final root = await Directory.systemTemp.createTemp('storage-migration');
      try {
        final old = Directory('${root.path}/old');
        await old.create();
        final db = File('${old.path}/database/my_list.hive');
        await db.parent.create();
        await db.writeAsBytes([1, 2, 3]);
        final credentials = File('${old.path}/encrypted_credentials.json');
        await credentials.writeAsString('encrypted-data');
        final selected = '${root.path}/chosen';
        await DesktopStorage.migrate(old.path, selected);
        expect(
          await File('$selected/AppData/database/my_list.hive').readAsBytes(),
          [1, 2, 3],
        );
        expect(
          await File(
            '$selected/AppData/encrypted_credentials.json',
          ).readAsString(),
          'encrypted-data',
        );
        expect(await db.exists(), true);
        await DesktopStorage.migrate(old.path, selected);
        expect(await db.exists(), true);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
}
