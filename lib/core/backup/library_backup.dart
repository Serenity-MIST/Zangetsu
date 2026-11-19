import 'package:hive/hive.dart';
import 'package:watch_app/core/hive/hive_key.dart';

import 'backup_boxes.dart';

/// Backs up the user's library — My List, watch history, and manga/novel
/// reading progress — and merges it back in on restore. Never deletes:
/// My List and the reading boxes merge by union (existing entries win),
/// watch history keeps whichever side was updated more recently.
class LibraryBackup {
  static const _myListBox = 'my_list';
  // Was 'history' — no box by that name is ever opened anywhere in the app,
  // so this silently backed up nothing. The real Continue Watching box is
  // 'watch_history' (see WatchHistory.boxName).
  static const _historyBox = 'watch_history';
  static const _readHistoryBox = 'read_history';
  static const _readPositionsBox = 'read_positions';
  static const _listStatusBox = 'list_status';
  // Added for file backups that fully bring a library back. All four hold
  // things the user made, not caches:
  // My List categories and which titles are in them (CategoryStore).
  static const _categoriesBox = 'list_categories';
  // Mid-episode resume points and hand-marked watched episodes (ResumeStore).
  static const _resumeBox = 'resume_positions';
  // Per-series reader direction / fit / page width (ReaderOverrideStore).
  static const _readerOverridesBox = 'reader_overrides';
  // Manual "this show = that tracker entry" fixes (TrackerBindingStore).
  static const _trackerBindingsBox = 'tracker_bindings';

  /// Every box a library restore can write to. The safety copy taken before
  /// a restore snapshots these so 'Undo restore' can put them back.
  static const List<String> boxNames = [
    _myListBox,
    _historyBox,
    _readHistoryBox,
    _readPositionsBox,
    _listStatusBox,
    _categoriesBox,
    _resumeBox,
    _readerOverridesBox,
    _trackerBindingsBox,
  ];

  Map<String, dynamic> build() => {
    'myList': _dump(_myListBox),
    'history': _dump(_historyBox),
    'profileMyList': _dumpProfileRows(_myListBox),
    'profileHistory': _dumpProfileRows(_historyBox),
    'readHistory': _dumpKeyed(_readHistoryBox, asMap: true),
    'readPositions': _dumpKeyed(_readPositionsBox, asMap: true),
    'listStatus': _dumpKeyed(_listStatusBox, asMap: false),
    'listCategories': _dumpPlain(_categoriesBox),
    'resumePositions': _dumpKeyed(_resumeBox, asMap: true),
    'readerOverrides': _dumpPlain(_readerOverridesBox),
    'trackerBindings': _dumpPlain(_trackerBindingsBox),
  };

  /// Dumps an untyped box as `{key: plain JSON value}`. Used by the boxes
  /// whose values are lists or maps under an untyped `Box` (categories,
  /// reader overrides, tracker bindings).
  Map<String, dynamic> _dumpPlain(String box) {
    final b = anyOpenBox(box);
    if (b == null) return const {};
    return {for (final k in b.keys) k.toString(): plainCopy(b.get(k))};
  }

  List<Map<String, dynamic>> _dump(String box) {
    if (!Hive.isBoxOpen(box)) return const [];
    final b = Hive.box<Map>(box);
    return [
      for (final key in b.keys)
        if (!key.toString().startsWith('p:'))
          Map<String, dynamic>.from(b.get(key) ?? const {}),
    ];
  }

  /// My List and watch-history records do not carry their Hive keys, unlike
  /// reading progress. Keep profile-scoped keys beside the legacy payload so
  /// restore cannot accidentally merge a private profile into the default.
  Map<String, dynamic> _dumpProfileRows(String box) {
    if (!Hive.isBoxOpen(box)) return const {};
    final b = Hive.box<Map>(box);
    return {
      for (final key in b.keys)
        if (key.toString().startsWith('p:'))
          key.toString(): Map<String, dynamic>.from(b.get(key) ?? const {}),
    };
  }

  /// Dumps [box] as a `{hiveKey: value}` map instead of a values list — for
  /// boxes whose stored VALUE doesn't carry its own key back (read_positions'
  /// value is bare `{pos, total}`; list_status' value is a bare status-name
  /// string), unlike [_dump]'s boxes where the key is rebuilt from fields
  /// inside the value on merge. [asMap] must match how the box was actually
  /// opened elsewhere (Box<Map> vs the untyped Box list_status uses) — Hive
  /// throws if you reopen a box under a different type parameter.
  Map<String, dynamic> _dumpKeyed(String box, {required bool asMap}) {
    if (!Hive.isBoxOpen(box)) return const {};
    if (asMap) {
      final b = Hive.box<Map>(box);
      return {
        for (final k in b.keys)
          k.toString(): Map<String, dynamic>.from(b.get(k) ?? const {}),
      };
    }
    final b = Hive.box(box);
    return {for (final k in b.keys) k.toString(): b.get(k)};
  }

