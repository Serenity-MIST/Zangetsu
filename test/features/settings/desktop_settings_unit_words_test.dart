// The Windows settings slider units (Reader, Playback, Source priority), the
// "already downloaded" note and the browser sign-in hint come from l10n now.
// The English words must read exactly as the old fixed strings did.
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/l10n/app_localizations.dart';

void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  test('slider units keep their English singular and plural', () {
    expect(en.desktopPagesAheadUnit(1), 'page ahead');
    expect(en.desktopPagesAheadUnit(3), 'pages ahead');
    expect(en.desktopSecondsUnit(1), 'second');
    expect(en.desktopSecondsUnit(85), 'seconds');
    expect(en.desktopSourcesUnit(1), 'source');
    expect(en.desktopSourcesUnit(4), 'sources');
  });

  test('the note and the sign-in hint read as before', () {
    expect(
      en.desktopEpisodesAlreadyDownloaded,
      'These episodes are already downloaded.',
    );
    expect(
      en.desktopApproveInBrowserHint,
      'Approve in your browser, then choose "Open Zangetsu". '
      'Click here to cancel.',
    );
  });

  test('the pages no longer carry the fixed English words', () {
    String read(String path) => File(path).readAsStringSync();
    expect(
      read('lib/features/settings/reader_settings_screen.dart'),
      isNot(contains("'pages ahead'")),
    );
    expect(
      read('lib/features/settings/settings_playback.dart'),
      isNot(contains("? 'second' : 'seconds'")),
    );
    expect(
      read('lib/features/settings/source_priority_screen.dart'),
      isNot(contains("? 'source' : 'sources'")),
    );
    for (final page in [
      'lib/features/settings/discord_settings_screen.dart',
      'lib/features/settings/tracker_settings_screen.dart',
    ]) {
      expect(read(page), isNot(contains("'Approve in your browser")));
    }
    expect(
      read('lib/features/detail/detail_screen.dart'),
      isNot(contains("'These episodes are already downloaded.'")),
    );
  });
}
