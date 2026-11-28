import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Paints a lightweight preview before requesting the full image. Full-image
/// failure never removes a usable preview, and stale callbacks cannot upgrade
/// a different card after its artwork changes.
class ProgressiveArtwork extends StatefulWidget {
  const ProgressiveArtwork({
    super.key,
    required this.preview,
    this.full,
    this.fallback,
    this.fitWhole = false,
    this.wholeRadius = 0,
  });
  final ImageProvider preview;
  final ImageProvider? full;

  /// Optional offline icon/poster when the preview cannot be fetched.
  final Widget? fallback;

  /// Windows cards: never crop the artwork. When the picture's shape differs
  /// from the box (landscape art in a poster box, or the reverse), the whole
  /// picture is shown and the leftover space is filled with a soft, darkened,
  /// blurred copy of the same picture. Pictures that already match the box
  /// still fill it edge to edge. Off by default, so other screens and
  /// platforms keep the plain cover fit.
  final bool fitWhole;

  /// Corner radius of the picture when [fitWhole] shows it whole over the
  /// blurred fill. Cards pass their own inner radius so the inset picture has
  /// the same rounded corners as the card instead of square ones. 0 keeps
  /// square corners.
  final double wholeRadius;
  @override
  State<ProgressiveArtwork> createState() => _ProgressiveArtworkState();
}

/// How far (as a fraction) the picture's shape may differ from the box before
/// [ProgressiveArtwork.fitWhole] stops filling the box and shows it whole.
/// Posters from AniList, MyAnimeList and Kitsu are about 0.71 wide per 1
/// high, slightly wider than the 2:3 card (0.667), which is 6 percent off.
/// Eight percent keeps those posters edge to edge (losing about 3 percent at
/// each side, which is not noticeable) instead of showing them as a smaller
/// inset picture with thin blurred bands.
const double kArtworkFitWholeTolerance = .08;

/// True when a picture of [imageAspect] (width / height) placed in a box of
/// [boxAspect] would lose more than [tolerance] of itself to a cover crop, so
/// it should be shown whole over a blurred fill instead.
bool artworkNeedsWholeFit(
  double imageAspect,
  double boxAspect, {
  double tolerance = kArtworkFitWholeTolerance,
}) {
  if (imageAspect <= 0 || boxAspect <= 0) return false;
  final ratio = imageAspect > boxAspect
      ? imageAspect / boxAspect
      : boxAspect / imageAspect;
  return ratio - 1 > tolerance;
}

/// Windows: how many cards may start loading their full picture, or first
/// draw a one-step picture that just arrived, in the same frame. Two keeps a
/// row's sharp pictures arriving quickly while never stacking a whole row's
/// decodes, graphics-card uploads and fade-ins into one frame.
const int kDesktopFullStartsPerFrame = 2;

/// Windows: counts full-picture starts (and first draws of one-step
/// pictures, see [_FadeInPicture.staggered]) per frame for
/// [ProgressiveArtwork].
/// A frame counter is bumped by a frame callback that is added once, and the
/// allowance resets whenever the counter moves on to a new frame.
abstract final class _FullStartBudget {
  static bool _counting = false;
  static int _frame = 0;
  static int _usedFrame = -1;
  static int _used = 0;

  /// True (and counted) when one more full picture may start this frame.
  static bool take() {
    if (!_counting) {
      _counting = true;
      SchedulerBinding.instance.addPersistentFrameCallback((_) => _frame++);
    }
    if (_usedFrame != _frame) {
      _usedFrame = _frame;
      _used = 0;
    }
    if (_used >= kDesktopFullStartsPerFrame) return false;
    _used++;
    return true;
  }
}

/// Starts the full request only after preview decode (or a preview failure).
class _ProgressiveArtworkState extends State<ProgressiveArtwork> {
  bool _upgrade = false;
  bool _scheduled = false;
  int _generation = 0;

  /// Windows: true once the full image is on screen and its fade-in has
  /// finished. The preview underneath is then no longer built, so each card
  /// keeps one decoded image instead of two and the preview can leave memory.
  bool _fullShown = false;

  /// [ProgressiveArtwork.fitWhole]: the picture's width / height, once known.
  /// Read from the preview (the full image has the same shape).
  double? _imageAspect;
  ImageStream? _shapeStream;
  ImageStreamListener? _shapeListener;

