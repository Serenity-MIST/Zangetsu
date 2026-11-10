import 'dart:io';
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/ui/desktop_settings_surface.dart';
import 'package:watch_app/core/provider/provider_downloader.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/provider/provider_repo_registry.dart';
import 'package:watch_app/core/tv/tv_focusable.dart';
import 'package:watch_app/features/sources/zangetsu_sources_screen.dart';

// ── Fakes (mirrors test/provider/provider_registry_test.dart) ────────────────

/// No-op runtime loader — this screen never installs anything in these tests.
class _FakeManager implements ProviderRuntimeLoader {
  final List<String> removed = [];
  @override
  JsProvider? get(String id) => null;

  @override
  Future<void> load({
    required String sourceId,
    required String jsSource,
    String originRepoUrl = '',
    String displayName = '',
  }) async {}

  @override
  void setSettings(String sourceId, Map<String, dynamic> s) {}

  @override
  void remove(String id) {
    removed.add(id);
  }
}

/// Stub fetcher — repo providers aren't exercised in these tests.
class _FakeFetcher implements ProviderJsFetcher {
  @override
  Future<CachedProvider> fetch({
    required String name,
    required String url,
    bool force = false,
  }) async => CachedProvider(
    name: name,
    jsCode: '// $name',
    url: url,
    fetchedAt: DateTime.now(),
  );

  @override
  Future<void> remove(String name) async {}
}

