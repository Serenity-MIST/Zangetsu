// The Windows Source Priority page: Pinned badges, Unpin all confirmation
// with Undo, Alt+Up/Down on the focused row, the "Use in Auto Resolve"
// switch, the searchable try-first preferred source and the Manual matches
// row (items ar-3, ar-9, ar-10, ar-11, ar-7).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/playback/source_health_store.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/ui/desktop_settings_surface.dart';
import 'package:watch_app/core/zmode/source_order_prefs.dart';
import 'package:watch_app/core/zmode/source_score_store.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/core/zmode/zmode_source_prefs.dart';
import 'package:watch_app/features/settings/source_priority_screen.dart';

/// Offline installed pool; the real screen still calls priorityCandidates.
class _Sources implements SourceRepository {
  @override
  List<({String id, String name})> get loadedSources => const [
    (id: 'first', name: 'Alpha'),
    (id: 'second', name: 'Bravo'),
    (id: 'third', name: 'Gamma'),
    (id: 'fourth', name: 'Delta'),
  ];
  @override
  List<({String id, String name})> get pickableSources => loadedSources;
  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _windows = TargetPlatformVariant.only(TargetPlatform.windows);

void main() {
  late Directory directory;
  late SourceOrderPrefs prefs;
  late ZSourcePrefs picks;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('win_priority_');
    Hive.init(directory.path);
    // In-memory boxes (opened first, so the stores' own open() reuses them):
    // writes then finish inside the fake clock and pumpAndSettle sees them,
    // with no real disk IO racing the widget test.
    await Hive.openBox<List>(SourceOrderPrefs.boxName, bytes: Uint8List(0));
    await Hive.openBox<String>(ZSourcePrefs.boxName, bytes: Uint8List(0));
    await Hive.openBox<int>(SourceScoreStore.boxName, bytes: Uint8List(0));
    prefs = await SourceOrderPrefs.open();
    picks = await ZSourcePrefs.open();
    sl.registerSingleton<SourceOrderPrefs>(prefs);
    sl.registerSingleton<ZSourcePrefs>(picks);
    sl.registerSingleton<SourceRepository>(_Sources());
    sl.registerSingleton<SourceScoreStore>(await SourceScoreStore.open());
    sl.registerSingleton<SourceHealthStore>(SourceHealthStore());
  });
  tearDown(() async {
    await sl.reset();
    await Hive.close();
    await directory.delete(recursive: true);
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(
        home: DesktopSettingsScope(child: SourcePriorityScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Lets a chain of screen awaits (in-memory Hive writes, then setState)
  /// finish.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      await tester.pumpAndSettle();
    }
  }

  /// Taps [finder] and waits for the Hive writes it starts.
  Future<void> tapAndFlush(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await tester.pumpAndSettle();
    await settle(tester);
  }

  Finder inDialog(String text) =>
      find.descendant(of: find.byType(Dialog), matching: find.text(text));

  testWidgets(
    'moves pin with a badge; Unpin all confirms and can be undone',
    (tester) async {
      await pumpPage(tester);
      expect(find.text('Pinned'), findsNothing);
      await tapAndFlush(tester, find.byTooltip('Move Bravo up'));
      expect(prefs.get(ZKind.anime), ['second', 'first']);
      expect(find.text('Pinned'), findsNWidgets(2));

      // Cancel keeps the pins.
      await tester.tap(find.widgetWithText(TextButton, 'Unpin all'));
      await tester.pumpAndSettle();
      expect(find.text('Unpin all sources?'), findsOneWidget);
      await tester.tap(inDialog('Cancel'));
      await tester.pumpAndSettle();
      expect(prefs.get(ZKind.anime), ['second', 'first']);

      // Confirm clears them, Undo restores the exact list.
      await tester.tap(find.widgetWithText(TextButton, 'Unpin all'));
      await tester.pumpAndSettle();
      await tapAndFlush(tester, inDialog('Unpin all'));
      expect(prefs.get(ZKind.anime), isEmpty);
      expect(find.text('Pinned'), findsNothing);
      await tapAndFlush(tester, find.text('Undo'));
      expect(prefs.get(ZKind.anime), ['second', 'first']);
      expect(find.text('1. Bravo'), findsOneWidget);
      // Let the toast's own timer run out.
      await tester.pump(const Duration(seconds: 8));
    },
    variant: _windows,
  );

  testWidgets(
    'per-row Unpin keeps the other pins',
    (tester) async {
      await prefs.set(ZKind.anime, ['second', 'first', 'third']);
      await pumpPage(tester);
      expect(find.text('Pinned'), findsNWidgets(3));
      await tapAndFlush(tester, find.byTooltip('Unpin Alpha'));
      expect(prefs.get(ZKind.anime), ['second', 'third']);
    },
    variant: _windows,
  );

  testWidgets(
    'Alt+Down moves the focused row',
    (tester) async {
      await pumpPage(tester);
      await tester.tap(find.text('1. Alpha'));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await settle(tester);
      expect(find.text('2. Alpha'), findsOneWidget);
      expect(find.text('1. Bravo'), findsOneWidget);
      expect(prefs.get(ZKind.anime), ['second', 'first']);

      // The moved row keeps focus, so a second Alt+Down moves it again.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await settle(tester);
      expect(find.text('3. Alpha'), findsOneWidget);
    },
    variant: _windows,
  );

  testWidgets(
    'Use in Auto Resolve switch skips the source in its own list only',
    (tester) async {
      await pumpPage(tester);
      expect(find.text('Use in Auto Resolve'), findsNWidgets(4));
      await tapAndFlush(tester, find.byType(Switch).first);
      expect(prefs.excluded(ZKind.anime), {'first'});
      expect(prefs.excluded(ZKind.movie), isEmpty);
      expect(find.text('Skipped by Auto Resolve'), findsOneWidget);
      // Switching it back on removes it again.
      await tapAndFlush(tester, find.byType(Switch).first);
      expect(prefs.excluded(ZKind.anime), isEmpty);
    },
    variant: _windows,
  );

  testWidgets(
    'preferred source is picked from a searchable list; Manual matches row',
    (tester) async {
      await pumpPage(tester);
      expect(find.text('Manual matches'), findsOneWidget);
      expect(find.byType(DropdownButton<String>), findsNothing);
      await tester.tap(find.text('Preferred source for anime'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.byType(TextField),
        ),
        'Gam',
      );
      await tester.pumpAndSettle();
      expect(inDialog('Alpha'), findsNothing);
      await tapAndFlush(tester, inDialog('Gamma'));
      expect(picks.get(ZKind.anime), 'third');
      expect(
        find.text('Gamma'),
        findsWidgets,
        reason: 'the row names the chosen source',
      );
    },
    variant: _windows,
  );
}
