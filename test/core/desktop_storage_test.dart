import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as p;
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
  test(
    'standard AppData migration retains originals, cookies, backups and download location',
    () async {
      final temp = await Directory.systemTemp.createTemp('standard-storage');
      try {
        final old = Directory('${temp.path}/chosen/AppData');
        final support = Directory('${temp.path}/system/Zangetsu');
        await old.create(recursive: true);
        await support.create(recursive: true);
        final db = File('${old.path}/database/library.hive');
        await db.parent.create();
        await db.writeAsString('library-43');
        final cookie = File('${old.path}/browser/Profile/Cookies');
        await cookie.parent.create(recursive: true);
        await cookie.writeAsString('cookie-bytes');
        await File(
          '${old.path}/shared_preferences.json',
        ).writeAsString('active-session');
        final backup = File('${temp.path}/chosen/Backups/backup.json');
        await backup.parent.create();
        await backup.writeAsString('backup');
        final download = File('${temp.path}/chosen/Downloads/movie.mp4');
        await download.parent.create();
        await download.writeAsBytes([1, 2, 3]);
        final pointer = File('${support.path}/storage-root.json');
        await pointer.writeAsString(
          jsonEncode({'root': '${temp.path}/chosen'}),
        );
        await DesktopStorage.prepare(
          supportPath: support.path,
          systemDownloadsPath: '${temp.path}/Downloads',
        );
        expect(
          await File(
            '${support.path}/AppData/database/library.hive',
          ).readAsString(),
          'library-43',
        );
        expect(
          await File(
            '${support.path}/AppData/browser/Profile/Cookies',
          ).readAsString(),
          'cookie-bytes',
        );
        expect(
          await File('${support.path}/Backups/backup.json').readAsString(),
          'backup',
        );
        expect(await db.exists(), true);
        expect(
          await File('${support.path}/shared_preferences.json').readAsString(),
          'active-session',
        );
        expect(await download.readAsBytes(), [1, 2, 3]);
        expect(
          p.normalize(DesktopStorage.downloadsRoot!),
          p.normalize(download.parent.path),
        );
        // Subsequent starts use the activated data, not the retained old copy.
        await db.writeAsString('stale-original');
        await DesktopStorage.prepare(
          supportPath: support.path,
          systemDownloadsPath: '${temp.path}/Downloads',
        );
        expect(
          await File(
            '${support.path}/AppData/database/library.hive',
          ).readAsString(),
          'library-43',
        );
      } finally {
        DesktopStorage.previousRoot = null;
        DesktopStorage.root = null;
        DesktopStorage.downloadsRoot = null;
        await temp.delete(recursive: true);
      }
    },
  );

  test(
    'interrupted routing commit restores previous pointer and backs up conflicting data',
    () async {
      final temp = await Directory.systemTemp.createTemp('interrupted-storage');
      try {
        final support = Directory('${temp.path}/system');
        await support.create();
        final old = File('${temp.path}/chosen/AppData/database.hive');
        await old.parent.create(recursive: true);
        await old.writeAsString('current');
        final target = File('${support.path}/AppData/database.hive');
        await target.parent.create();
        await target.writeAsString('older');
        await File(
          '${support.path}/storage-root.json.previous',
        ).writeAsString(jsonEncode({'root': '${temp.path}/chosen'}));
        await DesktopStorage.prepare(
          supportPath: support.path,
          systemDownloadsPath: '${temp.path}/Downloads',
        );
        expect(await target.readAsString(), 'current');
        expect(
          await File(
            '${support.path}/MigrationBackups/database.hive',
          ).readAsString(),
          'older',
        );
        expect(
          jsonDecode(
            await File('${support.path}/storage-root.json').readAsString(),
          )['version'],
          2,
        );
      } finally {
        DesktopStorage.previousRoot = null;
        DesktopStorage.root = null;
        DesktopStorage.downloadsRoot = null;
        await temp.delete(recursive: true);
      }
    },
  );

  test(
    'fresh install uses standard AppData and independent Downloads without a picker',
    () async {
      final temp = await Directory.systemTemp.createTemp('fresh-storage');
      try {
        await DesktopStorage.prepare(
          supportPath: '${temp.path}/Roaming/Zangetsu',
          systemDownloadsPath: '${temp.path}/Downloads',
        );
        expect(DesktopStorage.root, '${temp.path}/Roaming/Zangetsu');
        expect(Directory('${DesktopStorage.root}/AppData').existsSync(), true);
        expect(
          p.normalize(DesktopStorage.downloadsRoot!),
          p.normalize('${temp.path}/Downloads/Zangetsu'),
        );
      } finally {
        DesktopStorage.previousRoot = null;
        DesktopStorage.root = null;
        DesktopStorage.downloadsRoot = null;
        await temp.delete(recursive: true);
      }
    },
  );

  test(
    'unavailable old data stops migration without activating empty data',
    () async {
      final temp = await Directory.systemTemp.createTemp('missing-storage');
      try {
        final pointer = File('${temp.path}/storage-root.json');
        await pointer.writeAsString(
          jsonEncode({'root': '${temp.path}/missing'}),
        );
        await expectLater(
          DesktopStorage.prepare(
            supportPath: temp.path,
            systemDownloadsPath: '${temp.path}/Downloads',
          ),
          throwsStateError,
        );
        expect(jsonDecode(await pointer.readAsString())['version'], isNull);
      } finally {
        await temp.delete(recursive: true);
      }
    },
  );
  test(
    'migration rebase affects app-owned plugin paths but never downloads',
    () {
      DesktopStorage.root = p.absolute('standard');
      DesktopStorage.previousRoot = p.absolute('chosen');
      try {
        final oldPlugin = p.join(
          DesktopStorage.previousRoot!,
          'AppData',
          'cloudstream',
          'plugins',
          'provider.cs3',
        );
        expect(
          DesktopStorage.relocatedAppPath(oldPlugin),
          p.join(
            DesktopStorage.root!,
            'AppData',
            'cloudstream',
            'plugins',
            'provider.cs3',
          ),
        );
        final download = p.join(
          DesktopStorage.previousRoot!,
          'Downloads',
          'episode.mp4',
        );
        expect(DesktopStorage.relocatedAppPath(download), download);
        expect(
          DesktopStorage.relocatedAppPath('https://example.test/file'),
          'https://example.test/file',
        );
      } finally {
        DesktopStorage.root = null;
        DesktopStorage.previousRoot = null;
      }
    },
  );
  test(
    'unavailable download destination does not block an existing app library',
    () async {
      final temp = await Directory.systemTemp.createTemp('offline-downloads');
      try {
        final unavailable = File('${temp.path}/not-a-directory');
        await unavailable.writeAsString('file');
        await File('${temp.path}/storage-root.json').writeAsString(
          jsonEncode({
            'version': 2,
            'root': temp.path,
            'downloadsRoot': '${unavailable.path}/Downloads',
          }),
        );
        await DesktopStorage.prepare(
          supportPath: temp.path,
          systemDownloadsPath: '${temp.path}/Downloads',
        );
        expect(DesktopStorage.root, temp.path);
        expect(DesktopStorage.downloadsRoot, '${unavailable.path}/Downloads');
      } finally {
        DesktopStorage.root = null;
        DesktopStorage.downloadsRoot = null;
        DesktopStorage.previousRoot = null;
        await temp.delete(recursive: true);
      }
    },
  );
}
