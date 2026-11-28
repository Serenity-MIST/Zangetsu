import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/desktop/desktop_chrome_colors.dart';
import '../../core/di/injector.dart';
import '../../core/mode/content_mode.dart';
import '../../core/models/media_item.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/theme/theme_controller.dart';
import '../../core/tracker/tracker.dart';
import '../../core/tracker/tracker_hub.dart';
import '../../core/ui/desktop_settings_surface.dart';
import '../../l10n/l10n.dart';
import '../detail/detail_screen.dart';
import '../schedule/schedule_screen.dart';
import '../settings/tracker_settings_screen.dart';
import 'desktop_lists_hub_airing_panel.dart';
import 'desktop_lists_hub_library.dart';
import 'lists_hub_data.dart';
import 'lists_hub_models.dart';
import 'my_list_screen.dart';

/// Schedule and your tracker libraries, behind one door.
///
/// These used to be a card each on Home, which meant a strip of near-identical
/// slabs that grew every time a tracker was added and had to be filtered per
/// mode to stay a sensible width. A screen has room to say what each
/// destination actually is, and it drops the per-mode juggling entirely: every
/// connected tracker gets a row per kind of list it holds, named on the row, so
/// nothing here depends on the mode you arrived in.
class ListsHubScreen extends StatelessWidget {
  const ListsHubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Windows gets the two-column dashboard; phone and TV keep this list.
    if (defaultTargetPlatform == TargetPlatform.windows) {
      return const ListsHubWindowsPage();
    }
    final trackers = sl.isRegistered<TrackerHub>()
        ? sl<TrackerHub>().connected.toList()
        : const <Tracker>[];
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: Text(context.l10n.scheduleAndLists, style: AppText.barTitle),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          const _SectionLabel('BROWSE'),
          const SizedBox(height: 12),
          _HubRow(
            icon: Icons.calendar_month_rounded,
            tint: AppColors.accent,
            title: context.l10n.schedule,
            desc: context.l10n.scheduleHubDesc,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const ScheduleScreen()),
            ),
          ),
          for (final t in trackers) ...[
            const SizedBox(height: 28),
            _SectionLabel(t.displayName.toUpperCase()),
            const SizedBox(height: 12),
            for (final k in _kindsFor(t)) ...[
              _HubRow(
                icon: _iconFor(k),
                tint: _tintFor(t),
                title: _titleFor(context, t, k),
                desc: _descFor(context, k),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        MyListScreen(initialTracker: t, initialKind: k),
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
          ],
        ],
      ),
    );
  }

  /// Which lists a tracker actually holds. AniList and MAL split light novels
  /// out of the manga list (by `format`/`media_type`), so a novel row there has
  /// real content rather than being a permanently empty tab. Simkl has no
  /// reading side at all and gets the one video row; MangaBaka is the mirror
  /// of that and gets no video row, which is why this reads both flags rather
  /// than treating an anime list as a given.
  static List<ContentMode> _kindsFor(Tracker t) => [
    if (trackerSupportsVideo(t)) ContentMode.anime,
    if (t.supportsReading) ...[ContentMode.manga, ContentMode.novel],
  ];

  static IconData _iconFor(ContentMode k) => switch (k) {
    ContentMode.anime => Icons.play_circle_outline_rounded,
    ContentMode.manga => Icons.auto_stories_outlined,
    ContentMode.novel => Icons.menu_book_outlined,
  };

  /// A video-only tracker's single row says what it covers; elsewhere the kind
  /// is the whole point of the row, so it is the title.
  static String _titleFor(BuildContext context, Tracker t, ContentMode k) =>
      t.supportsReading
      ? _kindLabel(context, k)
      : context.l10n.trackerCoversVideo;

  static String _kindLabel(BuildContext context, ContentMode k) => switch (k) {
    ContentMode.anime => context.l10n.anime,
    ContentMode.manga => context.l10n.listKindManga,
    ContentMode.novel => context.l10n.listKindNovel,
  };

  static String _descFor(BuildContext context, ContentMode k) => switch (k) {
    ContentMode.anime => context.l10n.listKindAnimeDesc,
    ContentMode.manga => context.l10n.listKindMangaDesc,
    ContentMode.novel => context.l10n.listKindNovelDesc,
  };

  /// Each service's own colour, so the rows are told apart by more than their
  /// wording. Falls back to the app accent for anything unrecognised, which is
  /// what a newly added tracker gets until it is given one.
  static Color _tintFor(Tracker t) => switch (t.displayName) {
    'AniList' => const Color(0xFF02A9FF),
    'MyAnimeList' => const Color(0xFF2E51A2),
    'Simkl' => const Color(0xFF00B4E4),
    _ => AppColors.accent,
  };
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsetsDirectional.only(start: 4),
    child: Text(text, style: AppText.overline),
  );
}

