import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/ui/desktop_settings_surface.dart';
import 'package:flutter/services.dart';
import '../../core/desktop/desktop_chrome_colors.dart';
import '../../core/desktop/desktop_context_menu.dart';
import '../../core/desktop/desktop_shortcuts.dart';
import '../../core/desktop/desktop_undo_toast.dart';
import '../../core/reading/read_store.dart';
import '../home/desktop_continue_store.dart' show readEntryMarkedRead;

import '../../core/aniyomi/aniyomi_image_provider.dart';
import '../../core/di/injector.dart';
import '../../core/models/episode.dart';
import '../../core/models/media_detail.dart';
import '../../core/models/media_item.dart';
import '../../core/models/provider_info.dart';
import '../../core/playback/my_list.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/watch_history.dart';
import '../../core/reading/read_history.dart';
import '../../core/repository/catalogue_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../l10n/l10n.dart';
import '../../core/ui/app_dialog.dart';
import '../../core/ui/list_status_sheet.dart';
import '../../core/ui/media_info_sheet.dart';
import '../detail/detail_screen.dart';
import '../home/home_screen.dart' show readerFor;
import '../player/episode_player_route.dart';
import '../player/player_screen.dart';
import '../downloads/resume_downloaded.dart';

/// Full history, newest-first and grouped by day (Today / Yesterday / date),
/// split into three tabs: Anime (watch history, [WatchHistory]) and Manga /
/// Novel (reading history, [ReadHistory] filtered by [ReadEntry.type]). Tap a
/// row to resume, ✕ to remove one, and the toolbar to clear the active tab.
/// Every store is a per-title last-position pointer, so there's one row per
/// show/title.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, this.initialIndex = 0, this.showBack = true});

  /// False when shown as a dock tab — nothing to pop back to.
  final bool showBack;

  /// Which tab to open on: 0 Anime, 1 Manga, 2 Novel. Callers pass the current
  /// content mode's index (the [ContentMode] enum is ordered anime/manga/novel)
  /// so opening History from a reading mode lands on the matching tab.
  final int initialIndex;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen>
    with SingleTickerProviderStateMixin {
  final _watch = sl<WatchHistory>();
  final _read = sl<ReadHistory>();
  final _repo = sl<CatalogueRepository>();
  final _myList = sl<MyListStore>();

  late int _shownIndex = widget.initialIndex.clamp(0, 2);
  late final TabController _tab = TabController(
    length: 3,
    vsync: this,
    initialIndex: _shownIndex,
  )..addListener(_onTabChanged);

  /// Repaint so the "Clear all" action tracks the active tab — but only when
  /// the selected tab actually changes, not on every frame of the slide.
  void _onTabChanged() {
    if (_tab.index != _shownIndex && mounted) {
      setState(() => _shownIndex = _tab.index);
    }
  }

  late List<HistoryEntry> _anime = _watch.all();
  late List<ReadEntry> _manga = _readOf(ProviderType.manga);
  late List<ReadEntry> _novel = _readOf(ProviderType.novel);
  bool _loadingAnimeMore = false;
  bool _loadingMangaMore = false;
  bool _loadingNovelMore = false;

  List<ReadEntry> _readOf(ProviderType t) =>
      _read.all().where((e) => e.type == t).toList();

  void _reloadAnime() => setState(() => _anime = _watch.all());
  void _reloadReading() => setState(() {
    final all = _read.all();
    _manga = all.where((e) => e.type == ProviderType.manga).toList();
    _novel = all.where((e) => e.type == ProviderType.novel).toList();
  });

  Future<void> _loadMoreAnime() async {
    if (_loadingAnimeMore || !_watch.hasMoreCloudPages()) return;
    setState(() => _loadingAnimeMore = true);
    try {
      await _watch.loadMoreFromCloud();
      if (mounted) _reloadAnime();
    } finally {
      if (mounted) setState(() => _loadingAnimeMore = false);
    }
  }

  Future<void> _loadMoreReading(ProviderType type) async {
    final isManga = type == ProviderType.manga;
    final isLoading = isManga ? _loadingMangaMore : _loadingNovelMore;
    if (isLoading || !_read.hasMoreCloudPages(type)) return;
    setState(() {
      if (isManga) {
        _loadingMangaMore = true;
      } else {
        _loadingNovelMore = true;
      }
    });
    try {
      await _read.loadMoreFromCloud(type);
      if (mounted) _reloadReading();
    } finally {
      if (mounted) {
        setState(() {
          if (isManga) {
            _loadingMangaMore = false;
          } else {
            _loadingNovelMore = false;
          }
        });
      }
    }
  }

  @override
  void dispose() {
    _tab.dispose();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _pageFocus.dispose();
    super.dispose();
  }

  // ── Anime (watch history) ─────────────────────────────────────────────────

  MediaItem _stub(HistoryEntry e) => MediaItem(
    id: e.showId,
    title: e.showTitle,
    cover: e.cover,
    coverHeaders: e.coverHeaders,
    url: e.showUrl,
    type: ProviderType.anime,
    sourceId: e.sourceId,
  );

  Future<MediaDetail?> _detailOf(String url, String sourceId) async {
    try {
      return await _repo.detail(url, sourceId: sourceId);
    } catch (_) {
      return null;
    }
  }

  void _openDetail(MediaItem item) {
    Navigator.push(
      context,
      DetailScreen.route(item),
    ).then((_) => _reloadAnime());
  }

  /// Long-press info sheet — mirrors the Home Continue Watching card
  /// (Resume, progress, add-to-list, open detail, remove).
  void _showInfo(HistoryEntry e) {
    final stub = _stub(e);
    final pct = (e.progress * 100).round();
    showMediaInfoSheet(
      context,
      title: e.showTitle,
      cover: e.cover,
      headers: e.coverHeaders,
      detail: _detailOf(e.showUrl, e.sourceId),
      inMyList: _myList.contains(stub),
      playLabel: context.l10n.resume,
      progress: e.progress,
      progressLabel: e.episodeNumber != null
          ? context.l10n.episodeWatchedPct(e.episodeNumber!.toInt(), pct)
          : context.l10n.percentWatched(pct),
      onPlay: () => _resume(e),
      onOpenDetail: () => _openDetail(stub),
      onToggleMyList: () async {
        await showListStatusSheet(
          context,
          item: stub,
          onChanged: () {
            if (mounted) setState(() {});
          },
        );
        return _myList.contains(stub);
      },
      onRemoveFromContinue: () async {
        await _watch.remove(e.sourceId, e.showId);
        _reloadAnime();
      },
    );
  }

  Future<void> _resume(HistoryEntry e) async {
    // Windows: a downloaded episode resumes from the saved file (works
    // offline). Other platforms always return false here.
    final local = await resumeFromDownload(
      context,
      e,
      onlineEpisodes: () =>
          _repo.episodes(e.showUrl, category: e.category, sourceId: e.sourceId),
      onlineSources: (u) => _repo.sources(u, sourceId: e.sourceId, fast: true),
    );
    if (!mounted) return;
    if (!local) {
      await Navigator.push(
        context,
        episodePlayerRoute(
          nativeHandoff:
              Platform.isAndroid &&
              sl<PlaybackPrefs>().externalPlayerPackage ==
                  PlaybackPrefs.androidPlayerId,
          builder: (_) => PlayerScreen(
            sourceId: e.sourceId,
            episodesResolver: () => _repo.episodes(
              e.showUrl,
              category: e.category,
              sourceId: e.sourceId,
            ),
            resumeEpisodeId: e.episodeId,
            resumeEpisodeNumber: e.episodeNumber,
            resumePosition: e.position,
            resume: sl<ResumeStore>(),
            resolveSources: (u) =>
                _repo.sources(u, sourceId: e.sourceId, fast: true),
            history: _watch,
            showTitle: e.showTitle,
            cover: e.cover,
            coverHeaders: e.coverHeaders,
            showUrl: e.showUrl,
            category: e.category,
            malId: e.malId,
            scrobbleTitle: e.malId != null ? e.showTitle : null,
          ),
        ),
      );
    }
    _reloadAnime();
  }

  Future<void> _remove(HistoryEntry e) async {
    await _watch.remove(e.sourceId, e.showId);
    if (!mounted) return;
    _reloadAnime();
    // Windows (track-9): one click on X used to lose the resume point for
    // good. Undo puts the exact entry back (episode + position).
    if (_isWindows) {
      showUndoToast(
        context,
        message: context.l10n.removedFromHistory(e.showTitle),
        onUndo: () => unawaited(() async {
          await _watch.restore(e);
          if (mounted) _reloadAnime();
        }()),
      );
    }
  }

  /// Windows (track-10 C): marks the history row's episode as fully watched
  /// (it stays in History at 100% and leaves Continue watching).
  Future<void> _markFinished(HistoryEntry e) async {
    if (sl.isRegistered<ResumeStore>()) {
      await sl<ResumeStore>().setWatched(
        e.sourceId,
        e.showUrl,
        e.episodeId,
        watched: true,
      );
    }
    // A row with no known length still has to count as finished.
    final length = e.duration > Duration.zero
        ? e.duration
        : const Duration(milliseconds: 1);
    await _watch.save(
      HistoryEntry(
        sourceId: e.sourceId,
        showId: e.showId,
        showTitle: e.showTitle,
        cover: e.cover,
        coverHeaders: e.coverHeaders,
        thumbnail: e.thumbnail,
        showUrl: e.showUrl,
        category: e.category,
        episodeId: e.episodeId,
        episodeNumber: e.episodeNumber,
        episodeUrl: e.episodeUrl,
        position: length,
        duration: length,
        // Same time: marking does not move the row to the top of History.
        updatedAt: e.updatedAt,
        malId: e.malId,
      ),
      flush: true,
    );
    if (mounted) _reloadAnime();
  }

  /// Windows (track-10 C): the phone sheet's "My List" action — opens the
  /// status picker (add, change status, categories, remove).
  Future<void> _editListStatus(MediaItem item) => showListStatusSheet(
    context,
    item: item,
    onChanged: () {
      if (mounted) setState(() {});
    },
  );

  // ── Manga / Novel (reading history) ───────────────────────────────────────

  Future<void> _resumeRead(ReadEntry e) async {
    final l10n = context.l10n;
    final chapter = Episode(
      id: e.chapterId,
      title: e.chapterNumber != null
          ? l10n.chapterLabel(e.chapterNumber!.toInt())
          : l10n.chapter,
      number: e.chapterNumber,
      url: e.chapterUrl,
    );
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => readerFor(e, chapter)),
    );
    _reloadReading();
  }

  Future<void> _removeRead(ReadEntry e) async {
    await _read.remove(e.sourceId, e.showId);
    if (!mounted) return;
    _reloadReading();
    // Windows (track-9): Undo puts the entry (chapter + position) back.
    if (_isWindows) {
      showUndoToast(
        context,
        message: context.l10n.removedFromHistory(e.title),
        onUndo: () => unawaited(() async {
          await _read.save(e, flush: true);
          if (mounted) _reloadReading();
        }()),
      );
    }
  }

  /// Windows (track-10 C): marks the row's chapter as read.
  Future<void> _markReadFinished(ReadEntry e) async {
    if (sl.isRegistered<ReadStore>()) {
      await sl<ReadStore>().setRead(
        e.sourceId,
        e.showId,
        e.chapterId,
        read: true,
      );
    }
    await _read.save(readEntryMarkedRead(e), flush: true);
    if (mounted) _reloadReading();
  }

  /// Reading sources use `id == url` (both the series path), so a ReadEntry's
  /// [showId] doubles as the detail URL — enough to build a real MediaItem.
  MediaItem _readStub(ReadEntry e) => MediaItem(
    id: e.showId,
    title: e.title,
    cover: e.cover,
    url: e.showId,
    type: e.type,
    sourceId: e.sourceId,
  );

  void _openReadDetail(MediaItem item) {
    Navigator.push(
      context,
      DetailScreen.route(item),
    ).then((_) => _reloadReading());
  }

  /// Long-press info sheet for a manga/novel row — the reading twin of
  /// [_showInfo] (cover hero, synopsis, Resume, My List, Details, Remove).
  void _showReadInfo(ReadEntry e) {
    final stub = _readStub(e);
    final hasProgress = e.total > 0;
    final progress = hasProgress ? (e.pos / e.total).clamp(0.0, 1.0) : 0.0;
    final l10n = context.l10n;
    final chap = e.chapterNumber != null
        ? l10n.chapterLabel(e.chapterNumber!.toInt())
        : null;
    final pctLabel = hasProgress
        ? l10n.percentRead((progress * 100).round())
        : null;
    showMediaInfoSheet(
      context,
      title: e.title,
      cover: e.cover,
      typeLabel: e.type == ProviderType.manga ? l10n.modeManga : l10n.modeNovel,
      detail: _detailOf(e.showId, e.sourceId),
      inMyList: _myList.contains(stub),
      playLabel: l10n.resume,
      progress: hasProgress ? progress : null,
      progressLabel: [?chap, ?pctLabel].join('  ·  '),
      onPlay: () => _resumeRead(e),
      onOpenDetail: () => _openReadDetail(stub),
      onToggleMyList: () async {
        await showListStatusSheet(
          context,
          item: stub,
          onChanged: () {
            if (mounted) setState(() {});
          },
        );
        return _myList.contains(stub);
      },
      onRemoveFromContinue: () async {
        await _read.remove(e.sourceId, e.showId);
        _reloadReading();
      },
    );
  }

  // ── Clear-all (acts on the active tab only) ───────────────────────────────

  bool get _activeNotEmpty => switch (_tab.index) {
    0 => _anime.isNotEmpty,
    1 => _manga.isNotEmpty,
    _ => _novel.isNotEmpty,
  };

  Future<void> _clearActiveTab() async {
    final idx = _tab.index;
    // Scoped to the active tab only — clearing one mode never touches the
    // other two. The wording names the exact mode so that's unmistakable.
    final l10n = context.l10n;
    final (noun, kind) = switch (idx) {
      0 => (l10n.historyNounShow, l10n.historyKindWatch),
      1 => (l10n.historyNounMangaItem, l10n.historyKindManga),
      _ => (l10n.historyNounNovelItem, l10n.historyKindNovel),
    };
    final ok = await AppDialog.confirm(
      context,
      title: l10n.clearKindHistoryTitle(kind),
      message: l10n.clearKindHistoryBody(noun, kind),
      confirmLabel: l10n.clearAll,
      destructive: true,
    );
    if (ok != true) return;
    if (idx == 0) {
      await _watch.clearAll(); // local + cloud, so it can't sync back
      _reloadAnime();
    } else {
      await _read.clearType(idx == 1 ? ProviderType.manga : ProviderType.novel);
      _reloadReading();
    }
  }

  // ── Windows: desktop context menu instead of the phone info sheet ─────────

  /// Windows build: right-click/More menu and desktop header styling.
  bool get _isWindows => defaultTargetPlatform == TargetPlatform.windows;

  /// Windows: the shared graphite context menu at [position] (global) with
  /// the phone info sheet's actions — resume, details, My List (track-10 C),
  /// mark as finished (track-10 C) and remove (undoable, track-9).
  Future<void> _showRowMenu(
    Offset position, {
    required MediaItem item,
    required VoidCallback onResume,
    required VoidCallback onDetails,
    required VoidCallback onFinished,
    required VoidCallback onRemove,
    required bool finished,
  }) async {
    final l10n = context.l10n;
    final inList = _myList.contains(item);
    await showDesktopContextMenu<void>(
      context,
      position: position,
      items: [
        DesktopMenuItem(
          label: l10n.resume,
          icon: Icons.play_arrow_rounded,
          onTap: onResume,
        ),
        DesktopMenuItem(
          label: l10n.details,
          icon: Icons.info_outline_rounded,
          onTap: onDetails,
        ),
        DesktopMenuItem(
          label: inList
              ? context.l10n.changeListStatusEllipsis
              : context.l10n.addToMyListEllipsis,
          icon: inList ? Icons.bookmark_rounded : Icons.bookmark_add_outlined,
          onTap: () => unawaited(_editListStatus(item)),
        ),
        DesktopMenuItem(
          label: context.l10n.markAsFinished,
          icon: Icons.check_rounded,
          // Already finished rows have nothing to mark.
          enabled: !finished,
          onTap: onFinished,
        ),
        const DesktopMenuItem.divider(),
        DesktopMenuItem(
          label: l10n.remove,
          icon: Icons.close_rounded,
          destructive: true,
          onTap: onRemove,
        ),
      ],
    );
  }

  /// Windows: menu for a watch-history row.
  void _animeMenu(HistoryEntry e, Offset at) => _showRowMenu(
    at,
    item: _stub(e),
    finished: e.finished,
    onResume: () => _resume(e),
    onDetails: () => _openDetail(_stub(e)),
    onFinished: () => unawaited(_markFinished(e)),
    onRemove: () => _remove(e),
  );

  /// Windows: menu for a manga/novel row.
  void _readMenu(ReadEntry e, Offset at) => _showRowMenu(
    at,
    item: _readStub(e),
    finished: e.finished,
    onResume: () => _resumeRead(e),
    onDetails: () => _openReadDetail(_readStub(e)),
    onFinished: () => unawaited(_markReadFinished(e)),
    onRemove: () => _removeRead(e),
  );

  // ── Windows: search (track-10 A) ──────────────────────────────────────────

  /// Title filter for the tab on screen (Windows). Empty = everything.
  String _query = '';
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'history-search');

  /// Page focus so Ctrl+F reaches the shortcut before anything is clicked.
  final _pageFocus = FocusNode(debugLabel: 'history', skipTraversal: true);

  /// Ctrl+F: jump into the search box (selecting what is typed there).
  void _focusSearch() {
    _searchFocus.requestFocus();
    _searchCtrl.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _searchCtrl.text.length,
    );
  }

  /// Rows of one tab narrowed by [_query] (case-insensitive title match).
  List<T> _filtered<T>(List<T> entries, String Function(T) title) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return entries;
    return [
      for (final e in entries)
        if (title(e).toLowerCase().contains(q)) e,
    ];
  }

  /// The header search box (Windows): filters the current tab as you type,
  /// with a clear button; Ctrl+F focuses it.
  Widget _searchBox() => SizedBox(
    key: const ValueKey('history-search'),
    width: 240,
    height: 36,
    child: TextField(
      controller: _searchCtrl,
      focusNode: _searchFocus,
      onChanged: (v) => setState(() => _query = v),
      style: AppText.body.copyWith(color: AppColors.textPrimary, fontSize: 13),
      cursorColor: AppColors.accent,
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        // set-9: themed graphite fill/edge (stock greys by default).
        fillColor: GraphiteSettingsColors.dialog,
        hintText: context.l10n.searchHistoryCtrlF,
        hintStyle: AppText.caption.copyWith(color: AppColors.textTertiary),
        prefixIcon: const Icon(
          Icons.search_rounded,
          size: 18,
          color: AppColors.textTertiary,
        ),
        prefixIconConstraints: const BoxConstraints(minWidth: 34),
        suffixIcon: _query.isEmpty
            ? null
            : IconButton(
                tooltip: context.l10n.clearSearch,
                iconSize: 16,
                icon: const Icon(
                  Icons.close_rounded,
                  color: AppColors.textTertiary,
                ),
                onPressed: () => setState(() {
                  _query = '';
                  _searchCtrl.clear();
                }),
              ),
        contentPadding: const EdgeInsets.symmetric(vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: GraphiteSettingsColors.dialogEdge),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: GraphiteSettingsColors.dialogEdge),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: AppColors.accent),
        ),
      ),
    ),
  );

  /// The tab strip, shared by the phone and desktop headers.
  /// [desktop] packs the tabs to the start at their content width.
  TabBar _tabBar({bool desktop = false}) => TabBar(
    controller: _tab,
    isScrollable: desktop,
    tabAlignment: desktop ? TabAlignment.start : null,
    // Drop the default full-width hairline under the bar — that's the
    // "divider" that read badly; the sliding underline is the indicator.
    dividerColor: Colors.transparent,
    dividerHeight: 0,
    // Rounded accent underline hugging the label. The TabController
    // animates it between tabs and crossfades the label colour, so a tap
    // or a swipe glides the underline across.
    indicatorSize: TabBarIndicatorSize.label,
    indicator: UnderlineTabIndicator(
      borderRadius: const BorderRadius.all(Radius.circular(2)),
      borderSide: BorderSide(width: 3, color: AppColors.accent),
      insets: const EdgeInsets.symmetric(horizontal: -6),
    ),
    labelColor: AppColors.accent,
    unselectedLabelColor: AppColors.textSecondary,
    labelStyle: TextStyle(
      fontFamily: AppText.fontFamily,
      fontFamilyFallback: AppText.fontFamilyFallback,
      fontSize: 14.5,
      fontWeight: FontWeight.w700,
    ),
    unselectedLabelStyle: TextStyle(
      fontFamily: AppText.fontFamily,
      fontFamilyFallback: AppText.fontFamilyFallback,
      fontSize: 14.5,
      fontWeight: FontWeight.w600,
    ),
    overlayColor: WidgetStateProperty.all(Colors.transparent),
    tabs: [
      Tab(text: context.l10n.modeStreaming),
      Tab(text: context.l10n.modeManga),
      Tab(text: context.l10n.modeNovel),
    ],
  );

  /// Clear-all action for the active tab, shared by both headers.
  List<Widget> _actions() => [
    // Windows (track-10 A): filter the tab on screen by title.
    if (_isWindows) ...[Center(child: _searchBox()), const SizedBox(width: 4)],
    if (_activeNotEmpty)
      IconButton(
        key: const ValueKey('history-clear-all'),
        tooltip: context.l10n.clearAll,
        icon: const Icon(Icons.delete_sweep_outlined),
        onPressed: _clearActiveTab,
      ),
    if (_isWindows) const SizedBox(width: 12),
  ];

  /// Whether the graphite desktop header shows its rounded back button.
  /// A pushed History (Settings, Home, profile fallback) asks for it with
  /// [HistoryScreen.showBack]. On Windows the in-frame shell page (Profile
  /// page button / Ctrl+H) passes `showBack: false` but still needs a way
  /// out, so Windows always shows it: there `maybePop()` reaches RootShell's
  /// PopScope, whose Back handler closes the frame page and returns to the
  /// page underneath (the same thing Esc does).
  bool get _desktopBack => widget.showBack || _isWindows;

  /// Windows History header, used at every entry point (Settings, Profile
  /// page, Ctrl+H, Home): the same graphite bar every other desktop settings
  /// page uses (rounded back button, 23px title, 0xFF101114), with the
  /// compact Streaming/Manga/Novel tabs centred underneath it.
  PreferredSizeWidget _desktopAppBar() => AppBar(
    key: const ValueKey('history-desktop-header'),
    backgroundColor: DesktopChrome.frame, // set-9: themed frame
    surfaceTintColor: Colors.transparent,
    elevation: 0,
    scrolledUnderElevation: 0,
    automaticallyImplyLeading: false,
    titleSpacing: _desktopBack ? 10 : 24,
    leading: _desktopBack
        ? Padding(
            padding: const EdgeInsets.all(6),
            child: IconButton(
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: () => Navigator.of(context).maybePop(),
              style: IconButton.styleFrom(
                backgroundColor: const Color(0xFF24252D),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: const Icon(Icons.arrow_back_rounded, size: 20),
            ),
          )
        : null,
    title: Text(
      context.l10n.history,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: AppText.headline.copyWith(
        fontSize: 23,
        color: AppColors.textPrimary,
      ),
    ),
    actions: _actions(),
    bottom: PreferredSize(
      preferredSize: const Size.fromHeight(kTextTabBarHeight),
      child: Align(
        // Windows: the compact Streaming / Manga / Novel group sits in the
        // horizontal centre of the page (user request). It keeps its content
        // width (the scrollable TabBar shrink-wraps inside the Align), so the
        // tabs are centred, not stretched across the window. Other desktop
        // hosts of this header keep the original left-aligned placement.
        alignment: _isWindows
            ? Alignment.center
            : AlignmentDirectional.centerStart,
        // Left-aligned, content-width tabs read as desktop navigation rather
        // than three phone tabs stretched across a wide window. The start
        // inset only applies to that left-aligned case; centred tabs get
        // none so the group stays exactly in the middle.
        child: Padding(
          padding: EdgeInsetsDirectional.only(start: _isWindows ? 0 : 12),
          child: _tabBar(desktop: true),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    // Every Windows entry point (Settings, Profile page, Ctrl+H, Home) uses
    // the same graphite header with centred compact tabs as the
    // Settings-hosted History, so History looks the same wherever it opens.
    // The settings scope still selects it too; phone keeps its own AppBar.
    final desktop = _isWindows || DesktopSettingsScope.contains(context);
    // Windows: the row actions open a desktop context menu, not the sheet.
    final windows = _isWindows;
    final scaffold = Scaffold(
      backgroundColor: desktop ? DesktopChrome.frame : AppColors.bg, // set-9
      appBar: desktop
          ? _desktopAppBar()
          : AppBar(
              automaticallyImplyLeading: widget.showBack,
              backgroundColor: AppColors.bg,
              surfaceTintColor: Colors.transparent,
              title: Text(context.l10n.history),
              actions: _actions(),
              bottom: _tabBar(),
            ),
      body: TabBarView(
        controller: _tab,
        children: [
          _list<HistoryEntry>(
            entries: _filtered(_anime, (e) => e.showTitle),
            hasMore: _watch.hasMoreCloudPages(),
            loadingMore: _loadingAnimeMore,
            onLoadMore: _loadMoreAnime,
            tsMs: (e) => e.updatedAt,
            row: (e) => _HistoryRow(
              entry: e,
              onTap: () => _resume(e),
              onLongPress: () => _showInfo(e),
              onRemove: () => _remove(e),
              onMenu: windows ? (at) => _animeMenu(e, at) : null,
            ),
            empty: _EmptyState(
              icon: Icons.history_rounded,
              title: context.l10n.nothingWatchedYet,
              subtitle: context.l10n.showsYouWatchWillAppearHere,
            ),
          ),
          _list<ReadEntry>(
            entries: _filtered(_manga, (e) => e.title),
            hasMore: _read.hasMoreCloudPages(ProviderType.manga),
            loadingMore: _loadingMangaMore,
            onLoadMore: () => _loadMoreReading(ProviderType.manga),
            tsMs: (e) => e.updatedMs,
            row: (e) => _ReadRow(
              entry: e,
              onTap: () => _resumeRead(e),
              onLongPress: () => _showReadInfo(e),
              onRemove: () => _removeRead(e),
              onMenu: windows ? (at) => _readMenu(e, at) : null,
            ),
            empty: _EmptyState(
              icon: Icons.auto_stories_outlined,
              title: context.l10n.nothingReadYet,
              subtitle: context.l10n.mangaYouReadWillAppearHere,
            ),
          ),
          _list<ReadEntry>(
            entries: _filtered(_novel, (e) => e.title),
            hasMore: _read.hasMoreCloudPages(ProviderType.novel),
            loadingMore: _loadingNovelMore,
            onLoadMore: () => _loadMoreReading(ProviderType.novel),
            tsMs: (e) => e.updatedMs,
            row: (e) => _ReadRow(
              entry: e,
              onTap: () => _resumeRead(e),
              onLongPress: () => _showReadInfo(e),
              onRemove: () => _removeRead(e),
              onMenu: windows ? (at) => _readMenu(e, at) : null,
            ),
            empty: _EmptyState(
              icon: Icons.menu_book_outlined,
              title: context.l10n.nothingReadYet,
              subtitle: context.l10n.novelsYouReadWillAppearHere,
            ),
          ),
        ],
      ),
    );
    if (!windows) return scaffold;
    // Windows (track-10 A): Ctrl+F (lists.search) jumps into the search box.
    // The page focus node receives keys before any row has been clicked.
    final bindings = DesktopShortcuts.bindings({'lists.search': _focusSearch});
    return CallbackShortcuts(
      bindings: bindings.isNotEmpty
          ? bindings
          // Shortcut catalogue not registered (tests): the stock key.
          : {
              const SingleActivator(LogicalKeyboardKey.keyF, control: true):
                  _focusSearch,
            },
      child: Focus(focusNode: _pageFocus, autofocus: true, child: scaffold),
    );
  }

  /// Day-grouped list for one tab. [tsMs] pulls the epoch-ms timestamp off an
  /// entry so anime ([HistoryEntry.updatedAt]) and reading
  /// ([ReadEntry.updatedMs]) share this scaffolding.
  Widget _list<T>({
    required List<T> entries,
    required bool hasMore,
    required bool loadingMore,
    required Future<void> Function() onLoadMore,
    required int Function(T) tsMs,
    required Widget Function(T) row,
    required Widget empty,
  }) {
    final groups = _groupBy(context, entries, tsMs);
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (hasMore &&
            notification.metrics.extentAfter < 320 &&
            (notification is ScrollUpdateNotification ||
                notification is ScrollEndNotification)) {
          unawaited(onLoadMore());
        }
        return false;
      },
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.only(
          top: 4,
          bottom: MediaQuery.paddingOf(context).bottom,
        ),
        itemCount: (groups.isEmpty ? 1 : groups.length) + (hasMore ? 1 : 0),
        itemBuilder: (_, gi) {
          if (groups.isEmpty) {
            if (gi == 0) {
              return SizedBox(
                height: MediaQuery.sizeOf(context).height * 0.65,
                // Windows search with nothing matching: say so, rather than
                // claiming the history is empty.
                child: _query.trim().isNotEmpty
                    ? _EmptyState(
                        icon: Icons.search_off_rounded,
                        title: context.l10n.noMatches,
                        subtitle: context.l10n.nothingInTabMatches(_query.trim()),
                      )
                    : empty,
              );
            }
            return _HistoryLoadMore(loading: loadingMore);
          }
          if (gi == groups.length) {
            return _HistoryLoadMore(loading: loadingMore);
          }
          final g = groups[gi];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
                child: Text(
                  g.label,
                  style: TextStyle(
                    fontFamily: AppText.fontFamily,
                    fontFamilyFallback: AppText.fontFamilyFallback,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                    color: AppColors.accent,
                  ),
                ),
              ),
              for (final e in g.entries) row(e),
            ],
          );
        },
      ),
    );
  }

  // ── Day grouping ──────────────────────────────────────────────────────────
  List<_DayGroup<T>> _groupBy<T>(
    BuildContext context,
    List<T> entries,
    int Function(T) tsMs,
  ) {
    final out = <_DayGroup<T>>[];
    String? current;
    for (final e in entries) {
      final label = _dayLabel(
        context,
        DateTime.fromMillisecondsSinceEpoch(tsMs(e)),
      );
      if (label != current) {
        out.add(_DayGroup(label, []));
        current = label;
      }
      out.last.entries.add(e);
    }
    return out;
  }
}

