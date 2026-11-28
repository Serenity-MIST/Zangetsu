/// Search index for settings that live *inside* a sub-page.
///
/// The entry list in `settings_screen.dart` only knows about the ~26 category
/// rows, so "Search settings" could only ever return a folder: typing
/// "autoplay" surfaced **Playback**, not the *Autoplay next episode* toggle,
/// and anything nobody had hand-typed into a `keywords` string (e.g. "anime4k")
/// returned "No settings match" despite being a real setting.
///
/// Each leaf names one row a sub-page renders. A search result built from it
/// shows the setting's own title with its category underneath, and opens the
/// page that owns it — [parentId] points at the category row supplying the icon
/// and the tap.
///
/// **Titles are read through [AppLocalizations], not stored as text**, so the
/// results are in the reader's language and a search in that language matches.
/// Referencing the getter also means a renamed ARB key fails to compile rather
/// than silently dropping a setting out of search.
///
/// `settings_search_index_test.dart` reads the sub-page sources and fails when
/// a rendered setting isn't indexed, so this can't quietly rot.
library;

import 'package:flutter/foundation.dart';

import '../../core/desktop/desktop_storage.dart';
import '../../core/desktop/extension_runtime.dart';
import '../../l10n/app_localizations.dart';

/// Category rows that own a sub-page with searchable settings inside.
abstract final class LeafParent {
  static const playback = 'playback';
  static const reader = 'reader';
  static const appearance = 'appearance';
  static const privacy = 'privacy';
  static const storage = 'storage';
  static const downloads = 'downloads';

  /// The Windows Home rows editor row. Only the Windows-only home rows leaf
  /// points here; phone and TV reach Home rows through its own category row.
  static const homeRows = 'homeRows';

  /// The Download location page. Only Windows search points leaves here (via
  /// [SettingsLeaf.windowsParentId]); the Settings row with this id must
  /// exist on Windows, or those leaves are left out of results.
  static const downloadLocation = 'downloadLocation';

  /// Windows-only 'Window & system' page. Leaves reach it through
  /// [SettingsLeaf.windowsParentId]; phone never shows them.
  static const windowSystem = 'windowSystem';

  /// Windows-only Keyboard shortcuts page.
  static const keyboardShortcuts = 'keyboardShortcuts';
}

/// True on the Windows desktop build. Read through [defaultTargetPlatform] so
/// tests can flip it with `debugDefaultTargetPlatformOverride`.
bool _onWindows() => defaultTargetPlatform == TargetPlatform.windows;

/// Leaf predicate: the owning page hides this row on Windows, so Windows
/// search must not offer it either.
bool _hiddenOnWindows() => !_onWindows();

/// Leaf predicate for the Aniyomi NSFW row: Windows shows it only when the
/// bundled extension engine exists, because without it there are no Aniyomi
/// sources for the switch to affect. The Privacy page uses the same check.
bool aniyomiNsfwRowVisible() =>
    !_onWindows() || DesktopExtensionRuntime.isAvailable;

/// Leaf predicate for rows that only the Windows page renders (desktop-only
/// rows, or rows Windows names differently from phone).
bool _windowsOnly() => _onWindows();

/// Storage's "Open app data folder" row: Windows, once the desktop data
/// folder is known (the page hides the row while it is null).
bool _appDataRowVisible() => _onWindows() && DesktopStorage.root != null;

/// Spaces and hyphens, folded to one space before matching so "auto play"
/// finds "Auto-play".
final _spacing = RegExp(r'[\s-]+');

/// True when [query] matches [text]. [query] is already lower-cased.
///
/// By default the whole query must appear as one piece, after spaces and
/// hyphens are folded on both sides (how phone and TV search match). With
/// [allWords] (Windows) every word of [query] must appear somewhere in
/// [text], in any order ('intro skip' finds 'Skip intro').
bool settingsQueryMatches(String text, String query, {bool allWords = false}) {
  final haystack = text.toLowerCase().replaceAll(_spacing, ' ');
  if (!allWords) return haystack.contains(query.replaceAll(_spacing, ' '));
  final words = query.split(_spacing).where((w) => w.isNotEmpty);
  return words.every(haystack.contains);
}

