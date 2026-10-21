import 'dart:io';
import 'package:watch_app/core/ui/nav_prefs.dart';
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
          home: fromPlayer
              ? Builder(
                  builder: (context) => TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            const SettingsScreen(returnToPlayer: true),
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
    if (fromPlayer) {
      await tester.tap(find.text('Open player settings'));
      await tester.pumpAndSettle();
    }
  }

  testWidgets('player settings has a visible return button after drill-down', (
    tester,
  ) async {
    await pumpSettings(tester, fromPlayer: true);
    expect(find.text('Back to player'), findsOneWidget);
    await tester.tap(find.text('Sources'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byTooltip('Back'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Open player settings'), findsOneWidget);
    expect(find.byType(SettingsScreen), findsNothing);
  });

  testWidgets('top level shows one tappable row per section, not the tiles', (
    tester,
  ) async {
    await pumpSettings(tester);

    // Each section is now a single drill-down row.
    for (final section in const [
      'Account & sync',
      'Sources',
      'Playback',
      'Downloads',
      'Interface',
      'Advanced',
      'About',
    ]) {
      expect(find.text(section), findsOneWidget, reason: 'category: $section');
    }
    // Notifications is Android-only (its sole entry), so its category is absent
    // on the non-Android test host.
    expect(find.text('Notifications'), findsNothing);
    // The individual settings live INSIDE their section now, not up top.
    expect(find.text('Providers'), findsNothing);
    expect(find.text('Storage'), findsNothing);
    expect(find.text('Backup & Restore'), findsNothing);
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
    // Other sections' rows are gone (we're on the Sources sub-page).
    expect(find.text('Downloads'), findsNothing);
    expect(find.text('About'), findsNothing);
  });

  testWidgets(
    'desktop settings have one header and section back returns to hub',
    (tester) async {
      await pumpSettings(tester);
      expect(find.text('Settings.'), findsNothing);
      expect(find.byType(AppBar), findsOneWidget);
      await tester.tap(find.text('Sources'));
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsNothing);
      expect(find.text('Sources'), findsOneWidget);
      expect(find.byTooltip('Back'), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Account & sync'), findsOneWidget);
    },
  );

  testWidgets('connection summary includes all four trackers', (tester) async {
    final sl = GetIt.instance;
    (sl<AniListService>() as _StubAniList).connected = true;
    (sl<MalService>() as _StubMal).connected = true;
    (sl<SimklService>() as _StubSimkl).connected = true;
    (sl<MangaBakaService>() as _StubMangaBaka).connected = true;
    await pumpSettings(tester);
    await tester.tap(find.text('Account & sync'));
    await tester.pumpAndSettle();
    expect(find.text('4 connected'), findsOneWidget);
  });

  testWidgets('desktop account settings do not offer phone QR pairing', (
    tester,
  ) async {
    await pumpSettings(tester);
    await tester.tap(find.text('Account & sync'));
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
        .state<NavigatorState>(find.byType(Navigator))
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
    await tester.tap(find.text('Account & sync'));
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

    expect(find.text('MANGA'), findsOneWidget);
    expect(find.text('NOVEL'), findsOneWidget);
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
    expect(find.text('Sources'), findsNothing);
  });
}
