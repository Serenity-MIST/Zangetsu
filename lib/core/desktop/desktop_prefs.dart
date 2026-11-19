import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../hive/safe_box.dart';
import 'desktop_shortcut_catalog.dart';
import 'desktop_shortcuts.dart';

/// What the window's close button (X, Alt+F4, taskbar Close) does.
/// Stored as [Enum.name] under `close_behaviour`; the native close guard
/// reads that raw string, so the names must never change.
enum DesktopCloseBehaviour {
  /// Ask when downloads are running, otherwise quit.
  ask,

  /// Hide to the tray while downloads are running, otherwise quit.
  trayWhileDownloading,

  /// Always hide to the tray; quitting is done from the tray menu.
  alwaysTray,

  /// Always quit straight away.
  quit,
}

/// The page the Windows shell opens on launch.
enum DesktopStartPage { home, myList, sources, downloads, schedule, history, lastUsed }

/// How often the automatic backup runs.
enum AutoBackupFrequency { daily, weekly }

/// Windows desktop preferences that have no phone equivalent: window and
/// tray behaviour, start page, desktop notifications, automatic backups and
/// profile auto-lock. One Hive box so the native side and later features can
/// read a single place.
///
/// Every getter falls back to its default when the box is not open, so
/// widget tests (and phone builds that never read these) need no setup.
abstract final class DesktopPrefs {
  static const boxName = 'desktop_prefs';

  // Raw keys. `close_behaviour` and `shortcut_overrides` are also read by
  // other code without importing this file, so keep them stable.
  static const closeBehaviourKey = 'close_behaviour';
  static const shortcutOverridesKey = 'shortcut_overrides';
  static const _startPageKey = 'start_page';
  static const _lastPageKey = 'last_page';
  static const _sidebarExpandedKey = 'sidebar_expanded';
  static const _lastSettingsSectionKey = 'last_settings_section';
  static const _downloadNotificationsKey = 'download_notifications';
  static const _taskbarProgressKey = 'taskbar_progress';
  static const _newEpisodeAlertsKey = 'new_episode_alerts';
  static const _autoBackupEnabledKey = 'auto_backup_enabled';
  static const _autoBackupFolderKey = 'auto_backup_folder';
  static const _autoBackupFrequencyKey = 'auto_backup_frequency';
  static const _autoBackupKeepKey = 'auto_backup_keep';
  static const _autoBackupLastRunKey = 'auto_backup_last_run';
  static const _autoLockIdleMinutesKey = 'auto_lock_idle_minutes';
  static const _lockWhenWindowsLocksKey = 'lock_when_windows_locks';
  static const _discordOnlyWhileWatchingKey = 'discord_only_while_watching';

  /// Choices the "Keep last" picker offers for automatic backups.
  static const autoBackupKeepChoices = [3, 5, 10, 20];

  /// Choices (minutes, 0 = off) the profile auto-lock picker offers.
  static const autoLockChoices = [0, 5, 10, 15, 30, 60];

