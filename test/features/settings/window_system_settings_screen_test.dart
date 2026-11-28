import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/desktop/desktop_prefs.dart';
import 'package:watch_app/core/desktop/desktop_shortcuts.dart';
import 'package:watch_app/core/ui/nav_prefs.dart';
import 'package:watch_app/features/settings/window_system_settings_screen.dart';

// set-7: the Windows 'Window & system' page shows its rows, stores the
// close-button choice where the close guard reads it, and edits the same
// start page RootShell opens on (NavPrefs.startTab).
void main() {
  late Directory dir;

  setUp(() async {
    // Gate UI as Windows without touching the host OS checks.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    dir = await Directory.systemTemp.createTemp('window_system_test');
    Hive.init(dir.path);
    // In-memory boxes: a file-backed write started from a tap inside the
    // widget tester's fake clock never finishes, which hung tearDown's
    // Hive.close until the 10-minute timeout. Both inits reuse these.
    await Hive.openBox<dynamic>(DesktopPrefs.boxName, bytes: Uint8List(0));
    await Hive.openBox(NavPrefs.boxName, bytes: Uint8List(0));
    DesktopShortcuts.debugReset();
    await DesktopPrefs.init();
    await NavPrefs.init();
    GetIt.instance.registerSingleton<NavPrefs>(NavPrefs());
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await GetIt.instance.reset();
    DesktopShortcuts.debugReset();
    // Memory boxes cannot be deleted from disk; closing drops them.
    await Hive.close();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(home: WindowSystemSettingsScreen()),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows the Option A rows', (tester) async {
    await pump(tester);
    expect(find.text('Launch at sign-in'), findsOneWidget);
    expect(find.text('Close button'), findsOneWidget);
    expect(find.text('Remember window size and position'), findsOneWidget);
    expect(find.text('Start page'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('close button choice is stored for the close guard', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('Close button'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Always keep running in the tray').last);
    await tester.pumpAndSettle();
    expect(DesktopPrefs.closeBehaviour, DesktopCloseBehaviour.alwaysTray);
    // Raw name the native close guard reads.
    expect(
      Hive.box<dynamic>(DesktopPrefs.boxName).get(
        DesktopPrefs.closeBehaviourKey,
      ),
      'alwaysTray',
    );
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('start page edits NavPrefs.startTab', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Start page'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(DockTab.downloads.label).last);
    await tester.pumpAndSettle();
    expect(GetIt.instance<NavPrefs>().startTab, DockTab.downloads);
    expect(find.text(DockTab.downloads.label), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}
