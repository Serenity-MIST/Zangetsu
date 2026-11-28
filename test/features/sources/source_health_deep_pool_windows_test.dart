// src-1: on Windows, with JS providers off the UI isolate, the Source health
// deep check runs the full pool, but LNReader plugins (still on the UI
// isolate) stay capped at two deep checks in flight. Phone keeps the cap of
// two for everything.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/playback/search_source_prefs.dart';
import 'package:watch_app/core/playback/source_health_store.dart';
import 'package:watch_app/core/provider/js_engine.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/features/sources/source_health_screen.dart';

/// Eight LNReader plugins and eight other sources. Every search finds one
/// title; opening it takes 100 ms, and the fake counts how many are open.
class _Repository implements SourceRepository {
  int inFlight = 0;
  int maxInFlight = 0;
  int lnrInFlight = 0;
  int maxLnrInFlight = 0;

  @override
  List<({String id, String name})> get loadedSources => [
    for (var i = 0; i < 8; i++) (id: 'lnr:p$i', name: 'Novel $i'),
    for (var i = 0; i < 8; i++) (id: 'src-$i', name: 'Source $i'),
  ];

  @override
  Future<({List<MediaItem> items, SourceOutcome outcome})> searchStatus(
    String query, {
    String category = 'sub',
    String? sourceId,
    String? filtersJson,
    bool cache = false,
    int page = 1,
  }) async => (
    items: [
      MediaItem(
        id: '$sourceId-1',
        title: 'Title',
        url: 'https://example.invalid/$sourceId',
        type: ProviderType.anime,
        sourceId: sourceId ?? '',
      ),
    ],
    outcome: SourceOutcome.ok,
  );

  @override
  Future<List<Episode>> episodes(
    String url, {
    String category = 'sub',
    String? sourceId,
  }) async {
    final lnr = sourceId?.startsWith('lnr:') ?? false;
    inFlight++;
    if (lnr) lnrInFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    if (lnrInFlight > maxLnrInFlight) maxLnrInFlight = lnrInFlight;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    inFlight--;
    if (lnr) lnrInFlight--;
    return [Episode(id: '$url-1', title: 'One', url: '$url/1')];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SearchPrefs implements SearchSourcePrefs {
  @override
  bool isIncluded(String id) => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Repository repo;

  setUp(() {
    repo = _Repository();
    sl.registerSingleton<SourceRepository>(repo);
    sl.registerSingleton<SourceHealthStore>(SourceHealthStore());
    sl.registerSingleton<SearchSourcePrefs>(_SearchPrefs());
    sl.registerSingleton<AppMode>(const AppMode(isTv: false));
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    JsEngine.debugRunsOffUiIsolateOverride = null;
    sl.reset();
  });

  /// Opens the screen, waits out the quick test, then runs a deep test.
  Future<void> runDeep(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: SourceHealthScreen()));
    await tester.pumpAndSettle();
    final deep = find.byKey(const ValueKey('health-deep-test'));
    final button = deep.evaluate().isNotEmpty
        ? deep
        : find.byTooltip('Deep test (opens a title from each source)');
    await tester.tap(button);
    // Enough fake time for every deep check to finish.
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
  }

  testWidgets('Windows: bigger deep pool, LNReader still capped at two', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    JsEngine.debugRunsOffUiIsolateOverride = true;
    // The platform override must be cleared inside the test body.
    try {
      await runDeep(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
    expect(repo.maxInFlight, greaterThan(2));
    expect(repo.maxLnrInFlight, lessThanOrEqualTo(2));
    expect(repo.inFlight, 0);
  });

  testWidgets('phone keeps the deep cap of two', (tester) async {
    JsEngine.debugRunsOffUiIsolateOverride = true;
    await runDeep(tester);
    expect(repo.maxInFlight, lessThanOrEqualTo(2));
    expect(repo.inFlight, 0);
  });
}
