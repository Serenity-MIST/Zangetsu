part of 'schedule_screen.dart';

// ── Windows desktop week view (track-3, 4, 5, 7, 8) ─────────────────────────
//
// Only built on Windows (see ScheduleScreen); phone keeps ScheduleBody and
// TV keeps ScheduleScreenTv. Same ScheduleCubit underneath.

/// From this content width the week shows as seven day columns; below it,
/// a day list sits beside the chosen day's rows.
const double kScheduleWeekColumnsMinWidth = 1080;

/// Width of the day list in the narrower layout.
const double _kDayListWidth = 230;

/// One schedule row in a shape both tabs share (anime airing or a movie/TV
/// release), so rows, hover cards and the right-click menu are written once.
class _DesktopScheduleRow {
  const _DesktopScheduleRow({
    required this.title,
    required this.subtitle,
    required this.kind,
    this.id,
    this.cover,
    this.airs,
    this.synopsis,
    this.malId,
    this.tmdbId,
    this.isTv = false,
    this.followed = false,
  });

  /// From an anime airing; [followed] marks a show on the user's list.
  factory _DesktopScheduleRow.airing(
    AiringEntry e,
    AppLocalizations l10n, {
    required bool followed,
  }) => _DesktopScheduleRow(
    title: e.title,
    subtitle: l10n.episodeLabel(e.episode),
    kind: ZKind.anime,
    id: e.malId == null ? null : 'mal:${e.malId}',
    cover: e.coverUrl,
    airs: e.airsAtLocal,
    synopsis: e.synopsis,
    malId: e.malId,
    followed: followed,
  );

  /// From a movie/TV release on [day] (the release date may be missing).
  factory _DesktopScheduleRow.release(
    ComingSoonEntry e,
    AppLocalizations l10n,
    String locale,
    DateTime day,
  ) {
    final date = _monthDay(e.releaseDate ?? day, locale);
    return _DesktopScheduleRow(
      title: e.title,
      // Same "S2E7 · Series · date" line the phone rows show.
      subtitle: [
        if (e.episodeLabel != null) e.episodeLabel!,
        e.isTv ? l10n.seriesWithDate(date) : l10n.movieWithDate(date),
      ].join('  ·  '),
      kind: e.isTv ? ZKind.tv : ZKind.movie,
      id: 'tmdb:${e.tmdbId}',
      cover: e.posterUrl,
      synopsis: e.synopsis,
      tmdbId: e.tmdbId,
      isTv: e.isTv,
    );
  }

  final String title;
  final String subtitle;
  final ZKind kind;

  /// Canonical id ('mal:…' / 'tmdb:…'); null when AniList gave none.
  final String? id;
  final String? cover;

  /// Air time (anime only); drives the time label and the countdown.
  final DateTime? airs;
  final String? synopsis;
  final int? malId;
  final int? tmdbId;
  final bool isTv;
  final bool followed;

  /// The library item for this row, or null without an id.
  MediaItem? get item => id == null
      ? null
      : scheduleCanonicalItem(
          kind: kind,
          id: id!,
          title: title,
          coverUrl: cover,
        );
}

/// The Windows Schedule page: header with refresh, tab switch and filter;
/// a seven-column week (or day list + day) below; hover cards, right-click
/// menus and Left/Right/Home/F5 keys.
class ScheduleDesktopView extends StatefulWidget {
  const ScheduleDesktopView({super.key, this.now});

  /// Clock for the countdowns, "Updated" label and midnight check (tests).
  final DateTime Function()? now;

  @override
  State<ScheduleDesktopView> createState() => _ScheduleDesktopViewState();
}

class _ScheduleDesktopViewState extends State<ScheduleDesktopView> {
  /// 0 = Anime, 1 = Movies & TV.
  late int _tab;
  late StreamKind _streamKind;

  /// Ticks every 30 s. Only countdowns and the "Updated" label listen to it,
  /// so the tick no longer rebuilds the whole page (track-8 B).
  late final ValueNotifier<DateTime> _clock;

  /// The local day the page currently treats as "today" (track-4).
  late DateTime _today;
  Timer? _tick;

  /// Page focus so the day keys work before anything is clicked.
  final FocusNode _pageFocus = FocusNode(debugLabel: 'schedule-desktop');

  DateTime _now() => (widget.now ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    // Open on the kind the user was browsing, like the phone page.
    _streamKind = ZModePrefs.streamKind;
    _tab = _streamKind == StreamKind.movie ? 1 : 0;
    ZModePrefs.revision.addListener(_streamKindChanged);
    final now = _now();
    _clock = ValueNotifier<DateTime>(now);
    _today = _dayOf(now);
    _tick = Timer.periodic(const Duration(seconds: 30), (_) => _onTick());
  }

