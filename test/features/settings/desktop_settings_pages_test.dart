// Windows settings pages: every row the desktop build shows must do what its
// label says there, and rows that cannot work on PC must not appear (nor be
// offered by search). The settings workspace and Windows-only rows read
// defaultTargetPlatform; setUp forces the workspace on and the row tests run
// with the Windows target variant.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/anilist/anilist_service.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/download/download_prefs.dart';
import 'package:watch_app/core/locale/locale_controller.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/playback/search_prefs.dart';
import 'package:watch_app/core/profiles/profile_pin_store.dart';
import 'package:watch_app/core/profiles/viewer_profile.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/reading/reader_prefs.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/core/supabase/supabase_service.dart';
import 'package:watch_app/core/theme/theme_controller.dart';
import 'package:watch_app/core/torrent/torrent_prefs.dart';
import 'package:watch_app/core/tracker/mal_service.dart';
import 'package:watch_app/core/tracker/mangabaka_service.dart';
import 'package:watch_app/core/tracker/simkl_service.dart';
import 'package:watch_app/core/ui/nav_prefs.dart';
import 'package:watch_app/features/auth/auth_cubit.dart';
import 'package:watch_app/features/settings/desktop_settings_workspace.dart';
import 'package:watch_app/features/settings/settings_screen.dart';
import 'package:watch_app/l10n/app_localizations.dart';

/// Windows target for the rows gated on defaultTargetPlatform.
final _windows = TargetPlatformVariant.only(TargetPlatform.windows);

class _StubSearchPrefs extends SearchPrefs {
  @override
  SearchLayout get layout => SearchLayout.vertical;
}

/// Records start-page writes without disk I/O under the fake clock.
class _StartPrefs extends NavPrefs {
  DockTab _start = DockTab.home;
  int saves = 0;

  @override
  DockTab get startTab => _start;

  @override
  Future<void> setStartTab(DockTab tab) async {
    _start = tab;
    saves++;
    notifyListeners();
  }
}

