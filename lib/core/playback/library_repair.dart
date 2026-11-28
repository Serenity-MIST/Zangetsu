import 'package:hive/hive.dart';
import '../hive/hive_key.dart';
import '../models/media_item.dart';
import '../models/provider_info.dart';
import '../tracker/tracker_item_url.dart';
import '../zmode/zmode_ids.dart';
import '../profiles/profile_scope.dart';

/// Stable, kind-scoped identity shared by local and restored libraries.
MediaItem repairedLibraryItem(MediaItem item) {
  if (Hive.isBoxOpen('my_list_link_repairs')) {
    final linked = Hive.box<Map>(
      'my_list_link_repairs',
    ).get(hiveKey('${item.sourceId}::${item.id}'));
    if (linked != null) {
      try {
        item = MediaItem.fromJson(Map<String, dynamic>.from(linked));
      } catch (_) {}
    }
  }
  var c = ZmodeIds.parseShow(item.url);
  if (c == null &&
      {
        'zm',
        'mal',
        'myanimelist',
        'anilist',
        'simkl',
      }.contains(item.sourceId.toLowerCase())) {
    c = trackerCanonical(item);
  }
  if (c != null) {
    if (c.id.startsWith('al:') && item.malId != null)
      c = ZCanonical(c.kind, 'mal:${item.malId}');
    final ids = trackerIdsFromItem(item);
    return item.copyWith(
      id: c.key,
      sourceId: ZmodeIds.sourceId,
      url: ZmodeIds.showUrl(c),
      type: switch (c.kind) {
        ZKind.manga => ProviderType.manga,
        ZKind.novel => ProviderType.novel,
        ZKind.movie || ZKind.tv => ProviderType.movie,
        _ => ProviderType.anime,
      },
      malId: ids.malId,
      anilistId: ids.anilistId,
      tmdbId: ids.tmdbId,
      savedFrom: c.id.startsWith('al:') ? 'AniList' : item.savedFrom,
    );
  }
  // Old Android extension ids were occasionally stored without their namespace.
  if (RegExp(r'^-?\d+$').hasMatch(item.sourceId)) {
    return item.copyWith(
      sourceId:
          '${item.type == ProviderType.manga ? 'mihon' : 'ani'}:${item.sourceId}',
    );
  }
  return item;
}

/// Produces the stable local key after repairing legacy IDs/namespaces.
String libraryStorageKey(MediaItem item) {
  final fixed = repairedLibraryItem(item);
  return hiveKey('${fixed.sourceId}::${fixed.id}');
}

/// Resolves cloud rows through saved link repairs before deriving their key.
/// This prevents an old remote identity from resurrecting a repaired duplicate.
String libraryCloudKey(Map row) {
  final oldKey = hiveKey('${row['source_id']}::${row['item_id']}');
  if (Hive.isBoxOpen('my_list_link_repairs')) {
    final linked = Hive.box<Map>('my_list_link_repairs').get(oldKey);
    if (linked != null)
      return libraryStorageKey(
        MediaItem.fromJson(Map<String, dynamic>.from(linked)),
      );
  }
  final c = ZmodeIds.parseShow('${row['url'] ?? ''}');
  var source = '${row['source_id']}';
  if (RegExp(r'^-?\d+$').hasMatch(source)) {
    source = '${row['type'] == 'manga' ? 'mihon' : 'ani'}:$source';
  }
  return hiveKey(c == null ? '$source::${row['item_id']}' : 'zm::${c.key}');
}

/// Resolve category/sync keys using the backed-up identity migration.
String repairedLibraryKey(String source, String id) {
  final key = hiveKey('$source::$id');
  if (Hive.isBoxOpen('my_list_link_repairs')) {
    final linked = Hive.box<Map>('my_list_link_repairs').get(key);
    if (linked != null)
      return libraryStorageKey(
        MediaItem.fromJson(Map<String, dynamic>.from(linked)),
      );
  }
  if (Hive.isBoxOpen('my_list_repair_backup')) {
    final raw = Hive.box<Map>('my_list_repair_backup').get(key);
    if (raw != null) {
      try {
        return libraryStorageKey(
          MediaItem.fromJson(Map<String, dynamic>.from(raw)),
        );
      } catch (_) {
        /* keep unknown records intact */
      }
    }
  }
  return key;
}

