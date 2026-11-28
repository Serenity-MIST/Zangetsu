// Episodes tab: list and grid rows, season sheet, range chips, jump dialog.
part of 'detail_screen.dart';

/// Windows downloaded show page: an image saved next to the download comes
/// as a `file:` URI and is drawn straight from disk (works offline). Returns
/// null for any other URL so the caller keeps its network image; `file:`
/// URIs only ever appear in that mode, so the phone and the online page are
/// unaffected. A missing or broken file shows the usual grey box.
@visibleForTesting
Widget? localDetailImage(String url, {int? cacheWidth}) {
  if (!url.startsWith('file:')) return null;
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  final File file;
  try {
    file = File.fromUri(uri);
  } catch (_) {
    return ColoredBox(color: AppColors.surface2);
  }
  return Image.file(
    file,
    fit: BoxFit.cover,
    cacheWidth: cacheWidth,
    gaplessPlayback: true,
    errorBuilder: (_, _, _) => ColoredBox(color: AppColors.surface2),
  );
}

/// Windows: the show's wide picture (landscape poster, then banner) for an
/// episode tile with no still of its own, so a 16:9 tile shows wide art
/// before falling back to the portrait poster. Null on phone and TV.
String? _desktopWideEpisodeArt(MediaItem item, MediaDetail detail) {
  if (!_windowsDesktopUi) return null;
  for (final url in [item.landscapePoster, detail.banner, item.banner]) {
    final trimmed = url?.trim();
    if (trimmed != null && trimmed.isNotEmpty) return trimmed;
  }
  return null;
}

/// Whether an episode row shows as watched (row tick, thumbnail check,
/// dimming): finished locally, OR at/below the tracker's watched count.
/// The tracker rule only applies to single-season shows, where episode
/// numbers map cleanly to the tracker's per-entry progress. An explicit
/// "Mark as unwatched" override ([ResumeMark.markedUnwatched], Windows)
/// beats the tracker: trackers only keep a high-water mark, so without the
/// veto an unmarked episode at or below it kept every watched indicator.
/// Shared by the row and the episode menu so both always agree.
@visibleForTesting
bool episodeShowsWatched({
  required ResumeMark? mark,
  required int? episodeNumber,
  required int? trackerProgress,
  required bool hasMultipleSeasons,
}) {
  if (mark?.markedUnwatched ?? false) return false;
  if (mark?.finished ?? false) return true;
  return trackerProgress != null &&
      !hasMultipleSeasons &&
      episodeNumber != null &&
      episodeNumber <= trackerProgress;
}

// ─────────────────────────────────────────────────────────────────────────────
// Episodes tab — season selector (multi-season) + rich episode rows. PRESERVES
// season filtering and _openPlayer.
// ─────────────────────────────────────────────────────────────────────────────

class _EpisodesTab extends StatefulWidget {
  const _EpisodesTab({
    required this.loading,
    this.versionPicker,
    this.downloadedFallback = const [],
    required this.category,
    required this.eps,
    required this.seasonEps,
    required this.fillerEps,
    required this.hasMultipleSeasons,
    required this.seasonSet,
    required this.currentSeason,
    required this.onSelectSeason,
    required this.coverUrl,
    required this.coverHeaders,
    this.wideCoverUrl,
    required this.sourceId,
    required this.downloadSourceId,
    required this.showId,
    required this.showUrl,
    required this.resumeIndex,
    required this.hasAnyMark,
    this.trackerProgress,
    this.nextAiringEpisode,
    this.nextAiringAt,
    required this.onOpen,
    this.onEpisodeMenu,
    this.onRefresh,
    required this.onDownload,
    this.onDownloadMany,
    this.onDeleteMany,
    this.resumeChapter,
    this.onSwitchSource,
    this.isReading = false,
    this.filmMeta,
    this.filmTitle,
    this.hasScheduledVideos = false,
    this.malId,
    this.anyCutFallback = false,
  });

  /// The catalogue knows episodes exist but none are released yet — the empty
  /// state says "not yet aired" instead of "no episodes". Defaults off so
  /// every existing caller is unchanged.
  final bool hasScheduledVideos;

  /// The page's MAL id, handed to each row's download tick for the Windows
  /// any-cut lookup (B1). Null when the show has none.
  final int? malId;

  /// True only on the Windows online show page: a row's tick also shows a
  /// copy saved in another cut (B1). False on phone, TV and the downloaded
  /// show page, matching the right-click menu and Play.
  final bool anyCutFallback;

  /// Windows downloaded show page: deletes the saved files of the selected
  /// episodes. When set, the selection bar offers Delete instead of
  /// Download. Null on the normal page.
  final Future<void> Function(List<Episode> eps)? onDeleteMany;

  /// Opens the source picker for this title. Set only for catalogue titles,
  /// which are the ones that HAVE another source to try: when the one they
  /// are on returns nothing, the empty state below is otherwise a dead end
  /// and the way out (tapping the source name) is not obvious.
  final VoidCallback? onSwitchSource;

  /// The matched source's list is still being fetched — show the skeleton
  /// rather than the "no episodes" empty state (see
  /// [DetailState.episodesLoading]).
  final bool loading;
  final Widget? versionPicker;

  /// Windows: this show's finished downloads, listed in place of "No
  /// episodes available" when the source returned no episodes (offline).
  final List<DownloadRecord> downloadedFallback;
  final String category;

  final List<Episode> eps;
  final List<Episode> seasonEps;
  final Set<int> fillerEps; // episode numbers that are filler
  final bool hasMultipleSeasons;
  final Set<int> seasonSet;
  final int currentSeason;
  final ValueChanged<int> onSelectSeason;
  final String coverUrl;
  final Map<String, String>? coverHeaders;

  /// Windows: the show's wide picture for episode rows with no still (see
  /// [_desktopWideEpisodeArt]). Null on phone and TV.
  final String? wideCoverUrl;
  final String sourceId;

  /// The source that owns the chapter FILES, which for a metadata title is
  /// the matched extension rather than the `zm` pseudo-source in [sourceId].
  ///
  /// Kept apart on purpose: reading progress is keyed to the canonical id and
  /// must stay there, while downloads have to name the source that can
  /// actually fetch the pages.
  final String downloadSourceId;
  final String showId;
  final String showUrl;
  final int Function(List<Episode>) resumeIndex;
  final bool hasAnyMark;

  /// The connected tracker's watched-episode count, or null. Episodes at or
  /// below it render as watched (grey-out), merged with local playback marks.
  final int? trackerProgress;

  /// Next episode to air and when. Both null unless the title matched a
  /// tracker and is still airing, which is what keeps the row off finished
  /// shows and movies instead of showing an empty countdown.
  final int? nextAiringEpisode;
  final DateTime? nextAiringAt;
  final void Function(int fullIndex) onOpen;

  /// Long-press an episode → pick which player opens it, this once. Null on
  /// the reading path: a chapter opens the reader, so there's nothing to pick.
  final void Function(int fullIndex)? onEpisodeMenu;

  /// Force-refresh the list past the 10-min source cache. Null hides the menu item.
  final Future<void> Function()? onRefresh;

  /// Per-row download icon → the download sheet for an episode, or a straight
  /// enqueue for a chapter.
  final void Function(Episode ep) onDownload;

  /// Queue a run of chapters in one go. Null for video, where downloading is
  /// per-episode through the source picker.
  final Future<void> Function(List<Episode> eps)? onDownloadMany;

  /// Reading resume target from ReadStore / ReadHistory. Batch download starts
  /// here instead of at chapter one; an unfinished chapter is included.
  final Episode? resumeChapter;

  /// True for reading types — the section header reads "Chapters" instead
  /// of "Episodes" (single-season case only; multi-season keeps the season
  /// pill either way).
  final bool isReading;

  /// Non-null when this title is a film: the episodes tab becomes a single
  /// "Movie · 1h 52m" line. Null keeps the normal episode/chapter list.
  final String? filmMeta;
  final String? filmTitle;

  @override
  State<_EpisodesTab> createState() => _EpisodesTabState();
}

class _EpisodesTabState extends State<_EpisodesTab> {
  /// Windows (show-10) opens in the view last used on any show; phone keeps
  /// starting in the list.
  bool _grid = _windowsDesktopUi && DetailPrefs.episodeGridView;

  /// Starts from the Behaviour setting — newest-first on every detail screen
  /// when on. The list button still flips it; on phone that only lasts this
  /// visit, on Windows (show-10) the choice is saved back as that setting.
  bool _reverseList = DetailPrefs.reverseEpisodesDefault;

  // ── Windows: filter box (show-7) ─────────────────────────────────────────
  final _filterCtrl = TextEditingController();
  final _filterFocus = FocusNode(debugLabel: 'episode-filter');

  /// Live filter text; non-empty shows every match across all chunks.
  String _query = '';

  // ── Windows: multi-select (show-6) ───────────────────────────────────────
  /// Selected episodes by id (Ctrl/Shift-click or the hover checkbox).
  final _selection = DesktopSelection<String>();

  /// Holds focus inside the list while selecting, so Esc / Ctrl+A reach the
  /// selection shortcuts instead of the page or the window.
  final _listFocus = FocusNode(debugLabel: 'episode-list', skipTraversal: true);

  /// On-screen order of the rows last built, for Shift ranges and Ctrl+A.
  List<String> _orderedIds = const [];

  // ── Windows: "Go to episode" reveal (show-7 B) ───────────────────────────
  /// Rows currently mounted, by their index in the shown list; tells the
  /// jump which way to scroll until the target row exists.
  final Map<int, BuildContext> _mountedRows = {};

  /// Index (in the shown list) of the row the last jump landed on.
  int? _highlightIndex;
  Timer? _highlightTimer;

  /// A context inside the CustomScrollView, to reach its scroll position.
  BuildContext? _scrollContext;

  /// Selected scanlation group, or null for "All". Several groups release the
  /// same chapter number, so an unfiltered list legitimately reads 1, 1, 2, 2
  /// — picking a group is what makes it a single readable run.
  String? _scanlator;
  int _rangeIndex = 0;
  String? _highlightEpId; // outlines a grid tile right after a jump

  @override
  void initState() {
    super.initState();
    _rangeIndex = _initialRange();
    if (_windowsDesktopUi) {
      _selection.addListener(_onSelectionChanged);
      // F5 / Ctrl+F work wherever focus is on the page (show-8), so they
      // listen globally and check that this tab is the one on screen.
      HardwareKeyboard.instance.addHandler(_onHardwareKey);
    }
  }

