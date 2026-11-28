import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/ui/desktop_settings_surface.dart';
import 'package:watch_app/features/player/player_controls_config.dart';
import 'package:watch_app/features/settings/player_controls_screen.dart';

/// In-memory UI owner separates animation tests from real disk persistence.
class _ControlsPrefs extends PlaybackPrefs {
  List<String>? top, left, right;
  int writes = 0;
  @override
  List<String>? get playerBarTop => top;
  @override
  List<String>? get playerBarLeft => left;
  @override
  List<String>? get playerBarRight => right;
  @override
  Future<void> setPlayerBar(
    List<String> t,
    List<String> l,
    List<String> r,
  ) async {
    top = List.of(t);
    left = List.of(l);
    right = List.of(r);
    writes++;
  }

  @override
  Future<void> resetPlayerBar() async {
    top = null;
    left = null;
    right = null;
  }
}

void main() {
  late _ControlsPrefs prefs;
  setUp(() {
    prefs = _ControlsPrefs();
    sl.registerSingleton<PlaybackPrefs>(prefs);
  });
  tearDown(sl.reset);

  testWidgets(
    'desktop ordering, slot movement and reset preserve configuration',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: DesktopSettingsScope(child: PlayerControlsScreen()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('player-down-speed')),
      );
      await tester.tap(find.byKey(const ValueKey('player-down-speed')));
      await tester.pumpAndSettle();
      expect(prefs.left!.first, 'tracks');
      expect(prefs.left![1], 'speed');
      final speed = find.byKey(const ValueKey('player-slot-speed'));
      await tester.ensureVisible(speed);
      await tester.tap(speed);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hidden').last);
      await tester.pumpAndSettle();
      expect(prefs.left, isNot(contains('speed')));
      expect(prefs.writes, 2);
      await tester.tap(find.text('Reset'));
      await tester.pumpAndSettle();
      expect(prefs.left, isNull);
      expect(find.byKey(const ValueKey('left_speed')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('desktop selectors retain pinned More and full top limit', (
    tester,
  ) async {
    prefs.top = ['cast', 'info', 'speed', 'tracks', 'quality'];
    prefs.left = ['sources', 'more'];
    prefs.right = ['episodes', 'rotate', 'fit'];
    await tester.pumpWidget(
      const MaterialApp(
        home: DesktopSettingsScope(child: PlayerControlsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    final more = tester.widget<DropdownButtonFormField<ControlSlot>>(
      find.byKey(const ValueKey('player-slot-more')),
    );
    // The real DropdownButton carries the generated menu items.
    final dropdown = tester.widget<DropdownButton<ControlSlot>>(
      find.descendant(
        of: find.byKey(const ValueKey('player-slot-more')),
        matching: find.byType(DropdownButton<ControlSlot>),
      ),
    );
    expect(
      dropdown.items!
          .singleWhere((item) => item.value == ControlSlot.hidden)
          .enabled,
      isFalse,
    );
    expect(
      dropdown.items!
          .singleWhere((item) => item.value == ControlSlot.top)
          .enabled,
      isFalse,
    );
    expect(more, isNotNull);
  });

  testWidgets('desktop controls remain reachable with narrow enlarged text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(2)),
          child: DesktopSettingsScope(child: PlayerControlsScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('player-slot-more')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop controls reorder through keyboard traversal', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: DesktopSettingsScope(child: PlayerControlsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    var reached = false;
    for (var i = 0; i < 24; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      final button = FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<IconButton>();
      if (button?.key == const ValueKey('player-down-cast')) {
        reached = true;
        break;
      }
    }
    expect(reached, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(prefs.top, ['info', 'cast']);
    expect(prefs.writes, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unscoped phone presentation retains move menus', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: PlayerControlsScreen()));
    await tester.pumpAndSettle();
    expect(find.byType(PopupMenuButton<ControlSlot>), findsWidgets);
    expect(find.byType(DropdownButtonFormField<ControlSlot>), findsNothing);
  });

  test(
    'real player layout persists after reopening and reset clears all lists',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'player_controls_',
      );
      Hive.init(directory.path);
      await Hive.openBox(PlaybackPrefs.boxName);
      try {
        final real = PlaybackPrefs();
        await real.setPlayerBar(['info'], ['tracks', 'more'], ['fit']);
        await Hive.box(PlaybackPrefs.boxName).close();
        await Hive.openBox(PlaybackPrefs.boxName);
        expect(real.playerBarTop, ['info']);
        expect(real.playerBarLeft, ['tracks', 'more']);
        expect(real.playerBarRight, ['fit']);
        await real.resetPlayerBar();
        expect(real.playerBarTop, isNull);
        expect(real.playerBarLeft, isNull);
        expect(real.playerBarRight, isNull);
      } finally {
        await Hive.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