class _DayGroup<T> {
  _DayGroup(this.label, this.entries);
  final String label;
  final List<T> entries;
}

String _dayLabel(BuildContext context, DateTime d) {
  final l10n = context.l10n;
  final locale = Localizations.localeOf(context).toString();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return l10n.relativeToday;
  if (diff == 1) return l10n.relativeYesterday;
  if (diff < 7) return DateFormat.E(locale).format(day);
  if (day.year == now.year) {
    return DateFormat('EEE, MMM d', locale).format(day);
  }
  return DateFormat('EEE, MMM d, yyyy', locale).format(day);
}

String _clockTime(BuildContext context, DateTime d) {
  final locale = Localizations.localeOf(context).toString();
  return DateFormat.jm(locale).format(d);
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({
    required this.entry,
    required this.onTap,
    required this.onLongPress,
    required this.onRemove,
    this.onMenu,
  });

  final HistoryEntry entry;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onRemove;

  /// Windows only: opens the desktop context menu at a global position.
  final ValueChanged<Offset>? onMenu;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final time = _clockTime(
      context,
      DateTime.fromMillisecondsSinceEpoch(e.updatedAt),
    );
    final ep = e.episodeNumber != null
        ? context.l10n.episodeLabel(e.episodeNumber!.toInt())
        : null;
    final subtitle = [?ep, time].join('  ·  ');
    return _RowShell(
      title: e.showTitle,
      subtitle: subtitle,
      cover: e.cover,
      headers: e.coverHeaders,
      progress: e.progress,
      onTap: onTap,
      onLongPress: onLongPress,
      onRemove: onRemove,
      onMenu: onMenu,
    );
  }
}