  @override
  void dispose() {
    // Unconditional: both are no-ops when nothing was added, and the platform
    // check could differ from initState's (tests reset the override before
    // the tree is torn down), which would leak the global key handler.
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _selection.removeListener(_onSelectionChanged);
    _highlightTimer?.cancel();
    _selection.dispose();
    _listFocus.dispose();
    _filterCtrl.dispose();
    _filterFocus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _EpisodesTab old) {
    super.didUpdateWidget(old);
    // Season switched (or the episode set changed) → reset to the resume chunk.
    if (old.currentSeason != widget.currentSeason ||
        old.seasonEps.length != widget.seasonEps.length) {
      _rangeIndex = _initialRange();
      _highlightEpId = null;
      _highlightIndex = null;
      // A selection only makes sense within the episodes it was made in.
      if (old.currentSeason != widget.currentSeason) _selection.clear();
    }
  }

  // ── Windows helpers (show-6 / show-7 / show-8 / show-10) ─────────────────

  /// Repaints the rows and pulls focus into the list once a selection starts,
  /// so Esc clears it and Ctrl+A selects all.
  void _onSelectionChanged() {
    if (!mounted) return;
    setState(() {});
    if (_selection.isActive &&
        !_listFocus.hasFocus &&
        !_filterFocus.hasFocus) {
      _listFocus.requestFocus();
    } else if (!_selection.isActive && _listFocus.hasPrimaryFocus) {
      // Selection over: hand focus back to the page so its Enter/Space
      // (play) keys work again.
      _listFocus.unfocus(disposition: UnfocusDisposition.scope);
    }
  }

