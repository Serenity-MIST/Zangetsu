// Dock customization regressions cover the desktop editor and unchanged phone
// presentation. Hidden choices must be scrolled into view before asserting
// availability; unbuilt lazy rows are not evidence that an option was removed.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/ui/nav_prefs.dart';
import 'package:watch_app/core/ui/desktop_settings_surface.dart';
import 'package:watch_app/core/zmode/zmode_prefs.dart';
import 'package:watch_app/features/settings/nav_tabs_screen.dart';

class _MemoryNavPrefs extends NavPrefs {
  bool _keepDockExpanded = false;

  @override
  bool get keepDockExpanded => _keepDockExpanded;

  @override
  Future<void> setKeepDockExpanded(bool value) async {
    _keepDockExpanded = value;
    notifyListeners();
  }
}

void main() {
  late Directory dir;
  late NavPrefs navPrefs;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('nav_tabs_screen_test');
    Hive.init(dir.path);
    await NavPrefs.init();
    await ZModePrefs.init();
    // On by default since the Settings toggle was removed; these tests cover
    // both paths, so start from off and let each one opt in.
    await ZModePrefs.setEnabled(false);
    navPrefs = _MemoryNavPrefs();

    await sl.reset();
    sl.registerSingleton<NavPrefs>(navPrefs);
  });

  tearDown(() async {
    await sl.reset();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  testWidgets('desktop dock add/remove/start/move/reset persist real choices', (
    tester,
  ) async {
    await sl.unregister<NavPrefs>();
    navPrefs = NavPrefs();
    sl.registerSingleton<NavPrefs>(navPrefs);
    await tester.pumpWidget(
      const MaterialApp(home: DesktopSettingsScope(child: NavTabsScreen())),
    );
    await tester.pumpAndSettle();
    final search = find.byKey(const ValueKey('dock-add-search'));
    expect(search, findsOneWidget); // real hidden option, not an unbuilt row
    expect(tester.widget<OutlinedButton>(search).onPressed, isNull); // full
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('dock-remove-sources')));
      await Hive.box(NavPrefs.boxName).flush();
    });
    await tester.pumpAndSettle();
    await tester.ensureVisible(search);
    await tester.runAsync(() async {
      await tester.tap(search);
      await Hive.box(NavPrefs.boxName).flush();
    });
    await tester.pumpAndSettle();
    expect(navPrefs.tabs, contains(DockTab.search));
    final start = find.byKey(const ValueKey('dock-start-search'));
    await tester.ensureVisible(start);
    await tester.runAsync(() async {
      await tester.tap(start);
      await Hive.box(NavPrefs.boxName).flush();
    });
    await tester.pumpAndSettle();
    expect(navPrefs.startTab, DockTab.search);
    final up = find.byKey(const ValueKey('dock-up-search'));
    await tester.ensureVisible(up);
    await tester.runAsync(() async {
      await tester.tap(up);
      await Hive.box(NavPrefs.boxName).flush();
    });
    await tester.pumpAndSettle();
    expect(navPrefs.tabs[1], DockTab.search);
    expect(find.byKey(const ValueKey('dock-remove-profile')), findsNothing);
    await tester.runAsync(() async {
      await Hive.box(NavPrefs.boxName).close();
      await NavPrefs.init();
    });
    expect(navPrefs.startTab, DockTab.search);
    expect(navPrefs.tabs[1], DockTab.search);
    final removeStart = find.byKey(const ValueKey('dock-remove-search'));
    await tester.ensureVisible(removeStart);
    await tester.runAsync(() async {
      await tester.tap(removeStart);
      await Hive.box(NavPrefs.boxName).flush();
    });
    await tester.pumpAndSettle();
    expect(navPrefs.startTab, navPrefs.tabs.first);
    expect(navPrefs.tabs.length, NavPrefs.minTabs);
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('dock-remove-home')))
          .onPressed,
      isNull,
    );
    final expanded = find.byKey(const ValueKey('keep-dock-expanded-switch'));
    await tester.ensureVisible(expanded);
    await tester.runAsync(() async {
      await tester.tap(expanded);
      await Hive.box(NavPrefs.boxName).flush();
    });
    await tester.pumpAndSettle();
    expect(navPrefs.keepDockExpanded, isTrue);
    await tester.runAsync(() async {
      await tester.tap(find.text('Reset'));
      // Reset deletes three keys in sequence. Flushing the first queued write
      // does not mean the async reset handler has finished all three deletes.
      final elapsed = Stopwatch()..start();
      while (!navPrefs.isDefault &&
          elapsed.elapsed < const Duration(seconds: 2)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await Hive.box(NavPrefs.boxName).flush();
    });
    await tester.pumpAndSettle();
    expect(navPrefs.isDefault, isTrue);
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('desktop dock controls fit narrow windows with enlarged text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(2)),
          child: DesktopSettingsScope(child: NavTabsScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final add = find.byKey(const ValueKey('dock-add-search'));
    await tester.ensureVisible(add);
    await tester.pumpAndSettle();
    expect(add.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  Finder notShownSearchRow() => find.byKey(const ValueKey('off_search'));
  Finder onBarSearchRow() => find.byKey(const ValueKey('on_search'));

  testWidgets('desktop dock reorders from keyboard traversal', (tester) async {
    await sl.unregister<NavPrefs>();
    navPrefs = NavPrefs();
    sl.registerSingleton<NavPrefs>(navPrefs);
    await tester.pumpWidget(
      const MaterialApp(home: DesktopSettingsScope(child: NavTabsScreen())),
    );
    await tester.pumpAndSettle();
    var reached = false;
    for (var i = 0; i < 20; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      final button = FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<IconButton>();
      if (button?.key == const ValueKey('dock-down-home')) {
        reached = true;
        break;
      }
    }
    expect(reached, isTrue);
    await tester.runAsync(() async {
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await Hive.box(NavPrefs.boxName).flush();
    });
    await tester.pumpAndSettle();
    expect(navPrefs.tabs[1], DockTab.home);
    expect(navPrefs.tabs.first, DockTab.myList);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Search remains an available hidden tab with Z Mode off', (
    tester,
  ) async {
    expect(ZModePrefs.enabled, isFalse);
    await tester.pumpWidget(const MaterialApp(home: NavTabsScreen()));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      notShownSearchRow(),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(notShownSearchRow(), findsOneWidget);
    expect(onBarSearchRow(), findsNothing);
  });

  testWidgets('Search remains an available hidden tab with Z Mode on', (
    tester,
  ) async {
    // See the module doc comment on watch_app's known Hive-in-testWidgets
    // hazard: a real write here needs a genuine event-loop turn, which the
    // pump-driven test binding never gives it on its own.
    await tester.runAsync(() => ZModePrefs.setEnabled(true));
    expect(ZModePrefs.enabled, isTrue);

    await tester.pumpWidget(const MaterialApp(home: NavTabsScreen()));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      notShownSearchRow(),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(notShownSearchRow(), findsOneWidget);
    expect(onBarSearchRow(), findsNothing);
  });

  testWidgets('Keep dock expanded is off by default and can be enabled', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: NavTabsScreen()));
    await tester.pumpAndSettle();

    final toggle = find.byKey(const ValueKey('keep-dock-expanded-switch'));
    expect(toggle, findsOneWidget);
    expect(tester.widget<Switch>(toggle).value, isFalse);

    await tester.tap(find.text('Keep dock expanded'));
    await tester.pump();

    expect(tester.widget<Switch>(toggle).value, isTrue);
  });
}
