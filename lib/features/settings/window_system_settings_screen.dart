import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/desktop/desktop_native.dart';
import '../../core/desktop/desktop_prefs.dart';
import '../../core/di/injector.dart';
import '../../core/theme/app_colors.dart';
import '../../core/ui/desktop_settings_surface.dart';
import '../../core/ui/nav_prefs.dart';
import '../../core/ui/settings_widgets.dart';
import 'desktop_settings_workspace.dart';
import 'keyboard_shortcuts_screen.dart';
import '../../l10n/l10n.dart';

// The label helpers below have no context; appL10n follows the app language.

/// Labels for the close-button choices (set-7 / shell-5).
String closeBehaviourLabel(DesktopCloseBehaviour v) => switch (v) {
  DesktopCloseBehaviour.ask => appL10n.closeAskWhenDownloading,
  DesktopCloseBehaviour.trayWhileDownloading =>
    appL10n.closeTrayWhileDownloading,
  DesktopCloseBehaviour.alwaysTray => appL10n.closeAlwaysTray,
  DesktopCloseBehaviour.quit => appL10n.quit,
};

/// One-line explanation under each close-button choice.
String closeBehaviourDescription(DesktopCloseBehaviour v) => switch (v) {
  DesktopCloseBehaviour.ask => appL10n.closeAskDescription,
  DesktopCloseBehaviour.trayWhileDownloading =>
    appL10n.closeTrayWhileDownloadingDescription,
  DesktopCloseBehaviour.alwaysTray => appL10n.closeAlwaysTrayDescription,
  DesktopCloseBehaviour.quit => appL10n.closeQuitDescription,
};

/// Labels for the page the app opens on.
String startPageLabel(DesktopStartPage v) => switch (v) {
  DesktopStartPage.home => appL10n.home,
  DesktopStartPage.myList => appL10n.myList,
  DesktopStartPage.sources => appL10n.settingsSectionSources,
  DesktopStartPage.downloads => appL10n.settingsSectionDownloads,
  DesktopStartPage.schedule => appL10n.schedule,
  DesktopStartPage.history => appL10n.settingsSectionHistory,
  DesktopStartPage.lastUsed => appL10n.startPageLastUsed,
};

/// Label for an auto-lock idle time (0 = off).
String autoLockLabel(int minutes) =>
    minutes <= 0 ? appL10n.off : appL10n.afterNMinutes(minutes);

/// Windows "Window & system" settings (set-7 Option A): launch at sign-in,
/// close button behaviour, remembering the window placement and the start
/// page, plus new-episode alerts, profile auto-lock and a link to the
/// keyboard shortcuts page. Windows only; the Settings row is gated.
class WindowSystemSettingsScreen extends StatefulWidget {
  const WindowSystemSettingsScreen({super.key});

  @override
  State<WindowSystemSettingsScreen> createState() =>
      _WindowSystemSettingsScreenState();
}

