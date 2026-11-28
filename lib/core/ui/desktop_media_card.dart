import 'dart:collection';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../desktop/desktop_shortcuts.dart';
import '../theme/app_colors.dart';
import 'artwork_quality.dart';
import 'native_cover_provider.dart';
import '../cache/app_image_cache.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'progressive_artwork.dart';
import 'desktop_svg.dart';

/// One Windows media-card language across Home, library, search and catalogues.
/// Data/actions stay owned by callers; only presentation and pointer states live here.
class DesktopMediaCard extends StatelessWidget {
  const DesktopMediaCard({
    super.key,
    required this.title,
    this.image,
    this.headers,
    this.onTap,
    this.onMenu,
    this.score,
    this.rank,
    this.badges = const [],
    this.showTitle = true,
    this.titleInside = false,
    this.titleWidget,
    this.artworkKey,
    this.fallbackImage,
    this.fallbackHeaders,
    this.latchKey,
  });
  final String title;
  final String? image;
  final Map<String, String>? headers;

  /// Windows: the picture shown when [image] fails to load (the usual cover
  /// when [image] is a TMDB poster), with its own headers.
  final String? fallbackImage;
  final Map<String, String>? fallbackHeaders;

  /// See [DesktopMediaArtwork.latchKey].
  final Object? latchKey;
  final VoidCallback? onTap, onMenu;
  final int? score, rank;
  final List<String> badges;
  final bool showTitle, titleInside;
  final Widget? titleWidget;
  final Key? artworkKey;
  static double height(
    double width,
    double textScale, {
    bool wide = false,
    bool titleInside = false,
  }) =>
      // Portrait cards are true poster shape (2:3, height = 1.5 x width) so
      // a poster fits whole; the old .94 made near-square boxes that cut
      // heads off. Landscape cards stay 16:9.
      width * (wide ? 9 / 16 : 1.5) + (titleInside ? 0 : textScale * 56);
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final textHeight = MediaQuery.textScalerOf(context).scale(56);
      // With the title inside the art there is no caption row for the score,
      // so it joins the artwork badges instead of disappearing.
      final insideBadges = [
        ...badges,
        if (titleInside && showTitle && score != null)
          '★ ${(score! / 10).toStringAsFixed(1)}',
      ];
      // Captions retain the same click/right-click actions as the artwork.
      final card = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onSecondaryTap: onMenu,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: DesktopMediaSurface(
                key: artworkKey,
                onTap: onTap,
                onMenu: onMenu,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    DesktopMediaArtwork(
                      url: image,
                      headers: headers,
                      width: bounds.maxWidth,
                      fallbackUrl: fallbackImage,
                      fallbackHeaders: fallbackHeaders,
                      latchKey: latchKey,
                    ),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [Color(0x66000000), Colors.transparent],
                          stops: [0, .5],
                        ),
                      ),
                    ),
                    if (titleInside && showTitle)
                      Positioned(
                        left: 8,
                        right: 8,
                        bottom: 8,
                        // Inside placement keeps the rank beside the title,
                        // so a ranked shelf still reads as ranked.
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            if (rank != null) ...[
                              _RankNumeral(rank!),
                              const SizedBox(width: 7),
                            ],
                            Expanded(
                              child:
                                  titleWidget ??
                                  Text(
                                    title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white,
                                    ),
                                  ),
                            ),
                          ],
                        ),
                      ),
                    if (insideBadges.isNotEmpty)
                      Positioned(
                        left: 6,
                        top: titleInside ? 6 : null,
                        bottom: titleInside ? null : 6,
                        right: 6,
                        child: Wrap(
                          spacing: 4,
                          runSpacing: 3,
                          children: [
                            for (final badge in insideBadges)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xC0101318),
                                  borderRadius: BorderRadius.circular(5),
                                ),
                                child: Text(
                                  badge,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 9,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (showTitle && !titleInside)
              SizedBox(
                height: textHeight,
                child: Padding(
                  padding: const EdgeInsets.only(top: 7),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (rank != null) ...[
                        _RankNumeral(rank!),
                        const SizedBox(width: 9),
                      ],
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Flexible: a title-artwork logo (fixed height)
                            // shrinks to leave room for the score row instead
                            // of overflowing the caption.
                            Flexible(
                              child:
                                  titleWidget ??
                                  Text(
                                    title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 11,
                                      height: 1.2,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white,
                                    ),
                                  ),
                            ),
                            if (score != null) ...[
                              const SizedBox(height: 4),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SvgPicture.asset(
                                    'assets/icons/lucide/star.svg',
                                    width: 10,
                                    height: 10,
                                    renderingStrategy: desktopSvgStrategy,
                                    colorFilter: const ColorFilter.mode(
                                      Color(0xFFEAC458),
                                      BlendMode.srcIn,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    (score! / 10).toStringAsFixed(1),
                                    style: const TextStyle(
                                      fontSize: 10,
                                      color: Color(0xFFADB2BE),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );
      // Phone (and TV) keep the bare card exactly as before.
      if (!desktopCardExtrasEnabled || title.trim().isEmpty) return card;
      // Windows: the full title in a tooltip after a short hover, because the
      // caption stops after two lines (home-13). The tooltip stays out of the
      // semantics tree so screen readers do not hear the title twice.
      Widget result = Tooltip(
        message: title,
        waitDuration: desktopCardTooltipWait,
        excludeFromSemantics: true,
        child: card,
      );
      // Title-artwork logos and hidden captions leave no text behind, so the
      // card gets the title as its accessible name instead of only badges.
      if (titleWidget != null || !showTitle) {
        result = Semantics(
          label: title,
          button: onTap != null,
          container: true,
          child: result,
        );
      }
      return result;
    },
  );
}

/// True on the Windows desktop build, where cards add tooltips, accessible
/// names and keyboard actions. Uses the target platform (not dart:io) so
/// widget tests can opt in with debugDefaultTargetPlatformOverride.
bool get desktopCardExtrasEnabled =>
    defaultTargetPlatform == TargetPlatform.windows;

/// How long the pointer rests on a card before its full-title tooltip shows.
const desktopCardTooltipWait = Duration(milliseconds: 500);

/// Where a keyboard-opened card menu should appear.
///
/// Menu callbacks (onMenu) carry no position, so a menu opened from the
/// Menu key or Shift+F10 would otherwise appear at the last mouse click.
/// [DesktopCardKeys] sets [pending] to the card's centre for the duration of
/// the onMenu call; menu helpers read it synchronously before opening.
abstract final class DesktopMediaMenuOrigin {
  static Offset? _pending;

  /// Global centre of the card whose menu is being opened from the keyboard,
  /// or null when the menu came from the mouse.
  static Offset? get pending => _pending;

  /// Runs [open] with [at] published as [pending], then clears it again.
  static void run(Offset? at, VoidCallback open) {
    _pending = at;
    try {
      open();
    } finally {
      _pending = null;
    }
  }
}

/// Windows keyboard actions for a focused card (home-9): Enter opens it and
/// the Menu key / Shift+F10 opens its menu at the card's centre.
///
/// It is a pass-through focus node: it never takes focus itself, it only
/// sees keys bubbling up from a focused descendant (the card's InkWell).
/// Off Windows the child is returned untouched.
class DesktopCardKeys extends StatelessWidget {
  const DesktopCardKeys({
    super.key,
    required this.child,
    this.onOpen,
    this.onMenu,
  });
  final Widget child;
  final VoidCallback? onOpen, onMenu;

  /// True for the shared "open the focused item's menu" keys. Falls back to
  /// the stock keys when the shortcut catalogue was never registered (tests).
  static bool isMenuKey(KeyEvent event) {
    if (DesktopShortcuts.spec('app.contextMenu') != null) {
      return DesktopShortcuts.matches('app.contextMenu', event);
    }
    return event.logicalKey == LogicalKeyboardKey.contextMenu ||
        (event.logicalKey == LogicalKeyboardKey.f10 &&
            HardwareKeyboard.instance.isShiftPressed);
  }

  /// True for the "open the focused title" keys; the numpad Enter always
  /// counts too, like the main Enter key.
  static bool isOpenKey(KeyEvent event) {
    if (event.logicalKey == LogicalKeyboardKey.numpadEnter) return true;
    if (DesktopShortcuts.spec('home.open') != null) {
      return DesktopShortcuts.matches('home.open', event);
    }
    return event.logicalKey == LogicalKeyboardKey.enter;
  }

  /// Global centre of [context]'s box, where a keyboard menu opens.
  static Offset? centreOf(BuildContext? context) {
    final box = context?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(box.size.center(Offset.zero));
  }

  @override
  Widget build(BuildContext context) {
    if (!desktopCardExtrasEnabled || (onOpen == null && onMenu == null)) {
      return child;
    }
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (onMenu != null && isMenuKey(event)) {
          DesktopMediaMenuOrigin.run(centreOf(node.context), onMenu!);
          return KeyEventResult.handled;
        }
        // Modifier+Enter is left to other handlers.
        final keyboard = HardwareKeyboard.instance;
        if (onOpen != null &&
            !keyboard.isControlPressed &&
            !keyboard.isAltPressed &&
            !keyboard.isShiftPressed &&
            isOpenKey(event)) {
          onOpen!();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: child,
    );
  }
}

/// Large rank number on ranked shelves. No fixed family: it inherits the app
/// font chosen in Theme & colour > Font, like every other label.
class _RankNumeral extends StatelessWidget {
  const _RankNumeral(this.rank);
  final int rank;
  @override
  Widget build(BuildContext context) => Text(
    '$rank',
    key: ValueKey('desktop-media-rank-$rank'),
    style: const TextStyle(
      fontSize: 23,
      height: 1,
      fontWeight: FontWeight.w700,
      color: Colors.white,
      shadows: [Shadow(color: Color(0x99000000), blurRadius: 6)],
    ),
  );
}

/// Fresh source-aware artwork primitive, preserving protected-source headers.
class DesktopMediaArtwork extends StatefulWidget {
  const DesktopMediaArtwork({
    super.key,
    required this.url,
    required this.width,
    this.headers,
    this.backdrop = false,
    this.maxDecodeWidth = 2048,
    this.fitWhole = true,
    this.wholeRadius = 10,
    this.fallbackUrl,
    this.fallbackHeaders,
    this.latchKey,
  });
  final String? url;
  final double width;
  final Map<String, String>? headers;

  /// The picture shown when [url] fails to load, instead of a smaller copy
  /// of [url] itself. Windows poster cards pass the usual cover here when
  /// [url] is a TMDB poster, so a broken TMDB file never leaves a blank box.
  final String? fallbackUrl;
  final Map<String, String>? fallbackHeaders;

  /// While this stays the same, the card keeps the picture it was first
  /// built with, even when a rebuild brings a new [url] (a TMDB poster
  /// lookup that finished while the card was on screen), so the picture
  /// never swaps in front of the viewer. A new key (another item, or a new
  /// card shape) takes the new picture. Null follows [url] as before.
  final Object? latchKey;

  /// Windows: show the whole picture instead of cropping it when its shape
  /// differs from the card (see [ProgressiveArtwork.fitWhole]). On by
  /// default for every card; the full-width Home banner turns it off because
  /// it is a backdrop behind text, not a picture to read.
  final bool fitWhole;

  /// True when [url] is a wide backdrop or banner (the Home feature panel),
  /// so the CDN size is picked from the backdrop sizes.
  final bool backdrop;

  /// Upper bound for the decoded width in real pixels. Cards keep 2048; the
  /// full-width Home banner raises it so a 4K window stays sharp.
  final int maxDecodeWidth;

  /// Corner radius of a picture shown whole over its blurred fill, so it
  /// matches the rounded card around it (the card is 11 with a 1 px ring).
  /// Small thumbnails get a proportionally smaller radius.
  final double wholeRadius;

  @override
  State<DesktopMediaArtwork> createState() => _DesktopMediaArtworkState();
}

/// Windows: the picture each poster card was first given in this session,
/// by its [DesktopMediaArtwork.latchKey], whether Home's preloader asked for
/// it or the card itself.
///
/// A TMDB poster lookup can finish between the preloader loading a card's
/// picture and the card being built, or while the card is on screen. Without
/// this the card would then ask for the new TMDB picture, which was never
/// loaded ahead (a pop-in while paging), and the preloader would load TMDB
/// pictures that cards on screen never show. Both now get the first choice.
/// The pin is let go when the card that showed it goes away (scrolled far
/// off, or its page closed), so the next time it is built it takes the TMDB
/// poster.
abstract final class DesktopArtPins {
  /// Most pins kept; the oldest is let go beyond this.
  static const int limit = 3000;
  static final LinkedHashMap<Object, ({String? url, String? fallback})>
  _pins = LinkedHashMap();

  /// The picture pinned for [key], pinning [art] when there is none yet.
  static ({String? url, String? fallback}) keep(
    Object key,
    ({String? url, String? fallback}) art,
  ) {
    final pinned = _pins[key];
    if (pinned != null) return pinned;
    _pins[key] = art;
    while (_pins.length > limit) {
      _pins.remove(_pins.keys.first);
    }
    return art;
  }

  /// Lets the pin for [key] go, so its next card takes a fresh choice.
  static void release(Object? key) {
    if (key != null) _pins.remove(key);
  }

  /// Pins held now (tests).
  @visibleForTesting
  static int get length => _pins.length;

  /// Forgets every pin (tests).
  @visibleForTesting
  static void clear() => _pins.clear();
}

class _DesktopMediaArtworkState extends State<DesktopMediaArtwork> {
  /// The picture kept for the current [DesktopMediaArtwork.latchKey].
  ({
    String? url,
    Map<String, String>? headers,
    String? fallbackUrl,
    Map<String, String>? fallbackHeaders,
  })?
  _kept;
  Object? _keptFor;

  ({
    String? url,
    Map<String, String>? headers,
    String? fallbackUrl,
    Map<String, String>? fallbackHeaders,
  })
  get _current => (
    url: widget.url,
    headers: widget.headers,
    fallbackUrl: widget.fallbackUrl,
    fallbackHeaders: widget.fallbackHeaders,
  );

  ({
    String? url,
    Map<String, String>? headers,
    String? fallbackUrl,
    Map<String, String>? fallbackHeaders,
  })
  _picture() {
    final key = widget.latchKey;
    if (key == null) return _current;
    final kept = _kept;
    if (kept == null || _keptFor != key) {
      _keptFor = key;
      return _kept = _current;
    }
    return kept;
  }

  @override
  void didUpdateWidget(DesktopMediaArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.latchKey != widget.latchKey) {
      DesktopArtPins.release(oldWidget.latchKey);
    }
  }

  @override
  void dispose() {
    DesktopArtPins.release(widget.latchKey);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final picture = _picture();
    final url = picture.url;
    if (url == null || url.isEmpty) {
      return const ColoredBox(color: Color(0xFF20252D));
    }
    return desktopArtworkFor(
      url: url,
      width: widget.width,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      headers: picture.headers,
      backdrop: widget.backdrop,
      maxDecodeWidth: widget.maxDecodeWidth,
      fitWhole: widget.fitWhole,
      wholeRadius: widget.wholeRadius,
      fallbackUrl: picture.fallbackUrl,
      fallbackHeaders: picture.fallbackHeaders,
    );
  }
}

/// Builds the picture of a [DesktopMediaArtwork] for a non-empty [url].
/// Kept apart from the widget so Home can load the very same pictures ahead
/// of time, and tests can check which pictures (and at what sizes) a card
/// loads without building any network image.
ProgressiveArtwork desktopArtworkFor({
  required String url,
  required double width,
  required double devicePixelRatio,
  Map<String, String>? headers,
  bool backdrop = false,
  int maxDecodeWidth = 2048,
  bool fitWhole = true,
  double wholeRadius = 10,
  String? fallbackUrl,
  Map<String, String>? fallbackHeaders,
}) {
  final previewUrl = artworkPreviewUrl(url);
  // Decode at exactly the real screen pixels the card covers (logical width
  // x display scale), then ask the CDN for the smallest size that still
  // covers that. High-DPI screens get sharp art, small thumbnails stay light.
  final windows = defaultTargetPlatform == TargetPlatform.windows;
  final whole = fitWhole && windows;
  // Windows: a picture a little wider than the box (within the whole-fit
  // tolerance) fills it by cropping its sides, so it is drawn up to that
  // much wider than the box. Decoding with the same margin means it is
  // never stretched from fewer pixels than the screen shows.
  final targetWidth = desktopArtworkDecodeWidth(
    whole ? width * (1 + kArtworkFitWholeTolerance) : width,
    devicePixelRatio,
    maximum: maxDecodeWidth,
  );
  final fullUrl = desktopArtworkUrl(
    url,
    targetWidth: targetWidth,
    backdrop: backdrop,
  );
  final radius = math.min(wholeRadius, width * .08);
  // When the preview already has enough pixels (small thumbnails), the
  // preview and full URLs match and only one image is loaded.
  final staged = previewUrl != fullUrl;
  // Windows: a card this small loads its sharp picture straight away
  // instead of a preview first and then the full picture. At these sizes
  // the full file is about as light as the preview, so the two stages only
  // doubled the work while the lower Home rows load (two downloads, two
  // decodes, two uploads to the graphics card and two fade-ins per card),
  // which made first-time scrolling drop frames on built-in laptop
  // graphics. The final picture is the same, so it is just as sharp. If
  // the sharper size fails, the source's own picture is shown instead, so
  // a card never ends up blank where the preview used to stay.
  // A caller's own fallback (the usual cover behind a TMDB poster) is shown
  // at the size the card would have asked for it.
  final ownFallback = windows && fallbackUrl != null && fallbackUrl != url
      ? desktopArtworkUrl(
          fallbackUrl,
          targetWidth: targetWidth,
          backdrop: backdrop,
        )
      : null;
  if (windows && staged && targetWidth <= kDesktopArtworkSingleStageWidth) {
    final fallbackPicture = ownFallback ?? (fullUrl != url ? url : previewUrl);
    final fallbackSent = ownFallback != null ? fallbackHeaders : headers;
    return ProgressiveArtwork(
      preview: ResizeImage(
        _desktopCoverProvider(fullUrl, headers),
        width: targetWidth,
      ),
      // The fallback goes through the same whole-picture layout as the
      // card itself, so a landscape fallback in a poster box (or the
      // reverse) is shown whole over the soft fill instead of cropped,
      // exactly as the old preview-first card showed it.
      fallback: ProgressiveArtwork(
        key: const ValueKey('desktop-artwork-fallback'),
        preview: ResizeImage(
          _desktopCoverProvider(fallbackPicture, fallbackSent),
          width: targetWidth,
        ),
        fitWhole: whole,
        wholeRadius: radius,
      ),
      fitWhole: whole,
      wholeRadius: radius,
    );
  }
  return ProgressiveArtwork(
    preview: ResizeImage(
      _desktopCoverProvider(previewUrl, headers),
      width: staged ? math.min(targetWidth, 320) : targetWidth,
    ),
    full: staged
        ? ResizeImage(
            _desktopCoverProvider(fullUrl, headers),
            width: targetWidth,
          )
        : null,
    fallback: ownFallback == null
        ? null
        : ProgressiveArtwork(
            key: const ValueKey('desktop-artwork-fallback'),
            preview: ResizeImage(
              _desktopCoverProvider(ownFallback, fallbackHeaders),
              width: targetWidth,
            ),
            fitWhole: whole,
            wholeRadius: radius,
          ),
    fitWhole: whole,
    wholeRadius: radius,
  );
}

/// Windows: widest card picture, in real pixels, that is loaded in one step
/// (the sharp picture only, no preview first). Home posters and Continue
/// cards are well below this even on high-DPI screens; the full-width Home
/// banner and very large cards stay above it and keep the preview first.
const int kDesktopArtworkSingleStageWidth = 640;

/// Image provider for desktop card artwork. On Windows plain network artwork
/// is stored in the larger desktop disk cache, so a long Home page scrolled
/// back up is read from disk instead of downloaded again. Cloudflare-walled
/// Aniyomi / Mihon covers, and every other platform, keep the shared provider.
ImageProvider _desktopCoverProvider(String url, Map<String, String>? headers) {
  if (defaultTargetPlatform != TargetPlatform.windows ||
      headers?['x-ani-src'] != null ||
      headers?['x-mihon-src'] != null) {
    return nativeCoverProvider(url, headers);
  }
  return CachedNetworkImageProvider(
    url,
    headers: headers,
    cacheManager: AppImageCache.desktopArtworkManager,
  );
}

/// Shared motion only within this new Home design, with reduced-motion support.
class DesktopMediaSurface extends StatefulWidget {
  const DesktopMediaSurface({
    super.key,
    required this.child,
    this.onTap,
    this.onMenu,
    this.tooltip,
  });
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onMenu;

  /// Full title shown after a short hover on Windows (for cards whose own
  /// caption is cut off, such as the one-line Continue cards). Null = none.
  final String? tooltip;
  @override
  State<DesktopMediaSurface> createState() => DesktopMediaSurfaceState();
}

/// Owns only the pointer/focus highlight, never media or library state.
class DesktopMediaSurfaceState extends State<DesktopMediaSurface> {
  bool _active = false;
  @override
  Widget build(BuildContext context) {
    final surface = _surface(context);
    final tip = widget.tooltip?.trim();
    // Windows only: full title after a short hover (home-13).
    if (!desktopCardExtrasEnabled || tip == null || tip.isEmpty) {
      return surface;
    }
    return Tooltip(
      message: tip,
      waitDuration: desktopCardTooltipWait,
      excludeFromSemantics: true,
      child: surface,
    );
  }

  Widget _surface(BuildContext context) {
    final border = Border.all(
      // Hover/focus ring follows the Theme & colour accent; it is read on
      // every hover change, so a new accent shows on the next hover.
      color: _active ? AppColors.accent : const Color(0xFF2A3038),
    );
    // Windows: the ring is painted on top of the artwork (foreground), so
    // the picture can never cover part of it, for example at the rounded
    // corners, and the whole outline shows on hover and focus. Elsewhere the
    // ring stays behind the content as before.
    final ringOnTop = defaultTargetPlatform == TargetPlatform.windows;
    return AnimatedContainer(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 160),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xFF12161B),
        borderRadius: BorderRadius.circular(11),
        border: ringOnTop ? null : border,
      ),
      foregroundDecoration: ringOnTop
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(11),
              border: border,
            )
          : null,
      child: _content(),
    );
  }

  Widget _content() => Material(
    color: Colors.transparent,
    // Windows: Enter opens and Menu key / Shift+F10 opens the menu of the
    // focused card (pass-through elsewhere).
    child: DesktopCardKeys(
      onOpen: widget.onTap,
      onMenu: widget.onMenu,
      child: InkWell(
        onTap: widget.onTap,
        onSecondaryTap: widget.onMenu,
        onHover: (v) => setState(() => _active = v),
        onFocusChange: (v) => setState(() => _active = v),
        // Windows: the artwork gets its own paint layer, so the hover ring
        // animating (often while the list scrolls under the mouse) only
        // redraws the thin border, not the picture inside it.
        child: defaultTargetPlatform == TargetPlatform.windows
            ? RepaintBoundary(child: widget.child)
            : widget.child,
      ),
    ),
  );
}
