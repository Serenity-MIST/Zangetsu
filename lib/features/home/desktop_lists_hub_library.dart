import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/desktop/desktop_chrome_colors.dart';
import '../../core/mode/content_mode.dart';
import '../../core/theme/app_colors.dart';
import '../../core/tracker/tracker.dart';
import '../../core/tracker/tracker_hub.dart';
import '../../core/tracker/tracker_sync_queue.dart';
import '../../core/ui/desktop_media_card.dart';
import '../../l10n/l10n.dart';
import 'lists_hub_models.dart';

/// Which lists a tracker holds, what each tile is called and the service's
/// colour. A copy of [ListsHubScreen]'s private rules so the Windows page and
/// the phone/TV page always agree, without touching the shared screen.
abstract final class HubListKinds {
  /// Anime when the tracker covers video; manga and novel when it reads.
  static List<ContentMode> kindsFor(Tracker t) => [
    if (trackerSupportsVideo(t)) ContentMode.anime,
    if (t.supportsReading) ...[ContentMode.manga, ContentMode.novel],
  ];

  /// A video-only tracker's single tile says what it covers; elsewhere the
  /// kind is the title.
  static String titleFor(BuildContext context, Tracker t, ContentMode k) =>
      t.supportsReading
      ? kindLabel(context, k)
      : context.l10n.trackerCoversVideo;

  /// Localised name of a list kind.
  static String kindLabel(BuildContext context, ContentMode k) => switch (k) {
    ContentMode.anime => context.l10n.anime,
    ContentMode.manga => context.l10n.listKindManga,
    ContentMode.novel => context.l10n.listKindNovel,
  };

  /// Each service's own colour; the app accent for anything unrecognised.
  static Color tintFor(Tracker t) => switch (t.displayName) {
    'AniList' => const Color(0xFF02A9FF),
    'MyAnimeList' => const Color(0xFF2E51A2),
    'Simkl' => const Color(0xFF00B4E4),
    _ => AppColors.accent,
  };

  /// Lucide glyph per kind (`assets/icons/lucide/<name>.svg`).
  static String iconFor(ContentMode k) => switch (k) {
    ContentMode.anime => 'circle-play',
    ContentMode.manga => 'book-open',
    ContentMode.novel => 'book-text',
  };

  /// "12 watching · 40 planned" (anime) or "3 reading · 8 planned".
  static String countsLine(HubListSummary s) {
    final verb = s.kind == ContentMode.anime ? 'watching' : 'reading';
    return '${s.active} $verb · ${s.planned} planned';
  }
}

/// Graphite surface tones derived from the Windows chrome so Pure black and
/// a custom background reach the tiles too.
Color get _tileFill => Color.lerp(DesktopChrome.frame, Colors.white, .035)!;
Color get _tileHover => Color.lerp(DesktopChrome.frame, Colors.white, .065)!;
Color get _tileLine => Color.lerp(DesktopChrome.frame, Colors.white, .12)!;
Color get _skeleton => Color.lerp(DesktopChrome.frame, Colors.white, .07)!;

/// Lucide glyph tinted like the rest of the Windows chrome.
Widget _lucide(String name, {double size = 18, Color? color}) =>
    SvgPicture.asset(
      'assets/icons/lucide/$name.svg',
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(
        color ?? AppColors.textSecondary,
        BlendMode.srcIn,
      ),
    );

/// Soft accent halo drawn outside the border for keyboard focus, so focus
/// reads differently from hover without shifting layout.
List<BoxShadow> _focusRing(Color accent) => [
  BoxShadow(color: accent.withValues(alpha: .45), spreadRadius: 2),
];

Duration _motion(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context)
    ? Duration.zero
    : const Duration(milliseconds: 160);

/// Right column of the Windows "Schedule and lists" page: a tab per tracker
/// and, for the selected one, a tile per list kind with real covers and
/// counts. Pure widget: data and navigation come in through the callbacks.
class DesktopListsHubLibrary extends StatefulWidget {
  const DesktopListsHubLibrary({
    super.key,
    required this.trackers,
    required this.summariesFor,
    required this.loadingFor,
    required this.onOpenList,
    required this.onConnect,
    this.initialTracker,
  });

  /// Every tracker known to the hub, connected ones expected first.
  final List<({Tracker tracker, bool connected})> trackers;

  /// Cached tiles for a tracker, or null before its first load.
  final List<HubListSummary>? Function(Tracker) summariesFor;

  /// Whether a refresh for the tracker is in flight.
  final bool Function(Tracker) loadingFor;

  /// A tile was opened: show that tracker's list of [ContentMode].
  final void Function(Tracker, ContentMode) onOpenList;

  /// "Connect" was pressed for a not-connected tracker.
  final void Function(Tracker) onConnect;

