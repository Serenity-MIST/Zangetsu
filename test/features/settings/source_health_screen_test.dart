import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/playback/search_source_prefs.dart';
import 'package:watch_app/core/playback/source_health_store.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/ui/desktop_settings_surface.dart';
import 'package:watch_app/features/sources/source_health_screen.dart';
import 'package:watch_app/l10n/app_localizations_en.dart';

/// No external provider calls: the real probe orchestration receives outcomes.
class _ProbeRepo implements SourceRepository {
  bool empty = false;
  int searches = 0, opens = 0;
  @override
  List<({String id, String name})> get loadedSources => empty
      ? []
      : const [
          (
            id: 'ok',
            name:
                'A long source name that should remain fully readable on a desktop',
          ),
          (id: 'empty', name: 'No matches'),
          (id: 'bad', name: 'Broken provider'),
          (id: 'cs:blocked', name: 'Blocked provider'),
          (id: 'cs:broken', name: 'Broken CloudStream'),
        ];
  @override
  Future<({List<MediaItem> items, SourceOutcome outcome})> searchStatus(
    String query, {
    String category = 'sub',
    String? sourceId,
    String? filtersJson,
    bool cache = false,
    int page = 1,
  }) async {
    searches++;
    if (sourceId == 'ok') {
      return (
        items: const [
          MediaItem(
            id: '1',
            title: 'Test',
            url: 'show',
            type: ProviderType.anime,
            sourceId: 'ok',
          ),
        ],
        outcome: SourceOutcome.ok,
      );
    }
    return (
      items: const <MediaItem>[],
      outcome: sourceId == 'empty'
          ? SourceOutcome.empty
          : sourceId == 'cs:blocked'
          ? SourceOutcome.blocked
          : SourceOutcome.error,
    );
  }

  @override
  Future<List<Episode>> episodes(
    String url, {
    String category = 'sub',
    String? sourceId,
  }) async {
    opens++;
    return const [Episode(id: 'e', title: 'Episode', url: 'episode')];
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Capture the existing health writes without real Hive timers in widget tests.
class _Health extends SourceHealthStore {
  final Map<String, SourceOutcome> records = {};
  @override
  Future<void> record(
    String id,
    SourceOutcome outcome, {
    int? responseMs,
  }) async {
    records[id] = outcome;
  }
}

/// Search inclusion fixture owns no installed-source or library data.
class _SearchPrefs extends SearchSourcePrefs {
  final Set<String> excludedIds = {};
  @override
  bool isIncluded(String id) => !excludedIds.contains(id);
  @override
  Future<void> setIncluded(String id, bool included) async {
    if (included) {
      excludedIds.remove(id);
    } else {
      excludedIds.add(id);
    }
  }
}

void main() {
  late _ProbeRepo repo;
  late _Health health;
  late _SearchPrefs search;
  final l10n = AppLocalizationsEn();
  setUp(() {
    repo = _ProbeRepo();
    health = _Health();
    search = _SearchPrefs();
    sl.registerSingleton<SourceRepository>(repo);
    sl.registerSingleton<SourceHealthStore>(health);
    sl.registerSingleton<SearchSourcePrefs>(search);
  });
  tearDown(sl.reset);

  testWidgets(
    'desktop diagnostic outcomes stay distinct and deep test opens a title',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: DesktopSettingsScope(child: SourceHealthScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(health.records['ok'], SourceOutcome.ok);
      expect(health.records['cs:blocked'], SourceOutcome.blocked);
      expect(find.textContaining(l10n.searchOk), findsOneWidget);
      expect(repo.opens, 0);
      final deep = find.byKey(const ValueKey('health-deep-test'));
      await tester.ensureVisible(deep);
      await tester.tap(deep);
      await tester.pumpAndSettle();
      expect(repo.opens, 1);
      expect(find.textContaining('1 to play'), findsOneWidget);
      expect(find.byType(RefreshIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'dead source removal updates search inclusion without uninstalling',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: DesktopSettingsScope(child: SourceHealthScreen()),
        ),
      );
      await tester.pumpAndSettle();
      final row = find.byKey(const ValueKey('health-row-bad'));
      await tester.scrollUntilVisible(
        row,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      final remove = find.descendant(
        of: row,
        matching: find.text('Remove from search'),
      );
      await tester.ensureVisible(remove);
      await tester.pumpAndSettle();
      await tester.tap(remove);
      await tester.pumpAndSettle();
      expect(search.isIncluded('bad'), isFalse);
      expect(repo.loadedSources.length, 5);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('desktop diagnostics wrap at narrow enlarged text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(2)),
          child: DesktopSettingsScope(child: SourceHealthScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('health-row-ok'));
    await tester.scrollUntilVisible(
      row,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty pool has a usable explicit desktop empty state', (
    tester,
  ) async {
    repo.empty = true;
    await tester.pumpWidget(
      const MaterialApp(
        home: DesktopSettingsScope(child: SourceHealthScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(l10n.noEnabledSourcesToTest), findsOneWidget);
    expect(repo.searches, 0);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('health-quick-test')))
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });
}
