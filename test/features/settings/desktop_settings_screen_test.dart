import 'dart:io';
import 'package:watch_app/features/settings/desktop_settings_workspace.dart';
import 'package:watch_app/core/ui/nav_prefs.dart';
import 'package:watch_app/core/ui/desktop_settings_surface.dart';
import 'package:watch_app/core/ui/streaming_prefs.dart';
import 'package:watch_app/core/profiles/viewer_profile.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/anilist/anilist_service.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/appwrite/appwrite_service.dart';
import 'package:watch_app/core/download/download_prefs.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/playback/search_prefs.dart';
import 'package:watch_app/core/reading/reader_prefs.dart';
import 'package:watch_app/core/torrent/torrent_prefs.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/core/supabase/supabase_service.dart';
import 'package:watch_app/core/locale/locale_controller.dart';
import 'package:watch_app/core/theme/theme_controller.dart';
import 'package:watch_app/core/tracker/mal_service.dart';
import 'package:watch_app/core/tracker/simkl_service.dart';
import 'package:watch_app/core/tracker/mangabaka_service.dart';
import 'package:watch_app/features/auth/auth_screens.dart';
import 'package:watch_app/features/auth/auth_cubit.dart';
import 'package:watch_app/features/auth/migration_bridge.dart';
import 'package:watch_app/features/settings/settings_screen.dart';
import 'package:watch_app/features/settings/desktop_settings_category_grid.dart';
import 'package:watch_app/l10n/app_localizations.dart';

MigrationBridge _fakeBridge() => MigrationBridge(
  invoke: (_, _) async => const {'ok': false},
  signInPassword: (_, _) async => false,
  verifyOtp: (_, _) async => false,
);

// ── Minimal stubs (mirrors settings_screen_tv_test.dart / AppMode wiring) ────

class _StubSearchPrefs extends SearchPrefs {
  @override
  SearchLayout get layout => SearchLayout.vertical;
}

/// UI selection tests use immediate writes; real disk persistence is verified
/// separately outside Flutter's fake animation clock below.
class _WidgetBatchPrefs extends PlaybackPrefs {
  String _style = 'classic';
  int saves = 0;

  @override
  String get batchDownloadStyle => _style;

  @override
  Future<void> setBatchDownloadStyle(String value) async {
    _style = value;
    saves++;
  }
}

/// Keeps the My List dialog test independent of real I/O and animation time.
class _WidgetListStylePrefs extends NavPrefs {
  String _style = 'classic';
  int saves = 0;

  @override
  String get myListStyle => _style;

  @override
  Future<void> setMyListStyle(String value) async {
    _style = value;
    saves++;
    notifyListeners();
  }
}

class _StubProviderRegistry implements ProviderRegistry {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  List<ProviderRegistryEntry> getAll() => const [];

  @override
  ProviderRegistryEntry? entryFor(String sourceId) => null;

  @override
  Set<String> nsfwSourceIds() => const {};
}