class _ReadRow extends StatelessWidget {
  const _ReadRow({
    required this.entry,
    required this.onTap,
    required this.onLongPress,
    required this.onRemove,
    this.onMenu,
  });

  final ReadEntry entry;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onRemove;

  /// Windows only: opens the desktop context menu at a global position.
  final ValueChanged<Offset>? onMenu;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final time = _clockTime(
      context,
      DateTime.fromMillisecondsSinceEpoch(e.updatedMs),
    );
    final ch = e.chapterNumber != null
        ? context.l10n.chapterLabel(e.chapterNumber!.toInt())
        : null;
    final subtitle = [?ch, time].join('  ·  ');
    final progress = e.total > 0 ? (e.pos / e.total).clamp(0.0, 1.0) : 0.0;
    return _RowShell(
      title: e.title,
      subtitle: subtitle,
      cover: e.cover,
      // ReadEntry stores only a plain cover URL (no per-source headers) — same
      // as the Home Continue Reading card.
      headers: null,
      progress: progress,
      onTap: onTap,
      onLongPress: onLongPress,
      onRemove: onRemove,
      onMenu: onMenu,
    );
  }
}

/// Shared row chrome for both anime and reading history: cover + progress on
/// the left, title/subtitle in the middle, ✕ on the right.
class _RowShell extends StatelessWidget {
  const _RowShell({
    required this.title,
    required this.subtitle,
    required this.cover,
    required this.headers,
    required this.progress,
    required this.onTap,
    required this.onRemove,
    this.onLongPress,
    this.onMenu,
  });

