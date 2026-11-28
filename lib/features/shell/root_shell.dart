import 'desktop_sidebar_pages.dart';
import 'desktop_sync_indicator.dart';
import '../../core/desktop/desktop_focus_repair.dart';
import '../../core/desktop/desktop_history_opener.dart';
import '../../core/desktop/desktop_media_selector.dart';
import '../../core/desktop/desktop_settings_opener.dart';
import '../../core/desktop/desktop_shortcuts.dart';
import '../../core/desktop/desktop_window.dart';
import '../../core/notify/new_episode_inbox.dart';
// dl-11: the notification-click hook for the Downloads page.
import '../../core/notify/notification_router.dart'
    show openDownloadsFromNotification;
import '../../core/ui/global_messenger.dart';
import '../settings/keyboard_shortcuts_screen.dart'
    show showKeyboardShortcutsHelp;
import '../home/lists_hub_screen.dart';
import '../home/genres_screen.dart';
import '../settings/streaming_services_screen.dart';
import '../notify/subscriptions_screen.dart';
import 'dart:async';
import 'desktop_shell_workspace.dart';
import 'desktop_top_bar_avatar.dart';
import '../../core/theme/theme_controller.dart';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show SystemNavigator;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../search/browse_sources_screen.dart';
import '../home/home_catalogue_prefs.dart';
import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/playback/my_list.dart';
import '../../core/playback/category_store.dart';
import '../../core/playback/series_groups.dart';
import '../../core/playback/watch_history.dart';
import '../../core/profiles/viewer_profile.dart';
import '../../core/profiles/viewer_profile_avatar.dart';
import '../../core/profiles/profile_shell_scope.dart';
import '../../core/profiles/profile_lock_store.dart';
import '../../core/reading/read_history.dart';
import '../../core/mode/content_mode.dart';
import '../../core/mode/content_mode_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/ui/liquid_nav_glass.dart';
import '../../core/zmode/zmode_prefs.dart';
import '../../l10n/ui_strings.dart';
import '../../l10n/l10n.dart';
import '../../core/ui/nav_prefs.dart';
import '../../core/ui/adaptive_layout.dart';
import '../../core/ui/frosted_surface.dart';
import '../downloads/downloads_screen.dart';
import '../history/history_screen.dart';
import '../player/desktop_floating_player.dart';
import '../profiles/profile_lock_gate.dart';
import '../profiles/profile_unlock.dart' show ensureProfileAccess;
import '../profiles/viewer_profiles_screen.dart';
import '../profiles/viewer_profile_home_screen.dart';
import '../auth/auth_cubit.dart';
import '../home/cubit/home_cubit.dart';
import '../home/home_screen.dart';
import '../home/my_list_screen.dart';
import '../home/search_screen.dart';
import '../settings/settings_screen.dart';
import 'dock_icons.dart';
import 'mode_bar.dart';
import '../../core/ui/dock_visibility.dart';
import 'root_shell_tv.dart';

/// Main pages for [RootShellTv]'s navigation rail.
///
/// [searchFocusSignal] is bumped each time the Search rail item is
/// (re)selected on TV so the embedded search screen can auto-focus its
/// field.
///
/// [searchFixedSourceId] pins the Search page to one source catalogue. TV
/// leaves it null; the phone dock passes [dockSearchFixedSourceId].
List<Widget> buildShellPages(
  ValueNotifier<int>? searchFocusSignal, {
  bool homeIsActive = true,
  bool deferHomeStartupPrompts = false,
  String? searchFixedSourceId,
}) => [
  HomeScreen(
    isTabActive: homeIsActive,
    deferStartupPrompts: deferHomeStartupPrompts,
  ),
  SearchScreen(
    showBack: false,
    focusSignal: searchFocusSignal,
    fixedSourceId: searchFixedSourceId,
  ),
  const MyListScreen(),
  const SettingsScreen(),
];

/// What the phone dock's Search tab searches: the source catalogue Home is
/// showing in the given mode (e.g. AniKoto), or null for metadata search —
/// the same `fixedSourceId` the Home header icon passes.
///
/// Pure read of [HomeCataloguePrefs] so the mapping is unit-testable (pass
/// [mode] explicitly); the shell passes nothing and the current cubit mode
/// applies. The caller re-reads it on every rebuild (each tab switch), and
/// [SearchScreen] recreates its bloc on scope change, so the tab follows
/// catalogue picks with no extra plumbing.
String? dockSearchFixedSourceId([ContentMode? mode]) {
  if (!HomeCataloguePrefs.catalogueShown) return null;
  final m =
      mode ??
      (sl.isRegistered<ContentModeCubit>()
          ? sl<ContentModeCubit>().state
          : null);
  if (m == null) return HomeCataloguePrefs.sourceId;
  return HomeCataloguePrefs.sourceIdFor(m);
}

/// Whether the shell keeps Home mounted even while another dock tab or an
/// in-frame page (History, Settings, ...) is showing. True on Windows when
/// Home is one of the dock tabs: Home publishes the catalogue choices of the
/// shell pill's catalogue picker and clears them when disposed, so it must
/// stay mounted for the picker to show on every screen. Phones (false) keep
/// mounting Home only when it is visited. Pure, so the rule is unit-testable.
bool desktopKeepsHomeMounted({
  required bool windowsUi,
  required List<DockTab> tabs,
}) => windowsUi && tabs.contains(DockTab.home);

