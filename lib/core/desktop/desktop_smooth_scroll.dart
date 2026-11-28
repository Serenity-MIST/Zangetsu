import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart' show nearEqual;
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

/// How long one mouse-wheel glide takes on Windows. Long enough to read as
/// a smooth slide, short enough that the page still feels like it follows
/// the wheel. A notch that arrives during a glide starts a fresh glide of
/// this length from where the page is, towards the new (summed) target.
const desktopWheelGlide = Duration(milliseconds: 220);

/// The glide clock runs one frame ahead, so the very first frame after a
/// notch already moves the page instead of drawing a still frame (which is
/// what made each notch feel like a small hitch).
const _frameLead = Duration(microseconds: 16667);

/// Shape of one stretch of a wheel glide. Each stretch runs from where the
/// page is to the target in [desktopWheelGlide], ending at rest. [startSpeed]
/// is how fast it leaves, measured as "distances per glide length": 3 is a
/// quick start with a soft landing (exactly an ease-out cubic, what a fresh
/// glide uses), lower values start gentler and speed up a little first.
/// Values from 0 to 3 never overshoot the target.
///
/// Why: when a notch arrives during a glide, restarting a plain ease-out
/// made the page jump to top speed on every notch and slow down in between,
/// a speed saw-tooth that reads as judder when the wheel spins fast. A notch
/// during a glide now carries on at the speed the page already has.
double desktopGlideStretchValue(double s, double startSpeed) {
  // Cubic curve from 0 to 1 that leaves at [startSpeed] and lands at rest.
  final s2 = s * s, s3 = s2 * s;
  return (3 * s2 - 2 * s3) + startSpeed * (s3 - 2 * s2 + s);
}

/// Speed along a stretch at [s], in distances per glide length (see
/// [desktopGlideStretchValue]).
double desktopGlideStretchSpeed(double s, double startSpeed) =>
    (6 * s - 6 * s * s) + startSpeed * (3 * s * s - 4 * s + 1);

/// Start speed of a fresh glide: quick start, soft landing (ease-out cubic).
const double _freshStartSpeed = 3;

/// Slowest start a notch during a glide may get, so a notch that lands when
/// the page has nearly stopped still moves off promptly (at least the
/// stretch's own average speed).
const double _minCarrySpeed = 1;

/// The start speed for a new stretch of [distance] pixels when the page is
/// moving at [pixelsPerSecond]. Same direction: carry the current speed on.
/// The other way (or not moving yet): a fresh quick start.
double _carriedStartSpeed(double pixelsPerSecond, double distance) {
  if (distance == 0 || pixelsPerSecond * distance <= 0) {
    return _freshStartSpeed;
  }
  return (pixelsPerSecond * _glideSeconds / distance).clamp(
    _minCarrySpeed,
    _freshStartSpeed,
  );
}

/// Length of one glide in seconds.
double get _glideSeconds =>
    desktopWheelGlide.inMicroseconds / Duration.microsecondsPerSecond;

/// Smallest wheel step, in real screen pixels, that counts as a notch of a
/// normal mouse wheel. Windows sends about 100 real pixels per notch with
/// the default "3 lines" setting (33 with 1 line). Touchpads and
/// smooth-scrolling mice send many small steps instead; those already move
/// smoothly and are passed straight through without any animation.
const double desktopWheelNotchMinPhysical = 30;

/// True when [event] is a notch of a normal mouse wheel (to be animated),
/// false for touchpads and fine-step wheels (to be applied as is).
/// [devicePixelRatio] turns the logical delta back into real screen pixels.
bool desktopWheelIsNotch(PointerScrollEvent event, double devicePixelRatio) {
  if (event.kind != PointerDeviceKind.mouse) return false;
  final logical = event.scrollDelta.dx.abs() > event.scrollDelta.dy.abs()
      ? event.scrollDelta.dx.abs()
      : event.scrollDelta.dy.abs();
  return logical * devicePixelRatio >= desktopWheelNotchMinPhysical;
}

/// The running wheel glide of each scroll position, if any. Kept outside
/// the position so the helper works for any scroll view.
final _glides = Expando<_WheelGlideActivity>('desktop wheel glide');

/// Same, for positions that are not plain single scroll views (the two
/// linked lists of a NestedScrollView, such as the show detail page).
final _stepGlides = Expando<_StepGlide>('desktop wheel step glide');

