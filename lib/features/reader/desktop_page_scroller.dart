import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/ui/desktop_docked_panel.dart' show DesktopEscCloses;

/// Fit modes whose paged layout can be larger than a desktop window, so the
/// page needs its own scroll view there (Contain and Height always fit).
bool desktopFitOverflows(String fitKey) =>
    fitKey == 'width' || fitKey == 'smart' || fitKey == 'original';

/// How long the wheel must rest at a page edge before it may turn the page.
/// One fast flick then stops at the bottom of a page instead of skipping it.
const Duration kDesktopPageEdgeRest = Duration(milliseconds: 350);

/// How far one arrow-key press moves a long strip, a novel in scroll mode or
/// a tall page (reader-3): a few lines, so the line being read stays on
/// screen. PageUp/PageDown/Space keep moving a screenful.
const double kDesktopArrowScrollStep = 100;

/// Length of the short glide used for keyboard scrolling (reader-3 B), so
/// the eye can follow a screenful jump instead of losing its place.
const Duration kDesktopKeyScrollDuration = Duration(milliseconds: 160);

/// Where each controller's current keyboard glide is heading. Further key
/// presses during a glide add to that target, so holding a key or pressing
/// it quickly still covers the full distance instead of restarting short.
final Expando<double> _desktopScrollTargets = Expando<double>(
  'desktop-scroll-target',
);

/// Scrolls [controller] by [delta] pixels with a short animation (reader-3).
/// Clamped to the scroll extent; does nothing without a client.
Future<void> desktopAnimatedScrollBy(
  ScrollController controller,
  double delta,
) async {
  if (!controller.hasClients || delta == 0) return;
  final position = controller.position;
  final pending = _desktopScrollTargets[controller];
  final target = ((pending ?? position.pixels) + delta)
      .clamp(position.minScrollExtent, position.maxScrollExtent)
      .toDouble();
  if (pending == null && (target - position.pixels).abs() < 0.5) return;
  _desktopScrollTargets[controller] = target;
  try {
    await controller.animateTo(
      target,
      duration: kDesktopKeyScrollDuration,
      curve: Curves.easeOutCubic,
    );
  } finally {
    // A newer press may have moved the target on; only the last glide
    // clears it.
    if (_desktopScrollTargets[controller] == target) {
      _desktopScrollTargets[controller] = null;
    }
  }
}

/// Windows paged-reader viewport for a page whose fit makes it taller (or, for
/// Original, wider) than the window. The wheel, a mouse drag, the scrollbar
/// and the keyboard move through the page; the wheel falls through to the
/// reader's page turn only once the page sits at that edge.
class DesktopPageScroller extends StatefulWidget {
  const DesktopPageScroller({
    super.key,
    required this.child,
    this.horizontal = false,
    this.startAtEnd = false,
    this.onAttach,
    this.onDetach,
  });

  final Widget child;

  /// Also pan sideways (Original fit can be wider than the window).
  final bool horizontal;

  /// Open at the bottom of the page — used when the reader stepped backwards,
  /// so reading back up continues from the end of the previous page.
  final bool startAtEnd;

  /// Lets the reader route keyboard scrolling to the page on screen.
  final ValueChanged<DesktopPageScrollerState>? onAttach;
  final ValueChanged<DesktopPageScrollerState>? onDetach;

  @override
  State<DesktopPageScroller> createState() => DesktopPageScrollerState();
}

/// Owns the page's scroll controllers and the edge-rest wheel guard.
class DesktopPageScrollerState extends State<DesktopPageScroller> {
  final ScrollController vertical = ScrollController();
  final ScrollController sideways = ScrollController();

  /// Keeps the page pinned to its bottom while its image is still loading,
  /// until the user moves it themselves.
  late bool _pinToEnd = widget.startAtEnd;

  /// Time stamp of the last wheel event this page either scrolled or held.
  Duration? _lastWheel;

  /// True once the wheel has rested at an edge and been let through to the
  /// page turn; further wheel events at that edge then pass straight through.
  bool _edgeOpen = false;

