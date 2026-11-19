import 'dart:io';
import 'package:watch_app/core/ui/nav_prefs.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/anilist/anilist_service.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/download/download_prefs.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/playback/search_prefs.dart';
import 'package:watch_app/core/profiles/viewer_profile.dart';
import 'package:watch_app/core/reading/manga_translation/manga_page_translation_models.dart';
import 'package:watch_app/core/reading/reader_prefs.dart';
import 'package:watch_app/core/torrent/torrent_prefs.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/core/supabase/supabase_service.dart';
import 'package:watch_app/core/desktop/desktop_reveal.dart';
import 'package:watch_app/core/locale/locale_controller.dart';
import 'package:watch_app/core/logging/app_logger.dart';
import 'package:watch_app/core/logging/log_report_service.dart';
import 'package:watch_app/core/theme/theme_controller.dart';
import 'package:watch_app/core/tracker/mal_service.dart';
import 'package:watch_app/core/tracker/simkl_service.dart';
import 'package:watch_app/features/auth/auth_cubit.dart';
import 'package:watch_app/features/profiles/viewer_profile_home_screen.dart';
import 'package:watch_app/features/settings/settings_screen.dart';
import 'package:watch_app/l10n/app_localizations.dart';

class _SignedOutAuthCubit extends AuthCubit {
  _SignedOutAuthCubit() : super(SupabaseService()) {
    emit(const AuthState(status: AuthStatus.unauthenticated));
  }
}

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
  bool get isConnected => false;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _StubMal implements MalService {
  @override
  bool get isConnected => false;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _StubSimkl implements SimklService {
  @override
  bool get isConnected => false;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _MangaTranslationReaderPrefs extends ReaderPrefs {
  String sourceLanguage = 'ja';
  String targetLanguage = 'en';
  MangaTranslationEngine engine = MangaTranslationEngine.online;
  MangaOnlineTranslationProvider provider =
      MangaOnlineTranslationProvider.google;

  @override
  String get mangaTranslationSourceLanguage => sourceLanguage;

  @override
  Future<void> setMangaTranslationSourceLanguage(String value) async {
    sourceLanguage = value;
  }

  @override
  String get mangaTranslationTargetLanguage => targetLanguage;

  @override
  Future<void> setMangaTranslationTargetLanguage(String value) async {
    targetLanguage = value;
  }

  @override
  MangaTranslationEngine get mangaTranslationEngine => engine;

  @override
  Future<void> setMangaTranslationEngine(MangaTranslationEngine value) async {
    engine = value;
  }

  @override
  MangaOnlineTranslationProvider get mangaOnlineTranslationProvider => provider;

  @override
  Future<void> setMangaOnlineTranslationProvider(
    MangaOnlineTranslationProvider value,
  ) async {
    provider = value;
  }
}

/// Log intake not configured, so "Share logs" goes straight to the local save.
class _OfflineLogReporter implements LogReportService {
  @override
  bool get configured => false;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// Log intake configured but the upload fails (offline), so "Share logs"
/// falls back to saving the file.
class _FailingLogReporter implements LogReportService {
  @override
  bool get configured => true;
  @override
  Future<String?> send({String note = ''}) async => null;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// Save dialog stand-in: writes into [dir] (like the real picker) or throws
/// when [fail] is set, to exercise the app-folder fallback.
class _FakeSavePicker extends FilePickerPlatform {
  _FakeSavePicker(this.dir, {this.fail = false});

  final Directory dir;
  final bool fail;
  String? requestedName;
  String? requestedTitle;

  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    requestedName = fileName;
    requestedTitle = dialogTitle;
    if (fail) throw PlatformException(code: 'dialog_failed');
    final file = File('${dir.path}${Platform.pathSeparator}$fileName');
    await file.writeAsBytes(bytes);
    return Uri.file(file.path);
  }
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
    sl
      ..registerSingleton<AppMode>(AppMode(isTv: false))
      ..registerSingleton<SearchPrefs>(_StubSearchPrefs())
      ..registerSingleton<ProviderRegistry>(_StubProviderRegistry())
      ..registerSingleton<AniListService>(_StubAniList())
      ..registerSingleton<MalService>(_StubMal())
      ..registerSingleton<SimklService>(_StubSimkl())
      ..registerSingleton<PlaybackPrefs>(PlaybackPrefs())
      ..registerSingleton<DownloadPrefs>(DownloadPrefs())
      ..registerSingleton<TorrentPrefs>(TorrentPrefs())
      ..registerSingleton<ReaderPrefs>(ReaderPrefs());
    sl.registerSingleton<ViewerProfileStore>(ViewerProfileStore());
    activeCubit = ActiveSourceCubit();
    // These tests cover the phone hub. The test host is Windows, where the
    // screen would otherwise pick its desktop workspace.
    SettingsScreen.debugDesktopWorkspaceOverride = false;
  });

  tearDown(() async {
    SettingsScreen.debugDesktopWorkspaceOverride = null;
    debugRevealOverride = null;
    await activeCubit.close();
    await GetIt.instance.reset();
    await Hive.deleteFromDisk();
    if (hiveDir.existsSync()) await hiveDir.delete(recursive: true);
  });

  Future<void> pumpSettings(
    WidgetTester tester, {
    bool showBackButton = false,
    bool openFromProfile = false,
  }) async {
    _mockPathProvider(tester);
    await tester.binding.setSurfaceSize(const Size(1000, 2200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final authCubit = _SignedOutAuthCubit();
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
          home: openFromProfile
              ? const ViewerProfileHomeScreen()
              : SettingsScreen(showBackButton: showBackButton),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'top level shows one combined profile row and one row per section',
    (tester) async {
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
        expect(
          find.text(section),
          findsOneWidget,
          reason: 'category: $section',
        );
      }
      expect(find.text('Profiles & account'), findsOneWidget);
      expect(find.text('Watching as Home · Not signed in'), findsOneWidget);
      expect(find.text('Profiles'), findsNothing);
      // Notifications is Android-only (its sole entry), so its category is absent
      // on the non-Android test host.
      expect(find.text('Notifications'), findsNothing);
      // The individual settings live INSIDE their section now, not up top.
      expect(find.text('Providers'), findsNothing);
      expect(find.text('Storage'), findsNothing);
      expect(find.text('Backup & Restore'), findsNothing);
    },
  );

  testWidgets('route-pushed Settings shows a visible back button', (
    tester,
  ) async {
    await pumpSettings(tester, openFromProfile: true);
    await tester.tap(find.byTooltip('Profile menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('App settings'));
    await tester.pumpAndSettle();

    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
  });

  testWidgets(
    'combined profile row opens viewer manager and keeps sign-in available',
    (tester) async {
      await pumpSettings(tester);

      await tester.tap(find.text('Profiles & account'));
      await tester.pumpAndSettle();

      expect(find.text('Profiles'), findsOneWidget);
      expect(find.text('Ask who is watching on launch'), findsOneWidget);
      expect(find.text('Not signed in'), findsOneWidget);
      expect(find.text('Sign in'), findsOneWidget);
    },
  );

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

  testWidgets('Manga page translation is configurable in Reader settings', (
    tester,
  ) async {
    final translationPrefs = _MangaTranslationReaderPrefs();
    GetIt.instance
      ..unregister<ReaderPrefs>()
      ..registerSingleton<ReaderPrefs>(translationPrefs);

    const translationChannel = MethodChannel('zangetsu/manga_translation');
    final methodCalls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      translationChannel,
      (call) async {
        methodCalls.add(call.method);
        return switch (call.method) {
          'supportedOcrLanguages' ||
          'supportedOfflineLanguages' => ['ja', 'en', 'hi'],
          _ => null,
        };
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        translationChannel,
        null,
      ),
    );

    await pumpSettings(tester);

    await tester.tap(find.text('Reading'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reader'));
    await tester.pumpAndSettle();

    expect(find.text('Manga page translation'), findsOneWidget);
    await tester.tap(find.text('Manga page translation'));
    await tester.pumpAndSettle();

    expect(find.text('Translate page'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('manga-translation-source')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('manga-translation-target')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('manga-translation-submit')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('manga-translation-source')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('manga-language-hi')));
    await tester.pumpAndSettle();
    Navigator.of(
      tester.element(find.byKey(const ValueKey('manga-translation-source'))),
    ).pop();
    await tester.pumpAndSettle();

    expect(translationPrefs.mangaTranslationSourceLanguage, 'hi');
    expect(methodCalls, ['supportedOcrLanguages', 'supportedOfflineLanguages']);
    expect(methodCalls, isNot(contains('recognize')));
    expect(methodCalls, isNot(contains('translateTexts')));
    expect(methodCalls, isNot(contains('downloadModels')));
  });

  testWidgets('Manga translation appearance opens from Reader settings', (
    tester,
  ) async {
    await pumpSettings(tester);

    await tester.tap(find.text('Reading'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reader'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Manga translation appearance'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('manga-translation-appearance-preview')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('manga-translation-appearance-size')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('manga-translation-appearance-opacity')),
      findsOneWidget,
    );
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

  group('sync library partial failure message', () {
    test('names what synced, what failed and how to retry', () {
      expect(
        syncPartialFailureMessage(pushed: 12, failed: 3),
        "Synced 12 items, but 3 items couldn't be uploaded. "
        'Run Sync library again to retry.',
      );
    });

    test('uses singular wording for one item', () {
      expect(
        syncPartialFailureMessage(pushed: 1, failed: 1),
        "Synced 1 item, but 1 item couldn't be uploaded. "
        'Run Sync library again to retry.',
      );
    });

    test('does not claim anything synced when nothing did', () {
      expect(
        syncPartialFailureMessage(pushed: 0, failed: 2),
        "Couldn't sync your library: 2 items couldn't be uploaded. "
        'Check your connection and try again.',
      );
    });
  });

  test('Windows log file name is stamped to the minute', () {
    expect(
      windowsLogFileName(DateTime(2026, 1, 5, 9, 7)),
      'zangetsu-logs-20260105-0907.txt',
    );
  });

  group('Share logs on Windows', () {
    late Directory ioRoot;

    setUp(() {
      ioRoot = Directory.systemTemp.createTempSync('zangetsu-share-logs');
    });

    tearDown(() {
      if (ioRoot.existsSync()) ioRoot.deleteSync(recursive: true);
    });

    /// Real file I/O cannot finish inside the test's fake clock, so give it
    /// real time between frames until [done] holds.
    Future<void> settleIo(WidgetTester tester, bool Function() done) async {
      for (var i = 0; i < 150 && !done(); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
    }

    /// Opens the Windows workspace, taps Advanced > Share logs, and returns
    /// the paths File Explorer was asked to select.
    Future<List<String>> shareLogsOnWindows(
      WidgetTester tester,
      _FakeSavePicker picker, {
      LogReportService? reporter,
    }) async {
      SettingsScreen.debugDesktopWorkspaceOverride = true;
      GetIt.instance.registerSingleton<LogReportService>(
        reporter ?? _OfflineLogReporter(),
      );
      AppLogger.instance.log('share logs widget test line');
      final previousPicker = FilePickerPlatform.instance;
      FilePickerPlatform.instance = picker;
      addTearDown(() => FilePickerPlatform.instance = previousPicker);
      final revealed = <String>[];
      debugRevealOverride = (path, {required select}) async {
        revealed.add(path);
      };

      await pumpSettings(tester);
      // Temp and app-support folders point at real directories for the
      // export and the fallback copy.
      final temp = Directory('${ioRoot.path}${Platform.pathSeparator}temp')
        ..createSync();
      final support =
          Directory('${ioRoot.path}${Platform.pathSeparator}support')
            ..createSync();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => call.method == 'getApplicationSupportDirectory'
            ? support.path
            : temp.path,
      );

      await tester.tap(find.byKey(const ValueKey('desktop-nav-advanced')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Share logs'));
      await tester.pump();
      await settleIo(
        tester,
        () => find
            .byKey(const ValueKey('logs-saved-snackbar'))
            .evaluate()
            .isNotEmpty,
      );
      await tester.pump(const Duration(milliseconds: 750));
      return revealed;
    }

    testWidgets('saves through the Save dialog and selects it in Explorer', (
      tester,
    ) async {
      final saveDir = Directory('${ioRoot.path}${Platform.pathSeparator}out')
        ..createSync();
      final picker = _FakeSavePicker(saveDir);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final revealed = await shareLogsOnWindows(tester, picker);

        expect(picker.requestedTitle, 'Save logs');
        expect(
          picker.requestedName,
          matches(RegExp(r'^zangetsu-logs-\d{8}-\d{4}\.txt$')),
        );
        final saved =
            '${saveDir.path}${Platform.pathSeparator}${picker.requestedName}';
        expect(File(saved).readAsStringSync(), contains('share logs widget'));
        // Selected in Explorer straight away, and the snack bar says where.
        expect(revealed, [saved]);
        expect(find.text('Logs saved to $saved'), findsOneWidget);

        await tester.tap(find.text('Show in folder'));
        await settleIo(tester, () => revealed.length > 1);
        expect(revealed, [saved, saved]);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('a failed upload says so in the dialog title and snack bar', (
      tester,
    ) async {
      final saveDir = Directory('${ioRoot.path}${Platform.pathSeparator}out')
        ..createSync();
      final picker = _FakeSavePicker(saveDir);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await shareLogsOnWindows(
          tester,
          picker,
          reporter: _FailingLogReporter(),
        );

        expect(picker.requestedTitle, contains("Couldn't send the report"));
        final saved =
            '${saveDir.path}${Platform.pathSeparator}${picker.requestedName}';
        expect(
          find.text("Couldn't send the report. Logs saved to $saved"),
          findsOneWidget,
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('falls back to the app logs folder when the dialog fails', (
      tester,
    ) async {
      final picker = _FakeSavePicker(ioRoot, fail: true);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final revealed = await shareLogsOnWindows(tester, picker);

        final sep = Platform.pathSeparator;
        final kept =
            '${ioRoot.path}${sep}support${sep}logs$sep${picker.requestedName}';
        expect(File(kept).readAsStringSync(), contains('share logs widget'));
        expect(revealed, [kept]);
        expect(find.text('Logs saved to $kept'), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