/// Windows mouse wheel: moves [position] by [delta] pixels as a short eased
/// glide instead of one instant jump per notch, which reads as stutter on a
/// 60-144 Hz screen. Notches that arrive during a glide move the same
/// target further, and the glide carries on from where the page is towards
/// it, so fast wheeling is one continuous slide instead of a restart per
/// notch. Turning the wheel the other way starts from where the page is.
/// With reduced motion on ([reduceMotion]) it jumps straight there.
///
/// A drag, a keyboard scroll or anything else that takes over the position
/// ends the glide, and the next notch starts from where the page is.
void desktopSmoothScrollBy(
  ScrollPosition position,
  double delta, {
  bool reduceMotion = false,
}) {
  if (delta == 0 || !position.hasContentDimensions || !position.hasPixels) {
    return;
  }
  if (position is! ScrollPositionWithSingleContext) {
    // NestedScrollView and other linked positions: the glide is fed through
    // the position's own wheel handling a little at a time, so the header
    // and the inner list share the movement exactly as they do for a notch.
    if (reduceMotion) {
      _stepGlides[position]?.stop();
      position.pointerScroll(delta);
      return;
    }
    final running = _stepGlides[position];
    if (running != null && running.add(delta)) return;
    _stepGlides[position] = _StepGlide(position, delta);
    return;
  }

  final running = _glides[position];
  final live = running != null && running.isLive;
  // Same direction as the running glide: extend its target. Other way (or
  // nothing running): start from where the page is now.
  final sameWay = live && (running.target - position.pixels) * delta > 0;
  final from = sameWay ? running.target : position.pixels;
  final target = (from + delta).clamp(
    position.minScrollExtent,
    position.maxScrollExtent,
  );
  if (reduceMotion) {
    _glides[position] = null;
    if (target != position.pixels) position.jumpTo(target);
    return;
  }
  if (live) {
    // Keeps the one glide going (no new start/end scroll events, no lost
    // speed), just towards the new target.
    running.retarget(target);
    return;
  }
  if (target == position.pixels) return;
  // Very close already: just jump, like Flutter's own animateTo does.
  if (nearEqual(
    target,
    position.pixels,
    position.physics.toleranceFor(position).distance,
  )) {
    position.jumpTo(target);
    return;
  }
  final glide = _WheelGlideActivity(
    position,
    from: position.pixels,
    to: target,
    vsync: position.context.vsync,
  );
  _glides[position] = glide;
  position.beginActivity(glide);
}

/// One wheel glide on a normal scroll view. Unlike Flutter's own animated
/// scroll it keeps the page reacting to the mouse while it runs (hover and
/// clicks are not lost after each notch), and it can be pointed at a new
/// target without stopping, so rapid notches flow into one slide.
class _WheelGlideActivity extends ScrollActivity {
  _WheelGlideActivity(
    super.delegate, {
    required double from,
    required double to,
    required TickerProvider vsync,
  }) : _from = from,
       _to = to,
       _value = from {
    _ticker = vsync.createTicker(_tick)..start();
  }

  late final Ticker _ticker;

  /// Where the current stretch of the glide began and where it ends.
  double _from, _to;

  /// Where the glide put the page on the last frame.
  double _value;

  /// Glide clock time at which the current stretch began.
  Duration _stretchStart = Duration.zero;

  /// Glide clock time of the last frame, and whether one ran yet.
  Duration _lastElapsed = Duration.zero;
  bool _ticked = false;

  double _velocity = 0;
  bool _disposed = false;

  /// How fast the current stretch leaves (see [desktopGlideStretchValue]).
  double _startSpeed = _freshStartSpeed;

  /// Where the glide is heading.
  double get target => _to;

  /// Still running (not replaced by a drag, a jump or the glide's end).
  bool get isLive => !_disposed;

  /// Points the glide at [to], continuing from where the page is and at the
  /// speed it already has, so a notch never makes the page lurch.
  void retarget(double to) {
    _startSpeed = _ticked
        ? _carriedStartSpeed(_velocity, to - _value)
        : _freshStartSpeed;
    _from = _value;
    _to = to;
    // The next frame is already one frame into the new stretch, so the page
    // keeps moving on every frame while notches keep coming.
    _stretchStart = _ticked ? _lastElapsed + _frameLead : Duration.zero;
  }