  /// Follows the shell's anime / movies selector after first entry.
  void _streamKindChanged() {
    final kind = ZModePrefs.streamKind;
    if (!mounted || kind == _streamKind) return;
    _streamKind = kind;
    setState(() => _tab = kind == StreamKind.movie ? 1 : 0);
  }

  /// 30 s tick: move the clock; past midnight, roll the week over (track-4).
  void _onTick() {
    if (!mounted) return;
    final now = _now();
    _clock.value = now;
    final day = _dayOf(now);
    if (day == _today) return;
    final previous = _today;
    _today = day;
    // Moves a "today" selection to the new today and reloads the week.
    context.read<ScheduleCubit>().rollOverDay(previous, now: now);
    setState(() {}); // the seven days themselves shift by one
  }

  @override
  void dispose() {
    ZModePrefs.revision.removeListener(_streamKindChanged);
    _tick?.cancel();
    _clock.dispose();
    _pageFocus.dispose();
    super.dispose();
  }

  /// The seven days shown, starting today.
  List<DateTime> get _days => [
    for (var i = 0; i < 7; i++) _dayOf(_today.add(Duration(days: i, hours: 2))),
  ];

  /// Left / Right: previous / next day, kept inside the shown week.
  void _moveDay(int delta) {
    final cubit = context.read<ScheduleCubit>();
    final days = _days;
    var index = days.indexOf(cubit.state.selectedDay ?? _today);
    if (index < 0) index = 0;
    cubit.selectDay(days[(index + delta).clamp(0, days.length - 1)]);
  }

  // ── per-day rows (filters applied) ──

  /// Anime airing on [day], narrowed by the active My List / tracker filter.
  List<AiringEntry> _animeOn(ScheduleState state, DateTime day) {
    final list = state.airingByDay[day] ?? const <AiringEntry>[];
    final filter = state.activeFollowed;
    return filter == null ? list : list.where(filter.matches).toList();
  }

  /// Movies / TV releasing on [day].
  List<ComingSoonEntry> _soonOn(ScheduleState state, DateTime day) =>
      state.soonByDay[day] ?? const <ComingSoonEntry>[];

  /// Shared rows for [day] on the current tab.
  List<_DesktopScheduleRow> _rowsOn(
    BuildContext context,
    ScheduleState state,
    DateTime day,
  ) {
    final l10n = context.l10n;
    if (_tab == 0) {
      return [
        for (final e in _animeOn(state, day))
          _DesktopScheduleRow.airing(
            e,
            l10n,
            followed: state.followed.matches(e),
          ),
      ];
    }
    final locale = Localizations.localeOf(context).toString();
    return [
      for (final e in _soonOn(state, day))
        _DesktopScheduleRow.release(e, l10n, locale, day),
    ];
  }

  /// True while the current tab has nothing ready to show yet.
  bool _trackerLoading(ScheduleState state) =>
      _tab == 0 &&
      state.trackerFilterName != null &&
      state.loadingTrackerName == state.trackerFilterName;

  bool _loading(ScheduleState state) =>
      _tab == 0 ? state.loadingAiring : state.loadingSoon;

  bool _hasData(ScheduleState state) =>
      _tab == 0 ? state.airingAll.isNotEmpty : state.comingSoon.isNotEmpty;

  DateTime? _savedAt(ScheduleState state) =>
      _tab == 0 ? state.airingSavedAt : state.soonSavedAt;