/// One setting row rendered inside a settings sub-page, as search sees it.
class SettingsLeaf {
  const SettingsLeaf(
    this._parentId,
    this.title, {
    this.id,
    this.keywords = '',
    this.windowsKeywords = '',
    this.windowsParentId,
    this.visible,
  });

  /// Optional stable id of the row this leaf names. Windows search passes it
  /// (with the title) to the page, which scrolls that row into view, flashes
  /// it and focuses it. Needed only when the row's label differs from
  /// [title]; rows are otherwise found by their title.
  final String? id;

  final String _parentId;

  /// Which category row opens the page holding this setting. On Windows a
  /// [windowsParentId] wins, for rows that live on a different page there.
  String get parentId => (_onWindows() ? windowsParentId : null) ?? _parentId;

  /// Category row that opens the page holding this row on Windows, when it
  /// differs from the phone one. Null means the same page everywhere.
  final String? windowsParentId;

  /// The row's label, read from the active translations.
  final String Function(AppLocalizations) title;

  /// Extra terms that never render — synonyms and abbreviations people type
  /// instead of the label ("pip", "op", "subs"). English only: they widen an
  /// English search, while the localized [title] carries every other language.
  final String keywords;

  /// Extra terms matched only on Windows, for words that describe the desktop
  /// version of the row (keys, windows, File Explorer). Phone search ignores
  /// them, so its results stay as they were.
  final String windowsKeywords;

  /// Whether the owning page renders this row on the current platform. Null
  /// means always. Search drops a leaf whose row is hidden, so a result never
  /// opens a page that does not show the setting it named.
  final bool Function()? visible;

  /// Evaluated at search time rather than cached, so runtime state such as the
  /// Windows extension engine being installed is honoured.
  bool get isVisible => visible?.call() ?? true;

  /// [allWords]: match each word of [q] anywhere, in any order (Windows).
  bool matches(String q, AppLocalizations l10n, {bool allWords = false}) =>
      settingsQueryMatches(
        _onWindows() && windowsKeywords.isNotEmpty
            ? '${title(l10n)} $keywords $windowsKeywords'
            : '${title(l10n)} $keywords',
        q,
        allWords: allWords,
      );
}