class _WindowSystemSettingsScreenState
    extends State<WindowSystemSettingsScreen> {
  // Native values load asynchronously from the registry; null = loading.
  bool? _launchAtSignIn;
  bool? _rememberPlacement;

  @override
  void initState() {
    super.initState();
    _loadNative();
  }

  Future<void> _loadNative() async {
    // DesktopNative is a safe no-op off Windows / in tests; any failure just
    // shows the switch off rather than breaking the page.
    bool launch = false;
    bool remember = true;
    try {
      launch = await DesktopNative.isLaunchAtSignInEnabled();
      remember = await DesktopNative.rememberWindowPlacement();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _launchAtSignIn = launch;
      _rememberPlacement = remember;
    });
  }

  Future<void> _setLaunchAtSignIn(bool v) async {
    // Flip the switch straight away; put it back if Windows refuses the
    // Run-key change (setLaunchAtSignIn throws PlatformException then).
    setState(() => _launchAtSignIn = v);
    try {
      await DesktopNative.setLaunchAtSignIn(v);
    } catch (_) {
      if (!mounted) return;
      setState(() => _launchAtSignIn = !v);
      _showError(context.l10n.windowsSignInSettingRefused);
    }
  }

  Future<void> _setRememberPlacement(bool v) async {
    // Same optimistic flip and roll-back as launch at sign-in.
    setState(() => _rememberPlacement = v);
    try {
      await DesktopNative.setRememberWindowPlacement(v);
    } catch (_) {
      if (!mounted) return;
      setState(() => _rememberPlacement = !v);
      _showError(context.l10n.couldntSaveWindowSetting);
    }
  }

  // Short failure message for the native switches.
  void _showError(String text) {
    ScaffoldMessenger.maybeOf(context)
      ?..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _pickCloseBehaviour() async {
    final picked = await showGraphiteSettingsChoice<DesktopCloseBehaviour>(
      context,
      title: context.l10n.closeButton,
      description: context.l10n.closeButtonDescription,
      options: [
        for (final v in DesktopCloseBehaviour.values)
          (v, closeBehaviourLabel(v)),
      ],
      optionDescriptions: {
        for (final v in DesktopCloseBehaviour.values)
          v: closeBehaviourDescription(v),
      },
      current: DesktopPrefs.closeBehaviour,
    );
    if (picked != null) await DesktopPrefs.setCloseBehaviour(picked);
  }

  // The start page the shell really reads at launch is NavPrefs.startTab
  // (RootShell), the same value as Settings > Interface > Start page, so
  // this row edits that instead of a separate preference. Null in tests
  // that do not register NavPrefs.
  NavPrefs? get _navPrefs =>
      sl.isRegistered<NavPrefs>() ? sl<NavPrefs>() : null;

  // Label of the saved start tab, as the sidebar names it.
  String _startPageText() => (_navPrefs?.startTab ?? DockTab.home).label;

  Future<void> _pickStartPage() async {
    final prefs = _navPrefs;
    if (prefs == null) return;
    final picked = await showGraphiteSettingsChoice<DockTab>(
      context,
      title: context.l10n.startPage,
      description: context.l10n.startPageDescription,
      options: [for (final tab in NavPrefs.desktopStartTabs) (tab, tab.label)],
      current: prefs.startTab,
    );
    if (picked == null || picked == prefs.startTab) return;
    await prefs.setStartTab(picked);
    // NavPrefs is not a DesktopPrefs listenable, so refresh the row here.
    if (mounted) setState(() {});
  }

  Future<void> _pickAutoLock() async {
    final picked = await showGraphiteSettingsChoice<int>(
      context,
      title: context.l10n.autoLockAfterIdle,
      description: context.l10n.autoLockDescription,
      options: [
        for (final m in DesktopPrefs.autoLockChoices) (m, autoLockLabel(m)),
      ],
      current: DesktopPrefs.autoLockIdleMinutes,
    );
    if (picked != null) await DesktopPrefs.setAutoLockIdleMinutes(picked);
  }

  // The same switch as the Reader page's toggle rows (accent thumb,
  // shrink-wrapped tap target so the row keeps the shared row height).
  Widget _switch(bool value, ValueChanged<bool>? onChanged) => Switch.adaptive(
    value: value,
    activeThumbColor: AppColors.accent,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    onChanged: onChanged,
  );

  // Value and chevron of a choice row, as on the Reader page.
  Widget _value(String text) => DesktopSettingsValue(text);

  @override
  Widget build(BuildContext context) {
    // Reachable from places outside the settings workspace on Windows;
    // provide the desktop scope so it always renders the graphite design,
    // with the column centred since no Settings sidebar stands beside it
    // (like Download location and Manual matches).
    if (defaultTargetPlatform == TargetPlatform.windows &&
        !DesktopSettingsScope.contains(context)) {
      return DesktopSettingsScope(
        standalone: true,
        child: Builder(builder: _page),
      );
    }
    return _page(context);
  }

  Widget _page(BuildContext context) {
    return Scaffold(
      backgroundColor: settingsPageBackground(context),
      appBar: settingsAppBar(context.l10n.windowAndSystem),
      // Laid out like the other settings pages (Reader, Playback): a plain
      // list from the left edge whose cards cap themselves at the shared
      // settings width, instead of a narrow centred column.
      // Rebuild whenever a desktop preference changes.
      body: ListenableBuilder(
        listenable: DesktopPrefs.changes,
        builder: (context, _) => ListView(
          padding: DesktopSettingsScope.listPadding(
            context,
            top: 4,
            bottom: 28,
          ),
          children: [
            SettingsSectionLabel(context.l10n.windowSection, first: true),
            SettingsCard(
              children: [
                SettingsTile(
                  icon: Icons.login_rounded,
                  title: context.l10n.launchAtSignIn,
                  subtitle: context.l10n.launchAtSignInSubtitle,
                  subtitleMaxLines: null,
                  onTap: _launchAtSignIn == null
                      ? null
                      : () => _setLaunchAtSignIn(!_launchAtSignIn!),
                  trailing: _switch(
                    _launchAtSignIn ?? false,
                    _launchAtSignIn == null ? null : _setLaunchAtSignIn,
                  ),
                ),
                SettingsTile(
                  icon: Icons.close_rounded,
                  title: context.l10n.closeButton,
                  subtitle: closeBehaviourDescription(
                    DesktopPrefs.closeBehaviour,
                  ),
                  subtitleMaxLines: null,
                  trailing: _value(
                    closeBehaviourLabel(DesktopPrefs.closeBehaviour),
                  ),
                  onTap: _pickCloseBehaviour,
                ),
                SettingsTile(
                  icon: Icons.aspect_ratio_rounded,
                  title: context.l10n.rememberWindowSizePosition,
                  subtitle: context.l10n.rememberWindowSubtitle,
                  subtitleMaxLines: null,
                  onTap: _rememberPlacement == null
                      ? null
                      : () => _setRememberPlacement(!_rememberPlacement!),
                  trailing: _switch(
                    _rememberPlacement ?? true,
                    _rememberPlacement == null ? null : _setRememberPlacement,
                  ),
                ),
                SettingsTile(
                  icon: Icons.home_outlined,
                  title: context.l10n.startPage,
                  subtitle: context.l10n.startPageSubtitle,
                  trailing: _value(_startPageText()),
                  onTap: _pickStartPage,
                ),
              ],
            ),
            SettingsSectionLabel(context.l10n.settingsSectionNotifications),
            SettingsCard(
              children: [
                SettingsTile(
                  icon: Icons.notifications_none_rounded,
                  title: context.l10n.settingsSectionNotificationsSummary,
                  subtitle: context.l10n.newEpisodeAlertsWindowsSubtitle,
                  subtitleMaxLines: null,
                  onTap: () => DesktopPrefs.setNewEpisodeAlerts(
                    !DesktopPrefs.newEpisodeAlerts,
                  ),
                  trailing: _switch(
                    DesktopPrefs.newEpisodeAlerts,
                    DesktopPrefs.setNewEpisodeAlerts,
                  ),
                ),
              ],
            ),
            SettingsSectionLabel(context.l10n.profileLock),
            SettingsCard(
              children: [
                SettingsTile(
                  icon: Icons.timer_outlined,
                  title: context.l10n.autoLockAfterIdle,
                  subtitle: context.l10n.autoLockSubtitle,
                  subtitleMaxLines: null,
                  trailing: _value(
                    autoLockLabel(DesktopPrefs.autoLockIdleMinutes),
                  ),
                  onTap: _pickAutoLock,
                ),
                SettingsTile(
                  icon: Icons.lock_outline_rounded,
                  title: context.l10n.lockWhenWindowsLocks,
                  subtitle: context.l10n.lockWhenWindowsLocksSubtitle,
                  subtitleMaxLines: null,
                  onTap: () => DesktopPrefs.setLockWhenWindowsLocks(
                    !DesktopPrefs.lockWhenWindowsLocks,
                  ),
                  trailing: _switch(
                    DesktopPrefs.lockWhenWindowsLocks,
                    DesktopPrefs.setLockWhenWindowsLocks,
                  ),
                ),
              ],
            ),
            SettingsSectionLabel(context.l10n.keyboardSection),
            SettingsCard(
              children: [
                SettingsTile(
                  icon: Icons.keyboard_alt_outlined,
                  title: context.l10n.keyboardShortcuts,
                  subtitle: context.l10n.keyboardShortcutsSubtitle,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const KeyboardShortcutsScreen(),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
