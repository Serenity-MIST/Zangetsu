import '../../l10n/l10n.dart';
import 'desktop_shortcuts.dart';

/// Translated name of a Windows shortcut for the Keyboard shortcuts page,
/// the help overlay and menus. The catalog registers English labels at
/// startup (before the app language is known, and they must not change when
/// it does), so the text is translated here by the stable shortcut id.
/// Unknown ids (a shortcut added without a translation) show the English.
String desktopShortcutLabel(AppLocalizations l10n, DesktopShortcutSpec spec) {
  final id = spec.id;
  // Numbered families: app.section1-9, app.mode1-4, show.tab1-4.
  final numbered = RegExp(r'^(app\.section|app\.mode|show\.tab)(\d)$').firstMatch(id);
  if (numbered != null) {
    final n = int.parse(numbered.group(2)!);
    return switch (numbered.group(1)) {
      'app.section' => l10n.shortcutAppSection(n),
      'app.mode' => l10n.shortcutAppMode(n),
      _ => l10n.shortcutShowTab(n),
    };
  }
  return switch (id) {
    'app.search' => l10n.search,
    'app.settings' => l10n.shortcutAppSettings,
    // Reuses the translated "History" page title (no dedicated key).
    'app.history' => l10n.history,
    'app.back' => l10n.shortcutAppBack,
    'app.fullscreen' => l10n.shortcutAppFullscreen,
    'app.help' => l10n.shortcutAppHelp,
    'app.lockProfile' => l10n.shortcutAppLockProfile,
    'app.refresh' => l10n.refresh,
    'app.contextMenu' => l10n.shortcutAppContextMenu,
    'home.first' => l10n.shortcutHomeFirst,
    'home.last' => l10n.shortcutHomeLast,
    'home.open' => l10n.shortcutHomeOpen,
    'show.play' => l10n.shortcutShowPlay,
    'show.download' => l10n.shortcutShowDownload,
    'show.refreshEpisodes' => l10n.refreshEpisodes,
    'show.filter' => l10n.shortcutShowFilter,
    'show.selectAll' => l10n.shortcutShowSelectAll,
    'show.clearSelection' => l10n.shortcutShowClearSelection,
    'player.playPause' => l10n.shortcutPlayerPlayPause,
    'player.seekBack' => l10n.shortcutPlayerSeekBack,
    'player.seekForward' => l10n.shortcutPlayerSeekForward,
    'player.seekBackLong' => l10n.shortcutPlayerSeekBackLong,
    'player.seekForwardLong' => l10n.shortcutPlayerSeekForwardLong,
    'player.volumeUp' => l10n.shortcutPlayerVolumeUp,
    'player.volumeDown' => l10n.shortcutPlayerVolumeDown,
    'player.mute' => l10n.shortcutPlayerMute,
    'player.fullscreen' => l10n.shortcutAppFullscreen,
    'player.theatre' => l10n.theatreMode,
    'player.exit' => l10n.shortcutPlayerExit,
    'player.nextEpisode' => l10n.nextEpisode2,
    'player.previousEpisode' => l10n.previousEpisode,
    'player.skip' => l10n.shortcutPlayerSkip,
    'player.speedDown' => l10n.shortcutPlayerSpeedDown,
    'player.speedUp' => l10n.shortcutPlayerSpeedUp,
    'player.subtitles' => l10n.shortcutPlayerSubtitles,
    'player.jumpPercent' => l10n.shortcutPlayerJumpPercent,
    'player.frameBack' => l10n.shortcutPlayerFrameBack,
    'player.frameForward' => l10n.shortcutPlayerFrameForward,
    'player.subDelayDown' => l10n.shortcutPlayerSubDelayDown,
    'player.subDelayUp' => l10n.shortcutPlayerSubDelayUp,
    'player.miniPlayer' => l10n.shortcutPlayerMiniPlayer,
    'player.alwaysOnTop' => l10n.shortcutPlayerAlwaysOnTop,
    'player.help' => l10n.shortcutAppHelp,
    'reader.nextPage' => l10n.shortcutReaderNextPage,
    'reader.previousPage' => l10n.shortcutReaderPreviousPage,
    'reader.firstPage' => l10n.shortcutReaderFirstPage,
    'reader.lastPage' => l10n.shortcutReaderLastPage,
    'reader.nextChapter' => l10n.nextChapter,
    'reader.previousChapter' => l10n.previousChapter,
    'reader.chapterList' => l10n.shortcutReaderChapterList,
    'reader.settings' => l10n.readerSettings,
    'reader.autoScroll' => l10n.autoScroll,
    'reader.fullscreen' => l10n.shortcutAppFullscreen,
    'reader.toggleBars' => l10n.shortcutReaderToggleBars,
    'reader.back' => l10n.shortcutReaderBack,
    'reader.zoomIn' => l10n.shortcutReaderZoomIn,
    'reader.zoomOut' => l10n.shortcutReaderZoomOut,
    'reader.zoomReset' => l10n.shortcutReaderZoomReset,
    'reader.shiftSpread' => l10n.shortcutReaderShiftSpread,
    'reader.help' => l10n.shortcutAppHelp,
    'downloads.selectAll' => l10n.selectAll,
    'downloads.delete' => l10n.shortcutDownloadsDelete,
    'downloads.clearSelection' => l10n.shortcutShowClearSelection,
    'downloads.refresh' => l10n.refresh,
    'downloads.open' => l10n.shortcutDownloadsOpen,
    'lists.search' => l10n.shortcutListsSearch,
    'lists.refresh' => l10n.refresh,
    'lists.previousDay' => l10n.shortcutListsPreviousDay,
    'lists.nextDay' => l10n.shortcutListsNextDay,
    'lists.today' => l10n.relativeToday,
    'settings.search' => l10n.settingsSearchHint,
    'settings.nextSection' => l10n.shortcutSettingsNextSection,
    'settings.previousSection' => l10n.shortcutSettingsPreviousSection,
    _ => spec.label,
  };
}

/// Translated extra line under a shortcut (the English one when unknown).
String? desktopShortcutDescription(
  AppLocalizations l10n,
  DesktopShortcutSpec spec,
) => switch (spec.id) {
  'app.back' => l10n.shortcutAppBackDescription,
  'player.frameBack' || 'player.frameForward' =>
    l10n.shortcutWhilePaused,
  'lists.search' => l10n.shortcutListsSearchDescription,
  'lists.previousDay' || 'lists.nextDay' || 'lists.today' =>
    l10n.schedule,
  _ => spec.description,
};
