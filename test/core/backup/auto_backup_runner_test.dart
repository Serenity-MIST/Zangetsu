// acct-10: automatic scheduled backups to a folder, and the folder helpers
// in BackupFile they use. acct-12: the timestamped names sort correctly.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/backup/auto_backup_runner.dart';
import 'package:watch_app/core/backup/backup_file.dart';
import 'package:watch_app/core/desktop/desktop_prefs.dart';

void main() {
  late Directory hiveDir;
  late Directory folder;

  setUp(() async {
    hiveDir = await Directory.systemTemp.createTemp('auto_backup_hive_');
    folder = await Directory.systemTemp.createTemp('auto_backup_out_');
    Hive.init(hiveDir.path);
    // Only the box: DesktopPrefs getters/setters work once it is open.
    await Hive.openBox<dynamic>(DesktopPrefs.boxName);
    AutoBackupRunner.debugIsWindows = true;
    AutoBackupRunner.debugBuildPayload = () async => {
      'app': 'zangetsu',
      'version': 1,
      'bundles': <String, dynamic>{},
    };
  });

  tearDown(() async {
    AutoBackupRunner.debugReset();
    await Hive.deleteFromDisk();
    for (final d in [hiveDir, folder]) {
      if (d.existsSync()) await d.delete(recursive: true);
    }
  });

  group('isDue', () {
    final now = DateTime(2026, 11, 18, 12);
    test('never run is due', () {
      expect(
        AutoBackupRunner.isDue(null, AutoBackupFrequency.weekly, now),
        isTrue,
      );
    });
    test('daily and weekly intervals', () {
      final hoursAgo = now.subtract(const Duration(hours: 23));
      final dayAgo = now.subtract(const Duration(days: 1));
      final sixDays = now.subtract(const Duration(days: 6));
      expect(
        AutoBackupRunner.isDue(hoursAgo, AutoBackupFrequency.daily, now),
        isFalse,
      );
      expect(
        AutoBackupRunner.isDue(dayAgo, AutoBackupFrequency.daily, now),
        isTrue,
      );
      expect(
        AutoBackupRunner.isDue(sixDays, AutoBackupFrequency.weekly, now),
        isFalse,
      );
    });
    test('a last run in the future (clock moved back) is due', () {
      final future = now.add(const Duration(days: 3));
      expect(
        AutoBackupRunner.isDue(future, AutoBackupFrequency.weekly, now),
        isTrue,
      );
    });
  });

  test('does nothing while turned off', () async {
    await DesktopPrefs.setAutoBackupFolder(folder.path);
    expect(await AutoBackupRunner.runIfDue(), isNull);
    expect(folder.listSync(), isEmpty);
  });

  test('writes a timestamped file, records the run, then waits', () async {
    await DesktopPrefs.setAutoBackupFolder(folder.path);
    await DesktopPrefs.setAutoBackupEnabled(true);
    final now = DateTime(2026, 11, 18, 9, 5, 12);
    final rev = AutoBackupRunner.revision.value;

    final path = await AutoBackupRunner.runIfDue(now: now);
    expect(path, isNotNull);
    expect(
      File(path!).uri.pathSegments.last,
      'zangetsu-auto-20261118-090512.json',
    );
    expect(DesktopPrefs.autoBackupLastRun, now);
    expect(AutoBackupRunner.revision.value, rev + 1);
    // No temp file left behind.
    expect(folder.listSync().where((e) => e.path.endsWith('.part')), isEmpty);

    // A day later a weekly backup is not due yet.
    final later = await AutoBackupRunner.runIfDue(
      now: now.add(const Duration(days: 1)),
    );
    expect(later, isNull);
  });

  test(
    'keeps only the last N automatic backups and never prunes others',
    () async {
      await DesktopPrefs.setAutoBackupFolder(folder.path);
      await DesktopPrefs.setAutoBackupEnabled(true);
      await DesktopPrefs.setAutoBackupFrequency(AutoBackupFrequency.daily);
      await DesktopPrefs.setAutoBackupKeep(3);
      // A manual save and a safety copy in the same folder must survive.
      File(
        '${folder.path}/zangetsu-backup-20200101-0000.json',
      ).writeAsStringSync('{}');
      File(
        '${folder.path}/zangetsu-before-restore-20200101-000000.json',
      ).writeAsStringSync('{}');

      final start = DateTime(2026, 11, 1, 8);
      for (var i = 0; i < 5; i++) {
        await AutoBackupRunner.runIfDue(now: start.add(Duration(days: i)));
      }
      final files = await BackupFile().listBackupsIn([folder.path]);
      final names = files.map((f) => f.uri.pathSegments.last).toList();
      expect(names.where((n) => n.startsWith('zangetsu-auto-')), [
        'zangetsu-auto-20261105-080000.json',
        'zangetsu-auto-20261104-080000.json',
        'zangetsu-auto-20261103-080000.json',
      ]);
      expect(names, contains('zangetsu-backup-20200101-0000.json'));
      expect(names, contains('zangetsu-before-restore-20200101-000000.json'));
    },
  );

  test('a failing build leaves the last run unset so it retries', () async {
    await DesktopPrefs.setAutoBackupFolder(folder.path);
    await DesktopPrefs.setAutoBackupEnabled(true);
    AutoBackupRunner.debugBuildPayload = () async => throw StateError('locked');
    expect(await AutoBackupRunner.runIfDue(), isNull);
    expect(DesktopPrefs.autoBackupLastRun, isNull);
  });

  test('backup names sort newest first, old minute-only names included', () {
    expect(
      timestampedBackupName('zangetsu-auto', DateTime(2026, 1, 2, 3, 4, 5)),
      'zangetsu-auto-20260102-030405.json',
    );
    expect(
      backupStamp(File('zangetsu-backup-20260702-0905.json')),
      '20260702090500',
    );
  });
}