  Future<void> merge(Map<String, dynamic> data) async {
    if (Hive.isBoxOpen(_myListBox)) {
      final box = Hive.box<Map>(_myListBox);
      for (final raw in (data['myList'] as List? ?? const [])) {
        final m = Map<String, dynamic>.from(raw as Map);
        final key = hiveKey('${m['sourceId']}::${m['id']}');
        if (!box.containsKey(key)) {
          await box.put(key, m); // union, never overwrite
        }
      }
    }
    if (Hive.isBoxOpen(_historyBox)) {
      final box = Hive.box<Map>(_historyBox);
      for (final raw in (data['history'] as List? ?? const [])) {
        final h = Map<String, dynamic>.from(raw as Map);
        final key = hiveKey('${h['sourceId']}::${h['showId']}');
        final cur = box.get(key);
        final curTs = cur == null
            ? -1
            : (cur['updatedAt'] as num? ?? -1).toInt();
        final newTs = (h['updatedAt'] as num? ?? 0).toInt();
        if (newTs > curTs) await box.put(key, h); // keep-newer, never delete
      }
    }
    await _mergeProfileRows(_myListBox, data['profileMyList']);
    await _mergeProfileRows(
      _historyBox,
      data['profileHistory'],
      keepNewer: true,
    );
    await _mergeKeyed(_readHistoryBox, data['readHistory'], asMap: true);
    await _mergeKeyed(_readPositionsBox, data['readPositions'], asMap: true);
    await _mergeKeyed(_listStatusBox, data['listStatus'], asMap: false);
    await _mergeCategories(data['listCategories']);
    // Resume points: union, the current device's point for an episode wins.
    await _mergeKeyed(_resumeBox, data['resumePositions'], asMap: true);
    await _mergeFieldMaps(_readerOverridesBox, data['readerOverrides']);
    await _mergeFieldMaps(_trackerBindingsBox, data['trackerBindings']);
  }

  /// Merges My List categories. Category lists (keys ending in
  /// `__categories__`) are unioned by category id, keeping the current name
  /// and order for ids that exist on both sides. Assignment rows (a title's
  /// list of category ids) are unioned too. Nothing is removed.
  Future<void> _mergeCategories(Object? raw) async {
    final box = anyOpenBox(_categoriesBox);
    if (box == null || raw is! Map) return;
    for (final e in raw.entries) {
      final key = hiveKey(e.key.toString());
      final incoming = e.value;
      if (incoming is! List) continue;
      final current = box.get(key);
      if (key.endsWith('__categories__')) {
        final rows = current is List ? [...current] : <dynamic>[];
        final ids = {
          for (final r in rows)
            if (r is Map) r['id'],
        };
        for (final r in incoming) {
          if (r is Map && r['id'] is String && !ids.contains(r['id'])) {
            rows.add(Map<String, dynamic>.from(r));
            ids.add(r['id']);
          }
        }
        await box.put(key, rows);
      } else {
        final ids = <String>{
          if (current is List) ...current.whereType<String>(),
          ...incoming.whereType<String>(),
        };
        await box.put(key, ids.toList());
      }
    }
  }

  /// Merges an untyped box whose values are small field maps (reader
  /// overrides `{mode, fit, ...}`, tracker bindings `{tracker: id}`). Missing
  /// rows are added; for a row on both sides, only fields the current device
  /// doesn't already have are filled in, so nothing the user set here changes.
  Future<void> _mergeFieldMaps(String boxName, Object? raw) async {
    final box = anyOpenBox(boxName);
    if (box == null || raw is! Map) return;
    for (final e in raw.entries) {
      final value = e.value;
      if (value is! Map) continue;
      final key = hiveKey(e.key.toString());
      final current = box.get(key);
      final merged = <String, dynamic>{
        ...Map<String, dynamic>.from(value),
        if (current is Map) ...Map<String, dynamic>.from(current),
      };
      await box.put(key, merged);
    }
  }

  Future<void> _mergeProfileRows(
    String boxName,
    Object? raw, {
    bool keepNewer = false,
  }) async {
    if (!Hive.isBoxOpen(boxName) || raw is! Map) return;
    final box = Hive.box<Map>(boxName);
    for (final entry in raw.entries) {
      final key = hiveKey(entry.key.toString());
      final value = entry.value;
      if (value is! Map) continue;
      final row = Map<String, dynamic>.from(value);
      final current = box.get(key);
      if (current != null) {
        if (!keepNewer) continue;
        final currentMs = (current['updatedAt'] as num? ?? -1).toInt();
        final incomingMs = (row['updatedAt'] as num? ?? 0).toInt();
        if (incomingMs <= currentMs) continue;
      }
      await box.put(key, row);
    }
  }

  /// Union-merges a `{hiveKey: value}` map (as dumped by [_dumpKeyed]) into
  /// [box]: adds only keys not already present, never overwrites the current
  /// session's data. No-op when the box is closed or [raw] is missing/not a
  /// Map — covers both an old backup that lacks the key and a malformed one.
  Future<void> _mergeKeyed(
    String box,
    Object? raw, {
    required bool asMap,
  }) async {
    if (!Hive.isBoxOpen(box) || raw is! Map) return;
    if (asMap) {
      final b = Hive.box<Map>(box);
      for (final e in raw.entries) {
        final key = hiveKey(e.key.toString());
        if (b.containsKey(key)) continue;
        final v = e.value;
        if (v is Map) await b.put(key, Map<String, dynamic>.from(v));
      }
      return;
    }
    final b = Hive.box(box);
    for (final e in raw.entries) {
      final key = hiveKey(e.key.toString());
      if (!b.containsKey(key)) await b.put(key, e.value);
    }
  }
}