  void _tick(Duration elapsed) {
    _lastElapsed = elapsed;
    _ticked = true;
    final micros = (elapsed + _frameLead - _stretchStart).inMicroseconds;
    final t = (micros / desktopWheelGlide.inMicroseconds).clamp(0.0, 1.0);
    _value = _from + (_to - _from) * desktopGlideStretchValue(t, _startSpeed);
    // Speed in pixels per second. Flutter uses it to hold back image
    // loading while the page moves very fast; the next notch carries it on.
    _velocity =
        (_to - _from) *
        desktopGlideStretchSpeed(t, _startSpeed) /
        _glideSeconds;
    // The content got shorter under the glide: stop at the new edge.
    if (delegate.setPixels(_value) != 0) {
      delegate.goIdle();
      return;
    }
    if (t >= 1 && !_disposed) {
      _velocity = 0;
      delegate.goBallistic(0);
    }
  }

  @override
  bool get shouldIgnorePointer => false;

  @override
  bool get isScrolling => true;

  @override
  double get velocity => _velocity;

  @override
  void dispose() {
    _disposed = true;
    _ticker.dispose();
    super.dispose();
  }
}

/// A wheel glide for linked positions (NestedScrollView). Each frame it
/// hands the position the next small piece of the eased movement through
/// the position's own wheel handling. It uses frame callbacks rather than a
/// ticker of the scroll view, so leaving the page mid-glide is always safe.
class _StepGlide {
  _StepGlide(this.position, double delta) : _goal = delta {
    SchedulerBinding.instance.scheduleFrameCallback(_frame);
  }

  final ScrollPosition position;

  /// Total movement asked for, and how much was handed over so far.
  double _goal;
  double _applied = 0;

  /// Movement handed over when the current stretch began.
  double _stretchFrom = 0;
  Duration? _base;
  Duration _stretchStart = Duration.zero;
  Duration _lastElapsed = Duration.zero;
  bool _ticked = false;
  bool _stopped = false;

  /// How fast the current stretch leaves (see [desktopGlideStretchValue]),
  /// and the speed on the last frame in pixels per second.
  double _startSpeed = _freshStartSpeed;
  double _speed = 0;

  /// Adds one more notch. False when this glide has already ended, so the
  /// caller starts a new one.
  bool add(double delta) {
    if (_stopped) return false;
    final remaining = _goal - _applied;
    // The other way: drop what was left and head back from here.
    _goal = remaining * delta < 0 ? _applied + delta : _goal + delta;
    // Same way: carry on at the current speed instead of lurching.
    _startSpeed = _ticked
        ? _carriedStartSpeed(_speed, _goal - _applied)
        : _freshStartSpeed;
    _stretchFrom = _applied;
    _stretchStart = _ticked ? _lastElapsed + _frameLead : Duration.zero;
    return true;
  }

  void stop() {
    _stopped = true;
    if (identical(_stepGlides[position], this)) _stepGlides[position] = null;
  }

  /// Asks for the next frame from inside a frame callback.
  void _schedule() => SchedulerBinding.instance.scheduleFrameCallback(
    _frame,
    rescheduling: true,
  );

  void _frame(Duration timestamp) {
    if (_stopped) return;
    final view = position.context.notificationContext;
    // The page left, or something else (a drag) is moving the list.
    if (view == null || !view.mounted || position.isScrollingNotifier.value) {
      stop();
      return;
    }
    final base = _base ??= timestamp;
    final elapsed = timestamp - base;
    _lastElapsed = elapsed;
    _ticked = true;
    final micros = (elapsed + _frameLead - _stretchStart).inMicroseconds;
    final t = (micros / desktopWheelGlide.inMicroseconds).clamp(0.0, 1.0);
    final span = _goal - _stretchFrom;
    final value =
        _stretchFrom + span * desktopGlideStretchValue(t, _startSpeed);
    _speed = span * desktopGlideStretchSpeed(t, _startSpeed) / _glideSeconds;
    final step = value - _applied;
    _applied = value;
    if (step != 0) position.pointerScroll(step);
    if (t >= 1) {
      stop();
      return;
    }
    _schedule();
  }
}

/// Scroll controller for Windows pages whose mouse wheel should glide even
/// outside a [DesktopWheelGlideScope] (the app has one at the window root,
/// so this mainly keeps older call sites and tests working). Only wheel
/// notches change; dragging, the scrollbar and the keyboard behave as
/// before.
class DesktopSmoothScrollController extends ScrollController {
  DesktopSmoothScrollController({
    super.initialScrollOffset,
    super.keepScrollOffset,
    super.debugLabel,
  });

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _SmoothWheelPosition(
    physics: physics,
    context: context,
    initialPixels: initialScrollOffset,
    keepScrollOffset: keepScrollOffset,
    oldPosition: oldPosition,
    debugLabel: debugLabel,
  );
}

