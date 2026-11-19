import '../../core/ui/desktop_media_card.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../../core/desktop/desktop_focus_repair.dart';
import '../../core/desktop/desktop_chrome_colors.dart';
import '../../core/desktop/desktop_context_menu.dart';
import '../../core/desktop/desktop_row_scroller.dart';
import '../../core/desktop/desktop_shortcuts.dart';
import '../downloads/downloads_screen.dart';
import '../../core/metadata/streaming_service.dart';
import '../../core/models/home_section.dart';
import '../../core/models/media_item.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_font_prefs.dart';
import '../../core/theme/theme_controller.dart';
import '../../core/ui/featured_hero.dart' show HeroMeta;
import '../../core/ui/poster_card.dart';
import '../../core/ui/poster_palette.dart';
import 'streaming_service_card.dart';
import '../../l10n/l10n.dart';

const _muted = Color(0xFFADB2BE);

/// Home accent, read live from Theme & colour (never a fixed red).
Color get _accent => AppColors.accent;

/// True on the Windows desktop build. Every newer Home behaviour (cursor
/// menus, shelf arrows, banner controls, shortcuts) is gated on it; it reads
/// the target platform, not dart:io, so phone and tests keep today's Home.
bool get _windows => defaultTargetPlatform == TargetPlatform.windows;

/// How long each featured title stays in the banner before auto-advancing.
const desktopHomeBannerInterval = Duration(seconds: 8);

/// Rows "New from your list" shows on Windows before the "+N more" line.
/// Three keeps the column no taller than the Continue cards beside it.
const desktopHomeReleaseRows = 3;

/// One entry of the desktop Home arrangement, in the order saved under
/// Settings > Home rows. The Home adapter builds these from HomeCubit's merged
/// rows, so hiding, reordering and resetting rows drives the desktop shelves.
class DesktopHomeRow {
  /// The Continue block: the resume shelf plus "New from your list".
  DesktopHomeRow.resume()
    : section = null,
      onOpen = null,
      onAll = null,
      onMenu = null,
      tagsFor = null,
      progressFor = null,
      builder = null;

  /// A poster shelf. Null callbacks fall back to the page's own handlers
  /// (open Detail, see-all for the section, the poster menu).
  DesktopHomeRow.shelf(
    HomeSection this.section, {
    this.onOpen,
    this.onAll,
    this.onMenu,
    this.tagsFor,
    this.progressFor,
  }) : builder = null;

  /// A self-contained row such as the streaming services rail.
  DesktopHomeRow.custom(WidgetBuilder this.builder)
    : section = null,
      onOpen = null,
      onAll = null,
      onMenu = null,
      tagsFor = null,
      progressFor = null;

  final HomeSection? section;
  final ValueChanged<MediaItem>? onOpen, onMenu;
  final VoidCallback? onAll;

  /// Always-shown artwork badges for an item (for example "+2" new episodes).
  final List<String> Function(MediaItem)? tagsFor;

  /// Progress badge for an item; shown only while Poster cards > Badges >
  /// Watch progress is on.
  final String? Function(MediaItem)? progressFor;
  final WidgetBuilder? builder;

  bool get isResume => section == null && builder == null;
}

/// Fresh Windows Home view model. It carries real progress and actions, never
/// presentation widgets from the phone Home or the previous desktop layout.
class DesktopHomeResume {
  const DesktopHomeResume({
    required this.title,
    required this.subtitle,
    required this.progress,
    required this.open,
    this.menu,
    this.image,
    this.headers,
    this.remaining,
  });
  final String title, subtitle;
  final double progress;
  final String? image, remaining;
  final Map<String, String>? headers;
  final VoidCallback open;
  final VoidCallback? menu;
}

/// A library release with trustworthy text supplied by the data adapter.
class DesktopHomeRelease {
  const DesktopHomeRelease({
    required this.title,
    required this.subtitle,
    required this.open,
    this.image,
    this.headers,
    this.menu,
  });
  final String title, subtitle;
  final String? image;
  final Map<String, String>? headers;
  final VoidCallback open;

  /// Right-click / Menu key actions for the row (Windows); null = no menu.
  final VoidCallback? menu;
}

/// A show with saved files, offered on Home when the app is offline or the
/// catalogue came back empty. [subtitle] is built by the adapter from real
/// counts (for example "3 episodes saved"); nothing is invented here.
class DesktopHomeDownload {
  const DesktopHomeDownload({
    required this.title,
    required this.subtitle,
    required this.open,
    this.image,
    this.headers,
  });
  final String title, subtitle;
  final String? image;
  final Map<String, String>? headers;
  final VoidCallback open;
}

/// Entirely new desktop composition based on the approved screenshot. Legacy
/// Home cards, banner styles, mobile headers and shelf widgets never enter it.
class DesktopHomePage extends StatefulWidget {
  const DesktopHomePage({
    super.key,
    required this.featured,
    required this.sections,
    required this.resume,
    required this.releases,
    required this.reading,
    required this.onOpen,
    required this.onPlay,
    required this.onMenu,
    required this.onSection,
    required this.onHistory,
    required this.onReleases,
    required this.onRefresh,
    required this.meta,
    required this.playLabel,
    this.loading = false,
    this.error,
    this.onCatalogue,
    this.onVerify,
    this.onReconnect,
    this.reconnectLabel = 'Reconnect to sync',
    this.footer,
    this.downloads = const [],
    this.offline = false,
    this.onDownloads,
    this.rows,
    this.adaptiveColour,
    this.heroColour,
    this.continueListenable,
    this.resumeItems,
  });

  /// Fires when watch/read history changes. When set, only the Continue
  /// block rebuilds on it (via a ListenableBuilder) instead of all of Home.
  final Listenable? continueListenable;

  /// Live resume items, read each time the Continue block rebuilds. Null
  /// falls back to [resume].
  final List<DesktopHomeResume> Function()? resumeItems;

  /// The saved Home rows arrangement. Null (before the first load merges)
  /// keeps the built-in order: Continue first, then the catalogue shelves
  /// with Trending leading.
  final List<DesktopHomeRow>? rows;

  /// Overrides Theme & colour > Adaptive colour; null reads the setting.
  final bool? adaptiveColour;

  /// Reads the dominant colour of the featured art. Null uses the same
  /// palette extraction as Detail. Injectable for tests.
  final Future<Color?> Function(MediaItem item)? heroColour;

  /// Saved shows. Shown as a shelf while [offline] or when the catalogue is
  /// empty, so Home always has something playable.
  final List<DesktopHomeDownload> downloads;

  /// True when the app started without a network connection.
  final bool offline;

