import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../desktop/desktop_storage.dart';

import 'package:background_downloader/background_downloader.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';

import '../platform/apple_tv.dart';
import '../platform/app_paths.dart';

// ── Pure helpers (tested) ─────────────────────────────────────────────────────

/// Returns a file name like `zangetsu-backup-20260702-0905.json`.
String backupFileName(DateTime now) {
  final y = now.year.toString().padLeft(4, '0');
  final mo = now.month.toString().padLeft(2, '0');
  final d = now.day.toString().padLeft(2, '0');
  final h = now.hour.toString().padLeft(2, '0');
  final mi = now.minute.toString().padLeft(2, '0');
  return 'zangetsu-backup-$y$mo$d-$h$mi.json';
}

/// Returns `<prefix>-YYYYMMDD-HHMMSS.json`, e.g.
/// `zangetsu-auto-20261118-090512.json`. Used for the Windows folder backups.
String timestampedBackupName(String prefix, DateTime now) {
  String two(int n) => n.toString().padLeft(2, '0');
  final y = now.year.toString().padLeft(4, '0');
  return '$prefix-$y${two(now.month)}${two(now.day)}-'
      '${two(now.hour)}${two(now.minute)}${two(now.second)}.json';
}

/// Sort key for a backup file: the `YYYYMMDD-HHMM[SS]` stamp in its name
/// (seconds padded to 00 when absent), or '' when the name has none.
String backupStamp(File f) {
  final name = f.uri.pathSegments.last;
  final m = RegExp(r'(\d{8})-(\d{4})(\d{2})?').firstMatch(name);
  if (m == null) return '';
  return '${m[1]}${m[2]}${m[3] ?? '00'}';
}

/// Decodes [raw] as JSON and asserts it is a JSON object.
/// Throws [FormatException] if the string is not valid JSON or not an object.
Map<String, dynamic> parseBackupJson(String raw) {
  final dynamic decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    throw const FormatException('Backup file is not valid JSON');
  }
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException(
      'Backup JSON must be a JSON object, not an array or primitive',
    );
  }
  return decoded;
}

// ── Transport class ───────────────────────────────────────────────────────────

/// Signature of the desktop "Save as" step: shows a save dialog suggesting
/// [fileName], writes [bytes] to the chosen file and returns its path, or
/// null when the user cancels.
typedef BackupSaveDialog =
    Future<String?> Function(String fileName, Uint8List bytes);

class BackupFile {
  /// Test hook replacing the native Windows save dialog.
  @visibleForTesting
  static BackupSaveDialog? debugSaveDialog;

  /// Windows: asks where to save the backup with the native "Save as" dialog
  /// (suggested name `zangetsu-backup-<date>.json`) and writes it there.
  /// Returns the real saved path, or null when the user cancels. Write
  /// failures are thrown so the caller can report them.
  Future<String?> exportToChosenFile(Map<String, dynamic> payload) async {
    final name = backupFileName(DateTime.now());
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    final dialog = debugSaveDialog ?? _nativeSaveDialog;
    return dialog(name, bytes);
  }