  /// Windows: set once the "is the full picture already in memory?" check
  /// has run for the current pictures, so it runs once per picture pair.
  bool _memoryChecked = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _skipPreviewWhenCached();
    _readShape();
  }

  /// Windows: when the full picture is already decoded in memory (scrolling
  /// back to a row seen before), it is shown straight away and the preview is
  /// never built. Before, the preview was drawn first and the full picture
  /// was swapped in a frame later, so every card scrolled back into view did
  /// two image draws and an extra rebuild. Other platforms are unchanged.
  void _skipPreviewWhenCached() {
    if (_memoryChecked) return;
    _memoryChecked = true;
    if (defaultTargetPlatform != TargetPlatform.windows) return;
    final full = widget.full;
    if (full == null || !_decodedInMemory(full)) return;
    _upgrade = true;
    _fullShown = true;
  }

  /// True when [image] is already decoded in the shared image cache (kept
  /// there, or still on screen elsewhere). Only providers whose cache key is
  /// known at once are checked; anything else simply counts as not cached.
  bool _decodedInMemory(ImageProvider image) {
    Object? key;
    image
        .obtainKey(createLocalImageConfiguration(context))
        .then<void>((value) => key = value, onError: (Object _) {});
    final found = key;
    if (found == null) return false;
    final status = PaintingBinding.instance.imageCache.statusForKey(found);
    return status.keepAlive || (status.live && !status.pending);
  }

  @override
  void didUpdateWidget(covariant ProgressiveArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.preview != widget.preview || oldWidget.full != widget.full) {
      _generation++;
      _upgrade = false;
      _scheduled = false;
      _fullShown = false;
      _imageAspect = null;
      _stopShape();
      // New pictures: check again whether the full one is already in memory.
      _memoryChecked = false;
      _skipPreviewWhenCached();
      _readShape();
    } else if (oldWidget.fitWhole != widget.fitWhole) {
      _readShape();
    }
  }

  @override
  void dispose() {
    _stopShape();
    super.dispose();
  }

  /// Listens once to the preview to learn its shape. The same image provider
  /// is shared with the visible preview through the image cache, so this
  /// does not download or decode anything extra. The listener is removed as
  /// soon as the size is known, so it never keeps the preview in memory.
  void _readShape() {
    if (!widget.fitWhole || _imageAspect != null || _shapeStream != null) {
      return;
    }
    // Windows: a full picture shown straight from memory carries the shape,
    // so the preview is not loaded just to measure it.
    final source = _fullShown && widget.full != null
        ? widget.full!
        : widget.preview;
    final stream = source.resolve(createLocalImageConfiguration(context));
    var synchronous = true;
    final listener = ImageStreamListener(
      (info, _) {
        final image = info.image;
        final aspect = image.height == 0 ? null : image.width / image.height;
        info.dispose();
        // The size is all that is needed: stop listening straight away.
        _stopShape();
        if (aspect == null || aspect == _imageAspect) return;
        if (synchronous || !mounted) {
          _imageAspect = aspect;
        } else {
          setState(() => _imageAspect = aspect);
        }
      },
      // A failed preview simply keeps the plain cover fit.
      onError: (_, _) => _stopShape(),
    );
    _shapeStream = stream;
    _shapeListener = listener;
    stream.addListener(listener);
    synchronous = false;
  }

  void _stopShape() {
    final stream = _shapeStream, listener = _shapeListener;
    _shapeStream = null;
    _shapeListener = null;
    if (stream != null && listener != null) stream.removeListener(listener);
  }

  void _previewFinished() {
    if (_upgrade || _scheduled || widget.full == null) return;
    _scheduled = true;
    final generation = _generation;
    final windows = defaultTargetPlatform == TargetPlatform.windows;
    void start(Duration _) {
      if (!mounted || generation != _generation) return;
      // Windows: only a few cards start their full picture in the same
      // frame. When a whole row of previews lands together, the others wait
      // a frame or two, so their downloads, decodes and uploads to the
      // graphics card are spread out instead of all landing in one frame.
      if (windows && !_FullStartBudget.take()) {
        WidgetsBinding.instance.addPostFrameCallback(start);
        WidgetsBinding.instance.ensureVisualUpdate();
        return;
      }
      setState(() => _upgrade = true);
    }

    WidgetsBinding.instance.addPostFrameCallback(start);
  }

  /// Called when the full image has painted and finished fading in. Only on
  /// Windows the preview is then dropped; other platforms keep both layers as
  /// before. Runs after the frame because it can be reached during build.
  void _fullFinished() {
    if (_fullShown || defaultTargetPlatform != TargetPlatform.windows) return;
    final generation = _generation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _generation || _fullShown) return;
      setState(() => _fullShown = true);
      // The preview is no longer drawn, and scrolling back shows the full
      // picture straight from memory, so the preview's decoded copy is taken
      // out of the image cache. That leaves the room for full pictures, so
      // fewer of them are thrown out and decoded again when scrolling back.
      widget.preview
          .evict(configuration: createLocalImageConfiguration(context))
          .ignore();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.fitWhole) return _layers(BoxFit.cover, null);
    return LayoutBuilder(
      builder: (context, bounds) {
        final aspect = _imageAspect;
        final boxAspect = bounds.hasBoundedHeight && bounds.maxHeight > 0
            ? bounds.maxWidth / bounds.maxHeight
            : 0.0;
        final whole = aspect != null && artworkNeedsWholeFit(aspect, boxAspect);
        if (!whole) return _layers(BoxFit.cover, null);
        // The soft fill is a tiny copy of the picture (a few dozen pixels
        // wide) stretched over the box. It is the same tiny copy whichever
        // picture is on top, so it is decoded once and then shared.
        return _layers(
          BoxFit.contain,
          _SoftFill(image: artworkFillProvider(widget.preview)),
          inset: wholeArtworkSize(aspect, bounds.biggest),
        );
      },
    );
  }

  /// Builds the picture layers. With [inset] (whole-picture mode) the picture
  /// sits centred in a box of exactly its own shape, clipped to
  /// [ProgressiveArtwork.wholeRadius], so its corners are rounded like the
  /// card's instead of square.
  Widget _layers(BoxFit fit, Widget? fill, {Size? inset}) {
    final pictures = _pictures(fit);
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Color(0xFF20252D)),
        ?fill,
        if (inset == null)
          ...pictures
        else
          Center(
            child: SizedBox(
              key: const ValueKey('progressive-whole-picture'),
              width: inset.width,
              height: inset.height,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(widget.wholeRadius),
                child: Stack(fit: StackFit.expand, children: pictures),
              ),
            ),
          ),
      ],
    );
  }

  List<Widget> _pictures(BoxFit fit) {
    if (defaultTargetPlatform == TargetPlatform.windows) {
      return _windowsPictures(fit);
    }
    return _otherPictures(fit);
  }

  /// Windows: the same two layers, but each picture fades in by drawing
  /// itself see-through ([_FadeInPicture]) instead of through an opacity
  /// layer. An opacity layer makes the graphics card draw the picture
  /// off-screen first and then blend it, for every card that appears while
  /// the page scrolls; drawing the picture with its own see-through amount
  /// is one plain draw. The look is the same.
  List<Widget> _windowsPictures(BoxFit fit) {
    // Cover-fit pictures are decoded at the size they are drawn (within the
    // few percent a cover crop adds), so plain smoothing looks exactly the
    // same as the costlier mipmapped smoothing, which only helps a picture
    // drawn much smaller than it was decoded. A picture shown whole (contain)
    // can be drawn smaller than its decode, so it keeps the finer smoothing.
    final quality = fit == BoxFit.cover
        ? FilterQuality.low
        : FilterQuality.medium;
    return [
      // Keys keep the full image's state when the preview above it is removed.
      if (!_fullShown)
        _FadeInPicture(
          key: const ValueKey('progressive-preview-fade'),
          imageKey: const ValueKey('progressive-preview'),
          image: widget.preview,
          fit: fit,
          filterQuality: quality,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          onFrame: _previewFinished,
          // With no full picture to follow, this is the card's only (sharp)
          // picture, so it waits for a free slot in the per-frame budget
          // before it is first drawn, like full pictures do.
          staggered: widget.full == null,
          errorBuilder: (_, _, _) {
            _previewFinished();
            return widget.fallback ?? const SizedBox.shrink();
          },
        ),
      if (_upgrade && widget.full != null)
        _FadeInPicture(
          key: const ValueKey('progressive-full-fade'),
          imageKey: const ValueKey('progressive-full'),
          image: widget.full!,
          fit: fit,
          filterQuality: quality,
          duration: const Duration(milliseconds: 180),
          curve: Curves.linear,
          // Finished once it is fully shown (at once when it was in memory).
          onShown: _fullFinished,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        ),
    ];
  }

  /// Phone, TV and everything else: unchanged.
  List<Widget> _otherPictures(BoxFit fit) => [
    // Keys keep the full image's state when the preview above it is removed.
    if (!_fullShown)
      Image(
        key: const ValueKey('progressive-preview'),
        image: widget.preview,
        fit: fit,
        filterQuality: FilterQuality.medium,
        frameBuilder: (context, child, frame, synchronous) {
          if (frame != null) _previewFinished();
          // Windows: a picture that arrives while the card is on screen
          // fades in gently instead of popping in. Only the picture's
          // opacity changes (no layout), and a picture already in memory
          // (scrolling back) shows at once with no fade.
          if (synchronous || defaultTargetPlatform != TargetPlatform.windows) {
            return child;
          }
          return AnimatedOpacity(
            opacity: frame == null ? 0 : 1,
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            child: child,
          );
        },
        errorBuilder: (_, _, _) {
          _previewFinished();
          return widget.fallback ?? const SizedBox.shrink();
        },
      ),
    if (_upgrade && widget.full != null)
      Image(
        key: const ValueKey('progressive-full'),
        image: widget.full!,
        fit: fit,
        filterQuality: FilterQuality.medium,
        frameBuilder: (context, child, frame, synchronous) {
          // Already decoded (from the memory cache): it shows at once with
          // no fade, so it counts as finished straight away.
          if (frame != null && synchronous) _fullFinished();
          return AnimatedOpacity(
            opacity: frame == null ? 0 : 1,
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 180),
            onEnd: frame == null ? null : _fullFinished,
            child: child,
          );
        },
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      ),
  ];
}