/// Scroll position that turns wheel notches into glides on Windows.
class _SmoothWheelPosition extends ScrollPositionWithSingleContext {
  _SmoothWheelPosition({
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  @override
  void pointerScroll(double delta) {
    // Off Windows (never expected here) keep Flutter's own behaviour.
    if (delta == 0 || defaultTargetPlatform != TargetPlatform.windows) {
      super.pointerScroll(delta);
      return;
    }
    final view = context.notificationContext;
    final reduceMotion =
        view != null && (MediaQuery.maybeDisableAnimationsOf(view) ?? false);
    desktopSmoothScrollBy(this, delta, reduceMotion: reduceMotion);
  }

  /// Flutter's own one-step wheel scroll, for touchpad steps and reduced
  /// motion when the window-wide glide decided not to animate.
  void plainPointerScroll(double delta) => super.pointerScroll(delta);
}

/// Builds a scroll view with a [DesktopSmoothScrollController] on Windows and
/// no controller elsewhere, for panes that do not own a controller.
class DesktopSmoothScroll extends StatefulWidget {
  const DesktopSmoothScroll({super.key, required this.builder});

  /// Builds the scroll view; the controller is null off Windows.
  final Widget Function(BuildContext context, ScrollController? controller)
  builder;

  @override
  State<DesktopSmoothScroll> createState() => _DesktopSmoothScrollState();
}

class _DesktopSmoothScrollState extends State<DesktopSmoothScroll> {
  ScrollController? _controller;

  @override
  void initState() {
    super.initState();
    if (defaultTargetPlatform == TargetPlatform.windows) {
      _controller = DesktopSmoothScrollController();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _controller);
}

/// Window-wide smooth mouse wheel (Windows). Placed once around the whole
/// app, it makes every scroll view below glide on wheel notches: lists,
/// grids, CustomScrollView, PageView, horizontal rows (Shift+wheel) and
/// both parts of a NestedScrollView, whatever controller or scroll
/// behaviour they use. Nothing changes for drags, the keyboard, the
/// scrollbar, touchpads (passed straight through) or reduced motion (plain
/// jump, as before). With [enabled] off the child is left completely alone.
///
/// How: this widget sees each wheel event before any scroll view does. For
/// every scroll view under the pointer it swaps in, for that one event only,
/// a handler that makes exactly the same "do I take this event?" choice as
/// Flutter's own one, so the innermost scroll view that can move still wins
/// and widgets with their own wheel handling (player volume, reader pages)
/// keep working. The chosen scroll view then glides instead of jumping.
class DesktopWheelGlideScope extends SingleChildRenderObjectWidget {
  const DesktopWheelGlideScope({super.key, super.child, this.enabled = true});

  final bool enabled;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderWheelGlideScope(enabled);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderWheelGlideScope).enabled = enabled;
  }
}

/// Hit entry placed in front of everything under the pointer, so this
/// scope runs first and can see the whole list of hit widgets.
class _FrontEntry extends BoxHitTestEntry {
  _FrontEntry(super.target, super.localPosition, this.result);

  /// The hit list being built; complete by the time the event arrives.
  final HitTestResult result;
}

class _RenderWheelGlideScope extends RenderProxyBox {
  _RenderWheelGlideScope(this.enabled);

  bool enabled;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    // Cheap: one extra entry, read only for wheel events.
    if (enabled && size.contains(position)) {
      result.add(_FrontEntry(this, position, result));
    }
    return super.hitTest(result, position: position);
  }

  @override
  void handleEvent(PointerEvent event, HitTestEntry entry) {
    if (!enabled || entry is! _FrontEntry || event is! PointerScrollEvent) {
      return;
    }
    if (defaultTargetPlatform != TargetPlatform.windows) return;
    _prepareScrollViews(event, entry.result.path.toList(growable: false));
  }
}

