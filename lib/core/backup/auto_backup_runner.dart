import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../desktop/desktop_prefs.dart';
import '../desktop/desktop_storage.dart';
import '../di/injector.dart';
import 'backup_file.dart';
import 'backup_payload.dart';
import 'backup_service.dart';

/// Automatic scheduled backups to a folder on Windows (acct-10 Option A).
///
/// Settings live in [DesktopPrefs] (the Backup page's AutoBackupSettingsPanel
/// edits them). [runIfDue] is called once after launch: when automatic
/// backups are on and the last one is older than the chosen interval, it
/// writes a timestamped `zangetsu-auto-*.json` into the chosen folder (for
/// example a OneDrive folder), deletes the oldest automatic ones beyond
/// 'keep last N', and records the run time.
abstract final class AutoBackupRunner {
  /// File-name prefix of automatic backups. Only these are pruned.
  static const String autoPrefix = 'zangetsu-auto';

  /// File-name prefix of the safety copy saved before a restore.
  static const String safetyPrefix = 'zangetsu-before-restore';

  /// Bumped whenever a backup file is written here, so the Backup page can
  /// refresh its list of backups.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Test hook: builds the payload instead of the real BackupService.
  @visibleForTesting
  static Future<Map<String, dynamic>> Function()? debugBuildPayload;

  /// Test hook: forces the Windows check (tests run on a Windows host anyway).
  @visibleForTesting
  static bool? debugIsWindows;

  /// The run in progress, so a second call while one runs joins it instead
  /// of writing a duplicate file.
  static Future<String?>? _running;

  static bool get _isWindows => debugIsWindows ?? Platform.isWindows;

  /// Whether a backup is due: never run, or the last run is at least one
  /// interval ago. A last run in the future (clock moved back) counts as due
  /// so a wrong clock can't stop backups for good.
  static bool isDue(
    DateTime? lastRun,
    AutoBackupFrequency frequency,
    DateTime now,
  ) {
    if (lastRun == null || lastRun.isAfter(now)) return true;
    final interval = switch (frequency) {
      AutoBackupFrequency.daily => const Duration(days: 1),
      AutoBackupFrequency.weekly => const Duration(days: 7),
    };
    return now.difference(lastRun) >= interval;
  }

  /// Folders the Backup page lists backups from: the automatic-backup folder
  /// and the app's own Backups folder (where safety copies go when no
  /// automatic folder is set).
  static List<String> listedFolders() => [
    ?DesktopPrefs.autoBackupFolder,
    ?_appBackupsFolder(),
  ];

  /// Where the safety copy before a restore is written: the automatic-backup
  /// folder when set, else the app's own Backups folder. Null when neither
  /// is known (only in tests without storage).
  static String? safetyFolder() =>
      DesktopPrefs.autoBackupFolder ?? _appBackupsFolder();

  static String? _appBackupsFolder() {
    final root = DesktopStorage.root;
    return root == null ? null : '$root${Platform.pathSeparator}Backups';
  }

  /// Runs an automatic backup when one is due. Never throws: a failure is
  /// logged and retried on the next launch (the last-run time is only set
  /// after a successful write). Returns the written path, or null.
  static Future<String?> runIfDue({DateTime? now}) {
    final running = _running;
    if (running != null) return running;
    final run = _runIfDue(now ?? DateTime.now());
    _running = run;
    return run.whenComplete(() => _running = null);
  }

  static Future<String?> _runIfDue(DateTime now) async {
    if (!_isWindows || !DesktopPrefs.autoBackupEnabled) return null;
    final folder = DesktopPrefs.autoBackupFolder;
    if (folder == null) return null;
    if (!isDue(
      DesktopPrefs.autoBackupLastRun,
      DesktopPrefs.autoBackupFrequency,
      now,
    )) {
      return null;
    }
    try {
      final payload = await _buildPayload();
      final file = BackupFile();
      final path = await file.writeToFolder(
        payload,
        folder,
        prefix: autoPrefix,
        now: now,
      );
      await file.pruneFolder(
        folder,
        prefix: autoPrefix,
        keep: DesktopPrefs.autoBackupKeep,
      );
      await DesktopPrefs.setAutoBackupLastRun(now);
      revision.value++;
      debugPrint('[backup] automatic backup saved · $path');
      return path;
    } catch (e) {
      debugPrint('[backup] automatic backup failed: $e');
      return null;
    }
  }

  /// Saves a backup of the current data for [bundles] into [safetyFolder]
  /// before a restore. Returns the path, or null when it could not be saved
  /// (the restore still offers the in-memory 'Undo restore').
  static Future<String?> saveSafetyCopy(Set<BackupBundle> bundles) async {
    final folder = safetyFolder();
    if (folder == null || bundles.isEmpty) return null;
    try {
      final payload = await _buildPayload(bundles);
      final path = await BackupFile().writeToFolder(
        payload,
        folder,
        prefix: safetyPrefix,
      );
      revision.value++;
      return path;
    } catch (e) {
      debugPrint('[backup] safety copy failed: $e');
      return null;
    }
  }

  /// Builds an unencrypted payload of [bundles] (all by default). Stremio
  /// add-ons are left out: their file envelope needs a password the user
  /// types, which an unattended backup can't ask for.
  static Future<Map<String, dynamic>> _buildPayload([
    Set<BackupBundle>? bundles,
  ]) async {
    final hook = debugBuildPayload;
    if (hook != null) return hook();
    final service = sl<BackupService>();
    // The profile-lock check is the same one manual backups pass; it needs
    // no input, and throws (so nothing is written) while a profile is locked.
    await service.authorize();
    return service.build(bundles ?? BackupBundle.values.toSet());
  }

  /// Clears test hooks and state.
  @visibleForTesting
  static void debugReset() {
    debugBuildPayload = null;
    debugIsWindows = null;
    _running = null;
  }
}