  final String title;
  final String subtitle;
  final String? cover;
  final Map<String, String>? headers;
  final double progress;
  final VoidCallback onTap;
  final VoidCallback onRemove;
  final VoidCallback? onLongPress;

  /// Windows: desktop context menu (right-click, long-press, More button)
  /// replacing the phone info sheet. Null keeps the phone behaviour.
  final ValueChanged<Offset>? onMenu;

  /// Global centre of [context]'s box, where a keyboard/long-press menu opens.
  static Offset _centerOf(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return Offset.zero;
    return box.localToGlobal(box.size.center(Offset.zero));
  }

  @override
  Widget build(BuildContext context) {
    final menu = onMenu;
    return InkWell(
      onTap: onTap,
      onLongPress: menu == null ? onLongPress : () => menu(_centerOf(context)),
      onSecondaryTapUp: menu == null
          ? null
          : (details) => menu(details.globalPosition),
      splashColor: AppColors.accent.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Row(
          children: [
            _Cover(url: cover, headers: headers, progress: progress),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.headline.copyWith(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            // Windows: a visible way into the row menu for mouse users.
            if (menu != null)
              Builder(
                builder: (buttonContext) => IconButton(
                  key: const ValueKey('history-row-more'),
                  tooltip: context.l10n.more,
                  icon: const Icon(
                    Icons.more_horiz_rounded,
                    color: AppColors.textTertiary,
                    size: 20,
                  ),
                  onPressed: () => menu(_centerOf(buttonContext)),
                ),
              ),
            IconButton(
              tooltip: context.l10n.remove,
              icon: const Icon(
                Icons.close_rounded,
                color: AppColors.textTertiary,
                size: 20,
              ),
              onPressed: onRemove,
            ),
          ],
        ),
      ),
    );
  }
}