/// Finds each scroll view in the hit list [path] (innermost first) and
/// swaps its wheel handler for this one event.
void _prepareScrollViews(PointerScrollEvent event, List<HitTestEntry> path) {
  for (var i = 0; i < path.length; i++) {
    final position = _scrollPositionOf(path[i].target);
    if (position == null) continue;
    final view = position.context.notificationContext;
    if (view == null || !view.mounted) continue;
    // The scroll view's own gesture area sits just above its viewport, and
    // its wheel listener just above that.
    final gestures = view.findRenderObject();
    var k = i + 1;
    while (k < path.length && !identical(path[k].target, gestures)) {
      k++;
    }
    var found = false;
    for (var j = k + 1; j < path.length; j++) {
      final target = path[j].target;
      if (target is RenderPointerListener && target.onPointerSignal != null) {
        _swapForOneEvent(target, position);
        found = true;
        break;
      }
    }
    // Debug builds only: say so when a scroll view's wheel listener was not
    // where Flutter normally puts it (for example after a Flutter upgrade
    // changed Scrollable), because that list then jumps instead of gliding.
    assert(() {
      if (!found) {
        debugPrint(
          'DesktopWheelGlideScope: no wheel listener found for a scroll '
          'view; it will scroll without the glide.',
        );
      }
      return true;
    }());
  }
}

/// The scroll position behind a viewport render object, if [target] is one.
ScrollPosition? _scrollPositionOf(HitTestTarget target) {
  Object? offset;
  if (target is RenderViewportBase) {
    offset = target.offset;
  } else if (target is RenderListWheelViewport) {
    offset = target.offset;
  } else if (target is RenderAbstractViewport) {
    // SingleChildScrollView's viewport is private but has the same getter.
    try {
      offset = (target as dynamic).offset;
    } catch (_) {
      offset = null;
    }
  }
  return offset is ScrollPosition ? offset : null;
}

/// Replaces [listener]'s wheel handler until it has seen this one event.
void _swapForOneEvent(RenderPointerListener listener, ScrollPosition position) {
  final original = listener.onPointerSignal!;
  late final PointerSignalEventListener swapped;
  void restore() {
    if (identical(listener.onPointerSignal, swapped)) {
      listener.onPointerSignal = original;
    }
  }

  swapped = (event) {
    restore();
    if (!_claimWheel(event, position)) original(event);
  };
  listener.onPointerSignal = swapped;
  // Safety net: put the original back even if the event never reached it.
  scheduleMicrotask(restore);
}

/// Makes the same choice as Flutter's scroll view: take the wheel event
/// only if this list can actually move that way. Returns false for events
/// this does not handle (left to the original handler).
bool _claimWheel(PointerSignalEvent event, ScrollPosition position) {
  if (event is! PointerScrollEvent) return false;
  final view = position.context.notificationContext;
  if (view == null || !view.mounted) return false;
  if (!position.hasPixels || !position.hasContentDimensions) return false;
  if (!position.physics.shouldAcceptUserOffset(position)) return true;
  final delta = _wheelDelta(event, position, view);
  final target = (position.pixels + delta).clamp(
    position.minScrollExtent,
    position.maxScrollExtent,
  );
  if (delta == 0 || target == position.pixels) return true;
  GestureBinding.instance.pointerSignalResolver.register(event, (resolved) {
    if (!view.mounted) return;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(view) ?? false;
    final ratio = MediaQuery.maybeDevicePixelRatioOf(view) ?? 1;
    if (!reduceMotion &&
        desktopWheelIsNotch(resolved as PointerScrollEvent, ratio)) {
      desktopSmoothScrollBy(position, delta);
    } else if (position is _SmoothWheelPosition) {
      // Touchpad step or reduced motion: Flutter's plain one-step scroll.
      position.plainPointerScroll(delta);
    } else {
      position.pointerScroll(delta);
    }
    // Stops the parent page from also scrolling, as Flutter does.
    (resolved as PointerScrollEvent).respond(allowPlatformDefault: false);
  });
  return true;
}

/// The wheel movement along [position]'s axis, with Shift turning a
/// vertical wheel sideways for a mouse, exactly as Flutter computes it.
double _wheelDelta(
  PointerScrollEvent event,
  ScrollPosition position,
  BuildContext view,
) {
  final pressed = HardwareKeyboard.instance.logicalKeysPressed;
  final modifiers = ScrollConfiguration.of(view).pointerAxisModifiers;
  final flip =
      event.kind == PointerDeviceKind.mouse && pressed.any(modifiers.contains);
  final axis = flip ? flipAxis(position.axis) : position.axis;
  final delta = axis == Axis.horizontal
      ? event.scrollDelta.dx
      : event.scrollDelta.dy;
  return axisDirectionIsReversed(position.axisDirection) ? -delta : delta;
}
