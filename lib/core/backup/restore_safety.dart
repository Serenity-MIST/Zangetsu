import 'package:flutter/foundation.dart';

import 'backup_boxes.dart';
import 'backup_payload.dart';
import 'library_backup.dart';
import 'settings_backup.dart';

/// Exact copy of the Hive boxes a restore is about to write, taken just
/// before it runs (acct-4, the automatic safety copy). [rollback] puts every
/// box back the way it was: entries the restore added are removed and
/// entries it changed get their old values back.
///
/// Sources aren't covered: restoring them installs extensions and repos,
/// which a box copy can't undo, so 'Undo restore' leaves them as they are.
class RestoreSafetySnapshot {
  RestoreSafetySnapshot._(this._boxes, this.takenAt);

  /// box name -> {key: value} as it was when [capture] ran.
  final Map<String, Map<dynamic, dynamic>> _boxes;

  /// When the copy was taken.
  final DateTime takenAt;

  /// Names of the boxes this copy can put back.
  Iterable<String> get boxNames => _boxes.keys;

  /// The boxes a restore of [bundles] can change.
  static List<String> boxNamesFor(Set<BackupBundle> bundles) => [
    if (bundles.contains(BackupBundle.library)) ...LibraryBackup.boxNames,
    if (bundles.contains(BackupBundle.settings))
      ...SettingsBackup.restoredBoxNames,
  ];

  /// Copies every open box in [names]. Closed boxes are skipped: a restore
  /// can't write to them either.
  static RestoreSafetySnapshot capture(
    Iterable<String> names, {
    DateTime? now,
  }) {
    final boxes = <String, Map<dynamic, dynamic>>{};
    for (final name in names) {
      final box = anyOpenBox(name);
      if (box == null) continue;
      boxes[name] = {for (final k in box.keys) k: _deepCopy(box.get(k))};
    }
    return RestoreSafetySnapshot._(boxes, now ?? DateTime.now());
  }

  /// Puts every copied box back exactly as it was. Errors on one box are
  /// logged and the rest still roll back.
  Future<void> rollback() async {
    for (final entry in _boxes.entries) {
      final box = anyOpenBox(entry.key);
      if (box == null) continue;
      try {
        final saved = entry.value;
        // Drop entries the restore added.
        final added = [
          for (final k in box.keys)
            if (!saved.containsKey(k)) k,
        ];
        if (added.isNotEmpty) await box.deleteAll(added);
        // Put back every saved entry (fresh copies, so the snapshot can be
        // rolled back again if needed).
        for (final e in saved.entries) {
          await box.put(e.key, _deepCopy(e.value));
        }
      } catch (e) {
        debugPrint('[backup] undo restore failed for ${entry.key}: $e');
      }
    }
  }
}

/// Deep copy that keeps key types (unlike [plainCopy], which makes every map
/// key a string), so a rollback writes back exactly what was there.
Object? _deepCopy(Object? value) {
  if (value is Map) {
    return {for (final e in value.entries) e.key: _deepCopy(e.value)};
  }
  if (value is List) return [for (final v in value) _deepCopy(v)];
  return value;
}
