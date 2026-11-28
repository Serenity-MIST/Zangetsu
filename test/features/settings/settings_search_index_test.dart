import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/settings/settings_search_index.dart';
import 'package:watch_app/l10n/app_localizations_en.dart';
import 'package:watch_app/l10n/app_localizations_fr.dart';

/// Settings pages render their rows inline, so nothing links a new toggle to
/// the search index automatically. This reads the sources and fails when a
/// rendered setting isn't indexed — otherwise the index silently rots and the
/// setting becomes unfindable, which is the bug this feature exists to fix.
///
/// Since the l10n migration the rows read `title: l10n.someKey`, so we resolve
/// each key through `app_en.arb` and compare against the leaves resolved in
/// English. Matching on the English *value* rather than the key keeps the index
/// free of duplicated key names.
final _titleKey = RegExp(r'\btitle: (?:l10n|sheetL10n|context\.l10n)\.(\w+)');

/// Sub-page → the [LeafParent] whose row opens it.
const _pages = {
  'lib/features/settings/settings_playback.dart': LeafParent.playback,
  'lib/features/settings/reader_settings_screen.dart': LeafParent.reader,
  'lib/features/settings/appearance_screen.dart': LeafParent.appearance,
  'lib/features/settings/settings_privacy.dart': LeafParent.privacy,
  'lib/features/settings/settings_storage.dart': LeafParent.storage,
  'lib/features/settings/download_location_screen.dart': LeafParent.downloads,
};