  /// True when this tab is the visible page of the tab view (a kept-alive
  /// neighbour sits a full page width to the side).
  bool _onScreen() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return false;
    final left = box.localToGlobal(Offset.zero).dx;
    final screen = MediaQuery.sizeOf(context).width;
    return left > -box.size.width / 2 && left < screen - box.size.width / 2;
  }

  /// show-8 keys for this tab: F5 refreshes the episode list, Ctrl+F jumps
  /// into the filter box. Only while this page is the top route and the
  /// Episodes tab is showing.
  bool _onHardwareKey(KeyEvent event) {
    if (event is! KeyDownEvent || !mounted) return false;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;
    if (!_onScreen()) return false;
    // The filter box only exists for a non-empty episode list (not films);
    // F5 below still works on an empty or failed list, where it helps most.
    final hasFilter = widget.seasonEps.isNotEmpty && widget.filmMeta == null;
    if (hasFilter && DesktopShortcuts.matches('show.filter', event)) {
      _filterFocus.requestFocus();
      // Select what is there, so typing replaces the last search.
      _filterCtrl.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _filterCtrl.text.length,
      );
      return true;
    }
    final refresh = widget.onRefresh;
    if (refresh != null &&
        DesktopShortcuts.matches('show.refreshEpisodes', event)) {
      unawaited(refresh());
      showAppToast(
        context,
        widget.isReading
            ? context.l10n.refreshingChapters
            : context.l10n.refreshingEpisodes,
      );
      return true;
    }
    return false;
  }

  /// show-10: list/grid is remembered for every show on Windows.
  void _toggleView() {
    setState(() => _grid = !_grid);
    if (_windowsDesktopUi) unawaited(DetailPrefs.setEpisodeGridView(_grid));
  }

  /// show-10: newest-first is saved back as the app-wide default on Windows.
  void _saveReverse(bool value) {
    if (!_windowsDesktopUi) return;
    unawaited(DetailPrefs.rememberReverseEpisodes(value));
  }

  /// show-7: the filter text changed; leave any jump highlight behind.
  void _onFilterChanged(String value) {
    setState(() {
      _query = value;
      _highlightEpId = null;
      _highlightIndex = null;
    });
  }

  /// Second Esc in the filter box: hand the keyboard back to the page (the
  /// list while selecting, so Esc can then clear the selection).
  void _closeFilter() {
    if (_selection.isActive) {
      _listFocus.requestFocus();
    } else {
      _filterFocus.unfocus(disposition: UnfocusDisposition.scope);
    }
  }

  /// Episodes currently selected, in list order.
  List<Episode> get _selectedEpisodes {
    final ids = _selection.selected;
    return [
      for (final e in widget.seasonEps)
        if (ids.contains(e.id)) e,
    ];
  }

  /// show-6: Mark watched / unwatched (read / unread) for the selection.
  /// Writes the same stores and keys as the single-episode menu.
  Future<void> _markSelection(bool watched) async {
    final picked = _selectedEpisodes;
    if (picked.isEmpty) return;
    final readSource = widget.downloadSourceId.isNotEmpty
        ? widget.downloadSourceId
        : widget.sourceId;
    for (final ep in picked) {
      if (widget.isReading) {
        await sl<ReadStore>().setRead(
          readSource,
          widget.showId,
          ep.id,
          read: watched,
        );
      } else {
        await sl<ResumeStore>().setWatched(
          widget.sourceId,
          widget.showUrl,
          ep.id,
          watched: watched,
        );
      }
    }
    if (!mounted) return;
    _selection.clear();
    setState(() {});
    // Trackers hold a high-water mark: one write for the highest episode,
    // and nothing for "unwatched" (same rule as the episode menu).
    final host = context.findAncestorStateOfType<_DetailViewState>();
    final detail = _currentDetail();
    if (watched && host != null && detail != null) {
      final top = picked.reduce(
        (a, b) => (b.number ?? -1) > (a.number ?? -1) ? b : a,
      );
      unawaited(host._scrobbleUpTo(top, detail));
    }
    final n = picked.length;
    showAppToast(
      context,
      widget.isReading
          ? (watched
                ? context.l10n.markedChaptersAsRead(n)
                : context.l10n.markedChaptersAsUnread(n))
          : (watched
                ? context.l10n.markedEpisodesAsWatched(n)
                : context.l10n.markedEpisodesAsUnwatched(n)),
    );
  }

  /// The loaded detail from the page's cubit, or null outside the page.
  MediaDetail? _currentDetail() {
    try {
      return context.read<DetailCubit>().state.detail;
    } catch (_) {
      return null;
    }
  }

  /// Downloaded show page: Delete for the selection (the page confirms).
  Future<void> _deleteSelection() async {
    final picked = _selectedEpisodes;
    final delete = widget.onDeleteMany;
    if (picked.isEmpty || delete == null) return;
    await delete(picked);
    if (mounted) _selection.clear();
  }

  /// show-6: Download for the selection. Chapters queue straight away;
  /// episodes go through the page's existing batch download dialog with only
  /// the selected ones in it (all ticked), so quality/server/size and the
  /// already-downloaded check work exactly as from the Download button.
  Future<void> _downloadSelection() async {
    final picked = _selectedEpisodes;
    if (picked.isEmpty) return;
    if (widget.isReading) {
      if (widget.onDownloadMany == null) return;
      _selection.clear();
      await _enqueueAll(picked);
      return;
    }
    final host = context.findAncestorStateOfType<_DetailViewState>();
    final detail = _currentDetail();
    if (host == null || detail == null) return;
    _selection.clear();
    await host._openDownloadSheet(
      detail: detail,
      category: widget.category,
      episodesBySeason: {widget.currentSeason: picked},
      initialSeason: widget.currentSeason,
    );
  }

  /// Windows "Go to episode" (show-7 B): keep the current view, scroll the
  /// landed-on row into view and outline it for a moment. The row may not be
  /// built yet (lazy list), so this steps a screen at a time towards it.
  void _revealHighlight() {
    _highlightTimer?.cancel();
    var tries = 0;
    void step(Duration _) {
      final target = _highlightIndex;
      if (!mounted || target == null || tries++ > 40) return;
      final row = _mountedRows[target];
      if (row != null && row.mounted) {
        unawaited(
          Scrollable.ensureVisible(
            row,
            alignment: 0.3,
            duration: const Duration(milliseconds: 250),
          ),
        );
        return;
      }
      final scrollContext = _scrollContext;
      final position = scrollContext == null || !scrollContext.mounted
          ? null
          : Scrollable.maybeOf(scrollContext)?.position;
      if (position == null || _mountedRows.isEmpty) return;
      final built = _mountedRows.keys;
      final down = target > built.reduce((a, b) => a > b ? a : b);
      final next =
          (position.pixels +
                  position.viewportDimension * 0.8 * (down ? 1 : -1))
              .clamp(position.minScrollExtent, position.maxScrollExtent);
      if (next == position.pixels) return; // already at the end
      position.jumpTo(next);
      WidgetsBinding.instance.addPostFrameCallback(step);
    }

    WidgetsBinding.instance.addPostFrameCallback(step);
    // "Briefly": the outline fades after a few seconds.
    _highlightTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() {
        _highlightEpId = null;
        _highlightIndex = null;
      });
    });
  }

  /// Windows row wrapper: registers the row for [_revealHighlight], outlines
  /// a jump target and adds the selection wash + hover checkbox (show-6).
  Widget _desktopFrame({
    required int index,
    required Episode ep,
    required Widget child,
    required Offset checkboxOffset,
    double checkboxSize = 20,
    double radius = 10,
    // Grid tiles draw their own jump outline.
    bool outline = true,
  }) {
    final selectable = widget.filmMeta == null;
    final highlighted = outline && _highlightEpId == ep.id;
    Widget body = child;
    if (selectable) {
      body = EpisodeSelectableTile(
        selected: _selection.isSelected(ep.id),
        selectionActive: _selection.isActive,
        onCheckbox: () => _selection.toggle(ep.id),
        checkboxOffset: checkboxOffset,
        checkboxSize: checkboxSize,
        radius: radius,
        child: body,
      );
    }
    return _MountedRow(
      index: index,
      rows: _mountedRows,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(
            color: highlighted ? AppColors.accent : Colors.transparent,
            width: 2,
          ),
        ),
        child: body,
      ),
    );
  }

  /// Row click on Windows: Ctrl/Shift (or any click while selecting) selects
  /// instead of opening the episode.
  void _openOrSelect(Episode ep, int fullIndex) {
    if (_windowsDesktopUi &&
        widget.filmMeta == null &&
        _selection.handleClick(ep.id, _orderedIds)) {
      return;
    }
    widget.onOpen(fullIndex);
  }

  /// The chunk holding the resume episode, so the tab opens where the user left
  /// off instead of always at episode 1.
  int _initialRange() {
    if (!widget.hasAnyMark || widget.seasonEps.isEmpty) return 0;
    final resumeEp = widget.eps[widget.resumeIndex(widget.eps)];
    // Against the filtered display order so reversed lists open at the range
    // containing the saved resume episode.
    final local = _displayEps.indexOf(resumeEp);
    return episodeRangeIndex(
      local,
      total: _displayEps.length,
      reversed: _reverseList,
    );
  }

  int get _rangeCount => episodeRangeCount(_filteredEps.length);

  /// Scanlation groups on offer, first-seen order (which is the source's own
  /// ordering, so the group a reader is following tends to come first).
  List<String> get _scanlators {
    final seen = <String>[];
    for (final e in widget.seasonEps) {
      final s = e.scanlator?.trim();
      if (s != null && s.isNotEmpty && !seen.contains(s)) seen.add(s);
    }
    return seen;
  }

  /// The chapters actually shown. Identical to the source list when no group
  /// is picked, so nothing changes for the titles that have only one.
  List<Episode> get _filteredEps {
    final want = _scanlator;
    if (want == null) return widget.seasonEps;
    return [
      for (final e in widget.seasonEps)
        if (e.scanlator?.trim() == want) e,
    ];
  }

  List<Episode> get _displayEps {
    final episodes = _filteredEps;
    return _reverseList ? episodes.reversed.toList(growable: false) : episodes;
  }

  /// Reading progress lives in [ReadStore] (page index / scroll permille),
  /// keyed by showId — the video [ResumeStore] never holds a mark for a
  /// chapter, so without this a read chapter could never dim. Also OR's in
  /// the connected tracker's chapter progress ([_EpisodesTab.trackerProgress]),
  /// same idea as [_stateFor]'s watched calc for video — a chapter you've
  /// only read on AniList/MAL should dim too. No seasons in reading, so no
  /// hasMultipleSeasons guard is needed here.
  ({bool watched, bool inProgress, bool resume, double fraction}) _readStateFor(
    Episode ep,
  ) {
    final store = sl<ReadStore>();
    // Read marks are keyed by the SOURCE that owns the chapters, which is
    // [downloadSourceId] (`detail.sourceId`) — not [sourceId], which for a
    // metadata title is the `zm` pseudo-source. The reader writes under the
    // real source for the same reason it fetches pages with it, so looking
    // them up under `zm` found nothing and a finished chapter never dimmed.
    final readSource = widget.downloadSourceId.isNotEmpty
        ? widget.downloadSourceId
        : widget.sourceId;
    final mark = store.get(readSource, widget.showId, ep.id);
    final done = store.finished(readSource, widget.showId, ep.id);
    final inProgress = mark != null && !done && mark.total > 0;
    final watched =
        done ||
        (widget.trackerProgress != null &&
            ep.number != null &&
            ep.number! <= widget.trackerProgress!);
    return (
      watched: watched,
      inProgress: inProgress,
      // No CONTINUE badge in the reading row, and the resume index we're
      // handed is the video one — so never claim a resume here.
      resume: false,
      fraction: inProgress ? (mark.pos / mark.total).clamp(0.0, 1.0) : 0.0,
    );
  }

  ({bool watched, bool inProgress, bool resume, double fraction}) _stateFor(
    ResumeStore store,
    Episode ep,
    int fullIndex,
  ) {
    if (widget.isReading) return _readStateFor(ep);
    final mark = store.get(widget.sourceId, widget.showUrl, ep.id);
    final inProgress =
        mark != null && !mark.finished && mark.duration > Duration.zero;
    // Watched = finished locally, OR at/below the tracker's watched count.
    // Only applied to single-season shows, where episode numbers map cleanly
    // to the tracker's per-entry progress (avoids mis-greying across seasons).
    final watched = episodeShowsWatched(
      mark: mark,
      episodeNumber: ep.number?.toInt(),
      trackerProgress: widget.trackerProgress,
      hasMultipleSeasons: widget.hasMultipleSeasons,
    );
    final resume =
        widget.hasAnyMark && fullIndex == widget.resumeIndex(widget.eps);
    final fraction = inProgress
        ? (mark.position.inMilliseconds / mark.duration.inMilliseconds).clamp(
            0.0,
            1.0,
          )
        : 0.0;
    return (
      watched: watched,
      inProgress: inProgress,
      resume: resume,
      fraction: fraction,
    );
  }

  Future<void> _jump() async {
    final n = await showDialog<int>(
      context: context,
      builder: (_) => const _JumpDialog(),
    );
    if (n == null || !mounted) return;
    // Match by episode number; fall back to a 1-based position. Searched in
    // the FILTERED list, so jumping while a scanlator is picked lands on that
    // group's chapter rather than a position in the unfiltered run.
    final eps = _displayEps;
    var local = eps.indexWhere((e) => e.number?.toInt() == n);
    if (local < 0 && n >= 1 && n <= eps.length) {
      local = episodePositionForNumber(n, eps.length, reversed: _reverseList);
    }
    if (local < 0) return;
    final rangeIndex = episodeRangeIndex(
      local,
      total: eps.length,
      reversed: _reverseList,
    );
    setState(() {
      _rangeIndex = rangeIndex;
      // Phone: the grid makes the jumped-to episode easy to spot. Windows
      // (show-7 B) keeps the chosen view and scrolls to the row instead.
      if (!_windowsDesktopUi) _grid = true;
      _highlightEpId = eps[local].id;
      if (_windowsDesktopUi) {
        // A filter would hide the target: clear it so the chunk shows.
        _filterCtrl.clear();
        _query = '';
        _highlightIndex =
            local - episodeRangeSlice(rangeIndex, eps.length,
                reversed: _reverseList).start;
      }
    });
    if (_windowsDesktopUi) _revealHighlight();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.seasonEps.isEmpty) {
      if (widget.loading) return const _EpisodeListSkeleton();
      final saved = widget.downloadedFallback;
      if (saved.isNotEmpty) {
        return DesktopDownloadedEpisodes(
          records: saved,
          onPlay: (i) => unawaited(launchDownloadedEpisode(
            context,
            saved[i],
            episodes: episodesFromDownloads(saved),
            startIndex: i,
          )),
        );
      }
      // Windows: "Chapters" for reading titles and the desktop chip.
      if (_windowsDesktopUi && !widget.hasScheduledVideos) {
        return SourceEmptyState(
          isReading: widget.isReading,
          onSwitchSource: widget.onSwitchSource,
        );
      }
      return EmptyState(
        icon: Icons.video_library_outlined,
        message: widget.hasScheduledVideos
            ? context.l10n.episodesNotYetAired
            : context.l10n.noEpisodesAvailableFromThisSource,
        actionLabel: widget.onSwitchSource == null
            ? null
            : context.l10n.switchSource,
        onAction: widget.onSwitchSource,
      );
    }
    final store = sl<ResumeStore>();
    final eps = _filteredEps;
    final displayEps = _displayEps;
    final total = eps.length;
    // A group with fewer chapters than the one before it can leave the range
    // index past the end, so clamp before slicing.
    final maxRange = _rangeCount == 0 ? 0 : _rangeCount - 1;
    final rangeIndex = _rangeIndex.clamp(0, maxRange);
    final slice = episodeRangeSlice(rangeIndex, total, reversed: _reverseList);
    // Windows filter (show-7): every match across all chunks, in the shown
    // order, with no range chips. Empty text keeps the chunked list.
    final filtering =
        _windowsDesktopUi &&
        widget.filmMeta == null &&
        _query.trim().isNotEmpty;
    final visible = filtering
        ? filterEpisodes(displayEps, _query)
        : displayEps.sublist(slice.start, slice.end);
    final showRanges = _rangeCount > 1;
    final groups = _scanlators;
    // Number shown for a row whose episode has none: its place in the list.
    // The filtered view looks the place up, the chunked one counts from the
    // chunk start (unchanged phone maths).
    final int Function(int i, Episode ep) fallbackNumber = filtering
        ? (i, ep) {
            final at = displayEps.indexOf(ep);
            return _reverseList ? total - at : at + 1;
          }
        : (i, ep) => _reverseList ? total - slice.start - i : slice.start + i + 1;
    // Shift ranges and Ctrl+A follow what is on screen right now.
    _orderedIds = [for (final e in visible) e.id];
    final selecting = _windowsDesktopUi && _selection.isActive;

    // One scrollable (slivers): the header + chips scroll with the list so the
    // tab can never overflow when the NestedScrollView hands it a tiny height
    // during a layout pass (the Column+Expanded version did).
    final scroll = CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Builder(
            builder: (scrollContext) {
              // Remembered for the jump reveal, which scrolls this view.
              _scrollContext = scrollContext;
              return _EpisodesHeader(
                movieLabel: widget.filmMeta,
                versionPicker: widget.versionPicker,
                hasMultipleSeasons:
                    widget.hasMultipleSeasons && widget.filmMeta == null,
                seasons: widget.seasonSet.toList()..sort(),
                currentSeason: widget.currentSeason,
                onSelectSeason: widget.onSelectSeason,
                onRefresh: widget.onRefresh,
                reverseList: _reverseList,
                onToggleReverseList: () {
                  setState(() {
                    _reverseList = !_reverseList;
                    if (_rangeCount > 0) {
                      _rangeIndex = _rangeCount - 1 - _rangeIndex;
                    }
                    _highlightEpId = null;
                    _highlightIndex = null;
                  });
                  _saveReverse(_reverseList);
                },
                grid: _grid,
                onToggleView: _toggleView,
                onJump: showRanges ? _jump : null,
                isReading: widget.isReading,
                onBulkDownload:
                    widget.onDownloadMany != null && !sl<AppMode>().isTv
                    ? () => _openBulkDownload(eps)
                    : null,
                // Windows only: search box and the "Select" button beside it.
                // Placeholder: EpisodeFilterField's "Search episodes" /
                // "Search chapters" ("filter" read oddly to users).
                filter: _windowsDesktopUi && widget.filmMeta == null
                    ? EpisodeFilterField(
                        controller: _filterCtrl,
                        focusNode: _filterFocus,
                        onChanged: _onFilterChanged,
                        onClose: _closeFilter,
                        hint: widget.isReading
                            ? EpisodeFilterField.chapterHint
                            : null,
                      )
                    : null,
                onStartSelecting: _windowsDesktopUi && widget.filmMeta == null
                    ? _selection.startSelecting
                    : null,
              );
            },
          ),
        ),
        // show-6: the selection toolbar stays pinned while the list scrolls.
        if (selecting)
          SliverPersistentHeader(
            pinned: true,
            delegate: PinnedBoxDelegate(
              height: 52,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: EpisodeSelectionBar(
                  count: _selection.selected.length,
                  isReading: widget.isReading,
                  onMarkWatched: () => unawaited(_markSelection(true)),
                  onMarkUnwatched: () => unawaited(_markSelection(false)),
                  onSelectAll: () => _selection.selectAll(_orderedIds),
                  onClear: _selection.clear,
                  // Downloaded show page: Delete takes Download's place.
                  onDownload: widget.onDeleteMany != null
                      ? null
                      : widget.isReading
                      ? (widget.onDownloadMany == null
                            ? null
                            : () => unawaited(_downloadSelection()))
                      : () => unawaited(_downloadSelection()),
                  onDelete: widget.onDeleteMany == null
                      ? null
                      : () => unawaited(_deleteSelection()),
                ),
              ),
            ),
          ),
        // Only when the tracker says the show is still airing. Sits under the
        // header so it reads as part of the episode list rather than another
        // thing competing with the hero.
        if (widget.nextAiringEpisode != null && widget.nextAiringAt != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: RichText(
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                text: TextSpan(
                  style: AppText.body.copyWith(color: AppColors.textSecondary),
                  children: [
                    TextSpan(
                      text: context.l10n.episodeLabel(
                        widget.nextAiringEpisode!,
                      ),
                    ),
                    TextSpan(text: context.l10n.airsIn),
                    // The countdown carries the weight — it's the part worth
                    // glancing at; the rest is scaffolding around it.
                    TextSpan(
                      text: airsIn(widget.nextAiringAt!, long: true),
                      style: AppText.body.copyWith(
                        color: AppColors.accent,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        // Only when a title actually has more than one group — a single
        // scanlator needs no picker, and most titles have exactly one.
        if (groups.length > 1)
          SliverToBoxAdapter(
            child: _RangeChips(
              count: groups.length + 1,
              selected: _scanlator == null
                  ? 0
                  : groups.indexOf(_scanlator!) + 1,
              labelFor: (i) => i == 0 ? context.l10n.all : groups[i - 1],
              onSelect: (i) => setState(() {
                _scanlator = i == 0 ? null : groups[i - 1];
                _rangeIndex = 0;
                _highlightEpId = null;
                _highlightIndex = null;
              }),
            ),
          ),
        // Chunks mean nothing while a filter lists every match.
        if (showRanges && !filtering)
          SliverToBoxAdapter(
            child: _RangeChips(
              count: _rangeCount,
              episodeRanges: true,
              selected: rangeIndex,
              labelFor: (i) =>
                  episodeRangeLabel(displayEps, i, reversed: _reverseList),
              onSelect: (i) => setState(() {
                _rangeIndex = i;
                _highlightEpId = null;
                _highlightIndex = null;
              }),
            ),
          ),
        // show-7: say so when the filter matches nothing.
        if (filtering && visible.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
              child: Text(
                widget.isReading
                    ? context.l10n.noChaptersMatchQuery(_query.trim())
                    : context.l10n.noEpisodesMatchQuery(_query.trim()),
                textAlign: TextAlign.center,
                style: AppText.body.copyWith(color: AppColors.textSecondary),
              ),
            ),
          ),
        if (_grid && widget.filmMeta == null)
          _buildGrid(store, visible, fallbackNumber)
        else
          _buildList(store, visible, fallbackNumber),
        const SliverToBoxAdapter(child: SizedBox(height: 48)),
      ],
    );
    if (!_windowsDesktopUi) return scroll;
    // Windows (show-6): Ctrl+A / Esc / Shift+arrows for the selection while
    // focus is in the list; the inner Focus is what a selection pulls focus to.
    return DesktopSelectionShortcuts<String>(
      selection: _selection,
      orderedKeys: () => _orderedIds,
      child: Focus(focusNode: _listFocus, child: scroll),
    );
  }

  /// Opens the chapter batch sheet. "Next N" follows the reader's saved
  /// resume target, while "All" retains its original whole-list behavior.
  void _openBulkDownload(List<Episode> eps) {
    final store = sl<ChapterDownloadStore>();
    final downloader = sl<ChapterDownloader>();
    final unavailableUrls = <String>{};
    for (final chapter in eps) {
      final id = ChapterDownload.idFor(widget.downloadSourceId, chapter.url);
      if (store.isDownloaded(widget.downloadSourceId, chapter.url) ||
          downloader.isBusy(id)) {
        unavailableUrls.add(chapter.url);
      }
    }
    final pending = selectChapterDownloadRange(
      chapters: eps,
      fromIndex: 0,
      toIndex: eps.length - 1,
      unavailableUrls: unavailableUrls,
    );

    if (pending.isEmpty) {
      showAppToast(context, context.l10n.everyChapterIsAlreadyDownloaded);
      return;
    }

    final resume = widget.resumeChapter;
    final startIndex = resolveChapterDownloadStartIndex(
      chapters: eps,
      resumeChapterId: resume?.id,
      resumeChapterUrl: resume?.url,
      resumeChapterNumber: resume?.number,
    );
    // We only need to know whether each offered preset can be filled. Capping
    // this probe at the largest preset avoids allocating the entire tail of a
    // very long chapter list merely to build the sheet.
    final fromResume = selectNextChapterDownloads(
      chapters: eps,
      startIndex: startIndex,
      count: 50,
      unavailableUrls: unavailableUrls,
    );
    final counts = [
      for (final n in [10, 25, 50])
        if (fromResume.length >= n && !(startIndex == 0 && pending.length == n))
          n,
    ];

    // show-2: phone keeps its bottom sheet; Windows gets the graphite dialog
    // with the heading in its title bar (showAdaptiveSheet forwards
    // everything unchanged off Windows).
    showAdaptiveSheet<void>(
      context,
      title: context.l10n.downloadChapters,
      subtitle: context.l10n.notSavedCount(pending.length),
      desktopWidth: 440,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The desktop dialog already has the title bar, so the handle and
            // heading are phone-only.
            if (!DesktopSheetScope.of(sheetContext)) ...[
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
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        context.l10n.downloadChapters,
                        style: AppText.headline,
                      ),
                    ),
                    Text(
                      context.l10n.notSavedCount(pending.length),
                      style: AppText.caption,
                    ),
                  ],
                ),
              ),
            ] else
              const SizedBox(height: 6),
            for (final n in counts)
              Builder(
                builder: (context) {
                  final chapters = selectNextChapterDownloads(
                    chapters: eps,
                    startIndex: startIndex,
                    count: n,
                    unavailableUrls: unavailableUrls,
                  );
                  final first = eps.indexOf(chapters.first);
                  final last = eps.indexOf(chapters.last);
                  return ListTile(
                    leading: Icon(
                      Icons.file_download_outlined,
                      color: AppColors.accent,
                    ),
                    title: Text(
                      context.l10n.nextCount(n),
                      style: AppText.body.copyWith(
                        color: AppColors.textPrimary,
                      ),
                    ),
                    subtitle: Text(
                      '${chapterNumberLabel(eps, first)} – '
                      '${chapterNumberLabel(eps, last)}',
                      style: AppText.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _enqueueAll(chapters);
                    },
                  );
                },
              ),
            ListTile(
              leading: Icon(Icons.tune_rounded, color: AppColors.accent),
              title: Text(
                context.l10n.custom,
                style: AppText.body.copyWith(color: AppColors.textPrimary),
              ),
              onTap: () async {
                Navigator.pop(sheetContext);
                // show-2: graphite dialog on Windows, sheet on phone.
                final range = await showAdaptiveSheet<({int from, int to})>(
                  context,
                  title: context.l10n.custom,
                  desktopWidth: 460,
                  isScrollControlled: true,
                  backgroundColor: AppColors.surface,
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(20),
                    ),
                  ),
                  builder: (_) => ChapterDownloadRangeSheet(
                    chapters: eps,
                    initialFromIndex: startIndex,
                    initialToIndex: (startIndex + 9).clamp(0, eps.length - 1),
                    unavailableUrls: unavailableUrls,
                  ),
                );
                if (range == null || !mounted) return;
                final chapters = selectChapterDownloadRange(
                  chapters: eps,
                  fromIndex: range.from,
                  toIndex: range.to,
                  unavailableUrls: unavailableUrls,
                );
                if (chapters.isNotEmpty) _enqueueAll(chapters);
              },
            ),
            ListTile(
              leading: Icon(
                Icons.download_for_offline_outlined,
                color: AppColors.accent,
              ),
              title: Text(
                context.l10n.allCount(pending.length),
                style: AppText.body.copyWith(color: AppColors.textPrimary),
              ),
              subtitle: pending.length > 50
                  ? Text(
                      context.l10n.thisWillTakeAWhileAndUseALotOfStorage,
                      style: AppText.caption,
                    )
                  : null,
              onTap: () {
                Navigator.pop(sheetContext);
                _enqueueAll(pending);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _enqueueAll(List<Episode> chapters) async {
    // A long series can be thousands of chapters, and one tap shouldn't commit
    // to that much storage and traffic without saying so out loud.
    if (chapters.length > 50) {
      final ok = await AppDialog.confirm(
        context,
        title: context.l10n.downloadChaptersQuestion(chapters.length),
        message: context.l10n.chapterOneAtATimeWarning,
        confirmLabel: context.l10n.download,
      );
      if (ok != true) return;
      if (!mounted) return;
    }
    await widget.onDownloadMany!(chapters);
    if (!mounted) return;
    showAppToast(context, context.l10n.queuedChapters(chapters.length));
  }

  Widget _buildList(
    ResumeStore store,
    List<Episode> visible,
    int Function(int i, Episode ep) fallbackNumber,
  ) {
    return SliverList.builder(
      itemCount: visible.length,
      itemBuilder: (context, i) {
        final row = _buildListRow(store, visible, i, fallbackNumber);
        if (!_windowsDesktopUi) return row;
        // Windows: selection wash, hover checkbox (over the thumbnail) and
        // the jump outline (show-6 / show-7).
        return _desktopFrame(
          index: i,
          ep: visible[i],
          checkboxOffset: widget.isReading
              ? const Offset(20, 8)
              : const Offset(22, 14),
          checkboxSize: widget.isReading ? 18 : 20,
          child: row,
        );
      },
    );
  }

  /// One list row (episode or chapter); identical to before on phone.
  Widget _buildListRow(
    ResumeStore store,
    List<Episode> visible,
    int i,
    int Function(int i, Episode ep) fallbackNumber,
  ) {
    final ep = visible[i];
    final fullIndex = widget.eps.indexOf(ep);
    final st = _stateFor(store, ep, fullIndex);
    final epNum = ep.number?.toInt() ?? fallbackNumber(i, ep);
    final singleMovie = widget.filmMeta != null && widget.eps.length == 1;
    final displayTitle = singleMovie && (widget.filmTitle?.isNotEmpty ?? false)
        ? widget.filmTitle!
        : widget.hasMultipleSeasons
        ? cleanTitle(ep.title)
        : ep.title;
    if (widget.isReading) {
      return RepaintBoundary(
        child: _ChapterRow(
          ep: ep,
          number: epNum,
          displayTitle: displayTitle,
          coverUrl: widget.coverUrl,
          coverHeaders: widget.coverHeaders,
          isRead: st.watched,
          isInProgress: st.inProgress,
          fraction: st.fraction,
          onTap: () => _openOrSelect(ep, fullIndex),
          onLongPress: widget.onEpisodeMenu == null
              ? null
              : () => widget.onEpisodeMenu!(fullIndex),
          onDownload: () => widget.onDownload(ep),
          sourceId: widget.sourceId,
          downloadSourceId: widget.downloadSourceId,
        ),
      );
    }
    return RepaintBoundary(
      child: _EpisodeRow(
        category: widget.category,
        ep: ep,
        epNum: epNum,
        isMovie: singleMovie,
        displayTitle: displayTitle,
        filler: isFillerEpisode(ep, widget.fillerEps, fallbackNumber: epNum),
        coverUrl: widget.coverUrl,
        coverHeaders: widget.coverHeaders,
        wideCoverUrl: widget.wideCoverUrl,
        isWatched: st.watched,
        isInProgress: st.inProgress,
        isResume: st.resume,
        fraction: st.fraction,
        onTap: () => _openOrSelect(ep, fullIndex),
        onLongPress: widget.onEpisodeMenu == null
            ? null
            : () => widget.onEpisodeMenu!(fullIndex),
        onDownload: () => widget.onDownload(ep),
        sourceId: widget.sourceId,
        showId: widget.showId,
        malId: widget.malId,
        anyCutFallback: widget.anyCutFallback,
      ),
    );
  }

  Widget _buildGrid(
    ResumeStore store,
    List<Episode> visible,
    int Function(int i, Episode ep) fallbackNumber,
  ) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      sliver: SliverGrid.builder(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 5,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 1.15,
        ),
        itemCount: visible.length,
        itemBuilder: (context, i) {
          final ep = visible[i];
          final fullIndex = widget.eps.indexOf(ep);
          final st = _stateFor(store, ep, fullIndex);
          final epNum = ep.number?.toInt() ?? fallbackNumber(i, ep);
          final tile = _EpisodeGridTile(
            number: epNum,
            isWatched: st.watched,
            isInProgress: st.inProgress,
            isResume: st.resume,
            isFiller: ep.filler,
            highlight: _highlightEpId == ep.id,
            fraction: st.fraction,
            available: ep.available,
            onTap: () => _openOrSelect(ep, fullIndex),
            onLongPress: widget.onEpisodeMenu == null
                ? null
                : () => widget.onEpisodeMenu!(fullIndex),
          );
          if (!_windowsDesktopUi) return tile;
          // Windows: selection wash + hover checkbox in the corner; the tile
          // draws its own jump outline.
          return _desktopFrame(
            index: i,
            ep: ep,
            checkboxOffset: const Offset(5, 5),
            checkboxSize: 16,
            outline: false,
            child: tile,
          );
        },
      ),
    );
  }
}