/// Windows: a picture that fades in when it arrives late (downloaded or
/// decoded while the card is on screen) by drawing itself see-through, so
/// no opacity layer is needed. A picture that was already in memory shows
/// at once. With reduced motion it also shows at once.
class _FadeInPicture extends StatefulWidget {
  const _FadeInPicture({
    super.key,
    required this.image,
    required this.fit,
    required this.duration,
    required this.curve,
    required this.errorBuilder,
    this.filterQuality = FilterQuality.medium,
    this.imageKey,
    this.onFrame,
    this.onShown,
    this.staggered = false,
  });

  final ImageProvider image;
  final BoxFit fit;
  final Duration duration;
  final Curve curve;
  final ImageErrorWidgetBuilder errorBuilder;

  /// Smoothing used when the picture is scaled to its box.
  final FilterQuality filterQuality;

  /// Key of the picture itself, so it can be found like a plain image.
  final Key? imageKey;

  /// Called on every build that has a picture ready.
  final VoidCallback? onFrame;

  /// Called once the picture is fully shown (after its fade, if any).
  final VoidCallback? onShown;

  /// When true, a picture that arrives late (not straight from memory) is
  /// first drawn only once the shared per-frame budget ([_FullStartBudget])
  /// has a free slot. Cards loaded in one step (no preview first) all land
  /// at about the same time when a new row scrolls in; this spreads their
  /// first draws and fade-ins over a few frames instead of one heavy frame.
  /// Pictures already in memory always show at once.
  final bool staggered;

