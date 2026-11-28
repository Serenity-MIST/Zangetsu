import '../../core/ui/desktop_media_card.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../../core/desktop/desktop_focus_repair.dart';
import '../../core/desktop/desktop_image_cache.dart';
import '../../core/desktop/desktop_chrome_colors.dart';
import '../../core/desktop/desktop_context_menu.dart';
import '../../core/desktop/desktop_memory.dart';
import '../../core/desktop/desktop_picture_warmer.dart';
import '../../core/desktop/desktop_row_scroller.dart';
import '../../core/desktop/desktop_smooth_scroll.dart';
import '../../core/desktop/desktop_shortcuts.dart';
import '../../core/di/injector.dart';
import '../downloads/downloads_screen.dart';
import '../player/desktop_floating_player.dart';
import '../../core/metadata/title_logo_service.dart';
import '../../core/metadata/streaming_service.dart';
import '../../core/models/home_section.dart';
import '../../core/models/media_item.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_font_prefs.dart';
import '../../core/theme/theme_controller.dart';
import '../../core/ui/featured_hero.dart' show HeroMeta;
import 'home_known_artwork.dart';
import '../../core/ui/poster_card.dart';
import '../../core/ui/poster_palette.dart';
import '../../core/ui/desktop_svg.dart';
import 'desktop_home_warmup.dart';
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

/// Windows: how far below (and above) the visible part of Home shelves are
/// built ahead, in pixels, so their artwork is decoded before it shows. This
/// is the start value; once Home is quiet the rest of the page is built too,
/// one shelf at a time (see [DesktopHomeWarmup]).
const double desktopHomeCacheExtent = 900;

/// Windows PCs with more than 8 GB: furthest the build-ahead may grow. Far
/// more than any Home needs, so every shelf ends up built and stays built.
const double desktopHomeWarmCapRoomy = 20000;

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
    this.still,
    this.backdrop,
    this.sourceId,
    this.showId,
    this.malId,
  });
  final String title, subtitle;
  final double progress;
  final String? image, remaining;
  final Map<String, String>? headers;
  final VoidCallback open;
  final VoidCallback? menu;

  /// Windows: the episode picture (a landscape still), when the history entry
  /// has one. It is the best fit for the wide Continue card.
  final String? still;

  /// Windows: the show's own wide picture (TMDB backdrop / AniList banner),
  /// stored with the history entry or found in data already held for that
  /// show. Used when there is no [still].
  final String? backdrop;

  /// Windows: which show this is, so the Continue card can find the show's
  /// wide backdrop among titles Home already knows (catalogue rows, the
  /// banner, My List) when there is no episode picture. Null skips the
  /// search and the card keeps [image].
  final String? sourceId, showId;
  final int? malId;
}

/// Windows: the picture for a wide (16:9) Continue card and the headers to
/// load it with. Order: the episode still, then the show's own wide picture
/// ([DesktopHomeResume.backdrop]), then the show's wide backdrop (banner)
/// from [known] titles, then [DesktopHomeResume.image] (usually the portrait
/// poster, which the card shows whole over a blurred fill).
///
/// A known title matches on the same source and show id first, then on the
/// MyAnimeList id, then on the same title (ignoring case and punctuation),
/// because catalogue rows often come from a different source than the one
/// the episode was played from. Only the picture is borrowed, never anything
/// that changes what the card opens.
({String? url, Map<String, String>? headers}) desktopResumeArtwork(
  DesktopHomeResume entry,
  Iterable<MediaItem> known,
) {
  final still = entry.still?.trim();
  if (still != null && still.isNotEmpty) {
    return (url: still, headers: entry.headers);
  }
  final own = entry.backdrop?.trim();
  // Backdrops come from public artwork CDNs; the entry's headers belong to
  // its own cover, so they are not sent.
  if (own != null && own.isNotEmpty) return (url: own, headers: null);
  if (entry.sourceId != null || entry.showId != null) {
    final backdrop = _knownBackdrop(entry, known);
    // Backdrops come from public artwork CDNs; the entry's headers belong to
    // its own cover, so they are not sent.
    if (backdrop != null) return (url: backdrop, headers: null);
  }
  return (url: entry.image, headers: entry.headers);
}

/// The wide picture of the first [known] title that is the same show as
/// [entry], or null.
String? _knownBackdrop(DesktopHomeResume entry, Iterable<MediaItem> known) {
  String? wideOf(MediaItem item) {
    for (final url in [item.landscapePoster, item.banner]) {
      if (url != null && url.trim().isNotEmpty) return url.trim();
    }
    return null;
  }

  final title = _titleKey(entry.title);
  String? byMal, byTitle;
  for (final item in known) {
    final wide = wideOf(item);
    if (wide == null) continue;
    if (item.sourceId == entry.sourceId && item.id == entry.showId) {
      return wide;
    }
    if (byMal == null && entry.malId != null && item.malId == entry.malId) {
      byMal = wide;
    }
    // A title match alone can be a different show with the same name (the
    // movie of a series, a remake), so it is only trusted from the same
    // source, or when neither side has a MyAnimeList id to tell them apart.
    final titleTrusted =
        item.sourceId == entry.sourceId ||
        (entry.malId == null && item.malId == null);
    if (byTitle == null &&
        titleTrusted &&
        title.isNotEmpty &&
        (_titleKey(item.title) == title ||
            (item.englishTitle != null &&
                _titleKey(item.englishTitle!) == title))) {
      byTitle = wide;
    }
  }
  return byMal ?? byTitle;
}