  // ── build ──

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<ScheduleCubit>();
    return ListenableBuilder(
      // Background colour / accent changes repaint the graphite chrome.
      listenable: ThemeController.revision,
      builder: (context, _) => Material(
        color: DesktopChrome.canvas,
        child: CallbackShortcuts(
          // The lists.* ids from the shared shortcut catalogue.
          bindings: DesktopShortcuts.bindings({
            'lists.previousDay': () => _moveDay(-1),
            'lists.nextDay': () => _moveDay(1),
            'lists.today': () => cubit.selectDay(_today),
            'lists.refresh': () => unawaited(cubit.refresh()),
          }),
          child: Focus(
            focusNode: _pageFocus,
            autofocus: true,
            child: BlocBuilder<ScheduleCubit, ScheduleState>(
              builder: (context, state) => LayoutBuilder(
                builder: (context, bounds) =>
                    _page(context, state, cubit, bounds),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _page(
    BuildContext context,
    ScheduleState state,
    ScheduleCubit cubit,
    BoxConstraints bounds,
  ) {
    final gutter = bounds.maxWidth < 700 ? 16.0 : 28.0;
    final savedAt = _savedAt(state);
    return Padding(
      padding: EdgeInsets.fromLTRB(gutter, 18, gutter, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(context, state, cubit),
          const SizedBox(height: 12),
          if (savedAt != null && _hasData(state)) ...[
            _SavedCopyBanner(
              savedAt: savedAt,
              offline: state.offline,
              busy: _loading(state),
              onRetry: () => unawaited(cubit.refresh()),
            ),
            const SizedBox(height: 10),
          ],
          Expanded(
            child: _body(context, state, cubit, bounds.maxWidth - gutter * 2),
          ),
        ],
      ),
    );
  }

  /// Back, title, "Updated N min ago", busy dot; then tab switch, filter and
  /// the Refresh button on the right (track-3: refresh without a touch pull).
  Widget _header(
    BuildContext context,
    ScheduleState state,
    ScheduleCubit cubit,
  ) {
    final l10n = context.l10n;
    final canPop = ModalRoute.of(context)?.canPop ?? false;
    final muted = AppText.caption.copyWith(color: AppColors.textSecondary);
    final busy = _loading(state) || _trackerLoading(state);
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      alignment: WrapAlignment.spaceBetween,
      spacing: 12,
      runSpacing: 8,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (canPop) ...[
              IconButton(
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.arrow_back_rounded),
                color: AppColors.textSecondary,
              ),
              const SizedBox(width: 4),
            ],
            Text(l10n.schedule, style: AppText.title.copyWith(fontSize: 26)),
            const SizedBox(width: 12),
            // Only this label follows the 30 s clock, not the page.
            ValueListenableBuilder<DateTime>(
              valueListenable: _clock,
              builder: (context, now, _) {
                final label = hubUpdatedLabel(state.lastUpdated, now);
                return label.isEmpty
                    ? const SizedBox.shrink()
                    : Text(
                        label,
                        key: const ValueKey('schedule-desktop-updated'),
                        style: muted,
                      );
              },
            ),
            if (busy) ...[
              const SizedBox(width: 10),
              SizedBox(
                key: const ValueKey('schedule-desktop-busy'),
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 1.6,
                  color: AppColors.textTertiary,
                ),
              ),
            ],
          ],
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _TabSwitch(
              labels: [l10n.anime, l10n.moviesTV],
              index: _tab,
              onChanged: (i) => setState(() => _tab = i),
            ),
            if (_tab == 0) ...[
              const SizedBox(width: 8),
              _FilterButton(
                state: state,
                cubit: cubit,
                label: _filterLabel(context, state),
              ),
            ],
            const SizedBox(width: 8),
            IconButton(
              key: const ValueKey('schedule-desktop-refresh'),
              tooltip: _refreshTooltip(l10n.refresh),
              onPressed: busy ? null : () => unawaited(cubit.refresh()),
              icon: SvgPicture.asset(
                'assets/icons/lucide/rotate-cw.svg',
                width: 18,
                height: 18,
                colorFilter: ColorFilter.mode(
                  busy ? AppColors.textTertiary : AppColors.textSecondary,
                  BlendMode.srcIn,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// "Refresh (F5 / Ctrl+R)"; just "Refresh" when no key is bound.
  String _refreshTooltip(String label) {
    final keys = DesktopShortcuts.describeAll('lists.refresh');
    return keys.isEmpty ? label : '$label ($keys)';
  }

  /// "All" / "My List" / tracker name for the filter button.
  String _filterLabel(BuildContext context, ScheduleState state) {
    if (state.myListOnly) return context.l10n.myList;
    final name = state.trackerFilterName;
    if (name == null) return context.l10n.all;
    return name == 'MyAnimeList' ? 'MAL' : name;
  }

  Widget _body(
    BuildContext context,
    ScheduleState state,
    ScheduleCubit cubit,
    double width,
  ) {
    final hasData = _hasData(state);
    // Nothing to show yet: skeleton while loading (or reading a tracker).
    if ((!hasData && _loading(state)) || _trackerLoading(state)) {
      return const _DesktopScheduleSkeleton();
    }
    // Track-5 A: a failed load is an error with Retry, never "Nothing
    // airing" (a claim about the schedule that was never loaded).
    final failed = _tab == 0 ? state.errorAiring : state.errorSoon;
    if (!hasData && failed) {
      return _ScheduleErrorState(
        offline: state.offline,
        onRetry: () => unawaited(cubit.refresh()),
      );
    }
    final selected = state.selectedDay ?? _today;
    return width >= kScheduleWeekColumnsMinWidth
        ? _weekColumns(context, state, cubit, selected)
        : _dayListLayout(context, state, cubit, selected);
  }

  // ── seven columns ──

  Widget _weekColumns(
    BuildContext context,
    ScheduleState state,
    ScheduleCubit cubit,
    DateTime selected,
  ) {
    final days = _days;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        key: const ValueKey('schedule-desktop-week'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < days.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(
              child: _DayColumn(
                key: ValueKey('schedule-desktop-day-$i'),
                label: _dayName(context, days[i]),
                date: DateFormat(
                  'MMM d',
                  Localizations.localeOf(context).toString(),
                ).format(days[i]),
                selected: days[i] == selected,
                rows: _rowsOn(context, state, days[i]),
                emptyText: _emptyText(context, state),
                clock: _clock,
                onSelect: () => cubit.selectDay(days[i]),
                rowBuilder: (row) => _HoverCard(
                  card: _HoverDetails(row: row, clock: _clock),
                  child: _WeekRow(
                    row: row,
                    clock: _clock,
                    onTap: () => _open(row),
                    menuItems: () => _menuItems(row),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// "Today" / "Tomorrow" / "Wed" for a column or list header.
  String _dayName(BuildContext context, DateTime day) {
    final l10n = context.l10n;
    if (day == _today) return l10n.relativeToday;
    if (day == _dayOf(_today.add(const Duration(days: 1, hours: 2)))) {
      return l10n.relativeTomorrow;
    }
    return DateFormat(
      'EEE',
      Localizations.localeOf(context).toString(),
    ).format(day);
  }

  /// What an empty day says once the week did load.
  String _emptyText(BuildContext context, ScheduleState state) {
    final l10n = context.l10n;
    if (_tab == 1) return l10n.nothingReleasingOnThisDay;
    return state.activeFollowed != null
        ? l10n.noneOfFollowedAirOnThisDay
        : l10n.nothingAiringOnThisDay;
  }

  // ── day list beside the chosen day (narrower windows) ──

  Widget _dayListLayout(
    BuildContext context,
    ScheduleState state,
    ScheduleCubit cubit,
    DateTime selected,
  ) {
    final l10n = context.l10n;
    final locale = Localizations.localeOf(context).toString();
    final days = _days;
    final rows = _rowsOn(context, state, selected);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        key: const ValueKey('schedule-desktop-split'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: _kDayListWidth,
            child: ListView(
              children: [
                for (final d in days)
                  _DayTile(
                    label: _dayName(context, d),
                    date: DateFormat('MMM d', locale).format(d),
                    count: _rowsOn(context, state, d).length,
                    selected: d == selected,
                    onTap: () => cubit.selectDay(d),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: _Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(
                          _selectedHeader(l10n, locale, selected, _today),
                          style: AppText.headline,
                        ),
                        const SizedBox(width: 8),
                        if (rows.isNotEmpty)
                          Text(
                            l10n.scheduleCountDot(
                              rows.length,
                              _tab == 0
                                  ? l10n.scheduleNounAiring
                                  : l10n.scheduleNounReleasing,
                            ),
                            style: AppText.caption.copyWith(
                              color: AppColors.textSecondary,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: rows.isEmpty
                        ? Center(
                            child: Text(
                              _emptyText(context, state),
                              textAlign: TextAlign.center,
                              style: AppText.caption,
                            ),
                          )
                        // Lazy: a Movies day can be hundreds of rows.
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
                            itemCount: rows.length,
                            itemBuilder: (context, i) => _DetailRow(
                              row: rows[i],
                              clock: _clock,
                              onTap: () => _open(rows[i]),
                              menuItems: () => _menuItems(rows[i]),
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── actions ──

  /// Click: the show page (or a title search when there is no id).
  void _open(_DesktopScheduleRow row) => openCanonical(
    context,
    kind: row.kind,
    id: row.id,
    title: row.title,
    coverUrl: row.cover,
  );

  /// Track-7: History's right-click menu pattern for schedule rows.
  List<DesktopMenuItem<Object?>> _menuItems(_DesktopScheduleRow row) {
    final l10n = context.l10n;
    final item = row.item;
    final inList =
        item != null &&
        sl.isRegistered<MyListStore>() &&
        sl<MyListStore>().contains(item);
    return [
      DesktopMenuItem(
        label: l10n.details,
        icon: Icons.info_outline_rounded,
        onTap: () => _open(row),
      ),
      DesktopMenuItem(
        label: inList
            ? context.l10n.changeListStatusEllipsis
            : context.l10n.addToMyListEllipsis,
        icon: inList ? Icons.bookmark_rounded : Icons.bookmark_add_outlined,
        // A row without an id has no title to put on a list.
        enabled: item != null,
        onTap: () {
          if (item == null || !mounted) return;
          unawaited(
            showListStatusSheet(
              context,
              item: item,
              malId: row.malId,
              tmdbId: row.tmdbId,
              tmdbIsTv: row.isTv,
              onChanged: () {
                if (mounted) setState(() {});
              },
            ),
          );
        },
      ),
      DesktopMenuItem(
        label: l10n.searchSources,
        icon: Icons.search_rounded,
        onTap: () {
          if (mounted) openTitle(context, row.title);
        },
      ),
      const DesktopMenuItem.divider(),
      DesktopMenuItem(
        label: context.l10n.copyTitle,
        icon: Icons.copy_rounded,
        onTap: () =>
            unawaited(Clipboard.setData(ClipboardData(text: row.title))),
      ),
    ];
  }
}

// ── pieces ───────────────────────────────────────────────────────────────────

/// Graphite card used by the columns and the day pane (same fill, outline
/// and radius as the lists hub panels).
class _Panel extends StatelessWidget {
  const _Panel({required this.child, this.highlight = false});
  final Widget child;

  /// The selected day: accent outline.
  final bool highlight;

  @override
  Widget build(BuildContext context) => Container(
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: Color.lerp(DesktopChrome.frame, Colors.white, .035),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(
        color: highlight
            ? AppColors.accent.withValues(alpha: .55)
            : Color.lerp(DesktopChrome.frame, Colors.white, .12)!,
      ),
    ),
    child: child,
  );
}

/// Two-segment Anime / Movies & TV switch.
class _TabSwitch extends StatelessWidget {
  const _TabSwitch({
    required this.labels,
    required this.index,
    required this.onChanged,
  });
  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      color: Color.lerp(DesktopChrome.frame, Colors.white, .05),
      borderRadius: BorderRadius.circular(9),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < labels.length; i++)
          InkWell(
            key: ValueKey('schedule-desktop-tab-$i'),
            borderRadius: BorderRadius.circular(7),
            onTap: () => onChanged(i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: i == index
                    ? DesktopChrome.selectedFill(AppColors.accent)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(7),
              ),
              child: Text(
                labels[i],
                style: AppText.caption.copyWith(
                  fontWeight: FontWeight.w600,
                  color: i == index
                      ? AppColors.textPrimary
                      : AppColors.textSecondary,
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

/// All / My List / tracker filter, as a desktop dropdown menu.
class _FilterButton extends StatelessWidget {
  const _FilterButton({
    required this.state,
    required this.cubit,
    required this.label,
  });
  final ScheduleState state;
  final ScheduleCubit cubit;
  final String label;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final on = state.activeFollowed != null;
    return Builder(
      builder: (anchor) => InkWell(
        key: const ValueKey('schedule-desktop-filter'),
        borderRadius: BorderRadius.circular(9),
        onTap: () => showDesktopContextMenu<void>(
          context,
          anchor: anchor,
          items: [
            DesktopMenuItem(
              label: l10n.all,
              checked: state.activeFollowed == null,
              onTap: cubit.selectAllAirings,
            ),
            DesktopMenuItem(
              label: l10n.myList,
              checked: state.myListOnly,
              onTap: cubit.selectMyListFilter,
            ),
            if (state.connectedTrackerNames.isNotEmpty)
              const DesktopMenuItem.divider(),
            for (final name in state.connectedTrackerNames)
              DesktopMenuItem(
                label: name == 'MyAnimeList' ? 'MAL' : name,
                checked: state.trackerFilterName == name,
                onTap: () => unawaited(cubit.selectTrackerFilter(name)),
              ),
          ],
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: on
                ? DesktopChrome.selectedFill(AppColors.accent)
                : Color.lerp(DesktopChrome.frame, Colors.white, .05),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                state.myListOnly
                    ? Icons.bookmark_rounded
                    : Icons.filter_list_rounded,
                size: 15,
                color: on ? AppColors.accent : AppColors.textSecondary,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: AppText.caption.copyWith(
                  fontWeight: FontWeight.w600,
                  color: on ? AppColors.accent : AppColors.textSecondary,
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 16,
                color: on ? AppColors.accent : AppColors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Showing saved schedule from …" with Retry (track-5 B).
class _SavedCopyBanner extends StatelessWidget {
  const _SavedCopyBanner({
    required this.savedAt,
    required this.offline,
    required this.busy,
    required this.onRetry,
  });
  final DateTime savedAt;
  final bool offline;
  final bool busy;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context).toString();
    final when = DateFormat('EEE, MMM d', locale).add_jm().format(savedAt);
    return Container(
      key: const ValueKey('schedule-desktop-saved-copy'),
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: AppColors.accent.withValues(alpha: .25)),
      ),
      child: Row(
        children: [
          Icon(
            offline ? Icons.cloud_off_rounded : Icons.history_rounded,
            size: 16,
            color: AppColors.accent,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              // While a load is still running nothing has failed yet, so
              // the banner must not claim "Couldn't refresh" (the saved copy
              // is shown straight away on open).
              busy
                  ? context.l10n.scheduleSavedUpdating(when)
                  : offline
                  ? context.l10n.scheduleOfflineCopy(when)
                  : context.l10n.scheduleCouldntRefresh(when),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppText.caption.copyWith(color: AppColors.textPrimary),
            ),
          ),
          TextButton(
            onPressed: busy ? null : onRetry,
            style: TextButton.styleFrom(
              foregroundColor: AppColors.accent,
              visualDensity: VisualDensity.compact,
            ),
            child: Text(context.l10n.retry),
          ),
        ],
      ),
    );
  }
}

/// Failed load with nothing saved: say so, offer Retry (track-5 A).
class _ScheduleErrorState extends StatelessWidget {
  const _ScheduleErrorState({required this.offline, required this.onRetry});
  final bool offline;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Center(
      key: const ValueKey('schedule-desktop-error'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              offline ? Icons.cloud_off_rounded : Icons.error_outline_rounded,
              size: 34,
              color: AppColors.textTertiary,
            ),
            const SizedBox(height: 12),
            Text(
              offline
                  ? l10n.offlineTitle
                  : l10n.couldntLoadSchedule,
              textAlign: TextAlign.center,
              style: AppText.headline,
            ),
            const SizedBox(height: 6),
            Text(
              offline
                  ? l10n.offlineBody
                  : l10n.scheduleServiceNoAnswer,
              textAlign: TextAlign.center,
              style: AppText.caption.copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const ValueKey('schedule-desktop-retry'),
              onPressed: onRetry,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: DesktopChrome.onAccent(AppColors.accent),
              ),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: Text(l10n.retry),
            ),
          ],
        ),
      ),
    );
  }
}

/// One day of the seven-column week.
class _DayColumn extends StatelessWidget {
  const _DayColumn({
    super.key,
    required this.label,
    required this.date,
    required this.selected,
    required this.rows,
    required this.emptyText,
    required this.clock,
    required this.onSelect,
    required this.rowBuilder,
  });
  final String label;
  final String date;
  final bool selected;
  final List<_DesktopScheduleRow> rows;
  final String emptyText;
  final ValueListenable<DateTime> clock;
  final VoidCallback onSelect;
  final Widget Function(_DesktopScheduleRow row) rowBuilder;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      highlight: selected,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Day header: click (hand cursor via InkWell) selects the day.
          InkWell(
            onTap: onSelect,
            child: Container(
              color: selected
                  ? DesktopChrome.selectedFill(AppColors.accent, strength: .1)
                  : null,
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.headline.copyWith(
                            fontSize: 14,
                            color: selected
                                ? AppColors.textPrimary
                                : AppColors.textSecondary,
                          ),
                        ),
                        Text(
                          date,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.caption.copyWith(fontSize: 11.5),
                        ),
                      ],
                    ),
                  ),
                  if (rows.isNotEmpty)
                    _CountPill(count: rows.length, on: selected),
                ],
              ),
            ),
          ),
          Divider(
            height: 1,
            color: Color.lerp(DesktopChrome.frame, Colors.white, .1),
          ),
          Expanded(
            child: rows.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      emptyText,
                      textAlign: TextAlign.center,
                      style: AppText.caption.copyWith(fontSize: 11.5),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(4),
                    itemCount: rows.length,
                    itemBuilder: (context, i) => rowBuilder(rows[i]),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Small rounded count next to a day name.
class _CountPill extends StatelessWidget {
  const _CountPill({required this.count, required this.on});
  final int count;
  final bool on;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
      color: on ? AppColors.accent.withValues(alpha: .18) : AppColors.surface2,
      borderRadius: BorderRadius.circular(99),
    ),
    child: Text(
      '$count',
      style: AppText.caption.copyWith(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: on ? AppColors.accent : AppColors.textSecondary,
      ),
    ),
  );
}

/// One day in the narrow layout's day list.
class _DayTile extends StatelessWidget {
  const _DayTile({
    required this.label,
    required this.date,
    required this.count,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final String date;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Material(
      color: selected
          ? DesktopChrome.selectedFill(AppColors.accent)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: AppText.body.copyWith(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: selected
                            ? AppColors.textPrimary
                            : AppColors.textSecondary,
                      ),
                    ),
                    Text(date, style: AppText.caption.copyWith(fontSize: 11.5)),
                  ],
                ),
              ),
              if (count > 0) _CountPill(count: count, on: selected),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Shared hover / focus highlight for schedule rows, with right-click and
/// Menu-key support through [DesktopContextMenuRegion].
class _RowSurface extends StatefulWidget {
  const _RowSurface({
    required this.child,
    required this.onTap,
    required this.menuItems,
    this.followed = false,
  });
  final Widget child;
  final VoidCallback onTap;
  final List<DesktopMenuItem<Object?>> Function() menuItems;
  final bool followed;

  @override
  State<_RowSurface> createState() => _RowSurfaceState();
}

class _RowSurfaceState extends State<_RowSurface> {
  bool _hover = false, _focus = false;

  @override
  Widget build(BuildContext context) {
    var fill = widget.followed
        ? AppColors.accent.withValues(alpha: .07)
        : Colors.transparent;
    if (_hover || _focus) {
      fill = Color.alphaBlend(Colors.white.withValues(alpha: .05), fill);
    }
    return DesktopContextMenuRegion(
      items: widget.menuItems,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            onHover: (v) => setState(() => _hover = v),
            onFocusChange: (v) => setState(() => _focus = v),
            borderRadius: BorderRadius.circular(8),
            hoverColor: Colors.transparent,
            focusColor: Colors.transparent,
            child: Container(
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _focus ? AppColors.accent : Colors.transparent,
                ),
              ),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact row for a week column: thumb, two-line title, time / episode
/// and (anime) a live countdown.
class _WeekRow extends StatelessWidget {
  const _WeekRow({
    required this.row,
    required this.clock,
    required this.onTap,
    required this.menuItems,
  });
  final _DesktopScheduleRow row;
  final ValueListenable<DateTime> clock;
  final VoidCallback onTap;
  final List<DesktopMenuItem<Object?>> Function() menuItems;

  @override
  Widget build(BuildContext context) {
    final airs = row.airs;
    final locale = Localizations.localeOf(context).toString();
    final time = airs == null ? null : _timeParts(airs, locale);
    return _RowSurface(
      onTap: onTap,
      menuItems: menuItems,
      followed: row.followed,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _cachedThumb(row.cover, 28, 40),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    row.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.body.copyWith(
                      fontSize: 12.5,
                      height: 1.25,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    time == null
                        ? row.subtitle
                        : '${time.hm} ${time.ap}  ·  ${row.subtitle}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption.copyWith(fontSize: 11),
                  ),
                  if (airs != null) _Countdown(airs: airs, clock: clock),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Wider row for the day pane: time rail, thumb, full-title tooltip.
class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.row,
    required this.clock,
    required this.onTap,
    required this.menuItems,
  });
  final _DesktopScheduleRow row;
  final ValueListenable<DateTime> clock;
  final VoidCallback onTap;
  final List<DesktopMenuItem<Object?>> Function() menuItems;

  @override
  Widget build(BuildContext context) {
    final airs = row.airs;
    final locale = Localizations.localeOf(context).toString();
    final time = airs == null ? null : _timeParts(airs, locale);
    return _RowSurface(
      onTap: onTap,
      menuItems: menuItems,
      followed: row.followed,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            if (time != null)
              SizedBox(
                width: 54,
                child: Text(
                  '${time.hm} ${time.ap}',
                  style: AppText.caption.copyWith(
                    fontWeight: FontWeight.w700,
                    color: AppColors.textSecondary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            _cachedThumb(row.cover, 36, 50),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Track-7: titles are cut to one line, so hovering shows
                  // the whole title.
                  Tooltip(
                    message: row.title,
                    waitDuration: const Duration(milliseconds: 500),
                    child: Text(
                      row.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.body.copyWith(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    row.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption,
                  ),
                ],
              ),
            ),
            if (airs != null) ...[
              const SizedBox(width: 8),
              _Countdown(airs: airs, clock: clock, large: true),
            ],
          ],
        ),
      ),
    );
  }
}

/// "LIVE" / "2h 10m" / "Aired" that alone follows the 30 s clock.
class _Countdown extends StatelessWidget {
  const _Countdown({
    required this.airs,
    required this.clock,
    this.large = false,
  });
  final DateTime airs;
  final ValueListenable<DateTime> clock;
  final bool large;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<DateTime>(
    valueListenable: clock,
    builder: (context, now, _) {
      final status = _airStatus(context.l10n, airs, now);
      return Text(
        status.text,
        maxLines: 1,
        style: AppText.caption.copyWith(
          fontSize: large ? 11.5 : 10.5,
          fontWeight: FontWeight.w800,
          color: status.live ? _live : AppColors.accent,
        ),
      );
    },
  );
}

/// The bigger card shown after hovering a week-column row (track-3).
class _HoverDetails extends StatelessWidget {
  const _HoverDetails({required this.row, required this.clock});
  final _DesktopScheduleRow row;
  final ValueListenable<DateTime> clock;

  @override
  Widget build(BuildContext context) {
    final airs = row.airs;
    final locale = Localizations.localeOf(context).toString();
    final time = airs == null ? null : _timeParts(airs, locale);
    final synopsis = row.synopsis?.trim();
    return Container(
      width: 320,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Color.lerp(DesktopChrome.frame, Colors.white, .06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Color.lerp(DesktopChrome.frame, Colors.white, .16)!,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .45),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cachedThumb(row.cover, 72, 102),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Full title: the column rows cut it to two lines.
                Text(
                  row.title,
                  style: AppText.body.copyWith(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  time == null
                      ? row.subtitle
                      : '${row.subtitle}  ·  ${time.hm} ${time.ap}',
                  style: AppText.caption,
                ),
                if (airs != null) ...[
                  const SizedBox(height: 2),
                  _Countdown(airs: airs, clock: clock, large: true),
                ],
                if (synopsis != null && synopsis.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    synopsis,
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption.copyWith(
                      color: AppColors.textSecondary,
                      height: 1.35,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Shows [card] beside [child] after a short hover; hides on exit or tap.
/// Placed right of the row, or left when there is no room, and kept inside
/// the window vertically.
class _HoverCard extends StatefulWidget {
  const _HoverCard({required this.child, required this.card});
  final Widget child;
  final Widget card;

  @override
  State<_HoverCard> createState() => _HoverCardState();
}

class _HoverCardState extends State<_HoverCard> {
  final OverlayPortalController _portal = OverlayPortalController();
  Timer? _delay;

  /// Card width used for placement (matches [_HoverDetails]).
  static const double _cardWidth = 320;

  void _enter() {
    _delay?.cancel();
    _delay = Timer(const Duration(milliseconds: 450), () {
      if (mounted) _portal.show();
    });
  }

  void _exit() {
    _delay?.cancel();
    if (_portal.isShowing) _portal.hide();
  }

  @override
  void dispose() {
    _delay?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => _enter(),
    onExit: (_) => _exit(),
    child: Listener(
      // Any click (open, right-click menu) dismisses the card.
      onPointerDown: (_) => _exit(),
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: _buildCard,
        child: widget.child,
      ),
    ),
  );

  Widget _buildCard(BuildContext overlayContext) {
    final box = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.maybeOf(context)?.context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null || !box.attached) {
      return const SizedBox.shrink();
    }
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    final size = overlay.size;
    const gap = 8.0;
    final right = topLeft.dx + box.size.width + gap;
    final left = right + _cardWidth <= size.width - gap
        ? right
        : (topLeft.dx - gap - _cardWidth).clamp(gap, size.width);
    // Keep it on screen: a generous guess of the card height is enough.
    final top = topLeft.dy.clamp(
      gap,
      (size.height - 180).clamp(gap, size.height),
    );
    return Positioned(
      left: left.toDouble(),
      top: top.toDouble(),
      // Display only: never steals hover or clicks from the rows.
      child: IgnorePointer(child: widget.card),
    );
  }
}

/// Poster thumb from the shared disk image cache, decoded at about 3x the
/// box width instead of full size (track-8 A). Works offline once cached.
Widget _cachedThumb(String? url, double w, double h) => ClipRRect(
  borderRadius: BorderRadius.circular(6),
  child: SizedBox(
    width: w,
    height: h,
    child: url == null || url.isEmpty
        ? ColoredBox(color: AppColors.surface2)
        : CachedNetworkImage(
            imageUrl: url,
            fit: BoxFit.cover,
            memCacheWidth: (w * 3).round(),
            placeholder: (_, _) => ColoredBox(color: AppColors.surface2),
            errorWidget: (_, _, _) => ColoredBox(color: AppColors.surface2),
          ),
  ),
);

/// Static placeholder columns while the week loads.
class _DesktopScheduleSkeleton extends StatelessWidget {
  const _DesktopScheduleSkeleton();

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    key: const ValueKey('schedule-desktop-loading'),
    // Clips instead of overflowing in a short window; never scrolls.
    physics: const NeverScrollableScrollPhysics(),
    padding: const EdgeInsets.only(bottom: 16),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < 4; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: Column(
              children: [
                for (var j = 0; j < 5; j++)
                  Container(
                    height: 52,
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      color: Color.lerp(DesktopChrome.frame, Colors.white, .05),
                      borderRadius: BorderRadius.circular(9),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    ),
  );
}