/// Immediate widget snapshots isolate dispatch from Hive's real file IO.
/// Persistence and runtime removal are verified outside the widget fake clock.
class _InstalledFixtureRegistry implements ProviderRegistry {
  _InstalledFixtureRegistry(this.entry);
  ProviderRegistryEntry entry;
  int toggles = 0;
  final changes = StreamController<BoxEvent>.broadcast();
  @override
  List<ProviderRegistryEntry> getAll() => [entry];
  @override
  Stream<BoxEvent> watch() => changes.stream;
  @override
  Future<void> setEnabled(String key, bool enabled) async {
    toggles++;
    entry = entry.copyWith(enabled: enabled);
    changes.add(BoxEvent(key, entry.toJson(), false));
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Deterministic manifest fixture: refresh dispatch is observable without HTTP.
class _RepositoryFixture implements ProviderReposRegistry {
  int refreshes = 0, removals = 0;
  final repo = ProviderRepo(
    url: 'https://example.invalid/index.json',
    name: 'Desktop repository',
    description: 'Fixture',
    lastSyncedAt: DateTime(2026),
    sources: [
      RepoSource(
        id: 'fixture',
        name:
            'A long repository source title that must wrap without losing its language or version',
        version: '1.0.0',
        type: 'anime',
        lang: 'en',
        file: 'fixture.js',
      ),
    ],
  );
  @override
  List<ProviderRepo> getAll() => [repo];
  @override
  Stream<BoxEvent> watch() => const Stream.empty();
  @override
  Future<ProviderRepo> fetchAndCache(String url, {String? customName}) async {
    refreshes++;
    return repo;
  }

  @override
  Future<void> remove(String url) async {
    removals++;
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory tempDir;

  setUp(() async {
    // Real Hive (temp dir) + real registries — SourcesBloc subscribes to
    // both boxes' `.watch()` in its constructor, so a plain mock can't
    // stand in without reimplementing that surface.
    tempDir = await Directory.systemTemp.createTemp('zangetsu_sources_test');
    Hive.init(tempDir.path);
    await ProviderRegistry.init();
    await ProviderReposRegistry.init();

    final sl = GetIt.instance;
    sl.registerSingleton<AppMode>(const AppMode(isTv: true));
    sl.registerSingleton<ProviderRegistry>(
      ProviderRegistry(downloader: _FakeFetcher(), manager: _FakeManager()),
    );
    sl.registerSingleton<ProviderReposRegistry>(
      ProviderReposRegistry(dio: Dio()),
    );
  });

  tearDown(() async {
    await GetIt.instance.reset();
    await Hive.deleteFromDisk();
    await tempDir.delete(recursive: true);
  });

  testWidgets(
    'ZangetsuSourcesScreen (TV) exposes semantics labels for its tab chips, '
    'Back button and Add-repo action — with no duplicate-text nodes',
    (tester) async {
      final handle = tester.ensureSemantics();

      await tester.pumpWidget(const MaterialApp(home: ZangetsuSourcesScreen()));
      await tester.pumpAndSettle();

      // Installed tab chip: autofocused, so this is where the D-pad lands.
      expect(
        tester.getSemantics(find.bySemanticsLabel('Installed')),
        matchesSemantics(
          label: 'Installed',
          isButton: true,
          isFocusable: true,
          isFocused: true,
          hasTapAction: true,
          // Framework-supplied for anything focusable; matchesSemantics fails
          // on any action it wasn't told to expect.
          hasFocusAction: true,
        ),
      );
      // Each of these is a single announced node — no leftover sibling
      // Text nodes duplicating the same label.
      for (final label in ['Repositories', 'Back']) {
        expect(find.bySemanticsLabel(label), findsOneWidget);
      }

      // Switch to Repositories: with no repos added, the "Add repo" row
      // becomes reachable and announces its own label once. TvFocusable has
      // no gesture recognizer (D-pad OK / TalkBack double-tap are its only
      // real inputs), so invoke its onTap directly rather than tester.tap.
      final repositoriesChip = tester
          .widgetList<TvFocusable>(find.byType(TvFocusable))
          .firstWhere((f) => f.semanticLabel == 'Repositories');
      repositoriesChip.onTap();
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Add repo'), findsOneWidget);

      handle.dispose();
    },
  );
  testWidgets(
    'desktop source toolbar replaces FAB and preserves Add validation',
    (tester) async {
      await GetIt.instance.unregister<AppMode>();
      GetIt.instance.registerSingleton<AppMode>(const AppMode(isTv: false));
      await tester.pumpWidget(
        const MaterialApp(
          home: DesktopSettingsScope(child: ZangetsuSourcesScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(FloatingActionButton), findsNothing);
      // The toolbar starts with the search-field gutter rather than centering
      // its intrinsic width within the settings content pane.
      expect(tester.getTopLeft(find.byType(TabBar)).dx, closeTo(22, 1));
      expect(
        find.byKey(const ValueKey('desktop-add-zangetsu-repo')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('desktop-add-zangetsu-repo')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        DesktopSettingsScope.contains(tester.element(find.byType(AlertDialog))),
        isTrue,
      );
      expect(
        tester
            .widget<AlertDialog>(find.byType(AlertDialog))
            .constraints!
            .maxWidth,
        560,
      );
      expect(
        (tester.widget<AlertDialog>(find.byType(AlertDialog)).shape
                as RoundedRectangleBorder)
            .borderRadius,
        BorderRadius.circular(20),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a manifest URL.'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(GetIt.instance<ProviderReposRegistry>().getAll(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'desktop source toolbar fits narrow enlarged text and repository entry',
    (tester) async {
      await GetIt.instance.unregister<AppMode>();
      GetIt.instance.registerSingleton<AppMode>(const AppMode(isTv: false));
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: const DesktopSettingsScope(
            child: ZangetsuSourcesScreen(openToRepos: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        DefaultTabController.of(tester.element(find.byType(TabBar))).index,
        1,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'desktop installed group supports real enable writes and search expansion',
    (tester) async {
      await GetIt.instance.unregister<AppMode>();
      GetIt.instance.registerSingleton<AppMode>(const AppMode(isTv: false));
      final registry = _InstalledFixtureRegistry(
        ProviderRegistryEntry(
          name: 'desktop_fixture',
          url: 'bundled://desktop_fixture',
          originRepoUrl: kBundledRepoUrl,
          displayName: 'Desktop fixture source',
        ),
      );
      await GetIt.instance.unregister<ProviderRegistry>();
      GetIt.instance.registerSingleton<ProviderRegistry>(registry);
      await tester.pumpWidget(
        const MaterialApp(
          home: DesktopSettingsScope(child: ZangetsuSourcesScreen()),
        ),
      );
      await tester.pumpAndSettle();
      final toggle = find.byKey(
        ValueKey(
          'desktop-source-enabled-${ProviderRegistry.providerKey(kBundledRepoUrl, 'desktop_fixture')}',
        ),
      );
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(registry.getAll().single.enabled, isFalse);
      expect(registry.toggles, 1);
      expect(find.text('Disabled'), findsOneWidget);
      final group = find.byKey(
        const ValueKey('desktop-source-group-bundled://'),
      );
      await tester.ensureVisible(group);
      await tester.pumpAndSettle();
      await tester.tap(group);
      await tester.pumpAndSettle();
      expect(toggle, findsNothing);
      await tester.enterText(find.byType(TextField).first, 'Desktop fixture');
      await tester.pumpAndSettle();
      expect(toggle, findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await registry.changes.close();
    },
  );

  testWidgets('desktop installed source names and actions wrap at text2', (
    tester,
  ) async {
    await GetIt.instance.unregister<AppMode>();
    GetIt.instance.registerSingleton<AppMode>(const AppMode(isTv: false));
    const title =
        'A long source name with a language and repository suffix that must remain readable';
    await tester.runAsync(
      () => GetIt.instance<ProviderRegistry>().installFromBundled(
        name: 'desktop_long_fixture',
        jsSource: '// fixture',
        displayName: title,
      ),
    );
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: const DesktopSettingsScope(child: ZangetsuSourcesScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.text(title)).maxLines, isNull);
    await tester.drag(find.byType(ListView).first, const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  test(
    'provider enable persists across box reopen and removes runtime source',
    () async {
      final manager = _FakeManager();
      final registry = ProviderRegistry(
        downloader: _FakeFetcher(),
        manager: manager,
      );
      await registry.installFromBundled(
        name: 'persist_fixture',
        jsSource: '// fixture',
      );
      final key = ProviderRegistry.providerKey(
        kBundledRepoUrl,
        'persist_fixture',
      );
      await registry.setEnabled(key, false);
      await Hive.box<Map>(ProviderRegistry.boxName).flush();
      expect(manager.removed, ['persist_fixture']);
      await Hive.box<Map>(ProviderRegistry.boxName).close();
      await ProviderRegistry.init();
      expect(registry.getAll().single.enabled, isFalse);
    },
  );
  testWidgets(
    'desktop repositories expose refresh and cancellable removal directly',
    (tester) async {
      await GetIt.instance.unregister<AppMode>();
      GetIt.instance.registerSingleton<AppMode>(const AppMode(isTv: false));
      final repos = _RepositoryFixture();
      await GetIt.instance.unregister<ProviderReposRegistry>();
      GetIt.instance.registerSingleton<ProviderReposRegistry>(repos);
      await tester.pumpWidget(
        const MaterialApp(
          home: DesktopSettingsScope(
            child: ZangetsuSourcesScreen(openToRepos: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(PopupMenuButton<String>), findsNothing);
      final refresh = find.byKey(
        ValueKey('desktop-repository-refresh-${repos.repo.url}'),
      );
      await tester.ensureVisible(refresh);
      await tester.pumpAndSettle();
      await tester.tap(refresh);
      await tester.pumpAndSettle();
      expect(repos.refreshes, 1);
      final remove = find.widgetWithText(TextButton, 'Remove repo');
      await tester.ensureVisible(remove);
      await tester.pumpAndSettle();
      await tester.tap(remove);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(repos.removals, 0);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('desktop repository source metadata fits narrow text2', (
    tester,
  ) async {
    await GetIt.instance.unregister<AppMode>();
    GetIt.instance.registerSingleton<AppMode>(const AppMode(isTv: false));
    final repos = _RepositoryFixture();
    await GetIt.instance.unregister<ProviderReposRegistry>();
    GetIt.instance.registerSingleton<ProviderReposRegistry>(repos);
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: const DesktopSettingsScope(
          child: ZangetsuSourcesScreen(openToRepos: true),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.text(repos.repo.sources.single.name)).maxLines,
      isNull,
    );
    await tester.drag(find.byType(ListView).last, const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('wide desktop repository actions share the metadata row', (
    tester,
  ) async {
    await GetIt.instance.unregister<AppMode>();
    GetIt.instance.registerSingleton<AppMode>(const AppMode(isTv: false));
    final repos = _RepositoryFixture();
    await GetIt.instance.unregister<ProviderReposRegistry>();
    GetIt.instance.registerSingleton<ProviderReposRegistry>(repos);
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(
        home: DesktopSettingsScope(
          child: ZangetsuSourcesScreen(openToRepos: true),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final name = find.text(repos.repo.sources.single.name);
    final install = find.widgetWithText(FilledButton, 'Install');
    expect(
      tester.getCenter(install).dx,
      greaterThan(tester.getCenter(name).dx),
    );
    expect(
      (tester.getCenter(install).dy - tester.getCenter(name).dy).abs(),
      lessThan(35),
    );
    expect(tester.takeException(), isNull);
  });
}