/// A title reduced to lower-case letters and digits, so "The Odyssey" and
/// "the odyssey!" match.
String _titleKey(String title) {
  final known = _titleKeys[title];
  if (known != null) return known;
  // A whole Home holds a few hundred titles; the limit only keeps a very long
  // session from growing this without end.
  if (_titleKeys.length >= 4000) _titleKeys.clear();
  return _titleKeys[title] = title.toLowerCase().replaceAll(
    _titleKeyDropped,
    '',
  );
}

/// Compiled once: Continue compares every card with every known title, and
/// building this pattern for each comparison was slow.
final _titleKeyDropped = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

/// Titles already reduced by [_titleKey].
final _titleKeys = <String, String>{};

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
    this.wideArt,
  });

  /// Windows: a wide picture for a banner title, looked up in data the app
  /// already holds (for example a source catalogue title that is also in the
  /// AniList rows). Null, or a null answer, uses the title's own banner.
  final String? Function(MediaItem item)? wideArt;

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
  /// Windows: wheel turns glide to their target instead of jumping a whole
  /// notch at once. Other platforms keep the plain controller.
  late final ScrollController _scroll = _windows
      ? DesktopSmoothScrollController()
      : ScrollController();

  /// Index of the featured title in the banner. Only the banner listens to
  /// it, so the auto-rotate no longer rebuilds every shelf on the page.
  final _featured = ValueNotifier<int>(0);
  int get _featuredIndex => _featured.value;

  /// Windows: when the Home page last scrolled. The banner waits while the
  /// user is scrolling, so a title change never lands in the middle of it.
  DateTime? _lastScrollAt;

  /// How long after the last scroll the banner waits before it may move.
  static const _scrollQuiet = Duration(seconds: 1);

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

  /// Windows: builds the shelves further down while Home is quiet, and keeps
  /// them built, so scrolling never has to build one. Null elsewhere.
  DesktopHomeWarmup? _warmup;

  /// Windows, more than 8 GB: loads the next banner and the pictures one
  /// screen further along each shelf once everything above is built.
  DesktopPictureWarmer? _pictures;

  /// The page (route) Home sits on. Kept by [_RouteProbe], so checking
  /// whether another page covers Home never makes Home rebuild itself.
  ModalRoute<Object?>? _route;

  /// Windows: the shelf sizes of the last layout, for loading the same
  /// pictures the cards will ask for.
  ({
    double page,
    double pixelRatio,
    ({double width, double height, bool wide}) shelf,
  })?
  _pictureSizes;

  /// Windows: the poster shelves as last built, by row name. A Home rebuild
  /// hands Flutter the same shelf again when nothing on it changed, so a
  /// refresh with the same titles (or the loading bar coming and going) does
  /// not rebuild the cards of every shelf that is kept built.
  Map<String, _KeptShelf> _keptShelves = {};

  /// The theme, font and poster card settings [_keptShelves] were built with.
  (int, int, int)? _keptRevisions;

  @override
  void initState() {
    super.initState();
    if (_windows) {
      _warmup = DesktopHomeWarmup(
        initialExtent: desktopHomeCacheExtent,
        mayRun: _mayWarm,
        position: () => _scroll.hasClients ? _scroll.position : null,
        cap: _warmCap,
        logosWaiting: () => sl.isRegistered<TitleLogoService>()
            ? sl<TitleLogoService>().posterLogosWaiting
            : 0,
        onFinished: _warmPictures,
      );
      DesktopFloatingPlayer.instance.addListener(_resumeWarmup);
      _continueWarmup();
    }
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
    // More (or different) rows may have arrived: build those ahead too.
    if (_windows) {
      _continueWarmup();
      if (!identical(oldWidget.sections, widget.sections) ||
          oldWidget.rows?.length != widget.rows?.length) {
        _picturesDue = true;
      }
    }
  }

  /// True when the rows changed since the pictures were last queued.
  bool _picturesDue = true;

  /// After the next frame: starts the warm-up once there are real shelves,
  /// or lets it carry on when the page has grown.
  void _continueWarmup() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final warmup = _warmup;
      if (!mounted || warmup == null) return;
      if (!warmup.started) {
        if (_hasShelves) warmup.start();
        return;
      }
      _resumeWarmup();
      // Same length of page but other titles: only the pictures are new.
      if (warmup.finished && _picturesDue) _warmPictures();
    });
  }

  /// Something that stopped the idle work may be gone (a page above Home, a
  /// hidden tab, the mini player): carry on if so.
  void _resumeWarmup() {
    _warmup?.check();
    _pictures?.resume();
  }

  /// All shelves change in this frame (other size, other look, other titles,
  /// or they left the page): build only the ones near the screen now, and the
  /// others again later, one by one.
  void _restartWarmup() {
    _warmup?.reset();
    // Pictures still waiting may be for cards that no longer exist.
    _pictures?.load(const []);
    _picturesDue = true;
    _continueWarmup();
  }

  /// True once a catalogue shelf with titles is on the page.
  bool get _hasShelves =>
      !widget.offline &&
      (widget.rows?.any((r) => r.section?.items.isNotEmpty == true) ??
          widget.sections.any((s) => s.items.isNotEmpty));

  /// Whether the warm-up may work now: only while Home is the page in front,
  /// has finished loading, and the window is not minimised. Never while a
  /// video plays: the player page covers Home, and the mini player, which
  /// floats above it, is asked by name.
  bool _mayWarm() {
    if (!mounted || widget.offline) return false;
    // The rows may still be replaced by the ones being loaded.
    if (widget.loading || _refreshing) return false;
    if (DesktopFloatingPlayer.instance.isActive) return false;
    final life = WidgetsBinding.instance.lifecycleState;
    if (life == AppLifecycleState.hidden ||
        life == AppLifecycleState.paused ||
        life == AppLifecycleState.detached) {
      return false;
    }
    // The shell turns tickers off for every tab but the visible one.
    return TickerMode.getValuesNotifier(context).value.enabled &&
        (_route?.isCurrent ?? true);
  }

  /// Furthest shelves are built ahead: everything on PCs with more than 8 GB,
  /// two screens on 8 GB (or unknown) ones.
  double _warmCap() {
    if (_roomy) return desktopHomeWarmCapRoomy;
    final view = _scroll.hasClients && _scroll.position.hasViewportDimension
        ? _scroll.position.viewportDimension
        : 0.0;
    return math.max(desktopHomeCacheExtent, view * 2);
  }

  static bool get _roomy =>
      DesktopMemory.systemMemoryMb > DesktopMemory.lowMemoryLimitMb;

  /// Windows, more than 8 GB: queues the next banner and the second screen of
  /// every poster shelf. They load one at a time and pause while scrolling.
  void _warmPictures() {
    final sizes = _pictureSizes;
    if (!_roomy || sizes == null || !mounted) return;
    _picturesDue = false;
    final pictures = _pictures ??= DesktopPictureWarmer(
      mayRun: _mayWarm,
      ready: () =>
          !_warmup!.scrolledRecently &&
          !(_scroll.hasClients && _scroll.position.isScrollingNotifier.value),
    );
    final cell = sizes.shelf.width;
    final perScreen = math.max(
      1,
      ((sizes.page - 32 + 12) / (cell + 12)).round(),
    );
    pictures.load(first: _nextBannerPictures(), [
      for (final row in _layout())
        if (row.section case final section?)
          for (final item in section.items.skip(perScreen).take(perScreen))
            ?_posterPicture(item, sizes),
    ]);
  }

  /// The picture a shelf card shows for [item], exactly as the card asks for
  /// it, so it is decoded once and shared.
  ImageProvider? _posterPicture(
    MediaItem item,
    ({
      double page,
      double pixelRatio,
      ({double width, double height, bool wide}) shelf,
    })
    sizes,
  ) {
    final art = desktopPosterArtForItem(item, wide: sizes.shelf.wide);
    final url = art.url;
    if (url == null || url.isEmpty) return null;
    final picture = desktopArtworkFor(
      url: url,
      headers: art.headers,
      width: sizes.shelf.width,
      devicePixelRatio: sizes.pixelRatio,
    );
    return picture.full ?? picture.preview;
  }

  /// The pictures of the banner that comes next (none with a single title).
  List<ImageProvider> _nextBannerPictures() {
    final sizes = _pictureSizes;
    final count = widget.featured.length;
    if (sizes == null || widget.offline || count < 2) return const [];
    final next = widget.featured[(_featuredIndex + 1) % count];
    final art = desktopHeroArtwork(
      next,
      wideArt: _heroWideArt(next),
      // The page's side padding (16 each) and the panel's 1 px outline.
      panelWidth: sizes.page - 32 - 2,
    );
    final url = art.url;
    if (url == null || url.isEmpty) return const [];
    final picture = desktopArtworkFor(
      url: url,
      headers: art.headers,
      width: art.width,
      devicePixelRatio: sizes.pixelRatio,
      backdrop: art.backdrop,
      maxDecodeWidth: art.maxDecodeWidth,
      fitWhole: art.fitWhole,
    );
    return [?picture.full, if (picture.full == null) picture.preview];
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A long time minimised empties the picture cache, so the pictures loaded
    // ahead are asked for again afterwards (those still held are skipped).
    if (state == AppLifecycleState.hidden) _picturesDue = true;
    // Back from minimised: the warm-up carries on where it stopped.
    if (state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive) {
      _continueWarmup();
    }
    // Windows reports inactive when the window loses focus and hidden when
    // it is minimised: the banner only moves while the user can see it.
    final active = state == AppLifecycleState.resumed;
    if (active == _windowActive) return;
    _windowActive = active;
    if (active) _scheduleRotate();
  }

  /// (Re)starts the banner countdown; no-op off Windows or with < 2 titles.
  /// [after] is normally the full interval; a short wait is used when the
  /// banner is only holding back for a scroll to finish.
  void _scheduleRotate({Duration after = desktopHomeBannerInterval}) {
    _rotate?.cancel();
    _rotate = null;
    if (!_windows || widget.offline || widget.featured.length < 2) return;
    _rotate = Timer(after, _autoAdvance);
  }

  /// Timer tick: advance unless hovered, focused, reduced motion is on, the
  /// window is in the background or another page covers Home.
  void _autoAdvance() {
    if (!mounted) return;
    final reducedMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    // Read from the probe: asking for the route here made the whole of Home
    // rebuild each time a page or dialog opened or closed above it.
    final covered = !(_route?.isCurrent ?? true);
    if (_bannerHovered ||
        _bannerFocused ||
        !_windowActive ||
        reducedMotion ||
        covered) {
      _scheduleRotate();
      return;
    }
    // Windows: wait while the page is being scrolled, then try again
    // shortly, so the banner change and its image decode never land in
    // the middle of a scroll.
    final last = _lastScrollAt;
    if (last != null && DateTime.now().difference(last) < _scrollQuiet) {
      _scheduleRotate(after: _scrollQuiet);
      return;
    }
    _showFeature(_featuredIndex + 1);
  }

  /// Shows featured title [index] (wrapping both ways) and restarts the clock.
  void _showFeature(int index) {
    final count = widget.featured.length;
    if (count == 0) return;
    // Only the banner listens; the rest of the page is not rebuilt.
    _featured.value = index % count;
    // Keep the colour wash in step even when the banner is off-screen and
    // its builder does not run. Skipped offline, where no hero is shown.
    if (!widget.offline) _syncTint(widget.featured[_featured.value]);
    // The banner after this one loads next (after its own picture).
    if (_warmup?.finished ?? false) {
      _pictures?.loadFirst(_nextBannerPictures());
    }
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
      if (mounted) {
        setState(() => _refreshing = false);
        _continueWarmup();
      }
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
    if (_warmup != null) {
      DesktopFloatingPlayer.instance.removeListener(_resumeWarmup);
    }
    _warmup?.dispose();
    _pictures?.dispose();
    // Safe even when never added (removeObserver just returns false).
    WidgetsBinding.instance.removeObserver(this);
    // R1: stop offering this node to the focus repair.
    DesktopFocusRepair.unregister(_pageFocus);
    _pageFocus.dispose();
    _scroll.dispose();
    _tint.dispose();
    _featured.dispose();
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
        // Windows: the colour wash animates in its own layer, so its fade does
        // not repaint the scrolling shelves on top of it (and the other way).
        Positioned.fill(
          child: _windowsLayer(
            IgnorePointer(
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
        ),
        _windowsLayer(LayoutBuilder(builder: _content)),
        if (_windows)
          _RouteProbe(
            onRoute: (route) {
              _route = route;
              // Covered or shown again: the idle work looks once more.
              _continueWarmup();
            },
          ),
      ],
    );
  }

  /// Windows: puts [child] in its own paint layer. Elsewhere it is returned
  /// as is, so phone and tests keep the same tree.
  Widget _windowsLayer(Widget child) =>
      _windows ? RepaintBoundary(child: child) : child;

  /// Windows: remembers when the page last scrolled, so the banner can hold
  /// still while the user scrolls. Never stops the notification.
  bool _noteScroll(ScrollNotification n) {
    if (_windows && n is ScrollUpdateNotification) {
      _lastScrollAt = DateTime.now();
      _warmup?.noteScroll();
    }
    return false;
  }

  /// Windows: the page became longer or shorter (a row arrived, a card
  /// setting changed): build the new part ahead too.
  bool _noteMetrics(ScrollMetricsNotification n) {
    if (n.depth == 0) _warmup?.check();
    return false;
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
    // The featured title itself is picked inside the banner's own builder
    // below, so moving to the next title rebuilds only the banner and not
    // every shelf on the page.
    final hasHero = !(widget.offline || widget.featured.isEmpty);
    // The colour wash follows the featured title even while the banner is
    // scrolled off-screen (and so not built); _syncTint skips repeats.
    _syncTint(
      hasHero
          ? widget.featured[_featured.value % widget.featured.length]
          : null,
    );
    var restart = false;
    final kept = <String, _KeptShelf>{};
    if (_windows) {
      final sizes = (
        page: width,
        pixelRatio: MediaQuery.devicePixelRatioOf(context),
        shelf: desktopShelfGeometry(context, width - 32),
      );
      // Resizing the window lays out every built shelf at each step.
      restart = _pictureSizes != null && _pictureSizes != sizes;
      _pictureSizes = sizes;
      final revisions = (
        ThemeController.revision.value,
        AppFontPrefs.revision.value,
        PlaybackPrefs.posterRevision.value,
      );
      if (_keptRevisions != revisions) {
        restart = restart || _keptRevisions != null;
        _keptRevisions = revisions;
        _keptShelves = {};
      }
    }
    final rows = <Widget>[];
    var shelfIndex = 0, newShelves = 0, customRows = 0;
    // How many rows with the same title came before, so those keep separate
    // sideways positions (and a row added above changes none of them).
    final sameTitle = <String, int>{};
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
      final String name;
      if (row.isResume) {
        name = 'resume';
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
        name = 'custom|${customRows++}';
        child = row.builder!(context);
      } else {
        final section = row.section!;
        if (section.items.isEmpty) continue;
        // Only the leading shelf can carry Trending ranks.
        final ranked =
            shelfIndex == 0 && section.title.toLowerCase().contains('trending');
        shelfIndex++;
        final nth = sameTitle.update(
          section.title,
          (n) => n + 1,
          ifAbsent: () => 0,
        );
        name = 'poster|$nth|${section.title}';
        if (_windows) {
          final before = _keptShelves[name];
          final shelf = before != null && before.takes(row, ranked: ranked)
              ? before
              : _KeptShelf(
                  this,
                  row,
                  ranked: ranked,
                  storageId: _shelfId('poster', '$nth|${section.title}'),
                );
          if (!identical(shelf, before)) newShelves++;
          kept[name] = shelf;
          child = shelf.widget;
        } else {
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
      }
      if (child == null) continue;
      if (rows.isNotEmpty) {
        rows.add(_row('gap|$name', const SizedBox(height: 16)));
      }
      rows.add(_row(name, child));
    }
    if (_windows) {
      // Several shelves with other titles at once (a refreshed catalogue), or
      // none left (offline): never build the whole page in one frame, neither
      // now nor when the shelves come back.
      if (kept.isEmpty || newShelves > _maxNewShelves) restart = true;
      _keptShelves = kept;
      if (restart) _restartWarmup();
    }
    // Made here, outside the build-ahead builder below, so growing the
    // build-ahead hands Flutter the very same rows and rebuilds none of them.
    final slivers = <Widget>[
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        sliver: SliverList.list(
          children: [
            if (widget.onReconnect != null) ...[
              _row(
                'notice',
                _SessionNotice(
                  label: widget.reconnectLabel,
                  onReconnect: widget.onReconnect!,
                ),
              ),
              _row('gap|notice', const SizedBox(height: 12)),
            ],
            if (hasHero)
              // Only the banner listens to the featured index, so the
              // banner's auto-rotate never rebuilds the shelves below.
              _row(
                'banner',
                ValueListenableBuilder<int>(
                  valueListenable: _featured,
                  builder: (context, index, _) {
                    final hero =
                        widget.featured[index % widget.featured.length];
                    _syncTint(hero);
                    return _heroBanner(hero, width: width, scaled: scaled);
                  },
                ),
              )
            else
              _row(
                'feedback',
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
              ),
            _row('gap|banner', const SizedBox(height: 12)),
            // Offline, or nothing to show from the catalogue: put the
            // saved shows first so Home is never a dead end.
            if (widget.downloads.isNotEmpty &&
                (widget.offline || (!hasHero && !widget.loading))) ...[
              _row(
                'downloads',
                _DownloadsShelf(
                  storageId: _shelfId('downloads', ''),
                  title: widget.offline
                      ? 'Available offline'
                      : 'Your downloads',
                  items: widget.downloads,
                  onAll: widget.onDownloads,
                ),
              ),
              _row('gap|downloads', const SizedBox(height: 16)),
            ],
            ...rows,
            if (widget.loading && hasHero)
              _row(
                'loading',
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: LinearProgressIndicator(minHeight: 2, color: _accent),
                ),
              ),
            if (widget.footer != null) ...[
              _row('gap|footer', const SizedBox(height: 20)),
              _row('footer', widget.footer!),
            ],
          ],
        ),
      ),
    ];
    Widget view(double? extent) => CustomScrollView(
      controller: _scroll,
      key: const PageStorageKey('desktop-reference-home'),
      // Windows: shelves are built (and their artwork starts loading) up to
      // this far before they scroll into view, so the pictures are decoded
      // before they appear instead of landing mid-scroll. It starts at 900
      // pixels and grows to the whole page while Home is quiet, after which
      // no shelf is thrown away or built again. Elsewhere Flutter's default
      // stays. (The newer scrollCacheExtent form does not build with the
      // test compiler here, so this uses the same older setting as My List.)
      // ignore: deprecated_member_use
      cacheExtent: extent,
      slivers: slivers,
    );
    final warmup = _warmup;
    final page = NotificationListener<ScrollNotification>(
      onNotification: _noteScroll,
      child: Scrollbar(
        controller: _scroll,
        child: warmup == null
            ? view(null)
            : ValueListenableBuilder<double>(
                valueListenable: warmup.extent,
                builder: (context, extent, _) => view(extent),
              ),
      ),
    );
    if (warmup == null) return page;
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: _noteMetrics,
      child: page,
    );
  }

  /// Windows: names a row of the page, so that a row arriving, leaving or
  /// moving keeps every other row (and all its cards) as it is. Elsewhere the
  /// row is returned as is.
  Widget _row(String name, Widget child) => _windows
      ? KeyedSubtree(key: ValueKey('desktop-home-row|$name'), child: child)
      : child;

  /// Windows: how many shelves may be new (or changed) in one rebuild before
  /// only the ones near the screen are built at once.
  static const _maxNewShelves = 2;

  /// Windows: the name a shelf's sideways position is remembered under. The
  /// page's own key carries the mode and catalogue, so those never share.
  String? _shelfId(String kind, String name) =>
      _windows ? '${widget.key}|$kind|$name' : null;

  /// The featured banner for [hero] with its controls. Built from the
  /// featured-index listener only, so changing title leaves the shelves alone.
  Widget _heroBanner(
    MediaItem hero, {
    required double width,
    required bool scaled,
  }) =>
      // home-10: the hero's "Continue E5" label reads history,
      // so it follows the Continue store like the resume shelf.
      _followContinue(
        (_) => _bannerControls(
          _CinematicHero(
            item: hero,
            // Windows: the widest picture for the banner, its own or the same
            // show's from catalogue data already held; null means only the
            // portrait cover exists. Elsewhere the banner field as before.
            wideArt: _heroWideArt(hero),
            meta: widget.meta(hero),
            height: scaled ? 520 : ((width - 32) * .226).clamp(280, 350),
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
                ? () =>
                      _showFeature(_featuredIndex - 1 + widget.featured.length)
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
      );

  /// The wide picture the banner uses for [hero] (see [_CinematicHero]).
  String? _heroWideArt(MediaItem hero) => _windows
      ? (widget.wideArt?.call(hero) ?? homeWideArtOf(hero))
      : hero.banner;

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

  /// Titles Home already has (banner first, then the catalogue rows). The
  /// Continue cards look up a show's wide backdrop here; nothing is fetched.
  Iterable<MediaItem> get _knownTitles => [
    ...widget.featured,
    for (final section in widget.sections) ...section.items,
  ];

  /// Continue shelf with "New from your list" beside it (stacked when narrow).
  Widget _resumeBlock(bool wide) => wide
      ? Row(
          key: const ValueKey('desktop-home-continue'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 77,
              // Nothing from the Continue row (a hovered card's glow, a
              // half-scrolled card) may paint into the gap or the panel.
              child: ClipRect(
                child: _ResumeShelf(
                  storageId: _shelfId('resume', '${widget.reading}'),
                  items: _resumeItems,
                  reading: widget.reading,
                  onAll: widget.onHistory,
                  known: _knownTitles,
                ),
              ),
            ),
            const SizedBox(width: 20),
            Expanded(
              key: const ValueKey('desktop-home-release-panel'),
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
              storageId: _shelfId('resume', '${widget.reading}'),
              items: _resumeItems,
              reading: widget.reading,
              onAll: widget.onHistory,
              known: _knownTitles,
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

/// Text that shows only whole lines and ends the last one with "…".
///
/// It measures one line in the real font and text scale, then fits as many
/// lines as the given height allows (up to [maxLines]). When not even one
/// line fits it draws nothing, instead of half a line.
class DesktopWholeLineText extends StatelessWidget {
  const DesktopWholeLineText(
    this.text, {
    super.key,
    required this.maxLines,
    required this.style,
  });

  final String text;
  final int maxLines;
  final TextStyle style;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final resolved = DefaultTextStyle.of(context).style.merge(style);
      final scaler = MediaQuery.textScalerOf(context);
      var lines = maxLines;
      if (constraints.maxHeight.isFinite) {
        // Height of one line as the engine will lay it out.
        final probe = TextPainter(
          text: TextSpan(text: 'Ag', style: resolved),
          textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
          textScaler: scaler,
          maxLines: 1,
        )..layout();
        final lineHeight = probe.height;
        probe.dispose();
        // A tiny allowance keeps rounding from dropping a line that fits.
        lines = lineHeight <= 0
            ? maxLines
            : math.min(
                maxLines,
                ((constraints.maxHeight + .5) / lineHeight).floor(),
              );
      }
      if (lines < 1) return const SizedBox.shrink();
      return Text(
        text,
        maxLines: lines,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    },
  );
}

/// What picture the banner panel loads for [item], and at which size. Shared
/// by the panel itself and the preload of the next banner, so both ask for
/// exactly the same picture.
({
  String? url,
  Map<String, String>? headers,
  double width,
  bool backdrop,
  int maxDecodeWidth,
  bool fitWhole,
})
desktopHeroArtwork(
  MediaItem item, {
  required String? wideArt,
  required double panelWidth,
}) {
  // Windows, no wide picture at all: the cover stands whole on the right
  // (see _CinematicHero).
  if (wideArt == null && _windows && item.cover != null) {
    return (
      url: item.cover,
      headers: item.coverHeaders,
      width: panelWidth < 700 ? panelWidth : panelWidth * .57,
      backdrop: false,
      maxDecodeWidth: 2048,
      fitWhole: true,
    );
  }
  return (
    url: wideArt ?? item.cover,
    // A borrowed picture comes from a public artwork CDN; the title's headers
    // belong to its own source.
    headers: wideArt == null || wideArt == item.banner
        ? item.coverHeaders
        : null,
    // Decoded at the panel's width x display scale (up to the cap below), so
    // a wide window gets a sharp picture.
    width: panelWidth,
    // The banner is a wide backdrop and can span a whole 4K window, so it
    // uses the backdrop sizes (TMDB w1280 / original, never a smaller one)
    // and a higher decode cap.
    backdrop: wideArt != null,
    // Lower on 8 GB PCs so one banner cannot crowd the image cache.
    maxDecodeWidth: desktopBannerDecodeWidth(),
    // The banner is a backdrop behind the text, so it keeps filling the panel
    // edge to edge instead of showing a blurred fill.
    fitWhole: false,
  );
}

/// New typography-led feature with real wide artwork and bounded description.
class _CinematicHero extends StatelessWidget {
  const _CinematicHero({
    required this.item,
    required this.wideArt,
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

  /// The wide picture to fill the panel with; null when the title only has
  /// a portrait cover.
  final String? wideArt;
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

  /// The panel's picture for a panel of [panelWidth].
  Widget _art(Key key, double panelWidth) {
    final art = desktopHeroArtwork(
      item,
      wideArt: wideArt,
      panelWidth: panelWidth,
    );
    return DesktopMediaArtwork(
      key: key,
      url: art.url,
      headers: art.headers,
      width: art.width,
      backdrop: art.backdrop,
      maxDecodeWidth: art.maxDecodeWidth,
      fitWhole: art.fitWhole,
    );
  }

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
          if (wideArt == null && _windows && item.cover != null)
            // Windows, no wide picture at all: stretching the small portrait
            // cover across the whole panel made it look blurry and zoomed
            // in. The cover is shown whole on the right instead, over a soft
            // fill of itself, and the text keeps the left side.
            Positioned(
              left: bounds.maxWidth < 700 ? 0 : bounds.maxWidth * .43,
              top: 0,
              right: 0,
              bottom: 0,
              child: _art(
                const ValueKey('desktop-home-feature-poster'),
                bounds.maxWidth,
              ),
            )
          else
            _art(const ValueKey('desktop-home-feature-art'), bounds.maxWidth),
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
                        // One builder per slide: a description that arrives
                        // late (the AniList look-up) must never show the
                        // previous slide's text under the new title meanwhile.
                        key: ValueKey(
                          'desktop-home-feature-meta:'
                          '${item.sourceId}:${item.id}',
                        ),
                        future: meta,
                        builder: (context, snap) {
                          final description = snap.data?.description
                              ?.replaceAll(RegExp(r'<[^>]*>'), '')
                              .trim();
                          // Whole lines only: the line count follows the
                          // height left in the panel, so a short window
                          // never shows half a line at the bottom.
                          return DesktopWholeLineText(
                            description?.isNotEmpty == true
                                ? description!
                                : (snap.data?.genres ?? item.genres)
                                      .take(3)
                                      .join(' · '),
                            key: const ValueKey(
                              'desktop-home-feature-description',
                            ),
                            maxLines: 3,
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
                        _HeroAction(
                          label: context.l10n.details,
                          onTap: onDetails,
                        ),
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
    this.known = const [],
    this.storageId,
  });

  /// See [_HorizontalShelf.storageId].
  final String? storageId;
  final List<DesktopHomeResume> items;
  final bool reading;
  final VoidCallback onAll;

  /// Windows: titles Home already shows (banner and catalogue rows). A
  /// Continue card without an episode picture borrows the show's wide
  /// backdrop from here instead of squeezing its portrait poster into the
  /// wide box (see [desktopResumeArtwork]).
  final Iterable<MediaItem> known;
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
              storageId: storageId,
              // 16:9 art box, the shape of episode stills and backdrops, so
              // they show whole; the old 2.8:1 strip cut off top and bottom.
              height: width * 9 / 16 + textHeight,
              width: width,
              count: items.length,
              gap: 12,
              // Windows: the row always comes to rest on whole cards, so its
              // right end never shows a half card running up to the "New
              // from your list" panel beside it.
              snapToCards: _windows,
              builder: (index) {
                final entry = items[index];
                // Windows: the wide picture first (episode still, then the
                // show's backdrop); the portrait poster only when neither
                // exists, and then it is shown whole over a soft fill.
                final art = _windows
                    ? desktopResumeArtwork(entry, known)
                    : (url: entry.image, headers: entry.headers);
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
                              url: art.url,
                              headers: art.headers,
                              width: width,
                              // Landscape card: TMDB art uses the wide-image
                              // sizes (TMDB serves them for posters too).
                              backdrop: true,
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
            // Poster shape (2:3) at the row's old height, so the small
            // cover shows whole instead of a cropped near-square.
            child: SizedBox(
              width: 32,
              height: 48,
              child: DesktopMediaArtwork(
                url: item.image,
                headers: item.headers,
                width: 32,
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
    this.storageId,
  });

  /// See [_HorizontalShelf.storageId].
  final String? storageId;
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
            storageId: storageId,
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

/// Windows: one poster shelf of Home as it was last built, used again for as
/// long as nothing it draws has changed. What a click does always goes through
/// the newest row, so a shelf that was not rebuilt never acts on old data.
class _KeptShelf {
  _KeptShelf(
    this._page,
    this._row, {
    required this.ranked,
    required String? storageId,
  }) : _drawn = HomeSection(
         title: _row.section!.title,
         // A copy: a source may add to its own list later.
         items: [..._row.section!.items],
         more: _row.section!.more,
       ) {
    final tags = _row.tagsFor, progress = _row.progressFor;
    _tags = tags == null ? null : [..._drawn.items.map(tags)];
    _progress = progress == null ? null : [..._drawn.items.map(progress)];
    widget = _RankedPosterShelf(
      storageId: storageId,
      section: _drawn,
      onAll: () {
        final section = _row.section!;
        (_row.onAll ?? () => _page.widget.onSection(section))();
      },
      onOpen: (item) => (_row.onOpen ?? _page.widget.onOpen)(_newest(item)),
      onMenu: (item) => (_row.onMenu ?? _page.widget.onMenu)(_newest(item)),
      tagsFor: _tags == null ? null : (item) => _tags[_indexOf(item)],
      progressFor: _progress == null
          ? null
          : (item) => _progress[_indexOf(item)],
      ranked: ranked,
    );
  }

  final _DesktopHomePageState _page;

  /// The newest row for this shelf, and the titles [widget] draws.
  DesktopHomeRow _row;
  final HomeSection _drawn;
  final bool ranked;
  late final List<List<String>>? _tags;
  late final List<String?>? _progress;
  late final _RankedPosterShelf widget;

  /// Where each drawn title sits in the row.
  late final Map<MediaItem, int> _places = () {
    final places = Map<MediaItem, int>.identity();
    for (final (i, item) in _drawn.items.indexed) {
      places.putIfAbsent(item, () => i);
    }
    return places;
  }();

  int _indexOf(MediaItem item) => _places[item]!;

  MediaItem _newest(MediaItem item) {
    final items = _row.section!.items, i = _indexOf(item);
    return i < items.length ? items[i] : item;
  }

  /// True when [row] looks exactly like this shelf; the shelf then stands for
  /// [row] from now on and needs no rebuild.
  bool takes(DesktopHomeRow row, {required bool ranked}) {
    final section = row.section!, items = section.items;
    if (ranked != this.ranked ||
        section.title != _drawn.title ||
        items.length != _drawn.items.length ||
        (row.tagsFor == null) != (_tags == null) ||
        (row.progressFor == null) != (_progress == null)) {
      return false;
    }
    for (final (i, item) in items.indexed) {
      final drawn = _drawn.items[i];
      // The dub badge is on the card but not part of a title's equality.
      if (!identical(item, drawn) &&
          (item != drawn || item.dubBadge != drawn.dubBadge)) {
        return false;
      }
      if (_tags != null && !listEquals(row.tagsFor!(item), _tags[i])) {
        return false;
      }
      if (_progress != null && row.progressFor!(item) != _progress[i]) {
        return false;
      }
    }
    _row = row;
    return true;
  }
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
            // One services rail per Home, so a fixed name is enough.
            storageId: 'services',
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
    this.storageId,
  });

  /// See [_HorizontalShelf.storageId].
  final String? storageId;
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
              storageId: storageId,
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
    this.snapToCards = false,
    this.storageId,
  });

  /// Windows: the name this shelf's sideways position is remembered under.
  /// Without one every shelf shared the page's single slot, so a shelf built
  /// while scrolling jumped to the sideways (or even vertical) position of
  /// something else. Null (phone) keeps the plain list.
  final String? storageId;
  final double height, width, gap;
  final int count;
  final Widget Function(int) builder;

  /// Windows Continue row: when scrolling stops, the row settles on the
  /// nearest card edge and the arrows move by whole cards, so it always
  /// ends on a whole card instead of a cut-off one.
  final bool snapToCards;
  @override
  State<_HorizontalShelf> createState() => _HorizontalShelfState();
}

/// Disposes the shelf controller independently from the vertical Home scroller.
class _HorizontalShelfState extends State<_HorizontalShelf> {
  /// Windows: Shift+wheel glides the shelf sideways like the page scrolls.
  final _scroll = _windows
      ? DesktopSmoothScrollController()
      : ScrollController();

  /// Waits a moment after the last scroll before settling on a card edge, so
  /// a wheel glide or drag is never fought while it is still moving.
  Timer? _settle;

  double get _stride => widget.width + widget.gap;

  /// [_HorizontalShelf.snapToCards]: when the card width changes (the window
  /// was resized or maximised) the old scroll offset would land mid-card and
  /// leave a half card at the row's right end, next to the "New from your
  /// list" panel. Keep the same first card at the left edge instead.
  @override
  void didUpdateWidget(covariant _HorizontalShelf oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.snapToCards || !_scroll.hasClients) return;
    final oldStride = oldWidget.width + oldWidget.gap;
    if ((oldStride - _stride).abs() < .5 || oldStride <= 0) return;
    // Read the first card now, before the new layout clamps the offset.
    final first = (_scroll.position.pixels / oldStride).round();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final p = _scroll.position;
      final target = (first * _stride).clamp(
        p.minScrollExtent,
        p.maxScrollExtent,
      );
      if ((target - p.pixels).abs() >= .5) p.jumpTo(target);
    });
  }

  @override
  void dispose() {
    _settle?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  /// [_HorizontalShelf.snapToCards]: restarts the settle wait on every
  /// scroll and, once the row has been still for a moment, glides it to the
  /// nearest card edge (unless it is already there).
  bool _onScroll(ScrollNotification note) {
    if (!widget.snapToCards || note.depth != 0) return false;
    // Only real movement restarts the wait. A drag or glide ends with a
    // ScrollEnd followed by an "idle" UserScrollNotification; cancelling on
    // that one too threw the settle away, so the row stayed on a half card.
    if (note is ScrollStartNotification || note is ScrollUpdateNotification) {
      _settle?.cancel();
    }
    if (note is! ScrollEndNotification) return false;
    _settle?.cancel();
    _settle = Timer(const Duration(milliseconds: 220), () {
      if (!mounted || !_scroll.hasClients) return;
      final p = _scroll.position;
      final target = ((p.pixels / _stride).round() * _stride).clamp(
        p.minScrollExtent,
        p.maxScrollExtent,
      );
      if ((target - p.pixels).abs() < .5) return;
      _scroll.animateTo(
        target,
        duration: MediaQuery.disableAnimationsOf(context)
            ? const Duration(milliseconds: 1)
            : const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    });
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final storageId = widget.storageId;
    final list = ListView.separated(
      key: _windows && storageId != null
          ? PageStorageKey<String>('desktop-home-shelf:$storageId')
          : null,
      controller: _scroll,
      scrollDirection: Axis.horizontal,
      itemCount: widget.count,
      separatorBuilder: (_, _) => SizedBox(width: widget.gap),
      itemBuilder: (_, index) =>
          SizedBox(width: widget.width, child: widget.builder(index)),
    );
    final row = Scrollbar(
      controller: _scroll,
      child: widget.snapToCards
          ? NotificationListener<ScrollNotification>(
              onNotification: _onScroll,
              child: list,
            )
          : list,
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
            ? DesktopRowScroller(
                controller: _scroll,
                stride: widget.snapToCards ? _stride : null,
                child: row,
              )
            : row,
      ),
    );
  }
}

/// Windows: reports the page (route) it sits on without drawing anything, and
/// again whenever that page is covered or shown (by another page, a dialog or
/// another tab). Being a separate widget, only it rebuilds then, instead of
/// every shelf.
class _RouteProbe extends StatelessWidget {
  const _RouteProbe({required this.onRoute});
  final ValueChanged<ModalRoute<Object?>?> onRoute;
  @override
  Widget build(BuildContext context) {
    // Read so that switching tabs reports too (see the warm-up's tab check).
    TickerMode.valuesOf(context);
    onRoute(ModalRoute.of(context));
    return const SizedBox.shrink();
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
      renderingStrategy: desktopSvgStrategy,
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
