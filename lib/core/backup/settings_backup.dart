import 'backup_boxes.dart';

/// Codec that dumps and restores the plain preference Hive boxes.
///
/// Excluded intentionally:
///   - `discord`           — may hold the RPC auth token
///   - `provider_settings` — belongs to the Sources bundle
///   - `auth_cache`        — authentication token cache
///   - `*_cache`           — transient caches, not user preferences
///   - `genre_catalog`     — AniList's genre list, re-fetched on demand
///   - `download_prefs`    — holds the download LOCATION, which on a custom
///                           folder is a device-specific SAF `content://` URI.
///                           Restoring it onto another phone points downloads
///                           at a folder that does not exist and cannot be
///                           written. Add only with per-key handling.
///   - `pinned_sources`, `subscriptions` — reference source ids the restoring
///                           device may not have installed
///
/// `zmode_matches` is handled on its own (see [matchesBox]): only the
/// HAND-MADE matches ("Wrong title?" fixes and per-title source choices) are
/// saved, never the automatic guesses. A pin for a source the restoring device
/// lacks is harmless: the app ignores matches for sources that aren't
/// installed and uses them again once the source is reinstalled.
///
/// Every box here must be OPENED DURING BOOTSTRAP. [_boxFor] returns null for a
/// closed box and [build] skips it silently, so a lazily-opened box would look
/// backed up and quietly save nothing.
class SettingsBackup {
  static const List<String> boxNames = [
    'playback_prefs', // player, subtitle style, DNS, speed, etc.
    'app_prefs', // active source + app-level prefs
    'search_prefs', // search source inclusion prefs
    'title_prefs', // per-title remembered quality
    // Added 2026-08-29 — these are plain user settings that were simply never
    // added as the features landed, so a restore silently lost them.
    'reader_prefs', // manga/novel reader defaults + tap zones
    'theme_prefs', // accent colour, Material You
    'nav_prefs', // which tabs the bottom bar shows, and their order
    'search_view_prefs', // search layout (grid vs rows)
    'ui_prefs', // list sort / reveal animation
    'tracker_switch_prefs', // last-selected list view
    'privacy_prefs', // incognito
    'novel_lang_prefs', // novel language filter
    'torrent_prefs', // torrent settings
    'locale_prefs', // app language override
    'zmode_prefs', // Zangetsu Mode toggle + stream kind
    'source_domain_overrides', // per-source domain the user set by hand
    'zmode_source', // which source plays each kind in Zangetsu Mode
    'metadata_provider', // AniList vs MAL for anime metadata
    'app_font_prefs', // the UI font
    'home_rows_prefs', // per-layout home row order + visibility
    'streaming_prefs', // streaming-service region + pinned service rows
    'zmode_source_order', // Source Priority: which source Auto Resolve tries first
    'viewer_profiles', // per-account profile names and Kids-mode preference
    // The source-language filters: the same kind of setting as
    // novel_lang_prefs above (which languages a catalogue shows).
    'manga_lang_prefs',
    'aniyomi_lang_prefs',
    'mangayomi_lang_prefs',
  ];

  /// Per-title source matches. Only pinned (hand-made) entries and the title
  /// names remembered for them are backed up; see the class comment.
  static const String matchesBox = 'zmode_matches';

  /// Prefix of the remembered title-name entries in [matchesBox].
  static const String _matchLabelPrefix = 'label:';

  /// Every box a settings restore can write to. The safety copy taken before
  /// a restore snapshots these so 'Undo restore' can put them all back.
  static const List<String> restoredBoxNames = [...boxNames, matchesBox];

  /// Returns a map of `{boxName: {key: value, ...}}` for every open box.
  /// Closed boxes are silently skipped.
  Map<String, dynamic> build() {
    final out = <String, dynamic>{};
    for (final name in boxNames) {
      final box = _boxFor(name);
      if (box == null) continue;
      out[name] = Map<String, dynamic>.from(
        (box.toMap() as Map).map((k, v) => MapEntry(k.toString(), v)),
      );
    }
    final matches = _buildPinnedMatches();
    if (matches != null) out[matchesBox] = matches;
    return out;
  }

