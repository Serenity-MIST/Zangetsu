import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/playback/source_health_store.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/ui/desktop_settings_surface.dart';
import 'package:watch_app/core/zmode/source_order_prefs.dart';
import 'package:watch_app/core/zmode/source_score_store.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/features/settings/source_priority_screen.dart';

/// Offline installed-pool fixture; the real screen still calls sweepCandidates.
class _Sources implements SourceRepository {
  @override
  List<({String id, String name})> get loadedSources => const [
    (id: 'first', name: 'Alpha'),
    (id: 'second', name: 'Beta'),
    (id: 'third', name: 'Gamma'),
    (id: 'fourth', name: 'Delta'),
    (id: 'mihon:reader', name: 'Reader source'),
  ];
  @override
  List<({String id, String name})> get pickableSources => loadedSources;
  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory directory;
  late SourceOrderPrefs prefs;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('desktop_priority_');
    Hive.init(directory.path);
    prefs = await SourceOrderPrefs.open();
    sl.registerSingleton<SourceOrderPrefs>(prefs);
    sl.registerSingleton<SourceRepository>(_Sources());
    sl.registerSingleton<SourceScoreStore>(await SourceScoreStore.open());
    sl.registerSingleton<SourceHealthStore>(SourceHealthStore());
  });
  tearDown(() async {
    await sl.reset();
    await Hive.close();
    await directory.delete(recursive: true);
  });

  testWidgets(
    'desktop priority page wraps its media controls and cap boundary',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(
        () => prefs.setCap(ZKind.anime, SourceOrderPrefs.minCap),
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(2)),
            child: DesktopSettingsScope(child: SourcePriorityScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final boundary = find.text(
        'Auto Resolve stops here. Move a source above this line to include it.',
      );
      await tester.scrollUntilVisible(
        boundary,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(boundary, findsOneWidget);
      expect(tester.takeException(), isNull);
      final move = find.byTooltip('Move Beta up');
      await tester.scrollUntilVisible(
        move,
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(move.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'desktop move saves real pins and Unpin all restores automatic order',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: DesktopSettingsScope(child: SourcePriorityScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('1. Alpha'), findsOneWidget);
      expect(find.text('2. Beta'), findsOneWidget);
      // Run real disk work on the event loop, not Flutter's fake animation clock.
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('Move Beta up'));
        await Hive.box<List>(SourceOrderPrefs.boxName).flush();
      });
      await tester.pumpAndSettle();
      expect(find.text('1. Beta'), findsOneWidget);
      expect(prefs.get(ZKind.anime), ['second', 'first']);
      await tester.ensureVisible(find.text('Unpin all'));
      await tester.runAsync(() async {
        await tester.tap(find.text('Unpin all'));
        await Hive.box<List>(SourceOrderPrefs.boxName).flush();
      });
      await tester.pumpAndSettle();
      expect(prefs.get(ZKind.anime), isEmpty);
      expect(find.text('1. Alpha'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Manga'),
        -250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Manga'));
      await tester.pumpAndSettle();
      expect(find.text('1. Reader source'), findsOneWidget);
      expect(find.text('1. Alpha'), findsNothing);
      expect(prefs.get(ZKind.manga), isEmpty);
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