void main() {
  final en = AppLocalizationsEn();
  final arb =
      jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
          as Map<String, dynamic>;

  group('settings search index', () {
    test('covers every setting its sub-pages render', () {
      final missing = <String>[];
      for (final entry in _pages.entries) {
        final file = File(entry.key);
        expect(file.existsSync(), isTrue, reason: '${entry.key} moved');
        final indexed = settingsLeaves
            .where((l) => l.parentId == entry.value)
            .map((l) => l.title(en))
            .toSet();
        for (final m in _titleKey.allMatches(file.readAsStringSync())) {
          final key = m.group(1)!;
          final english = arb[key] as String?;
          if (english == null) continue; // not a title string we can resolve
          if (!indexed.contains(english)) {
            missing.add('${entry.value}: $key ("$english")');
          }
        }
      }
      expect(
        missing,
        isEmpty,
        reason:
            'Add these to settingsLeaves in settings_search_index.dart, or '
            'they cannot be found from "Search settings":\n  '
            '${missing.join('\n  ')}',
      );
    });

    test('every leaf names a real category, and resolves to a title', () {
      const known = {
        LeafParent.playback,
        LeafParent.reader,
        LeafParent.appearance,
        LeafParent.privacy,
        LeafParent.storage,
        LeafParent.downloads,
        LeafParent.homeRows,
      };
      for (final l in settingsLeaves) {
        expect(known, contains(l.parentId));
        expect(l.title(en).trim(), isNotEmpty);
      }
      // Windows may route a leaf to the Download location page as well.
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        for (final l in settingsLeaves) {
          expect(
            // Windows-only categories: download folder, Window & system and
            // Keyboard shortcuts.
            {
              ...known,
              LeafParent.downloadLocation,
              LeafParent.windowSystem,
              LeafParent.keyboardShortcuts,
            },
            contains(l.parentId),
          );
        }
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    // Every leaf Windows offers must name a row its target page renders on
    // Windows. Pairs are `parent:title` in English.
    test('Windows offers exactly the rows its pages render', () {
      Set<String> visible() => {
        for (final l in settingsLeaves)
          if (l.isVisible) '${l.parentId}:${l.title(en)}',
      };
      final phone = visible();
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final Set<String> windows;
      try {
        windows = visible();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }

      // Rows the Windows pages do not render (Android/TV-only rows, picker
      // and dialog titles).
      const absentOnWindows = [
        'playback:Default audio',
        'playback:Video renderer',
        'playback:Default player',
        'playback:Native TV player',
        'playback:Show video seek buttons',
        'playback:Double-tap skip',
        'playback:Swipe to seek',
        'playback:Hold for 2× speed',
        'reader:Orientation lock',
        'reader:Tap zones',
        'privacy:Show adult titles?',
        'privacy:Enable NSFW sources?',
        'privacy:Show NSFW Aniyomi sources?',
        'downloads:Keep downloads private',
      ];
      for (final key in absentOnWindows) {
        expect(windows, isNot(contains(key)), reason: key);
        // Each sample must exist on phone, or the check is vacuous.
        expect(phone, contains(key), reason: key);
      }
      for (final l in settingsLeaves) {
        final t = l.title(en);
        // Android/TV-only leaves resolved by l10n key, in any language.
        for (final hidden in [
          en.autoPictureInPicture,
          en.gestureControls,
          en.autoPlayerFallback,
          en.androidPlayerCache,
          en.tvDecoderMode,
          en.softwareAudioDolbyDTS,
          en.materialYou,
          en.mangaTranslationSettings,
          en.mangaTranslationAppearance,
          en.keepDownloadsPrivate,
          en.videoRenderer,
          en.defaultPlayer,
        ]) {
          if (t == hidden) {
            expect(windows.any((k) => k.endsWith(':$t')), isFalse, reason: t);
          }
        }
      }

      // Rows Windows renders, under the page that renders them.
      const presentOnWindows = [
        'playback:Player controls',
        'playback:Seek Duration',
        'playback:Play downloaded copy if streaming fails',
        'playback:Default audio (anime sub/dub)',
        'reader:Keep screen on',
        'reader:Fullscreen',
        'appearance:Background colour',
        'appearance:Title logo on Detail',
        'appearance:App font',
        'appearance:Reverse episode list always on',
        'privacy:Enable NSFW sources',
        'storage:Clear image cache',
        'downloadLocation:Choose folder…',
        'downloadLocation:Reset to default',
        'downloadLocation:Open in File Explorer',
        'homeRows:Customise Home',
      ];
      for (final key in presentOnWindows) {
        expect(windows, contains(key), reason: key);
      }
      // Download location rows never open the Downloads page on Windows.
      expect(windows.where((k) => k.startsWith('downloads:')), isEmpty);

      // Phone keeps its routes and rows.
      expect(phone, contains('downloads:Choose folder…'));
      expect(phone, contains('downloads:Keep downloads private'));
      expect(phone, contains('playback:Default audio'));
      expect(phone, isNot(contains('appearance:App font')));
      expect(phone, isNot(contains('downloads:Open in File Explorer')));
    });

    test('Windows-only search words match on Windows only', () {
      Iterable<String> hits(String q) => settingsLeaves
          .where((l) => l.isVisible && l.matches(q, en))
          .map((l) => l.title(en));
      // Windows has no "Player opens in" row any more (the player always
      // opens on the watch page), so no platform finds it.
      for (final q in ['player opens in', 'watch page', 'full window']) {
        expect(hits(q), isNot(contains('Player opens in')), reason: q);
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        try {
          expect(hits(q), isNot(contains('Player opens in')), reason: q);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      }
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        expect(hits('f11'), contains(en.readerFullscreen));
        expect(hits('arrow keys'), contains(en.seekButtonDuration));
        // Phone rotation words do not lead to the Windows row.
        for (final q in ['rotate', 'portrait', 'landscape']) {
          expect(hits(q), isNot(contains('Player opens in')), reason: q);
          expect(hits(q), isNot(contains(en.orientationLock)), reason: q);
        }
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
      expect(hits('f11'), isEmpty);
    });

    // The two reports that started this: "autoplay" only found the Playback
    // folder, and "anime4k" found nothing at all.
    test('finds the settings that used to be unreachable', () {
      Iterable<String> hits(String q) => settingsLeaves
          .where((l) => l.matches(q, en))
          .map((l) => l.title(en));

      expect(hits('autoplay'), contains('Autoplay next episode'));
      expect(hits('autoplay'), contains('Autoplay trailer'));
      expect(hits('anime4k'), contains('Anime4K Enhancement'));
      expect(hits('adaptive'), contains('Adaptive colour'));
    });

    test('matches synonyms nobody spells out', () {
      Iterable<String> hits(String q) => settingsLeaves
          .where((l) => l.matches(q, en))
          .map((l) => l.title(en));

      expect(hits('pip'), contains('Auto picture-in-picture'));
      expect(hits('scrobble'), contains('Auto-track'));
      expect(hits('oled'), contains('Pure black background'));
    });

    // Windows search must not return rows its pages hide; phone and TV keep
    // every leaf. Titles checked in English.
    test('Windows drops leaves for rows hidden on Windows only', () {
      Set<String> visible() => {
        for (final l in settingsLeaves)
          if (l.isVisible) '${l.parentId}:${l.title(en)}',
      };
      final phone = visible();
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final Set<String> windows;
      try {
        windows = visible();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
      const hiddenOnWindows = [
        'playback:TV decoder priority',
        'playback:Auto picture-in-picture',
        'playback:Gesture controls',
        'appearance:Material You',
        'reader:Tap zones',
      ];
      for (final key in phone.where((k) => hiddenOnWindows.any(k.startsWith))) {
        expect(windows, isNot(contains(key)), reason: key);
      }
      // Each sample above must exist on phone, or the check is vacuous.
      expect(
        hiddenOnWindows.where((h) => phone.any((k) => k.startsWith(h))),
        hasLength(hiddenOnWindows.length),
        reason: 'phone index: $phone',
      );
      // Windows still finds its own settings.
      expect(windows, contains('playback:Autoplay next episode'));
      expect(windows, contains('appearance:Pure black background'));
      // Windows has neither the orientation row nor "Player opens in".
      expect(windows, isNot(contains('playback:Player opens in')));
      expect(windows, isNot(contains('playback:Orientation lock')));
      expect(phone, contains('playback:Orientation lock'));
      // Without the bundled engine, the Aniyomi NSFW switch is not offered.
      expect(windows, isNot(contains('privacy:Show NSFW sources')));
      expect(phone, contains('privacy:Show NSFW sources'));
    });

    test('Home rows leaf opens the Home rows page, not Theme & colour', () {
      final leaf = settingsLeaves.firstWhere(
        (l) => l.title(en) == en.homeRows,
      );
      expect(leaf.parentId, LeafParent.homeRows);
    });

    test('no setting is indexed twice under the same page', () {
      final seen = <String>{};
      final dupes = <String>[];
      for (final l in settingsLeaves) {
        if (!seen.add('${l.parentId}:${l.title(en)}')) {
          dupes.add('${l.parentId}:${l.title(en)}');
        }
      }
      expect(dupes, isEmpty);
    });

    // The whole point of reading titles through l10n: a French user searching
    // French finds the setting, and the result reads in French.
    test('searches and reads in the active language', () {
      final fr = AppLocalizationsFr();
      final autoplay = settingsLeaves.firstWhere(
        (l) => l.title(en) == 'Autoplay next episode',
      );
      expect(autoplay.title(fr), isNot('Autoplay next episode'));
      expect(autoplay.matches(autoplay.title(fr).toLowerCase(), fr), isTrue);
    });
  });
}