/// Same furniture as the Sources hub's row, so drilling into either reads the
/// same way.
class _HubRow extends StatelessWidget {
  const _HubRow({
    required this.icon,
    required this.tint,
    required this.title,
    required this.desc,
    required this.onTap,
  });

  final IconData icon;
  final Color tint;
  final String title;
  final String desc;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.surface2,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: tint, size: 24),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: AppText.headline,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(desc, style: AppText.caption),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: AppColors.textSecondary),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Windows ──────────────────────────────────────────────────────────────

/// Where the Windows page's links go. A class so tests can record taps
/// instead of building the real destinations.
class ListsHubNavigation {
  const ListsHubNavigation();

  /// "Full week schedule": the same Schedule the phone row opens.
  void openSchedule(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => const ScheduleScreen()),
  );

  /// A list tile: that tracker's library on that kind.
  void openList(BuildContext context, Tracker tracker, ContentMode kind) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              MyListScreen(initialTracker: tracker, initialKind: kind),
        ),
      );

  /// An airing row: the show page, as the Schedule's own rows open it.
  void openShow(BuildContext context, MediaItem item) =>
      Navigator.of(context).push(DetailScreen.route(item));

  /// An airing row with no id: search the user's sources for its title.
  void openSearch(BuildContext context, String title) =>
      openTitle(context, title);

  /// "Connect": the tracker's connect screen, in the desktop settings look.
  /// It fills the window without the Settings sidebar, so its column is
  /// centred.
  Future<void> openConnect(BuildContext context, Tracker tracker) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => DesktopSettingsScope(
            standalone: true,
            child: TrackerSettingsScreen(tracker: tracker),
          ),
        ),
      );
}

/// "Updated just now" / "Updated 5 min ago" for the page header. Also used
/// by the Windows Schedule header (track-3), so it is no longer test-only.
String hubUpdatedLabel(DateTime? at, DateTime now) {
  if (at == null) return '';
  final d = now.difference(at);
  if (d.inMinutes < 1) return 'Updated just now';
  if (d.inMinutes < 60) return 'Updated ${d.inMinutes} min ago';
  if (d.inHours < 24) return 'Updated ${d.inHours} h ago';
  final days = d.inDays;
  return 'Updated $days ${days == 1 ? 'day' : 'days'} ago';
}

/// The Windows "Schedule and lists" page: today's airing on the left, the
/// tracker libraries as cover tiles on the right. Renders from cache at once
/// and refreshes in the background on open, when shown again and when a
/// tracker connects or disconnects. A failed refresh keeps what is shown.
class ListsHubWindowsPage extends StatefulWidget {
  const ListsHubWindowsPage({
    super.key,
    this.data,
    this.trackers,
    this.navigation = const ListsHubNavigation(),
    this.now,
  });

  /// Data source; defaults to the registered [ListsHubData] or a page-owned
  /// [ListsHubDataImpl].
  final ListsHubData? data;

  /// Trackers to show; defaults to [TrackerHub.trackers].
  final List<Tracker>? trackers;
  final ListsHubNavigation navigation;

  /// Clock for the header and the airing countdown (tests).
  final DateTime Function()? now;

  @override
  State<ListsHubWindowsPage> createState() => _ListsHubWindowsPageState();
}

class _ListsHubWindowsPageState extends State<ListsHubWindowsPage> {
  /// Below this content width the airing panel stacks above the tiles.
  static const double _stackBelow = 900;
  static const double _maxContent = 1180;

  /// A page shown again sooner than this does not refetch.
  static const Duration _reopenRefresh = Duration(minutes: 2);