  @override
  State<_FadeInPicture> createState() => _FadeInPictureState();
}

class _FadeInPictureState extends State<_FadeInPicture>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: widget.duration,
  )..addStatusListener(_status);
  late final Animation<double> _opacity = CurvedAnimation(
    parent: _fade,
    curve: widget.curve,
  );

  /// The picture has arrived and the fade was started (or skipped).
  bool _started = false;

  /// [_FadeInPicture.staggered]: the picture has arrived but is waiting for
  /// a free slot in the per-frame budget. Nothing is drawn meanwhile.
  bool _waiting = false;

  /// Bumped when the picture changes, so a slot found for an old picture
  /// never starts the new one.
  int _generation = 0;

  @override
  void didUpdateWidget(covariant _FadeInPicture oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A different picture in the same place starts over.
    if (oldWidget.image != widget.image) {
      _started = false;
      _waiting = false;
      _generation++;
      _fade.value = 0;
    }
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  void _status(AnimationStatus status) {
    if (status == AnimationStatus.completed) widget.onShown?.call();
  }

  /// Runs while the picture is being built, as soon as it has a frame.
  void _arrived(bool synchronous) {
    if (_started || _waiting) return;
    // Staggered pictures that arrived late wait their turn (see
    // [_FadeInPicture.staggered]); ones from memory show at once.
    if (widget.staggered && !synchronous && !_FullStartBudget.take()) {
      _waiting = true;
      _waitForSlot(_generation);
      return;
    }
    _begin(synchronous);
  }

  /// Tries again after each frame until the budget has a free slot, then
  /// rebuilds so the picture is drawn and starts its fade.
  void _waitForSlot(int generation) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _generation || !_waiting) return;
      if (!_FullStartBudget.take()) {
        _waitForSlot(generation);
        // Makes sure another frame comes even if nothing else changes.
        WidgetsBinding.instance.ensureVisualUpdate();
        return;
      }
      setState(() {
        _waiting = false;
        _begin(false);
      });
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// Marks the picture as started and runs (or skips) its fade.
  void _begin(bool synchronous) {
    _started = true;
    final instant =
        synchronous ||
        MediaQuery.disableAnimationsOf(context) ||
        widget.duration == Duration.zero;
    if (instant) {
      // Setting the end value counts as completed, which reports "shown".
      _fade.value = 1;
    } else {
      _fade.forward();
    }
  }

  @override
  Widget build(BuildContext context) => Image(
    key: widget.imageKey,
    image: widget.image,
    fit: widget.fit,
    filterQuality: widget.filterQuality,
    // The see-through amount is applied while drawing, not as a layer.
    opacity: _opacity,
    frameBuilder: (context, child, frame, synchronous) {
      if (frame != null) {
        _arrived(synchronous);
        widget.onFrame?.call();
      }
      // While waiting for a slot nothing is drawn at all (a picture at zero
      // opacity would still cost a full draw on the graphics card).
      if (_waiting) return const SizedBox.shrink();
      return child;
    },
    errorBuilder: widget.errorBuilder,
  );
}