/// App-level navigation shell — a reorderable dock (3-5 tabs, [NavPrefs])
/// via a custom floating capsule (frosted, hovering over the content; no
/// Material NavigationBar).
///
/// Uses [IndexedStack] so each screen preserves its scroll/state when
/// the user switches tabs.
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell>
    with SingleTickerProviderStateMixin {
  /// The tab showing, by identity. Was an int index into a hardcoded five —
  /// which stopped meaning anything once the dock became reorderable.
  ///
  /// Starts wherever the user chose to land; [NavPrefs.startTab] falls back to
  /// the leftmost tab, so an untouched install still opens on Home.
  late final _selectedTab = ValueNotifier(_navPrefs.startTab);
  DockTab get _tab => _selectedTab.value;
  final _visitedTabs = <DockTab>{};
  String? _visitedTabsProfileId;

  /// Extra Windows destinations do not alter the shared mobile dock schema.
  String? _desktopPage;

  /// Shows the in-frame Windows page [page] (Schedule, Genres, History, ...)
  /// over the current tab.
  void _selectDesktopPage(String page) {
    if (_desktopPage == page) return;
    _lastBackPress = null;
    setState(() => _desktopPage = page);
    _repairFocusAfterSwitch();
  }

  /// R1: after a tab / page switch the hidden page's focus is dropped and
  /// the new page's autofocus does not fire again, so give the keys to the
  /// newly shown page once it is laid out (Windows UI only).
  void _repairFocusAfterSwitch() {
    if (!_windowsUi) return;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => DesktopFocusRepair.run(),
    );
  }

  /// Windows UI (not TV). Gated on [defaultTargetPlatform] so widget tests
  /// can switch it on and phones never see it.
  bool get _windowsUi => defaultTargetPlatform == TargetPlatform.windows;

  /// True while the full-page Settings route opened by
  /// [_openDesktopSettings] is on the navigator, so a second click or
  /// Ctrl+, never stacks another Settings page on top of it.
  bool _settingsRouteOpen = false;

  /// acct-3: brings the shell back on screen and opens Profile, where the
  /// user signs in. Called from the title-bar sync icon.
  void _openProfileForSignIn() {
    if (!mounted) return;
    final route = ModalRoute.of(context);
    // Close pages pushed over the shell so Profile is actually visible.
    if (route != null && !route.isCurrent) {
      Navigator.of(context).popUntil((r) => r == route);
    }
    _onTabSelected(DockTab.profile);
  }

  /// Opens Settings as a full page pushed over the whole shell, so it covers
  /// the left rail and the top bar (the title bar stays: it sits above the
  /// navigator). Back (its button, Esc, Alt+Left, mouse Back) pops the page
  /// and shows exactly the tab / page underneath, e.g. Home.
  ///
  /// Installed as [DesktopSettingsOpener.handler] so the Profile page's
  /// Settings button and Ctrl+, both open it the same way (Settings is not
  /// on the rail).
  void _openDesktopSettings() {
    if (!mounted || _settingsRouteOpen) return;
    _settingsRouteOpen = true;
    _lastBackPress = null;
    unawaited(
      Navigator.of(context)
          .push<void>(
            MaterialPageRoute<void>(
              // showBackButton: Settings' Back pops this route instead of
              // asking the shell to swap an in-frame page.
              builder: (_) => const SettingsScreen(showBackButton: true),
            ),
          )
          .whenComplete(() {
            // The page closed: allow opening it again, and give the keys
            // back to the page that is showing again (R1).
            _settingsRouteOpen = false;
            if (mounted) _repairFocusAfterSwitch();
          }),
    );
  }

  /// Opens the in-frame History page (Ctrl+H, and the Profile page button
  /// through [DesktopHistoryOpener.handler]); History left the rail.
  void _openDesktopHistory() => _selectDesktopPage('history');

  /// shell-7: the top-bar search box, focused by Ctrl+F and '/'.
  final FocusNode _desktopSearchFocus = FocusNode(
    debugLabel: 'desktop-shell-search',
  );
  final TextEditingController _desktopSearchCtrl = TextEditingController();

  /// shell-9: query of the in-frame search page, and a counter so
  /// submitting the same text again runs a fresh search.
  String? _desktopSearchQuery;
  int _desktopSearchSerial = 0;

  /// shell-9: top-bar search opens results in the frame, like Schedule.
  void _openDesktopSearch(String query) {
    final q = query.trim();
    if (q.isEmpty) return;
    setState(() {
      _desktopSearchQuery = q;
      _desktopSearchSerial++;
    });
    _selectDesktopPage('search');
  }

  /// True while this shell's route is the one on screen, so app shortcuts
  /// never act behind a pushed page, dialog or the player.
  bool get _shellOnTop =>
      mounted && (ModalRoute.of(context)?.isCurrent ?? true);

  /// Rail destinations in rail order, for Ctrl+1..N (shell-7): the primary
  /// tabs, then the extra shortcuts (Streaming, Schedule, Genres, Downloads).
  List<VoidCallback> _desktopSections() => [
    for (final entry in desktopRailTabs) () => _onTabSelected(entry.$1),
    for (final shortcut in _desktopShortcuts()) shortcut.onTap,
  ];

  /// shell-7: focuses the top-bar search and selects its text.
  void _focusDesktopSearch() {
    _desktopSearchFocus.requestFocus();
    _desktopSearchCtrl.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _desktopSearchCtrl.text.length,
    );
  }

  /// shell-7: app-scope keyboard actions handed to DesktopWindow. Pages
  /// with their own Ctrl+F / Ctrl+number handlers sit deeper in the focus
  /// tree and win; these only run while the shell is the page on screen.
  Map<String, VoidCallback> _desktopAppActions() {
    void onShell(VoidCallback action) {
      if (_shellOnTop) action();
    }

    return {
      'app.search': () => onShell(_focusDesktopSearch),
      for (var i = 1; i <= 9; i++)
        'app.section$i': () => onShell(() {
          final sections = _desktopSections();
          if (i <= sections.length) sections[i - 1]();
        }),
      for (var i = 1; i <= modeChoices.length && i <= 4; i++)
        'app.mode$i': () => onShell(
          () => unawaited(DesktopMediaSelector.select(modeChoices[i - 1])),
        ),
      'app.settings': () => onShell(_openDesktopSettings),
      // Ctrl+H: History opens in the frame now that it left the rail.
      'app.history': () => onShell(_openDesktopHistory),
      // acct-11: 'app.lockProfile' (Ctrl+L) is deliberately not bound here.
      // DesktopProfileRelock handles and consumes it through a
      // HardwareKeyboard handler; menus call DesktopProfileRelock.lockNow().
      // The help overlay works over any page.
      'app.help': () {
        final overlayContext = rootNavigatorKey.currentContext ?? context;
        unawaited(
          showKeyboardShortcutsHelp(
            overlayContext,
            scope: DesktopShortcutScope.app,
          ),
        );
      },
    };
  }

  /// Whether the floating mode bar (Anime / Movie/TV / Manga / Novel) is
  /// showing above the dock. Z Mode only — the centre button that toggles it
  /// doesn't exist otherwise.
  bool _modeBarOpen = false;

  /// Falls back to an unregistered instance rather than throwing.
  ///
  /// Production always registers it; widget tests build this shell with only
  /// the deps they care about. A bare [NavPrefs] reads no Hive box and returns
  /// [NavPrefs.defaultTabs], which is the dock those tests expect anyway —
  /// same guard the bloc uses for ContentModeCubit.
  late final NavPrefs _navPrefs = sl.isRegistered<NavPrefs>()
      ? sl<NavPrefs>()
      : NavPrefs();

  /// Cached for the scroll callback: don't read local storage during scrolling.
  late bool _keepDockExpanded = _navPrefs.keepDockExpanded;

  /// Double-back-to-exit: timestamp of the last root Back press. A second Back
  /// within 2s exits the app; the first just shows the "press back again" toast.
  DateTime? _lastBackPress;
  DateTime? _lastProfileTap;
  bool _deferTabsForPicker = false;
  late final _homePage = HomeScreen(activeDockTab: _selectedTab);
  late final _deferredHomePage = HomeScreen(
    activeDockTab: _selectedTab,
    deferStartupPrompts: true,
  );
  late final _profilePage = ViewerProfileHomeScreen(
    onProfileSelected: () {
      setState(() => _deferTabsForPicker = true);
      _onTabSelected(DockTab.home);
    },
    onPickerClosed: () {
      if (mounted && _deferTabsForPicker) {
        setState(() => _deferTabsForPicker = false);
      }
    },
  );
  SearchScreen _searchPage = const SearchScreen(showBack: false);

  /// Tab-switch entrance: the visible page swaps immediately and the INCOMING
  /// tab fades + slides up into place (200ms, ease-out). We never fade the old
  /// tab out to blank — that midpoint blank frame read as a stutter. The
  /// [IndexedStack] stays alive, so every tab keeps its scroll position and
  /// nothing is rebuilt during the animation (the page is a cached layer).
  late final AnimationController _switchCtrl;
  late final Animation<double> _switch;

  @override
  void initState() {
    super.initState();
    _switchCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      value: 1,
    );
    _switch = CurvedAnimation(parent: _switchCtrl, curve: Curves.easeOutCubic);
    _navPrefs.addListener(_onTabsChanged);
    ZModePrefs.revision.addListener(_onZMode);
    if (_windowsUi && !(sl.isRegistered<AppMode>() && sl<AppMode>().isTv)) {
      // shell-7: app-wide shortcuts.
      DesktopWindow.setAppActions(_desktopAppActions());
      // Profile page buttons: Settings opens as a full page over the shell,
      // History in the frame.
      DesktopSettingsOpener.handler = _openDesktopSettings;
      DesktopHistoryOpener.handler = _openDesktopHistory;
      // acct-3: the title-bar sync icon opens Profile when sign-in is needed.
      DesktopSyncIndicator.signInHandler = _openProfileForSignIn;
      // dl-11: a click on a download batch notification opens Downloads.
      openDownloadsFromNotification = _openDownloadsFromNotification;
    }
    if (sl.isRegistered<ViewerProfileStore>()) {
      sl<ViewerProfileStore>().active.addListener(_onProfileChanged);
      sl<ViewerProfileStore>().contextRevision.addListener(
        _onProfileContextChanged,
      );
    }
  }

  void _onProfileChanged() {
    if (!mounted || (sl.isRegistered<AppMode>() && sl<AppMode>().isTv)) return;
    setState(() {});
  }

  void _onProfileContextChanged() {
    // RootShellTv owns these listeners when the TV shell is active.
    if (!mounted || (sl.isRegistered<AppMode>() && sl<AppMode>().isTv)) return;
    final profileId = sl<ViewerProfileStore>().activeId;
    if (sl.isRegistered<HomeCubit>()) {
      unawaited(sl<HomeCubit>().reloadAfterProfileChange());
    }
    unawaited(_syncProfile(profileId));
  }

  Future<void> _syncProfile(String profileId) async {
    if (!sl.isRegistered<MyListStore>() ||
        !sl.isRegistered<WatchHistory>() ||
        !sl.isRegistered<ReadHistory>() ||
        !sl.isRegistered<CategoryStore>() ||
        !sl.isRegistered<SeriesGroupStore>()) {
      return;
    }
    try {
      await Future.wait([
        sl<MyListStore>().seedCloudIfNeeded(),
        sl<WatchHistory>().seedCloudIfNeeded(),
        sl<ReadHistory>().seedCloudIfNeeded(),
      ]).timeout(const Duration(seconds: 8));
      if (!mounted || sl<ViewerProfileStore>().activeId != profileId) return;
      await Future.wait([
        sl<MyListStore>().pullFromCloud(forProfileId: profileId),
        sl<WatchHistory>().pullFromCloud(forProfileId: profileId),
        sl<ReadHistory>().pullFromCloud(forProfileId: profileId),
        sl<CategoryStore>().pullFromCloud(),
        sl<SeriesGroupStore>().pullFromCloud(),
      ]).timeout(const Duration(seconds: 8));
      if (mounted && sl<ViewerProfileStore>().activeId == profileId) {
        sl<HomeCubit>().relayout();
      }
    } catch (_) {
      // Keep the already-available local profile usable when cloud sync fails.
    }
  }

  /// The toggle changed: close the mode bar and, as a safety net, bounce off
  /// any tab that somehow stopped being visible.
  void _onZMode() {
    if (!mounted) return;
    // TV returns [RootShellTv] from [build], but this State is still the
    // parent. setState here rebuilds every tab (two 10-foot Homes + Search +
    // Schedule) and freezes the UI for seconds even on a HomeCubit cache hit.
    if (sl.isRegistered<AppMode>() && sl<AppMode>().isTv) return;
    setState(() {
      _modeBarOpen = false;
      final visible = _visibleTabs();
      if (!visible.contains(_tab)) _selectedTab.value = visible.first;
    });
  }

  /// The dock was edited in Settings. If the tab we're on just got hidden,
  /// land somewhere that still exists instead of showing a page with no item.
  void _onTabsChanged() {
    if (!mounted) return;
    final keepDockExpanded = _navPrefs.keepDockExpanded;
    if (keepDockExpanded != _keepDockExpanded) {
      _keepDockExpanded = keepDockExpanded;
      DockScrollCollapse.reset();
    }
    final visible = _visibleTabs();
    setState(() {
      if (!visible.contains(_tab)) _selectedTab.value = visible.first;
    });
  }

  /// The dock as actually rendered. Every tab suits every content mode now
  /// that Schedule lives on Home instead (see `_scheduleCard` there), so this
  /// is just the user's order. The Windows rail always carries every tab.
  List<DockTab> _visibleTabs() => _windowsUi ? DockTab.values : _navPrefs.tabs;

  @override
  void dispose() {
    _navPrefs.removeListener(_onTabsChanged);
    ZModePrefs.revision.removeListener(_onZMode);
    if (sl.isRegistered<ViewerProfileStore>()) {
      sl<ViewerProfileStore>().active.removeListener(_onProfileChanged);
      sl<ViewerProfileStore>().contextRevision.removeListener(
        _onProfileContextChanged,
      );
    }
    _switchCtrl.dispose();
    _selectedTab.dispose();
    // Only remove the Windows hooks this shell installed.
    // The Settings opener doubles as the "this shell installed the Windows
    // hooks" marker, so the app actions are cleared with it.
    if (DesktopSettingsOpener.handler == _openDesktopSettings) {
      DesktopSettingsOpener.handler = null;
      DesktopWindow.setAppActions(null);
    }
    if (DesktopHistoryOpener.handler == _openDesktopHistory) {
      DesktopHistoryOpener.handler = null;
    }
    if (DesktopSyncIndicator.signInHandler == _openProfileForSignIn) {
      DesktopSyncIndicator.signInHandler = null;
    }
    if (openDownloadsFromNotification == _openDownloadsFromNotification) {
      openDownloadsFromNotification = null;
    }
    _desktopSearchFocus.dispose();
    _desktopSearchCtrl.dispose();
    super.dispose();
  }

  /// Windows (dl-11): a download notification was clicked. Close whatever is
  /// pushed over the shell (detail pages, dialogs) and show the Downloads tab.
  void _openDownloadsFromNotification() {
    if (!mounted) return;
    rootNavigatorKey.currentState?.popUntil((route) => route.isFirst);
    _onTabSelected(DockTab.downloads);
  }

  void _onTabSelected(DockTab tab) {
    // The double-tap-Profile-for-Settings shortcut is phone-only: Windows
    // opens Settings from the Profile page and Ctrl+, instead.
    if (tab == DockTab.profile && !_windowsUi) {
      final now = DateTime.now();
      final lastTap = _lastProfileTap;
      _lastProfileTap = now;
      if (lastTap != null &&
          now.difference(lastTap) < const Duration(milliseconds: 350)) {
        _lastProfileTap = null;
        Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const SettingsScreen(showBackButton: true),
          ),
        );
        return;
      }
    } else {
      _lastProfileTap = null;
    }
    // Re-tapping the current tab: no transition (unless leaving a desktop
    // page on Windows).
    if (tab == _tab && _desktopPage == null) return;
    DockScrollCollapse.reset();
    _selectedTab.value = tab;
    if (_windowsUi) {
      // The Windows workspace is built in build(), so it needs a rebuild to
      // show the new tab and drop any in-frame page.
      setState(() => _desktopPage = null);
      _repairFocusAfterSwitch();
    }
    _switchCtrl.forward(from: 0);
    if (tab == DockTab.myList && sl.isRegistered<MyListStore>()) {
      unawaited(sl<MyListStore>().pullFromCloud());
    }
  }

  /// Root-level Back: the first press shows a toast, a second within 2s exits.
  /// Only reached when Back would otherwise close the app — deep screens
  /// (detail, player, …) are pushed above this shell and pop normally.
  void _onBack() {
    // A sub-page inside the current tab (an open Settings section, an active
    // search) owns this Back — its own PopScope handles it in the same event.
    // Both PopScopes share this route, so Flutter fires ours too; bail so we
    // don't flash the exit toast over a normal in-tab back-out.
    // Extra desktop pages own Back before any retained hidden tab's interceptor.
    if (_windowsUi) {
      _lastBackPress = null;
      // Settings is a route pushed over the shell, so its Back pops that
      // route and never reaches here.
      if (_desktopPage != null) {
        setState(() => _desktopPage = null);
        return;
      }
      // shell-1 / shell-6: on a PC, Esc and Back never quit the app, so
      // the root never reaches the "press back again to exit" toast.
      return;
    }
    if (shellBackIntercepted.value) return;
    final now = DateTime.now();
    if (_lastBackPress != null &&
        now.difference(_lastBackPress!) < const Duration(seconds: 2)) {
      SystemNavigator.pop();
      return;
    }
    _lastBackPress = now;
    // FToast (part of fluttertoast) rather than the plain showToast, so the
    // pill can sit ABOVE the floating dock — showToast has no bottom offset.
    (FToast()..init(context)).showToast(
      gravity: ToastGravity.BOTTOM,
      toastDuration: const Duration(seconds: 2),
      child: Container(
        margin: const EdgeInsets.only(bottom: kDockClearance),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xF01C1C1E),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Text(
          context.l10n.pressBackAgainToExit,
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
      ),
    );
  }

  /// One page per visible tab, in the same order the dock draws them, so the
  /// [IndexedStack] index is just the tab's position in that list.
  ///
  /// Search is an opt-in dock tab that searches what Home is showing (source
  /// catalogue or metadata) — [dockSearchFixedSourceId], re-read on every
  /// rebuild so it follows catalogue picks. TV keeps its Settings rail
  /// destination.
  List<Widget> _pagesFor(
    List<DockTab> tabs,
    String profileId, {
    required bool deferInactiveTabs,
  }) {
    if (_visitedTabsProfileId != profileId) {
      _visitedTabsProfileId = profileId;
      _visitedTabs.clear();
    }
    _visitedTabs
      ..retainAll(tabs)
      ..add(tabs.contains(_tab) ? _tab : tabs.first);
    // Windows: Home is the only page that publishes the catalogue choices
    // for the shell pill's catalogue picker ("AniList ▾"), and it clears them
    // when it is disposed. Keeping Home mounted (hidden, tickers muted) makes
    // the picker show on every screen that shows the pill. Phones keep lazy
    // Home.
    if (desktopKeepsHomeMounted(windowsUi: _windowsUi, tabs: tabs)) {
      _visitedTabs.add(DockTab.home);
    }

    if (_visitedTabs.contains(DockTab.search)) {
      final sourceId = dockSearchFixedSourceId();
      if (sourceId != _searchPage.fixedSourceId) {
        _searchPage = SearchScreen(showBack: false, fixedSourceId: sourceId);
      }
    }
    return [
      for (final t in tabs)
        KeyedSubtree(
          // The revision in the key remounts the tabs when theme colours
          // change: their scaffolds read AppColors once and would otherwise
          // keep painting the old background.
          key: ValueKey(
            '$profileId:${t.name}:${ThemeController.revision.value}',
          ),
          child: _desktopTabPage(
            t,
            !_visitedTabs.contains(t)
                ? const SizedBox.shrink()
                : switch (t) {
                    DockTab.home =>
                      deferInactiveTabs ? _deferredHomePage : _homePage,
                    DockTab.search => _searchPage,
                    DockTab.myList => const MyListScreen(),
                    DockTab.profile => _profilePage,
                    // Both normally get pushed with a back button; as tabs they own the
                    // whole screen, so their own back affordance is suppressed.
                    DockTab.downloads => const DownloadsScreen(showBack: false),
                    DockTab.history => const HistoryScreen(showBack: false),
                    DockTab.sources => const BrowseSourcesScreen(),
                  },
          ),
        ),
    ];
  }

  /// Windows only: tickers run only on the current tab, and the page is
  /// wrapped in [TooltipVisibility] so a tooltip label that was fading out
  /// when the tab changed is removed at once instead of freezing on screen
  /// (its fade animation stops when the page's tickers are muted). Phones get
  /// [page] back untouched.
  Widget _desktopTabPage(DockTab tab, Widget page) {
    if (!_windowsUi) return page;
    return TooltipVisibility(
      visible: tab == _tab,
      child: TickerMode(enabled: tab == _tab, child: page),
    );
  }

  /// Extra Windows rail destinations below the primary tabs, in rail order.
  List<({String id, String label, String icon, VoidCallback onTap})>
  _desktopShortcuts() => [
    if (!sl<ContentModeCubit>().state.isReading)
      (
        id: 'streaming',
        label: context.l10n.streamingServices,
        icon: 'circle-play',
        onTap: () => _selectDesktopPage('streaming'),
      ),
    (
      id: 'schedule',
      label: 'Schedule & lists',
      icon: 'calendar-days',
      onTap: () => _selectDesktopPage('schedule'),
    ),
    (
      id: 'genres',
      label: 'Genres',
      icon: 'tags',
      onTap: () => _selectDesktopPage('genres'),
    ),
    (
      id: 'downloads',
      label: 'Downloads',
      icon: 'download',
      onTap: () => _onTabSelected(DockTab.downloads),
    ),
  ];

  /// The Windows window body: the icon rail, the top bar and the frame that
  /// shows either an in-frame page or the retained dock tabs.
  Widget _buildDesktopWorkspace() {
    final tabs = _visibleTabs();
    final profile = sl.isRegistered<ViewerProfileStore>()
        ? sl<ViewerProfileStore>().activeProfile
        : null;
    final profileId = sl.isRegistered<ViewerProfileStore>()
        ? sl<ViewerProfileStore>().dataProfileId
        : 'default';
    return DesktopShellWorkspace(
      active: _tab,
      activeShortcut: _desktopPage,
      onSelected: _onTabSelected,
      // shell-9: Notifications open in the frame like Schedule, and the
      // bell shows the unread new-episode count.
      onNotifications: () => _selectDesktopPage('notifications'),
      unreadNotifications: NewEpisodeInbox.unread,
      // shell-7: Ctrl+F and '/' focus this box.
      searchFocusNode: _desktopSearchFocus,
      searchController: _desktopSearchCtrl,
      shortcuts: _desktopShortcuts(),
      // shell-9: results open in the frame instead of a full-window page.
      onSearch: _openDesktopSearch,
      // The top-right avatar picks its picture the same way the Profile
      // page does and redraws itself when the profile or account changes.
      profile: const DesktopTopBarAvatar(),
      child: DesktopSidebarPages(
        key: ValueKey('desktop-pages:${profile?.id ?? 'default'}'),
        selected: _desktopPage,
        builders: {
          'streaming': (_) => const StreamingServicesScreen(),
          'schedule': (_) => const ListsHubScreen(),
          'genres': (_) => const GenresScreen(),
          // shell-9: top-bar search results, rebuilt for every submit.
          'search': (_) => SearchScreen(
            key: ValueKey('desktop-search:$_desktopSearchSerial'),
            showBack: false,
            initialQuery: _desktopSearchQuery,
          ),
          'notifications': (_) => const SubscriptionsScreen(),
          // Settings is not an in-frame page: it opens as a full page over
          // the rail (see _openDesktopSettings).
          // History in the frame (Ctrl+H / Profile page); Esc returns to
          // the tab underneath.
          'history': (_) => const HistoryScreen(showBack: false),
        },
        // Rebuilds on tab and theme changes like the phone body, so retained
        // desktop tabs pick up new colours too.
        fallback: ListenableBuilder(
          listenable: Listenable.merge([
            _selectedTab,
            ThemeController.revision,
          ]),
          builder: (context, _) => IndexedStack(
            index: math.max(0, tabs.indexOf(_tab)),
            children: _pagesFor(
              tabs,
              profileId,
              deferInactiveTabs:
                  _deferTabsForPicker ||
                  ProfileShellScope.shouldDeferTabs(context),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final deferContent = ProfileShellScope.shouldDeferContent(context);
    if (sl<AppMode>().isTv) {
      return deferContent ? const SizedBox.expand() : const RootShellTv();
    }
    if (deferContent) {
      return ColoredBox(color: AppColors.bg, child: const SizedBox.expand());
    }
    // Windows lets the user choose a Start page other than Home, and Home is
    // only built when visited, so launch checks (update dialog, daily
    // extension auto-update) start here once the shell is unlocked and shown.
    // AppLaunchChecks runs once per process, so Home mounting later is a no-op.
    if (_windowsUi && !AppLaunchChecks.started) {
      AppLaunchChecks.runOnce(this);
    }
    return PopScope(
      // Intercept Back at the app root: first press toasts, second exits.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBack();
      },
      child: BlocListener<ContentModeCubit, ContentMode>(
        bloc: sl<ContentModeCubit>(),
        listenWhen: (prev, curr) => prev != curr,
        listener: (context, mode) {
          // Always rebuild: the dock's items are computed in build(), so the
          // mode change has to reach it. No tab has to be bounced off any
          // more — the dock is the same in every mode now that Schedule is
          // not in it. Windows drops the Streaming page in reading modes.
          setState(() {
            if (mode.isReading && _desktopPage == 'streaming') {
              _desktopPage = null;
            }
          });
        },
        child: Scaffold(
          backgroundColor: AppColors.bg,
          // Content runs under the floating dock (screens keep their own bottom
          // padding so the last row scrolls clear of it).
          extendBody: true,
          // Windows uses its sidebar workspace; phones keep the dock body.
          body: _windowsUi
              ? _buildDesktopWorkspace()
              : NotificationListener<ScrollNotification>(
                  // One place, so no screen has to know the dock exists. Returns
                  // false throughout — it reads the scroll, never eats it.
                  onNotification: (notification) =>
                      DockScrollCollapse.onNotification(
                        notification,
                        enabled: !_keepDockExpanded,
                      ),
                  child: Builder(
                    builder: (context) {
                      final deferInactiveTabs =
                          _deferTabsForPicker ||
                          ProfileShellScope.shouldDeferTabs(context);
                      final visible = _visibleTabs();
                      return AnimatedBuilder(
                        animation: _switch,
                        builder: (context, child) {
                          final v = _switch.value;
                          // Incoming tab fades in from 0.4 and slides up 20px. Never blanks.
                          return Opacity(
                            opacity: 0.4 + 0.6 * v,
                            child: Transform.translate(
                              offset: Offset(0, (1 - v) * 20),
                              child: child,
                            ),
                          );
                        },
                        // RepaintBoundary → the page is a single cached layer the transition
                        // just composites (opacity + translate), so no repaint per frame.
                        child: RepaintBoundary(
                          child: ListenableBuilder(
                            listenable: Listenable.merge([
                              _selectedTab,
                              ThemeController.revision,
                            ]),
                            builder: (context, _) => IndexedStack(
                              // indexOf can be -1 for one frame if the mode flipped before
                              // the listener ran; clamp rather than throw.
                              index: math.max(0, visible.indexOf(_tab)),
                              children: _pagesFor(
                                visible,
                                sl.isRegistered<ViewerProfileStore>()
                                    ? sl<ViewerProfileStore>().dataProfileId
                                    : 'default',
                                deferInactiveTabs: deferInactiveTabs,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
          // Windows navigates with its rail, so it has no bottom dock.
          bottomNavigationBar: _windowsUi
              ? null
              : ListenableBuilder(
                  listenable: Listenable.merge([
                    _selectedTab,
                    dockHiddenBySection,
                    HomeCataloguePrefs.revision,
                  ]),
                  builder: (context, _) {
                    // Slide the dock away only when a Settings section is open AND the
                    // Profile tab is showing — every other tab keeps its dock.
                    final hide =
                        dockHiddenBySection.value && _tab == DockTab.profile;
                    final modesEnabled =
                        ZModePrefs.enabled &&
                        !(HomeCataloguePrefs.stremioSelected &&
                            sl<ContentModeCubit>().state == ContentMode.anime);
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (modesEnabled && _navPrefs.style == NavBarStyle.dock)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: BlocBuilder<ContentModeCubit, ContentMode>(
                              bloc: sl<ContentModeCubit>(),
                              builder: (_, mode) => ModeBar(
                                open: _modeBarOpen,
                                current: (mode, ZModePrefs.streamKind),
                                onPicked: (m, k) async {
                                  setState(() => _modeBarOpen = false);
                                  await ZModePrefs.setStreamKind(k);
                                  await sl<ContentModeCubit>().setMode(m);
                                  if (m != ContentMode.anime) {
                                    sl<HomeCubit>().load(reset: true);
                                  }
                                },
                              ),
                            ),
                          ),
                        // Collapse the SLOT as well as sliding the dock out of it.
                        // The dock is this Scaffold's bottomNavigationBar and the
                        // shell sets extendBody, so its height lands in the body's
                        // MediaQuery bottom padding whether or not it is on screen.
                        // Sliding alone left an open Settings section reserving a
                        // dock's worth of space for a dock that wasn't there.
                        TweenAnimationBuilder<double>(
                          tween: Tween<double>(begin: 1, end: hide ? 0 : 1),
                          duration: const Duration(milliseconds: 240),
                          // Held at one end, then changed in a step — deliberately
                          // NOT eased across the whole 240ms.
                          //
                          // This factor is the dock's height, the dock is the
                          // Scaffold's bottomNavigationBar, and the shell sets
                          // extendBody. So every distinct value here relays out the
                          // Scaffold and rebuilds the body — and the body is an
                          // IndexedStack, which lays out all mounted tabs. Easing
                          // it smoothly meant ~14 rebuilds of
                          // Home, My List and Sources for a dock animation, which
                          // measured 13-36ms of build per frame while raster sat
                          // at 3-5ms. It is why opening a Settings section stuttered
                          // and opening Playback or History never did: only the
                          // in-page sections hide the dock.
                          //
                          // Collapse late and expand early, so the slide below has
                          // its space for the whole of its travel either way.
                          curve: hide
                              ? const Interval(
                                  0.88,
                                  1,
                                  curve: Curves.easeOutCubic,
                                )
                              : const Interval(
                                  0,
                                  0.12,
                                  curve: Curves.easeOutCubic,
                                ),
                          builder: (context, factor, child) {
                            final aligned = Align(
                              alignment: Alignment.topCenter,
                              heightFactor: factor,
                              child: child,
                            );
                            return factor < 1
                                ? ClipRect(child: aligned)
                                : aligned;
                          },
                          child: AnimatedSlide(
                            offset: hide ? const Offset(0, 1.6) : Offset.zero,
                            duration: const Duration(milliseconds: 240),
                            curve: Curves.easeOutCubic,
                            child: IgnorePointer(
                              ignoring: hide,
                              // Scoped to the dock subtree on purpose. The dock's
                              // HEIGHT never changes below, so the Scaffold keeps its
                              // bottom inset and the body is never rebuilt by this.
                              child: ValueListenableBuilder<bool>(
                                valueListenable: dockCollapsedByScroll,
                                builder: (context, collapsed, child) {
                                  final tabs = _visibleTabs();
                                  if (_navPrefs.style == NavBarStyle.liquid) {
                                    return _LiquidNavDock(
                                      tabs: tabs,
                                      active: _tab,
                                      collapsed:
                                          collapsed && !_keepDockExpanded,
                                      glassTint: _navPrefs.glassTint,
                                      glassVisibility:
                                          _navPrefs.glassVisibility,
                                      glassQuality: _navPrefs.glassQuality,
                                      glassBlurEnabled:
                                          _navPrefs.glassBlurEnabled,
                                      onSelected: _onTabSelected,
                                      modesEnabled: modesEnabled,
                                      onModeSelected: (mode, kind) async {
                                        await ZModePrefs.setStreamKind(kind);
                                        await sl<ContentModeCubit>().setMode(
                                          mode,
                                        );
                                        if (mode != ContentMode.anime) {
                                          sl<HomeCubit>().load(reset: true);
                                        }
                                      },
                                    );
                                  }
                                  return _FloatingDock(
                                    collapsed: collapsed && !_keepDockExpanded,
                                    tabs: tabs,
                                    active: _tab,
                                    onSelected: _onTabSelected,
                                    centre: modesEnabled
                                        ? BlocBuilder<
                                            ContentModeCubit,
                                            ContentMode
                                          >(
                                            bloc: sl<ContentModeCubit>(),
                                            builder: (_, mode) => ModeFab(
                                              open: _modeBarOpen,
                                              icon: iconForMode(
                                                mode,
                                                ZModePrefs.streamKind,
                                              ),
                                              onTap: () => setState(
                                                () => _modeBarOpen =
                                                    !_modeBarOpen,
                                              ),
                                            ),
                                          )
                                        : null,
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
        ),
      ),
    );
  }
}

/// Liquid-glass navigation tabs with a Cue mode menu on the right.
class _LiquidNavDock extends StatelessWidget {
  const _LiquidNavDock({
    required this.tabs,
    required this.active,
    required this.collapsed,
    required this.glassTint,
    required this.glassVisibility,
    required this.glassQuality,
    required this.glassBlurEnabled,
    required this.onSelected,
    required this.modesEnabled,
    required this.onModeSelected,
  });

  final List<DockTab> tabs;
  final DockTab active;
  final bool collapsed;
  final double glassTint;
  final double glassVisibility;
  final GlassQuality glassQuality;
  final bool glassBlurEnabled;
  final ValueChanged<DockTab> onSelected;
  final bool modesEnabled;
  final void Function(ContentMode, StreamKind) onModeSelected;

  Widget _icon(DockTab tab, {bool selected = false}) {
    final color = selected ? AppColors.accent : AppColors.textPrimary;
    if (tab == DockTab.profile) {
      final profile = sl.isRegistered<ViewerProfileStore>()
          ? sl<ViewerProfileStore>().activeProfile
          : null;
      if (profile != null) {
        final avatar = ClipOval(
          child: ProfileAvatarFace(
            profile: profile,
            photoUrl: profilePhotoForFace(
              profile: profile,
              accountPhotoUrl: sl.isRegistered<AuthCubit>()
                  ? sl<AuthCubit>().state.avatarUrl
                  : null,
            ),
            iconSize: 18,
            photoDiameter: 26,
          ),
        );
        // The glass indicator renders a second, selected copy of nearby tabs.
        return selected
            ? avatar
            : Hero(tag: viewerProfileHeroTag(profile.id), child: avatar);
      }
      return Icon(Icons.person_outline_rounded, color: color);
    }
    final glyph = dockGlyphFor(tab);
    if (glyph != null) {
      return DockIcon(glyph, color: color, filled: selected, size: 23);
    }
    final icons = _iconFor(tab)!;
    return Icon(selected ? icons.$2 : icons.$1, color: color);
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final glass = liquidNavGlassSettings(
      glassTint,
      extraBlur: glassBlurEnabled,
      glassVisibility: glassVisibility,
    );
    final menuGlass =
        liquidNavGlassSettings(glassTint, extraBlur: glassBlurEnabled).copyWith(
          glassColor: AppColors.settingsCard.withValues(alpha: 0.84),
          blur: 8,
        );
    final glassTabs = [
      for (final tab in tabs)
        GlassTab(
          icon: tab == DockTab.profile
              // The package tab bar has no per-tab long-press, so the
              // gesture lives inside our own icon widget: the inner tap
              // forwards selection unchanged, the inner long-press wins
              // the arena and opens the switcher without selecting.
              ? GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onSelected(tab),
                  onLongPress: () => unawaited(openProfileSwitcher(context)),
                  child: _icon(tab),
                )
              : _icon(tab),
          activeIcon: tab == DockTab.profile
              ? GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onSelected(tab),
                  onLongPress: () => unawaited(openProfileSwitcher(context)),
                  child: _icon(tab, selected: true),
                )
              : _icon(tab, selected: true),
          label: tab.localizedLabel(context),
          semanticLabel: tab.localizedLabel(context),
        ),
    ];
    // 12 on a phone, as before; on a tablet the dock keeps a phone-like width
    // and sits centred instead of stretching across the screen.
    final side = isTabletLayout(context)
        ? math.max(12.0, (MediaQuery.sizeOf(context).width - 520) / 2)
        : 12.0;
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: 96 + bottomInset),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: EdgeInsets.only(
            left: side,
            right: side,
            bottom: bottomInset + 12,
          ),
          child: Row(
            children: [
              Expanded(
                child: _LiquidGlassTabBar(
                  tabs: glassTabs,
                  selectedIndex: tabs.indexOf(active).clamp(0, tabs.length - 1),
                  collapsed: collapsed,
                  modesEnabled: modesEnabled,
                  quality: glassQuality,
                  settings: glass,
                  onTabSelected: (index) => onSelected(tabs[index]),
                ),
              ),
              if (modesEnabled) ...[
                const SizedBox(width: 8),
                SizedBox(
                  width: 56,
                  height: 56,
                  child: GlassMenu(
                    menuAlignment: GlassMenuAlignment.bottomRight,
                    autoAdjustToScreen: true,
                    menuPadding: const EdgeInsets.all(12),
                    menuWidth: 224,
                    menuBorderRadius: 28,
                    itemBorderRadius: 20,
                    quality: glassQuality,
                    settings: menuGlass,
                    selectionColor: AppColors.accent.withValues(alpha: 0.14),
                    enableInteractionGlow: false,
                    semanticLabel: 'Change content mode',
                    triggerBuilder: (context, toggleMenu) => GlassButton(
                      icon: const Icon(Icons.menu_rounded),
                      label: 'Change content mode',
                      onTap: toggleMenu,
                      width: 56,
                      height: 56,
                      quality: glassQuality,
                      settings: glass,
                      isStationary: true,
                    ),
                    items: [
                      for (final choice in modeChoices)
                        if (ZModePrefs.enabled ||
                            choice.mode != ContentMode.anime ||
                            choice.kind == StreamKind.anime)
                          GlassMenuItem(
                            title: choice.label(context),
                            icon: Icon(choice.icon),
                            trailing:
                                choice.mode == sl<ContentModeCubit>().state &&
                                    (choice.mode != ContentMode.anime ||
                                        choice.kind == ZModePrefs.streamKind)
                                ? Icon(
                                    Icons.check_rounded,
                                    color: AppColors.accent,
                                  )
                                : null,
                            isSelected:
                                choice.mode == sl<ContentModeCubit>().state &&
                                (choice.mode != ContentMode.anime ||
                                    choice.kind == ZModePrefs.streamKind),
                            iconColor: AppColors.textPrimary,
                            titleStyle: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                            ),
                            height: 48,
                            onTap: () =>
                                onModeSelected(choice.mode, choice.kind),
                          ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _LiquidGlassTabBar extends StatelessWidget {
  const _LiquidGlassTabBar({
    required this.tabs,
    required this.selectedIndex,
    required this.collapsed,
    required this.modesEnabled,
    required this.quality,
    required this.settings,
    required this.onTabSelected,
  });

  final List<GlassTab> tabs;
  final int selectedIndex;
  final bool collapsed;
  final bool modesEnabled;
  final GlassQuality quality;
  final LiquidGlassSettings settings;
  final ValueChanged<int> onTabSelected;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final compactWidth = math.min(
        constraints.maxWidth,
        tabs.length * 52.0 + 8,
      );
      // Keep the missing mode button's 56px plus 8px gap out of the open bar.
      final expandedWidth = modesEnabled
          ? constraints.maxWidth
          : math.max(compactWidth, constraints.maxWidth - 64);
      return TweenAnimationBuilder<double>(
        tween: Tween(end: collapsed ? 1 : 0),
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        builder: (context, progress, _) {
          return Align(
            alignment: modesEnabled ? Alignment.centerRight : Alignment.center,
            child: SizedBox(
              width: expandedWidth + (compactWidth - expandedWidth) * progress,
              child: GlassTabBar.bottom(
                tabs: tabs,
                selectedIndex: selectedIndex,
                onTabSelected: onTabSelected,
                horizontalPadding: 4,
                verticalPadding: 12 - 8 * progress,
                barHeight: 60 - 10 * progress,
                barBorderRadius: 30,
                tabPadding: const EdgeInsets.symmetric(horizontal: 2),
                iconSize: 22,
                labelFontSize: math.max(0.01, 10 * (1 - progress)),
                iconLabelSpacing: 4 * (1 - progress),
                quality: quality,
                backgroundQuality: progress == 0 || progress == 1
                    ? quality
                    : GlassQuality.minimal,
                settings: settings,
                indicatorColor: AppColors.accent.withValues(alpha: 0.14),
                selectedIconColor: AppColors.accent,
                unselectedIconColor: AppColors.textPrimary,
                selectedLabelColor: AppColors.textPrimary.withValues(
                  alpha: 1 - progress,
                ),
                unselectedLabelColor: AppColors.textSecondary.withValues(
                  alpha: 1 - progress,
                ),
                indicatorExpansion: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 8,
                ),
                magnification: 1.08,
              ),
            ),
          );
        },
      );
    },
  );
}

/// The frosted floating capsule: blurred surface, hairline border, five
/// items. Active tab = the icon's solid accent twin + accent label — the
/// state change lives in the icon itself (deliberately not the Material
/// pill/indicator look).
class _FloatingDock extends StatelessWidget {
  const _FloatingDock({
    required this.tabs,
    required this.active,
    required this.onSelected,
    this.collapsed = false,
    this.centre,
  });

  /// Scrolled down far enough that the dock gives way: labels fade out and the
  /// pill draws in. The tabs stay put and stay tappable — see
  /// [dockCollapsedByScroll].
  final bool collapsed;

  /// Exactly what to draw, already ordered and already filtered for the
  /// content mode — the dock does no picking of its own any more.
  final List<DockTab> tabs;
  final DockTab active;
  final ValueChanged<DockTab> onSelected;

  /// The Z Mode centre button. Not a [DockTab] — it isn't reorderable,
  /// hideable, or counted toward the tab limit. Null when Z Mode is off.
  final Widget? centre;

  Widget _item(BuildContext context, DockTab t, double labels) =>
      t == DockTab.profile
      ? _ProfileDockItem(
          selected: active == t,
          onTap: () => onSelected(t),
          labelOpacity: labels,
        )
      : _DockItem(
          labelOpacity: labels,
          label: t.localizedLabel(context),
          glyph: dockGlyphFor(t),
          icon: _iconFor(t),
          selected: active == t,
          onTap: () => onSelected(t),
        );

  // Pieces of the dock's height, so the slot reserved below is measured rather
  // than guessed — a guess breaks the moment the system font scale moves.
  static const double _iconRow = 25;
  static const double _labelGap = 3;
  static const double _labelSize = 10;
  static const double _labelLeading = 1.2;
  static const double _itemVPad = 4;
  static const double _pillVPad = 18;
  static const double _fabOpen = 50;
  static const double _fabShut = 38;

  /// Width one tab gets in the collapsed pill. The items are [Expanded], so
  /// they always divide whatever width the pill has — narrowing it by a fixed
  /// amount just leaves the icons floating in wide cells. So the collapsed
  /// width is built up from this instead, and the pill ends up roughly the
  /// size of its icons.
  ///
  /// Width one tab gets collapsed. 48 is the guideline, and the pill's clip
  /// trims a few off it, so the real target lands near 44 — Apple's floor.
  ///
  /// Measured on device rather than assumed: at 40 this budget produced a
  /// 36-wide target. Inside the pill's ClipRRect the hit area and the painted
  /// width are the same thing, so this cannot be shrunk without shrinking the
  /// target with it.
  static const double _tabShut = 48;

  /// Minimum HEIGHT of a tab's tap area. The painted icon is 25 and the pill
  /// collapses to 56 — but a 27-tall target sitting just above the gesture bar
  /// is a miss waiting to happen, so the touchable box is held at 44 (Apple's
  /// floor) even when nothing is drawn in most of it.
  ///
  /// 48 is Android's floor. Free: the open row is 50 anyway (the centre
  /// button), and the collapsed row is paid for by dropping the pill's own
  /// padding 9 → 4 as it closes. Both states keep the exact height they had —
  /// 68 open, 56 closed — the space just moves from padding into the box you
  /// can actually hit.
  static const double _tapMin = 48;

  /// Widest the open dock gets on a tablet.
  static const double _tabletDockMax = 520;

  /// iOS-ish: almost all of the travel happens early, then it eases into place
  /// instead of stopping. Slower than a Material fling on purpose — this is a
  /// shape settling, not a thing arriving.
  static const Curve _ease = Cubic(0.32, 0.72, 0, 1);

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final half = tabs.length ~/ 2;
    final first = tabs.sublist(0, half);
    final rest = tabs.sublist(half);

    // The SLOT stays the size of the open dock, always. The pill shrinks
    // inside it and hangs from the bottom, so the Scaffold's bottom inset
    // never moves and the body is never relaid out while you scroll.
    //
    // Taken through the text scaler, not from a constant: at a larger system
    // font the label is taller, and a slot that assumed 10px would clip the
    // labels off the dock for exactly the people who need them most.
    final labelRow =
        _labelGap +
        MediaQuery.textScalerOf(context).scale(_labelSize) * _labelLeading;
    final openInner = math.max(
      math.max(_itemVPad + _iconRow + labelRow, _tapMin),
      centre != null ? _fabOpen : 0.0,
    );
    // Slack, because predicting a text line to the pixel is a losing game —
    // font, locale and platform metrics all move it. The constraint below is a
    // MINIMUM, not a fixed height, so being wrong costs a pixel of dead space
    // instead of a RenderFlex overflow.
    final slot = openInner + _pillVPad + bottomInset + 12 + 4;

    return ConstrainedBox(
      // minHeight, deliberately: the slot holds the open dock's size so the
      // Scaffold's inset never moves while the pill shrinks inside it — but if
      // the open dock ever needs MORE (a big system font), it gets it rather
      // than clipping the labels off.
      constraints: BoxConstraints(minHeight: slot),
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: collapsed ? 1 : 0),
        duration: const Duration(milliseconds: 340),
        curve: _ease,
        builder: (context, t, _) => Align(
          alignment: Alignment.bottomCenter,
          child: _pill(context, bottomInset, t, first, rest),
        ),
      ),
    );
  }

  /// The dock at collapse fraction [t] — 0 open, 1 icons-only.
  ///
  /// Nothing here is given a fixed height: the label row folds away inside
  /// each item and the centre button scales down, so the pill takes whatever
  /// height its contents actually need and can't be made to overflow.
  Widget _pill(
    BuildContext context,
    double bottomInset,
    double t,
    List<DockTab> first,
    List<DockTab> rest,
  ) {
    // Collapsed width is derived, not a fixed inset: it is what the icons
    // actually need, so three tabs draw in further than four and a narrow
    // phone doesn't end up with a pill wider than its contents.
    final width = MediaQuery.sizeOf(context).width;
    final shutWidth =
        tabs.length * _tabShut +
        (centre != null ? _fabShut + 12 : 0) +
        12; // the pill's own horizontal padding
    // Never past the open inset — on a screen too narrow to shrink into, the
    // dock simply stays where it is rather than growing.
    // On a tablet the open dock keeps a phone-sized width, centred, instead of
    // stretching across the screen. 16 on a phone, exactly as before.
    final openSide = isTabletLayout(context)
        ? math.max(16.0, (width - _tabletDockMax) / 2)
        : 16.0;
    final shutSide = math.max(openSide, (width - shutWidth) / 2);
    final windows = defaultTargetPlatform == TargetPlatform.windows;
    final side = windows
        ? math.max(
            16.0,
            (width - math.min(420.0, tabs.length * 60.0 + 60.0)) / 2,
          )
        : openSide + (shutSide - openSide) * t;
    final labels = 1 - t;
    final fab = _fabOpen - (_fabOpen - _fabShut) * t;
    // 9 open, 4 closed — the room the taller tap box needs, given back.
    final pillPad = windows ? 4.0 : 9 - 5 * t;
    return Padding(
      padding: EdgeInsets.fromLTRB(side, 0, side, bottomInset + 12),
      child: FakeFrost(
        key: const ValueKey('dockPill'),
        borderRadius: BorderRadius.circular(26),
        opacity: 0.55,
        blur: true,
        blurSigma: 14,
        padding: EdgeInsets.symmetric(horizontal: 6, vertical: pillPad),
        child: Row(
          children: [
            for (final tab in first) _item(context, tab, labels),
            if (centre != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                // Sized down rather than scaled in place: it is the tallest
                // thing in the row, so leaving it at 50 would hold the
                // whole dock open no matter what the tabs did.
                child: SizedBox(
                  width: fab,
                  height: fab,
                  child: FittedBox(fit: BoxFit.contain, child: centre!),
                ),
              ),
            for (final tab in rest) _item(context, tab, labels),
          ],
        ),
      ),
    );
  }
}

/// (outline, filled) Material icons for tabs with no hand-drawn glyph.
(IconData, IconData)? _iconFor(DockTab t) => switch (t) {
  DockTab.downloads => (Icons.download_outlined, Icons.download_rounded),
  DockTab.history => (Icons.history_outlined, Icons.history_rounded),
  DockTab.sources => (Icons.extension_outlined, Icons.extension_rounded),
  _ => null,
};

/// A quick spring "pop" for a dock icon the moment its tab becomes selected
/// (scale 0.7 → 1.0 with a soft overshoot). Deselection doesn't animate —
/// the motion belongs to the tab you're landing on.
class _DockPop extends StatelessWidget {
  const _DockPop({required this.selected, required this.child});

  final bool selected;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      key: ValueKey(selected), // restart the tween when selection flips
      tween: Tween(begin: selected ? 0.7 : 1.0, end: 1.0),
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeOutBack,
      builder: (_, v, c) => Transform.scale(scale: v, child: c),
      child: child,
    );
  }
}

class _DockItem extends StatelessWidget {
  const _DockItem({
    required this.label,
    required this.glyph,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.labelOpacity = 1,
  });

  /// 1 whole, 0 collapsed. Drives both the fade AND the row's height, so the
  /// label takes its space with it when it goes.
  final double labelOpacity;

  final String label;

  /// Hand-drawn glyph; null when [icon] carries the tab instead.
  final DockGlyph? glyph;

  /// (outline, filled) Material pair, used when [glyph] is null.
  final (IconData, IconData)? icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.accent : AppColors.textSecondary;
    return Expanded(
      // The name lives here, not on the Text below: collapsed, that Text has
      // zero height and drops out of the tree, and a screen reader was left
      // with four unlabelled buttons.
      child: Semantics(
        label: label,
        button: true,
        selected: selected,
        container: true,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: _FloatingDock._tapMin),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      height: 25,
                      child: Center(
                        child: _DockPop(
                          selected: selected,
                          child: glyph != null
                              ? DockIcon(glyph!, color: color, filled: selected)
                              : Icon(
                                  selected ? icon!.$2 : icon!.$1,
                                  color: color,
                                  size: 23,
                                ),
                        ),
                      ),
                    ),
                    // Folded away, not just faded: heightFactor takes the row's
                    // height with it, which is what lets the pill actually shrink.
                    ClipRect(
                      child: Align(
                        alignment: Alignment.topCenter,
                        heightFactor: labelOpacity,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: ExcludeSemantics(
                            child: Opacity(
                              opacity: labelOpacity,
                              child: Text(
                                label,
                                maxLines: 1,
                                overflow: TextOverflow.clip,
                                softWrap: false,
                                style: TextStyle(
                                  fontSize: 10,
                                  height: 1.2,
                                  letterSpacing: 0.1,
                                  color: color,
                                  fontWeight: selected
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Profile switcher sheet, shared by both docks: the old floating dock's
/// profile item and the liquid dock's profile tab both long-press into this.
Future<void> openProfileSwitcher(BuildContext context) async {
  if (!sl.isRegistered<ViewerProfileStore>()) return;
  final profiles = sl<ViewerProfileStore>();
  if (profiles.profiles.length < 2) return;

  final addProfile = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
    ),
    builder: (sheetContext) => _ProfileSwitcherSheet(
      profiles: profiles,
      onSelected: (profile) {
        Navigator.of(sheetContext).pop();
        unawaited(_switchProfile(context, profiles, profile));
      },
      onAddProfile: () => Navigator.of(sheetContext).pop(true),
    ),
  );
  if (addProfile == true && context.mounted) {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const ViewerProfilesScreen()),
    );
  }
}

Future<void> _switchProfile(
  BuildContext context,
  ViewerProfileStore profiles,
  ViewerProfile profile,
) async {
  try {
    if (!context.mounted) return;
    final owner = profiles.ownerKey;
    // Windows also accepts (and moves) a PIN set by an older PC-only build.
    final unlocked = defaultTargetPlatform == TargetPlatform.windows
        ? await ensureProfileAccess(context, profile)
        : await ensureProfileUnlocked(context, profile);
    if (!unlocked) return;
    if (!context.mounted || profiles.ownerKey != owner) return;
    if (!profiles.profiles.any((p) => p.id == profile.id)) return;
    final locks = sl.isRegistered<ProfileLockStore>()
        ? sl<ProfileLockStore>()
        : null;
    if (profiles.activeId != profile.id) {
      // Windows: history is per profile, so a video in the floating mini
      // player is saved to the profile that watched it and stopped first.
      if (defaultTargetPlatform == TargetPlatform.windows) {
        await closeFloatingPlayerBeforeProfileSwitch();
      }
      locks?.approveSwitch(profile.id);
    }
    try {
      await profiles.switchTo(profile.id);
    } finally {
      locks?.consumeSwitchApproval(profile.id);
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text("Couldn't switch profile. Try again.")),
      );
    }
  }
}

/// The Profile tab — the user's avatar when signed in (accent ring while
/// active), a plain person glyph otherwise. Opens the same Settings screen
/// the gear used to.
class _ProfileDockItem extends StatelessWidget {
  const _ProfileDockItem({
    required this.selected,
    required this.onTap,
    this.labelOpacity = 1,
  });

  /// See [_DockItem.labelOpacity].
  final double labelOpacity;

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.accent : AppColors.textSecondary;
    final profile = sl.isRegistered<ViewerProfileStore>()
        ? sl<ViewerProfileStore>().activeProfile
        : null;
    return Expanded(
      // See [_DockItem]: the name has to survive the label folding away.
      child: Semantics(
        label: context.l10n.profile,
        button: true,
        selected: selected,
        container: true,
        hint: 'Long-press to switch profiles',
        onLongPress: () => unawaited(openProfileSwitcher(context)),
        child: InkWell(
          onTap: onTap,
          onLongPress: () => unawaited(openProfileSwitcher(context)),
          borderRadius: BorderRadius.circular(18),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: _FloatingDock._tapMin),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      height: 25,
                      child: Center(
                        child: _DockPop(
                          selected: selected,
                          child: profile == null
                              ? BlocBuilder<AuthCubit, AuthState>(
                                  builder: (context, auth) {
                                    final ring = selected
                                        ? Border.all(
                                            color: AppColors.accent,
                                            width: 1.8,
                                          )
                                        : null;
                                    if (auth.isLoggedIn) {
                                      final initial =
                                          auth.displayName.isNotEmpty
                                          ? auth.displayName[0].toUpperCase()
                                          : '?';
                                      return Container(
                                        width: 24,
                                        height: 24,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          border: ring,
                                          color: AppColors.surface2,
                                          image: auth.avatarUrl != null
                                              ? DecorationImage(
                                                  image:
                                                      CachedNetworkImageProvider(
                                                        auth.avatarUrl!,
                                                      ),
                                                  fit: BoxFit.cover,
                                                )
                                              : null,
                                        ),
                                        alignment: Alignment.center,
                                        child: auth.avatarUrl == null
                                            ? Text(
                                                initial,
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w800,
                                                  color: selected
                                                      ? AppColors.accent
                                                      : AppColors.textPrimary,
                                                ),
                                              )
                                            : null,
                                      );
                                    }
                                    // Signed out — quiet person glyph in a hairline circle.
                                    return Container(
                                      width: 24,
                                      height: 24,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        border:
                                            ring ??
                                            Border.all(
                                              color: color,
                                              width: 1.4,
                                            ),
                                      ),
                                      child: Icon(
                                        Icons.person_outline,
                                        size: 15,
                                        color: color,
                                      ),
                                    );
                                  },
                                )
                              : Hero(
                                  tag: viewerProfileHeroTag(profile.id),
                                  child: Container(
                                    width: 24,
                                    height: 24,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      border: selected
                                          ? Border.all(
                                              color: AppColors.accent,
                                              width: 1.8,
                                            )
                                          : null,
                                      color: viewerProfileAvatarColor(
                                        profile.avatar,
                                      ),
                                    ),
                                    alignment: Alignment.center,
                                    child: ProfileAvatarFace(
                                      profile: profile,
                                      photoUrl: profilePhotoForFace(
                                        profile: profile,
                                        accountPhotoUrl:
                                            sl.isRegistered<AuthCubit>()
                                            ? sl<AuthCubit>().state.avatarUrl
                                            : null,
                                      ),
                                      iconSize: 14,
                                      photoDiameter: 24,
                                    ),
                                  ),
                                ),
                        ),
                      ),
                    ),
                    // Folded away, not just faded: heightFactor takes the row's
                    // height with it, which is what lets the pill actually shrink.
                    ClipRect(
                      child: Align(
                        alignment: Alignment.topCenter,
                        heightFactor: labelOpacity,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: ExcludeSemantics(
                            child: Opacity(
                              opacity: labelOpacity,
                              child: Text(
                                context.l10n.profile,
                                maxLines: 1,
                                overflow: TextOverflow.clip,
                                softWrap: false,
                                style: TextStyle(
                                  fontSize: 10,
                                  height: 1.2,
                                  letterSpacing: 0.1,
                                  color: color,
                                  fontWeight: selected
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProfileSwitcherSheet extends StatelessWidget {
  const _ProfileSwitcherSheet({
    required this.profiles,
    required this.onSelected,
    required this.onAddProfile,
  });

  final ViewerProfileStore profiles;
  final ValueChanged<ViewerProfile> onSelected;
  final VoidCallback onAddProfile;

  @override
  Widget build(BuildContext context) {
    final choices = profiles.profiles;
    final activeId = profiles.activeId;
    final accountPhotoUrl = sl.isRegistered<AuthCubit>()
        ? sl<AuthCubit>().state.avatarUrl
        : null;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 2, 14, 8),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.7,
          ),
          child: Column(
            key: const ValueKey('profile-switcher-sheet'),
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: ClipRRect(
                  key: const ValueKey('profile-switcher-options-card'),
                  borderRadius: BorderRadius.circular(18),
                  child: Material(
                    color: AppColors.surface,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                      side: BorderSide(color: AppColors.hairline),
                    ),
                    child: ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
                      children: [
                        for (final profile in choices) ...[
                          Semantics(
                            button: true,
                            selected: profile.id == activeId,
                            label: profile.name,
                            child: ListTile(
                              key: ValueKey(
                                profile.id == activeId
                                    ? 'profile-switcher-active'
                                    : 'profile-switcher-choice-${profile.id}',
                              ),
                              selected: profile.id == activeId,
                              visualDensity: const VisualDensity(vertical: -1),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                              onTap: () => onSelected(profile),
                              leading: Container(
                                width: 38,
                                height: 38,
                                decoration: BoxDecoration(
                                  color: viewerProfileAvatarColor(
                                    profile.avatar,
                                  ),
                                  shape: BoxShape.circle,
                                ),
                                child: ClipOval(
                                  child: ProfileAvatarFace(
                                    profile: profile,
                                    photoUrl: profilePhotoForFace(
                                      profile: profile,
                                      accountPhotoUrl: accountPhotoUrl,
                                    ),
                                    iconSize: 17,
                                    photoDiameter: 38,
                                  ),
                                ),
                              ),
                              title: Text(profile.name, maxLines: 1),
                              trailing: profile.id == activeId
                                  ? Icon(
                                      Icons.check_circle_rounded,
                                      color: AppColors.accent,
                                    )
                                  : null,
                            ),
                          ),
                        ],
                        ListTile(
                          key: const ValueKey('profile-switcher-add'),
                          visualDensity: const VisualDensity(vertical: -1),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          leading: Container(
                            width: 38,
                            height: 38,
                            decoration: BoxDecoration(
                              color: AppColors.surface,
                              shape: BoxShape.circle,
                              border: Border.all(color: AppColors.hairline),
                            ),
                            child: Icon(
                              Icons.add_rounded,
                              color: AppColors.textSecondary,
                            ),
                          ),
                          title: const Text('Add profile'),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: onAddProfile,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                key: const ValueKey('profile-switcher-brand-footer'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  Image.asset(
                    'assets/icon/logo_mark.png',
                    width: 18,
                    height: 18,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Zangetsu',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: AppColors.textSecondary,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.2,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