class _StubAniList implements AniListService {
  @override
  String get displayName => 'AniList';
  bool connected = false;
  @override
  bool get isConnected => connected;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _StubMal implements MalService {
  @override
  String get displayName => 'MyAnimeList';
  bool connected = false;
  @override
  bool get isConnected => connected;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _StubSimkl implements SimklService {
  @override
  String get displayName => 'Simkl';
  bool connected = false;
  @override
  bool get isConnected => connected;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// Keeps the tracker list offline while checking desktop-only navigation.
class _StubMangaBaka implements MangaBakaService {
  bool connected = false;
  @override
  bool get isConnected => connected;
  @override
  String get displayName => 'MangaBaka';
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void _mockPathProvider(WidgetTester tester) {
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    channel,
    (call) async => '/tmp/test',
  );
}

void main() {
  late ActiveSourceCubit activeCubit;
  late Directory hiveDir;

  setUp(() async {
    hiveDir = await Directory.systemTemp.createTemp();
    Hive.init(hiveDir.path);
    await Hive.openBox(DownloadPrefs.boxName);
    await Hive.openBox(TorrentPrefs.boxName);
    await Hive.openBox(ThemeController.boxName);
    await Hive.openBox(LocaleController.boxName);
    await LocaleController.init();
    await Hive.openBox(PlaybackPrefs.boxName);
    await ReaderPrefs.init();
    await NavPrefs.init();
    await ViewerProfileStore.init();
    final sl = GetIt.instance;
    sl.registerSingleton<NavPrefs>(NavPrefs());
    sl.registerSingleton<ViewerProfileStore>(ViewerProfileStore());
    sl
      ..registerSingleton<AppMode>(AppMode(isTv: false))
      ..registerSingleton<SearchPrefs>(_StubSearchPrefs())
      ..registerSingleton<ProviderRegistry>(_StubProviderRegistry())
      ..registerSingleton<AniListService>(_StubAniList())
      ..registerSingleton<MalService>(_StubMal())
      ..registerSingleton<SimklService>(_StubSimkl())
      ..registerSingleton<MangaBakaService>(_StubMangaBaka())
      ..registerSingleton<PlaybackPrefs>(PlaybackPrefs())
      ..registerSingleton<DownloadPrefs>(DownloadPrefs())
      ..registerSingleton<TorrentPrefs>(TorrentPrefs())
      ..registerSingleton<ReaderPrefs>(ReaderPrefs());
    activeCubit = ActiveSourceCubit();
  });

  tearDown(() async {
    await activeCubit.close();
    await GetIt.instance.reset();
    await Hive.deleteFromDisk();
    if (hiveDir.existsSync()) await hiveDir.delete(recursive: true);
  });

  Future<void> pumpSettings(
    WidgetTester tester, {
    bool fromPlayer = false,
    bool routed = false,
  }) async {
    _mockPathProvider(tester);
    await tester.binding.setSurfaceSize(const Size(1000, 2200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final authCubit = AuthCubit(
      SupabaseService(),
      AppwriteService(),
      _fakeBridge(),
    );
    addTearDown(authCubit.close);
    GetIt.instance.registerSingleton<AuthCubit>(authCubit);

    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<AuthCubit>.value(value: authCubit),
          BlocProvider<ActiveSourceCubit>.value(value: activeCubit),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: fromPlayer || routed
              ? Builder(
                  builder: (context) => TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            SettingsScreen(returnToPlayer: fromPlayer),
                      ),
                    ),
                    child: const Text('Open player settings'),
                  ),
                )
              : const SettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (fromPlayer || routed) {
      await tester.tap(find.text('Open player settings'));
      await tester.pumpAndSettle();
    }
  }

  testWidgets('desktop workspace keeps category and embedded search routes', (
    tester,
  ) async {
    await pumpSettings(tester);
    expect(find.byType(DesktopSettingsWorkspace), findsOneWidget);
    expect(find.byType(DesktopSettingsCategoryGrid), findsNothing);
    expect(find.text('Settings appearance'), findsNothing);

    // The new cards retain real existing routes rather than placeholder pages.
    await tester.tap(find.text('Sources'));
    await tester.pumpAndSettle();
    expect(find.text('Providers'), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    // The new presentation also keeps the existing leaf-search destination.
    await tester.enterText(find.byType(TextField), 'autoplay next');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Autoplay next episode'));
    await tester.pumpAndSettle();
    expect(find.byType(PlaybackSettingsScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('desktop-nav-playback')), findsOneWidget);
    // The destination's Back pops only the leaf, preserving the sidebar.
    await tester.tap(find.byTooltip('Back').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    expect(find.byType(DesktopSettingsWorkspace), findsOneWidget);
    expect(find.byKey(const ValueKey('desktop-nav-account')), findsOneWidget);
  });

  testWidgets('player settings has a visible return button after drill-down', (
    tester,
  ) async {
    await pumpSettings(tester, fromPlayer: true);
    expect(find.byType(DesktopSettingsWorkspace), findsOneWidget);
    await tester.tap(find.text('Sources'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Open player settings'), findsOneWidget);
    expect(find.byType(SettingsScreen), findsNothing);
  });

  testWidgets('workspace exposes every category and defaults to Account', (
    tester,
  ) async {
    await pumpSettings(tester);

    // Each section is now a single drill-down row.
    for (final section in const [
      'account',
      'sources',
      'playback',
      'downloads',
      'interface',
      'advanced',
      'about',
    ]) {
      expect(
        find.byKey(ValueKey('desktop-nav-$section')),
        findsOneWidget,
        reason: 'category: $section',
      );
    }
    // Notifications is Android-only (its sole entry), so its category is absent
    // on the non-Android test host.
    expect(find.text('Notifications'), findsNothing);
    // The individual settings live INSIDE their section now, not up top.
    expect(find.text('Providers'), findsNothing);
    expect(find.text('Storage'), findsNothing);
    expect(find.text('Backup & Restore'), findsOneWidget);
    expect(find.text('Manage profiles'), findsOneWidget);
  });

  testWidgets('tapping a category drills into its settings', (tester) async {
    await pumpSettings(tester);

    await tester.tap(find.text('Sources'));
    await tester.pumpAndSettle();

    // The Sources section's tiles are now on screen.
    for (final t in const ['Providers', 'Source health']) {
      expect(find.text(t), findsOneWidget, reason: 'tile: $t');
    }
    expect(find.text('Active source'), findsNothing);
    // The sidebar persists while the content pane changes categories.
    expect(find.byKey(const ValueKey('desktop-nav-downloads')), findsOneWidget);
    expect(find.byKey(const ValueKey('desktop-nav-about')), findsOneWidget);
    expect(find.text('Backup & Restore'), findsNothing);
  });

  for (final section in ['sources', 'interface', 'advanced']) {
    testWidgets('one Back exits desktop $section without an Account hop', (tester) async {
      await pumpSettings(tester, routed: true);
      await tester.tap(find.byKey(ValueKey('desktop-nav-$section')));
      await tester.pumpAndSettle();
      expect(find.byType(DesktopSettingsWorkspace), findsOneWidget);
      await tester.tap(find.byTooltip('Back').first);
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsNothing);
      expect(find.text('Open player settings'), findsOneWidget);
    });
  }

  testWidgets('system Back exits a desktop category in one action', (tester) async {
    await pumpSettings(tester, routed: true);
    await tester.tap(find.byKey(const ValueKey('desktop-nav-advanced')));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsNothing);
  });

  testWidgets('desktop playback exposes working control-bar customization', (
    tester,
  ) async {
    await pumpSettings(tester);
    await tester.tap(find.text('Playback'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Player controls'),
      250,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Player controls'));
    await tester.pumpAndSettle();
    expect(find.text('Reset'), findsOneWidget);
    expect(find.text('Default player'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('connection summary includes all four trackers', (tester) async {
    final sl = GetIt.instance;
    (sl<AniListService>() as _StubAniList).connected = true;
    (sl<MalService>() as _StubMal).connected = true;
    (sl<SimklService>() as _StubSimkl).connected = true;
    (sl<MangaBakaService>() as _StubMangaBaka).connected = true;
    await pumpSettings(tester);
    await tester.tap(find.byKey(const ValueKey('desktop-nav-account')));
    await tester.pumpAndSettle();
    expect(find.text('4 connected'), findsOneWidget);
  });

  testWidgets('desktop account settings do not offer phone QR pairing', (
    tester,
  ) async {
    await pumpSettings(tester);
    await tester.tap(find.byKey(const ValueKey('desktop-nav-account')));
    await tester.pumpAndSettle();
    expect(find.text('Connections'), findsOneWidget);
    expect(find.text('Pair this PC'), findsNothing);
    expect(find.byIcon(Icons.qr_code_2_rounded), findsNothing);
  });

  testWidgets('desktop login offers direct sign-in without a phone QR', (
    tester,
  ) async {
    await pumpSettings(tester);
    tester
        .state<NavigatorState>(find.byType(Navigator).first)
        .push(MaterialPageRoute<void>(builder: (_) => const LoginScreen()));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNWidgets(2));
    expect(find.byIcon(Icons.qr_code_rounded), findsNothing);
    expect(find.text('Sign in with your phone'), findsNothing);
  });

  testWidgets('desktop connections show direct trackers without QR transfer', (
    tester,
  ) async {
    await pumpSettings(tester);
    await tester.tap(find.byKey(const ValueKey('desktop-nav-account')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connections'));
    await tester.pumpAndSettle();
    for (final tracker in ['AniList', 'MyAnimeList', 'Simkl', 'MangaBaka']) {
      expect(find.text(tracker), findsOneWidget);
    }
    expect(find.text('Scan and link all'), findsNothing);
    expect(find.byIcon(Icons.qr_code_scanner_rounded), findsNothing);
  });

  test(
    'Android Player is marked experimental in the player settings label',
    () {
      final l10n = lookupAppLocalizations(const Locale('en'));

      expect(l10n.androidPlayer, 'Android Player (Experimental)');
    },
  );

  testWidgets('Reading section has a Reader entry that opens reader defaults', (
    tester,
  ) async {
    await pumpSettings(tester);

    await tester.tap(find.text('Reading'));
    await tester.pumpAndSettle();
    expect(find.text('Reader'), findsOneWidget);

    await tester.tap(find.text('Reader'));
    await tester.pumpAndSettle();

    // Desktop section headings preserve readable localized case.
    final l10n = lookupAppLocalizations(const Locale('en'));
    expect(find.text(l10n.modeManga), findsOneWidget);
    expect(find.text(l10n.modeNovel), findsOneWidget);
  });

  testWidgets(
    'desktop batch style keeps descriptions and saves only selection',
    (tester) async {
      Future<void> settle(String step) async {
        await tester.pumpAndSettle(
          const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 5),
        );
      }

      final prefs = _WidgetBatchPrefs();
      await GetIt.instance.unregister<PlaybackPrefs>();
      GetIt.instance.registerSingleton<PlaybackPrefs>(prefs);
      await pumpSettings(tester);
      final l10n = lookupAppLocalizations(const Locale('en'));
      await tester.tap(find.byKey(const ValueKey('desktop-nav-interface')));
      await settle('Interface selected');
      await tester.ensureVisible(find.text(l10n.batchDownloadStyle));
      await settle('batch row visible');
      await tester.tap(find.text(l10n.batchDownloadStyle));
      await settle('dialog open');
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text(l10n.batchDownloadStyleBlurb), findsOneWidget);
      expect(find.text(l10n.batchDownloadMinimalBlurb), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.text(l10n.batchDownloadMinimal),
        ),
      );
      await settle('minimal chosen');
      expect(prefs.batchDownloadStyle, 'minimal');
      expect(prefs.saves, 1);
      expect(find.byType(Dialog), findsNothing);
      await tester.ensureVisible(find.text(l10n.batchDownloadStyle));
      await settle('batch row visible again');
      await tester.tap(find.text(l10n.batchDownloadStyle));
      await settle('dialog reopened');
      await tester.tap(find.byTooltip('Close'));
      await settle('dialog cancelled');
      expect(prefs.batchDownloadStyle, 'minimal');
      expect(prefs.saves, 1);
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'batch style persists through closing and reopening its real Hive box',
    () async {
      final prefs = GetIt.instance<PlaybackPrefs>();
      await prefs.setBatchDownloadStyle('minimal');
      await Hive.box(PlaybackPrefs.boxName).close();
      await Hive.openBox(PlaybackPrefs.boxName);
      expect(prefs.batchDownloadStyle, 'minimal');
    },
  );

  testWidgets('desktop region dialog opens and cancellation preserves region', (
    tester,
  ) async {
    await pumpSettings(tester);
    final l10n = lookupAppLocalizations(const Locale('en'));
    final before = StreamingPrefs.region;
    await tester.tap(find.byKey(const ValueKey('desktop-nav-sources')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.streamingRegion));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text(l10n.streamingRegionSubtitle), findsOneWidget);
    expect(
      find.descendant(of: find.byType(Dialog), matching: find.text('US')),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(StreamingPrefs.region, before);
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets(
    'Reader translation appearance keeps desktop scope in its dialog',
    (tester) async {
      await pumpSettings(tester);
      await tester.tap(find.text('Reading'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reader'));
      await tester.pumpAndSettle();
      final label = lookupAppLocalizations(
        const Locale('en'),
      ).mangaTranslationAppearance;
      await tester.ensureVisible(find.text(label));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.byType(GraphiteSettingsPanel),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Appearance font and animation choices use desktop dialogs', (
    tester,
  ) async {
    await pumpSettings(tester);
    await tester.tap(find.byKey(const ValueKey('desktop-nav-interface')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Theme & colour'));
    await tester.tap(find.text('Theme & colour'));
    await tester.pumpAndSettle();
    final l10n = lookupAppLocalizations(const Locale('en'));
    // Cancel both pickers: opening settings must not download a font or save
    // an animation preference before the user has selected anything.
    for (final label in ['App font', l10n.animationStyle]) {
      await tester.ensureVisible(find.text(label));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      if (label == 'App font') {
        expect(find.text('Downloads on first use'), findsWidgets);
      } else {
        for (final description in [
          l10n.animRiseDesc,
          l10n.animFadeDesc,
          l10n.animZoomDesc,
        ]) {
          expect(
            find.descendant(
              of: find.byType(Dialog),
              matching: find.text(description),
            ),
            findsOneWidget,
          );
        }
      }
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop My List choice saves once and cancellation is inert', (
    tester,
  ) async {
    final prefs = _WidgetListStylePrefs();
    await GetIt.instance.unregister<NavPrefs>();
    GetIt.instance.registerSingleton<NavPrefs>(prefs);
    await pumpSettings(tester);
    await tester.tap(find.byKey(const ValueKey('desktop-nav-interface')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('My List style'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('My List style'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(
      find.text('Switch between Streaming, Manga and Novel inside My List.'),
      findsOneWidget,
    );
    await tester.tap(
      find.descendant(of: find.byType(Dialog), matching: find.text('New')),
    );
    await tester.pumpAndSettle();
    expect(prefs.myListStyle, 'new');
    expect(prefs.saves, 1);
    await tester.ensureVisible(find.text('My List style'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('My List style'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(prefs.myListStyle, 'new');
    expect(prefs.saves, 1);
  });

  test('My List style survives reopening its real preference box', () async {
    final prefs = GetIt.instance<NavPrefs>();
    await prefs.setMyListStyle('new');
    await Hive.box(NavPrefs.boxName).close();
    await Hive.openBox(NavPrefs.boxName);
    expect(prefs.myListStyle, 'new');
  });

  testWidgets('search cuts across every section (flat filtered list)', (
    tester,
  ) async {
    await pumpSettings(tester);

    await tester.enterText(find.byType(TextField), 'backup');
    await tester.pumpAndSettle();

    // The matching tile surfaces regardless of its section…
    expect(find.text('Backup & Restore'), findsOneWidget);
    // …and non-matching tiles/categories are filtered out.
    expect(find.text('Providers'), findsNothing);
    expect(find.byKey(const ValueKey('desktop-nav-sources')), findsOneWidget);
  });
}
