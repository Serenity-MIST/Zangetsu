import 'dart:io';
import 'package:watch_app/features/settings/desktop_settings_workspace.dart';
import 'package:watch_app/core/ui/nav_prefs.dart';
import 'package:watch_app/core/ui/desktop_settings_surface.dart';
import 'package:watch_app/core/ui/streaming_prefs.dart';
import 'package:watch_app/core/profiles/viewer_profile.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:watch_app/core/desktop/desktop_storage.dart';
import 'package:watch_app/core/desktop/desktop_prefs.dart';
import 'package:watch_app/features/settings/download_location_screen.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/anilist/anilist_service.dart';
import 'package:watch_app/core/app_mode.dart';
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
import 'package:watch_app/features/settings/settings_screen.dart';
import 'package:watch_app/l10n/app_localizations.dart';

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
    // The workspace gate reads the target platform now (not the host OS), so
    // these desktop-workspace tests opt in explicitly.
    SettingsScreen.debugDesktopWorkspaceOverride = true;
  });

  tearDown(() async {
    SettingsScreen.debugDesktopWorkspaceOverride = null;
    debugDefaultTargetPlatformOverride = null;
    DesktopStorage.downloadsRoot = null;
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

    final authCubit = AuthCubit(SupabaseService());
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
    // Backup & Restore lives on the Zangetsu account page now; the Account
    // section links to that page and to Connected services.
    expect(find.text('Backup & Restore'), findsNothing);
    expect(
      find.widgetWithText(DesktopSettingsAction, 'Zangetsu account'),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(DesktopSettingsAction, 'Connected services'),
      findsOneWidget,
    );
    // The Account page's profile strip switches profiles (the card above
    // opens the manager), so there is no duplicate Manage button.
    expect(find.text('Switch profile'), findsOneWidget);
    expect(find.text('Manage profiles'), findsNothing);
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
    // The Windows Player section (control bar editor) is a Windows target row.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
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
    debugDefaultTargetPlatformOverride = null;
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
    expect(find.text('4 trackers connected'), findsOneWidget);
  });

  testWidgets('desktop account settings do not offer phone QR pairing', (
    tester,
  ) async {
    await pumpSettings(tester);
    await tester.tap(find.byKey(const ValueKey('desktop-nav-account')));
    await tester.pumpAndSettle();
    expect(
      find.widgetWithText(DesktopSettingsAction, 'Connected services'),
      findsOneWidget,
    );
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
    await tester.tap(
      find.widgetWithText(DesktopSettingsAction, 'Connected services'),
    );
    await tester.pumpAndSettle();
    for (final tracker in ['AniList', 'MyAnimeList', 'Simkl', 'MangaBaka']) {
      expect(find.text(tracker), findsOneWidget);
    }
    expect(find.text('Scan and link all'), findsNothing);
    expect(find.byIcon(Icons.qr_code_scanner_rounded), findsNothing);
  });

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
        // The new System option leads the list, so the downloadable fonts sit
        // below the dialog's fold: scroll the dialog list to reach them.
        expect(find.text("Your system's default font"), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('Rubik'),
          120,
          scrollable: find
              .descendant(
                of: find.byType(Dialog),
                matching: find.byType(Scrollable),
              )
              .first,
        );
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
    // My List style is a Windows-only Interface row.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
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
    debugDefaultTargetPlatformOverride = null;
  });

  test('My List style survives reopening its real preference box', () async {
    final prefs = GetIt.instance<NavPrefs>();
    await prefs.setMyListStyle('new');
    await Hive.box(NavPrefs.boxName).close();
    await Hive.openBox(NavPrefs.boxName);
    expect(prefs.myListStyle, 'new');
  });

  // Windows: Downloads has a Download location row, and the search leaves
  // pointed at it (LeafParent.downloadLocation) appear and open that page.
  testWidgets('Windows Download location row and its search leaves', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    DesktopStorage.downloadsRoot = '${hiveDir.path}\\Downloads\\Zangetsu';
    await pumpSettings(tester);

    await tester.tap(find.byKey(const ValueKey('desktop-nav-downloads')));
    await tester.pumpAndSettle();
    expect(find.text('Download location'), findsOneWidget);
    await tester.tap(find.text('Download location'));
    await tester.pumpAndSettle();
    expect(find.byType(DownloadLocationScreen), findsOneWidget);
    await tester.tap(find.byTooltip('Back').last);
    await tester.pumpAndSettle();
    expect(find.byType(DownloadLocationScreen), findsNothing);

    for (final leaf in const [
      'Choose folder…',
      'Reset to default',
      'Open in File Explorer',
    ]) {
      await tester.enterText(find.byType(TextField), leaf);
      await tester.pumpAndSettle();
      // The query also sits in the search field; match the result row only.
      final hit = find.byWidgetPredicate(
        (w) => w is Text && w.data == leaf,
      );
      expect(hit, findsOneWidget, reason: leaf);
      await tester.tap(hit);
      await tester.pumpAndSettle();
      expect(find.byType(DownloadLocationScreen), findsOneWidget, reason: leaf);
      await tester.tap(find.byTooltip('Back').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
    }
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('search cuts across every section (flat filtered list)', (
    tester,
  ) async {
    await pumpSettings(tester);

    await tester.enterText(find.byType(TextField), 'backup');
    await tester.pumpAndSettle();

    // The matching row surfaces regardless of its section: backup lives on
    // the Zangetsu account page, so that page is the hit…
    expect(
      find.widgetWithText(DesktopSettingsAction, 'Zangetsu account'),
      findsOneWidget,
    );
    // …and non-matching tiles/categories are filtered out.
    expect(find.text('Providers'), findsNothing);
    expect(find.byKey(const ValueKey('desktop-nav-sources')), findsOneWidget);
  });

  // set-1: a one-page section (Playback) shows that page as the section, so
  // one Back leaves Settings instead of landing on a one-row list.
  testWidgets('one-page sections show their page with nothing underneath', (
    tester,
  ) async {
    await pumpSettings(tester, routed: true);
    await tester.tap(find.byKey(const ValueKey('desktop-nav-playback')));
    await tester.pumpAndSettle();
    expect(find.byType(PlaybackSettingsScreen), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsNothing);
    expect(find.text('Open player settings'), findsOneWidget);
  });

  // set-8 C: Settings reopens on the section used last, not always Account.
  testWidgets('reopens on the last settings section', (tester) async {
    // Real Hive file IO runs outside the fake-async test zone. The box is
    // closed again before the widgets run: a write started inside the fake
    // zone (a sidebar tap saves the section) never completes there, and
    // tearDown would wait on it forever. Closed box -> the getter falls back.
    await tester.runAsync(() async {
      await Hive.openBox(DesktopPrefs.boxName);
      await DesktopPrefs.setLastSettingsSection('sources');
    });
    await pumpSettings(tester);
    // Opens on Sources, not Account.
    expect(find.text('Providers'), findsOneWidget);
    expect(find.text('Backup & Restore'), findsNothing);
    await tester.runAsync(() => Hive.box(DesktopPrefs.boxName).close());
  });

  // set-3 + set-2: Ctrl+F focuses the sidebar search from a page, words
  // match in any order, and a leaf result focuses its own row.
  testWidgets('Ctrl+F searches and a leaf result focuses its row', (
    tester,
  ) async {
    await pumpSettings(tester);
    await tester.tap(find.byKey(const ValueKey('desktop-nav-sources')));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    final search = find.byType(TextField).first;
    expect(tester.widget<TextField>(search).focusNode?.hasFocus, isTrue);
    await tester.enterText(search, 'episode next autoplay');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Autoplay next episode'));
    // Route transition, seeking and the flash.
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
    expect(find.byType(PlaybackSettingsScreen), findsOneWidget);
    final row = find.widgetWithText(
      GraphiteSettingsControl,
      'Autoplay next episode',
    );
    expect(row, findsOneWidget);
    final focused = FocusManager.instance.primaryFocus?.context;
    expect(focused, isNotNull);
    expect(
      find.descendant(of: row, matching: find.byWidget(focused!.widget)),
      findsOneWidget,
    );
  });
}