  /// Opens the full Downloads page. Null hides the shortcut buttons.
  final VoidCallback? onDownloads;
  final List<MediaItem> featured;
  final List<HomeSection> sections;
  final List<DesktopHomeResume> resume;
  final List<DesktopHomeRelease> releases;
  final bool reading, loading;
  final String? error;
  final ValueChanged<MediaItem> onOpen, onPlay, onMenu;
  final ValueChanged<HomeSection> onSection;
  final VoidCallback onHistory, onReleases;
  final Future<void> Function() onRefresh;
  final Future<HeroMeta?> Function(MediaItem) meta;
  final String Function(MediaItem) playLabel;
  final VoidCallback? onCatalogue;
  final VoidCallback? onVerify;
  final VoidCallback? onReconnect;
  final String reconnectLabel;
  final Widget? footer;
  @override
  State<DesktopHomePage> createState() => _DesktopHomePageState();
}

/// Keeps scroll and featured selection local without copying any account data.
class _DesktopHomePageState extends State<DesktopHomePage>
    with WidgetsBindingObserver {
  final _scroll = ScrollController();
  int _featuredIndex = 0;

  /// Windows: a non-traversable focus target for the whole page, so F5 and
  /// Home/End reach the page shortcuts even before any card has focus.
  final _pageFocus = FocusNode(debugLabel: 'desktop-home', skipTraversal: true);

  /// Windows banner auto-rotate (home-5 B). One-shot timer, restarted after
  /// every change so a manual pick always gets a full interval.
  Timer? _rotate;

  /// Pointer over / keyboard focus inside the banner: auto-rotate waits.
  bool _bannerHovered = false, _bannerFocused = false;

  /// False while the window is in the background (not focused / minimised).
  bool _windowActive = true;

  /// True while a header Refresh started here is running.
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    // R1: lost focus (a text field left, a tab switch) comes back here.
    DesktopFocusRepair.register(_pageFocus);
    if (_windows) {
      WidgetsBinding.instance.addObserver(this);
      final state = WidgetsBinding.instance.lifecycleState;
      _windowActive = state == null || state == AppLifecycleState.resumed;
      _scheduleRotate();
    }
  }

  @override
  void didUpdateWidget(DesktopHomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new featured list (reload, catalogue switch) restarts the clock, and
    // stops it when fewer than two titles remain.
    if (_windows &&
        (oldWidget.featured.length != widget.featured.length ||
            oldWidget.offline != widget.offline)) {
      _scheduleRotate();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Windows reports inactive when the window loses focus and hidden when
    // it is minimised: the banner only moves while the user can see it.
    final active = state == AppLifecycleState.resumed;
    if (active == _windowActive) return;
    _windowActive = active;
    if (active) _scheduleRotate();
  }

  /// (Re)starts the banner countdown; no-op off Windows or with < 2 titles.
  void _scheduleRotate() {
    _rotate?.cancel();
    _rotate = null;
    if (!_windows || widget.offline || widget.featured.length < 2) return;
    _rotate = Timer(desktopHomeBannerInterval, _autoAdvance);
  }

  /// Timer tick: advance unless hovered, focused, reduced motion is on, the
  /// window is in the background or another page covers Home.
  void _autoAdvance() {
    if (!mounted) return;
    final reducedMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final covered = !(ModalRoute.of(context)?.isCurrent ?? true);
    if (_bannerHovered ||
        _bannerFocused ||
        !_windowActive ||
        reducedMotion ||
        covered) {
      _scheduleRotate();
      return;
    }
    _showFeature(_featuredIndex + 1);
  }

  /// Shows featured title [index] (wrapping both ways) and restarts the clock.
  void _showFeature(int index) {
    final count = widget.featured.length;
    if (count == 0) return;
    setState(() => _featuredIndex = index % count);
    _scheduleRotate();
  }

  /// Hover / focus changes from the banner; leaving restarts the countdown.
  void _holdBanner({bool? hovered, bool? focused}) {
    final wasHeld = _bannerHovered || _bannerFocused;
    _bannerHovered = hovered ?? _bannerHovered;
    _bannerFocused = focused ?? _bannerFocused;
    if (wasHeld && !(_bannerHovered || _bannerFocused)) _scheduleRotate();
  }

  /// Header Refresh button and F5 / Ctrl+R (home-4 Home part, home-9).
  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await widget.onRefresh();
    } catch (_) {
      // The page's own error state reports failures; the button just resets.
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  /// Home / End: jump the page to the top or bottom (home-9).
  void _jumpPage({required bool end}) {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    final target = end ? p.maxScrollExtent : p.minScrollExtent;
    if (MediaQuery.disableAnimationsOf(context)) {
      _scroll.jumpTo(target);
    } else {
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    }
  }

  /// Dominant colour of the featured art for the Adaptive colour wash; null
  /// shows the plain canvas. Blended against the background at build time, so
  /// changing Pure black / Background colour re-tints without a re-sample.
  final _tint = ValueNotifier<Color?>(null);

  /// Artwork the current [_tint] was (or is being) read from.
  String? _tintSource;
  int _tintRequest = 0;

  @override
  void dispose() {
    _rotate?.cancel();
    // Safe even when never added (removeObserver just returns false).
    WidgetsBinding.instance.removeObserver(this);
    // R1: stop offering this node to the focus repair.
    DesktopFocusRepair.unregister(_pageFocus);
    _pageFocus.dispose();
    _scroll.dispose();
    _tint.dispose();
    super.dispose();
  }

  bool get _adaptive => widget.adaptiveColour ?? ThemeController.adaptiveColour;

  /// Keeps the Adaptive colour wash in step with the featured title. Runs
  /// after the frame because it may change [_tint], which a builder listens
  /// to.
  void _syncTint(MediaItem? hero) {
    final banner = hero?.banner?.trim();
    final url = hero == null || !_adaptive
        ? null
        : banner?.isNotEmpty == true
        ? banner
        : hero.cover;
    if (url == _tintSource) return;
    _tintSource = url;
    final request = ++_tintRequest;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || request != _tintRequest) return;
      if (url == null || url.isEmpty) {
        _tint.value = null;
        return;
      }
      final read =
          widget.heroColour?.call(hero!) ??
          extractAdaptiveColor(
            adaptiveSampleUrl(url, backdrop: url == banner),
            url == hero!.cover ? hero.coverHeaders : null,
          );
      unawaited(
        read.then((colour) {
          if (!mounted || request != _tintRequest) return;
          // Raw dominant colour; the wash is blended at build time.
          _tint.value = colour;
        }, onError: (_) {}),
      );
    });
  }

  // Theme, font and poster revisions rebuild the whole page so accent,
  // background, font and every Poster cards setting apply immediately.
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      ThemeController.revision,
      AppFontPrefs.revision,
      PlaybackPrefs.posterRevision,
    ]),
    builder: (context, _) =>
        _windows ? _withShortcuts(_page(context)) : _page(context),
  );

  /// Windows Home keys (home-9): F5 / Ctrl+R refresh, Home / End jump to the
  /// top / bottom. Enter and the Menu key are handled by the focused card
  /// itself ([DesktopCardKeys]) so they never swallow keys from buttons.
  Widget _withShortcuts(Widget page) => CallbackShortcuts(
    bindings: DesktopShortcuts.bindings({
      'app.refresh': () => unawaited(_refresh()),
      'home.first': () => _jumpPage(end: false),
      'home.last': () => _jumpPage(end: true),
    }),
    child: Focus(
      focusNode: _pageFocus,
      autofocus: true,
      child: Listener(
        // A click on Home brings keyboard focus back to the page so the
        // shortcuts work after focus was elsewhere (a card keeps its own).
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) {
          if (!_pageFocus.hasFocus) _pageFocus.requestFocus();
        },
        child: page,
      ),
    ),
  );

  Widget _page(BuildContext context) {
    final canvas = DesktopChrome.canvas;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Canvas follows Pure black / Background colour. With Adaptive colour
        // on, the featured art's colour washes down from the top.
        Positioned.fill(
          child: IgnorePointer(
            child: ValueListenableBuilder<Color?>(
              valueListenable: _tint,
              builder: (context, dominant, _) => AnimatedContainer(
                key: const ValueKey('desktop-home-canvas'),
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : adaptiveColourDuration,
                curve: adaptiveColourCurve,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      // Off (or no sample yet) shows the plain canvas.
                      dominant == null || !_adaptive
                          ? canvas
                          : tintFromDominant(
                              dominant,
                              blend: adaptiveColourBlend,
                            ),
                      canvas,
                    ],
                    stops: const [0, .75],
                  ),
                ),
              ),
            ),
          ),
        ),
        LayoutBuilder(builder: _content),
      ],
    );
  }

  /// The arrangement to draw: the saved Home rows when known, otherwise the
  /// built-in order (Continue, then shelves with Trending first).
  List<DesktopHomeRow> _layout() {
    final saved = widget.rows;
    if (saved != null) {
      // Offline, catalogue shelves cannot open anything; Continue stays.
      return widget.offline ? [...saved.where((r) => r.isResume)] : saved;
    }
    final shelves = widget.offline ? <HomeSection>[] : [...widget.sections];
    // The reference leads with Trending. Keep every other real source section.
    final trending = shelves.indexWhere(
      (s) => s.title.toLowerCase().contains('trending'),
    );
    if (trending > 0) shelves.insert(0, shelves.removeAt(trending));
    return [
      DesktopHomeRow.resume(),
      for (final s in shelves) DesktopHomeRow.shelf(s),
    ];
  }

  Widget _content(BuildContext context, BoxConstraints bounds) {
    final width = bounds.maxWidth;
    final scaled = MediaQuery.textScalerOf(context).scale(14) > 21;
    final wide = width >= 1000 && !scaled;
    // Offline, the cached hero and catalogue shelves are hidden: they look
    // online but cannot open anything. Downloads and history stay.
    final hero = widget.offline || widget.featured.isEmpty
        ? null
        : widget.featured[_featuredIndex % widget.featured.length];
    _syncTint(hero);
    final rows = <Widget>[];
    var shelfIndex = 0;
    final layout = _layout();
    // Hiding "Continue watching" removes only the resume shelf; library
    // releases ("New from your list") keep their place at the top.
    if (!layout.any((r) => r.isResume) && widget.releases.isNotEmpty) {
      rows.add(
        KeyedSubtree(
          key: const ValueKey('desktop-home-releases-only'),
          child: _LibraryReleasePanel(
            items: widget.releases,
            onAll: widget.onReleases,
          ),
        ),
      );
    }
    for (final row in layout) {
      final Widget? child;
      if (row.isResume) {
        final live = widget.continueListenable;
        if (live != null) {
          // Only the Continue block listens to history changes, so a resume
          // update does not rebuild the hero or the catalogue shelves. It is
          // always mounted; an empty history collapses it to nothing.
          child = ListenableBuilder(
            listenable: live,
            builder: (_, _) => _resumeItems.isEmpty && widget.releases.isEmpty
                ? const SizedBox.shrink()
                : _resumeBlock(wide),
          );
        } else {
          child = widget.resume.isEmpty && widget.releases.isEmpty
              ? null
              : _resumeBlock(wide);
        }
      } else if (row.builder != null) {
        child = row.builder!(context);
      } else {
        final section = row.section!;
        if (section.items.isEmpty) continue;
        // Only the leading shelf can carry Trending ranks.
        final ranked =
            shelfIndex == 0 && section.title.toLowerCase().contains('trending');
        shelfIndex++;
        child = _RankedPosterShelf(
          section: section,
          onAll: row.onAll ?? () => widget.onSection(section),
          onOpen: row.onOpen ?? widget.onOpen,
          onMenu: row.onMenu ?? widget.onMenu,
          tagsFor: row.tagsFor,
          progressFor: row.progressFor,
          ranked: ranked,
        );
      }
      if (child == null) continue;
      if (rows.isNotEmpty) rows.add(const SizedBox(height: 16));
      rows.add(child);
    }
    return Scrollbar(
      controller: _scroll,
      child: CustomScrollView(
        controller: _scroll,
        key: const PageStorageKey('desktop-reference-home'),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            sliver: SliverList.list(
              children: [
                if (widget.onReconnect != null) ...[
                  _SessionNotice(
                    label: widget.reconnectLabel,
                    onReconnect: widget.onReconnect!,
                  ),
                  const SizedBox(height: 12),
                ],
                if (hero != null)
                  // home-10: the hero's "Continue E5" label reads history,
                  // so it follows the Continue store like the resume shelf.
                  _followContinue(
                    (_) => _bannerControls(
                    _CinematicHero(
                      item: hero,
                      meta: widget.meta(hero),
                      height: scaled
                          ? 520
                          : ((width - 32) * .226).clamp(280, 350),
                      onPlay: () => widget.onPlay(hero),
                      onDetails: () => widget.onOpen(hero),
                      playLabel: widget.playLabel(hero),
                      onCatalogue: widget.onCatalogue,
                      onNext: widget.featured.length > 1
                          ? () => _showFeature(_featuredIndex + 1)
                          : null,
                      // Windows only (home-5): Previous, position dots and
                      // the header Refresh (home-4's Home part).
                      onPrevious: _windows && widget.featured.length > 1
                          ? () => _showFeature(
                              _featuredIndex - 1 + widget.featured.length,
                            )
                          : null,
                      index: _featuredIndex % widget.featured.length,
                      count: widget.featured.length,
                      onSelect: _windows && widget.featured.length > 1
                          ? _showFeature
                          : null,
                      onRefresh: _windows ? () => unawaited(_refresh()) : null,
                      refreshing: _refreshing || widget.loading,
                    ),
                  ),
                  )
                else
                  _HomeFeedback(
                    loading: widget.loading,
                    message:
                        widget.error ??
                        (widget.offline
                            ? (widget.downloads.isEmpty
                                  ? "You're offline. Connect to browse the catalogue."
                                  : "You're offline. Your downloads are ready to watch.")
                            : 'Your catalogue is empty.'),
                    onRetry: widget.onRefresh,
                    onVerify: widget.onVerify,
                    onCatalogue: widget.onCatalogue,
                    offline: widget.offline,
                    // Only offer the shortcut when there is something to open.
                    onDownloads: widget.downloads.isEmpty
                        ? null
                        : widget.onDownloads,
                  ),
                const SizedBox(height: 12),
                // Offline, or nothing to show from the catalogue: put the
                // saved shows first so Home is never a dead end.
                if (widget.downloads.isNotEmpty &&
                    (widget.offline || (hero == null && !widget.loading))) ...[
                  _DownloadsShelf(
                    title: widget.offline
                        ? 'Available offline'
                        : 'Your downloads',
                    items: widget.downloads,
                    onAll: widget.onDownloads,
                  ),
                  const SizedBox(height: 16),
                ],
                ...rows,
                if (widget.loading && hero != null)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: LinearProgressIndicator(
                      minHeight: 2,
                      color: _accent,
                    ),
                  ),
                if (widget.footer != null) ...[
                  const SizedBox(height: 20),
                  widget.footer!,
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Windows banner input (home-5): hover and focus pause auto-rotate, and
  /// Left / Right step through the featured titles while focus is inside it.
  Widget _bannerControls(Widget banner) {
    if (!_windows) return banner;
    final many = widget.featured.length > 1;
    return MouseRegion(
      onEnter: (_) => _holdBanner(hovered: true),
      onExit: (_) => _holdBanner(hovered: false),
      child: Focus(
        // Pass-through: it only watches focus and keys of its buttons.
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (focused) => _holdBanner(focused: focused),
        onKeyEvent: (node, event) {
          if (!many || event is KeyUpEvent) return KeyEventResult.ignored;
          final key = event.logicalKey;
          if (key == LogicalKeyboardKey.arrowLeft) {
            _showFeature(_featuredIndex - 1 + widget.featured.length);
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.arrowRight) {
            _showFeature(_featuredIndex + 1);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: banner,
      ),
    );
  }

  /// Current resume items: the live getter when Home supplies one (read on
  /// each Continue rebuild), otherwise the list passed at construction.
  List<DesktopHomeResume> get _resumeItems =>
      widget.resumeItems?.call() ?? widget.resume;

  /// Rebuilds [build] on [DesktopHomePage.continueListenable] when Home
  /// supplies one (home-10); otherwise builds it once like before.
  Widget _followContinue(WidgetBuilder build) {
    final live = widget.continueListenable;
    if (live == null) return build(context);
    return ListenableBuilder(
      listenable: live,
      builder: (context, _) => build(context),
    );
  }

  /// Continue shelf with "New from your list" beside it (stacked when narrow).
  Widget _resumeBlock(bool wide) => wide
      ? Row(
          key: const ValueKey('desktop-home-continue'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 77,
              child: _ResumeShelf(
                items: _resumeItems,
                reading: widget.reading,
                onAll: widget.onHistory,
              ),
            ),
            const SizedBox(width: 20),
            Expanded(
              flex: 23,
              child: _LibraryReleasePanel(
                items: widget.releases,
                onAll: widget.onReleases,
              ),
            ),
          ],
        )
      : Column(
          key: const ValueKey('desktop-home-continue'),
          children: [
            _ResumeShelf(
              items: _resumeItems,
              reading: widget.reading,
              onAll: widget.onHistory,
            ),
            if (widget.releases.isNotEmpty)
              _LibraryReleasePanel(
                items: widget.releases,
                onAll: widget.onReleases,
              ),
          ],
        );
}

/// Poster shelf geometry from Poster cards > Shape, Portrait/Landscape card
/// size and Title placement. Default size keeps the original seven-up
/// portrait shelf (four-up landscape); Small fits one more card, Large one
/// fewer. Height comes from the same maths as every other desktop grid.
({double width, double height, bool wide}) desktopShelfGeometry(
  BuildContext context,
  double maxWidth,
) {
  final wide = posterLayout(context) == PosterCardLayout.wide;
  final scale = posterCardScale(context);
  final step = scale < 1
      ? 1
      : scale > 1
      ? -1
      : 0;
  final base = wide
      ? (maxWidth >= 1050 ? 4 : math.max(1, (maxWidth / 280).floor()))
      : (maxWidth >= 1050 ? 7 : math.max(2, (maxWidth / 165).floor()));
  final count = math.max(wide ? 1 : 2, base + step);
  final width = (maxWidth - (count - 1) * 12) / count;
  return (
    width: width,
    height: DesktopMediaCard.height(
      width,
      MediaQuery.textScalerOf(context).scale(1),
      wide: wide,
      titleInside: posterTitleInside(context, wide: wide),
    ),
    wide: wide,
  );
}

/// New typography-led feature with real wide artwork and bounded description.
class _CinematicHero extends StatelessWidget {
  const _CinematicHero({
    required this.item,
    required this.meta,
    required this.height,
    required this.onPlay,
    required this.onDetails,
    required this.playLabel,
    this.onCatalogue,
    this.onNext,
    this.onPrevious,
    this.onSelect,
    this.onRefresh,
    this.index = 0,
    this.count = 1,
    this.refreshing = false,
  });
  final MediaItem item;
  final Future<HeroMeta?> meta;
  final double height;
  final VoidCallback onPlay, onDetails;
  final VoidCallback? onCatalogue, onNext;

  /// Windows: previous featured title; null hides the button.
  final VoidCallback? onPrevious;

  /// Windows: jump to a featured title from its position dot; null hides
  /// the dots.
  final ValueChanged<int>? onSelect;

  /// Windows: header Refresh; null hides it.
  final VoidCallback? onRefresh;

  /// Position of this title among [count] featured titles (for the dots).
  final int index, count;

  /// Shows a small spinner instead of the Refresh icon while loading.
  final bool refreshing;
  final String playLabel;

  /// Scrim base: the canvas pushed toward black (the stock canvas gives the
  /// original 0xFF080B0E-ish shade).
  Color get _shade => Color.lerp(DesktopChrome.canvas, Colors.black, .4)!;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('desktop-home-feature'),
    height: height,
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: const Color(0xFF30343A)),
    ),
    child: LayoutBuilder(
      builder: (context, bounds) => Stack(
        fit: StackFit.expand,
        children: [
          DesktopMediaArtwork(
            url: item.banner ?? item.cover,
            headers: item.coverHeaders,
            width: bounds.maxWidth,
          ),
          // Legibility scrims shade from the page canvas, so Pure black and a
          // custom Background colour carry into the feature panel.
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  _shade.withValues(alpha: .98),
                  _shade.withValues(alpha: .85),
                  _shade.withValues(alpha: .086),
                ],
                stops: const [0, .32, 1],
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.center,
                colors: [_shade.withValues(alpha: .52), Colors.transparent],
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: bounds.maxWidth < 700 ? 22 : 42,
                vertical: 22,
              ),
              child: SizedBox(
                width: bounds.maxWidth < 700
                    ? bounds.maxWidth - 44
                    : bounds.maxWidth * .43,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    InkWell(
                      onTap: onCatalogue,
                      child: const Padding(
                        padding: EdgeInsets.symmetric(vertical: 4),
                        child: Text(
                          'ZANGETSU PRESENTS',
                          style: TextStyle(
                            fontSize: 9,
                            letterSpacing: 3.3,
                            color: Color(0xFFB9BDC7),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    // No fixed family: the title inherits Theme & colour >
                    // Font like the rest of the app.
                    Text(
                      item.title,
                      key: const ValueKey('desktop-home-feature-title'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        // The display size needs a full-width window; below
                        // that the smaller size keeps the panel from clipping.
                        fontSize: bounds.maxWidth < 900 ? 29 : 40,
                        height: 1.02,
                        letterSpacing: -.8,
                        fontWeight: FontWeight.w700,
                        color: const Color(0xFFF5F5F7),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Flexible(
                      child: FutureBuilder<HeroMeta?>(
                        future: meta,
                        builder: (context, snap) {
                          final description = snap.data?.description
                              ?.replaceAll(RegExp(r'<[^>]*>'), '')
                              .trim();
                          return Text(
                            description?.isNotEmpty == true
                                ? description!
                                : (snap.data?.genres ?? item.genres)
                                      .take(3)
                                      .join(' · '),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              height: 1.5,
                              color: _muted,
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 20),
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        _HeroAction(
                          label: playLabel,
                          icon: 'play',
                          primary: true,
                          onTap: onPlay,
                        ),
                        _HeroAction(label: context.l10n.details, onTap: onDetails),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (onNext != null)
            Positioned(
              right: 10,
              bottom: 10,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Windows: Previous beside Next (mirrored chevron, since
                  // the bundled Lucide set has no chevron-left).
                  if (onPrevious != null) ...[
                    _HomeIconButton(
                      key: const ValueKey('desktop-home-feature-previous'),
                      icon: 'chevron-right',
                      label: context.l10n.previousFeature,
                      onTap: onPrevious!,
                      mirror: true,
                      backdrop: true,
                    ),
                    const SizedBox(width: 6),
                  ],
                  _HomeIconButton(
                    key: const ValueKey('desktop-home-feature-next'),
                    icon: 'chevron-right',
                    label: context.l10n.nextFeature,
                    onTap: onNext!,
                    backdrop: onPrevious != null,
                  ),
                ],
              ),
            ),
          // Windows: clickable position dots, centred along the bottom.
          if (onSelect != null && count > 1)
            Positioned(
              left: 0,
              right: 0,
              bottom: 6,
              child: Center(
                child: _BannerDots(
                  count: count,
                  index: index,
                  onSelect: onSelect!,
                ),
              ),
            ),
          // Windows: no visible Refresh button on the banner any more (user
          // feedback); F5 / Ctrl+R still refresh. Only a small spinner shows
          // in the top-right corner while a refresh is running.
          if (onRefresh != null && refreshing)
            Positioned(
              right: 10,
              top: 10,
              child: Container(
                key: const ValueKey('desktop-home-refreshing'),
                width: 40,
                height: 40,
                padding: const EdgeInsets.all(12),
                decoration: const BoxDecoration(
                  color: _heroButtonFill,
                  shape: BoxShape.circle,
                ),
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: _accent,
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

/// Newly composed landscape resume shelf; no legacy ContinueCard is used.
class _ResumeShelf extends StatelessWidget {
  const _ResumeShelf({
    required this.items,
    required this.reading,
    required this.onAll,
  });
  final List<DesktopHomeResume> items;
  final bool reading;
  final VoidCallback onAll;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _SectionHeading(
        title: reading ? 'Continue reading' : 'Continue watching',
        onAll: onAll,
      ),
      if (items.isEmpty)
        const SizedBox(
          height: 150,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Your next story starts here.',
              style: TextStyle(color: _muted),
            ),
          ),
        ),
      if (items.isNotEmpty)
        LayoutBuilder(
          builder: (context, bounds) {
            final count = bounds.maxWidth >= 620
                ? 3
                : bounds.maxWidth >= 420
                ? 2
                : 1;
            final width = (bounds.maxWidth - (count - 1) * 12) / count;
            final textHeight = MediaQuery.textScalerOf(context).scale(52);
            return _HorizontalShelf(
              height: width * .36 + textHeight,
              width: width,
              count: items.length,
              gap: 12,
              builder: (index) {
                final entry = items[index];
                return DesktopMediaSurface(
                  key: ValueKey('desktop-home-resume-$index'),
                  onTap: entry.open,
                  onMenu: entry.menu,
                  // Windows: the one-line title in full on hover (home-13).
                  tooltip: entry.title,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            DesktopMediaArtwork(
                              url: entry.image,
                              headers: entry.headers,
                              width: width,
                            ),
                            if (entry.remaining != null)
                              Positioned(
                                top: 6,
                                right: 6,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xCC15191F),
                                    borderRadius: BorderRadius.circular(7),
                                  ),
                                  child: Text(
                                    entry.remaining!,
                                    style: const TextStyle(fontSize: 10),
                                  ),
                                ),
                              ),
                            Positioned(
                              left: 8,
                              right: 8,
                              bottom: 2,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(2),
                                child: LinearProgressIndicator(
                                  value: entry.progress.clamp(0, 1),
                                  minHeight: 3,
                                  color: _accent,
                                  backgroundColor: const Color(0xFF45464C),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(9, 7, 9, 7),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    entry.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  '${(entry.progress.clamp(0, 1) * 100).round()}%',
                                  style: const TextStyle(
                                    fontSize: 10,
                                    color: _muted,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              entry.subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11,
                                color: _muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
    ],
  );
}

/// Quiet compact release list. Unknown dates/episodes are never fabricated.
class _LibraryReleasePanel extends StatelessWidget {
  const _LibraryReleasePanel({required this.items, required this.onAll});
  final List<DesktopHomeRelease> items;
  final VoidCallback onAll;
  @override
  Widget build(BuildContext context) {
    // Windows shows up to five rows plus a "+N more" count (home-7); the
    // other platforms keep the original three.
    final limit = _windows ? desktopHomeReleaseRows : 3;
    final more = items.length - limit;
    return Padding(
      padding: const EdgeInsets.only(left: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHeading(title: context.l10n.newFromYourList, onAll: onAll),
          if (items.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 18),
              child: Text(
                'No new releases available from your connected library.',
                style: TextStyle(fontSize: 11, color: _muted, height: 1.5),
              ),
            ),
          for (final item in items.take(limit))
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _releaseRow(item),
            ),
          // Windows: how many more releases See all would show.
          if (_windows && more > 0)
            InkWell(
              key: const ValueKey('desktop-home-releases-more'),
              onTap: onAll,
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                child: Text(
                  context.l10n.plusNMore(more),
                  style: const TextStyle(fontSize: 11, color: _muted),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// One release row. On Windows it also gets the row's menu on right-click
  /// and the Menu key / Shift+F10, plus the full title as a tooltip.
  Widget _releaseRow(DesktopHomeRelease item) {
    Widget row = InkWell(
      onTap: item.open,
      onSecondaryTap: _windows ? item.menu : null,
      borderRadius: BorderRadius.circular(8),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(7),
            child: SizedBox(
              width: 40,
              height: 48,
              child: DesktopMediaArtwork(
                url: item.image,
                headers: item.headers,
                width: 40,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  item.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10, color: _accent),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    // Phone keeps the plain row.
    if (!_windows) return row;
    // Windows: Enter opens and the Menu key / Shift+F10 opens the row menu
    // while the row has keyboard focus (home-7 / home-9).
    row = DesktopCardKeys(onOpen: item.open, onMenu: item.menu, child: row);
    // Windows: the one-line title in full after a short hover (home-13).
    if (item.title.trim().isEmpty) return row;
    return Tooltip(
      message: item.title,
      waitDuration: desktopCardTooltipWait,
      excludeFromSemantics: true,
      child: row,
    );
  }
}

/// Ranked poster shelf. Cards follow every Poster cards setting (shape, card
/// size, title placement, title artwork and badges) through the same
/// [desktopPosterCardForItem] mapping as the other desktop grids. All entries
/// remain reachable horizontally.
class _RankedPosterShelf extends StatelessWidget {
  const _RankedPosterShelf({
    required this.section,
    required this.onAll,
    required this.onOpen,
    required this.onMenu,
    required this.ranked,
    this.tagsFor,
    this.progressFor,
  });
  final HomeSection section;
  final VoidCallback onAll;
  final ValueChanged<MediaItem> onOpen, onMenu;
  final bool ranked;
  final List<String> Function(MediaItem)? tagsFor;
  final String? Function(MediaItem)? progressFor;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      _SectionHeading(title: section.title, onAll: onAll),
      LayoutBuilder(
        builder: (context, bounds) {
          final geometry = desktopShelfGeometry(context, bounds.maxWidth);
          return _HorizontalShelf(
            height: geometry.height,
            width: geometry.width,
            count: section.items.length,
            gap: 12,
            builder: (index) {
              final item = section.items[index];
              return desktopPosterCardForItem(
                context,
                item,
                cellWidth: geometry.width,
                artworkKey: ValueKey(
                  'desktop-home-poster-${section.title}-$index',
                ),
                rank: ranked ? index + 1 : null,
                tags: tagsFor?.call(item) ?? const [],
                progressBadge: progressFor?.call(item),
                onTap: () => onOpen(item),
                onMenu: () => onMenu(item),
              );
            },
          );
        },
      ),
    ],
  );
}

/// Streaming services rail for the desktop Home, shown where Settings > Home
/// rows places "Streaming services". Loads once; collapses when the region
/// lists no services, like the phone rail.
class DesktopHomeServicesShelf extends StatefulWidget {
  const DesktopHomeServicesShelf({
    super.key,
    required this.title,
    required this.load,
    required this.onOpen,
    required this.onAll,
  });
  final String title;
  final Future<List<StreamingService>> Function() load;
  final ValueChanged<StreamingService> onOpen;
  final VoidCallback onAll;
  @override
  State<DesktopHomeServicesShelf> createState() =>
      _DesktopHomeServicesShelfState();
}

/// Holds the one service request so Home rebuilds never refetch it.
class _DesktopHomeServicesShelfState extends State<DesktopHomeServicesShelf> {
  late final Future<List<StreamingService>> _services = widget.load();
  @override
  Widget build(BuildContext context) => FutureBuilder<List<StreamingService>>(
    future: _services,
    builder: (context, snap) {
      final services = snap.data ?? const <StreamingService>[];
      if (snap.connectionState == ConnectionState.done && services.isEmpty) {
        return const SizedBox.shrink();
      }
      return Column(
        children: [
          _SectionHeading(title: widget.title, onAll: widget.onAll),
          _HorizontalShelf(
            height: 88,
            width: 160,
            count: services.length,
            gap: 12,
            builder: (index) => StreamingServiceCard(
              service: services[index],
              width: 160,
              height: 88,
              onTap: () => widget.onOpen(services[index]),
            ),
          ),
        ],
      );
    },
  );
}

/// Poster shelf of saved shows. Uses the same card, spacing and column maths as
/// the catalogue shelves so it reads as part of Home, and eases in (fade plus a
/// short rise) when it first appears, for example right after going offline.
class _DownloadsShelf extends StatelessWidget {
  const _DownloadsShelf({
    required this.title,
    required this.items,
    required this.onAll,
  });
  final String title;
  final List<DesktopHomeDownload> items;
  final VoidCallback? onAll;

  /// "See all" target. Windows always goes somewhere (home-12 B): the
  /// page's own handler, else the Downloads page pushed directly. Other
  /// platforms keep the original behaviour.
  VoidCallback _seeAll(BuildContext context) {
    if (onAll != null) return onAll!;
    if (!_windows) return () {};
    return () => Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const DownloadsScreen()));
  }

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    key: const ValueKey('desktop-home-downloads'),
    tween: Tween(begin: 0, end: 1),
    duration: const Duration(milliseconds: 380),
    curve: Curves.easeOutCubic,
    builder: (context, t, child) => Opacity(
      opacity: t,
      child: Transform.translate(offset: Offset(0, (1 - t) * 10), child: child),
    ),
    child: Column(
      children: [
        _SectionHeading(title: title, onAll: _seeAll(context)),
        LayoutBuilder(
          builder: (context, bounds) {
            // Same Poster cards geometry and mapping as the catalogue shelves.
            final geometry = desktopShelfGeometry(context, bounds.maxWidth);
            return _HorizontalShelf(
              height: geometry.height,
              width: geometry.width,
              count: items.length,
              gap: 12,
              builder: (index) {
                final item = items[index];
                return desktopPosterCard(
                  context,
                  artworkKey: ValueKey('desktop-home-download-$index'),
                  title: item.title,
                  wide: geometry.wide,
                  titleInside: posterTitleInside(context, wide: geometry.wide),
                  artUrl: item.image,
                  sourceImageUrl: item.image,
                  headers: item.headers,
                  cellWidth: geometry.width,
                  tags: [item.subtitle],
                  onTap: item.open,
                );
              },
            );
          },
        ),
      ],
    ),
  );
}

/// Owns horizontal input; vertical wheel events continue to the Home scroller.
class _HorizontalShelf extends StatefulWidget {
  const _HorizontalShelf({
    required this.height,
    required this.width,
    required this.count,
    required this.gap,
    required this.builder,
  });
  final double height, width, gap;
  final int count;
  final Widget Function(int) builder;
  @override
  State<_HorizontalShelf> createState() => _HorizontalShelfState();
}

/// Disposes the shelf controller independently from the vertical Home scroller.
class _HorizontalShelfState extends State<_HorizontalShelf> {
  final _scroll = ScrollController();
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final row = Scrollbar(
      controller: _scroll,
      child: ListView.separated(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        itemCount: widget.count,
        separatorBuilder: (_, _) => SizedBox(width: widget.gap),
        itemBuilder: (_, index) =>
            SizedBox(width: widget.width, child: widget.builder(index)),
      ),
    );
    return SizedBox(
      height: widget.height,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(
          dragDevices: const {
            PointerDeviceKind.mouse,
            PointerDeviceKind.touch,
            PointerDeviceKind.trackpad,
          },
        ),
        // Windows (home-2): hover arrows at both ends page the shelf, each
        // hidden at its end of the row. Pass-through elsewhere.
        child: _windows
            ? DesktopRowScroller(controller: _scroll, child: row)
            : row,
      ),
    );
  }
}

/// Bundled official Lucide SVG; the surrounding button owns its semantics.
class DesktopHomeIcon extends StatelessWidget {
  const DesktopHomeIcon(
    this.name, {
    super.key,
    this.size = 18,
    this.color = Colors.white,
  });
  final String name;
  final double size;
  final Color color;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SvgPicture.asset(
      'assets/icons/lucide/$name.svg',
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    ),
  );
}

/// Section title and a single Lucide browse action.
class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.title, required this.onAll});
  final String title;

  /// Null hides the "See all" chevron instead of drawing a dead button
  /// (home-12).
  final VoidCallback? onAll;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: MediaQuery.textScalerOf(context).scale(34).clamp(34, 80),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
        if (onAll != null)
          _HomeIconButton(
            icon: 'chevron-right',
            label: context.l10n.seeAllNamed(title),
            onTap: onAll!,
          ),
      ],
    ),
  );
}

/// Translucent fill behind banner buttons so they read over bright artwork
/// (same shade as the secondary hero action).
const _heroButtonFill = Color(0x8013181E);

/// Compact accessible Lucide action target.
class _HomeIconButton extends StatelessWidget {
  const _HomeIconButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.mirror = false,
    this.backdrop = false,
  });
  final String icon, label;
  final VoidCallback onTap;

  /// Flips the glyph horizontally (a left chevron from chevron-right).
  final bool mirror;

  /// Draws a round translucent fill behind the icon (banner buttons).
  final bool backdrop;
  @override
  Widget build(BuildContext context) {
    Widget glyph = DesktopHomeIcon(
      icon,
      size: 17,
      color: backdrop ? Colors.white : _muted,
    );
    if (mirror) {
      glyph = Transform.flip(flipX: true, child: glyph);
    }
    return IconButton(
      tooltip: label,
      onPressed: onTap,
      style: backdrop
          ? IconButton.styleFrom(backgroundColor: _heroButtonFill)
          : null,
      icon: glyph,
    );
  }
}

/// Windows banner position dots (home-5): one per featured title, the
/// current one drawn as a wider accent pill; clicking a dot shows that title.
class _BannerDots extends StatelessWidget {
  const _BannerDots({
    required this.count,
    required this.index,
    required this.onSelect,
  });
  final int count, index;
  final ValueChanged<int> onSelect;
  @override
  Widget build(BuildContext context) {
    final animate = !MediaQuery.disableAnimationsOf(context);
    return Container(
      key: const ValueKey('desktop-home-feature-dots'),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: _heroButtonFill,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < count; i++)
            Semantics(
              button: true,
              selected: i == index,
              label: context.l10n.featuredTitleNofM(i + 1, count),
              excludeSemantics: true,
              child: InkWell(
                key: ValueKey('desktop-home-feature-dot-$i'),
                onTap: () => onSelect(i),
                customBorder: const StadiumBorder(),
                child: Padding(
                  // A roomy 20px hit area around a small dot.
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 7,
                  ),
                  child: AnimatedContainer(
                    duration: animate
                        ? const Duration(milliseconds: 200)
                        : Duration.zero,
                    width: i == index ? 16 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: i == index
                          ? _accent
                          : Colors.white.withValues(alpha: .45),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// New rectangular hero action with the reference corner radius.
class _HeroAction extends StatelessWidget {
  const _HeroAction({
    required this.label,
    required this.onTap,
    this.icon,
    this.primary = false,
  });
  final String label;
  final String? icon;
  final VoidCallback onTap;
  final bool primary;
  // The primary action is filled with the Theme & colour accent; its label
  // switches to dark ink on light accents so it stays readable.
  @override
  Widget build(BuildContext context) {
    final accent = _accent;
    final ink = primary ? DesktopChrome.onAccent(accent) : Colors.white;
    return Material(
      key: primary ? const ValueKey('desktop-home-primary-action') : null,
      color: primary ? accent : const Color(0x8013181E),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: primary ? accent : const Color(0xFF727881)),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 11),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                DesktopHomeIcon(icon!, size: 16, color: ink),
                const SizedBox(width: 10),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 2,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: ink,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Restores account recovery in the new desktop design without signing out or
/// touching cached library data. The owner controls visibility from auth state.
class _SessionNotice extends StatelessWidget {
  const _SessionNotice({required this.label, required this.onReconnect});
  final String label;
  final VoidCallback onReconnect;

  // Tinted from the accent over the canvas instead of a fixed red panel.
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Color.alphaBlend(
        _accent.withValues(alpha: .10),
        DesktopChrome.canvas,
      ),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: _accent.withValues(alpha: .35)),
    ),
    child: Wrap(
      spacing: 16,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        DesktopHomeIcon('user-round', size: 18, color: _accent),
        const Text(
          'Your session expired. Reconnect to sync your library.',
          style: TextStyle(color: _muted, fontSize: 13),
        ),
        _HeroAction(label: label, onTap: onReconnect),
      ],
    ),
  );
}

/// Explicit loading/empty/error state with a recoverable action.
class _HomeFeedback extends StatelessWidget {
  const _HomeFeedback({
    required this.loading,
    required this.message,
    required this.onRetry,
    this.onVerify,
    this.onCatalogue,
    this.offline = false,
    this.onDownloads,
  });
  final bool loading;
  final String message;
  final Future<void> Function() onRetry;
  final VoidCallback? onVerify;
  final VoidCallback? onCatalogue;
  final bool offline;
  final VoidCallback? onDownloads;
  @override
  Widget build(BuildContext context) => ConstrainedBox(
    // Recovery text and actions must grow with Windows text scaling. The
    // parent Home scroll view owns overflow instead of clipping this panel.
    constraints: BoxConstraints(minHeight: offline ? 180 : 240),
    child: Center(
      child: loading
          ? CircularProgressIndicator(color: _accent)
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (offline) ...[
                  const DesktopHomeIcon('wifi-off', size: 22, color: _muted),
                  const SizedBox(height: 12),
                ],
                Text(message, style: const TextStyle(color: _muted)),
                const SizedBox(height: 16),
                // Offline with saved shows: the useful action comes first.
                if (onDownloads != null) ...[
                  _HeroAction(
                    label: context.l10n.openDownloads,
                    icon: 'download',
                    primary: true,
                    onTap: onDownloads!,
                  ),
                  const SizedBox(height: 10),
                ],
                if (onVerify != null) ...[
                  _HeroAction(
                    label: context.l10n.verifyWebsite,
                    icon: 'info',
                    onTap: onVerify!,
                  ),
                  const SizedBox(height: 10),
                ],
                // A failed source must not hide the route to another catalogue.
                if (onCatalogue != null) ...[
                  _HeroAction(
                    label: context.l10n.chooseCatalogue,
                    icon: 'blocks',
                    onTap: onCatalogue!,
                  ),
                  const SizedBox(height: 10),
                ],
                _HeroAction(
                  label: offline ? 'Try again' : 'Refresh catalogue',
                  icon: 'rotate-cw',
                  onTap: onRetry,
                ),
              ],
            ),
    ),
  );
}

/// Desktop action menu for Home cards; existing controllers supply its
/// actions.
///
/// Windows (home-1 A): a compact context menu right where the user clicked,
/// with the same actions. A keyboard-opened card menu (Menu key / Shift+F10)
/// opens at the card's centre instead. Other platforms keep the centred
/// dialog. [title] only heads that dialog; context menus carry no title.
Future<void> showDesktopHomeMenu(
  BuildContext context, {
  required String title,
  required List<({String label, String icon, VoidCallback run})> actions,
}) {
  if (!_windows) {
    return _showHomeMenuDialog(context, title: title, actions: actions);
  }
  // Read synchronously: the keyboard origin is only set during this call.
  // Otherwise the most recent click (left or right) places the menu, so a
  // menu opened from a left-click link never jumps to an old right-click.
  final position = DesktopMediaMenuOrigin.pending ?? DesktopPointer.lastDown;
  return showDesktopContextMenu<void>(
    context,
    position: position,
    items: [
      for (final action in actions)
        DesktopMenuItem<void>(
          label: action.label,
          icon: desktopHomeMenuIcon(action.icon),
          onTap: action.run,
        ),
    ],
  );
}

/// Material icon for a Home menu's Lucide icon name, so context menu rows
/// keep the same visual hint as the old dialog. Unknown names get none.
IconData? desktopHomeMenuIcon(String name) => switch (name) {
  'info' => Icons.info_outline_rounded,
  'bookmark' => Icons.bookmark_border_rounded,
  'book-open' => Icons.menu_book_outlined,
  'history' => Icons.history_rounded,
  'play' => Icons.play_arrow_rounded,
  // Sources/extensions: widgets_outlined is the Material twin of the Lucide
  // 'blocks' icon that Settings and the rail use (not the puzzle piece).
  // 'puzzle' maps to it too so any older caller still matches.
  'blocks' || 'puzzle' => Icons.widgets_outlined,
  'download' => Icons.download_rounded,
  'rotate-cw' => Icons.refresh_rounded,
  'trash' || 'trash-2' => Icons.delete_outline_rounded,
  'check' => Icons.check_rounded,
  'arrow-right' || 'chevron-right' => Icons.arrow_forward_rounded,
  _ => null,
};

/// The original centred dialog menu, kept for non-Windows platforms.
Future<void> _showHomeMenuDialog(
  BuildContext context, {
  required String title,
  required List<({String label, String icon, VoidCallback run})> actions,
}) => showDialog<void>(
  context: context,
  builder: (dialogContext) => Dialog(
    backgroundColor: const Color(0xFF151A20),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: const BorderSide(color: Color(0xFF353C46)),
    ),
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: 420,
        maxHeight: MediaQuery.sizeOf(context).height * .8,
      ),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(10),
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              for (final action in actions)
                TextButton(
                  onPressed: () {
                    Navigator.of(dialogContext).pop();
                    action.run();
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.all(14),
                  ),
                  child: Row(
                    children: [
                      DesktopHomeIcon(action.icon, color: _muted),
                      const SizedBox(width: 14),
                      Expanded(child: Text(action.label)),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  ),
);

/// Secondary routes stay reachable without restoring the old oversized cards.
class DesktopHomeUtilities extends StatelessWidget {
  const DesktopHomeUtilities({super.key, required this.actions});
  final List<({String label, String icon, VoidCallback run})> actions;
  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 16,
    runSpacing: 8,
    children: [
      for (final action in actions)
        TextButton.icon(
          onPressed: action.run,
          icon: DesktopHomeIcon(action.icon, size: 15, color: _muted),
          label: Text(
            action.label,
            style: const TextStyle(fontSize: 11, color: _muted),
          ),
        ),
    ],
  );
}
