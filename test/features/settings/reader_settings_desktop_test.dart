import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/reading/reader_prefs.dart';
import 'package:watch_app/core/ui/desktop_settings_surface.dart';
import 'package:watch_app/features/settings/reader_settings_screen.dart';
import 'package:watch_app/features/reader/reader_auto_scroll_ui.dart';

/// Starts preference writes outside the widget test's fake timer zone while
/// retaining the real Hive backend and persistence behavior under test.
class _DiskReaderPrefs extends ReaderPrefs {
  late WidgetTester tester;
  Future<void>? pending;

  Future<void> _write(Future<void> Function() write) async {
    pending = tester.runAsync(write);
    await pending;
  }

  @override
  Future<void> setDirection(String value) =>
      _write(() => super.setDirection(value));
  @override
  Future<void> setKeepScreenOn(bool value) =>
      _write(() => super.setKeepScreenOn(value));
  @override
  Future<void> setFullscreen(bool value) =>
      _write(() => super.setFullscreen(value));
  @override
  Future<void> setFontSize(double value) =>
      _write(() => super.setFontSize(value));
  @override
  Future<void> setLineHeight(double value) =>
      _write(() => super.setLineHeight(value));
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

  /// The Windows settings page: desktop scope, 1280x720 window.
  Future<void> pumpDesktop(WidgetTester tester, {double height = 720}) async {
    tester.view.physicalSize = Size(1280, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(
        home: DesktopSettingsScope(child: ReaderSettingsScreen()),
      ),
    );
  }

  testWidgets(
    'Windows reader settings drop OCR translation and show shared rows once',
    (tester) async {
      prefs.tester = tester;
      // Tall enough that the whole page is built at once.
      await pumpDesktop(tester, height: 3000);
      expect(find.text('Reader'), findsWidgets);
      expect(find.text('Manga page translation'), findsNothing);
      expect(find.text('Manga translation appearance'), findsNothing);
      expect(
        find.text('Page OCR is not available on Windows yet'),
        findsNothing,
      );
      expect(find.text('Tap zones'), findsNothing);
      expect(find.text('Orientation lock'), findsNothing);

      expect(find.text('Both readers'), findsOneWidget);
      expect(find.text('Keep screen on'), findsOneWidget);
      expect(find.text('Fullscreen'), findsOneWidget);

      // Each shared toggle persists the single preference both readers read.
      final keepOn = prefs.keepScreenOn;
      await tester.tap(find.text('Keep screen on'));
      await tester.pump();
      await prefs.pending;
      await tester.pumpAndSettle();
      expect(ReaderPrefs().keepScreenOn, !keepOn);
      final full = prefs.fullscreen;
      await tester.tap(find.text('Fullscreen'));
      await tester.pump();
      await prefs.pending;
      await tester.pumpAndSettle();
      expect(ReaderPrefs().fullscreen, !full);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'phone reader settings are unchanged: translation and both rows per reader',
    (tester) async {
      prefs.tester = tester;
      tester.view.physicalSize = const Size(400, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const MaterialApp(home: ReaderSettingsScreen()));
      expect(find.text('Manga page translation'), findsOneWidget);
      expect(find.text('Manga translation appearance'), findsOneWidget);
      expect(find.text('Both readers'), findsNothing);
      // Manga and Novel cards each keep their own copy of the shared toggles.
      expect(find.text('Keep screen on'), findsNWidgets(2));
      expect(find.text('Fullscreen'), findsNWidgets(2));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'Windows sliders are Graphite rows that save clean stepped values',
    (tester) async {
      prefs.tester = tester;
      await pumpDesktop(tester);
      final fontRow = find.text('Font size');
      await tester.scrollUntilVisible(fontRow, 300);
      await tester.pumpAndSettle();
      // The shared Windows slider row keeps a per-title key on its slider.
      final slider = find.byKey(const ValueKey('reader-slider-Font size'));
      expect(slider, findsOneWidget);
      // Windows text sizes run 10-40 in whole steps (reader-11 B).
      expect(tester.widget<Slider>(slider).divisions, 30);
      // Drag most of the way right; the stored size is a whole number.
      await tester.drag(slider, const Offset(250, 0));
      await tester.pump();
      await prefs.pending;
      await tester.pumpAndSettle();
      final size = ReaderPrefs().fontSize;
      expect(size, size.roundToDouble());
      expect(size, greaterThan(16));
      expect(
        find.byKey(const ValueKey('reader-slider-value-Font size')),
        findsOneWidget,
      );
      expect(find.text('${size.round()}'), findsWidgets);

      final lineRow = find.text('Line height');
      await tester.scrollUntilVisible(lineRow, 200);
      await tester.pumpAndSettle();
      final line = find.byKey(const ValueKey('reader-slider-Line height'));
      await tester.drag(line, const Offset(120, 0));
      await tester.pump();
      await prefs.pending;
      await tester.pumpAndSettle();
      final height = ReaderPrefs().lineHeight;
      expect((height * 10).roundToDouble() / 10, height);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
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
