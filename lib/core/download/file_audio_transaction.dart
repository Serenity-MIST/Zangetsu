import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// A recoverable same-volume file replacement. The journal is flushed before
/// either rename; a replacement hash distinguishes published media from a
/// conflicting file without trusting an interrupted phase counter.
class FileAudioTransaction {
  static const journalName = 'publish.json';
  static const recoveryError =
      'Interrupted audio selection needs file recovery';

  /// Publish only an already-probed replacement from the known scratch folder.
  static Future<String?> publish(
    File input,
    File output,
    Directory scratch,
    bool Function() canceled,
  ) async {
    if (!p.equals(input.parent.absolute.path, scratch.parent.absolute.path) ||
        !p.equals(output.parent.absolute.path, scratch.absolute.path)) {
      return recoveryError;
    }
    final digest = (await sha256.bind(output.openRead()).first).toString();
    if (canceled()) return 'canceled';
    final pendingJournal = File(p.join(scratch.path, 'publish.tmp'));
    await pendingJournal.writeAsString(
      jsonEncode({
        'version': 1,
        'target': p.basename(input.path),
        'backup': 'original${p.extension(input.path)}',
        'sha256': digest,
      }),
      flush: true,
    );
    await pendingJournal.rename(p.join(scratch.path, journalName));
    try {
      if (canceled()) {
        await recover(input.path);
        return 'canceled';
      }
      await input.rename(
        p.join(scratch.path, 'original${p.extension(input.path)}'),
      );
      await output.rename(input.path);
      await scratch.delete(recursive: true);
      return null;
    } catch (_) {
      return await recover(input.path) ??
          'The selected audio could not be saved';
    }
  }

  /// Recover only transactions for this exact sibling filename. Never follow
  /// scratch-directory or backup symlinks and never overwrite a conflicting
  /// target. Unknown/corrupt journals remain on disk for explicit recovery.
  static Future<String?> recover(String targetPath) async {
    final target = File(targetPath).absolute;
    if (!await target.parent.exists()) return null;
    try {
      await for (final entity in target.parent.list(followLinks: false)) {
        if (entity is! Directory ||
            !p.basename(entity.path).startsWith('.zangetsu-file-audio-')) {
          continue;
        }
        final journal = File(p.join(entity.path, journalName));
        if (!await journal.exists()) continue;
        if (await FileSystemEntity.type(journal.path, followLinks: false) !=
            FileSystemEntityType.file) {
          return recoveryError;
        }
        final decoded = jsonDecode(await journal.readAsString());
        if (decoded is! Map || decoded['version'] != 1) return recoveryError;
        if (decoded['target'] != p.basename(target.path)) continue;
        final backupName = 'original${p.extension(target.path)}';
        if (decoded['backup'] != backupName ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch('${decoded['sha256']}')) {
          return recoveryError;
        }
        // Never recursively sweep unexpected user files or linked entries.
        final knownNames = {
          journalName,
          'publish.tmp',
          backupName.toLowerCase(),
          'selected${p.extension(target.path).toLowerCase()}',
        };
        await for (final child in entity.list(followLinks: false)) {
          if (child is! File ||
              !knownNames.contains(p.basename(child.path).toLowerCase())) {
            return recoveryError;
          }
        }
        final backup = File(p.join(entity.path, backupName));
        final backupType = await FileSystemEntity.type(
          backup.path,
          followLinks: false,
        );
        final targetType = await FileSystemEntity.type(
          target.path,
          followLinks: false,
        );
        if (backupType != FileSystemEntityType.notFound &&
            backupType != FileSystemEntityType.file) {
          return recoveryError;
        }
        if (targetType != FileSystemEntityType.notFound &&
            targetType != FileSystemEntityType.file) {
          return recoveryError;
        }
        if (backupType == FileSystemEntityType.file) {
          if (targetType == FileSystemEntityType.notFound) {
            await backup.rename(target.path);
          } else {
            final digest = (await sha256.bind(target.openRead()).first)
                .toString();
            if (digest != decoded['sha256']) return recoveryError;
          }
        } else if (targetType == FileSystemEntityType.notFound) {
          return recoveryError;
        }
        // Either the original has been restored, the rename had not started,
        // or the replacement matches the verified payload recorded in advance.
        await entity.delete(recursive: true);
      }
      return null;
    } catch (_) {
      return recoveryError;
    }
  }
}
