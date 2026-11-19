// acct-9 (the four library boxes added to file backups), acct-4 (restore
// preview summary and the safety snapshot behind 'Undo restore').
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/backup/backup_payload.dart';
import 'package:watch_app/core/backup/library_backup.dart';
import 'package:watch_app/core/backup/restore_safety.dart';
import 'package:watch_app/core/backup/settings_backup.dart';

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp();
    Hive.init(dir.path);
    // Opened with the same value types as the real stores.
    await Hive.openBox<Map>('my_list');
    await Hive.openBox('list_categories');
    await Hive.openBox<Map>('resume_positions');
    await Hive.openBox('reader_overrides');
    await Hive.openBox('tracker_bindings');
    await Hive.openBox('playback_prefs');
  });
  tearDown(() async {
    await Hive.deleteFromDisk();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  group('library extras (acct-9)', () {
    test('categories, resume points, reader overrides and tracker links '
        'round-trip through JSON', () async {
      final cats = Hive.box('list_categories');
      await cats.put('__categories__', [
        {'id': 'c1', 'name': 'Gym', 'position': 0},
      ]);
      await cats.put('src::1', ['c1']);
      await Hive.box<Map>(
        'resume_positions',
      ).put('src::1::e1', {'positionMs': 5000, 'durationMs': 9000});
      await Hive.box('reader_overrides').put('src:1', {'mode': 'rtl'});
      await Hive.box('tracker_bindings').put('src|u', {'AniList': '42'});

      // Through JSON, exactly like a file backup.
      final data =
          jsonDecode(jsonEncode(LibraryBackup().build()))
              as Map<String, dynamic>;
      for (final b in [
        'list_categories',
        'resume_positions',
        'reader_overrides',
        'tracker_bindings',
      ]) {
        await anyClear(b);
      }
      await LibraryBackup().merge(data);

      expect(cats.get('__categories__'), [
        {'id': 'c1', 'name': 'Gym', 'position': 0},
      ]);
      expect(cats.get('src::1'), ['c1']);
      expect(Hive.box<Map>('resume_positions').get('src::1::e1'), {
        'positionMs': 5000,
        'durationMs': 9000,
      });
      expect(Hive.box('reader_overrides').get('src:1'), {'mode': 'rtl'});
      expect(Hive.box('tracker_bindings').get('src|u'), {'AniList': '42'});
    });

    test('merge never removes or overwrites what this device has', () async {
      final cats = Hive.box('list_categories');
      await cats.put('__categories__', [
        {'id': 'c1', 'name': 'Renamed here', 'position': 0},
      ]);
      await cats.put('src::1', ['c1']);
      await Hive.box('reader_overrides').put('src:1', {'mode': 'ltr'});
      await Hive.box('tracker_bindings').put('src|u', {'AniList': '1'});

      await LibraryBackup().merge({
        'listCategories': {
          '__categories__': [
            {'id': 'c1', 'name': 'Old name', 'position': 3},
            {'id': 'c2', 'name': 'New', 'position': 1},
          ],
          'src::1': ['c2'],
        },
        'readerOverrides': {
          'src:1': {'mode': 'rtl', 'fit': 'width'},
        },
        'trackerBindings': {
          'src|u': {'AniList': '2', 'MAL': '9'},
        },
      });

      final rows = (cats.get('__categories__') as List).cast<Map>();
      expect(rows.map((r) => r['id']), ['c1', 'c2']);
      expect(rows.first['name'], 'Renamed here');
      expect(cats.get('src::1'), unorderedEquals(['c1', 'c2']));
      expect(Hive.box('reader_overrides').get('src:1'), {
        'mode': 'ltr',
        'fit': 'width',
      });
      expect(Hive.box('tracker_bindings').get('src|u'), {
        'AniList': '1',
        'MAL': '9',
      });
    });

    test('an old backup without the new keys merges fine', () async {
      await LibraryBackup().merge({'myList': const []});
      expect(Hive.box('list_categories').isEmpty, isTrue);
    });
  });

  group('restore preview summary (acct-4)', () {
    test('reads the date and counts what is inside', () {
      final payload = {
        'app': 'zangetsu',
        'createdAt': '2026-11-18T09:05:00.000Z',
        'bundles': {
          'library': {
            'myList': [{}, {}],
            'profileMyList': {'p:x': {}},
            'history': [{}],
            'listCategories': {
              '__categories__': [{}, {}],
              'src::1': ['c1'],
            },
          },
          'settings': {
            'playback_prefs': {},
            'theme_prefs': {},
            'zmode_matches': {'anime:1@a': {}, 'label:anime:1': {}},
          },
        },
      };
      expect(backupCreatedAt(payload), DateTime.utc(2026, 11, 18, 9, 5));
      final summary = summarizeBackup(payload);
      expect(summary.keys, {BackupBundle.library, BackupBundle.settings});
      int count(BackupBundle b, String label) =>
          summary[b]!.firstWhere((c) => c.label == label).count;
      expect(count(BackupBundle.library, 'list items'), 3);
      expect(count(BackupBundle.library, 'in Continue Watching'), 1);
      expect(count(BackupBundle.library, 'categories'), 2);
      expect(count(BackupBundle.settings, 'setting groups'), 2);
      expect(count(BackupBundle.settings, 'hand-made title matches'), 1);
    });

    test('odd payloads give an empty summary instead of throwing', () {
      expect(summarizeBackup({'bundles': 'nope'}), isEmpty);
      expect(backupCreatedAt({'createdAt': 3}), isNull);
    });
  });

  group('restore safety snapshot (acct-4 Undo restore)', () {
    test('rollback removes added entries and restores changed ones', () async {
      final prefs = Hive.box('playback_prefs');
      await prefs.put('speed', 1.0);
      final list = Hive.box<Map>('my_list');
      await list.put('a', {'id': 'a'});

      final snap = RestoreSafetySnapshot.capture(
        RestoreSafetySnapshot.boxNamesFor({
          BackupBundle.library,
          BackupBundle.settings,
        }),
      );
      expect(snap.boxNames, containsAll(['playback_prefs', 'my_list']));

      // What a restore does: overwrite a setting, add list rows.
      await prefs.put('speed', 2.0);
      await prefs.put('newKey', true);
      await list.put('b', {'id': 'b'});

      await snap.rollback();
      expect(prefs.get('speed'), 1.0);
      expect(prefs.containsKey('newKey'), isFalse);
      expect(list.keys, ['a']);
    });

    test('sources are never part of the snapshot', () {
      expect(
        RestoreSafetySnapshot.boxNamesFor({BackupBundle.sources}),
        isEmpty,
      );
      expect(
        RestoreSafetySnapshot.boxNamesFor({BackupBundle.settings}),
        contains(SettingsBackup.matchesBox),
      );
    });
  });
}

/// Clears an open box whatever value type it was opened with.
Future<void> anyClear(String name) async {
  for (final get in <Box<dynamic> Function()>[
    () => Hive.box<Map>(name),
    () => Hive.box(name),
  ]) {
    try {
      await get().clear();
      return;
    } catch (_) {}
  }
}
