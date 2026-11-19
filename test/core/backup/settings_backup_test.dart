import 'dart:io';
import 'package:hive/hive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/backup/settings_backup.dart';

void main() {
  _driftGuard();
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp();
    Hive.init(dir.path);
    await Hive.openBox('playback_prefs');
    await Hive.openBox('viewer_profiles');
    // A typed Box<Map> — the codec must read/write it without a type-mismatch.
    await Hive.openBox<Map>('title_prefs');
  });
  tearDown(() async {
    await Hive.deleteFromDisk();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('build dumps open boxes and merge overwrites them', () async {
    Hive.box('playback_prefs').put('defaultSpeed', 1.5);
    final data = SettingsBackup().build();
    await Hive.box('playback_prefs').clear();
    await SettingsBackup().merge(data);
    expect(Hive.box('playback_prefs').get('defaultSpeed'), 1.5);
  });

  test('merge skips boxes that are not open (no throw)', () async {
    await SettingsBackup().merge({
      'not_open_box': {'x': 1},
    });
  });

  test(
    'restores the last tracker view without backing up sign-in data',
    () async {
      final selection = await Hive.openBox('tracker_switch_prefs');
      await selection.put('lastTracker', 'AniList');
      final auth = await Hive.openBox('anilist');
      await auth.put('token', 'test-only-token');

      final backup = SettingsBackup().build();
      expect(backup['tracker_switch_prefs'], {'lastTracker': 'AniList'});
      expect(backup.containsKey('anilist'), isFalse);
      await selection.clear();
      await SettingsBackup().merge(backup);
      expect(selection.get('lastTracker'), 'AniList');
      expect(auth.get('token'), 'test-only-token');
    },
  );

  test('backs up viewer profile metadata', () async {
    final profile = {
      'id': 'default',
      'name': 'Home',
      'avatar': 0,
      'isKids': false,
    };
    Hive.box('viewer_profiles').put('profiles:local', [profile]);

    final data = SettingsBackup().build();
    await Hive.box('viewer_profiles').clear();
    await SettingsBackup().merge(data);

    expect(Hive.box('viewer_profiles').get('profiles:local'), [profile]);
  });

  // Regression: title_prefs is opened as Box<Map>; an untyped Hive.box() throws.
  test('handles a Box<Map>-typed box without a type mismatch', () async {
    Hive.box<Map>('title_prefs').put('src::1', {'quality': '720p'});
    final data = SettingsBackup().build(); // must NOT throw
    expect(data['title_prefs'], {
      'src::1': {'quality': '720p'},
    });
    await Hive.box<Map>('title_prefs').clear();
    await SettingsBackup().merge(data);
    expect(Hive.box<Map>('title_prefs').get('src::1'), {'quality': '720p'});
  });

  // zmode_source_order is a Box<List>; the old type tries missed it entirely.
  test('backs up a Box<List> box (source priority order)', () async {
    final order = await Hive.openBox<List>('zmode_source_order');
    await order.put('video', ['a', 'b']);
    final data = SettingsBackup().build();
    expect(data['zmode_source_order'], {
      'video': ['a', 'b'],
    });
    await order.clear();
    await SettingsBackup().merge(data);
    expect(order.get('video'), ['a', 'b']);
  });

  // ar-8: hand-made matches survive a restore; automatic guesses are not saved.
  test('backs up only pinned matches and their title names', () async {
    final matches = await Hive.openBox<Map>(SettingsBackup.matchesBox);
    Map<String, dynamic> m(String src, {required bool pinned}) => {
      'sourceId': src,
      'showUrl': 'https://$src/show',
      'showId': '1',
      'showTitle': 'Show',
      'pinned': pinned,
    };
    await matches.put('anime:1@srcA', m('srcA', pinned: true));
    await matches.put('anime:1@srcB', m('srcB', pinned: false));
    await matches.put('anime:2@srcB', m('srcB', pinned: false));
    await matches.put('label:anime:1', {'title': 'Frieren'});
    await matches.put('last:anime:1', {'sourceId': 'srcB'});

    final data = SettingsBackup().build();
    final saved = data[SettingsBackup.matchesBox] as Map;
    expect(saved.keys.toSet(), {'anime:1@srcA', 'label:anime:1'});

    // New device: the title has a different pin of its own. The restored pin
    // wins and the old one is demoted, so only one pin remains per title.
    await matches.clear();
    await matches.put('anime:1@srcC', m('srcC', pinned: true));
    await SettingsBackup().merge(data);
    expect(matches.get('anime:1@srcA')?['pinned'], isTrue);
    expect(matches.get('anime:1@srcC')?['pinned'], isFalse);
    expect(matches.get('label:anime:1'), {'title': 'Frieren'});
    expect(matches.containsKey('anime:2@srcB'), isFalse);
  });
}

// The real bug wasn't any one missing box — it was drift. The list was written
// once and never revisited, so every settings box added afterwards silently
// fell out of backup (nav_prefs was missing the same day it was created).
// This fails when a new `boxName` appears in lib/ and nobody has decided
// whether it belongs in a backup.
void _driftGuard() {
  group('settings backup coverage', () {
    /// Boxes deliberately left out, each with the reason it must stay out.
    /// Adding one here is a decision; leaving a box in neither list is a bug.
    const excluded = <String, String>{
      // Secrets / tokens — must never leave the device in a backup file.
      'anilist': 'oauth token',
      'mal': 'oauth token',
      'simkl': 'oauth token',
      'mangabaka': 'oauth token',
      'discord': 'rpc token',
      'auth_cache': 'session cache',
      'stremio_installations': 'requires device-local secure addon URLs',
      // Device-specific: holds a SAF content:// URI that is meaningless (and
      // unwritable) on another device.
      'download_prefs': 'device-specific download location',
      // Reference source ids the restoring device may not have installed.
      'pinned_sources': 'source ids',
      'subscriptions': 'source ids',
      // Only the hand-made (pinned) matches are saved, through
      // SettingsBackup.matchesBox, never the automatic guesses.
      'zmode_matches': 'pinned matches only, via SettingsBackup.matchesBox',
      // Installed sources — carried by the separate Sources bundle.
      'provider_settings': 'sources bundle',
      'provider_registry': 'sources bundle',
      'provider_repos': 'sources bundle',
      'cs_repos': 'sources bundle',
      'aniyomi_installed': 'sources bundle',
      'lnreader_plugins': 'sources bundle',
      // User data — carried by the library backup, not settings.
      'my_list': 'library backup',
      'watch_history': 'library backup',
      'read_history': 'library backup',
      'resume_positions': 'library backup',
      'read_positions': 'library backup',
      'list_status': 'library backup',
      'list_categories': 'library backup',
      'tracker_bindings': 'library backup',
      'reader_overrides': 'per-title, library-shaped',
      'chapter_downloads': 'downloads, not settings',
      'downloads': 'downloads, not settings',
      // Offline details cache for downloaded shows; rebuilt on demand.
      'downloaded_show_details': 'download cache, not settings',
      // Caches and transient state — regenerated, never restored.
      'logo_cache': 'cache',
      'provider_js_cache': 'cache',
      'episode_meta': 'cache',
      'skip_times': 'cache of intro/outro times, refetched online',
      'cf_clearance': 'cache',
      'genre_catalog': 'cache',
      // Icon URLs picked back up the next time a repo index is read.
      'source_icons': 'cache',
      'source_health': 'transient',
      'zmode_source_score': 'derived play counts, rebuilt from use',
      'updates': 'transient',
      'announcements': 'transient',
      'search_history': 'transient',
      'content_mode': 'restored per device',
      'home_cache': 'cache',
      // Windows "Schedule and lists" tiles and airing rows, refetched online.
      'lists_hub_cache': 'cache',
      // Windows window/close/folder choices: device-specific (an automatic
      // backup folder path means nothing on another PC).
      'desktop_prefs': 'device-specific Windows settings',
      // New-episode alerts already shown on this device.
      'new_episode_inbox': 'transient',
      // Pending tracker pushes, retried online; not a setting.
      'tracker_sync_queue': 'transient',
      // Offline copy of the airing schedule, refetched online.
      'schedule_offline_cache': 'cache',
    };

    test('every settings box is either backed up or explicitly excluded', () {
      final declared = <String>{};
      final re = RegExp(r"boxName\s*=\s*'([a-z0-9_]+)'");
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        for (final m in re.allMatches(f.readAsStringSync())) {
          declared.add(m.group(1)!);
        }
      }
      expect(declared, isNotEmpty, reason: 'the scan itself must find boxes');

      final unclassified =
          declared
              .where((b) => !SettingsBackup.boxNames.contains(b))
              .where((b) => !excluded.containsKey(b))
              .toList()
            ..sort();

      expect(
        unclassified,
        isEmpty,
        reason:
            'These Hive boxes are neither backed up nor listed as excluded.\n'
            'Add each to SettingsBackup.boxNames if it holds user settings, or\n'
            'to this test\'s `excluded` map with the reason it should not be\n'
            'restored: $unclassified',
      );
    });

    test('no backed-up box is also on the excluded list', () {
      for (final b in SettingsBackup.boxNames) {
        expect(excluded.containsKey(b), isFalse, reason: '$b is in both lists');
      }
    });
  });
}