  /// Tab to start on; defaults to the first connected tracker.
  final Tracker? initialTracker;

  @override
  State<DesktopListsHubLibrary> createState() => _DesktopListsHubLibraryState();
}

class _DesktopListsHubLibraryState extends State<DesktopListsHubLibrary> {
  /// Selected tab by display name, so a rebuilt tracker list keeps the tab.
  String? _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialTracker?.displayName;
  }

  /// The selected entry, falling back to the first connected, then the first.
  ({Tracker tracker, bool connected})? get _current {
    final all = widget.trackers;
    if (all.isEmpty) return null;
    for (final e in all) {
      if (e.tracker.displayName == _selected) return e;
    }
    for (final e in all) {
      if (e.connected) return e;
    }
    return all.first;
  }

  @override
  Widget build(BuildContext context) {
    final current = _current;
    if (current == null) return const _NoTrackers();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final e in widget.trackers)
              _TrackerTab(
                key: ValueKey('hub-tab-${e.tracker.displayName}'),
                tracker: e.tracker,
                connected: e.connected,
                selected: identical(e, current),
                onTap: () => setState(() => _selected = e.tracker.displayName),
              ),
          ],
        ),
        const SizedBox(height: 16),
        if (current.connected)
          _TileGrid(
            tracker: current.tracker,
            summaries: widget.summariesFor(current.tracker),
            loading: widget.loadingFor(current.tracker),
            onOpen: (k) => widget.onOpenList(current.tracker, k),
          )
        else
          _ConnectRow(
            key: ValueKey('hub-connect-${current.tracker.displayName}'),
            tracker: current.tracker,
            onConnect: () => widget.onConnect(current.tracker),
          ),
      ],
    );
  }
}

/// One tracker tab: tint dot, name and, when not connected, a dimmed note.
class _TrackerTab extends StatefulWidget {
  const _TrackerTab({
    super.key,
    required this.tracker,
    required this.connected,
    required this.selected,
    required this.onTap,
  });

  final Tracker tracker;
  final bool connected;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_TrackerTab> createState() => _TrackerTabState();
}