/// Windows: registers a mounted episode row by its index in the shown list,
/// so "Go to episode" knows which way to scroll until its target exists.
class _MountedRow extends StatefulWidget {
  const _MountedRow({
    required this.index,
    required this.rows,
    required this.child,
  });

  final int index;
  final Map<int, BuildContext> rows;
  final Widget child;

  @override
  State<_MountedRow> createState() => _MountedRowState();
}

/// Registers its row while mounted so the jump reveal can find it.
class _MountedRowState extends State<_MountedRow> {
  @override
  void initState() {
    super.initState();
    widget.rows[widget.index] = context;
  }

  @override
  void didUpdateWidget(covariant _MountedRow old) {
    super.didUpdateWidget(old);
    // A reused element can move to another index (new chunk / filter).
    if (old.index != widget.index) {
      if (identical(old.rows[old.index], context)) old.rows.remove(old.index);
      widget.rows[widget.index] = context;
    }
  }

  @override
  void dispose() {
    if (identical(widget.rows[widget.index], context)) {
      widget.rows.remove(widget.index);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

// ─────────────────────────────────────────────────────────────────────────────
// Episodes header with a season picker for multi-season titles.
// ─────────────────────────────────────────────────────────────────────────────

class _EpisodesHeader extends StatelessWidget {
  const _EpisodesHeader({
    this.movieLabel,
    this.versionPicker,
    required this.hasMultipleSeasons,
    required this.seasons,
    required this.currentSeason,
    required this.onSelectSeason,
    this.onRefresh,
    required this.reverseList,
    required this.onToggleReverseList,
    required this.grid,
    required this.onToggleView,
    this.onJump,
    this.isReading = false,
    this.onBulkDownload,
    this.filter,
    this.onStartSelecting,
  });

  /// Windows (show-7): the episode filter box, shown before the buttons.
  final Widget? filter;

  /// Windows (show-6): the "Select" button beside the search box; null
  /// hides it.
  final VoidCallback? onStartSelecting;

  final String? movieLabel;

  /// The episode version (Sub / Dub) picker shown in the header, if any.
  final Widget? versionPicker;
  final bool hasMultipleSeasons;
  final List<int> seasons;
  final int currentSeason;
  final ValueChanged<int> onSelectSeason;

  /// Force-refresh the list past the source cache; null hides the menu item.
  final Future<void> Function()? onRefresh;
  final bool reverseList;
  final VoidCallback onToggleReverseList;

  /// Whether the grid view is active (toggles the view icon).
  final bool grid;
  final VoidCallback onToggleView;

  /// Jump-to-episode; null hides the button (short seasons don't need it).
  final VoidCallback? onJump;

  /// True for reading types — the single-season label reads "Chapters".
  final bool isReading;

  /// Download a run of chapters at once; null hides the button. Reading only —
  /// a 200-chapter manga one tap at a time isn't a feature.
  final VoidCallback? onBulkDownload;

  Widget _circle(IconData icon, VoidCallback onTap, {String? semanticLabel}) =>
      Semantics(
        button: true,
        label: semanticLabel,
        child: Material(
          color: AppColors.surface2,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(icon, color: AppColors.textPrimary, size: 20),
            ),
          ),
        ),
      );

  Future<void> _openSheet(BuildContext context) async {
    // show-2: on Windows the season picker is a dropdown under the pill,
    // ticking the current season, instead of a phone bottom sheet.
    if (_windowsDesktopUi) {
      final picked = await showDesktopContextMenu<int>(
        context,
        anchor: context,
        items: [
          for (final s in seasons)
            DesktopMenuItem<int>(
              label: context.l10n.seasonNumber(s),
              value: s,
              checked: s == currentSeason,
            ),
        ],
      );
      if (picked != null && picked != currentSeason) onSelectSeason(picked);
      return;
    }
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: AppColors.surface,
      barrierColor: Colors.black54,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) =>
          _SeasonSheet(seasons: seasons, currentSeason: currentSeason),
    );
    if (picked != null) onSelectSeason(picked);
  }

  /// Windows: the ⋮ button opens the graphite desktop menu (same rows as the
  /// phone popup, with key hints).
  Widget _desktopMore(BuildContext context) {
    final l10n = context.l10n;
    // Shown next to the row so the remappable key is discoverable.
    String? keyHint(String id) => DesktopShortcuts.spec(id) == null
        ? null
        : DesktopShortcuts.describeAll(id);
    return Builder(
      builder: (buttonContext) => IconButton(
        tooltip: l10n.more,
        icon: const Icon(Icons.more_vert_rounded, size: 20),
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(
          backgroundColor: AppColors.surface2,
          fixedSize: const Size.square(36),
          minimumSize: const Size.square(36),
          maximumSize: const Size.square(36),
          padding: EdgeInsets.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: const CircleBorder(),
        ),
        onPressed: () => unawaited(
          showDesktopContextMenu<void>(
            buttonContext,
            anchor: buttonContext,
            items: [
              if (onRefresh != null)
                DesktopMenuItem(
                  label: isReading ? l10n.refreshChapters : l10n.refreshEpisodes,
                  icon: Icons.refresh_rounded,
                  shortcut: keyHint('show.refreshEpisodes'),
                  onTap: () {
                    unawaited(onRefresh!());
                    if (context.mounted) {
                      showAppToast(
                        context,
                        isReading
                            ? l10n.refreshingChapters
                            : l10n.refreshingEpisodes,
                      );
                    }
                  },
                ),
              DesktopMenuItem(
                label: l10n.reverseList,
                icon: Icons.swap_vert_rounded,
                checked: reverseList,
                onTap: onToggleReverseList,
              ),
              // "Select episodes" moved out of this menu to the "Select"
              // button beside the search box.
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
      child: Row(
        children: [
          // Left: season dropdown pill (multi-season) or a plain label.
          Expanded(
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: hasMultipleSeasons
                  ? Builder(
                      // The pill's own context, so the Windows dropdown opens
                      // right under it.
                      builder: (pillContext) => Material(
                      color: AppColors.surface2,
                      borderRadius: BorderRadius.circular(10),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () => _openSheet(pillContext),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  context.l10n.seasonNumber(currentSeason),
                                  style: AppText.headline,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 6),
                              const Icon(
                                Icons.keyboard_arrow_down_rounded,
                                color: AppColors.textPrimary,
                                size: 22,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    )
                  : Text(
                      movieLabel ??
                          (isReading
                              ? context.l10n.chapters
                              : context.l10n.episodes),
                      style: AppText.headline,
                    ),
            ),
          ),
          if (versionPicker case final picker?) ...[
            const SizedBox(width: 8),
            picker,
            const SizedBox(width: 8),
          ],
          // Right: episode actions.
          // Windows (show-7): the search box, shrinking on a narrow window,
          // with the "Select" button right before it (show-6).
          if (filter != null)
            Flexible(
              child: Padding(
                padding: const EdgeInsetsDirectional.only(start: 8, end: 8),
                child: Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (onStartSelecting != null) ...[
                        EpisodeSelectButton(
                          isReading: isReading,
                          onPressed: onStartSelecting!,
                        ),
                        const SizedBox(width: 8),
                      ],
                      Flexible(child: filter!),
                    ],
                  ),
                ),
              ),
            ),
          // Right: jump-to-episode (long seasons) · list/grid toggle · ⓘ info.
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (onBulkDownload != null) ...[
                _circle(
                  Icons.download_rounded,
                  onBulkDownload!,
                  semanticLabel: context.l10n.downloadChapters,
                ),
                const SizedBox(width: 8),
              ],
              if (onJump != null) ...[
                _circle(
                  Icons.search_rounded,
                  onJump!,
                  semanticLabel: context.l10n.findEpisode,
                ),
                const SizedBox(width: 8),
              ],
              if (movieLabel == null) ...[
                _circle(
                  grid ? Icons.view_list_rounded : Icons.grid_view_rounded,
                  onToggleView,
                  semanticLabel: grid
                      ? context.l10n.listView
                      : context.l10n.gridView,
                ),
                const SizedBox(width: 8),
              ],
              if (_windowsDesktopUi)
                _desktopMore(context)
              else
              PopupMenuButton<_EpisodesHeaderAction>(
                tooltip: context.l10n.more,
                icon: const Icon(Icons.more_vert_rounded, size: 20),
                padding: EdgeInsets.zero,
                style: IconButton.styleFrom(
                  backgroundColor: AppColors.surface2,
                  fixedSize: const Size.square(36),
                  minimumSize: const Size.square(36),
                  maximumSize: const Size.square(36),
                  padding: EdgeInsets.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: const CircleBorder(),
                ),
                color: AppColors.surface,
                surfaceTintColor: Colors.transparent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                onSelected: (action) {
                  if (action == _EpisodesHeaderAction.reverseList) {
                    onToggleReverseList();
                    return;
                  }
                  onRefresh?.call();
                  showAppToast(
                    context,
                    isReading
                        ? context.l10n.refreshingChapters
                        : context.l10n.refreshingEpisodes,
                  );
                },
                itemBuilder: (context) => [
                  if (onRefresh != null)
                    PopupMenuItem(
                      value: _EpisodesHeaderAction.refresh,
                      child: Row(
                        children: [
                          const Icon(Icons.refresh_rounded, size: 20),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              isReading
                                  ? context.l10n.refreshChapters
                                  : context.l10n.refreshEpisodes,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  PopupMenuItem(
                    value: _EpisodesHeaderAction.reverseList,
                    child: Row(
                      children: [
                        const Icon(Icons.swap_vert_rounded, size: 20),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            context.l10n.reverseList,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 20,
                          height: 20,
                          child: reverseList
                              ? const Icon(Icons.check_rounded, size: 18)
                              : null,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 8),
              // The ⓘ that used to sit here jumped to the Details tab — which
              // is a tap away in the tab bar directly above it. Two controls,
              // same destination, inches apart.
            ],
          ),
        ],
      ),
    );
  }
}

enum _EpisodesHeaderAction { refresh, reverseList }

// Dark, rounded-top bottom sheet listing the available seasons with a coral
// check on the current one. Returns the picked season via Navigator.pop.
class _SeasonSheet extends StatelessWidget {
  const _SeasonSheet({required this.seasons, required this.currentSeason});

  final List<int> seasons;
  final int currentSeason;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Grab handle.
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 6),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.textTertiary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(context.l10n.seasons, style: AppText.title),
            ),
          ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 8),
              itemCount: seasons.length,
              itemBuilder: (context0, i) {
                final s = seasons[i];
                final selected = s == currentSeason;
                return InkWell(
                  onTap: () => Navigator.of(context0).pop(s),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 14,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            context.l10n.seasonNumber(s),
                            style: AppText.body.copyWith(
                              color: selected
                                  ? AppColors.textPrimary
                                  : AppColors.textSecondary,
                              fontWeight: selected
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                          ),
                        ),
                        if (selected)
                          Icon(
                            Icons.check_rounded,
                            color: AppColors.accent,
                            size: 22,
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Range chips — horizontal "1–50 / 51–100 / …" selector for long seasons so
// big anime stay navigable without endless scrolling. Selected chip is coral.
// ─────────────────────────────────────────────────────────────────────────────

/// Horizontal episode ranges; Windows also accepts mouse dragging like Home rows.
class _RangeChips extends StatelessWidget {
  const _RangeChips({
    required this.count,
    required this.selected,
    required this.labelFor,
    required this.onSelect,
    this.episodeRanges = false,
  });

  final int count;
  final int selected;
  final String Function(int) labelFor;
  final ValueChanged<int> onSelect;
  final bool episodeRanges;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: episodeRanges ? 40 : 42,
      child: ScrollConfiguration(
        behavior: _windowsDesktopUi
            ? ScrollConfiguration.of(context).copyWith(
                dragDevices: {
                  ...ScrollConfiguration.of(context).dragDevices,
                  PointerDeviceKind.mouse,
                  PointerDeviceKind.trackpad,
                },
              )
            : ScrollConfiguration.of(context),
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          itemCount: count,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, i) {
            final sel = i == selected;
            return Material(
              color: sel ? AppColors.accent : AppColors.surface2,
              borderRadius: BorderRadius.circular(episodeRanges ? 999 : 9),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => onSelect(i),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: episodeRanges ? 12 : 14,
                  ),
                  child: Center(
                    child: Text(
                      labelFor(i),
                      style: AppText.caption.copyWith(
                        color: sel ? Colors.white : AppColors.textSecondary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Compact episode-number tile for the grid view — coral when it's the resume
// target, dimmed + ✓ when watched, a filler dot, and a resume bar when partly
// watched. Outlined briefly after a jump.
// ─────────────────────────────────────────────────────────────────────────────

class _EpisodeGridTile extends StatelessWidget {
  const _EpisodeGridTile({
    required this.number,
    required this.isWatched,
    required this.isInProgress,
    required this.isResume,
    required this.isFiller,
    required this.highlight,
    required this.fraction,
    required this.onTap,
    this.onLongPress,
    this.available = true,
  });

  final int number;
  final bool isWatched;
  final bool isInProgress;
  final bool isResume;
  final bool isFiller;
  final bool highlight;
  final double fraction;

  /// False when no matched source has this episode — see [Episode.available].
  final bool available;
  final VoidCallback onTap;

  /// Long-press opens the "play this episode with" sheet. Optional so the
  /// reading path can leave it off — a chapter opens the reader, where a
  /// player picker has nothing to say.
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final bg = isResume
        ? AppColors.accent
        : (isWatched ? AppColors.surface : AppColors.surface2);
    // Nothing has this one yet — same dimming the list row uses, so the two
    // views agree about which numbers will actually open.
    final fg = !available
        ? AppColors.textTertiary
        : isResume
        ? Colors.white
        : (isWatched ? AppColors.textTertiary : AppColors.textPrimary);
    final side = highlight
        ? BorderSide(color: AppColors.accent, width: 2)
        : (isResume
              ? BorderSide.none
              : const BorderSide(color: AppColors.hairline, width: 0.5));

    return Material(
      color: bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: side,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: _windowsDesktopUi ? null : onLongPress,
        onSecondaryTap: _windowsDesktopUi ? onLongPress : null,
        child: Stack(
          children: [
            Center(
              child: Text(
                '$number',
                style: AppText.body.copyWith(
                  color: fg,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (isWatched && !isResume)
              const Positioned(
                top: 4,
                right: 4,
                child: Icon(
                  Icons.check_rounded,
                  size: 13,
                  color: AppColors.textTertiary,
                ),
              ),
            if (isFiller)
              const Positioned(
                top: 6,
                left: 6,
                child: SizedBox(
                  width: 6,
                  height: 6,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: AppColors.textTertiary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            if (isInProgress)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _ThumbnailProgressBar(fraction: fraction),
              ),
          ],
        ),
      ),
    );
  }
}

// Small number-input dialog for "jump to episode".
class _JumpDialog extends StatefulWidget {
  const _JumpDialog();

  @override
  State<_JumpDialog> createState() => _JumpDialogState();
}

class _JumpDialogState extends State<_JumpDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(int.tryParse(_ctrl.text.trim()));

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(context.l10n.goToEpisode, style: AppText.headline),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        keyboardType: TextInputType.number,
        style: AppText.body.copyWith(color: AppColors.textPrimary),
        decoration: InputDecoration(
          hintText: context.l10n.episodeNumber,
          hintStyle: AppText.body.copyWith(color: AppColors.textTertiary),
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.l10n.cancel, style: AppText.body),
        ),
        TextButton(
          onPressed: _submit,
          child: Text(
            'Go',
            style: AppText.body.copyWith(color: AppColors.accent),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Reading (manga/novel) chapter row — the minimal counterpart to _EpisodeRow.
// A 44×62 portrait cover (the series art, dimmed once read), the chapter title
// with no "14." prefix (sources put the number in the title already), a muted
// meta line, and a hairline accent bar while a chapter is part-read. No play
// glyph, no tick, no badges — none of that means anything for a chapter.
//
// Deliberately a separate widget rather than a flag inside _EpisodeRow: it
// needs a third of _EpisodeRow's inputs, and this way the streaming row's code
// is untouched.
// ─────────────────────────────────────────────────────────────────────────────

class _ChapterRow extends StatelessWidget {
  const _ChapterRow({
    required this.ep,
    required this.number,
    required this.displayTitle,
    required this.coverUrl,
    required this.coverHeaders,
    required this.isRead,
    required this.isInProgress,
    required this.fraction,
    required this.onTap,
    this.onLongPress,
    required this.onDownload,
    required this.sourceId,
    required this.downloadSourceId,
  });

  /// Key on the portrait cover — the one structural marker that tells a
  /// chapter row apart from an episode row (see chapter row tests).
  static const coverKey = Key('chapterCover');

  final Episode ep;
  final int number;
  final String displayTitle;
  final String coverUrl;
  final Map<String, String>? coverHeaders;
  final bool isRead;
  final bool isInProgress;
  final double fraction;
  final VoidCallback onTap;

  /// The chapter actions menu — mark read, mark this and all above. A chapter
  /// row is NOT an episode row (that's the point of this class), so it needs
  /// its own: wiring the menu up to [_EpisodeRow] alone left reading with no
  /// long-press at all.
  final VoidCallback? onLongPress;
  final VoidCallback onDownload;
  final String sourceId;

  /// The source holding the chapter files — the matched extension for a
  /// metadata title, where [sourceId] is the pseudo-source.
  final String downloadSourceId;

  @override
  Widget build(BuildContext context) {
    final title = displayTitle.trim().isNotEmpty
        ? displayTitle.trim()
        : context.l10n.chapterLabel(number);
    final meta = chapterMetaLine(context.l10n, ep);
    final art = (ep.thumbnail != null && ep.thumbnail!.isNotEmpty)
        ? ep.thumbnail!
        : coverUrl;

    return InkWell(
      onTap: onTap,
      onLongPress: _windowsDesktopUi ? null : onLongPress,
      onSecondaryTap: _windowsDesktopUi ? onLongPress : null,
      splashColor: AppColors.accentSoft,
      highlightColor: AppColors.surface,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          _windowsDesktopUi ? 5 : 8,
          16,
          _windowsDesktopUi ? 5 : 8,
        ),
        child: Row(
          children: [
            SizedBox(
              key: coverKey,
              width: _windowsDesktopUi ? 32 : 44,
              height: _windowsDesktopUi ? 44 : 62,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Opacity(
                  opacity: isRead ? 0.45 : 1,
                  child: art.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: art,
                          cacheManager: AppImageCache.cacheManagerOrDefault,
                          httpHeaders: coverHeaders,
                          fit: BoxFit.cover,
                          memCacheWidth: 140,
                          placeholder: (c, u) =>
                              ColoredBox(color: AppColors.surface2),
                          errorWidget: (c, u, e) =>
                              ColoredBox(color: AppColors.surface2),
                        )
                      : ColoredBox(color: AppColors.surface2),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: AppText.body.copyWith(
                      color: isRead
                          ? AppColors.textTertiary
                          : AppColors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: _windowsDesktopUi ? 1 : 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  // Dropped entirely when the source gives us nothing to put
                  // here, so the row shrinks instead of holding blank space.
                  if (meta != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      meta,
                      style: AppText.caption.copyWith(
                        color: isRead
                            ? AppColors.textTertiary
                            : AppColors.textSecondary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  if (isInProgress && fraction > 0) ...[
                    const SizedBox(height: 6),
                    FractionallySizedBox(
                      widthFactor: fraction.clamp(0.0, 1.0),
                      alignment: AlignmentDirectional.centerStart,
                      child: Container(
                        height: 2,
                        decoration: BoxDecoration(
                          color: AppColors.accent,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            // Same rule as the episode row: phone only. Reading is phone-only
            // anyway, but a TV chapter list would still reach this.
            if (!sl<AppMode>().isTv) ...[
              const SizedBox(width: 8),
              _ChapterDownloadIcon(
                sourceId: downloadSourceId,
                chapterUrl: ep.url,
                onDownload: onDownload,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Netflix episode block — a Column per episode (NO divider lines, whitespace
// instead):  Row[ rounded ~116px 16:9 thumb + centered play-circle (watched dim
// / ✓ / resume bar) | "N. Title" bold + date under + CONTINUE/FILLER badges |
// download icon ]  then, when the episode has a date, a muted line full-width
// below. Our model has no per-episode synopsis/duration, so we surface the air
// date in the below-row slot and omit it gracefully when absent (no faked data).
// ─────────────────────────────────────────────────────────────────────────────

class _EpisodeRow extends StatelessWidget {
  const _EpisodeRow({
    this.isMovie = false,
    required this.ep,
    required this.category,
    required this.epNum,
    required this.displayTitle,
    required this.coverUrl,
    required this.coverHeaders,
    this.wideCoverUrl,
    required this.isWatched,
    required this.isInProgress,
    required this.isResume,
    required this.fraction,
    required this.onTap,
    this.onLongPress,
    required this.onDownload,
    required this.sourceId,
    required this.showId,
    this.filler = false,
    this.malId,
    this.anyCutFallback = false,
  });

  /// Passed on to the row's download tick for the Windows any-cut lookup
  /// (B1); see [_EpisodeDownloadIcon.malId] and
  /// [_EpisodeDownloadIcon.anyCutFallback].
  final int? malId;
  final bool anyCutFallback;

  final bool isMovie;
  final Episode ep;
  final String category;
  final int epNum;
  final String displayTitle;
  final bool filler;
  final String coverUrl;
  final Map<String, String>? coverHeaders;

  /// Windows: the show's wide picture, used before the portrait poster
  /// when the episode has no still. Null on phone and TV.
  final String? wideCoverUrl;
  final bool isWatched;
  final bool isInProgress;
  final bool isResume;
  final double fraction;
  final VoidCallback onTap;

  /// Long-press opens the "play this episode with" sheet. Optional so the
  /// reading path can leave it off — a chapter opens the reader, where a
  /// player picker has nothing to say.
  final VoidCallback? onLongPress;
  final VoidCallback onDownload;
  final String sourceId;
  final String showId;

  @override
  Widget build(BuildContext context) {
    // Listed by the catalogue, absent from every matched source. Kept in the
    // list — an airing show's next episode genuinely exists — but dimmed and
    // labelled, so it reads as "not yet" rather than as a row that silently
    // does nothing.
    final unavailable = !ep.available;
    final titleColor = unavailable
        ? AppColors.textTertiary
        : isResume
        ? AppColors.accent
        : (isWatched ? AppColors.textSecondary : AppColors.textPrimary);

    final hasStill = ep.thumbnail != null && ep.thumbnail!.isNotEmpty;
    // Windows: with no still, the show's wide picture comes before the
    // portrait poster, and a poster that is left is shown whole over a soft
    // fill instead of cropped to 16:9. Phone and TV keep the poster as is.
    // The downloaded show page draws its saved poster from disk (works
    // offline), so it never swaps to an online wide picture.
    final wide = hasStill || coverUrl.startsWith('file:')
        ? ''
        : (wideCoverUrl?.trim() ?? '');
    final useWide = wide.isNotEmpty;
    final thumbUrl = hasStill
        ? ep.thumbnail!
        : useWide
        ? wide
        : coverUrl;
    final wholePoster = _windowsDesktopUi && !hasStill && !useWide;
    // The wide picture comes from a public artwork site, so the source's
    // cover headers are not sent with it.
    final thumbHeaders = useWide ? null : coverHeaders;

    // Air date stays as a small line next to the title; the episode synopsis
    // (AniZip/TMDB, ~3 lines) spans full width below the row — under the image
    // too, CloudStream-style.
    final desc = (ep.description != null && ep.description!.trim().isNotEmpty)
        ? ep.description!.trim()
        : null;
    // Runtime · air date. The rating now rides as a chip on the thumbnail
    // (always fully visible) instead of getting clipped on this cramped line.
    final metaLine = unavailable
        // Already worded by the catalogue layer — "Airs 12 Sep" when the
        // tracker knows it isn't out, else the one source we actually asked.
        // Anything stronger would be a claim nobody verified (see
        // Episode.unavailable).
        ? ep.unavailable!
        : [
            if (ep.runtimeMinutes != null) '${ep.runtimeMinutes} min',
            if (ep.date != null && ep.date!.trim().isNotEmpty) ep.date!.trim(),
          ].join('  ·  ');

    // Prefer the real AniZip/TMDB title when the source only gave a generic
    // "Episode N" (or nothing); keep the source's own title when it has a real
    // one.
    final srcTitle = displayTitle.trim();
    final titleText =
        episodeDisplayTitle(ep, sourceTitle: srcTitle, number: epNum) ?? '';
    final heading = isMovie
        ? (srcTitle.isNotEmpty ? srcTitle : context.l10n.movie)
        : titleText.isNotEmpty
        ? '$epNum. $titleText'
        : context.l10n.episodeLabel(epNum);

    return InkWell(
      onTap: onTap,
      onLongPress: _windowsDesktopUi ? null : onLongPress,
      onSecondaryTap: _windowsDesktopUi ? onLongPress : null,
      splashColor: AppColors.accentSoft,
      highlightColor: AppColors.surface,
      child: Padding(
        // Generous vertical spacing between episodes (whitespace, no dividers).
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Rounded 16:9 thumbnail with a centered play-circle.
                SizedBox(
                  width: 116,
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          thumbUrl.isNotEmpty
                              // Downloaded show page: a thumbnail saved next
                              // to the download (file: URI) loads from disk.
                              ? localDetailImage(thumbUrl, cacheWidth: 320) ??
                                    (wholePoster
                                        ? ProgressiveArtwork(
                                            preview: ResizeImage(
                                              CachedNetworkImageProvider(
                                                thumbUrl,
                                                headers: thumbHeaders,
                                                cacheManager: AppImageCache
                                                    .cacheManagerOrDefault,
                                              ),
                                              width: 320,
                                            ),
                                            fitWhole: true,
                                            fallback: ColoredBox(
                                              color: AppColors.surface2,
                                            ),
                                          )
                                        : null) ??
                                    CachedNetworkImage(
                                      imageUrl: thumbUrl,
                                      cacheManager:
                                          AppImageCache.cacheManagerOrDefault,
                                      httpHeaders: thumbHeaders,
                                      fit: BoxFit.cover,
                                      memCacheWidth: 320,
                                      placeholder: (c, u) => ColoredBox(
                                        color: AppColors.surface2,
                                      ),
                                      errorWidget: (c, u, e) => ColoredBox(
                                        color: AppColors.surface2,
                                      ),
                                    )
                              : ColoredBox(color: AppColors.surface2),
                          if (isWatched)
                            const DecoratedBox(
                              decoration: BoxDecoration(
                                color: Color(0x73000000),
                              ),
                              child: SizedBox.expand(),
                            ),
                          // Centered play-circle (white ring like the ref).
                          Center(
                            child: DecoratedBox(
                              decoration: const BoxDecoration(
                                color: Color(0x59000000),
                                shape: BoxShape.circle,
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(7),
                                child: Icon(
                                  unavailable
                                      ? Icons.hourglass_empty_rounded
                                      : Icons.play_arrow_rounded,
                                  color: unavailable
                                      ? Colors.white70
                                      : Colors.white,
                                  size: 22,
                                ),
                              ),
                            ),
                          ),
                          if (isWatched)
                            const Positioned(
                              top: 4,
                              right: 4,
                              child: Icon(
                                Icons.check_circle,
                                color: Colors.white,
                                size: 16,
                              ),
                            ),
                          // Rating chip — top-left so it never overlaps the
                          // watched check (top-right); always fully visible,
                          // unlike the old inline "★ 8.0" that got clipped.
                          if (ep.rating != null)
                            Positioned(
                              top: 4,
                              left: 4,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: const Color(0xB3000000),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 5,
                                    vertical: 2,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(
                                        Icons.star_rounded,
                                        color: Color(0xFFFFC107),
                                        size: 11,
                                      ),
                                      const SizedBox(width: 2),
                                      Text(
                                        ep.rating!.toStringAsFixed(1),
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 10,
                                          fontWeight: FontWeight.w700,
                                          height: 1.1,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          if (isInProgress)
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: _ThumbnailProgressBar(fraction: fraction),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                // Title + date/duration under + badges.
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        heading,
                        style: AppText.body.copyWith(
                          color: titleColor,
                          fontWeight: isResume
                              ? FontWeight.w800
                              : FontWeight.w700,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (metaLine.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          metaLine,
                          style: AppText.caption.copyWith(
                            color: AppColors.textSecondary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      if (isResume || filler) ...[
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            if (isResume)
                              TagBadge(text: context.l10n.continueBadge),
                            if (isResume && filler) const SizedBox(width: 6),
                            if (filler)
                              TagBadge(text: context.l10n.fillerBadge),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                // Per-episode download icon (phone only). On TV it's redundant
                // clutter next to the main Download button + hard to focus, so
                // it's hidden — the TV path downloads via the Download action.
                if (!sl<AppMode>().isTv) ...[
                  const SizedBox(width: 8),
                  _EpisodeDownloadIcon(
                    category: category,
                    sourceId: sourceId,
                    showId: showId,
                    episodeId: ep.id,
                    episodeNumber: ep.number,
                    season: ep.season,
                    malId: malId,
                    anyCutFallback: anyCutFallback,
                    onTap: onDownload,
                  ),
                ],
              ],
            ),
            // Full-width synopsis under the whole row (under the image too).
            if (desc != null) ...[
              const SizedBox(height: 8),
              Text(
                desc,
                style: AppText.caption.copyWith(
                  color: AppColors.textSecondary,
                  fontStyle: FontStyle.italic,
                  height: 1.4,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// Per-chapter download icon (manga/novel). Watches the downloader for live
// progress and the store for what's already saved, so only this row rebuilds.
// A chapter that failed shows the plain download glyph again — enqueueing it
// again is the retry, and it picks up the pages already in the .part folder.
class _ChapterDownloadIcon extends StatelessWidget {
  const _ChapterDownloadIcon({
    required this.sourceId,
    required this.chapterUrl,
    required this.onDownload,
  });

  final String sourceId;
  final String chapterUrl;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    final downloader = sl<ChapterDownloader>();
    final store = sl<ChapterDownloadStore>();
    final id = ChapterDownload.idFor(sourceId, chapterUrl);
    return ListenableBuilder(
      listenable: Listenable.merge([downloader, store.listenable()]),
      builder: (context, _) {
        final live = downloader.inFlight[id];
        if (live != null) {
          return _button(
            tooltip: context.l10n.cancelDownload,
            onPressed: () => unawaited(downloader.cancel(id)),
            icon: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                value: live.progress > 0 ? live.progress : null,
                strokeWidth: 2.4,
                color: AppColors.accent,
                backgroundColor: AppColors.surface2,
              ),
            ),
          );
        }
        if (store.isDownloaded(sourceId, chapterUrl)) {
          // Builder: the Windows delete dropdown anchors to this tick.
          return Builder(
            builder: (iconContext) => _button(
              tooltip: context.l10n.downloaded,
              onPressed: () => _offerDelete(iconContext, store, id),
              icon: Icon(
                Icons.check_circle_rounded,
                color: AppColors.accent,
                size: 24,
              ),
            ),
          );
        }
        return _button(
          tooltip: context.l10n.downloadChapter,
          onPressed: onDownload,
          icon: const Icon(
            Icons.file_download_outlined,
            color: AppColors.textPrimary,
            size: 24,
          ),
        );
      },
    );
  }

  Widget _button({
    required String tooltip,
    required VoidCallback onPressed,
    required Widget icon,
  }) => IconButton(
    onPressed: onPressed,
    visualDensity: VisualDensity.compact,
    splashRadius: 22,
    tooltip: tooltip,
    icon: icon,
  );

  void _offerDelete(
    BuildContext context,
    ChapterDownloadStore store,
    String id,
  ) {
    // show-2: on Windows a one-row choice is a small dropdown under the tick
    // rather than a bottom sheet.
    if (_windowsDesktopUi) {
      unawaited(
        showDesktopContextMenu<void>(
          context,
          anchor: context,
          items: [
            DesktopMenuItem(
              label: context.l10n.deleteDownload,
              icon: Icons.delete_outline_rounded,
              destructive: true,
              onTap: () => unawaited(store.remove(id)),
            ),
          ],
        ),
      );
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      barrierColor: Colors.black54,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                Icons.delete_outline_rounded,
                color: AppColors.accent,
              ),
              title: Text(
                context.l10n.deleteDownload,
                style: AppText.body.copyWith(color: AppColors.accent),
              ),
              onTap: () {
                Navigator.pop(sheetContext);
                unawaited(store.remove(id));
              },
            ),
          ],
        ),
      ),
    );
  }
}

// Per-episode download icon — self-updates from the DownloadManager so the
// row reflects live progress without the whole list rebuilding.
/// Per-episode download tick. Phone and TV use the shared [EpisodeDownloadIcon]
/// unchanged; Windows keys the record by sub/dub [category], finds copies saved
/// in another cut and opens the finished-download menu.
class _EpisodeDownloadIcon extends StatelessWidget {
  const _EpisodeDownloadIcon({
    required this.sourceId,
    required this.showId,
    required this.episodeId,
    required this.category,
    required this.onTap,
    this.episodeNumber,
    this.season,
    this.malId,
    this.anyCutFallback = false,
  });

  final String sourceId;
  final String showId;
  final String episodeId;
  final String category;
  final VoidCallback onTap;

  /// Episode number and season, used only by the Windows any-cut fallback
  /// (B1) to also find files that were recovered from disk.
  final double? episodeNumber;
  final int? season;

  /// The page's MAL id, for the same any-cut lookup (matches a copy saved
  /// from another source page of this show).
  final int? malId;

  /// True only on the Windows online show page: look for this episode saved
  /// in another cut when this cut has nothing (B1). False on the phone, TV
  /// and the downloaded show page.
  final bool anyCutFallback;

  @override
  Widget build(BuildContext context) {
    if (!_windowsDesktopUi) {
      return EpisodeDownloadIcon(
        sourceId: sourceId,
        showId: showId,
        episodeId: episodeId,
        onTap: onTap,
      );
    }
    final manager = sl<DownloadManager>();
    return ListenableBuilder(
      listenable: Listenable.merge([manager, SavedStubCheck.changes]),
      builder: (context, _) {
        final exactFound = manager.recordFor(
          sourceId,
          showId,
          episodeId,
          category: category,
        );
        // Windows online page: a finished stub (by its recorded size, or by
        // its file on disk) is not shown as downloaded, the same as the
        // right-click menu (Download / Delete) and Play (streams).
        final exact =
            anyCutFallback &&
                tickCopyIsStub(exactFound, _DetailViewState._savedFileSize)
            ? null
            : exactFound;
        // B1 (Windows only): nothing live or finished in this cut, so look
        // for this episode saved in another cut (e.g. a Dub download on a
        // page that looks things up as Sub) and show that file's tick,
        // labelled with its cut. The manager lookup itself stays cut-exact.
        // Same malId as the right-click menu and Play use, so all three
        // agree; one shared record list per manager change (not per row).
        // Off on the downloaded show page, like the menu and Play.
        final other = anyCutFallback && !_liveOrDone(exact?.status)
            ? savedEpisodeAnyCut(
                SavedRecordsSnapshot.of(manager),
                sourceId: sourceId,
                showId: showId,
                episodeId: episodeId,
                episodeNumber: episodeNumber,
                season: season,
                malId: malId,
                preferredCategory: category,
              )
            : null;
        final rec = other ?? exact;
        final otherCut = other != null && other.category != category
            ? savedCutName(other.category, context.l10n)
            : null;
        // Windows: a failed or unsupported download shows as not downloaded.
        final s = shownDownloadStatus(rec?.status);
        // While a download is live (or paused/queued/resolving), tapping the ring
        // opens a Pause/Cancel menu instead of re-opening the server picker.
        final inProgress =
            rec != null &&
            (s == DownloadStatus.downloading ||
                s == DownloadStatus.paused ||
                s == DownloadStatus.queued ||
                s == DownloadStatus.resolving);
        // Windows (show-1): a finished tick opens Play offline / Show in
        // folder / Delete download / Download again instead of a new
        // source search.
        final finished =
            _windowsDesktopUi && rec != null && s == DownloadStatus.done;
        return Builder(
          // Builder: the menu anchors to the tick itself.
          builder: (iconContext) => _glyph(
            context.l10n,
            s,
            rec?.progress ?? 0,
            otherCut: otherCut,
            onPressed: inProgress
                ? () => EpisodeDownloadIcon.showDownloadMenu(
                    context,
                    manager,
                    rec,
                  )
                : finished
                ? () => unawaited(
                    EpisodeDownloadIcon.showFinishedMenu(
                      iconContext,
                      manager,
                      rec,
                      onDownloadAgain: onTap,
                    ),
                  )
                : onTap,
          ),
        );
      },
    );
  }

  /// True when this cut's own record is moving or finished, so the Windows
  /// any-cut fallback must not hide it (B1).
  static bool _liveOrDone(DownloadStatus? s) => switch (s) {
    DownloadStatus.done ||
    DownloadStatus.downloading ||
    DownloadStatus.paused ||
    DownloadStatus.queued ||
    DownloadStatus.resolving ||
    DownloadStatus.finalizing => true,
    _ => false,
  };

  Widget _glyph(
    AppLocalizations l10n,
    DownloadStatus? status,
    double progress, {
    required VoidCallback onPressed,
    // Windows (B1): the cut of a file saved in another cut, for the tooltip
    // "Downloaded · Dub". Null keeps the plain wording.
    String? otherCut,
  }) {
    final child = switch (status) {
      DownloadStatus.done => Icon(
        Icons.download_done_rounded,
        color: AppColors.accent,
        size: 24,
      ),
      DownloadStatus.downloading || DownloadStatus.paused => SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(
          value: progress > 0 ? progress : null,
          strokeWidth: 2.4,
          color: AppColors.accent,
          backgroundColor: AppColors.surface2,
        ),
      ),
      DownloadStatus.queued || DownloadStatus.resolving => const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: AppColors.textSecondary,
        ),
      ),
      DownloadStatus.unsupported => const Icon(
        Icons.cloud_off_outlined,
        color: AppColors.textTertiary,
        size: 22,
      ),
      DownloadStatus.failed => Icon(
        Icons.refresh_rounded,
        color: AppColors.accent,
        size: 24,
      ),
      // null (never downloaded) or canceled → offer to download.
      _ => const Icon(
        Icons.file_download_outlined,
        color: AppColors.textPrimary,
        size: 24,
      ),
    };
    final label = switch (status) {
      DownloadStatus.done =>
        otherCut == null ? l10n.downloaded : l10n.desktopDownloadedCut(otherCut),
      DownloadStatus.downloading || DownloadStatus.paused => l10n.downloading,
      DownloadStatus.queued || DownloadStatus.resolving => l10n.downloading,
      DownloadStatus.unsupported => l10n.downloadUnsupported,
      DownloadStatus.failed => l10n.retryDownload,
      _ => l10n.downloadEpisode,
    };
    return IconButton(
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      splashRadius: 22,
      tooltip: label,
      icon: child,
    );
  }
}

/// Empty state of the Episodes/Chapters tab when the source returned nothing.
/// Reading titles (manga, novels) say "chapters"; anime/movies say
/// "episodes". Phone keeps the shared [EmptyState] (red FilledButton)
/// unchanged. Windows mirrors that layout (icon over message) but swaps the
/// button for the hero's graphite [_IconAction] chip so the switch action
/// matches the other desktop detail buttons. Public for widget tests.
class SourceEmptyState extends StatelessWidget {
  const SourceEmptyState({
    super.key,
    required this.isReading,
    required this.onSwitchSource,
  });

  /// Manga/novel title: chapters wording and (Windows) a book icon.
  final bool isReading;

  /// Opens the source picker. Null when the title has no alternative
  /// sources, so no button is shown.
  final VoidCallback? onSwitchSource;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final message = isReading
        ? l10n.noChaptersAvailableFromThisSource
        : l10n.noEpisodesAvailableFromThisSource;
    final switchSource = onSwitchSource;
    if (!_windowsDesktopUi) {
      // Phone: the shared empty state, exactly as before (wording aside).
      return EmptyState(
        icon: Icons.video_library_outlined,
        message: message,
        actionLabel: switchSource == null ? null : l10n.switchSource,
        onAction: switchSource,
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isReading
                  ? Icons.menu_book_outlined
                  : Icons.video_library_outlined,
              size: 44,
              color: AppColors.textTertiary,
            ),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center, style: AppText.body),
            if (switchSource != null) ...[
              const SizedBox(height: 16),
              // Same chip as the hero's My List / Tracking / Share row.
              // KeyedSubtree gives tests a handle without touching _IconAction.
              KeyedSubtree(
                key: const ValueKey('desktop-empty-switch-source'),
                child: _IconAction(
                  icon: Icons.swap_horiz_rounded,
                  label: context.l10n.switchSource,
                  tooltip: context.l10n.switchSource,
                  onTap: switchSource,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
