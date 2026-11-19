// src-11: on Windows a search that timed out says "Source timed out" with an
// hourglass icon and keeps Retry; other failures and the phone keep the
// generic "Something went wrong" text.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/desktop/desktop_shortcut_catalog.dart';
import 'package:watch_app/core/desktop/desktop_shortcuts.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/playback/source_health_store.dart';
import 'package:watch_app/core/provider/base_provider.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/repository/catalogue_repository.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/features/search/browse_source_screen.dart';

/// A source whose search throws [searchError].
class _Repo implements SourceRepository, CatalogueRepository {
  Object searchError = TimeoutException('slow');

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  bool hasSource(String id) => true;

  @override
  Future<bool> ensureSourceLoaded(String sourceId) async => true;

  @override
  Future<List<HomeSection>> home({
    String category = 'sub',
    String? sourceId,
  }) async => [
    HomeSection(
      title: 'Popular',
      items: [
        MediaItem(
          id: 'home',
          title: 'home',
          url: 'https://x.test/home',
          type: ProviderType.anime,
          sourceId: 'cs:Src',
        ),
      ],
    ),
  ];

  @override
  Future<List<MediaItem>> search(
    String query, {
    String category = 'sub',
    String? sourceId,
  }) async => throw searchError;

  @override
  Future<({List<MediaItem> items, SourceOutcome outcome})> searchStatus(
    String query, {
    String category = 'sub',
    String? sourceId,
    String? filtersJson,
    bool cache = false,
    int page = 1,
  }) async => throw searchError;

  @override
  String baseUrlFor(String sourceId) => '';

  @override
  Future<String?> cfSolveTargetFor(String sourceId) async => null;

  @override
  String displayName(String sourceId) => sourceId;

  @override
  String? languageFor(String sourceId) => null;
}

/// Enough of the CloudStream manager for the screen to build.
class _FakeCloudStreamManager extends ChangeNotifier
    implements CloudStreamManager {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  BaseProvider? get(String sourceId) => null;
  @override
  BaseProvider? resolveCompatible(String sourceId) => get(sourceId);
  @override
  String? repoNameForSourceId(String sourceId) => null;
}

void main() {
  late _Repo repo;

  setUp(() {
    cloudStreamHostOverride = (method, args) async => false;
    repo = _Repo();
    DesktopShortcuts.debugReset();
    registerDefaultDesktopShortcuts();
    sl.registerSingleton<ActiveSourceCubit>(
      ActiveSourceCubit(fallback: 'cs:1'),
    );
    sl.registerSingleton<CloudStreamManager>(_FakeCloudStreamManager());
    sl.registerSingleton<SourceRepository>(repo);
    sl.registerSingleton<AppMode>(const AppMode(isTv: false));
  });

  tearDown(() async {
    cloudStreamHostOverride = null;
    debugDefaultTargetPlatformOverride = null;
    await sl<ActiveSourceCubit>().close();
    await sl.reset();
  });

  // Opens the source page and runs a search that fails.
  Future<void> failSearch(WidgetTester t) async {
    await t.pumpWidget(
      const MaterialApp(
        home: BrowseSourceScreen(sourceId: 'cs:Src', title: 'Src'),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.byIcon(Icons.search));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'naruto');
    await t.testTextInput.receiveAction(TextInputAction.search);
    await t.pumpAndSettle();
  }

  testWidgets('Windows: a timed-out search says so and keeps Retry', (
    t,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await failSearch(t);
    final panel = find.byKey(const ValueKey('browse-source-failed'));
    expect(panel, findsOneWidget);
    expect(
      find.descendant(of: panel, matching: find.textContaining('Source timed out')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.hourglass_disabled_rounded), findsOneWidget);
    expect(find.descendant(of: panel, matching: find.text('Retry')), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Windows: other failures keep the generic message', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    repo.searchError = StateError('offline');
    await failSearch(t);
    expect(find.byKey(const ValueKey('browse-source-failed')), findsOneWidget);
    expect(find.textContaining('Source timed out'), findsNothing);
    expect(find.byIcon(Icons.hourglass_disabled_rounded), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });
}