/// Every setting reachable one level below the category rows.
final settingsLeaves = <SettingsLeaf>[
  // Playback → PlaybackSettingsScreen
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.defaultQuality,
    keywords: 'resolution 1080p 720p',
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.defaultAudio,
    keywords: 'sub dub language',
    visible: _hiddenOnWindows,
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.defaultAudioAnimeSubDub,
    keywords: 'sub dub',
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.defaultSpeed,
    keywords: 'playback rate faster',
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.videoDecoder,
    keywords: 'hardware software codec',
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.videoRenderer,
    keywords: 'output gpu vulkan',
    visible: _hiddenOnWindows,
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.anime4kEnhancement,
    keywords: 'upscale shader glsl anime4k',
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.anime4kGPUTier,
    keywords: 'upscale shader quality anime4k',
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.defaultPlayer,
    keywords: 'external mpv android native vlc',
    visible: _hiddenOnWindows,
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.playerControls,
    keywords: 'buttons reorder hide bar',
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.resumePlayback,
    keywords: 'continue where left off',
  ),
  // TV native player's on-screen seek buttons (and how far each press jumps).
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.seekButton,
    keywords: 'tv remote skip jump interval',
    visible: _hiddenOnWindows,
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.seekButtonDuration,
    keywords: 'tv remote skip jump seconds',
    // Windows: the step used by the arrow keys, J / L and mouse buttons.
    windowsKeywords: 'arrow keys keyboard j l mouse forward back step',
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.askBeforeJumping,
    keywords: 'confirm resume',
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.autoAddToMyList,
    keywords: 'library watchlist',
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.autoTrack,
    keywords: 'scrobble anilist mal simkl',
  ),
  // Auto Paused/Dropped rows. Hard-coded English titles matching the
  // Windows-only rows in settings_playback.dart; indexed for Windows only.
  SettingsLeaf(
    LeafParent.playback,
    (_) => 'Auto-pause idle titles',
    keywords: 'my list library paused dropped idle inactive on hold status',
    windowsKeywords: 'anilist mal simkl tracker',
    visible: _windowsOnly,
  ),
  SettingsLeaf(
    LeafParent.playback,
    (_) => 'Move to Paused after',
    keywords: 'my list idle days paused on hold inactive',
    visible: _windowsOnly,
  ),
  SettingsLeaf(
    LeafParent.playback,
    (_) => 'Move to Dropped after',
    keywords: 'my list idle days dropped inactive',
    visible: _windowsOnly,
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.closeConfirmation,
    keywords: 'exit confirm',
  ),
  // Windows-only Playback behaviour row.
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.playDownloadedCopyIfFails,
    keywords: 'offline local download fallback stream fails',
    visible: _windowsOnly,
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.autoplayNextEpisode,
    keywords: 'auto play continue',
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.autoSkipFillerEpisodes,
    keywords: 'filler tenrai',
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.autoplayTrailer,
    keywords: 'auto play preview detail',
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.playTrailersInHD,
    keywords: 'trailer 1080p quality',
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.skipIntroButton,
    keywords: 'opening op ending ed',
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.autoSkipOpening,
    keywords: 'op intro',
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.autoSkipRecap,
    keywords: 'previously on',
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.autoSkipEnding,
    keywords: 'ed outro credits',
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.megaskipButton,
    keywords: 'jump forward megaskip',
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.megaSkipDuration,
    keywords: 'jump forward seconds megaskip',
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.keepScreenOn,
    keywords: 'wakelock awake display',
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.nativeTVPlayer,
    keywords: 'exoplayer tv android',
    visible: _hiddenOnWindows,
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.softwareAudioDolbyDTS,
    keywords: 'passthrough ac3 dolby dts',
    visible: _hiddenOnWindows,
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.inAppMiniPlayer,
    keywords: 'minimize dock pinch resize',
    visible: _hiddenOnWindows,
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.autoPictureInPicture,
    keywords: 'pip floating window',
    visible: _hiddenOnWindows,
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.playerInfoOverlay,
    keywords: 'stats debug hud',
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.showQualityLabel,
    keywords: 'resolution badge 1080p',
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.orientationLock,
    keywords: 'rotate portrait landscape default player',
    visible: _hiddenOnWindows,
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.doubleTapSkip,
    keywords: 'seek seconds gesture',
    visible: _hiddenOnWindows,
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.gestureControls,
    keywords: 'swipe brightness volume',
    visible: _hiddenOnWindows,
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.swipeToSeek,
    keywords: 'drag scrub gesture',
    visible: _hiddenOnWindows,
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.holdFor2Speed,
    keywords: 'long press fast 2x',
    visible: _hiddenOnWindows,
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.videoBufferSize,
    keywords: 'cache memory mb',
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.videoBufferLength,
    keywords: 'cache seconds',
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.clearImageVideoCache,
    keywords: 'storage free space',
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.styledSubtitlesLibass,
    keywords: 'ass ssa styling subs libass',
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.subtitleStyle,
    keywords: 'subs font colour outline size',
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.subtitleLanguage,
    keywords: 'subs preferred language',
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.opensubtitlesAPIKey,
    keywords: 'subs download account opensubtitles',
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.autoDownloadSubtitles,
    keywords: 'subs opensubtitles',
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.autoTranslateSubtitles,
    keywords: 'subs translate google',
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.translateSubtitlesTo,
    keywords: 'subs language translate',
  ),

  SettingsLeaf(
    LeafParent.playback,
    (l) => l.tvDecoderMode,
    visible: _hiddenOnWindows,
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.autoPlayerFallback,
    visible: _hiddenOnWindows,
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.portraitVideoEdgeToEdge,
    keywords: 'portrait video full width mini player',
    visible: _hiddenOnWindows,
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.ambientPlayer,
    keywords: 'glow portrait',
    visible: _hiddenOnWindows,
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.androidPlayerCache,
    visible: _hiddenOnWindows,
  ),

  // Reading → ReaderSettingsScreen
  SettingsLeaf(
    LeafParent.reader,
    (l) => l.readingMode,
    keywords: 'manga direction webtoon',
  ),
  SettingsLeaf(
    LeafParent.reader,
    (l) => l.fit,
    keywords: 'width height page scale',
  ),
  SettingsLeaf(
    LeafParent.reader,
    (l) => l.cropBorders,
    keywords: 'trim margins whitespace',
  ),
  SettingsLeaf(
    LeafParent.reader,
    (l) => l.doublePageLandscape,
    keywords: 'spread facing pages',
  ),
  SettingsLeaf(
    LeafParent.reader,
    (l) => l.preloadPages,
    keywords: 'ahead buffer manga',
  ),
  SettingsLeaf(
    LeafParent.reader,
    (l) => l.tapZones,
    keywords: 'tapping regions navigation',
    visible: _hiddenOnWindows,
  ),
  SettingsLeaf(
    LeafParent.reader,
    (l) => l.orientationLock,
    keywords: 'rotate portrait landscape',
    visible: _hiddenOnWindows,
  ),
  SettingsLeaf(
    LeafParent.reader,
    (l) => l.keepScreenOn,
    keywords: 'wakelock awake display',
  ),
  SettingsLeaf(
    LeafParent.reader,
    (l) => l.readerFullscreen,
    keywords: 'immersive hide status navigation bars',
    // Windows opens the readers borderless; Esc leaves and F11 toggles.
    windowsKeywords: 'borderless full screen f11 esc window',
  ),
  SettingsLeaf(
    LeafParent.reader,
    (l) => l.background,
    keywords: 'colour theme page',
  ),
  SettingsLeaf(
    LeafParent.reader,
    (l) => l.colourFilter,
    keywords: 'tint warmth night',
  ),
  SettingsLeaf(
    LeafParent.reader,
    (l) => l.theme,
    keywords: 'novel colour sepia dark',
  ),
  SettingsLeaf(
    LeafParent.reader,
    (l) => l.font,
    keywords: 'novel typeface family',
  ),
  SettingsLeaf(
    LeafParent.reader,
    (l) => l.fontSize,
    keywords: 'novel text bigger smaller',
  ),
  SettingsLeaf(
    LeafParent.reader,
    (l) => l.lineHeight,
    keywords: 'novel leading spacing',
  ),
  SettingsLeaf(
    LeafParent.reader,
    (l) => l.paragraphSpacing,
    keywords: 'novel gap',
  ),
  SettingsLeaf(
    LeafParent.reader,
    (l) => l.margin,
    keywords: 'novel padding edge',
  ),
  SettingsLeaf(
    LeafParent.reader,
    (l) => l.justifyText,
    keywords: 'novel align',
  ),
  SettingsLeaf(
    LeafParent.reader,
    (l) => l.textDirection,
    keywords: 'novel rtl ltr',
  ),
  SettingsLeaf(
    LeafParent.reader,
    (l) => l.paginated,
    keywords: 'novel pages scroll book',
  ),

  SettingsLeaf(LeafParent.reader, (l) => l.showPageNumber),
  SettingsLeaf(
    LeafParent.reader,
    (l) => l.mangaTranslationSettings,
    visible: _hiddenOnWindows,
  ),
  SettingsLeaf(
    LeafParent.reader,
    (l) => l.mangaTranslationAppearance,
    visible: _hiddenOnWindows,
  ),

  // Interface → AppearanceScreen
  SettingsLeaf(LeafParent.appearance, (l) => l.customColour),
  SettingsLeaf(
    LeafParent.appearance,
    (l) => l.materialYou,
    keywords: 'wallpaper colours dynamic theme',
    visible: _hiddenOnWindows,
  ),
  SettingsLeaf(
    LeafParent.appearance,
    (l) => l.pureBlackBackground,
    keywords: 'oled amoled dark',
  ),
  SettingsLeaf(
    LeafParent.appearance,
    (_) => 'Adaptive colour',
    keywords: 'poster background tint color theme',
  ),
  // Theme & colour rows only the Windows page renders, indexed for Windows
  // only so phone search results stay unchanged.
  SettingsLeaf(
    LeafParent.appearance,
    (l) => l.appBackgroundColour,
    keywords: 'background color tint dark theme',
    visible: _windowsOnly,
  ),
  SettingsLeaf(
    LeafParent.appearance,
    (l) => l.titleLogoOnDetail,
    keywords: 'title artwork logo detail page text',
    visible: _windowsOnly,
  ),
  SettingsLeaf(
    LeafParent.appearance,
    (l) => l.appFont,
    keywords: 'font typeface text family',
    visible: _windowsOnly,
  ),
  SettingsLeaf(
    LeafParent.appearance,
    (l) => l.reverseEpisodeListAlwaysOn,
    keywords: 'episodes newest first order reverse descending',
    visible: _windowsOnly,
  ),
  SettingsLeaf(
    LeafParent.appearance,
    (l) => l.animateLists,
    keywords: 'fade scroll animation',
  ),
  SettingsLeaf(
    LeafParent.appearance,
    (l) => l.animationStyle,
    keywords: 'transition motion',
  ),
  // Windows: Home rows is its own row in the Settings sidebar.
  SettingsLeaf(
    LeafParent.homeRows,
    (l) => l.homeRows,
    keywords:
        'home screen rows reorder hide customize arrangement sections '
        'discover tracker continue watching',
    visible: _windowsOnly,
  ),

  // Advanced → PrivacySettingsScreen
  SettingsLeaf(
    LeafParent.privacy,
    (l) => l.incognitoMode,
    keywords: 'private pause history tracking',
  ),
  SettingsLeaf(
    LeafParent.privacy,
    (l) => l.showNSFWSources,
    keywords: 'adult 18+ nsfw',
    visible: aniyomiNsfwRowVisible,
  ),
  SettingsLeaf(
    LeafParent.privacy,
    (l) => l.enableNSFWSources2,
    keywords: 'adult 18+ nsfw aniyomi',
  ),
  SettingsLeaf(
    LeafParent.privacy,
    (l) => l.adultCatalogue,
    keywords: 'adult 18+ nsfw anilist mal tmdb catalogue hentai',
  ),
  SettingsLeaf(
    LeafParent.privacy,
    (l) => l.enableAdultCatalogue,
    keywords: 'adult 18+ nsfw catalogue confirm show titles',
    visible: _hiddenOnWindows,
  ),
  SettingsLeaf(
    LeafParent.privacy,
    (l) => l.enableNSFWSources,
    keywords: 'adult 18+ nsfw sources confirm enable',
    visible: _hiddenOnWindows,
  ),
  SettingsLeaf(
    LeafParent.privacy,
    (l) => l.showNSFWAniyomiSources,
    keywords: 'adult 18+ nsfw aniyomi confirm show',
    visible: _hiddenOnWindows,
  ),

  // Downloads → StorageSettingsScreen
  SettingsLeaf(
    LeafParent.storage,
    (l) => l.clearImageCache,
    keywords: 'free space covers',
  ),
  SettingsLeaf(
    LeafParent.storage,
    (l) => l.clearProviderCache,
    keywords: 'free space js sources',
  ),
  // Windows-only Storage row.
  SettingsLeaf(
    LeafParent.storage,
    (l) => l.openAppDataFolder,
    keywords: 'appdata data folder file explorer location settings database',
    visible: _appDataRowVisible,
  ),

  // Downloads → DownloadLocationScreen
  SettingsLeaf(
    LeafParent.downloads,
    (l) => l.chooseFolder,
    keywords: 'location saf path storage',
    windowsKeywords: 'download location drive directory browse',
    windowsParentId: LeafParent.downloadLocation,
  ),
  SettingsLeaf(
    LeafParent.downloads,
    (l) => l.resetToDefault,
    keywords: 'location folder path',
    windowsKeywords: 'download location default folder',
    windowsParentId: LeafParent.downloadLocation,
  ),
  // Windows-only Download location row.
  SettingsLeaf(
    LeafParent.downloads,
    (l) => l.openInFileExplorer,
    keywords: 'download location folder show reveal explorer',
    windowsParentId: LeafParent.downloadLocation,
    visible: _windowsOnly,
  ),
  SettingsLeaf(
    LeafParent.downloads,
    (l) => l.keepDownloadsPrivate,
    keywords: 'private hidden app storage downloads folder',
    visible: _hiddenOnWindows,
  ),
  // Windows-only rows on the Reader and Playback pages.
  SettingsLeaf(
    LeafParent.reader,
    (l) => l.clickToTurnPages,
    keywords: 'mouse click side page turn left right back forward',
    visible: _windowsOnly,
  ),
  SettingsLeaf(
    LeafParent.reader,
    (l) => l.clickZones,
    keywords: 'mouse click areas layout tap zones',
    visible: _windowsOnly,
  ),
  SettingsLeaf(
    LeafParent.playback,
    (l) => l.cacheAndStorage,
    keywords: 'cache storage clear size disk',
    visible: _windowsOnly,
  ),
  // Windows-only 'Window & system' and Keyboard shortcuts pages. The phone
  // parent is never used (the leaves are hidden off Windows) but must name a
  // real category.
  ..._windowSystemLeaves,
];

