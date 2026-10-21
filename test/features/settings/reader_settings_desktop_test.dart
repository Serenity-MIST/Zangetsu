import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/reading/reader_prefs.dart';
import 'package:watch_app/features/settings/reader_settings_screen.dart';
import 'package:watch_app/features/reader/reader_auto_scroll_ui.dart';

/// Starts preference writes outside the widget test's fake timer zone while
/// retaining the real Hive backend and persistence behavior under test.
class _DiskReaderPrefs extends ReaderPrefs {
  late WidgetTester tester;
  Future<void>? pending;
  @override
  Future<void> setDirection(String value) async {
    pending = tester.runAsync(() => super.setDirection(value));
    await pending;
  }
}

void main() {
  late Directory directory;
  late _DiskReaderPrefs prefs;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('reader_pc_settings');
    Hive.init(directory.path);
    await ReaderPrefs.init();
    prefs = _DiskReaderPrefs();
    sl.registerSingleton<ReaderPrefs>(prefs);
  });
  tearDown(() async {
    await sl.reset();
    await Hive.close();
    await directory.delete(recursive: true);
  });

  testWidgets(
    'desktop reader settings hide touch-only controls and explain OCR capability',
    (tester) async {
      prefs.tester = tester;
      await tester.pumpWidget(const MaterialApp(home: ReaderSettingsScreen()));
      expect(find.text('Reader'), findsOneWidget);
      if (Platform.isWindows) {
        expect(find.text('Tap zones'), findsNothing);
        expect(find.text('Orientation lock'), findsNothing);
        expect(
          find.text('Page OCR is not available on Windows yet'),
          findsOneWidget,
        );
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reading mode picker persists the selected mode', (tester) async {
    prefs.tester = tester;
    await tester.pumpWidget(const MaterialApp(home: ReaderSettingsScreen()));
    await tester.tap(find.text('Reading mode'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Right to left'));
    // The route result resumes the picker in the test's fake-async zone. Pump
    // that continuation first so its actual write starts BEFORE flushing real
    // disk I/O; flushing inside runAsync around tap can run before the write.
    await tester.pump();
    await prefs.pending;
    await tester.pumpAndSettle();
    expect(ReaderPrefs().direction, 'rtl');
    expect(
      find.text('Right to left'),
      findsOneWidget,
      reason:
          'Picker must refresh its visible selected value after persistence. '
          'Mounted texts: ${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).toList()}',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'desktop auto-scroll keeps speed and enable without a dead phone-button setting',
    (tester) async {
      var running = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderAutoScrollSheet(
              desktop: true,
              running: true,
              speed: 4,
              showButton: true,
              onToggle: (value) => running = value,
              onSpeed: (_) {},
              onShowButton: (_) {},
            ),
          ),
        ),
      );
      expect(find.byType(Slider), findsOneWidget);
      expect(find.byType(Switch), findsOneWidget);
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(running, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}