/// Idempotent startup repair. Original rows and state remain recoverable.
Future<int> repairLibraryBox(Box<Map> box) async {
  Box<Map>? backup;
  var changed = 0;
  for (final key in box.keys.toList()) {
    // Startup migration applies to the legacy default viewer only. Other
    // viewers repair links on demand without moving rows between profiles.
    if (!profileOwnsKey(key, kDefaultProfileId)) continue;
    final raw = box.get(key);
    if (raw == null) continue;
    MediaItem before;
    try {
      final json = Map<String, dynamic>.from(raw);
      if (json['coverHeaders'] is Map)
        json['coverHeaders'] = (json['coverHeaders'] as Map).map(
          (k, v) => MapEntry('$k', '$v'),
        );
      before = MediaItem.fromJson(json);
    } catch (_) {
      continue;
    }
    final fixed = repairedLibraryItem(before);
    final target = libraryStorageKey(fixed);
    if ('$key' == target && before == fixed) continue;
    backup ??= Hive.isBoxOpen('my_list_repair_backup')
        ? Hive.box<Map>('my_list_repair_backup')
        : await Hive.openBox<Map>('my_list_repair_backup');
    // Save before any replacement/deletion; a failed backup aborts the repair.
    if (!backup.containsKey(key)) await backup.put(key, raw);
    final existing = box.get(target);
    var output = fixed.toJson();
    if (existing != null && '$key' != target) {
      output = {...output, ...Map<String, dynamic>.from(existing)};
      // Fill absent metadata without overriding the surviving record.
      for (final entry in fixed.toJson().entries) {
        if (output[entry.key] == null) output[entry.key] = entry.value;
      }
    }
    await box.put(target, output);
    await _copyState(before, fixed);
    // Detail/player repositories still use the canonical id without its kind
    // prefix; retain progress under that runtime identity as well.
    final canonical = ZmodeIds.parseShow(fixed.url);
    if (canonical != null) {
      await _copyState(
        before,
        fixed.copyWith(id: canonical.id),
        runtimeOnly: true,
      );
    }
    if (Hive.isBoxOpen('library_sync_meta')) {
      final meta = Hive.box('library_sync_meta');
      final pending = meta.get('mylist_pending');
      if (pending is List && pending.contains(key)) {
        await meta.put(
          'mylist_pending',
          pending.map((k) => k == key ? target : k).toSet().toList(),
        );
      }
    }
    if ('$key' != target) await box.delete(key);
    changed++;
  }
  return changed;
}

/// Copies status, progress, preferences and categories to a repaired identity.
/// Existing target state wins; source keys remain for recovery/older versions.
Future<void> _copyState(
  MediaItem before,
  MediaItem after, {
  bool runtimeOnly = false,
  String profileId = kDefaultProfileId,
}) async {
  final oldPrefix = '${before.sourceId}::${before.id}';
  final newPrefix = '${after.sourceId}::${after.id}';
  if (oldPrefix == newPrefix) return;
  for (final name in [
    'list_status',
    'resume_positions',
    'read_positions',
    'title_prefs',
    'list_categories',
  ]) {
    if (runtimeOnly && !['resume_positions', 'read_positions'].contains(name))
      continue;
    if (!Hive.isBoxOpen(name)) continue;
    final Box box = (name == 'list_status' || name == 'list_categories')
        ? Hive.box(name)
        : Hive.box<Map>(name);
    if (name == 'title_prefs') {
      final from = profileScopedKey(
        profileId,
        hiveKey('${before.sourceId}::${before.url}'),
      );
      final to = profileScopedKey(
        profileId,
        hiveKey('${after.sourceId}::${after.url}'),
      );
      if (box.containsKey(from) && !box.containsKey(to))
        await box.put(to, box.get(from));
      continue;
    }
    for (final key in box.keys.toList()) {
      if (key is! String || !profileOwnsKey(key, profileId)) continue;
      final prefix = profileId == kDefaultProfileId
          ? ''
          : profileScopePrefix(profileId);
      final unscoped = key.substring(prefix.length);
      if (!(unscoped == oldPrefix || unscoped.startsWith('$oldPrefix::')))
        continue;
      final target = profileScopedKey(
        profileId,
        hiveKey('$newPrefix${unscoped.substring(oldPrefix.length)}'),
      );
      if (name == 'list_categories' && box.get(key) is List) {
        final merged = {
          ...(box.get(target) is List ? box.get(target) as List : []),
          ...box.get(key) as List,
        };
        await box.put(target, merged.toList());
      } else if (!box.containsKey(target)) {
        await box.put(target, box.get(key));
      }
    }
    // Original state keys are retained so interrupted/old app versions recover.
  }
}

/// Carries local state to a new link and its catalogue-ID progress aliases.
Future<void> preserveRepairedLinkState(
  MediaItem before,
  MediaItem after, {
  String profileId = kDefaultProfileId,
}) async {
  await _copyState(before, after, profileId: profileId);
  final c = ZmodeIds.parseShow(after.url);
  if (c != null)
    await _copyState(
      before,
      after.copyWith(id: c.id),
      runtimeOnly: true,
      profileId: profileId,
    );
}