  /// Opens the box, then registers the shortcut catalogue and loads any
  /// remapped keys, so shortcuts are ready before the first frame.
  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) await openBoxSafely<dynamic>(boxName);
    registerDefaultDesktopShortcuts();
    DesktopShortcuts.loadOverrides();
  }

  /// The open box, or null in tests / before [init].
  static Box<dynamic>? get _box =>
      Hive.isBoxOpen(boxName) ? Hive.box<dynamic>(boxName) : null;

  /// Rebuild trigger for settings pages. Before [init] it is a never-firing
  /// notifier so callers can listen unconditionally. Prefer
  /// `ListenableBuilder(listenable: DesktopPrefs.listenable(), ...)` (or
  /// [changes]): its value has no box to return before [init].
  static ValueListenable<Box<dynamic>> listenable() {
    final box = _box;
    if (box != null) return box.listenable();
    return _ClosedBoxListenable();
  }

  /// Same as [listenable] typed as a plain [Listenable], safe in tests.
  static Listenable get changes => listenable();

  // Typed reads with defaults; a wrong type (corrupt value) also falls back.
  static T _get<T>(String key, T fallback) {
    final value = _box?.get(key);
    return value is T ? value : fallback;
  }

  // Writes are dropped silently when the box is closed (tests).
  static Future<void> _put(String key, Object? value) async {
    final box = _box;
    if (box == null) return;
    if (value == null) {
      await box.delete(key);
    } else {
      await box.put(key, value);
    }
  }

  // Enum read by name, defaulting when the stored name is unknown.
  static E _enum<E extends Enum>(String key, List<E> values, E fallback) {
    final name = _get<String?>(key, null);
    for (final v in values) {
      if (v.name == name) return v;
    }
    return fallback;
  }

  /// Raw read for sibling helpers (the shortcut overrides map).
  static Object? readRaw(String key) => _box?.get(key);

  /// Raw write for sibling helpers; null deletes the key.
  static Future<void> writeRaw(String key, Object? value) => _put(key, value);

  // ---- Window & system ----------------------------------------------------

  static DesktopCloseBehaviour get closeBehaviour => _enum(
    closeBehaviourKey,
    DesktopCloseBehaviour.values,
    DesktopCloseBehaviour.ask,
  );
  static Future<void> setCloseBehaviour(DesktopCloseBehaviour v) =>
      _put(closeBehaviourKey, v.name);

  static DesktopStartPage get startPage =>
      _enum(_startPageKey, DesktopStartPage.values, DesktopStartPage.home);
  static Future<void> setStartPage(DesktopStartPage v) =>
      _put(_startPageKey, v.name);

  /// Last page the shell showed; used when [startPage] is lastUsed.
  static String? get lastPage => _get<String?>(_lastPageKey, null);
  static Future<void> setLastPage(String id) => _put(_lastPageKey, id);

  /// Whether the desktop sidebar is expanded (labels shown).
  static bool get sidebarExpanded => _get(_sidebarExpandedKey, false);
  static Future<void> setSidebarExpanded(bool v) =>
      _put(_sidebarExpandedKey, v);

  /// Settings section reopened when Settings is opened again.
  static String? get lastSettingsSection =>
      _get<String?>(_lastSettingsSectionKey, null);
  static Future<void> setLastSettingsSection(String id) =>
      _put(_lastSettingsSectionKey, id);

  // ---- Downloads (dl-11) --------------------------------------------------

  /// Windows notification when a download batch finishes or fails.
  static bool get downloadNotifications =>
      _get(_downloadNotificationsKey, true);
  static Future<void> setDownloadNotifications(bool v) =>
      _put(_downloadNotificationsKey, v);

  /// Overall download progress on the taskbar button.
  static bool get taskbarProgress => _get(_taskbarProgressKey, true);
  static Future<void> setTaskbarProgress(bool v) =>
      _put(_taskbarProgressKey, v);

  // ---- New episodes (track-1) ---------------------------------------------

  /// Windows alert when a followed show gets a new episode or chapter.
  static bool get newEpisodeAlerts => _get(_newEpisodeAlertsKey, true);
  static Future<void> setNewEpisodeAlerts(bool v) =>
      _put(_newEpisodeAlertsKey, v);

  // ---- Automatic backups (acct-10) ----------------------------------------

  static bool get autoBackupEnabled => _get(_autoBackupEnabledKey, false);
  static Future<void> setAutoBackupEnabled(bool v) =>
      _put(_autoBackupEnabledKey, v);

  /// Folder backups are written to; null means not chosen yet.
  static String? get autoBackupFolder =>
      _get<String?>(_autoBackupFolderKey, null);
  static Future<void> setAutoBackupFolder(String? v) =>
      _put(_autoBackupFolderKey, (v == null || v.isEmpty) ? null : v);

  static AutoBackupFrequency get autoBackupFrequency => _enum(
    _autoBackupFrequencyKey,
    AutoBackupFrequency.values,
    AutoBackupFrequency.weekly,
  );
  static Future<void> setAutoBackupFrequency(AutoBackupFrequency v) =>
      _put(_autoBackupFrequencyKey, v.name);

  /// How many automatic backups are kept; older ones are pruned.
  static int get autoBackupKeep {
    final v = _get(_autoBackupKeepKey, 5);
    return v < 1 ? 5 : v;
  }

  static Future<void> setAutoBackupKeep(int v) =>
      _put(_autoBackupKeepKey, v < 1 ? 1 : v);

  /// When the last automatic backup finished (stored as epoch ms).
  static DateTime? get autoBackupLastRun {
    final ms = _get<int?>(_autoBackupLastRunKey, null);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  static Future<void> setAutoBackupLastRun(DateTime v) =>
      _put(_autoBackupLastRunKey, v.millisecondsSinceEpoch);

  // ---- Profile lock (acct-11) ---------------------------------------------

  /// Minutes of no input before the profile locks again; 0 = off.
  static int get autoLockIdleMinutes {
    final v = _get(_autoLockIdleMinutesKey, 0);
    return v < 0 ? 0 : v;
  }

  static Future<void> setAutoLockIdleMinutes(int v) =>
      _put(_autoLockIdleMinutesKey, v < 0 ? 0 : v);

  /// Lock the profile when the Windows session locks (Win+L).
  static bool get lockWhenWindowsLocks =>
      _get(_lockWhenWindowsLocksKey, false);
  static Future<void> setLockWhenWindowsLocks(bool v) =>
      _put(_lockWhenWindowsLocksKey, v);

  // ---- Discord (track-12) -------------------------------------------------

  /// Show Discord presence only while something is playing.
  static bool get discordOnlyWhileWatching =>
      _get(_discordOnlyWhileWatchingKey, false);
  static Future<void> setDiscordOnlyWhileWatching(bool v) =>
      _put(_discordOnlyWhileWatchingKey, v);
}

/// Stand-in listenable used before the box is open: it never notifies and
/// has no box value, which is fine because getters return defaults then.
class _ClosedBoxListenable implements ValueListenable<Box<dynamic>> {
  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}

  @override
  Box<dynamic> get value =>
      throw StateError('${DesktopPrefs.boxName} is not open');
}
