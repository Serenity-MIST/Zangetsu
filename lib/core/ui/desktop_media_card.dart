import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../desktop/desktop_shortcuts.dart';
import '../theme/app_colors.dart';
import 'artwork_quality.dart';
import 'native_cover_provider.dart';
import 'progressive_artwork.dart';

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
  });
  final String title;
  final String? image;
  final Map<String, String>? headers;
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
  }) => width * (wide ? 9 / 16 : .94) + (titleInside ? 0 : textScale * 56);
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
class DesktopMediaArtwork extends StatelessWidget {
  const DesktopMediaArtwork({
    super.key,
    required this.url,
    required this.width,
    this.headers,
  });
  final String? url;
  final double width;
  final Map<String, String>? headers;
  @override
  Widget build(BuildContext context) {
    if (url?.isNotEmpty != true) {
      return const ColoredBox(color: Color(0xFF20252D));
    }
    final previewUrl = artworkPreviewUrl(url!);
    final fullUrl = desktopArtworkUrl(url!);
    final targetWidth = artworkDecodeWidth(
      width,
      MediaQuery.devicePixelRatioOf(context),
    );
    final staged = previewUrl != fullUrl;
    return ProgressiveArtwork(
      preview: ResizeImage(
        nativeCoverProvider(previewUrl, headers),
        width: staged ? math.min(targetWidth, 320) : targetWidth,
      ),
      full: staged
          ? ResizeImage(
              nativeCoverProvider(fullUrl, headers),
              width: targetWidth,
            )
          : null,
    );
  }
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

  Widget _surface(BuildContext context) => AnimatedContainer(
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 160),
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: const Color(0xFF12161B),
      borderRadius: BorderRadius.circular(11),
      border: Border.all(
        // Hover/focus ring follows the Theme & colour accent; it is read on
        // every hover change, so a new accent shows on the next hover.
        color: _active ? AppColors.accent : const Color(0xFF2A3038),
      ),
    ),
    child: Material(
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
          child: widget.child,
        ),
      ),
    ),
  );
}
