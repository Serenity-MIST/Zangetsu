import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show KeepAliveParentDataMixin;
import 'package:visibility_detector/visibility_detector.dart';

import '../app_mode.dart';
import '../desktop/desktop_memory.dart';
import '../di/injector.dart';
import 'animation_prefs.dart';

/// Entrance animation for a list/grid item: a fade with a slide-up and a small
/// scale, fired the first time the card is actually ON SCREEN.
///
/// Visibility is the whole point. This used to start on BUILD, and a lazy list
/// builds roughly a screen ahead of the viewport — so every card finished
/// animating long before it was scrolled to and the reveal was invisible in
/// practice. `visibility_detector` was already a dependency (main.dart even
/// tunes its interval for "the list-reveal animations") but nothing used it.
///
/// Windows: only the first screenful of a freshly opened list plays it. Cards
/// met while scrolling (or coming back to a list) simply are there, because
/// dozens of fades and moves starting in the middle of a scroll read as lag,
/// and a card scrolled away and back used to fade in all over again.
///
/// Self-gating: on TV, or with [AnimationPrefs.listAnimations] off, the child
/// is returned untouched with no detector and no controller.
class RevealItem extends StatefulWidget {
  const RevealItem({super.key, required this.index, required this.child});

  /// Position in the list — drives the stagger so a screenful cascades in
  /// rather than snapping as one block.
  final int index;
  final Widget child;

  @override
  State<RevealItem> createState() => _RevealItemState();
}