/// Size of a picture of [imageAspect] (width / height) shown whole inside
/// [box]: as large as possible while keeping its shape (the same area a
/// "contain" fit paints).
Size wholeArtworkSize(double imageAspect, Size box) {
  if (imageAspect <= 0 || box.isEmpty) return box;
  final boxAspect = box.width / box.height;
  return imageAspect > boxAspect
      ? Size(box.width, box.width / imageAspect)
      : Size(box.height * imageAspect, box.height);
}

/// Width, in pixels, of the tiny copy of a picture used as the soft fill
/// behind a picture shown whole. Stretched over a whole card it looks like
/// a heavy blur, without any blur work while the page scrolls.
const int kArtworkFillDecodeWidth = 24;

/// The tiny copy of [preview] used for the soft fill. A preview that is
/// already a resized copy is unwrapped first, so the tiny copy is decoded
/// straight from the original picture (one small decode, cached and shared
/// by every card that shows the same picture).
ImageProvider artworkFillProvider(ImageProvider preview) {
  final source = preview is ResizeImage ? preview.imageProvider : preview;
  return ResizeImage(source, width: kArtworkFillDecodeWidth);
}

/// The soft background behind a picture shown whole: a tiny copy of the
/// picture stretched to cover the box with the cheapest smoothing, then
/// darkened. Stretching a picture only a few dozen pixels wide already
/// gives the soft, out-of-focus look, so there is no blur filter at all.
/// The old blur filter had to be redrawn on every frame while the page
/// scrolled, which made scrolling drop frames on built-in laptop graphics.
/// This is two plain draws (the picture and the dark tint), so it needs no
/// paint layer of its own either.
class _SoftFill extends StatelessWidget {
  const _SoftFill({required this.image});
  final ImageProvider image;

  @override
  Widget build(BuildContext context) => Stack(
    key: const ValueKey('progressive-blur-fill'),
    fit: StackFit.expand,
    children: [
      Image(
        key: const ValueKey('progressive-soft-fill-image'),
        image: image,
        // Cover fit clips itself to the box, so no clip widget is needed.
        fit: BoxFit.cover,
        // Smooth stretching of the tiny copy is what makes it look soft.
        filterQuality: FilterQuality.low,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      ),
      // Darkens the fill so the sharp picture on top stands out.
      const ColoredBox(color: Color(0x73000000)),
    ],
  );
}