class _TrackerTabState extends State<_TrackerTab> {
  // Hover and keyboard focus tracked apart so leaving with the mouse never
  // hides the focus ring of a tab reached with Tab.
  bool _hover = false, _focus = false;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accent;
    final active = _hover || _focus;
    final fill = widget.selected
        ? DesktopChrome.selectedFill(accent)
        : active
        ? _tileHover
        : _tileFill;
    final border = widget.selected
        ? accent
        : active
        ? accent.withValues(alpha: .6)
        : _tileLine;
    return Semantics(
      selected: widget.selected,
      button: true,
      child: Opacity(
        opacity: widget.connected ? 1 : .55,
        child: AnimatedContainer(
          duration: _motion(context),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: border),
            boxShadow: _focus ? _focusRing(accent) : const [],
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              mouseCursor: SystemMouseCursors.click,
              focusColor: Colors.transparent,
              hoverColor: Colors.transparent,
              onTap: widget.onTap,
              onHover: (v) => setState(() => _hover = v),
              onFocusChange: (v) => setState(() => _focus = v),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: HubListKinds.tintFor(widget.tracker),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Flexible + ellipsis: a long name or translation at
                    // large text shrinks inside the Wrap row, never overflows.
                    Flexible(
                      child: Text(
                        widget.tracker.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: widget.selected
                              ? FontWeight.w700
                              : FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                    // Amber dot while this tracker's last sync failed, its
                    // login needs renewing or updates are waiting (track-2).
                    _SyncWarningDot(tracker: widget.tracker),
                    if (!widget.connected) ...[
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          context.l10n.notConnected.toLowerCase(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.textTertiary,
                          ),
                        ),
                      ),
                    ],
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

/// Small amber warning dot for a tracker tab, driven by the shared sync
/// outbox (track-2). Hidden (zero size) while the tracker is healthy; the
/// tooltip says what is wrong and where to fix it.
class _SyncWarningDot extends StatelessWidget {
  const _SyncWarningDot({required this.tracker});

  final Tracker tracker;

  @override
  Widget build(BuildContext context) {
    final queue = TrackerSyncQueue.instance;
    return ListenableBuilder(
      // Only the queue: the page already rebuilds tabs when a tracker's
      // connection changes.
      listenable: queue,
      builder: (context, _) {
        final name = tracker.displayName;
        final health = queue.healthOf(name);
        final pending = queue.pendingFor(name);
        final signIn = health.needsSignIn || trackerNeedsSignIn(tracker);
        if (!signIn && !health.failed && pending == 0) {
          return const SizedBox.shrink();
        }
        final message = signIn
            ? context.l10n.trackerNeedsSignInOpenSettings(name)
            : health.failed
            ? context.l10n.trackerLastSyncFailedRetry(name)
            : context.l10n.trackerUpdatesWaiting(pending, name);
        return Padding(
          padding: const EdgeInsets.only(left: 6),
          child: Tooltip(
            message: message,
            child: Semantics(
              label: message,
              child: Container(
                key: ValueKey('hub-sync-warning-$name'),
                width: 7,
                height: 7,
                decoration: const BoxDecoration(
                  color: trackerWarningColor,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Responsive tiles: 3 across wide, 2 narrow, 1 very narrow.
class _TileGrid extends StatelessWidget {
  const _TileGrid({
    required this.tracker,
    required this.summaries,
    required this.loading,
    required this.onOpen,
  });

  final Tracker tracker;
  final List<HubListSummary>? summaries;
  final bool loading;
  final void Function(ContentMode) onOpen;

  static const _gap = 14.0;

  @override
  Widget build(BuildContext context) {
    final kinds = HubListKinds.kindsFor(tracker);
    // Skeletons only when nothing is cached yet; cached tiles stay visible
    // while a background refresh runs.
    final skeleton = summaries == null && loading;
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        final cols = w >= 640
            ? 3
            : w >= 400
            ? 2
            : 1;
        final tileW = ((w - _gap * (cols - 1)) / cols).floorToDouble();
        return Wrap(
          spacing: _gap,
          runSpacing: _gap,
          children: [
            for (final k in kinds)
              SizedBox(
                width: tileW,
                child: skeleton
                    ? _SkeletonTile(key: ValueKey('hub-skeleton-${k.name}'))
                    : _ListTile(
                        key: ValueKey(
                          'hub-tile-${tracker.displayName}-${k.name}',
                        ),
                        tracker: tracker,
                        kind: k,
                        summary: summaries
                            ?.where((s) => s.kind == k)
                            .firstOrNull,
                        onTap: () => onOpen(k),
                      ),
              ),
          ],
        );
      },
    );
  }
}

/// Height of the cover strip shared by real and skeleton tiles.
const double _coverHeight = 112;

/// One list kind: stacked covers, name and counts. Lifts on hover/focus.
class _ListTile extends StatefulWidget {
  const _ListTile({
    super.key,
    required this.tracker,
    required this.kind,
    required this.summary,
    required this.onTap,
  });

  final Tracker tracker;
  final ContentMode kind;

  /// Null when the tracker returned nothing for this kind yet.
  final HubListSummary? summary;
  final VoidCallback onTap;

  @override
  State<_ListTile> createState() => _ListTileState();
}

class _ListTileState extends State<_ListTile> {
  // Kept apart so the keyboard focus ring survives the mouse leaving.
  bool _hover = false, _focus = false;

  @override
  Widget build(BuildContext context) {
    final tint = HubListKinds.tintFor(widget.tracker);
    final s = widget.summary;
    final active = _hover || _focus;
    return AnimatedContainer(
      duration: _motion(context),
      transform: Matrix4.translationValues(0, active ? -2 : 0, 0),
      decoration: BoxDecoration(
        color: active ? _tileHover : _tileFill,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: active ? AppColors.accent : _tileLine),
        boxShadow: [
          if (_focus) ..._focusRing(AppColors.accent),
          if (active)
            const BoxShadow(
              color: Color(0x55000000),
              blurRadius: 18,
              offset: Offset(0, 8),
            ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          mouseCursor: SystemMouseCursors.click,
          focusColor: Colors.transparent,
          hoverColor: Colors.transparent,
          onTap: widget.onTap,
          onHover: (v) => setState(() => _hover = v),
          onFocusChange: (v) => setState(() => _focus = v),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: _coverHeight,
                  child: _CoverStack(
                    covers: s?.covers ?? const [],
                    tint: tint,
                    icon: HubListKinds.iconFor(widget.kind),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    _lucide(
                      HubListKinds.iconFor(widget.kind),
                      size: 15,
                      color: tint,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        HubListKinds.titleFor(
                          context,
                          widget.tracker,
                          widget.kind,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                    _lucide(
                      'chevron-right',
                      size: 15,
                      color: active
                          ? AppColors.textPrimary
                          : AppColors.textTertiary,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  s == null ? ' ' : HubListKinds.countsLine(s),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
                // Always present (blank before data) so every tile is the
                // same height, with or without completed titles.
                Text(
                  s == null ? ' ' : '${s.completed} completed',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textTertiary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Up to three covers fanned left to right, back ones slightly smaller and
/// dimmer. Missing covers become tinted placeholders with the kind glyph.
class _CoverStack extends StatelessWidget {
  const _CoverStack({
    required this.covers,
    required this.tint,
    required this.icon,
  });

  final List<String> covers;
  final Color tint;
  final String icon;

  @override
  Widget build(BuildContext context) {
    // Always three slots so tiles line up; real covers fill from the front.
    const count = 3;
    return LayoutBuilder(
      builder: (context, c) {
        final h = c.maxHeight;
        final front = h * 2 / 3; // portrait 2:3 width of the front cover
        final step = ((c.maxWidth - front) / (count - 1)).clamp(
          0.0,
          front * .6,
        );
        return Stack(
          clipBehavior: Clip.none,
          children: [
            // Painted back to front: slot 2 (dimmest) first, slot 0 on top.
            for (var i = count - 1; i >= 0; i--)
              Positioned(
                left: step * i,
                top: i * 6.0,
                child: _Cover(
                  url: i < covers.length ? covers[i] : null,
                  width: front * (1 - i * .08),
                  height: h - i * 12.0,
                  tint: tint,
                  icon: icon,
                  dim: i * .18,
                ),
              ),
          ],
        );
      },
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover({
    required this.url,
    required this.width,
    required this.height,
    required this.tint,
    required this.icon,
    required this.dim,
  });

  final String? url;
  final double width, height;
  final Color tint;
  final String icon;

  /// Black overlay strength for covers further back.
  final double dim;

  @override
  Widget build(BuildContext context) {
    final placeholder = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [tint.withValues(alpha: .35), tint.withValues(alpha: .12)],
        ),
      ),
      child: Center(
        child: _lucide(icon, size: 22, color: tint.withValues(alpha: .8)),
      ),
    );
    return Container(
      width: width,
      height: height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: _skeleton,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: DesktopChrome.frame, width: 1.5),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 8,
            offset: Offset(2, 3),
          ),
        ],
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (url == null || url!.isEmpty)
            placeholder
          else
            // Shared desktop artwork path: cache, staged preview, decode size.
            DesktopMediaArtwork(url: url, width: width),
          if (dim > 0) ColoredBox(color: Colors.black.withValues(alpha: dim)),
        ],
      ),
    );
  }
}

/// Static placeholder tile shown before a tracker's first load.
class _SkeletonTile extends StatelessWidget {
  const _SkeletonTile({super.key});

  @override
  Widget build(BuildContext context) {
    Widget bar(double w, double h) => Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        color: _skeleton,
        borderRadius: BorderRadius.circular(6),
      ),
    );
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _tileFill,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _tileLine),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: _coverHeight,
            child: Align(
              alignment: Alignment.centerLeft,
              child: bar(_coverHeight * 2 / 3, _coverHeight),
            ),
          ),
          const SizedBox(height: 12),
          bar(90, 15),
          const SizedBox(height: 8),
          bar(140, 11),
        ],
      ),
    );
  }
}

/// Dashed invitation to connect a tracker that is not connected yet.
class _ConnectRow extends StatelessWidget {
  const _ConnectRow({
    super.key,
    required this.tracker,
    required this.onConnect,
  });

  final Tracker tracker;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final name = tracker.displayName;
    return CustomPaint(
      painter: _DashedBorderPainter(color: _tileLine, radius: 14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          alignment: WrapAlignment.spaceBetween,
          spacing: 12,
          runSpacing: 10,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _lucide('plug', size: 18, color: HubListKinds.tintFor(tracker)),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    'Connect $name to see its lists here',
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
            FilledButton(
              key: ValueKey('hub-connect-button-$name'),
              onPressed: onConnect,
              style:
                  FilledButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: DesktopChrome.onAccent(AppColors.accent),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    minimumSize: const Size(0, 34),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(9),
                    ),
                  ).copyWith(
                    mouseCursor: const WidgetStatePropertyAll(
                      SystemMouseCursors.click,
                    ),
                  ),
              child: Text(context.l10n.connect),
            ),
          ],
        ),
      ),
    );
  }
}

/// Muted note when the hub knows no trackers at all.
class _NoTrackers extends StatelessWidget {
  const _NoTrackers();

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _DashedBorderPainter(color: _tileLine, radius: 14),
    child: const Padding(
      padding: EdgeInsets.all(16),
      child: Text(
        'No trackers available',
        style: TextStyle(fontSize: 13, color: AppColors.textTertiary),
      ),
    ),
  );
}

/// Rounded dashed outline for the connect row.
class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Offset.zero & size,
          Radius.circular(radius),
        ).deflate(.6),
      );
    const dash = 6.0, gap = 4.0;
    for (final m in path.computeMetrics()) {
      for (var d = 0.0; d < m.length; d += dash + gap) {
        canvas.drawPath(m.extractPath(d, d + dash), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) =>
      old.color != color || old.radius != radius;
}