class _RevealItemState extends State<RevealItem>
    with SingleTickerProviderStateMixin {
  AnimationController? _c;
  bool _fired = false;

  /// Stagger starter. Cancellable (unlike a bare Future.delayed) so an item
  /// that unmounts mid-cascade — mode switch, tab switch, fast scroll — never
  /// leaves a dangling timer behind.
  Timer? _starter;

  /// Captured once, at build time for this card. A card that has already
  /// revealed keeps the style it revealed with; a change applies as you scroll
  /// on, which is the only thing that makes sense for a one-shot entrance.
  late final ListAnimStyle _style = AnimationPrefs.style;

  /// VisibilityDetector keys must be unique across the whole app, and stable
  /// for the life of this state — index alone would collide between two rows
  /// showing the same position, and a key rebuilt each frame would re-register
  /// the detector constantly.
  final Key _visKey = UniqueKey();

  /// How far the card travels up on the way in. Was 10 — too small to register
  /// as movement at all.
  static const double _travel = 28;

  /// Windows: true once the entrance has played. The card is then built
  /// without the visibility detector and the fade/move wrappers, so scrolling
  /// a long grid no longer re-checks every card's bounds or keeps an extra
  /// layer per card.
  bool _done = false;

  /// Windows: keeps the card's own state (hover, loaded artwork) when the
  /// wrappers around it are removed after the entrance.
  final GlobalKey _childKey = GlobalKey();

  bool get _windows => defaultTargetPlatform == TargetPlatform.windows;

  /// Windows, more than 8 GB: how many cards from the start of a list stay
  /// built after they scroll away, so coming back builds nothing.
  static const int _keepAliveCards = 96;

  bool get _wantsToStay =>
      _windows &&
      DesktopMemory.systemMemoryMb > DesktopMemory.lowMemoryLimitMb &&
      widget.index < _keepAliveCards &&
      !(sl.isRegistered<AppMode>() && sl<AppMode>().isTv);

  /// Held while this card asks its own list to keep it built.
  KeepAliveHandle? _stay;

  /// Windows: steps over this card's focus while it is kept but scrolled
  /// away, so Tab never lands on a card nobody can see. Only made for cards
  /// that are kept.
  _KeptCardFocus? _keptFocus;

  /// Asks the list this card sits in (and no list further out) to keep it.
  ///
  /// The usual mixin sends its request up through every list around the card,
  /// and each of those then keeps its whole item too: every visited tab of My
  /// List and every search row stayed built, with no limit. This hands the
  /// request to the nearest list only, and only when that is an ordinary
  /// vertical list or grid. A short sideways row gains nothing from it.
  void _updateStay() {
    if (!_wantsToStay) {
      _stay?.dispose();
      _stay = null;
      return;
    }
    if (_stay != null) return;
    final position = context
        .findAncestorStateOfType<ScrollableState>()
        ?.position;
    if (position == null ||
        position is PageMetrics ||
        position.axis != Axis.vertical) {
      return;
    }
    NotificationListener<KeepAliveNotification>? keeper;
    context.visitAncestorElements((element) {
      final widget = element.widget;
      if (widget is NotificationListener<KeepAliveNotification>) {
        keeper = widget;
      } else if (widget is! Scrollable) {
        return true;
      }
      return false;
    });
    final keep = keeper?.onNotification;
    if (keep == null) return;
    final stay = _stay = KeepAliveHandle();
    keep(KeepAliveNotification(stay));
    _keptFocus ??= _KeptCardFocus(() => _scrolledAway);
  }

  /// True while the card is only kept: built, but outside what its list lays
  /// out.
  bool get _scrolledAway {
    if (!mounted) return false;
    RenderObject? box = context.findRenderObject();
    while (box != null) {
      final data = box.parentData;
      if (data is KeepAliveParentDataMixin) return data.keptAlive;
      box = box.parent;
    }
    return false;
  }

  @override
  void deactivate() {
    _stay?.dispose();
    _stay = null;
    super.deactivate();
  }

  @override
  void initState() {
    super.initState();
    _updateStay();
    if (!AnimationPrefs.listAnimations || sl<AppMode>().isTv) return;
    if (_windows) {
      if (_listHasMoved()) return;
      // Cards built ahead, below the visible part, also skip the entrance, so
      // they never pop in from nothing when they are scrolled to.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _done || _fired || !_outsideList()) return;
        setState(() => _done = true);
      });
    }
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );
    if (_windows) {
      _c!.addStatusListener((status) {
        if (status == AnimationStatus.completed && mounted && !_done) {
          setState(() => _done = true);
        }
      });
    }
  }

  @override
  void didUpdateWidget(RevealItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) _updateStay();
  }

  /// Every list this card sits in, from the nearest outwards (a grid can sit
  /// inside a longer page). Swiped pages and tabs are not lists.
  Iterable<ScrollableState> _lists() sync* {
    var list = context.findAncestorStateOfType<ScrollableState>();
    while (list != null) {
      if (list.position is! PageMetrics) yield list;
      list = list.context.findAncestorStateOfType<ScrollableState>();
    }
  }

  /// Windows: true when a list around this card is moving, or is no longer at
  /// its start, so this card is not part of a freshly opened screen.
  bool _listHasMoved() {
    for (final list in _lists()) {
      final position = list.position;
      if (!position.hasPixels) continue;
      final start = position.hasContentDimensions
          ? position.minScrollExtent
          : 0.0;
      if (position.isScrollingNotifier.value || position.pixels > start + 1) {
        return true;
      }
    }
    return false;
  }

  /// Windows: true when this card was laid out outside the visible part of
  /// any list it sits in. Measured inside the list, so a page that is still
  /// sliding in counts as it will look once it is there.
  bool _outsideList() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return false;
    for (final list in _lists()) {
      final view = list.context.findRenderObject();
      if (view is! RenderBox || !view.hasSize) continue;
      final card = MatrixUtils.transformRect(
        box.getTransformTo(view),
        Offset.zero & box.size,
      );
      if (!card.overlaps(Offset.zero & view.size)) return true;
    }
    return false;
  }

  @override
  void dispose() {
    _starter?.cancel();
    _c?.dispose();
    _keptFocus?.dispose();
    super.dispose();
  }

  void _onVisible(VisibilityInfo info) {
    if (_fired || !mounted || info.visibleFraction <= 0) return;
    _fired = true;
    // Cascade across a screenful. The old stagger was `index % 4`, which reset
    // every fourth card, so items 4, 8, 12… all started together and there was
    // no wave. Modulo 8 with a longer step reads as one continuous run, and
    // stays capped so a long list never accumulates a visible lag.
    final delay = Duration(milliseconds: 45 * (widget.index % 8));
    _starter = Timer(delay, () {
      if (mounted) _c?.forward();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Also after a move to another place in the tree, which gave it up.
    _updateStay();
    final focus = _keptFocus;
    if (focus == null) return _card(context);
    return Focus.withExternalFocusNode(
      focusNode: focus,
      includeSemantics: false,
      child: _card(context),
    );
  }

  Widget _card(BuildContext context) {
    final c = _c;
    if (c == null) return widget.child;
    // Windows: the same card under a stable key, so dropping the wrappers
    // below moves it rather than rebuilding it from scratch.
    final child = _windows
        ? KeyedSubtree(key: _childKey, child: widget.child)
        : widget.child;
    if (_done) return child;
    return VisibilityDetector(
      key: _visKey,
      onVisibilityChanged: _onVisible,
      child: AnimatedBuilder(
        animation: c,
        child: child,
        builder: (context, child) {
          final t = Curves.easeOutCubic.transform(c.value);
          // Full opacity arrives a little before the movement settles, so the
          // card is readable while it's still easing into place.
          final fade = Curves.easeOut.transform(
            (c.value * 1.4).clamp(0.0, 1.0),
          );
          return switch (_style) {
            ListAnimStyle.fade => Opacity(opacity: fade, child: child),
            ListAnimStyle.zoom => Opacity(
              opacity: fade,
              child: Transform.scale(scale: 0.85 + 0.15 * t, child: child),
            ),
            ListAnimStyle.rise => Opacity(
              opacity: fade,
              child: Transform.translate(
                offset: Offset(0, (1 - t) * _travel),
                // The lift, rather than just a drift upwards.
                child: Transform.scale(scale: 0.94 + 0.06 * t, child: child),
              ),
            ),
          };
        },
      ),
    );
  }
}

/// Takes no focus itself; hides the focus of everything below it from Tab and
/// the arrow keys while [hidden] says so. Asked at the moment a key is
/// pressed, so a card scrolling in or out needs no rebuild.
class _KeptCardFocus extends FocusNode {
  _KeptCardFocus(this.hidden)
    : super(
        debugLabel: 'kept card',
        canRequestFocus: false,
        skipTraversal: true,
      );

  final bool Function() hidden;

  @override
  bool get descendantsAreTraversable =>
      super.descendantsAreTraversable && !hidden();
}
