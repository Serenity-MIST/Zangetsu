// Windows Sources manager (two-pane): list, Streaming / Manga / Novel chips
// (default follows the content pill, a picked chip sticks), no repositories
// section, selection, details, Update visibility, Remove confirmation,
// keyboard, empty state with 'Manage in Settings'.
//
// Uses fake Zangetsu registries (the pattern of providers_hub_windows_test)
// and the real, empty CloudStream / Aniyomi / Mihon managers.

import 'dart:io';

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/desktop/extension_load_failures.dart';
import 'package:watch_app/core/desktop/extension_runtime.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/mihon/mihon_manager.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/mode/content_mode_cubit.dart';
import 'package:watch_app/core/playback/pinned_sources.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/provider/provider_repo_registry.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/features/sources/aniyomi_repo_tab.dart';
import 'package:watch_app/features/sources/desktop_sources_manager.dart';
import 'package:watch_app/features/sources/mihon_repo_tab.dart';

const _repoUrl = 'https://example.com/z/repo.json';

/// In-memory registry: lists [entries], records uninstalls.
class _Registry implements ProviderRegistry {
  _Registry(this.entries);

  final List<ProviderRegistryEntry> entries;
  final uninstalled = <String>[];

  @override
  List<ProviderRegistryEntry> getAll() => List.of(entries);

  @override
  ({Map<String, String> types, Map<String, String> logos}) manifestMapsOf() =>
      (types: const {'mdx': 'manga', 'ak': 'anime'}, logos: const {});

  @override
  Set<String> nsfwSourceIds() => const {};