  late final ListsHubData _data;
  ListsHubDataImpl? _owned;
  late final List<Tracker> _trackers;
  late final Listenable _trackerChanges;

  /// Connection fingerprint per tracker, so only real connect / disconnect /
  /// account changes trigger a refetch (trackers also notify on other state).
  final Map<String, String> _accounts = {};
  final Set<String> _loadingLists = {};
  bool _loadingAiring = false;
  bool _airingFailed = false;
  DateTime? _lastRefresh;
  bool _visible = true;
  Timer? _clockTick;

  DateTime _now() => (widget.now ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    final injected = widget.data;
    if (injected != null) {
      _data = injected;
    } else if (sl.isRegistered<ListsHubData>()) {
      _data = sl<ListsHubData>();
    } else {
      // No DI entry: the page owns one. The cache lives in Hive, so a new
      // instance still renders the last data immediately once the box opens.
      final owned = ListsHubDataImpl();
      unawaited(owned.ensureLoaded());
      _data = _owned = owned;
    }
    _trackers =
        widget.trackers ??
        (sl.isRegistered<TrackerHub>()
            ? sl<TrackerHub>().trackers
            : const <Tracker>[]);
    for (final t in _trackers) {
      _accounts[t.displayName] = _fingerprint(t);
    }
    _trackerChanges = Listenable.merge(_trackers);
    _trackerChanges.addListener(_onTrackersChanged);
    _refreshAll();
    // Keeps "Updated N min ago" current, and refetches airing after local
    // midnight (yesterday's cached rows are hidden by the data layer).
    _clockTick = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!mounted) return;
      if (_isNewDay()) unawaited(_refreshAiring());
      if (_visible) setState(() {});
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The desktop shell keeps visited pages alive and only flips TickerMode,
    // so coming back to this page is seen here; refresh if it has been a while.
    final visible = TickerMode.valuesOf(context).enabled;
    if (visible && !_visible) {
      final last = _lastRefresh;
      if (last == null || _now().difference(last) >= _reopenRefresh) {
        _refreshAll();
      }
    }
    _visible = visible;
  }

  @override
  void dispose() {
    _clockTick?.cancel();
    _trackerChanges.removeListener(_onTrackersChanged);
    _owned?.dispose();
    super.dispose();
  }

  static String _fingerprint(Tracker t) =>
      t.isConnected ? 'on:${t.viewerName ?? ''}' : 'off';

  /// Refetches a tracker whose connection or account changed, plus airing
  /// (its "On your list" tags depend on the connected lists).
  void _onTrackersChanged() {
    var changed = false;
    for (final t in _trackers) {
      final now = _fingerprint(t);
      if (_accounts[t.displayName] == now) continue;
      _accounts[t.displayName] = now;
      changed = true;
      if (t.isConnected) unawaited(_refreshList(t));
    }
    if (!mounted) return;
    if (changed) unawaited(_refreshAiring());
    setState(() {});
  }

  /// Background refresh of airing and every connected tracker's lists.
  void _refreshAll() {
    _lastRefresh = _now();
    unawaited(_refreshAiring());
    for (final t in _trackers) {
      if (t.isConnected) unawaited(_refreshList(t));
    }
  }

  Future<void> _refreshList(Tracker t) async {
    // Flags flip without setState: every caller rebuilds right after
    // (initState, didChangeDependencies, a listener or a tap).
    if (!_loadingLists.add(t.displayName)) return;
    try {
      await _data.refreshSummaries(t);
    } catch (_) {
      // The contract says refreshes never throw; keep the cache regardless.
    } finally {
      _loadingLists.remove(t.displayName);
      if (mounted) setState(() {});
    }
  }

  /// Local day the airing rows were last fetched for.
  DateTime? _airingDay;

  bool _isNewDay() {
    final day = _airingDay;
    final now = _now();
    return day != null &&
        (day.year != now.year || day.month != now.month || day.day != now.day);
  }

  Future<void> _refreshAiring() async {
    if (_loadingAiring) return;
    _loadingAiring = true;
    _airingDay = _now();
    try {
      await _data.refreshAiringToday();
    } catch (_) {
      // Same as above: never an error wall.
    }
    _loadingAiring = false;
    // A successful refresh always caches (even an empty day), so nothing
    // cached afterwards means it failed.
    _airingFailed = _data.cachedAiringToday() == null;
    if (mounted) setState(() {});
  }

  /// Connected trackers first, each group in the hub's own order.
  List<({Tracker tracker, bool connected})> get _tabs => [
    for (final t in _trackers)
      if (t.isConnected) (tracker: t, connected: true),
    for (final t in _trackers)
      if (!t.isConnected) (tracker: t, connected: false),
  ];

  bool get _anyLoading => _loadingAiring || _loadingLists.isNotEmpty;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    // Data notifies after each refresh; the theme revision carries Pure
    // black / Background colour / accent changes.
    listenable: Listenable.merge([_data, ThemeController.revision]),
    builder: (context, _) => Material(
      color: DesktopChrome.canvas,
      child: LayoutBuilder(builder: _layout),
    ),
  );

  Widget _layout(BuildContext context, BoxConstraints bounds) {
    final gutter = bounds.maxWidth < 700 ? 20.0 : 36.0;
    final airing = KeyedSubtree(
      key: const ValueKey('lists-hub-airing'),
      child: DesktopListsHubAiringPanel(
        items: _data.cachedAiringToday(),
        loading: _loadingAiring,
        failed: _airingFailed,
        now: widget.now,
        onOpenSchedule: () => widget.navigation.openSchedule(context),
        onOpenItem: (row) => row.item != null
            ? widget.navigation.openShow(context, row.item!)
            // No id from AniList: search the title, as the Schedule does.
            : widget.navigation.openSearch(context, row.title),
      ),
    );
    final library = Column(
      key: const ValueKey('lists-hub-library'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 14),
          child: Text('Your lists', style: AppText.headline),
        ),
        DesktopListsHubLibrary(
          trackers: _tabs,
          summariesFor: _data.cachedSummaries,
          loadingFor: (t) => _loadingLists.contains(t.displayName),
          onOpenList: (t, k) => widget.navigation.openList(context, t, k),
          onConnect: (t) => widget.navigation.openConnect(context, t),
        ),
      ],
    );
    return SingleChildScrollView(
      key: const ValueKey('lists-hub-scroll'),
      padding: EdgeInsets.fromLTRB(gutter, 28, gutter, 40),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _maxContent),
          child: LayoutBuilder(
            builder: (context, content) {
              final stacked = content.maxWidth < _stackBelow;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _header(context),
                  const SizedBox(height: 24),
                  if (stacked) ...[
                    airing,
                    const SizedBox(height: 28),
                    library,
                  ] else
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 38, child: airing),
                        const SizedBox(width: 32),
                        Expanded(flex: 62, child: library),
                      ],
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// Title, "Updated …" and, after a failed refresh, a quiet Retry.
  Widget _header(BuildContext context) {
    final canPop = ModalRoute.of(context)?.canPop ?? false;
    final updated = hubUpdatedLabel(_data.lastUpdated, _now());
    final failed = _data.lastError != null && !_anyLoading;
    final muted = AppText.caption.copyWith(color: AppColors.textSecondary);
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 6,
      children: [
        if (canPop)
          IconButton(
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back_rounded),
            color: AppColors.textSecondary,
          ),
        Text(
          context.l10n.scheduleAndLists,
          style: AppText.title.copyWith(fontSize: 26),
        ),
        if (updated.isNotEmpty)
          Text(updated, key: const ValueKey('lists-hub-updated'), style: muted),
        if (_anyLoading)
          SizedBox(
            key: const ValueKey('lists-hub-refreshing'),
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.6,
              color: AppColors.textTertiary,
            ),
          ),
        if (failed)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text("Couldn't refresh", style: muted),
              const SizedBox(width: 2),
              TextButton.icon(
                key: const ValueKey('lists-hub-retry'),
                onPressed: () => setState(_refreshAll),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.accent,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 30),
                  visualDensity: VisualDensity.compact,
                ),
                icon: SvgPicture.asset(
                  'assets/icons/lucide/rotate-cw.svg',
                  width: 14,
                  height: 14,
                  colorFilter: ColorFilter.mode(
                    AppColors.accent,
                    BlendMode.srcIn,
                  ),
                ),
                label: Text(context.l10n.retry),
              ),
            ],
          ),
      ],
    );
  }
}