  @override
  void initState() {
    super.initState();
    widget.onAttach?.call(this);
    if (_pinToEnd) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToEndIfPinned());
    }
  }

  @override
  void dispose() {
    widget.onDetach?.call(this);
    vertical.dispose();
    sideways.dispose();
    super.dispose();
  }

  /// True when there is more page below the viewport.
  bool get canScrollDown =>
      vertical.hasClients &&
      vertical.position.pixels < vertical.position.maxScrollExtent - 0.5;

  /// True when there is more page above the viewport.
  bool get canScrollUp =>
      vertical.hasClients &&
      vertical.position.pixels > vertical.position.minScrollExtent + 0.5;

  /// The visible page height, used for PageUp/PageDown/Space steps.
  double get viewportHeight =>
      vertical.hasClients ? vertical.position.viewportDimension : 0;

  /// Moves the page by [delta] pixels. Returns false (and does nothing) when
  /// the page is already at that edge, so the caller can turn the page.
  /// [animate] glides there instead of jumping (keyboard steps, reader-3).
  bool scrollBy(double delta, {bool animate = false}) {
    _pinToEnd = false;
    if (!vertical.hasClients || delta == 0) return false;
    if (delta > 0 && !canScrollDown) return false;
    if (delta < 0 && !canScrollUp) return false;
    if (animate) {
      desktopAnimatedScrollBy(vertical, delta);
      return true;
    }
    final p = vertical.position;
    vertical.jumpTo(
      (p.pixels + delta).clamp(p.minScrollExtent, p.maxScrollExtent),
    );
    return true;
  }

  /// Home/End: jumps to the top or the bottom of the page.
  bool jumpToEdge({required bool end}) {
    _pinToEnd = false;
    if (!vertical.hasClients) return false;
    final p = vertical.position;
    final target = end ? p.maxScrollExtent : p.minScrollExtent;
    if ((p.pixels - target).abs() < 0.5) return false;
    vertical.jumpTo(target);
    return true;
  }

  void _jumpToEndIfPinned() {
    if (!mounted || !_pinToEnd || !vertical.hasClients) return;
    final max = vertical.position.maxScrollExtent;
    if (vertical.position.pixels != max) vertical.jumpTo(max);
  }

  /// Runs after the Scrollable below has had first claim on the wheel. If the
  /// page could still move it already took the event; otherwise the event is
  /// held while the wheel has not rested at the edge for [kDesktopPageEdgeRest].
  void _onSignal(PointerSignalEvent event) {
    _pinToEnd = false;
    if (event is! PointerScrollEvent) return;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final sidewaysWheel =
        shift || event.scrollDelta.dx.abs() > event.scrollDelta.dy.abs();
    if (sidewaysWheel) {
      // Original-fit pages pan sideways themselves; at their edge the event is
      // held so the PageView behind cannot drift half a page off its snap.
      if (widget.horizontal) {
        GestureBinding.instance.pointerSignalResolver.register(event, (_) {});
      }
      return;
    }
    final dy = event.scrollDelta.dy;
    final scrolls = dy > 0 ? canScrollDown : canScrollUp;
    final last = _lastWheel;
    _lastWheel = event.timeStamp;
    if (scrolls) {
      // Moving through the page again closes the edge until it rests there.
      _edgeOpen = false;
      return;
    }
    // Once released, the edge stays open so a high-resolution wheel (many
    // small notches) can add up to a full page turn without pausing again.
    if (_edgeOpen) return;
    if (last != null && event.timeStamp - last < kDesktopPageEdgeRest) {
      GestureBinding.instance.pointerSignalResolver.register(event, (_) {});
      return;
    }
    _edgeOpen = true;
  }

  @override
  Widget build(BuildContext context) {
    // Mouse drag pans the page (desktop scroll behaviour excludes the mouse by
    // default). Scoped to this page, so the PageView keeps its own devices.
    final behavior = ScrollConfiguration.of(context).copyWith(
      dragDevices: {
        PointerDeviceKind.mouse,
        PointerDeviceKind.touch,
        PointerDeviceKind.stylus,
        PointerDeviceKind.invertedStylus,
        PointerDeviceKind.trackpad,
      },
      scrollbars: true,
    );
    Widget content = widget.child;
    if (widget.horizontal) {
      content = SingleChildScrollView(
        key: const ValueKey('desktop-page-scroll-sideways'),
        controller: sideways,
        scrollDirection: Axis.horizontal,
        child: content,
      );
    }
    return ScrollConfiguration(
      behavior: behavior,
      child: NotificationListener<ScrollMetricsNotification>(
        onNotification: (_) {
          if (_pinToEnd) {
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => _jumpToEndIfPinned(),
            );
          }
          return false;
        },
        child: Listener(
          onPointerDown: (_) => _pinToEnd = false,
          onPointerSignal: _onSignal,
          child: SingleChildScrollView(
            key: const ValueKey('desktop-page-scroll'),
            controller: vertical,
            child: content,
          ),
        ),
      ),
    );
  }
}

/// Gives a desktop reader the first look at key presses, ahead of
/// DesktopReaderInput (an ancestor), by holding primary focus itself.
/// Keys it ignores bubble up to DesktopReaderInput unchanged.
class DesktopReaderKeyScope extends StatefulWidget {
  const DesktopReaderKeyScope({
    super.key,
    required this.onKey,
    required this.child,
  });

  final KeyEventResult Function(KeyEvent event) onKey;
  final Widget child;

  @override
  State<DesktopReaderKeyScope> createState() => _DesktopReaderKeyScopeState();
}

/// Requests focus after the first frame so it sits below DesktopReaderInput.
class _DesktopReaderKeyScopeState extends State<DesktopReaderKeyScope> {
  final FocusNode _node = FocusNode(debugLabel: 'desktop-reader-keys');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ModalRoute.of(context)?.isCurrent != false) {
        _node.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _node,
    onKeyEvent: (node, event) {
      if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
        return KeyEventResult.ignored;
      }
      if (ModalRoute.of(context)?.isCurrent == false) {
        return KeyEventResult.ignored;
      }
      if (HardwareKeyboard.instance.isControlPressed ||
          HardwareKeyboard.instance.isAltPressed ||
          HardwareKeyboard.instance.isMetaPressed) {
        return KeyEventResult.ignored;
      }
      return widget.onKey(event);
    },
    child: widget.child,
  );
}

/// Shows reader settings and other reader panels. Phones keep the bottom
/// sheet; Windows gets a floating side panel that leaves the page visible on
/// the left, so every setting previews live while it is changed.
Future<T?> showReaderPanel<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  if (defaultTargetPlatform != TargetPlatform.windows) {
    return showModalBottomSheet<T>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: builder,
    );
  }
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black26,
    transitionDuration: const Duration(milliseconds: 180),
    // Esc closes the panel itself, ahead of the window-level Esc that would
    // otherwise leave fullscreen and keep the panel open.
    pageBuilder: (ctx, _, _) => DesktopEscCloses(
      child: SafeArea(
        child: Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 6, 4),
            child: SizedBox(
              key: const ValueKey('reader-desktop-panel'),
              width: 460,
              child: Material(
                type: MaterialType.transparency,
                // The shared sheet bodies cap themselves at 85% of the height
                // and scroll inside, so they fit a 720px-tall window.
                child: Builder(builder: builder),
              ),
            ),
          ),
        ),
      ),
    ),
    transitionBuilder: (ctx, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0.06, 0),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
}
