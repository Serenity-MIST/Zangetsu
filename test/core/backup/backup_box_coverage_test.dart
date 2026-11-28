// acct-9 Option B: a developer check that every Hive box the app uses is
// either carried by a backup (settings, library or sources) or deliberately
// left out with a reason. A new box that is in neither list fails this test,
// so a new kind of user data can't silently fall out of file backups.
//
// The scan reads lib/ as text: box names declared as `...box... = 'name'`
// constants, literal names passed to openBoxSafely / Hive.openBox /
// Hive.box / Hive.isBoxOpen, the language-filter boxes passed to
// `super('..._prefs')`, plus the legacy box list used for the storage move.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/backup/library_backup.dart';
import 'package:watch_app/core/backup/settings_backup.dart';
import 'package:watch_app/core/hive/legacy_boxes.dart';

/// Boxes the Sources bundle (SourcesBackup / StremioBackup) restores by
/// reinstalling sources and repos rather than copying the box.
const _sourcesBundle = <String>{
  'provider_settings',
  'provider_registry',
  'provider_repos',
  'cs_repos',
  'aniyomi_installed',
  'aniyomi_repos',
  'mihon_installed',
  'mihon_repos',
  'lnreader_plugins',
  'lnreader_repos',
};

/// Boxes deliberately left out of every backup, each with its reason.
/// Adding one here is a decision; a box in no list is a bug.
const _excluded = <String, String>{
  // Secrets / tokens: must never leave the device in a backup file.
  'anilist': 'oauth token',
  'mal': 'oauth token',
  'simkl': 'oauth token',
  'mangabaka': 'oauth token',
  'discord': 'rpc token',
  'auth_cache': 'session cache',
  'stremio_installations':
      'device-local secure addon URLs (the Sources bundle carries addons '
      'in its own encrypted envelope)',
  // Device-specific.
  'download_prefs': 'device-specific download location',
  'desktop_prefs': 'device-specific Windows window/close/folder settings',
  'desktop_connect':
      'the sharing switch of this PC and last-used times; pairings are secrets '
      'in the secure store',
  'desktop_cs_plugins':
      'Windows CloudStream plugin files on this PC; reinstalled from the '
      'Sources bundle',
  'content_mode': 'restored per device',
  'account_local_data': 'which account owns the live boxes on this device',
  // Reference source ids the restoring device may not have installed.
  'pinned_sources': 'source ids',
  'subscriptions': 'source ids',
  // Downloads are files on this device.
  'chapter_downloads': 'downloads, not backup data',
  'downloads': 'downloads, not backup data',
  // Offline details cache for downloaded shows; rebuilt from the online page.
  'downloaded_show_details': 'cache for downloaded shows, not backup data',
  // Bookkeeping for cloud sync and one-off repairs.
  'library_sync_meta': 'cloud pull timestamps',
  'my_list_repair_backup': 'one-off repair undo data',
  'my_list_cloud_repair_backup': 'one-off repair undo data',
  'my_list_link_repairs': 'one-off repair bookkeeping',
  'tracker_sync_queue': 'pending tracker pushes, retried online',
  // R5 auto Paused/Dropped: per-device idle clocks and their settings. A
  // restored clock would be stale on the new device; it reseeds instead.
  'list_idle_activity': 'device-local idle clocks, reseeded on first run',
  'list_idle_prefs': 'device-local auto Paused/Dropped settings',
  // Caches and transient state: regenerated, never restored.
  'logo_cache': 'cache',
  'schedule_offline_cache': 'offline copy of the airing schedule',
  'provider_js_cache': 'cache',
  'episode_meta': 'cache',
  'skip_times': 'cache of intro/outro times, refetched online',
  'cf_clearance': 'cache',
  'genre_catalog': 'cache',
  'source_icons': 'cache',
  'source_health': 'transient',
  'zmode_source_score': 'derived play counts, rebuilt from use',
  'updates': 'transient',
  'announcements': 'transient',
  'search_history': 'transient',
  'home_cache': 'cache',
  'lists_hub_cache': 'cache',
  'new_episode_inbox': 'transient alerts',
  'app_flags': 'one-time hints already shown',
  'tmdb_posters': 'cache of TMDB poster lookups, refetched online',
  'tmdb_banner_cache_v4': 'cache of TMDB banner lookups, refetched online',
  'stremio_home_cache':
      'old Stremio home cache box, only opened to delete it (the cache now '
      'lives in encrypted files)',
  // Upstream keeps My List series groups in step through the signed-in
  // account's cloud sync, not in file backups.
  'my_list_series_groups': 'synced through the cloud account',
};

/// Every Hive box name the scan finds in lib/.
Set<String> _scanBoxNames() {
  // Each pattern captures the quoted box name in group 1.
  final patterns = [
    // static const String boxName = 'x'; const _flagsBox = 'x'; ...
    RegExp(r"[A-Za-z_]*[bB]ox[A-Za-z_]*\s*=\s*'([a-z0-9_]+)'"),
    // openBoxSafely<Map>('x'), Hive.openBox('x'), Hive.box('x'), ...
    RegExp(
      r'(?:openBoxSafely|Hive\.openBox|Hive\.openLazyBox|Hive\.box|'
      r"Hive\.lazyBox|Hive\.isBoxOpen)(?:<[^>(]*>)?\(\s*'([a-z0-9_]+)'",
    ),
    // LangPrefs subclasses: super('manga_lang_prefs').
    RegExp(r"super\(\s*'([a-z0-9_]+_prefs)'"),
  ];
  final found = <String>{...legacyZangetsuBoxes};
  for (final f in Directory('lib').listSync(recursive: true)) {
    if (f is! File || !f.path.endsWith('.dart')) continue;
    final text = f.readAsStringSync();
    for (final re in patterns) {
      for (final m in re.allMatches(text)) {
        found.add(m.group(1)!);
      }
    }
  }
  return found;
}

void main() {
  final backedUp = <String>{
    ...SettingsBackup.restoredBoxNames,
    ...LibraryBackup.boxNames,
    ..._sourcesBundle,
  };

  test('every Hive box is backed up or explicitly excluded', () {
    final found = _scanBoxNames();
    // Sanity: the scan must see well-known boxes, or it is broken.
    expect(
      found,
      containsAll(['my_list', 'playback_prefs', 'list_categories']),
    );

    final unclassified =
        found
            .where((b) => !backedUp.contains(b) && !_excluded.containsKey(b))
            .toList()
          ..sort();
    expect(
      unclassified,
      isEmpty,
      reason:
          'These Hive boxes are in no backup and not on the excluded list.\n'
          'Add each to SettingsBackup / LibraryBackup if it is user data, or\n'
          'to `_excluded` in this test with the reason it is left out: '
          '$unclassified',
    );
  });

  test('no box is both backed up and excluded', () {
    for (final b in backedUp) {
      expect(_excluded.containsKey(b), isFalse, reason: '$b is in both lists');
    }
  });

  test('the four library gaps from acct-9 are now backed up', () {
    expect(
      LibraryBackup.boxNames,
      containsAll([
        'list_categories',
        'resume_positions',
        'reader_overrides',
        'tracker_bindings',
      ]),
    );
  });
}