  /// The pinned matches plus the remembered names of those titles, or null
  /// when the match box isn't open. Match keys are `'<kind>:<id>@<sourceId>'`.
  Map<String, dynamic>? _buildPinnedMatches() {
    final box = anyOpenBox(matchesBox);
    if (box == null) return null;
    final out = <String, dynamic>{};
    final titles = <String>{};
    for (final k in box.keys) {
      if (k is! String) continue;
      final v = box.get(k);
      if (v is! Map || v['pinned'] != true) continue;
      final at = k.indexOf('@');
      if (at <= 0) continue; // not a match entry
      out[k] = plainCopy(v);
      titles.add(k.substring(0, at));
    }
    // The title name shown on the Manual matches page, for pinned titles only.
    for (final t in titles) {
      final label = box.get('$_matchLabelPrefix$t');
      if (label is Map) out['$_matchLabelPrefix$t'] = plainCopy(label);
    }
    return out;
  }

  /// Puts backed-up pins back. A restored pin becomes the title's choice, so
  /// any other pin on the same title is demoted to a plain guess first (one
  /// title has one chosen source, as MatchStore.pin does). Remembered title
  /// names are only added when missing.
  Future<void> _mergePinnedMatches(Map raw) async {
    final box = anyOpenBox(matchesBox);
    if (box == null) return;
    for (final e in raw.entries) {
      final key = e.key.toString();
      final value = e.value;
      if (value is! Map) continue;
      if (key.startsWith(_matchLabelPrefix)) {
        if (!box.containsKey(key)) await box.put(key, Map.of(value));
        continue;
      }
      final at = key.indexOf('@');
      if (at <= 0 || value['pinned'] != true) continue;
      final prefix = key.substring(0, at + 1);
      for (final other in box.keys.toList()) {
        if (other is! String || other == key || !other.startsWith(prefix)) {
          continue;
        }
        final m = box.get(other);
        if (m is Map && m['pinned'] == true) {
          await box.put(other, {...m, 'pinned': false});
        }
      }
      await box.put(key, Map.of(value));
    }
  }

  /// Overwrites each box with the entries from [data].
  /// Closed boxes and unknown box names are silently skipped.
  /// Never calls `clear()` — only `putAll`.
  Future<void> merge(Map<String, dynamic> data) async {
    for (final entry in data.entries) {
      final kv = entry.value;
      if (kv is! Map) continue;
      // Hand-made matches merge on their own (pins stay exclusive per title).
      if (entry.key == matchesBox) {
        await _mergePinnedMatches(kv);
        continue;
      }
      final box = _boxFor(entry.key);
      if (box == null) continue;
      // Per-key put (not putAll): a Box<Map> rejects a Map<String,dynamic> whose
      // static value type isn't Map, whereas put() checks each value at runtime.
      for (final e in kv.entries) {
        await box.put(e.key, e.value);
      }
    }
  }

  /// The already-open box for [name] regardless of the type it was opened with:
  /// some prefs boxes are `Box<Map>` (e.g. `title_prefs`), some `Box<String>`
  /// (e.g. `source_domain_overrides`), others `Box<dynamic>`, and a mismatched
  /// `Hive.box<E>(name)` throws. Null when the box isn't open (or is an
  /// unexpected type) — a listed box that lands here saves NOTHING while still
  /// looking backed up, which is why every type in [boxNames] needs a case.
  dynamic _boxFor(String name) {
    // The match box is only ever read and written through its pinned-only path.
    if (name == matchesBox) return null;
    // Shared lookup that also knows Box<List> (zmode_source_order), which the
    // old Map/String/dynamic tries missed.
    return anyOpenBox(name);
  }
}
