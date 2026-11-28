import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/desktop/desktop_prefs.dart';
import 'package:watch_app/features/downloads/desktop_download_settings_dialog.dart';
import 'package:watch_app/l10n/app_localizations_en.dart';
import 'package:watch_app/l10n/l10n.dart';

// The words on the Windows "Download settings" slider rows ("at once",
// "connection(s)" and "Default: ...") come from the translations, not from
// English typed into the widgets. English still reads exactly as before.

/// English with the three slider words swapped, so the test can tell the
/// dialog really asks the translations for them.
class _MarkedL10n extends AppLocalizationsEn {
  @override
  String get desktopDownloadsAtOnceUnit => 'AT-ONCE';

  @override
  String desktopConnectionsUnit(int count) => count == 1 ? 'CONN' : 'CONNS';

  @override
  String desktopSliderDefaultValue(String value) => 'STD=$value';
}

class _MarkedDelegate extends LocalizationsDelegate<AppLocalizations> {
  const _MarkedDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<AppLocalizations> load(Locale locale) =>
      SynchronousFuture<AppLocalizations>(_MarkedL10n());

  @override
  bool shouldReload(_MarkedDelegate old) => false;
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('dl_dialog_words');
    Hive.init(dir.path);
    await DesktopPrefs.init();
  });

  tearDown(() async {
    await Hive.close();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> pumpDialog(
    WidgetTester tester, {
    required int connections,
    bool marked = false,
  }) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: marked
            ? const [
                _MarkedDelegate(),
                DefaultMaterialLocalizations.delegate,
                DefaultWidgetsLocalizations.delegate,
              ]
            : null,
        home: Scaffold(
          body: DesktopDownloadSettingsDialog(
            parallel: 3,
            connections: connections,
            onParallelChanged: (_) {},
            onParallelCommit: (_) {},
            onConnectionsChanged: (_) {},
            onConnectionsCommit: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder inRow(String key, String text) =>
      find.descendant(of: find.byKey(ValueKey(key)), matching: find.text(text));

  test('English words are unchanged', () {
    final en = AppLocalizationsEn();
    expect(en.desktopDownloadsAtOnceUnit, 'at once');
    expect(en.desktopConnectionsUnit(1), 'connection');
    expect(en.desktopConnectionsUnit(4), 'connections');
    expect(
      en.desktopSliderDefaultValue('4 connections'),
      'Default: 4 connections',
    );
  });

  testWidgets('English dialog reads as before', (tester) async {
    await pumpDialog(tester, connections: 1);
    expect(inRow('desktop-parallel-downloads', ' at once'), findsOneWidget);
    expect(
      inRow('desktop-parallel-downloads', '  ·  Default: 3 at once'),
      findsOneWidget,
    );
    // One connection is singular; the default (4) stays plural.
    expect(
      inRow('desktop-connections-per-download', ' connection'),
      findsOneWidget,
    );
    expect(
      inRow('desktop-connections-per-download', '  ·  Default: 4 connections'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('slider words come from the translations', (tester) async {
    await pumpDialog(tester, connections: 8, marked: true);
    expect(inRow('desktop-parallel-downloads', ' AT-ONCE'), findsOneWidget);
    expect(
      inRow('desktop-parallel-downloads', '  ·  STD=3 AT-ONCE'),
      findsOneWidget,
    );
    expect(inRow('desktop-connections-per-download', ' CONNS'), findsOneWidget);
    expect(
      inRow('desktop-connections-per-download', '  ·  STD=4 CONNS'),
      findsOneWidget,
    );
    expect(find.text(' at once'), findsNothing);
    expect(find.textContaining('  ·  Default:'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