/// Leaf on a Windows-only page: phone parent Privacy (same Advanced
/// section, never shown off Windows), Windows parent [windowsParent].
SettingsLeaf _windowsLeaf(
  String windowsParent,
  String Function(AppLocalizations) title, {
  String keywords = '',
}) => SettingsLeaf(
  LeafParent.privacy,
  title,
  keywords: keywords,
  windowsParentId: windowsParent,
  visible: _windowsOnly,
);

/// Rows rendered by window_system_settings_screen.dart and
/// keyboard_shortcuts_screen.dart (same translation keys as those pages).
final _windowSystemLeaves = <SettingsLeaf>[
  _windowsLeaf(
    LeafParent.windowSystem,
    (l) => l.launchAtSignIn,
    keywords: 'startup start with windows boot autostart login',
  ),
  _windowsLeaf(
    LeafParent.windowSystem,
    (l) => l.closeButton,
    keywords: 'close tray minimise minimize quit exit background x',
  ),
  _windowsLeaf(
    LeafParent.windowSystem,
    (l) => l.rememberWindowSizePosition,
    keywords: 'window placement monitor restore maximised maximized',
  ),
  _windowsLeaf(
    LeafParent.windowSystem,
    (l) => l.startPage,
    keywords: 'open launch first page home default tab last used',
  ),
  _windowsLeaf(
    LeafParent.windowSystem,
    (l) => l.settingsSectionNotificationsSummary,
    keywords: 'notifications new episode chapter alert toast',
  ),
  _windowsLeaf(
    LeafParent.windowSystem,
    (l) => l.autoLockAfterIdle,
    keywords: 'profile lock pin idle timeout away',
  ),
  _windowsLeaf(
    LeafParent.windowSystem,
    (l) => l.lockWhenWindowsLocks,
    keywords: 'profile lock pin win+l session screen',
  ),
  _windowsLeaf(
    LeafParent.keyboardShortcuts,
    (l) => l.resetAll,
    keywords: 'keyboard shortcuts keys default restore remap',
  ),
];