  @override
  Future<void> uninstall(String key) async {
    uninstalled.add(key);
    entries.removeWhere(
      (e) => ProviderRegistry.providerKey(e.originRepoUrl, e.name) == key,
    );
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// One repo whose manifest lists a newer 'ak' than the installed one.
class _Repos implements ProviderReposRegistry {
  _Repos(this.repos);

  final List<ProviderRepo> repos;

  @override
  List<ProviderRepo> getAll() => repos;

  @override
  ProviderRepo? get(String url) => repos.where((r) => r.url == url).firstOrNull;

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Counts pushed routes (to see 'Manage in Settings' open a screen).
class _PushObserver extends NavigatorObserver {
  int pushes = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => pushes++;
}

ProviderRegistryEntry _entry(String id, String name, String version) =>
    ProviderRegistryEntry(
      name: id,
      url: 'https://example.com/$id.js',
      version: version,
      originRepoUrl: _repoUrl,
      displayName: name,
    );

ProviderRepo _repo() => ProviderRepo(
  url: _repoUrl,
  name: 'Z Repo',
  description: '',
  lastSyncedAt: DateTime(2026),
  sources: [
    RepoSource(
      id: 'ak',
      name: 'Anikoto',
      version: '2.0.0',
      type: 'anime',
      lang: 'en',
      file: 'ak.js',
    ),
    RepoSource(
      id: 'mdx',
      name: 'MangaDex',
      version: '1.0.0',
      type: 'manga',
      lang: 'en',
      file: 'mdx.js',
    ),
  ],
);

void main() {
  late Directory dir;
  late _Registry registry;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('desktop_sources_test');
    Hive.init(dir.path);
    // Opened up front (outside the fake clock) so the manager finds them.
    await Hive.openBox<String>(kAniyomiReposBoxName);
    await Hive.openBox<String>(kMihonReposBoxName);
    await Hive.openBox<String>('lnreader_repos');
    await Hive.openBox(PinnedSources.boxName);
    // Backing box of ContentModeCubit (the top content pill).
    await Hive.openBox('content_mode');
  });

  tearDownAll(() async {
    await Hive.close();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  void register({
    required List<ProviderRegistryEntry> entries,
    List<ProviderRepo>? repos,
  }) {
    registry = _Registry(entries);
    sl.registerSingleton<AppMode>(const AppMode(isTv: false));
    sl.registerSingleton<ProviderRegistry>(registry);
    sl.registerSingleton<ProviderReposRegistry>(_Repos(repos ?? [_repo()]));
    sl.registerSingleton<CloudStreamManager>(CloudStreamManager());
    sl.registerSingleton<AniyomiManager>(AniyomiManager());
    sl.registerSingleton<MihonManager>(MihonManager());
    sl.registerSingleton<ActiveSourceCubit>(ActiveSourceCubit(fallback: ''));
  }

  setUp(() {
    DesktopExtensionRuntime.debugAvailableOverride = true;
    ExtensionLoadFailures.debugReset();
    PinnedSources.notifier.value = const [];
    // The picked chip is remembered across rebuilds; start each test clean.
    DesktopSourcesManager.debugResetMemory();
  });

  tearDown(() async {
    DesktopExtensionRuntime.debugAvailableOverride = null;
    ExtensionLoadFailures.debugReset();
    if (sl.isRegistered<ActiveSourceCubit>()) {
      await sl<ActiveSourceCubit>().close();
    }
    await sl.reset();
  });

  Future<void> pump(
    WidgetTester tester, {
    String? initial,
    List<NavigatorObserver> observers = const [],
  }) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: observers,
        home: DesktopSourcesManager(initialSourceId: initial),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Registers a real ContentModeCubit (the top content pill) set to [mode].
  Future<ContentModeCubit> registerPill(
    WidgetTester tester,
    ContentMode mode,
  ) async {
    final cubit = (await tester.runAsync(() async {
      await Hive.box('content_mode').clear();
      final c = await ContentModeCubit.create(sl<ActiveSourceCubit>());
      await c.setMode(mode);
      return c;
    }))!;
    sl.registerSingleton<ContentModeCubit>(cubit);
    addTearDown(cubit.close);
    return cubit;
  }

  final windows = TargetPlatformVariant.only(TargetPlatform.windows);

  testWidgets('lists every source with "Ecosystem · LANG" and selects the '
      'first', (tester) async {
    register(
      entries: [
        _entry('ak', 'Anikoto', '1.0.0'),
        _entry('mdx', 'MangaDex', '1.0.0'),
      ],
    );
    await pump(tester);
    // No pill registered: the Streaming chip is the default, so only the
    // anime source is listed.
    expect(find.text('Anikoto'), findsNWidgets(2)); // row + details
    expect(find.byKey(const ValueKey('desktop-source-row-mdx')), findsNothing);
    // Only Anikoto's row carries the subtitle (MangaDex is under Manga).
    expect(find.text('Zangetsu · EN'), findsOneWidget);
    // No REPOSITORIES section, repo rows or Add repository button.
    expect(find.text('REPOSITORIES'), findsNothing);
    // (The detail footer may still name the source's repo; the list may not.)
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('desktop-sources-list')),
        matching: find.textContaining('Z Repo'),
      ),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('desktop-sources-add-repo')),
      findsNothing,
    );
    // Details for the first row.
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('desktop-source-name')))
          .data,
      'Anikoto',
    );
    expect(find.byKey(const ValueKey('desktop-source-browse')), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: windows);

  testWidgets('Update shows only when an update exists', (tester) async {
    register(
      entries: [
        _entry('ak', 'Anikoto', '1.0.0'), // manifest has 2.0.0
        _entry('mdx', 'MangaDex', '1.0.0'), // up to date
      ],
    );
    await pump(tester);
    expect(find.byKey(const ValueKey('desktop-source-update')), findsOneWidget);
    // MangaDex is a manga source: switch chips to reach it.
    await tester.tap(find.byKey(const ValueKey('desktop-sources-chip-manga')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('MangaDex').first);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('desktop-source-name')))
          .data,
      'MangaDex',
    );
    expect(find.byKey(const ValueKey('desktop-source-update')), findsNothing);
  }, variant: windows);

  testWidgets('chips filter by kind; only Streaming / Manga / Novel', (
    tester,
  ) async {
    register(
      entries: [
        _entry('ak', 'Anikoto', '1.0.0'),
        _entry('mdx', 'MangaDex', '1.0.0'),
      ],
    );
    await pump(tester);
    // No 'All' chip any more.
    expect(
      find.byKey(const ValueKey('desktop-sources-chip-all')),
      findsNothing,
    );
    for (final k in ['streaming', 'manga', 'novel']) {
      expect(find.byKey(ValueKey('desktop-sources-chip-$k')), findsOneWidget);
    }
    await tester.tap(find.byKey(const ValueKey('desktop-sources-chip-manga')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('desktop-source-row-ak')), findsNothing);
    // MangaDex is now the selected (and only) source.
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('desktop-source-name')))
          .data,
      'MangaDex',
    );
  }, variant: windows);

  testWidgets('a rebuilt page keeps the picked chip and row', (tester) async {
    // Reconnecting reloads the profile and the shell rebuilds its pages;
    // the user's Manga pick must survive that instead of resetting.
    register(
      entries: [
        _entry('ak', 'Anikoto', '1.0.0'),
        _entry('mdx', 'MangaDex', '1.0.0'),
      ],
    );
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('desktop-sources-chip-manga')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('MangaDex').first);
    await tester.pumpAndSettle();
    // Throw the page away and build a fresh one, as the shell does.
    await tester.pumpWidget(const SizedBox());
    await pump(tester);
    expect(find.byKey(const ValueKey('desktop-source-row-ak')), findsNothing);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('desktop-source-name')))
          .data,
      'MangaDex',
    );
    expect(tester.takeException(), isNull);
  }, variant: windows);

  testWidgets('default chip follows the content pill until a chip is picked', (
    tester,
  ) async {
    register(
      entries: [
        _entry('ak', 'Anikoto', '1.0.0'),
        _entry('mdx', 'MangaDex', '1.0.0'),
      ],
    );
    final pill = await registerPill(tester, ContentMode.manga);
    await pump(tester);
    // Pill on Manga: the Manga chip is the default.
    expect(find.byKey(const ValueKey('desktop-source-row-ak')), findsNothing);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('desktop-source-name')))
          .data,
      'MangaDex',
    );
    // Pill to Anime (also what Movie/TV uses): Streaming follows.
    await tester.runAsync(() => pill.setMode(ContentMode.anime));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('desktop-source-row-mdx')), findsNothing);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('desktop-source-name')))
          .data,
      'Anikoto',
    );
    // The user picks Novel: it sticks when the pill moves again.
    await tester.tap(find.byKey(const ValueKey('desktop-sources-chip-novel')));
    await tester.pumpAndSettle();
    await tester.runAsync(() => pill.setMode(ContentMode.manga));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('desktop-source-row-mdx')), findsNothing);
    expect(find.byKey(const ValueKey('desktop-source-row-ak')), findsNothing);
    // No novel sources: the list points to Settings, never Add repository.
    expect(
      find.byKey(const ValueKey('desktop-sources-manage-settings')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('desktop-sources-add-repo')),
      findsNothing,
    );
  }, variant: windows);

  testWidgets('search box filters, Esc clears it', (tester) async {
    register(
      entries: [
        _entry('ak', 'Anikoto', '1.0.0'),
        _entry('hi', 'HiAnime', '1.0.0'),
      ],
    );
    await pump(tester);
    await tester.enterText(
      find.byKey(const ValueKey('desktop-sources-search')),
      'hian',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('desktop-source-row-ak')), findsNothing);
    // A search miss says 'No matches found' and does not offer the
    // 'Manage in Settings' button (that is only for an empty kind).
    await tester.enterText(
      find.byKey(const ValueKey('desktop-sources-search')),
      'zzz-nothing',
    );
    await tester.pumpAndSettle();
    expect(find.text('No matches found'), findsWidgets);
    expect(
      find.byKey(const ValueKey('desktop-sources-manage-settings')),
      findsNothing,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Anikoto'), findsWidgets);
  }, variant: windows);

  testWidgets('Down arrow moves the selection; Ctrl+F focuses the search', (
    tester,
  ) async {
    register(
      entries: [
        _entry('ak', 'Anikoto', '1.0.0'),
        _entry('hi', 'HiAnime', '1.0.0'),
      ],
    );
    await pump(tester);
    // Click the first row: the list takes keyboard focus.
    await tester.tap(find.text('Zangetsu · EN').first);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('desktop-source-name')))
          .data,
      'HiAnime',
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('desktop-sources-search')),
    );
    expect(field.focusNode!.hasFocus, isTrue);
    // Up from the search box moves the selection back.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('desktop-source-name')))
          .data,
      'Anikoto',
    );
  }, variant: windows);

  testWidgets('Remove asks first, then uninstalls through the registry', (
    tester,
  ) async {
    register(entries: [_entry('ak', 'Anikoto', '1.0.0')]);
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('desktop-source-remove')));
    await tester.pumpAndSettle();
    // Nothing removed until confirmed.
    expect(registry.uninstalled, isEmpty);
    await tester.tap(find.text('Uninstall').last);
    await tester.pumpAndSettle();
    expect(registry.uninstalled, ['$_repoUrl::ak']);
  }, variant: windows);

  testWidgets('Manage source opens on that source\'s chip', (tester) async {
    register(
      entries: [
        _entry('ak', 'Anikoto', '1.0.0'),
        _entry('mdx', 'MangaDex', '1.0.0'),
      ],
    );
    await pump(tester, initial: 'mdx');
    expect(find.byKey(const ValueKey('desktop-source-row-ak')), findsNothing);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('desktop-source-name')))
          .data,
      'MangaDex',
    );
  }, variant: windows);

  testWidgets('right-click menu: Browse, Settings, Pin, Update, Remove', (
    tester,
  ) async {
    register(entries: [_entry('ak', 'Anikoto', '1.0.0')]);
    await pump(tester);
    await tester.tap(
      // The selected row carries the scroll key, so find it by its text.
      find.text('Zangetsu · EN').first,
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    double y(String label) => tester.getTopLeft(find.text(label).last).dy;
    final order = [
      y('Browse'),
      y('Source settings'),
      y('Pin to top'),
      y('Update (v2.0.0)'),
      y('Remove'),
    ];
    expect(order, [...order]..sort());
  }, variant: windows);

  testWidgets('Pin to top moves a source above the others', (tester) async {
    register(
      entries: [
        _entry('ak', 'Anikoto', '1.0.0'),
        _entry('hi', 'HiAnime', '1.0.0'),
      ],
    );
    await pump(tester);
    await tester.tap(find.text('HiAnime'));
    await tester.pumpAndSettle();
    expect(find.text('Pin to top'), findsOneWidget);
    // Pinning writes a Hive box (real IO the fake clock never finishes), so
    // the pin store is set directly; the button calls PinnedSources.toggle.
    PinnedSources.notifier.value = const ['hi'];
    await tester.pumpAndSettle();
    final hi = tester.getTopLeft(find.text('HiAnime').first).dy;
    final ak = tester.getTopLeft(find.text('Anikoto').first).dy;
    expect(hi, lessThan(ak));
    expect(find.text('Unpin'), findsOneWidget);
  }, variant: windows);

  testWidgets('empty state offers Manage in Settings, not Add repository', (
    tester,
  ) async {
    register(entries: [], repos: []);
    final observer = _PushObserver();
    await pump(tester, observers: [observer]);
    expect(find.byKey(const ValueKey('desktop-sources-empty')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('desktop-sources-empty-add')),
      findsNothing,
    );
    final pushesBefore = observer.pushes;
    await tester.tap(
      find.byKey(const ValueKey('desktop-sources-manage-settings')),
    );
    await tester.pump();
    // Settings > Sources was pushed on top of the manager.
    expect(observer.pushes, pushesBefore + 1);
  }, variant: windows);

  testWidgets('engine missing shows the notice with Open folder', (
    tester,
  ) async {
    register(entries: [_entry('ak', 'Anikoto', '1.0.0')]);
    DesktopExtensionRuntime.debugAvailableOverride = false;
    await pump(tester);
    expect(
      find.byKey(const ValueKey('desktop-sources-engine-missing')),
      findsOneWidget,
    );
    expect(find.text('Open folder'), findsOneWidget);
  }, variant: windows);
}