/// Records the auto-update switch without disk I/O.
class _UpdatePrefs extends PlaybackPrefs {
  bool _auto = false;
  @override
  bool get autoUpdateExtensions => _auto;
  @override
  Future<void> setAutoUpdateExtensions(bool value) async => _auto = value;
  @override
  Future<void> setLastExtensionUpdateMs(int value) async {}
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
  @override
  bool get isConnected => false;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _StubMal implements MalService {
  @override
  String get displayName => 'MyAnimeList';
  @override
  bool get isConnected => false;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _StubSimkl implements SimklService {
  @override
  String get displayName => 'Simkl';
  @override
  bool get isConnected => false;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _StubMangaBaka implements MangaBakaService {
  @override
  String get displayName => 'MangaBaka';
  @override
  bool get isConnected => false;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// Unused key storage: the locked store below never verifies a PIN.
class _NoStorage implements PinSecretStorage {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}

/// Reports every profile as PIN-locked, as the Windows PIN store would.
class _LockedPins extends ProfilePinStore {
  _LockedPins()
    : super(
        storage: _NoStorage(),
        owner: () => 'test',
        derive: (_, _, _) async => Uint8List(32),
      );
  @override
  bool isLocked(String profileId) => true;
}

void main() {
  late ActiveSourceCubit activeCubit;
  late Directory hiveDir;
  final l10n = lookupAppLocalizations(const Locale('en'));

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
    GetIt.instance
      ..registerSingleton<NavPrefs>(_StartPrefs())
      ..registerSingleton<ViewerProfileStore>(ViewerProfileStore())
      ..registerSingleton<AppMode>(AppMode(isTv: false))
      ..registerSingleton<SearchPrefs>(_StubSearchPrefs())
      ..registerSingleton<ProviderRegistry>(_StubProviderRegistry())
      ..registerSingleton<AniListService>(_StubAniList())
      ..registerSingleton<MalService>(_StubMal())
      ..registerSingleton<SimklService>(_StubSimkl())
      ..registerSingleton<MangaBakaService>(_StubMangaBaka())
      ..registerSingleton<PlaybackPrefs>(_UpdatePrefs())
      ..registerSingleton<DownloadPrefs>(DownloadPrefs())
      ..registerSingleton<TorrentPrefs>(TorrentPrefs())
      ..registerSingleton<ReaderPrefs>(ReaderPrefs());
    activeCubit = ActiveSourceCubit();
    // The workspace follows the target platform, so opt in for every test.
    SettingsScreen.debugDesktopWorkspaceOverride = true;
  });

  tearDown(() async {
    SettingsScreen.debugDesktopWorkspaceOverride = null;
    await activeCubit.close();
    await GetIt.instance.reset();
    await Hive.deleteFromDisk();
    if (hiveDir.existsSync()) await hiveDir.delete(recursive: true);
  });

  Future<void> pumpSettings(WidgetTester tester, {Size? size}) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => hiveDir.path,
    );
    await tester.binding.setSurfaceSize(size ?? const Size(1280, 2000));
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
          home: const SettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(DesktopSettingsWorkspace), findsOneWidget);
  }

  Future<void> openSection(WidgetTester tester, String id) async {
    await tester.tap(find.byKey(ValueKey('desktop-nav-$id')));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Interface: Start page replaces Customize dock and saves the choice',
    (tester) async {
      await pumpSettings(tester);
      await openSection(tester, 'interface');
      expect(find.text('Customize dock'), findsNothing);
      expect(find.text('Start page'), findsOneWidget);
      // The splash row is named for the only picker left on Windows.
      expect(find.text('Splash screen'), findsOneWidget);
      expect(find.text('Icon, splash & banner'), findsNothing);

      await tester.tap(find.text('Start page'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      for (final label in ['Home', 'My List', 'Sources', 'Downloads']) {
        expect(
          find.descendant(of: find.byType(Dialog), matching: find.text(label)),
          findsOneWidget,
          reason: label,
        );
      }
      await tester.tap(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.text('Downloads'),
        ),
      );
      await tester.pumpAndSettle();
      final prefs = GetIt.instance<NavPrefs>() as _StartPrefs;
      expect(prefs.startTab, DockTab.downloads);
      expect(prefs.saves, 1);
      // Confirmation is shown on the settings page itself.
      expect(
        find.text('Zangetsu will open on Downloads next time'),
        findsOneWidget,
      );
      // The row now reports the saved page.
      expect(
        find.descendant(
          of: find.byType(DesktopSettingsWorkspace),
          matching: find.text('Downloads'),
        ),
        findsWidgets,
      );
      expect(tester.takeException(), isNull);
    },
    variant: _windows,
  );

  testWidgets(
    'App language opens the desktop dialog, not a bottom sheet',
    (tester) async {
      await pumpSettings(tester);
      await openSection(tester, 'interface');
      await tester.ensureVisible(find.text(l10n.appLanguage));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.appLanguage));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.text(l10n.appLanguageSystem),
        ),
        findsOneWidget,
      );
      // Dialog stays bounded on a wide window.
      expect(
        tester
            .getSize(
              find
                  .descendant(
                    of: find.byType(Dialog),
                    matching: find.byType(Material),
                  )
                  .first,
            )
            .width,
        lessThanOrEqualTo(560),
      );
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(LocaleController.tag, LocaleController.systemTag);
    },
    variant: _windows,
  );

  testWidgets(
    'Sources shows Auto-update extensions on Windows, not Source updates',
    (tester) async {
      await pumpSettings(tester);
      await openSection(tester, 'sources');
      expect(find.text(l10n.autoUpdateExtensions), findsOneWidget);
      expect(find.text(l10n.sourceUpdates), findsNothing);
    },
    variant: _windows,
  );

  testWidgets(
    'search never offers settings that Windows pages hide',
    (tester) async {
      await pumpSettings(tester);
      Future<void> search(String q) async {
        await tester.enterText(find.byType(TextField).first, q);
        await tester.pumpAndSettle();
      }

      await search('pip');
      expect(find.text(l10n.autoPictureInPicture), findsNothing);
      await search('wallpaper');
      expect(find.text(l10n.materialYou), findsNothing);
      await search('gesture');
      expect(find.text(l10n.gestureControls), findsNothing);
      await search('private');
      expect(find.text(l10n.keepDownloadsPrivate), findsNothing);
      // Real Windows settings are still found.
      await search('autoplay next');
      expect(find.text(l10n.autoplayNextEpisode), findsOneWidget);
      // Home rows is listed once (its own row), not again as a leaf.
      await search('customise home');
      expect(find.text(l10n.homeRows), findsOneWidget);
    },
    variant: _windows,
  );

  testWidgets('section header has no "Settings /" breadcrumb button', (
    tester,
  ) async {
    await pumpSettings(tester);
    await openSection(tester, 'about');
    expect(find.widgetWithText(TextButton, l10n.settingsTitle), findsNothing);
    expect(find.text(' / '), findsNothing);
  });

  testWidgets('Privacy hides the Aniyomi NSFW switch without the engine', (
    tester,
  ) async {
    await pumpSettings(tester);
    await openSection(tester, 'advanced');
    await tester.tap(find.text(l10n.privacy));
    await tester.pumpAndSettle();
    expect(find.text(l10n.enableNSFWSources2), findsOneWidget);
    // The test runner is not a Windows build with the extension engine.
    expect(find.text(l10n.showNSFWSources), findsNothing);
  }, variant: _windows);

  testWidgets(
    'Account profile strip switches profile instead of duplicating Manage',
    (tester) async {
      final store = GetIt.instance<ViewerProfileStore>();
      final second = await tester.runAsync(() => store.create('Second'));
      await pumpSettings(tester);
      expect(find.text('Manage profiles'), findsNothing);
      expect(find.text('Switch profile'), findsOneWidget);
      final avatar = find.byKey(ValueKey('desktop-profile-${second!.id}'));
      expect(avatar, findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(avatar);
        // Let the Hive write behind switchTo finish on the real clock.
        for (var i = 0; i < 20 && store.activeId != second.id; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pumpAndSettle();
      expect(store.activeId, second.id);
      expect(find.text('Watching'), findsOneWidget);
    },
  );

  testWidgets('a PIN-locked profile asks for its PIN and Cancel keeps it', (
    tester,
  ) async {
    final store = GetIt.instance<ViewerProfileStore>();
    final second = await tester.runAsync(() => store.create('Locked'));
    GetIt.instance.registerSingleton<ProfilePinStore>(_LockedPins());
    await pumpSettings(tester);
    final before = store.activeId;
    await tester.tap(find.byKey(ValueKey('desktop-profile-${second!.id}')));
    await tester.pumpAndSettle();
    expect(find.text('Enter PIN'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(store.activeId, before);
  });

  testWidgets(
    'Theme & colour: every accent swatch reachable in a narrow pane',
    (tester) async {
      await pumpSettings(tester, size: const Size(1000, 1400));
      await openSection(tester, 'interface');
      await tester.tap(find.text('Theme & colour'));
      await tester.pumpAndSettle();
      final cards = find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('accent-'),
      );
      expect(cards, findsNWidgets(ThemeController.accentPresets.length + 1));
      // Wrapped, not a horizontal strip: each one is on screen and tappable.
      for (final element in cards.evaluate()) {
        final rect = tester.getRect(find.byWidget(element.widget));
        expect(rect.right, lessThanOrEqualTo(1000), reason: '${rect.right}');
      }
      expect(find.byKey(const ValueKey('accent-custom')).hitTestable(),
          findsOneWidget);
      // Detail logo row is named apart from the Poster cards row.
      expect(find.text('Title logo on Detail'), findsOneWidget);
    },
  );

  testWidgets('Background colour dialog stays bounded on a wide window', (
    tester,
  ) async {
    await pumpSettings(tester, size: const Size(1920, 1400));
    await openSection(tester, 'interface');
    await tester.tap(find.text('Theme & colour'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Background colour'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Background colour'));
    await tester.pumpAndSettle();
    final dialog = find.byKey(const ValueKey('background-colour-dialog'));
    expect(dialog, findsOneWidget);
    expect(
      tester
          .getSize(
            find.descendant(of: dialog, matching: find.byType(Material)).first,
          )
          .width,
      lessThanOrEqualTo(440),
    );
    expect(tester.takeException(), isNull);
  });
}