/// 48×72 rounded cover thumbnail with a thin progress bar pinned to its base.
/// Mirrors [ContinueCard]'s Aniyomi/CachedNetworkImage branching.
class _Cover extends StatelessWidget {
  const _Cover({
    required this.url,
    required this.headers,
    required this.progress,
  });

  final String? url;
  final Map<String, String>? headers;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final p = progress.clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 48,
        height: 72,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (url == null || url!.isEmpty)
              ColoredBox(color: AppColors.surface2)
            else if (headers?['x-ani-src'] != null)
              Image(
                // Resize to the 48×72 thumb's pixel width (matches the
                // non-Aniyomi memCacheWidth) so it isn't cached full-res.
                image: ResizeImage(
                  AniyomiImage(int.parse(headers!['x-ani-src']!), url!),
                  width: 144,
                ),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    ColoredBox(color: AppColors.surface2),
              )
            else
              CachedNetworkImage(
                imageUrl: url!,
                httpHeaders: headers,
                memCacheWidth: 144,
                fit: BoxFit.cover,
                placeholder: (_, _) => ColoredBox(color: AppColors.surface2),
                errorWidget: (_, _, _) => ColoredBox(color: AppColors.surface2),
              ),
            if (p > 0)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 3,
                child: Row(
                  children: [
                    Expanded(
                      flex: (p * 1000).round(),
                      child: ColoredBox(color: AppColors.accent),
                    ),
                    Expanded(
                      flex: ((1.0 - p) * 1000).round(),
                      child: const ColoredBox(color: AppColors.hairline),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _HistoryLoadMore extends StatelessWidget {
  const _HistoryLoadMore({required this.loading});

  final bool loading;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 56,
    child: loading
        ? const Center(
            child: SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        : const SizedBox.shrink(),
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 56,
              color: AppColors.textTertiary.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 16),
            Text(title, style: AppText.headline.copyWith(fontSize: 16)),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: AppText.caption.copyWith(color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
