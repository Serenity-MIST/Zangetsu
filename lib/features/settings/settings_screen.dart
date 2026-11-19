import '../../core/desktop/desktop_focus_repair.dart';
import '../../core/ui/nav_prefs.dart';
import '../../core/desktop/desktop_prefs.dart';
import '../../core/ui/desktop_settings_row_target.dart';
import 'desktop_settings_navigation.dart';
import 'desktop_settings_search.dart';
import 'desktop_settings_profile.dart';
import 'desktop_settings_workspace.dart';
import 'dart:async';
import '../../core/theme/theme_controller.dart';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/anilist/anilist_service.dart';
import '../../core/app_config.dart';
import '../../core/app_mode.dart';
import '../../core/metadata/streaming_providers.dart';
import '../../core/tracker/tracker_hub.dart';
import '../../core/ui/streaming_prefs.dart';
import '../../core/zmode/metadata_provider_prefs.dart';
import '../../core/cache/media_cache.dart';
import '../../core/logging/app_logger.dart';
import '../../core/logging/log_report_service.dart';
import '../../core/tracker/mal_service.dart';
import '../../core/tracker/mangabaka_service.dart';
import '../../core/tracker/simkl_service.dart';
import '../../core/tracker/tracker.dart';
import '../player/player_screen.dart' show openSubtitleStyleSheet;
import '../player/shader_presets.dart';
import '../player/tv_exo_spike_screen.dart';
import '../../core/di/injector.dart';
import '../../core/platform/apple_tv.dart';
import '../../core/playback/external_player.dart';
import '../../core/playback/my_list.dart';
import '../../core/playback/list_idle_runner.dart'; // R5 rows in Playback
import '../../core/playback/list_idle_status.dart' show ListIdleRule;
import '../../core/playback/playback_prefs.dart';
import '../../core/playback/watch_history.dart';
import '../../core/reading/read_history.dart';
import 'library_cloud_sync.dart';
import '../auth/reconnect.dart';
import '../home/home_catalogue_prefs.dart';
import '../../core/privacy/incognito_mode.dart';
import '../../core/profiles/viewer_profile.dart';
import '../../core/profiles/viewer_profile_avatar.dart';
import '../../core/playback/search_prefs.dart';
import '../../core/playback/subtitle_language.dart';
import '../../core/aniyomi/aniyomi_provider.dart';
import '../../core/provider/cloudstream_provider.dart';
import '../../core/provider/cs_dns.dart';
import '../../core/provider/provider_manager.dart';
import '../downloads/downloads_screen.dart';
import '../history/history_screen.dart';
import 'app_face_screen.dart';
import 'appearance_screen.dart';
import 'poster_card_settings_screen.dart';
import 'home_rows_screen.dart';
import 'nav_tabs_screen.dart';
import 'reader_settings_screen.dart';
import 'discord_settings_screen.dart';
import 'download_location_screen.dart';
import 'keyboard_shortcuts_screen.dart';
import 'window_system_settings_screen.dart';
import 'torrent_settings_screen.dart';
import '../../core/provider/provider_downloader.dart';
import '../../core/provider/provider_registry.dart';
import '../../core/state/active_source_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/locale/app_language_picker.dart';
import '../../core/locale/locale_controller.dart';
import '../../l10n/l10n.dart';
import '../../core/mode/content_mode_cubit.dart';
import '../home/metadata_switch_sheet.dart';
import '../home/cubit/home_cubit.dart';
import '../../l10n/ui_strings.dart';
import '../../core/ui/subtitle_language_picker.dart';
import '../../core/theme/app_text.dart';
import '../../core/update/update_service.dart';
import '../update/update_dialog.dart';
import '../../core/ui/app_dialog.dart';
import '../../core/ui/settings_widgets.dart';
import '../../core/ui/desktop_settings_surface.dart';
import '../../core/desktop/desktop_chrome_colors.dart';
import '../../core/desktop/desktop_reveal.dart';
import 'package:path_provider/path_provider.dart';
import '../../core/tv/tv_list_focusable.dart';
import '../../core/ui/dock_visibility.dart';
import '../../core/ui/team_section.dart';
import 'contributors_screen.dart';
import 'donate_screen.dart';
import '../auth/auth_cubit.dart';
import '../backup/backup_screen.dart';
import '../watch_together/ui/watch_party_lobby_screen.dart';
import '../watch_together/watch_together_controller.dart';
import '../profiles/viewer_profiles_screen.dart';
import '../profiles/profile_unlock.dart';
import '../../core/profiles/profile_lock_store.dart';
import '../../core/update/extension_auto_updater.dart';
import '../onboarding/how_it_works.dart';
import '../notify/subscriptions_screen.dart';
import 'tracker_settings_screen.dart';
// set-6: Windows storage dashboard, used by the settings_storage.dart part.
import 'desktop_storage_dashboard.dart';
import '../sources/source_health_screen.dart';
import '../sources/sources_screen.dart';
import 'source_priority_screen.dart';
import 'desktop_settings_slider.dart'; // shared Windows slider row (Playback)
import 'player_controls_screen.dart';
import 'native_player_cache_screen.dart';
import 'connections_screen_tv.dart';
import 'settings_search_index.dart';
import 'cubit/settings_cubit.dart';
import '../../core/tv/tv_focusable.dart';

part 'settings_playback.dart';
part 'settings_storage.dart';
part 'settings_about.dart';
part 'settings_connections.dart';
part 'settings_privacy.dart';
part 'settings_tv_pickers.dart';

/// Default name for a log saved on Windows, stamped to the minute so repeated
/// saves never overwrite each other (zangetsu-logs-20261117-0930.txt).
@visibleForTesting
String windowsLogFileName(DateTime now) {
  String two(int v) => v.toString().padLeft(2, '0');
  return 'zangetsu-logs-${now.year}${two(now.month)}${two(now.day)}-'
      '${two(now.hour)}${two(now.minute)}.txt';
}

/// "Sync library" result when some uploads failed: says what did sync, how
/// many did not, and what to do, with correct singular/plural wording.
@visibleForTesting
String syncPartialFailureMessage({required int pushed, required int failed}) {
  String items(int n) => n == 1 ? '1 item' : '$n items';
  final notSent = "${items(failed)} couldn't be uploaded";
  return pushed == 0
      ? "Couldn't sync your library: $notSent. "
            'Check your connection and try again.'
      : 'Synced ${items(pushed)}, but $notSent. '
            'Run Sync library again to retry.';
}

/// Windows desktop UI gate for this library and its parts. Read through
/// [defaultTargetPlatform] (not Platform.isWindows) so phone tests, which run
/// on a Windows host as the Android target, keep the phone layout.
bool get _windowsUi => defaultTargetPlatform == TargetPlatform.windows;