  /// The Windows IFileSaveDialog via file_picker. It appends `.json` when the
  /// user types a bare name and asks before overwriting an existing file.
  static Future<String?> _nativeSaveDialog(
    String fileName,
    Uint8List bytes,
  ) async {
    final uri = await FilePicker.saveFile(
      dialogTitle: 'Save Zangetsu backup',
      fileName: fileName,
      bytes: bytes,
      mimeType: 'application/json',
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    return uri?.toFilePath(windows: true);
  }

  /// Encodes [payload] as JSON and saves it into the public
  /// **Downloads/Zangetsu** folder so the user can find it in their file
  /// manager. Returns the saved public path, or `null` if the move to shared
  /// storage failed.
  Future<String?> export(
    Map<String, dynamic> payload, {
    bool keepLocalCopy = false,
  }) async {
    final name = backupFileName(DateTime.now());
    final tmpDir = (Platform.isWindows && DesktopStorage.root != null
        ? await Directory(
            '${DesktopStorage.root}/Backups',
          ).create(recursive: true)
        : await getTemporaryDirectory());
    final file = File('${tmpDir.path}/$name');
    await file.writeAsString(jsonEncode(payload));
    if (Platform.isWindows && DesktopStorage.root != null) return file.path;

    // TV boxes usually have no document-picker UI, so restore-from-file can't
    // browse public Downloads. Keep an app-private, always-readable copy (no
    // storage permission needed) that [listLocalBackups] can enumerate. Only
    // done when the caller asks (TV) — phone exports are byte-identical.
    String? localCopyPath;
    if (keepLocalCopy) {
      try {
        final dir = await _localBackupDir();
        if (dir != null) {
          localCopyPath = (await file.copy('${dir.path}/$name')).path;
        }
      } catch (_) {
        /* best-effort — never block the primary export */
      }
    }

    // Move into public Downloads/Zangetsu for the user's file manager. On TV
    // boxes this often has no shared-storage target and returns null/throws —
    // in which case the app-private copy above is the saved backup, so report
    // its path (restore-from-file lists it) instead of failing. On a phone
    // (keepLocalCopy == false) localCopyPath is null, so this is byte-identical.
    if (isAppleTv) return localCopyPath;
    try {
      final shared = await FileDownloader().moveFileToSharedStorage(
        file.path,
        SharedStorage.downloads,
        directory: 'Zangetsu',
      );
      if (shared != null && shared.isNotEmpty) return shared;
    } catch (_) {
      /* shared storage unavailable (common on TV) */
    }
    return localCopyPath;
  }

  /// App-private backups directory (Caches on Apple TV, external storage on Android).
  Future<Directory?> _localBackupDir() async {
    if (isAppleTv) {
      return writableAppSubdir('backups');
    }
    final ext = await getExternalStorageDirectory();
    if (ext == null) return null;
    final dir = Directory('${ext.path}/backups');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// Backup files this app can read back without a document picker, newest
  /// first. Scans the app-private backups dir plus a best-effort look at the
  /// public Downloads/Zangetsu folder (readable on many TV boxes). Used by the
  /// TV restore flow in place of the (usually absent) system file picker.
  Future<List<File>> listLocalBackups() async {
    final found = <String, File>{}; // de-dupe by file name
    Future<void> scan(Directory? d) async {
      if (d == null || !d.existsSync()) return;
      try {
        for (final e in d.listSync()) {
          if (e is File && e.path.toLowerCase().endsWith('.json')) {
            found[e.uri.pathSegments.last] = e;
          }
        }
      } catch (_) {
        /* unreadable dir (scoped storage) — skip */
      }
    }

    await scan(await _localBackupDir());
    await scan(Directory('/storage/emulated/0/Download/Zangetsu'));

    final files = found.values.toList()
      ..sort((a, b) => b.path.compareTo(a.path)); // name embeds the timestamp
    return files;
  }

  // ── Windows folder backups (automatic + safety copies) ──────────────────

  /// Writes [payload] into [folder] as `<prefix>-YYYYMMDD-HHMMSS.json` and
  /// returns the file path. Seconds are in the name so two backups in the
  /// same minute never overwrite each other. Write errors are thrown.
  Future<String> writeToFolder(
    Map<String, dynamic> payload,
    String folder, {
    required String prefix,
    DateTime? now,
  }) async {
    final dir = await Directory(folder).create(recursive: true);
    final name = timestampedBackupName(prefix, now ?? DateTime.now());
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    // Write to a temp name first, then rename: a crash mid-write can't leave
    // a half-written file that looks like a real backup.
    final tmp = File('${file.path}.part');
    await tmp.writeAsString(jsonEncode(payload), flush: true);
    await tmp.rename(file.path);
    return file.path;
  }

  /// Zangetsu backup files (`zangetsu-*.json`) in [folders], newest first by
  /// the timestamp in their names. Missing or unreadable folders are skipped.
  Future<List<File>> listBackupsIn(Iterable<String?> folders) async {
    final found = <String, File>{}; // de-dupe by full path
    for (final folder in folders) {
      if (folder == null || folder.isEmpty) continue;
      final dir = Directory(folder);
      try {
        if (!await dir.exists()) continue;
        await for (final e in dir.list(followLinks: false)) {
          final name = e.uri.pathSegments.last.toLowerCase();
          if (e is File &&
              name.startsWith('zangetsu-') &&
              name.endsWith('.json')) {
            found[e.path] = e;
          }
        }
      } catch (_) {
        // Unreadable folder (permissions, OneDrive offline): skip it.
      }
    }
    final files = found.values.toList()
      ..sort((a, b) => backupStamp(b).compareTo(backupStamp(a)));
    return files;
  }

  /// Deletes the oldest `<prefix>-*.json` files in [folder] so at most [keep]
  /// remain. Only files with that prefix are touched, so manual saves and
  /// safety copies are never pruned. Returns the deleted paths.
  Future<List<String>> pruneFolder(
    String folder, {
    required String prefix,
    required int keep,
  }) async {
    final all = await listBackupsIn([folder]);
    final mine = [
      for (final f in all)
        if (f.uri.pathSegments.last.toLowerCase().startsWith('$prefix-')) f,
    ];
    final deleted = <String>[];
    for (final f in mine.skip(keep < 1 ? 1 : keep)) {
      try {
        await f.delete();
        deleted.add(f.path);
      } catch (_) {
        // Locked by a sync client or antivirus; try again next run.
      }
    }
    return deleted;
  }

  /// Reads and parses a backup [file] chosen from [listLocalBackups].
  Future<Map<String, dynamic>> readBackup(File file) async =>
      parseBackupJson(await file.readAsString());

  /// Opens the system file picker (JSON filter), reads the chosen file, and
  /// returns the parsed map. Returns `null` if the user cancels.
  Future<Map<String, dynamic>?> import() async {
    // Pick ANY file rather than FileType.custom + ['json']: Android's document
    // picker greys out .json on many devices (its MIME map doesn't tag them),
    // which makes the backup impossible to select — the #1 "restore doesn't
    // work" cause. The content is validated by parseBackupJson/unwrapPayload
    // right after reading, so allowing any file is safe (bad picks get a clear
    // "isn't a Zangetsu backup" error).
    // Windows titles its Open dialog so it is clear what to pick; other
    // platforms keep the untitled system picker.
    // Windows has no such MIME problem, so its Open dialog is filtered to
    // .json backups (acct-12); Android keeps the any-file workaround.
    final windows = Platform.isWindows;
    final picked = await FilePicker.pickFile(
      dialogTitle: windows ? 'Choose a Zangetsu backup file' : null,
      type: windows ? FileType.custom : FileType.any,
      allowedExtensions: windows ? const ['json'] : null,
    );
    if (picked == null) return null;

    final String content;
    if (picked.path != null) {
      content = await File(picked.path!).readAsString();
    } else {
      content = utf8.decode(await picked.readAsBytes());
    }
    return parseBackupJson(content);
  }
}
