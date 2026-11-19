// src-9 A: on Windows a Blocked (Cloudflare) row in 'Test sources' offers
// Verify, which runs the site verification and then re-tests that source.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/playback/search_source_prefs.dart';
import 'package:watch_app/core/playback/source_health_store.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/features/sources/source_health_screen.dart';

/// One Mihon source that is Blocked until it has been verified once.
class _Repository implements SourceRepository {
  bool verified = false;
  int searches = 0;

  @override
  List<({String id, String name})> get loadedSources => [
    (id: 'mihon:1', name: 'Guarded'),
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
    return (
      items: verified
          ? [
              const MediaItem(
                id: 'x',
                title: 'X',
                url: 'https://site.example/x',
                type: ProviderType.manga,
                sourceId: 'mihon:1',
              ),
            ]
          : const <MediaItem>[],
      outcome: verified ? SourceOutcome.ok : SourceOutcome.blocked,
    );
  }

  @override
  Future<String?> cfSolveTargetFor(String sourceId) async {
    // The test host has no native solver (it is skipped quietly), so
    // reaching this point stands in for a passed verification.
    verified = true;
    return 'https://site.example';
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
  late _Repository repository;

  setUp(() {
    repository = _Repository();
    sl.registerSingleton<SourceRepository>(repository);
    sl.registerSingleton<SourceHealthStore>(SourceHealthStore());
    sl.registerSingleton<SearchSourcePrefs>(_SearchPrefs());
    sl.registerSingleton<AppMode>(const AppMode(isTv: false));
  });

  tearDown(() => sl.reset());

  testWidgets('Blocked row offers Verify, then re-tests that source', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      // The Mihon solver channel answers at once (no native window here).
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('zangetsu/mihon'),
        (_) async => null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('zangetsu/mihon'),
          null,
        ),
      );
      await tester.pumpWidget(const MaterialApp(home: SourceHealthScreen()));
      await tester.pumpAndSettle();

      final verify = find.byKey(const ValueKey('health-verify-mihon:1'));
      expect(verify, findsOneWidget);
      final before = repository.searches;

      await tester.tap(verify);
      await tester.pumpAndSettle();

      // Re-tested in place: searched again, now passes, no Verify left.
      expect(repository.searches, greaterThan(before));
      expect(verify, findsNothing);
      expect(find.textContaining('Search OK'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('phone shows no Verify button', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SourceHealthScreen()));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('health-verify-mihon:1')), findsNothing);
  });
}