/// Settings navigation shares one entry catalogue across platforms. Windows
/// presents category cards; phone and TV retain their own navigation surfaces.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    this.returnToPlayer = false,
    this.showBackButton = false,
  });

  final bool returnToPlayer;
  final bool showBackButton;

  /// Test hook: forces the Windows settings workspace on (true) or off
  /// (false). Null in the app, where the Windows host decides. Phone-layout
  /// tests set false because the test host itself runs on Windows.
  @visibleForTesting
  static bool? debugDesktopWorkspaceOverride;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // Opt-in in-app DNS-over-HTTPS for CloudStream sources (Android-only). Loaded
  // from native on open; CsDns.off (default) until then.
  int _dnsChoice = CsDns.off;

  final TextEditingController _searchCtrl = TextEditingController();
  // Search text + which section's sub-page is open. Held in a Cubit so the
  // drill-down/search state is testable; the async prefs mirror below
  // (_dnsChoice) and subtitle refreshes stay local setState.
  late final SettingsCubit _settingsCubit = SettingsCubit();

  /// Nested navigator for TV leaf screens (Playback, Downloads, …) so they
  /// stay in the content pane beside the left rail instead of covering it.
  final List<_TvSettingsLeaf> _tvLeaves = [];
  final _desktopNavigator = GlobalKey<NavigatorState>();
  int _desktopDepth = 0;

  /// set-3: the always-visible Windows search box, focused by Ctrl+F / Ctrl+K.
  final FocusNode _desktopSearchFocus = FocusNode(
    debugLabel: 'desktop-settings-search',
  );

  bool get _isTv => sl.isRegistered<AppMode>() && sl<AppMode>().isTv;

  /// Windows desktop build. Used for Windows-only rows and pickers; read via
  /// [defaultTargetPlatform] so widget tests can switch it on.
  bool get _windowsDesktop =>
      defaultTargetPlatform == TargetPlatform.windows && !_isTv;

  /// The Windows settings workspace (sidebar, graphite panels and dialogs)
  /// instead of the phone hub. One gate for every layout and picker choice so
  /// they can never disagree; tests flip it with
  /// [SettingsScreen.debugDesktopWorkspaceOverride].
  bool get _desktopWorkspace =>
      !_isTv &&
      (SettingsScreen.debugDesktopWorkspaceOverride ?? _windowsUi);

  /// Guards the avatar strip against a second switch while one is running.
  bool _switchingProfile = false;

  /// True while "Auto-update extensions" is running its immediate check.
  bool _updatingExtensions = false;

  /// The metadata rows show the CURRENT provider, and it can now be changed
  /// from outside this screen (the Home wordmark shortcut). Without this the
  /// rows kept whatever they read when the screen was built and only caught
  /// up when their own picker ran.
  void _onProviderChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    MetadataProviderPrefs.revision.addListener(_onProviderChanged);
    if (Platform.isAndroid) {
      CsDns.get().then((c) {
        if (mounted) setState(() => _dnsChoice = c);
      });
    }
  }

  @override
  void dispose() {
    MetadataProviderPrefs.revision.removeListener(_onProviderChanged);
    _searchCtrl.dispose();
    _desktopSearchFocus.dispose();
    _settingsCubit.close();
    // Settings is gone, so nothing of it is open any more (shell-1).
    if (_desktopWorkspace) DesktopSettingsNavigation.atRoot.value = true;
    for (final leaf in _tvLeaves) {
      if (!leaf.done.isCompleted) leaf.done.complete();
    }
    _tvLeaves.clear();
    dockHiddenBySection.value = false; // never leave the dock stuck hidden
    shellBackIntercepted.value = false;
    super.dispose();
  }

  /// Counts every account type, including the reading-only MangaBaka tracker.
  int get _connectedTrackerCount => <Tracker>[
    if (sl.isRegistered<AniListService>()) sl<AniListService>(),
    if (sl.isRegistered<MalService>()) sl<MalService>(),
    if (sl.isRegistered<SimklService>()) sl<SimklService>(),
    if (sl.isRegistered<MangaBakaService>()) sl<MangaBakaService>(),
  ].where((tracker) => tracker.isConnected).length;

  ProviderRegistry get _registry => sl<ProviderRegistry>();

  Future<void> _push(Widget screen) => _pushBuilder((_) => screen);

  /// Pushes onto the TV nested navigator (or the root navigator on phone).
  /// [builder] is re-invoked when Settings rebuilds so section pages stay fresh.
  Future<void> _pushBuilder(Widget Function(BuildContext context) builder) {
    if (_desktopWorkspace) return _pushDesktopBuilder(builder);
    if (_isTv) {
      final done = Completer<void>();
      final key = UniqueKey();
      setState(() {
        _tvLeaves.add(_TvSettingsLeaf(key: key, builder: builder, done: done));
      });
      _syncShellBackIntercept();
      return done.future;
    }
    // Desktop leaf pages must match the in-hub section slide/fade below;
    // MaterialPageRoute otherwise chooses a different platform animation.
    final desktop = switch (defaultTargetPlatform) {
      TargetPlatform.windows || TargetPlatform.linux || TargetPlatform.macOS =>
        true,
      _ => false,
    };
    return Navigator.of(context).push<void>(
      desktop
          ? PageRouteBuilder<void>(
              pageBuilder: (context, animation, secondaryAnimation) =>
                  builder(context),
              transitionDuration: const Duration(milliseconds: 280),
              reverseTransitionDuration: const Duration(milliseconds: 280),
              transitionsBuilder:
                  (context, animation, secondaryAnimation, child) {
                    final curved = animation.drive(
                      CurveTween(curve: Curves.easeOutCubic),
                    );
                    return FadeTransition(
                      opacity: curved,
                      child: SlideTransition(
                        position: curved.drive(
                          Tween<Offset>(
                            begin: const Offset(1, 0),
                            end: Offset.zero,
                          ),
                        ),
                        child: child,
                      ),
                    );
                  },
            )
          : MaterialPageRoute<void>(builder: builder),
    );
  }

  /// Keeps Windows leaf pages inside the reference workspace rather than
  /// replacing its sidebar. Original route completion/await behavior survives.
  Future<void> _pushDesktopBuilder(
    Widget Function(BuildContext context) builder,
  ) async {
    final navigator = _desktopNavigator.currentState;
    if (navigator == null) return;
    setState(() => _desktopDepth++);
    shellBackIntercepted.value = true;
    try {
      await navigator.push<void>(
        PageRouteBuilder<void>(
          // set-2: a page opened from a search result scrolls down to the
          // named row when it is not built yet (see DesktopSettingsRowSeeker).
          pageBuilder: (context, animation, secondaryAnimation) =>
              DesktopSettingsRowSeeker(child: builder(context)),
          transitionDuration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 220),
          reverseTransitionDuration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 180),
          transitionsBuilder: (context, animation, secondaryAnimation, child) =>
              FadeTransition(opacity: animation, child: child),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _desktopDepth--);
        _syncShellBackIntercept();
      }
    }
  }

  void _removeTvLeaf(Page<dynamic> page) {
    final i = _tvLeaves.indexWhere((l) => l.key == page.key);
    if (i < 0) return;
    final leaf = _tvLeaves.removeAt(i);
    if (!leaf.done.isCompleted) leaf.done.complete();
  }

  /// Tell the TV/phone shell when Settings owns Back (section, search, or a
  /// nested leaf route on TV).
  void _syncShellBackIntercept({SettingsState? state}) {
    final s = state ?? _settingsCubit.state;
    if (_desktopWorkspace) {
      // Windows: sidebar sections are peers, so an open section is not
      // something Back closes; only a page above it or search text are.
      final owned = _desktopDepth > 0 || s.query.isNotEmpty;
      shellBackIntercepted.value = owned;
      DesktopSettingsNavigation.atRoot.value = !owned;
      dockHiddenBySection.value = s.openSection != null;
      return;
    }
    final nestedCanPop = _isTv && _tvLeaves.isNotEmpty;
    shellBackIntercepted.value =
        s.openSection != null || s.query.isNotEmpty || nestedCanPop;
    if (!_isTv) {
      dockHiddenBySection.value = s.openSection != null;
    }
  }

  /// TV multi-item section list — same Material page push/pop as Playback.
  Widget _tvSectionPage(BuildContext context, String section) {
    final enabledCount = _registry.getAll().where((e) => e.enabled).length;
    final connectedCount = _connectedTrackerCount;
    final items = _buildSettingsEntries(
      l10n: context.l10n,
      enabledCount: enabledCount,
      connectedCount: connectedCount,
    ).where((e) => e.section == section).toList();

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar(settingsSectionTitle(context.l10n, section)),
      body: ListView(
        clipBehavior: Clip.none,
        padding: const EdgeInsets.only(top: 8, bottom: 24),
        children: [
          SettingsCard(
            children: [
              for (var i = 0; i < items.length; i++)
                items[i].toTile(iconAccent: i == 0, autofocus: i == 0),
            ],
          ),
        ],
      ),
    );
  }

  /// The metadata provider store is registered by `registerZangetsuMode`,
  /// which runs late in boot — and this screen is built eagerly as the dock's
  /// Profile tab. Guarded so it reads as the default rather than throwing if
  /// it is built first. Same guard `SourceRepository._domainOverride` uses.
  static MetadataProviderPrefs? get _providerPrefs =>
      sl.isRegistered<MetadataProviderPrefs>()
      ? sl<MetadataProviderPrefs>()
      : null;

  static String _animeProviderLabel() =>
      _providerPrefs?.anime == AnimeProvider.mal ? 'MyAnimeList' : 'AniList';

  static String _videoProviderLabel() =>
      _providerPrefs?.video == VideoProvider.simkl ? 'Simkl' : 'TMDB';

  /// MAL browsing works signed out (public reads), but the *list* does not.
  /// The switch-time toast only fires once, so someone who picked MAL months
  /// ago, or signed out since, gets no explanation for the missing list. Say
  /// it on the row instead, where it stays true.
  static bool get _malNeedsLogin =>
      _providerPrefs?.anime == AnimeProvider.mal &&
      !(sl.isRegistered<TrackerHub>() &&
          sl<TrackerHub>().connected.any(
            (t) => t.displayName.toLowerCase().contains('myanimelist'),
          ));

  /// Label for the title-language row. Romaji and Native are proper nouns for
  /// what they are, so only the third needs translating.
  String _titleLanguageLabel(AppLocalizations l10n) =>
      switch (_providerPrefs?.titleLanguage ?? TitleLanguage.english) {
        TitleLanguage.romaji => 'Romaji',
        TitleLanguage.english => 'English',
        TitleLanguage.native => l10n.titleLanguageNative,
      };

  /// Which of AniList's three titles to show. Seeded from the account on
  /// sign-in, so most people never open this.
  Future<void> _pickTitleLanguage() async {
    final prefs = _providerPrefs;
    if (prefs == null) return;
    final l10n = context.l10n;
    final options = TitleLanguage.values
        .map(
          (t) => (
            t,
            switch (t) {
              TitleLanguage.romaji => 'Romaji',
              TitleLanguage.english => 'English',
              TitleLanguage.native => l10n.titleLanguageNative,
            },
          ),
        )
        .toList();

    final TitleLanguage? picked;
    if (_isTv) {
      picked = await showDialog<TitleLanguage>(
        context: context,
        barrierColor: Colors.black54,
        builder: (ctx) => _TvOptionPicker<TitleLanguage>(
          title: l10n.titleLanguage,
          options: options,
          current: prefs.titleLanguage,
        ),
      );
    } else if (_desktopWorkspace) {
      picked = await showGraphiteSettingsChoice<TitleLanguage>(
        context,
        title: l10n.titleLanguage,
        options: options,
        current: prefs.titleLanguage,
      );
    } else {
      picked = await showModalBottomSheet<TitleLanguage>(
        context: context,
        backgroundColor: AppColors.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (sheet) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 14),
              Text(l10n.titleLanguage, style: AppText.headline),
              const SizedBox(height: 10),
              for (final t in TitleLanguage.values)
                ListTile(
                  title: Text(switch (t) {
                    TitleLanguage.romaji => 'Romaji',
                    TitleLanguage.english => 'English',
                    TitleLanguage.native => l10n.titleLanguageNative,
                  }, style: AppText.body),
                  trailing: prefs.titleLanguage == t
                      ? Icon(Icons.check_rounded, color: AppColors.accent)
                      : null,
                  onTap: () => Navigator.of(sheet).pop(t),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
    }
    if (picked == null) return;
    await prefs.setTitleLanguage(picked);
  }

  /// Windows App language: the bounded desktop choice dialog instead of the
  /// phone bottom sheet. Same options and the same [LocaleController] write,
  /// so the whole app re-renders in the new language as soon as it is picked.
  Future<void> _pickAppLanguageDesktop() async {
    final l10n = context.l10n;
    final device = View.of(context).platformDispatcher.locale;
    final current = LocaleController.tag;
    final picked = await showGraphiteSettingsChoice<String>(
      context,
      title: l10n.appLanguage,
      current: current,
      options: [
        (LocaleController.systemTag, l10n.appLanguageSystem),
        ...LocaleController.options,
      ],
      optionDescriptions: {
        LocaleController.systemTag: l10n.appLanguageSystemSubtitle(
          LocaleController.nativeNameForDevice(device),
        ),
      },
    );
    if (picked == null || picked == current) return;
    await LocaleController.setTag(picked);
  }

  /// Start page choices on Windows: the sidebar destinations the app can open
  /// on. Labels match the sidebar.
  static final _desktopStartPages = <(DockTab, String)>[
    for (final tab in NavPrefs.desktopStartTabs) (tab, tab.label),
  ];

  String _desktopStartLabel() {
    final tab = sl<NavPrefs>().startTab;
    return _desktopStartPages
        .firstWhere((p) => p.$1 == tab, orElse: () => _desktopStartPages.first)
        .$2;
  }

  /// Windows replacement for "Customize dock": only the start page applies
  /// on PC, since the sidebar is fixed. Read once when the app opens.
  Future<void> _pickDesktopStartPage() async {
    final prefs = sl<NavPrefs>();
    final picked = await showGraphiteSettingsChoice<DockTab>(
      context,
      title: 'Start page',
      description: 'The page Zangetsu shows when it opens. Applies the next '
          'time you start the app.',
      current: prefs.startTab,
      options: _desktopStartPages,
    );
    if (picked == null || picked == prefs.startTab) return;
    await prefs.setStartTab(picked);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            'Zangetsu will open on '
            '${_desktopStartLabel()} next time',
          ),
        ),
      );
  }

  /// Turning auto-update on at Windows runs one check right away, so the
  /// switch visibly does something; after that it runs once a day at launch
  /// (AppLaunchChecks in home_screen.dart, started by RootShell on Windows).
  /// Phone keeps its launch-only behaviour.
  Future<void> _setAutoUpdateExtensions(bool value) async {
    final prefs = sl<PlaybackPrefs>();
    await prefs.setAutoUpdateExtensions(value);
    if (!mounted) return;
    setState(() {});
    if (!value || !_windowsDesktop || _updatingExtensions) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _updatingExtensions = true);
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(content: Text(context.l10n.checkingExtensionsForUpdates)),
      );
    var updated = 0;
    try {
      // Stamp first so the launch check does not repeat this run today.
      await prefs.setLastExtensionUpdateMs(
        DateTime.now().millisecondsSinceEpoch,
      );
      updated = await ExtensionAutoUpdater.run();
    } finally {
      if (mounted) setState(() => _updatingExtensions = false);
    }
    if (!mounted) return;
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            updated == 0
                ? 'Extensions are up to date'
                : '$updated extension${updated == 1 ? '' : 's'} updated',
          ),
        ),
      );
  }

  /// Send the diagnostic log straight to us, falling back to the share sheet.
  ///
  /// Sharing put the work on the reporter — find the file, pick an app, send it
  /// somewhere — so reports arrived as screen recordings with no log attached.
  /// This sends it in one tap and hands back a short code to quote.
  ///
  /// The fallback matters: the upload needs the Worker deployed AND a network,
  /// and where it can't reach (blocked networks, offline) the old behaviour is
  /// still there rather than a dead button.
  Future<void> _sendLogReport() async {
    final reporter = sl<LogReportService>();
    if (!reporter.configured) return _shareLogs();

    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(context.l10n.sendingReport)));

    final ref = await reporter.send();
    if (!mounted) return;
    messenger.clearSnackBars();
    // Windows says why the Save dialog opened instead of a "Report sent".
    if (ref == null) return _shareLogs(reportFailed: true);

    await AppDialog.show<void>(
      context,
      title: context.l10n.reportSent,
      body: Text(context.l10n.reportSentBody(ref)),
      actions: [
        // Windows: also offer the log as a file, since there is no share
        // sheet worth using there.
        if (_windowsDesktop)
          TvAlertAction(
            label: 'Save a copy',
            onTap: () {
              Navigator.of(context, rootNavigator: true).pop();
              _shareLogs();
            },
          ),
        TvAlertAction(
          label: context.l10n.copy,
          onTap: () {
            Clipboard.setData(ClipboardData(text: ref));
            Navigator.of(context, rootNavigator: true).pop();
          },
        ),
        TvAlertAction(
          label: context.l10n.ok,
          primary: true,
          autofocus: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(),
        ),
      ],
    );
  }

  /// [reportFailed]: the upload just failed, so this is the fallback.
  Future<void> _shareLogs({bool reportFailed = false}) async {
    final file = await AppLogger.instance.exportFile();
    if (!mounted) return;
    if (file == null) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(content: Text(context.l10n.couldNotExportLogs)),
        );
      return;
    }
    if (_windowsDesktop) {
      return _saveLogsOnWindows(file, reportFailed: reportFailed);
    }
    await SharePlus.instance.share(
      ShareParams(files: [XFile(file.path)], subject: 'Zangetsu logs'),
    );
  }

  /// Windows replacement for the share sheet. The native Save dialog picks
  /// where the log goes; if that dialog cannot open, a copy is kept in the
  /// app's own logs folder instead. Either way the saved file is selected in
  /// File Explorer and a snack bar names the full path.
  Future<void> _saveLogsOnWindows(
    File file, {
    bool reportFailed = false,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final name = windowsLogFileName(DateTime.now());
    String? savedPath;
    try {
      final bytes = await file.readAsBytes();
      final saved = await FilePicker.saveFile(
        // After a failed upload the dialog title is the only explanation the
        // user sees, so it says why the dialog opened.
        dialogTitle: reportFailed
            ? "Couldn't send the report: save the log to a file"
            : 'Save logs',
        fileName: name,
        bytes: bytes,
        mimeType: 'text/plain',
        // A bare typed name still gets .txt: the Windows picker takes the
        // default extension from [name]. Owned by the app window: modal and never hidden behind it.
        windowsOptions: const WindowsOptions(lockParentWindow: true),
      );
      // Null means the user cancelled the dialog: nothing to report.
      if (saved == null) return;
      savedPath = saved.toFilePath(windows: Platform.isWindows);
      // The picker writes the bytes itself; make sure they really landed so
      // the snack bar never points at a file that is not there.
      final target = File(savedPath);
      if (!await target.exists()) await target.writeAsBytes(bytes);
    } catch (e) {
      AppLogger.instance.log('Save logs dialog failed: $e');
      savedPath = await _keepLogsInAppFolder(file, name);
    }
    if (!mounted) return;
    if (savedPath == null) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(content: Text(context.l10n.couldNotExportLogs)),
        );
      return;
    }
    final path = savedPath;
    final shown = await _revealLogs(path);
    if (!mounted) return;
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          key: const ValueKey('logs-saved-snackbar'),
          duration: const Duration(seconds: 8),
          // A bounded floating toast instead of a window-wide bar.
          behavior: SnackBarBehavior.floating,
          width: 640,
          content: Text(
            '${reportFailed ? "Couldn't send the report. " : ''}'
            'Logs saved to $path'
            "${shown ? '' : ". File Explorer couldn't be opened."}",
          ),
          action: SnackBarAction(
            label: 'Show in folder',
            onPressed: () => unawaited(_revealLogs(path)),
          ),
        ),
      );
  }

  /// Fallback when the Save dialog fails: copies the log into
  /// `%APPDATA%\...\logs` (the app support folder). Null when even that fails.
  Future<String?> _keepLogsInAppFolder(File file, String name) async {
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory(
        '${support.path}${Platform.pathSeparator}logs',
      );
      await dir.create(recursive: true);
      final copy = await file.copy(
        '${dir.path}${Platform.pathSeparator}$name',
      );
      return copy.path;
    } catch (e) {
      AppLogger.instance.log('Keeping logs in the app folder failed: $e');
      return null;
    }
  }

  /// Selects the saved log in File Explorer. False when Explorer could not be
  /// opened (or the file is gone); failures are only logged.
  Future<bool> _revealLogs(String path) async {
    try {
      return await revealInExplorer(path);
    } catch (e) {
      AppLogger.instance.log('Could not open Explorer: $e');
      return false;
    }
  }

  Future<void> _pickDns() async {
    final int? picked;
    if (_isTv) {
      picked = await showDialog<int>(
        context: context,
        barrierColor: Colors.black54,
        builder: (ctx) => _TvOptionPicker<int>(
          title: ctx.l10n.dns,
          options: CsDns.labels.entries.map((e) => (e.key, e.value)).toList(),
          current: _dnsChoice,
        ),
      );
    } else {
      picked = await showModalBottomSheet<int>(
        context: context,
        backgroundColor: AppColors.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (ctx) {
          final sheetL10n = ctx.l10n;
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 12, bottom: 8),
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.textTertiary.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(sheetL10n.dns, style: AppText.headline),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(sheetL10n.dnsBlurb, style: AppText.caption),
                  ),
                ),
                const Divider(color: AppColors.hairline, height: 1),
                for (final e in CsDns.labels.entries)
                  ListTile(
                    title: Text(e.value, style: AppText.body),
                    trailing: e.key == _dnsChoice
                        ? Icon(Icons.check_rounded, color: AppColors.accent)
                        : null,
                    onTap: () => Navigator.pop(ctx, e.key),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      );
    }
    if (picked == null || picked == _dnsChoice) return;
    await CsDns.set(picked);
    if (mounted) setState(() => _dnsChoice = picked!);
  }

  /// Selects the TV keyboard presentation independently of result layout.
  Future<void> _pickTvSearchStyle() async {
    final prefs = sl<SearchPrefs>();
    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => _TvOptionPicker<String>(
        title: 'Search style',
        options: const [('classic', 'Classic'), ('new', 'New')],
        current: prefs.tvSearchStyle,
      ),
    );
    if (selected == null) return;
    await prefs.setTvSearchStyle(selected);
    if (mounted) setState(() {});
  }

  /// Picks the result layout independently of the TV keyboard style.
  Future<void> _pickSearchLayout() async {
    final prefs = sl<SearchPrefs>();
    final SearchLayout? picked;
    if (_isTv) {
      picked = await showDialog<SearchLayout>(
        context: context,
        barrierColor: Colors.black54,
        builder: (ctx) => _TvOptionPicker<SearchLayout>(
          title: ctx.l10n.searchLayout,
          options: SearchLayout.values
              .map((l) => (l, l.localizedLabel(ctx)))
              .toList(),
          current: prefs.layout,
        ),
      );
    } else if (_desktopWorkspace) {
      picked = await showGraphiteSettingsChoice<SearchLayout>(
        context,
        title: context.l10n.searchLayout,
        options: SearchLayout.values
            .map((layout) => (layout, layout.localizedLabel(context)))
            .toList(),
        current: prefs.layout,
      );
    } else {
      picked = await showModalBottomSheet<SearchLayout>(
        context: context,
        backgroundColor: AppColors.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (ctx) {
          final sheetL10n = ctx.l10n;
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 12, bottom: 8),
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.textTertiary.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      sheetL10n.searchLayout,
                      style: AppText.headline,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      sheetL10n.searchLayoutBlurb,
                      style: AppText.caption,
                    ),
                  ),
                ),
                const Divider(color: AppColors.hairline, height: 1),
                for (final l in SearchLayout.values)
                  ListTile(
                    title: Text(l.localizedLabel(ctx), style: AppText.body),
                    trailing: l == prefs.layout
                        ? Icon(Icons.check_rounded, color: AppColors.accent)
                        : null,
                    onTap: () => Navigator.pop(ctx, l),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      );
    }
    if (picked == null) return;
    await prefs.setLayout(picked);
    if (mounted) setState(() {});
  }

  Future<void> _pickBatchDownloadStyle() async {
    final prefs = sl<PlaybackPrefs>();
    final l10n = context.l10n;
    final options = <(String, String)>[
      ('classic', l10n.batchDownloadClassic),
      ('minimal', l10n.batchDownloadMinimal),
    ];
    final String? picked;
    if (_isTv) {
      picked = await showDialog<String>(
        context: context,
        barrierColor: Colors.black54,
        builder: (ctx) => _TvOptionPicker<String>(
          title: ctx.l10n.batchDownloadStyle,
          options: options,
          current: prefs.batchDownloadStyle,
        ),
      );
    } else if (_desktopWorkspace) {
      picked = await showGraphiteSettingsChoice<String>(
        context,
        title: l10n.batchDownloadStyle,
        description: l10n.batchDownloadStyleBlurb,
        options: options,
        current: prefs.batchDownloadStyle,
        optionDescriptions: {
          'classic': l10n.batchDownloadClassicBlurb,
          'minimal': l10n.batchDownloadMinimalBlurb,
        },
      );
    } else {
      picked = await showModalBottomSheet<String>(
        context: context,
        backgroundColor: AppColors.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (ctx) {
          final sheetL10n = ctx.l10n;
          final sheetOptions = <(String, String, String)>[
            (
              'classic',
              sheetL10n.batchDownloadClassic,
              sheetL10n.batchDownloadClassicBlurb,
            ),
            (
              'minimal',
              sheetL10n.batchDownloadMinimal,
              sheetL10n.batchDownloadMinimalBlurb,
            ),
          ];
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 12, bottom: 8),
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.textTertiary.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      sheetL10n.batchDownloadStyle,
                      style: AppText.headline,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      sheetL10n.batchDownloadStyleBlurb,
                      style: AppText.caption,
                    ),
                  ),
                ),
                const Divider(color: AppColors.hairline, height: 1),
                for (final o in sheetOptions)
                  ListTile(
                    title: Text(o.$2, style: AppText.body),
                    subtitle: Text(o.$3, style: AppText.caption),
                    trailing: o.$1 == prefs.batchDownloadStyle
                        ? Icon(Icons.check_rounded, color: AppColors.accent)
                        : null,
                    onTap: () => Navigator.pop(ctx, o.$1),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      );
    }
    if (picked == null) return;
    await prefs.setBatchDownloadStyle(picked);
    if (mounted) setState(() {});
  }

  /// Chooses Classic or dock-following My List and persists it without changing
  /// library records. The selected descriptive row displays an accent check.
  Future<void> _pickMyListStyle() async {
    final prefs = sl<NavPrefs>();
    final selected = _desktopWorkspace
        ? await showGraphiteSettingsChoice<String>(
            context,
            title: 'My List style',
            description:
                'Choose how your library is organized. Your saved titles and progress stay the same.',
            options: const [('classic', 'Classic'), ('new', 'New')],
            current: prefs.myListStyle,
            optionDescriptions: const {
              'classic':
                  'Switch between Streaming, Manga and Novel inside My List.',
              'new':
                  'My List follows Anime, Movie/TV, Manga or Novel selected in the dock.',
            },
          )
        : await showModalBottomSheet<String>(
            context: context,
            backgroundColor: AppColors.surface,
            constraints: const BoxConstraints(maxWidth: 640),
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            builder: (ctx) => SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    margin: const EdgeInsets.only(top: 12, bottom: 12),
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.textTertiary,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const ListTile(
                    title: Text('My List style'),
                    subtitle: Text(
                      'Choose how your library is organized. Your saved titles and progress stay the same.',
                    ),
                  ),
                  const Divider(height: 1),
                  for (final option in const [
                    (
                      'classic',
                      'Classic',
                      'Switch between Streaming, Manga and Novel inside My List.',
                    ),
                    (
                      'new',
                      'New',
                      'My List follows Anime, Movie/TV, Manga or Novel selected in the dock.',
                    ),
                  ])
                    ListTile(
                      title: Text(option.$2),
                      subtitle: Text(option.$3),
                      trailing: prefs.myListStyle == option.$1
                          ? Icon(Icons.check_rounded, color: AppColors.accent)
                          : null,
                      onTap: () => Navigator.pop(ctx, option.$1),
                    ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          );
    if (selected == null) return;
    await prefs.setMyListStyle(selected);
    if (mounted) setState(() {});
  }

  /// Which country's streaming catalogue to browse.
  ///
  /// A service's shelf differs per country, so the wrong region silently shows
  /// titles the user cannot get — which is why this is a visible setting and
  /// not only a locale guess.
  Future<void> _pickStreamingRegion() async {
    final current = StreamingPrefs.region;
    final picked = _desktopWorkspace
        ? await showGraphiteSettingsChoice<String>(
            context,
            title: context.l10n.streamingRegion,
            description: context.l10n.streamingRegionSubtitle,
            options: [for (final code in kStreamingRegions) (code, code)],
            current: current,
          )
        : await showModalBottomSheet<String>(
            context: context,
            backgroundColor: AppColors.surface,
            isScrollControlled: true,
            builder: (ctx) => SafeArea(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final code in kStreamingRegions)
                    ListTile(
                      title: Text(code, style: AppText.body),
                      trailing: code == current
                          ? Icon(Icons.check_rounded, color: AppColors.accent)
                          : null,
                      onTap: () => Navigator.pop(ctx, code),
                    ),
                ],
              ),
            ),
          );
    if (picked == null || picked == current) return;
    await StreamingPrefs.setRegion(picked);
    // The cached provider list is per region; leaving it would show the old
    // country's services under the new country's name.
    if (sl.isRegistered<StreamingProvidersService>()) {
      sl<StreamingProvidersService>().clearCache();
    }
    if (mounted) setState(() {});
  }

  /// One Settings entry for both the active viewer profile and the account.
  Widget _accountCard(BuildContext context) {
    final profiles = sl<ViewerProfileStore>();
    return BlocBuilder<AuthCubit, AuthState>(
      builder: (context, auth) => ValueListenableBuilder<ViewerProfile?>(
        valueListenable: profiles.active,
        builder: (context, active, _) {
          final profile = active ?? profiles.activeProfile;
          final accountStatus = auth.isLoggedIn
              ? (auth.user?.email ?? auth.displayName)
              : context.l10n.notSignedIn;
          if (_desktopWorkspace) {
            return DesktopSettingsProfile(
              title: context.l10n.profilesAndAccount,
              subtitle: context.l10n.watchingAsNameStatus(profile.name, accountStatus),
              onOpen: () => _push(const ViewerProfilesScreen()),
              avatar: CircleAvatar(
                radius: 22,
                backgroundColor: viewerProfileAvatarColor(profile.avatar),
                child: ProfileAvatarFace(
                  profile: profile,
                  photoUrl: profilePhotoForFace(
                    profile: profile,
                    accountPhotoUrl: auth.avatarUrl,
                  ),
                  iconSize: 22,
                  photoDiameter: 44,
                ),
              ),
            );
          }
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: SettingsCard(
              children: [
                _accountRow(
                  onTap: () => _push(const ViewerProfilesScreen()),
                  autofocus: _isTv,
                  semanticLabel: context.l10n.profilesAndAccount,
                  avatar: CircleAvatar(
                    radius: 24,
                    backgroundColor: viewerProfileAvatarColor(profile.avatar),
                    child: ProfileAvatarFace(
                      profile: profile,
                      photoUrl: profilePhotoForFace(
                        profile: profile,
                        accountPhotoUrl: auth.avatarUrl,
                      ),
                      iconSize: 24,
                      photoDiameter: 48,
                    ),
                  ),
                  title: context.l10n.profilesAndAccount,
                  subtitle: context.l10n.watchingAsNameStatus(profile.name, accountStatus),
                  trailing: const Icon(
                    Icons.chevron_right_rounded,
                    color: AppColors.textTertiary,
                    size: 20,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _accountRow({
    required VoidCallback onTap,
    required Widget avatar,
    required String title,
    required String subtitle,
    required Widget trailing,
    bool autofocus = false,
    String? semanticLabel,
  }) {
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      child: Row(
        children: [
          avatar,
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: AppText.headline.copyWith(fontSize: 16),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: AppText.caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          trailing,
        ],
      ),
    );
    if (_isTv) {
      return TvListFocusable(
        autofocus: autofocus,
        semanticLabel: semanticLabel ?? title,
        onTap: onTap,
        child: ExcludeSemantics(child: content),
      );
    }
    return InkWell(onTap: onTap, child: content);
  }

  /// A plain grey value shown at the row's trailing edge (before the chevron).
  /// Used for e.g. "Rows", "Off", "2 linked".
  Widget _value(String text) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        text,
        style: AppText.caption.copyWith(color: AppColors.textSecondary),
      ),
      const SizedBox(width: 6),
      const Icon(
        Icons.chevron_right_rounded,
        color: AppColors.textTertiary,
        size: 20,
      ),
    ],
  );

  /// Live "Search settings" field — filters every setting as you type
  /// (title, description and keyword synonyms), Samsung-style. A clear (×)
  /// button appears once there's a query.
  Widget _searchField(String query) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
    child: Container(
      decoration: BoxDecoration(
        color: AppColors.settingsCard,
        borderRadius: BorderRadius.circular(13),
      ),
      padding: const EdgeInsetsDirectional.only(start: 14, end: 4),
      child: Row(
        children: [
          const Icon(
            Icons.search_rounded,
            color: AppColors.textTertiary,
            size: 20,
          ),
          const SizedBox(width: 11),
          Expanded(
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) => _settingsCubit.setQuery(v.trim()),
              style: AppText.body.copyWith(color: AppColors.textPrimary),
              cursorColor: AppColors.accent,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                isCollapsed: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 13),
                border: InputBorder.none,
                hintText: context.l10n.settingsSearchHint,
                hintStyle: AppText.body.copyWith(color: AppColors.textTertiary),
              ),
            ),
          ),
          if (query.isNotEmpty)
            InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () {
                _searchCtrl.clear();
                _settingsCubit.setQuery('');
                DesktopFocusRepair.dropFocus(context);
              },
              child: const Padding(
                padding: EdgeInsets.all(8),
                child: Icon(
                  Icons.close_rounded,
                  color: AppColors.textSecondary,
                  size: 18,
                ),
              ),
            ),
        ],
      ),
    ),
  );

  /// Shared entry list for phone and TV. Visibility gates use [_isTv],
  /// [Platform.isAndroid], and [isAppleTv] so one catalog drives both hubs.
  List<_SettingsEntry> _buildSettingsEntries({
    required AppLocalizations l10n,
    required int enabledCount,
    required int connectedCount,
  }) => [
    // Account & sync
    _SettingsEntry(
      section: SettingsSection.account,
      icon: Icons.sync_alt_rounded,
      title: l10n.connections,
      subtitle: connectedCount > 0
          ? l10n.connectedCount(connectedCount)
          : l10n.connectionsTvSubtitle,
      keywords: l10n.connectionsTvSubtitle.toLowerCase(),
      onTap: () async {
        await _push(
          _isTv ? const ConnectionsScreenTv() : const ConnectionsScreen(),
        );
        if (mounted) setState(() {});
      },
    ),
    if (!_isTv || !isAppleTv)
      _SettingsEntry(
        section: SettingsSection.account,
        icon: Icons.gamepad_outlined,
        title: l10n.discord,
        subtitle: l10n.discordSubtitle,
        keywords: 'discord rich presence',
        onTap: () async {
          await _push(const DiscordSettingsScreen());
          if (mounted) setState(() {});
        },
      ),
    if (WatchTogetherController.isEnabled)
      _SettingsEntry(
        section: SettingsSection.account,
        icon: Icons.groups_2_outlined,
        title: l10n.watchParty,
        subtitle: l10n.watchPartySubtitle,
        keywords: 'watch party together',
        onTap: () {
          if (sl<AuthCubit>().state.user == null) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(l10n.signInToWatchTogether)));
            return;
          }
          _push(const WatchPartyLobbyScreen());
        },
      ),
    _SettingsEntry(
      section: SettingsSection.account,
      icon: Icons.cloud_upload_outlined,
      title: l10n.syncLibraryToCloud,
      subtitle: l10n.syncLibraryToCloudSubtitle,
      keywords:
          'sync cloud upload library history continue watching list device '
          'cross-device re-sync fix restore',
      onTap: () async {
        if (sl<AuthCubit>().state.user == null) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(l10n.signInFirst)));
          return;
        }
        // The session may have lapsed (logged-in from cache only). Get a live
        // one first — otherwise every upsert silently no-ops ("Synced 0").
        final live = await ensureLiveSession(context);
        if (!mounted) return;
        if (!live) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(l10n.reconnectToSyncLibrary)));
          return;
        }
        final messenger = ScaffoldMessenger.of(context);
        messenger
          ..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text(l10n.syncingLibraryToCloud)));
        // Reading progress is part of the same library as watch progress.
        // Preserve partial failures instead of treating a failed upload as an
        // empty, already-synced library, and continue with the other stores.
        final history = await uploadLibraryStores([
          sl<WatchHistory>().pushAllLocalToCloud,
          if (sl.isRegistered<ReadHistory>())
            sl<ReadHistory>().pushAllLocalToCloud,
        ]);
        final list = await uploadLibraryStores([
          sl<MyListStore>().pushAllLocalToCloud,
        ]);
        final failed = history.failed + list.failed;
        if (!mounted) return;
        messenger
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              content: Text(
                failed > 0
                    ? syncPartialFailureMessage(
                        pushed: history.pushed + list.pushed,
                        failed: failed,
                      )
                    : history.pushed == 0 && list.pushed == 0
                    ? l10n.syncLibraryAlreadySynced
                    : l10n.syncLibraryPushed(history.pushed, list.pushed),
              ),
            ),
          );
      },
    ),
    _SettingsEntry(
      section: SettingsSection.account,
      icon: Icons.cloud_sync_outlined,
      title: l10n.backupAndRestore,
      subtitle: l10n.backupAndRestoreSubtitle,
      keywords: 'backup restore export import save cloud',
      onTap: () => _push(const BackupScreen()),
    ),
    // Sources
    _SettingsEntry(
      section: SettingsSection.sources,
      icon: Icons.dns_rounded,
      title: l10n.providers,
      subtitle: l10n.providersEnabledCount(enabledCount),
      keywords:
          'providers sources extensions plugins cloudstream aniyomi repository',
      onTap: () async {
        await _push(const SourcesScreen());
        if (mounted) setState(() {});
      },
    ),
    _SettingsEntry(
      section: SettingsSection.sources,
      icon: Icons.low_priority_rounded,
      title: context.l10n.sourcePriority,
      subtitle: context.l10n.sourcePrioritySubtitle,
      keywords: 'source priority order auto resolve sweep anime movies tv',
      onTap: () => _push(const SourcePriorityScreen()),
    ),
    _SettingsEntry(
      section: SettingsSection.sources,
      icon: Icons.public_rounded,
      title: l10n.streamingRegion,
      subtitle: '${l10n.streamingRegionSubtitle} · ${StreamingPrefs.region}',
      keywords: 'streaming region country provider watch service catalogue',
      onTap: _pickStreamingRegion,
    ),
    _SettingsEntry(
      section: SettingsSection.sources,
      icon: Icons.health_and_safety_outlined,
      title: l10n.sourceHealth,
      subtitle: l10n.sourceHealthSubtitle,
      keywords: 'source health test working dead status check',
      onTap: () => _push(const SourceHealthScreen()),
    ),
    // Update notifications are an Android notification feature; auto-update
    // itself also runs on Windows (CloudStream, JS and the bundled Aniyomi
    // engine), so that row is shown there too.
    if (Platform.isAndroid)
      _SettingsEntry(
        section: SettingsSection.sources,
        icon: Icons.update_rounded,
        title: l10n.sourceUpdates,
        subtitle: l10n.sourceUpdatesSubtitle,
        keywords: 'source updates notify extensions upgrade',
        trailing: Switch.adaptive(
          value: sl<CloudStreamManager>().notifyUpdates,
          activeThumbColor: AppColors.accent,
          onChanged: (v) async {
            await sl<CloudStreamManager>().setNotifyUpdates(v);
            if (mounted) setState(() {});
          },
        ),
      ),
    if (Platform.isAndroid || _windowsDesktop)
      _SettingsEntry(
        section: SettingsSection.sources,
        icon: Icons.autorenew_rounded,
        title: l10n.autoUpdateExtensions,
        subtitle: _windowsDesktop
            ? (_updatingExtensions
                  ? 'Checking for updates now…'
                  // The daily check is started at launch by RootShell
                  // (AppLaunchChecks), whatever the Start page is.
                  : 'Updates installed extensions once a day, when Zangetsu '
                        'opens. Turning it on checks now.')
            : l10n.autoUpdateExtensionsSubtitle,
        keywords:
            'auto update extensions sources plugins automatic upgrade cloudstream aniyomi',
        trailing: Switch.adaptive(
          value: sl<PlaybackPrefs>().autoUpdateExtensions,
          activeThumbColor: AppColors.accent,
          onChanged: _updatingExtensions ? null : _setAutoUpdateExtensions,
        ),
        // The desktop row toggles on click, like every other switch row.
        onTap: _windowsDesktop && !_updatingExtensions
            ? () => _setAutoUpdateExtensions(
                !sl<PlaybackPrefs>().autoUpdateExtensions,
              )
            : null,
      ),
    // Playback & downloads
    _SettingsEntry(
      section: SettingsSection.playback,
      id: LeafParent.playback,
      icon: Icons.play_circle_outline,
      title: l10n.playback,
      subtitle: l10n.playbackSubtitle,
      // Windows has no touch gestures or decoder picker, so search must not
      // send those words to a page that does not show them.
      keywords: _windowsDesktop
          ? 'playback quality autoplay speed player audio subtitle resume seek'
          : 'playback quality autoplay speed player decoder audio subtitle '
                'resume gesture',
      // set-1: Playback is its section's only page, so Windows shows it
      // as the section itself.
      page: (_) => const PlaybackSettingsScreen(),
      onTap: () => _push(const PlaybackSettingsScreen()),
    ),
    // Manga/novel reader — phone only. TV has no reading surface.
    if (!_isTv)
      _SettingsEntry(
        section: SettingsSection.reading,
        id: LeafParent.reader,
        icon: Icons.menu_book_outlined,
        title: l10n.reader,
        subtitle: l10n.readerSubtitle,
        keywords:
            'reader manga novel reading defaults fit direction fontsize theme orientation preload',
        page: (_) => const ReaderSettingsScreen(),
        onTap: () => _push(const ReaderSettingsScreen()),
      ),
    _SettingsEntry(
      section: SettingsSection.history,
      icon: Icons.history_rounded,
      title: l10n.history,
      subtitle: l10n.historySubtitle,
      keywords: 'history watch watched continue recent resume',
      page: (_) => const HistoryScreen(),
      onTap: () async {
        await _push(const HistoryScreen());
        if (mounted) setState(() {});
      },
    ),
    _SettingsEntry(
      section: SettingsSection.downloads,
      id: LeafParent.downloads,
      icon: Icons.download_outlined,
      title: l10n.downloads,
      subtitle: _isTv ? l10n.downloadsSubtitleTv : l10n.downloadsSubtitle,
      keywords: 'downloads offline episodes save manage',
      onTap: () => _push(const DownloadsScreen()),
    ),
    _SettingsEntry(
      section: SettingsSection.downloads,
      id: LeafParent.storage,
      icon: Icons.sd_storage_outlined,
      title: l10n.storage,
      subtitle: l10n.storageSubtitle,
      keywords: 'storage space cache clear disk usage',
      onTap: () => _push(const StorageSettingsScreen()),
    ),
    // Windows: the download folder gets its own row (phone reaches it from
    // the Downloads page). Search leaves for "Choose folder…", "Reset to
    // default" and "Open in File Explorer" open this row via its id.
    if (_windowsDesktop)
      _SettingsEntry(
        section: SettingsSection.downloads,
        id: LeafParent.downloadLocation,
        icon: Icons.folder_outlined,
        title: l10n.downloadLocation,
        subtitle: 'The folder new downloads are saved in',
        keywords: 'download location folder path directory drive save',
        onTap: () => _push(const DownloadLocationScreen()),
      ),
    // This setting controls Android's torrent host and mobile-data permission.
    // Desktop uses direct video streams and has neither native capability.
    if (Platform.isAndroid)
      _SettingsEntry(
        section: SettingsSection.downloads,
        icon: Icons.downloading_outlined,
        title: l10n.torrents,
        subtitle: l10n.torrentsSubtitle,
        keywords: 'torrent magnet streaming seed data wifi',
        onTap: () => _push(const TorrentSettingsScreen()),
      ),
    // Interface & notifications
    _SettingsEntry(
      section: SettingsSection.interface,
      id: LeafParent.appearance,
      group: 'Look',
      icon: Icons.palette_outlined,
      title: 'Theme & colour',
      subtitle: 'Accent colour, dark mode and font',
      // Windows: no AMOLED/wallpaper wording; it names its own rows instead.
      keywords: _windowsDesktop
          ? 'appearance accent colour color theme highlight personalise '
                'dark pure black background font typeface animation motion '
                'adaptive title logo'
          : 'appearance accent colour color theme highlight personalise '
                'dark amoled black font type animation motion',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _value(themeAccentLabel(l10n)),
          const SizedBox(width: 10),
          Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: AppColors.accent,
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.hairline),
            ),
          ),
        ],
      ),
      onTap: () => _push(const AppearanceScreen()),
    ),
    // Windows has no launcher-icon switch and its Home has one fixed hero, so
    // only the splash picker remains there: the row is named for it.
    if (!_isTv)
      _SettingsEntry(
        section: SettingsSection.interface,
        group: 'Look',
        icon: Icons.auto_awesome_outlined,
        title: _windowsDesktop ? 'Splash screen' : 'Icon, splash & banner',
        subtitle: _windowsDesktop
            ? 'The animation that plays while Zangetsu starts'
            : 'How the app looks before you open it',
        keywords: _windowsDesktop
            ? 'splash startup launch animation bankai wordmark intro'
            : 'app icon launcher splash startup animation bankai wordmark '
                  'home banner card panels face',
        onTap: () => _push(const AppFaceScreen()),
      ),
    _SettingsEntry(
      section: SettingsSection.interface,
      group: 'Look',
      icon: Icons.view_carousel_outlined,
      title: 'Poster cards',
      subtitle: 'Shape and labels for title cards',
      keywords:
          'poster landscape portrait wide badges quality sub dub '
          'score genre age 18 progress customize cards',
      onTap: () => _push(const PosterCardSettingsScreen()),
    ),
    if (!_isTv)
      _SettingsEntry(
        section: SettingsSection.interface,
        group: 'Layout',
        // Lets the "Home rows" search leaf open this page.
        id: LeafParent.homeRows,
        icon: Icons.view_agenda_outlined,
        title: l10n.homeRows,
        subtitle: 'Which rows show on Home, and their order',
        keywords: 'home rows order hide show continue watching trending',
        onTap: () => _push(const HomeRowsScreen()),
      ),
    // Windows has a fixed sidebar instead of a dock, so the dock editor is
    // replaced by the one part of it that applies on PC: the start page.
    if (_windowsDesktop)
      _SettingsEntry(
        section: SettingsSection.interface,
        group: 'Layout',
        icon: Icons.home_outlined,
        title: 'Start page',
        subtitle: 'The page Zangetsu opens on',
        keywords:
            'start page startup launch open opens on landing default home '
            'my list sources downloads',
        trailing: _value(_desktopStartLabel()),
        onTap: _pickDesktopStartPage,
      ),
    if (!_isTv && !_windowsDesktop)
      _SettingsEntry(
        section: SettingsSection.interface,
        group: 'Layout',
        icon: Icons.dashboard_customize_outlined,
        title: 'Customize dock',
        subtitle: 'Choose buttons, reorder them and set the starting page',
        keywords:
            'navigation bar tabs dock bottom reorder hide downloads '
            'history customise customize interface',
        onTap: () => _push(const NavTabsScreen()),
      ),
    if (!_isTv)
      _SettingsEntry(
        section: SettingsSection.interface,
        group: 'Layout',
        icon: Icons.view_list_rounded,
        title: 'My List style',
        subtitle: 'Classic tabs or follow the dock media selection',
        keywords:
            'library my list classic new style dock content anime manga movie novel',
        trailing: _value(
          sl<NavPrefs>().myListStyle == 'new' ? 'New' : 'Classic',
        ),
        onTap: _pickMyListStyle,
      ),
    if (_isTv)
      _SettingsEntry(
        section: SettingsSection.interface,
        group: 'Layout',
        icon: Icons.keyboard_alt_outlined,
        title: 'Search style',
        subtitle: 'Choose Classic or New for search',
        keywords: 'tv search style keyboard classic new alphabet letters input',
        trailing: _value(
          sl<SearchPrefs>().tvSearchStyle == 'new' ? 'New' : 'Classic',
        ),
        onTap: _pickTvSearchStyle,
      ),
    _SettingsEntry(
      section: SettingsSection.interface,
      group: 'Layout',
      icon: Icons.grid_view_rounded,
      title: l10n.searchLayout,
      subtitle: 'How results from different sources line up',
      keywords: 'search layout grid list results view interface',
      trailing: _value(sl<SearchPrefs>().layout.localizedLabel(context)),
      onTap: _pickSearchLayout,
    ),
    _SettingsEntry(
      section: SettingsSection.interface,
      group: 'Layout',
      icon: Icons.download_rounded,
      title: l10n.batchDownloadStyle,
      subtitle: 'How the sheet looks when you grab a batch of episodes',
      keywords:
          'batch download style sheet minimal classic wheel episodes multi',
      trailing: _value(
        sl<PlaybackPrefs>().batchDownloadStyle == 'minimal'
            ? l10n.batchDownloadMinimal
            : l10n.batchDownloadClassic,
      ),
      onTap: _pickBatchDownloadStyle,
    ),
    _SettingsEntry(
      section: SettingsSection.interface,
      group: 'Language',
      icon: Icons.translate_rounded,
      title: l10n.titleLanguage,
      subtitle: l10n.titleLanguageSubtitle,
      keywords: 'title language romaji english native japanese anilist name',
      trailing: _value(_titleLanguageLabel(l10n)),
      onTap: () async {
        await _pickTitleLanguage();
        if (mounted) setState(() {});
      },
    ),
    // One row, both settings. Two rows opening the same sheet would lie about
    // what each opens, and the sheet is the Home wordmark's too — sharing it
    // is what keeps the two entry points from drifting apart.
    _SettingsEntry(
      section: SettingsSection.interface,
      group: 'Language',
      icon: Icons.hub_outlined,
      title: l10n.metadata,
      subtitle: _malNeedsLogin ? l10n.malLoginForLists : l10n.metadataSubtitle,
      // Every keyword both rows carried, so searching any one provider still
      // finds this.
      keywords:
          'anime manga novel metadata provider anilist mal myanimelist '
          'movie tv series tmdb simkl fallback catalogue',
      trailing: _value(
        HomeCataloguePrefs.stremioSelected
            ? 'Stremio'
            : HomeCataloguePrefs.sourceSelected
            ? 'Source Catalogue'
            : '${_animeProviderLabel()} · ${_videoProviderLabel()}',
      ),
      onTap: () async {
        final selection = await showMetadataSwitchSheet(
          context,
          sourceCatalogueSelected: HomeCataloguePrefs.sourceSelected,
          stremioCatalogueSelected: HomeCataloguePrefs.stremioSelected,
        );
        if (!mounted || selection == null) return;
        final kind = switch (selection) {
          HomeCatalogueSelection.metadata => HomeCatalogueKind.metadata,
          HomeCatalogueSelection.source => HomeCatalogueKind.source,
          HomeCatalogueSelection.stremio => HomeCatalogueKind.stremio,
        };
        await HomeCataloguePrefs.setCatalogue(
          sl<ContentModeCubit>().state,
          kind,
        );
        if (mounted) setState(() {});
      },
    ),
    _SettingsEntry(
      section: SettingsSection.interface,
      group: 'Language',
      icon: Icons.language_rounded,
      title: l10n.appLanguage,
      subtitle: l10n.appLanguageSubtitle,
      keywords: l10n.appLanguageKeywords,
      trailing: _value(appLanguageValueLabel(context)),
      onTap: () async {
        if (_isTv) {
          await pickAppLanguageTv(context);
        } else if (_windowsDesktop) {
          await _pickAppLanguageDesktop();
        } else {
          await pickAppLanguagePhone(context);
        }
        if (mounted) setState(() {});
      },
    ),
    if (Platform.isAndroid)
      _SettingsEntry(
        section: SettingsSection.notifications,
        icon: Icons.notifications_none_rounded,
        title: l10n.notifications,
        subtitle: l10n.notificationsSubtitle,
        keywords: 'notifications alerts new episode subscribe airing',
        page: (_) => const SubscriptionsScreen(),
        onTap: () => _push(const SubscriptionsScreen()),
      ),
    // Advanced
    if (Platform.isAndroid)
      _SettingsEntry(
        section: SettingsSection.advanced,
        icon: Icons.vpn_lock_outlined,
        title: l10n.dns,
        subtitle: _isTv
            ? (_dnsChoice == CsDns.off
                  ? l10n.dnsOffTvSubtitle
                  : CsDns.labelFor(_dnsChoice))
            : l10n.dnsSubtitle,
        keywords:
            'dns cloudflare google adguard quad9 isp block bypass private',
        trailing: _value(
          _dnsChoice == CsDns.off ? l10n.off : CsDns.labelFor(_dnsChoice),
        ),
        onTap: _pickDns,
      ),
    // set-7: Windows takes DNS's place here with the desktop-only window,
    // tray, start page, alerts and profile-lock settings.
    if (_windowsDesktop)
      _SettingsEntry(
        section: SettingsSection.advanced,
        id: LeafParent.windowSystem,
        icon: Icons.desktop_windows_outlined,
        title: context.l10n.windowAndSystem,
        subtitle: context.l10n.windowAndSystemSubtitle,
        keywords:
            'window system startup launch sign in boot autostart close tray '
            'minimise minimize remember size position start page open '
            'notifications alerts new episode lock idle auto-lock',
        onTap: () => _push(const WindowSystemSettingsScreen()),
      ),
    // set-8: every shortcut in one place, with player key remapping.
    if (_windowsDesktop)
      _SettingsEntry(
        section: SettingsSection.advanced,
        id: LeafParent.keyboardShortcuts,
        icon: Icons.keyboard_alt_outlined,
        title: context.l10n.keyboardShortcuts,
        subtitle: context.l10n.keyboardShortcutsSubtitle,
        keywords:
            'keyboard shortcuts keys hotkeys bindings remap customise '
            'customize player reader help',
        onTap: () => _push(const KeyboardShortcutsScreen()),
      ),
    _SettingsEntry(
      section: SettingsSection.advanced,
      id: LeafParent.privacy,
      icon: Icons.shield_outlined,
      title: l10n.privacy,
      subtitle: l10n.privacySubtitle,
      keywords: 'privacy nsfw adult content hide 18',
      onTap: () async {
        await _push(const PrivacySettingsScreen());
        if (mounted) setState(() {});
      },
    ),
    _SettingsEntry(
      section: SettingsSection.advanced,
      icon: Icons.bug_report_outlined,
      title: l10n.shareLogs,
      subtitle: l10n.shareLogsSubtitle,
      keywords: 'logs share diagnostic debug bug report crash',
      onTap: _sendLogReport,
    ),
    // About — a single destination holding the app info, contributors,
    // social links, updates, beta toggle and support (so the section opens
    // straight to it — no nested "About" sub-page).
    _SettingsEntry(
      section: SettingsSection.about,
      icon: Icons.info_outline_rounded,
      title: l10n.about,
      subtitle: 'v$kAppVersion',
      // Windows hides the prerelease opt-in, so its search drops those words.
      keywords:
          'about version app info license developers credits team '
          'contributors social discord telegram how it works guide '
          'check updates upgrade latest support donate coffee'
          '${_windowsDesktop ? ' windows github' : ' beta prerelease'}',
      page: (_) => const AboutSettingsScreen(),
      onTap: () => _push(const AboutSettingsScreen()),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final enabledCount = _registry.getAll().where((e) => e.enabled).length;
    final l10n = context.l10n;
    final connectedCount = _connectedTrackerCount;

    // Single source of truth for both the grouped list and the search filter.
    final entries = _buildSettingsEntries(
      l10n: l10n,
      enabledCount: enabledCount,
      connectedCount: connectedCount,
    );

    // Windows keeps its desktop workspace; every other non-TV platform takes
    // upstream's theme-revision-aware hub.
    if (_desktopWorkspace) {
      // Rebuild on theme changes (accent, background, pure black) so the
      // section page and its row previews repaint as soon as one is changed,
      // instead of keeping the old colours until Settings is reopened.
      return ValueListenableBuilder<int>(
        valueListenable: ThemeController.revision,
        builder: (context, _, _) => _buildDesktopWorkspace(
          _buildSettingsEntries(
            l10n: context.l10n,
            enabledCount: enabledCount,
            connectedCount: connectedCount,
          ),
        ),
      );
    }
    if (!_isTv) {
      // Screens paint AppColors directly at build time, so rebuild the hub
      // whenever the theme's mutable colours change; otherwise the section
      // you just edited keeps its old background until the app restarts.
      return ValueListenableBuilder<int>(
        valueListenable: ThemeController.revision,
        builder: (_, _, _) => _buildHub(entries),
      );
    }
    final hub = _buildHub(entries);

    // Nested navigator keeps leaf settings beside the left rail. An outer
    // PopScope owns system/TV Back (NavigatorPopHandler alone was unreliable
    // once the shell stood down on [shellBackIntercepted]).
    return PopScope(
      canPop: widget.returnToPlayer && _tvLeaves.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_tvLeaves.isNotEmpty) {
          setState(() {
            final leaf = _tvLeaves.removeLast();
            if (!leaf.done.isCompleted) leaf.done.complete();
          });
          _syncShellBackIntercept();
          return;
        }
        // Phone-style in-hub section/search (TV sections are nested pages).
        final s = _settingsCubit.state;
        if (s.openSection != null) {
          _settingsCubit.back();
          return;
        }
        if (s.query.isNotEmpty) {
          _searchCtrl.clear();
          _settingsCubit.setQuery('');
        }
      },
      child: Navigator(
        pages: [
          MaterialPage<void>(key: const ValueKey('settings-hub'), child: hub),
          for (final leaf in _tvLeaves)
            MaterialPage<void>(
              key: leaf.key,
              name: leaf.key.toString(),
              child: Builder(builder: leaf.builder),
            ),
        ],
        onDidRemovePage: (page) {
          setState(() => _removeTvLeaf(page));
          _syncShellBackIntercept();
        },
      ),
    );
  }

  /// Reference workspace owns category navigation; the nested navigator owns
  /// leaf Back actions. Switching category always returns to its root first.
  Widget _buildDesktopWorkspace(List<_SettingsEntry> entries) =>
      BlocConsumer<SettingsCubit, SettingsState>(
        bloc: _settingsCubit,
        listener: (context, state) => _syncShellBackIntercept(state: state),
        builder: (context, state) {
          final selected = _desktopSelectedSection(entries, state);
          return PopScope(
            canPop: _desktopDepth == 0 && state.query.isEmpty,
            onPopInvokedWithResult: (didPop, _) {
              // Only close what Settings owns (a page above the section, or
              // the search). At the root another PopScope on this route (the
              // shell's) blocked the pop; calling Back again from here would
              // just bounce between the two, so the shell decides (shell-1).
              if (didPop) return;
              // A retained, hidden Settings tab must not react to Back meant
              // for the page that is showing.
              if (!TickerMode.valuesOf(context).enabled) return;
              if (_desktopDepth > 0 || _settingsCubit.state.query.isNotEmpty) {
                _desktopBack();
              }
            },
            child: DesktopSettingsWorkspace(
              title: context.l10n.settingsTitle,
              selectedId: selected,
              onExit: _desktopBack,
              // set-3: one search box for every settings page.
              search: DesktopSettingsSearch(
                controller: _searchCtrl,
                focusNode: _desktopSearchFocus,
                hint: context.l10n.settingsSearchHint,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                onChanged: _onDesktopSearchChanged,
                onSubmitted: (_) => _openFirstDesktopResult(entries),
                onClear: () {
                  _searchCtrl.clear();
                  _settingsCubit.setQuery('');
                  _desktopSearchFocus.unfocus();
                },
              ),
              onSearchShortcut: _focusDesktopSearch,
              destinations: [
                for (final section in _sectionOrder)
                  if (entries.any((entry) => entry.section == section))
                    DesktopSettingsDestination(
                      id: section,
                      title: settingsSectionTitle(context.l10n, section),
                      icon: settingsSectionIcon(section),
                      onOpen: () => _openDesktopSection(section),
                    ),
              ],
              child: Navigator(
                key: _desktopNavigator,
                pages: [
                  MaterialPage<void>(
                    key: const ValueKey('desktop-settings-root'),
                    child: _desktopRoot(entries, state, selected),
                  ),
                ],
                onDidRemovePage: (_) {},
              ),
            ),
          );
        },
      );

  /// set-8: the section the sidebar shows as selected. An explicit choice
  /// wins; otherwise the section used last time (DesktopPrefs), and Account
  /// only on a first visit. A section this platform does not show (or one
  /// saved by another build) falls back too.
  String _desktopSelectedSection(
    List<_SettingsEntry> entries,
    SettingsState state,
  ) {
    bool shown(String? id) =>
        id != null && entries.any((entry) => entry.section == id);
    if (shown(state.openSection)) return state.openSection!;
    final last = DesktopPrefs.lastSettingsSection;
    if (shown(last)) return last!;
    return SettingsSection.account;
  }

  /// Sidebar click, arrow key or Ctrl+number: show [section] from its root,
  /// clear any search, and remember it for next time (set-8).
  void _openDesktopSection(String section) {
    _desktopNavigator.currentState?.popUntil((r) => r.isFirst);
    _searchCtrl.clear();
    _settingsCubit.setQuery('');
    _settingsCubit.open(section);
    _syncShellBackIntercept();
    unawaited(DesktopPrefs.setLastSettingsSection(section));
  }

  /// Typing in the sidebar search shows results in place of whatever page
  /// was open, so a page left open never hides them.
  void _onDesktopSearchChanged(String value) {
    final query = value.trim();
    if (query.isNotEmpty && _desktopDepth > 0) {
      _desktopNavigator.currentState?.popUntil((r) => r.isFirst);
    }
    _settingsCubit.setQuery(query);
  }

  /// Ctrl+F / Ctrl+K: focus the search box and select its text, so typing
  /// replaces the last search.
  void _focusDesktopSearch() {
    _desktopSearchFocus.requestFocus();
    _searchCtrl.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _searchCtrl.text.length,
    );
  }

  /// Enter in the search box opens the first result.
  void _openFirstDesktopResult(List<_SettingsEntry> entries) {
    final query = _settingsCubit.state.query.toLowerCase();
    if (query.isEmpty) return;
    final results = _desktopResultItems(entries, query);
    if (results.isEmpty) return;
    results.first.open();
  }

  /// What the nested navigator's root shows: search results while there is
  /// a query; a one-page section's page itself (set-1); otherwise the
  /// section's list of rows.
  Widget _desktopRoot(
    List<_SettingsEntry> entries,
    SettingsState state,
    String section,
  ) {
    final query = state.query.toLowerCase();
    if (query.isNotEmpty) {
      return KeyedSubtree(
        key: const ValueKey('desktop-root-search'),
        child: _desktopResultsBody(entries, query),
      );
    }
    final items = entries.where((entry) => entry.section == section).toList();
    final page = items.length == 1 ? items.single.page : null;
    if (page != null) {
      return PopScope(
        // set-1: nothing sits under this page. Its own header Back button
        // pops this (first) route, which cannot pop, so leave Settings the
        // same way the sidebar's Back does instead of doing nothing.
        key: ValueKey('desktop-root-page-$section'),
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _leaveDesktopSettings();
        },
        child: DesktopSettingsRowSeeker(child: Builder(builder: page)),
      );
    }
    return KeyedSubtree(
      key: ValueKey('desktop-root-section-$section'),
      child: _desktopSectionBody(entries, section),
    );
  }

  /// Return from real nested content or search, then exit Settings directly.
  /// Sidebar categories are peers, so they must not add a hidden Account hop.
  void _desktopBack() {
    if (widget.returnToPlayer) {
      // Opened from the player: the sidebar's Back always returns to it.
      Navigator.of(context).maybePop();
    } else if (_desktopDepth > 0) {
      _desktopNavigator.currentState?.maybePop();
    } else if (_settingsCubit.state.query.isNotEmpty) {
      _searchCtrl.clear();
      _settingsCubit.setQuery('');
    } else {
      _leaveDesktopSettings();
    }
    _syncShellBackIntercept();
  }

  /// Leaves Settings: back to the player when opened from it; otherwise
  /// through the shell's handler (shell-1: return to the previous page), and
  /// a plain route pop when the shell installed none.
  void _leaveDesktopSettings() {
    if (widget.returnToPlayer || widget.showBackButton) {
      Navigator.of(context).maybePop();
      return;
    }
    if (!DesktopSettingsNavigation.leave()) Navigator.of(context).maybePop();
  }

  /// Heading, summary and content for a Windows settings page body, capped to
  /// the shared content width (set-4) and left-aligned like Windows Settings.
  Widget _desktopPageBody({
    required Key key,
    required String title,
    String? summary,
    required List<Widget> children,
  }) {
    // A Scaffold (not a bare Material) so this page hosts snack bars: without
    // one, "Sync library", "Share logs", Start page and auto-update messages
    // were drawn on the app shell hidden behind the Settings route.
    return Scaffold(
      // The shared desktop frame colour, so Pure black and a custom
      // Background colour reach this page exactly as they reach the title bar
      // and sidebar around it.
      backgroundColor: DesktopChrome.frame,
      body: SingleChildScrollView(
        key: key,
        padding: const EdgeInsets.fromLTRB(28, 24, 28, 32),
        child: Align(
          alignment: AlignmentDirectional.topStart,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: kDesktopSettingsContentMaxWidth,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // No "Settings /" breadcrumb: the sidebar is the overview.
                Text(
                  title,
                  style: AppText.headline.copyWith(
                    fontSize: 30,
                    color: AppColors.textPrimary,
                  ),
                ),
                if (summary != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    summary,
                    style: AppText.body.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                ...children,
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Real entry callbacks are rendered in new graphite panels. No account,
  /// preference or source data is copied into presentation state.
  Widget _desktopSectionBody(List<_SettingsEntry> entries, String section) {
    final items = entries.where((entry) => entry.section == section).toList();
    final groups = <String, List<_SettingsEntry>>{};
    for (final item in items) {
      groups.putIfAbsent(item.group ?? '', () => []).add(item);
    }
    return _desktopPageBody(
      key: ValueKey('desktop-section-$section'),
      title: settingsSectionTitle(context.l10n, section),
      summary: settingsSectionSummary(context.l10n, section),
      children: [
        if (section == SettingsSection.account) ...[
          _accountCard(context),
          _desktopProfilesPanel(),
        ],
        for (final group in groups.entries) ...[
          if (group.key.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 10),
              child: Text(
                group.key,
                style: AppText.body.copyWith(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          _desktopPanel([
            for (final item in group.value)
              DesktopSettingsAction(
                title: item.title,
                subtitle: item.subtitle,
                icon: item.icon,
                trailing: item.trailing,
                onTap: item.onTap,
              ),
          ]),
          const SizedBox(height: 16),
        ],
      ],
    );
  }

  /// Search results page shown at the navigator root while there is a query.
  Widget _desktopResultsBody(List<_SettingsEntry> entries, String query) {
    final results = _desktopResultItems(entries, query);
    return _desktopPageBody(
      key: const ValueKey('desktop-settings-results'),
      title: context.l10n.searchResults,
      children: [
        if (results.isEmpty)
          Text(
            context.l10n.settingsNoMatch(_searchCtrl.text.trim()),
            style: AppText.body,
          )
        else
          _desktopPanel([
            for (final result in results)
              DesktopSettingsAction(
                title: result.title,
                subtitle: result.subtitle,
                icon: result.icon,
                trailing: result.trailing,
                onTap: result.open,
              ),
          ]),
      ],
    );
  }

  /// Panel boundaries group related actions without individual mobile cards.
  Widget _desktopPanel(List<Widget> children) =>
      GraphiteSettingsPanel(margin: EdgeInsets.zero, children: children);

  /// Quick profile switcher. The card above already opens the profile editor,
  /// so this strip switches instead: clicking an avatar goes through
  /// [ensureProfileAccess], so the profile PIN (the synced lock shared
  /// with phone and TV) is always asked first. Disabled when Settings was
  /// opened from the player, where swapping the viewer mid-playback would be wrong.
  Widget _desktopProfilesPanel() {
    final store = sl<ViewerProfileStore>();
    return ValueListenableBuilder<int>(
      valueListenable: store.revision,
      builder: (context, revision, child) =>
          ValueListenableBuilder<ViewerProfile?>(
            valueListenable: store.active,
            builder: (context, _, _) {
              final canSwitch = !widget.returnToPlayer && !_switchingProfile;
              return Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: _desktopPanel([
                  Padding(
                    padding: const EdgeInsets.all(22),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          context.l10n.switchProfile,
                          style: AppText.headline.copyWith(fontSize: 23),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          widget.returnToPlayer
                              ? context.l10n.closePlayerToSwitchProfiles
                              : context.l10n.clickProfileToWatchAs,
                          style: AppText.caption.copyWith(
                            color: AppColors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 22),
                        Wrap(
                          spacing: 16,
                          runSpacing: 16,
                          children: [
                            for (final profile in store.profiles)
                              _DesktopProfileAvatar(
                                key: ValueKey('desktop-profile-${profile.id}'),
                                profile: profile,
                                active: profile.id == store.activeId,
                                onTap: canSwitch && profile.id != store.activeId
                                    ? () => _switchDesktopProfile(profile)
                                    : null,
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ]),
              );
            },
          ),
    );
  }

  /// Same steps as the shell's profile menu: unlock, approve the switch for
  /// the synced lock, then switch. A cancelled or wrong PIN changes nothing.
  Future<void> _switchDesktopProfile(ViewerProfile profile) async {
    if (_switchingProfile) return;
    final profiles = sl<ViewerProfileStore>();
    final owner = profiles.ownerKey;
    setState(() => _switchingProfile = true);
    try {
      if (!await ensureProfileAccess(context, profile)) return;
      if (!mounted || profiles.ownerKey != owner) return;
      if (!profiles.profiles.any((p) => p.id == profile.id)) return;
      final locks = sl.isRegistered<ProfileLockStore>()
          ? sl<ProfileLockStore>()
          : null;
      if (profiles.activeId != profile.id) locks?.approveSwitch(profile.id);
      try {
        await profiles.switchTo(profile.id);
      } finally {
        locks?.consumeSwitchApproval(profile.id);
      }
    } catch (e) {
      AppLogger.instance.log('Profile switch from Settings failed: $e');
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text("Couldn't switch profile. Try again.")),
        );
      }
    } finally {
      if (mounted) setState(() => _switchingProfile = false);
    }
  }

  /// Search keeps the real indexed leaf destinations while using new rows.
  /// Words match in any order (set-3). A leaf result also names its row, so
  /// the page it opens scrolls to that row, flashes and focuses it (set-2).
  List<_DesktopResult> _desktopResultItems(
    List<_SettingsEntry> entries,
    String query,
  ) {
    final l10n = context.l10n;
    final byId = {
      for (final entry in entries)
        if (entry.id != null) entry.id!: entry,
    };
    return [
      for (final entry in entries)
        if (entry.matches(query, allWords: true))
          _DesktopResult(
            title: entry.title,
            subtitle: entry.subtitle,
            icon: entry.icon,
            trailing: entry.trailing,
            open: () => entry.onTap?.call(),
          ),
      for (final leaf in settingsLeaves)
        if (byId.containsKey(leaf.parentId) &&
            // Never offer a setting this platform's page does not render.
            leaf.isVisible &&
            leaf.matches(query, l10n, allWords: true) &&
            // Skip a leaf that only repeats its own page's row (Home rows).
            !(byId[leaf.parentId]!.title == leaf.title(l10n) &&
                byId[leaf.parentId]!.matches(query, allWords: true)))
          _DesktopResult(
            title: leaf.title(l10n),
            subtitle: byId[leaf.parentId]!.title,
            icon: byId[leaf.parentId]!.icon,
            open: () {
              // Name the row first: the page built by onTap looks for it.
              DesktopSettingsRowTargets.request(
                id: leaf.id,
                title: leaf.title(l10n),
              );
              byId[leaf.parentId]!.onTap?.call();
            },
          ),
    ];
  }

  /// Phone and other non-Windows layouts. Windows always returns the desktop
  /// workspace from build() before reaching this (set-10 removed the old
  /// Windows category-grid branches that used to live here).
  Widget _buildHub(List<_SettingsEntry> entries) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: widget.returnToPlayer
          ? AppBar(
              leading: BackButton(onPressed: () => Navigator.of(context).pop()),
              title: const Text('Back to player'),
            )
          : widget.showBackButton
          ? settingsAppBar('Settings')
          : null,
      // bottom: false — the shell's floating dock overlays the content
      // (extendBody); a full SafeArea would clip the list at the dock's top
      // edge, leaving a dead band on both sides of the capsule.
      body: SafeArea(
        bottom: false,
        child: BlocConsumer<SettingsCubit, SettingsState>(
          bloc: _settingsCubit,
          // Hide the shell's floating dock while a section sub-page is open, so
          // it reads as a full page. The shell also gates on the active tab.
          listener: (context, s) {
            _syncShellBackIntercept(state: s);
          },
          builder: (context, s) {
            final section = s.openSection;
            final query = s.query;
            final children = <Widget>[];
            if (section != null) {
              // Drill-down: a back header, then just this section's rows
              // (lead row accent-tinted).
              final items = entries.where((e) => e.section == section).toList();
              children
                ..add(_sectionHeader(section))
                ..addAll(_groupedRows(items));
            } else {
              children.add(
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    _isTv ? 56 : 20,
                    _isTv ? 24 : 12,
                    _isTv ? 48 : 20,
                    _isTv ? 16 : 14,
                  ),
                  child: _settingsWordmark(size: _isTv ? 34 : 30),
                ),
              );
              if (!_isTv) children.add(_searchField(query));
              if (query.isEmpty) {
                // Browse view: account row + one tappable row per section.
                children
                  ..add(_accountCard(context))
                  ..addAll(_categoryRows(entries));
              } else {
                // Search cuts across every section (unchanged behaviour).
                children.addAll(_buildSettingsList(entries, query));
              }
            }
            return PopScope(
              // Phone: top level with no search → back leaves Settings.
              // TV: the outer PopScope around the nested Navigator owns Back
              // (leaves + sections); this one must not also fire cubit.back().
              canPop:
                  !_isTv &&
                  (widget.returnToPlayer || (section == null && query.isEmpty)),
              onPopInvokedWithResult: (didPop, _) {
                if (didPop || _isTv) return;
                if (section != null) {
                  _settingsCubit.back();
                } else if (query.isNotEmpty) {
                  _searchCtrl.clear();
                  _settingsCubit.setQuery('');
                  DesktopFocusRepair.dropFocus(context);
                }
              },
              // Slide the drill-down in like a real pushed page (matching the
              // native transition you get opening e.g. Providers). Keyed by
              // which "page" is showing so the switcher animates category↔section
              // but NOT search-as-you-type (both are the same '_root' key).
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 280),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(1, 0),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                ),
                child: CustomScrollView(
                  key: ValueKey(section ?? '_root'),
                  slivers: [
                    SliverPadding(
                      // Bottom: clear the floating dock (its height arrives as
                      // MediaQuery bottom padding thanks to extendBody).
                      padding: EdgeInsets.only(
                        bottom: 24 + MediaQuery.paddingOf(context).bottom,
                      ),
                      sliver: SliverList.list(children: children),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  static const _sectionOrder = SettingsSection.order;

  /// Renders [entries] grouped by section. When there's a query, only matching
  /// entries survive; sections that end up empty are dropped, and an empty
  /// result shows a "no matches" line.
  List<Widget> _buildSettingsList(List<_SettingsEntry> entries, String query) {
    final q = query.toLowerCase();
    final out = <Widget>[];
    var first = true;
    // Settings that live inside a sub-page aren't in [entries], so a search
    // could only ever return the category row. Each leaf names its category by
    // id; that row supplies the icon and the tap, so a hit opens the page
    // holding the setting. Leaf titles come from l10n, so they match and read
    // in the same language as the rest of the results.
    final l10n = context.l10n;
    final byId = {
      for (final e in entries)
        if (e.id != null) e.id!: e,
    };
    final leaves = q.isEmpty
        ? const <SettingsLeaf>[]
        : settingsLeaves
              .where(
                (l) =>
                    l.isVisible &&
                    l.matches(q, l10n) &&
                    byId.containsKey(l.parentId),
              )
              .toList();
    for (final section in _sectionOrder) {
      final items = entries
          .where((e) => e.section == section && (q.isEmpty || e.matches(q)))
          .toList();
      final hits = leaves
          .where((l) => byId[l.parentId]!.section == section)
          .toList();
      if (items.isEmpty && hits.isEmpty) continue;
      out.add(
        SettingsSectionLabel(
          settingsSectionTitle(context.l10n, section),
          first: first,
        ),
      );
      first = false;
      out.add(
        SettingsCard(
          children: [
            for (var i = 0; i < items.length; i++)
              items[i].toTile(iconAccent: i == 0),
            for (var i = 0; i < hits.length; i++)
              _leafTile(
                hits[i],
                byId[hits[i].parentId]!,
                l10n,
                iconAccent: items.isEmpty && i == 0,
              ),
          ],
        ),
      );
    }
    if (out.isEmpty) {
      out.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 40, 22, 40),
          child: Center(
            child: Text(
              context.l10n.settingsNoMatch(_searchCtrl.text),
              style: AppText.body.copyWith(color: AppColors.textTertiary),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    return out;
  }

  /// A search hit for a setting one level down. Reads as the setting itself
  /// with its category beneath, and opens the page that owns it — we can't
  /// scroll a sub-page to a specific row, so landing on the right page is the
  /// useful part.
  Widget _leafTile(
    SettingsLeaf leaf,
    _SettingsEntry parent,
    AppLocalizations l10n, {
    bool iconAccent = false,
  }) => SettingsTile(
    icon: parent.icon,
    title: leaf.title(l10n),
    subtitle: parent.title,
    onTap: parent.onTap,
    iconAccent: iconAccent,
  );

  /// One tappable row per section (browse view). Each drills into the section's
  /// sub-page. Built from the same [entries], so counts/conditionals stay in
  /// sync — an empty section (e.g. all-Android entries on iOS) is skipped.
  List<Widget> _categoryRows(List<_SettingsEntry> entries) {
    final tiles = <Widget>[];
    for (final section in _sectionOrder) {
      final items = entries.where((e) => e.section == section).toList();
      if (items.isEmpty) continue;
      tiles.add(
        SettingsTile(
          icon: settingsSectionIcon(section),
          title: settingsSectionTitle(context.l10n, section),
          subtitle: settingsSectionSummary(context.l10n, section),
          iconAccent: tiles.isEmpty, // accent the lead row
          // A section with a single destination (Playback, History,
          // Notifications) opens it directly — no redundant one-row sub-page.
          // Multi-item sections: phone uses in-hub drill-down; TV pushes a
          // section page so the transition matches Playback.
          onTap: items.length == 1
              ? items.first.onTap
              : () {
                  if (_isTv) {
                    final id = section;
                    _pushBuilder((ctx) => _tvSectionPage(ctx, id));
                  } else {
                    _settingsCubit.open(section);
                  }
                },
        ),
      );
    }
    return [SettingsCard(children: tiles)];
  }

  /// A section's rows, split into cards under their [_SettingsEntry.group]
  /// headings. A section whose rows carry no group renders as one card, which
  /// is what every section did before groups existed.
  List<Widget> _groupedRows(List<_SettingsEntry> items) {
    if (items.every((e) => e.group == null)) {
      return [
        SettingsCard(
          children: [
            for (var i = 0; i < items.length; i++)
              items[i].toTile(iconAccent: i == 0, autofocus: _isTv && i == 0),
          ],
        ),
      ];
    }
    final out = <Widget>[];
    String? current;
    var block = <_SettingsEntry>[];
    var first = true;

    void flush() {
      if (block.isEmpty) return;
      if (current != null) {
        out.add(SettingsSectionLabel(current, first: first));
      }
      out.add(
        SettingsCard(
          children: [
            for (var i = 0; i < block.length; i++)
              block[i].toTile(
                iconAccent: first && i == 0,
                autofocus: _isTv && first && i == 0,
              ),
          ],
        ),
      );
      first = false;
      block = <_SettingsEntry>[];
    }

    for (final e in items) {
      if (e.group != current) {
        flush();
        current = e.group;
      }
      block.add(e);
    }
    flush();
    return out;
  }

  /// Compact app-bar-style header for a section sub-page: a small back chevron
  /// + an 18px title with a hairline underneath (replaces the oversized title).
  /// On TV, a D-pad Back control pops the section via [SettingsCubit.back].
  Widget _sectionHeader(String section) => Padding(
    padding: EdgeInsets.fromLTRB(_isTv ? 16 : 6, _isTv ? 8 : 4, 16, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (_isTv)
              // Pop the section via cubit — don't Navigator.pop (that used to
              // bubble to the TV shell and leave the Settings tab entirely).
              TvFocusable(
                semanticLabel: 'Back',
                onTap: _settingsCubit.back,
                child: ExcludeSemantics(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.arrow_back_rounded,
                          color: AppColors.textPrimary,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Back',
                          style: AppText.body.copyWith(
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            else
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(
                  Icons.arrow_back_ios_new_rounded,
                  color: AppColors.textPrimary,
                  size: 18,
                ),
                onPressed: _settingsCubit.back,
              ),
            SizedBox(width: _isTv ? 12 : 2),
            Expanded(
              child: Text(
                settingsSectionTitle(context.l10n, section),
                style: AppText.headline.copyWith(
                  fontSize: _isTv ? 22 : 18,
                  fontWeight: FontWeight.w700,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        const Divider(height: 1, thickness: 1, color: AppColors.hairline),
        const SizedBox(height: 14),
      ],
    ),
  );

  Widget _settingsWordmark({required double size}) {
    return Text.rich(
      TextSpan(
        style: TextStyle(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w700,
          fontSize: size,
          letterSpacing: -0.5,
        ),
        children: [
          TextSpan(text: context.l10n.settingsTitle),
          TextSpan(
            text: '.',
            style: TextStyle(color: AppColors.accent),
          ),
        ],
      ),
    );
  }
}

/// One avatar in the Windows "Switch profile" strip. The active profile gets
/// an accent ring and a "Watching" caption; the others show a hand cursor and
/// a hover ring, and are keyboard-focusable.
class _DesktopProfileAvatar extends StatefulWidget {
  const _DesktopProfileAvatar({
    super.key,
    required this.profile,
    required this.active,
    required this.onTap,
  });

  final ViewerProfile profile;
  final bool active;

  /// Null when the profile cannot be switched to (already active, a switch is
  /// running, or Settings was opened from the player).
  final VoidCallback? onTap;

  @override
  State<_DesktopProfileAvatar> createState() => _DesktopProfileAvatarState();
}

class _DesktopProfileAvatarState extends State<_DesktopProfileAvatar> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final ring = widget.active
        ? AppColors.accent
        : _hovered && widget.onTap != null
        ? AppColors.textSecondary
        : Colors.transparent;
    return Semantics(
      button: widget.onTap != null,
      selected: widget.active,
      label: widget.active
          ? '${widget.profile.name}, watching now'
          : 'Switch to ${widget.profile.name}',
      child: ExcludeSemantics(
        child: InkWell(
          onTap: widget.onTap,
          onHover: (v) => setState(() => _hovered = v),
          borderRadius: BorderRadius.circular(14),
          mouseCursor: widget.onTap == null
              ? SystemMouseCursors.basic
              : SystemMouseCursors.click,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: SizedBox(
              width: 92,
              child: Column(
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 140),
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: ring, width: 2),
                    ),
                    child: CircleAvatar(
                      radius: 32,
                      backgroundColor: viewerProfileAvatarColor(
                        widget.profile.avatar,
                      ),
                      child: ProfileAvatarFace(
                        profile: widget.profile,
                        iconSize: 32,
                        photoDiameter: 64,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    widget.profile.name,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption.copyWith(
                      color: widget.active
                          ? AppColors.textPrimary
                          : AppColors.textSecondary,
                      fontWeight: widget.active
                          ? FontWeight.w700
                          : FontWeight.w500,
                    ),
                  ),
                  if (widget.active)
                    Text(
                      'Watching',
                      style: AppText.caption.copyWith(
                        color: AppColors.accent,
                        fontSize: 11,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A TV leaf route stacked on the nested Settings navigator, with a [done]
/// future completed when the page is popped (so `await _push(...)` still works).
class _TvSettingsLeaf {
  _TvSettingsLeaf({
    required this.key,
    required this.builder,
    required this.done,
  });

  final LocalKey key;
  final Widget Function(BuildContext context) builder;
  final Completer<void> done;
}

/// One searchable settings row — the single source of truth for both the
/// grouped list and the "Search settings" filter.
class _SettingsEntry {
  const _SettingsEntry({
    required this.section,
    required this.icon,
    required this.title,
    this.id,
    this.subtitle,
    this.keywords = '',
    this.trailing,
    this.onTap,
    this.group,
    this.page,
  });

  final String section;

  /// set-1: the page [onTap] opens, for rows that are their section's only
  /// destination. The Windows workspace then shows this page as the section
  /// itself, so Back never lands on a one-row list underneath it.
  final WidgetBuilder? page;

  /// Optional heading this row sits under inside its section's page. Purely
  /// presentational: rows with no group render exactly as they always have,
  /// in one card, and nothing about what a row DOES depends on this.
  final String? group;

  /// Stable [LeafParent] id, set only on rows whose sub-page holds settings
  /// listed in [settingsLeaves]. Titles are translated, so search results can't
  /// find their category row by name.
  final String? id;
  final IconData icon;
  final String title;
  final String? subtitle;

  /// Extra search terms (synonyms) that never render but widen matches.
  final String keywords;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// [q] is already lower-cased by the caller. [allWords] (Windows): every
  /// word of [q] must appear, in any order.
  bool matches(String q, {bool allWords = false}) => settingsQueryMatches(
    '$title ${subtitle ?? ''} $keywords $section',
    q,
    allWords: allWords,
  );

  SettingsTile toTile({bool iconAccent = false, bool autofocus = false}) =>
      SettingsTile(
        icon: icon,
        title: title,
        subtitle: subtitle,
        trailing: trailing,
        onTap: onTap,
        iconAccent: iconAccent,
        autofocus: autofocus,
      );
}

/// One Windows settings search result: what the row shows and what opening
/// it does (Enter in the search box opens the first one).
class _DesktopResult {
  const _DesktopResult({
    required this.title,
    required this.icon,
    required this.open,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final IconData icon;
  final Widget? trailing;
  final VoidCallback open;
}
