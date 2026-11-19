// Windows: mouse input on the video surface, shared by the full player and
// the theater watch page.
//
// A GestureDetector with both onTap and onDoubleTap holds every single click
// for ~300ms waiting for a possible second one, which made pausing feel slow.
// [DesktopVideoClick] acts on the FIRST click at once (play/pause) and, when a
// second click lands inside the double-click window, undoes that toggle and
// runs the double-click action (fullscreen) instead, as YouTube and VLC do.
//
// [DesktopVideoPointer] feeds it from raw pointer events (no gesture arena,
// so nothing waits) and also reports right-clicks for the context menu.
// [DesktopVideoWheel] turns the mouse wheel into volume steps, but only for
// wheel events over the widget it wraps (the video), not the whole page.
import 'package:flutter/gestures.dart'
    show
        GestureBinding,
        PointerScrollEvent,
        kDoubleTapTimeout,
        kPrimaryMouseButton,
        kSecondaryMouseButton,
        kTouchSlop;
import 'package:flutter/widgets.dart';

class DesktopVideoClick {
  DesktopVideoClick({
    this.window = kDoubleTapTimeout,
    @visibleForTesting DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Longest gap between two clicks that still counts as a double-click.
  final Duration window;
  final DateTime Function() _clock;

  /// When the previous click landed; null once it was used for a double.
  DateTime? _last;

  /// Whether the previous click actually toggled playback (it doesn't
  /// while the video is still loading), so a double only undoes a real toggle.
  bool _lastToggled = false;

  /// Handles one click. [onSingle] runs right away unless [canToggle] is
  /// false; a second click inside [window] calls [onSingle] again (undoing the
  /// first toggle) and then [onDouble].
  void click({
    required VoidCallback onSingle,
    required VoidCallback onDouble,
    bool canToggle = true,
  }) {
    final now = _clock();
    final last = _last;
    if (last != null && now.difference(last) <= window) {
      // Second click of a double: put playback back how it was, then go
      // fullscreen. Reset so a third click starts a fresh sequence.
      if (_lastToggled) onSingle();
      _last = null;
      _lastToggled = false;
      onDouble();
      return;
    }
    _last = now;
    _lastToggled = canToggle;
    if (canToggle) onSingle();
  }

  /// Forgets a pending first click (e.g. after a drag or a menu).
  void reset() {
    _last = null;
    _lastToggled = false;
  }
}

/// Raw-pointer click layer for the video. A primary click fires on release
/// (when the mouse barely moved, so a window drag in the mini player is not a
/// click); a right-button press opens the context menu at once, at the
/// pointer. Translucent, so the video and anything below still get events.
class DesktopVideoPointer extends StatefulWidget {
  const DesktopVideoPointer({
    super.key,
    required this.onToggle,
    required this.onDoubleClick,
    this.canToggle,
    this.onContextMenu,
    this.onDragStart,
    this.child,
  });

  /// Single click: play / pause.
  final VoidCallback onToggle;

  /// Double click: fullscreen (or the full player on the watch page).
  final VoidCallback onDoubleClick;

  /// False while playback cannot be toggled yet (first load); the click is
  /// still counted so a double-click keeps working.
  final bool Function()? canToggle;

  /// Right-click at a global position.
  final ValueChanged<Offset>? onContextMenu;

  /// The primary button moved past the touch slop while held: a drag, not
  /// a click. The mini player uses it to move its borderless window.
  final ValueChanged<Offset>? onDragStart;

  final Widget? child;

  @override
  State<DesktopVideoPointer> createState() => _DesktopVideoPointerState();
}

class _DesktopVideoPointerState extends State<DesktopVideoPointer> {
  final DesktopVideoClick _click = DesktopVideoClick();

  /// Where the primary button went down; null when no primary press is live.
  Offset? _downAt;
  bool _moved = false;

  void _onDown(PointerDownEvent e) {
    if (e.buttons & kSecondaryMouseButton != 0) {
      // A right-click must never count toward a double-click.
      _click.reset();
      widget.onContextMenu?.call(e.position);
      return;
    }
    if (e.buttons & kPrimaryMouseButton == 0) return;
    _downAt = e.position;
    _moved = false;
  }

  void _onMove(PointerMoveEvent e) {
    final at = _downAt;
    if (at == null || _moved) return;
    if ((e.position - at).distance > kTouchSlop) {
      _moved = true;
      widget.onDragStart?.call(at);
    }
  }

  void _onUp(PointerUpEvent e) {
    final at = _downAt;
    _downAt = null;
    if (at == null) return;
    if (_moved) {
      // A drag is not a click, and must not pair with the next one.
      _click.reset();
      return;
    }
    _click.click(
      onSingle: widget.onToggle,
      onDouble: widget.onDoubleClick,
      canToggle: widget.canToggle?.call() ?? true,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onUp,
      onPointerCancel: (_) => _downAt = null,
      child: widget.child ?? const SizedBox.expand(),
    );
  }
}

/// Mouse wheel over [child] changes the volume: [onStep] gets +1 for wheel
/// up and -1 for wheel down. Claimed through the pointer-signal resolver, so
/// a scrollable around the video (the watch page list) does not scroll, and
/// the wheel elsewhere on the page keeps scrolling normally. A horizontal
/// touchpad swipe is ignored.
class DesktopVideoWheel extends StatelessWidget {
  const DesktopVideoWheel({
    super.key,
    required this.onStep,
    required this.child,
    this.enabled = true,
  });

  final ValueChanged<int> onStep;
  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerSignal: (event) {
        if (event is! PointerScrollEvent || event.scrollDelta.dy == 0) return;
        final step = event.scrollDelta.dy < 0 ? 1 : -1;
        GestureBinding.instance.pointerSignalResolver.register(
          event,
          (_) => onStep(step),
        );
      },
      child: child,
    );
  }
}
