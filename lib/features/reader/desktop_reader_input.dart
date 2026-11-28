import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../core/desktop/desktop_focus_repair.dart';
import '../../core/desktop/desktop_shortcut_catalog.dart';
import '../../core/desktop/desktop_shortcuts.dart';
import '../../core/desktop/desktop_window.dart';
import '../settings/keyboard_shortcuts_screen.dart';
import 'desktop_page_scroller.dart' show kDesktopArrowScrollStep;

/// How long the mouse may rest over the page before its cursor is hidden
/// (reader-13). Any movement brings it straight back.
const Duration kDesktopReaderCursorHideDelay = Duration(milliseconds: 2500);

/// Desktop reading input and independent, transient edge controls.
/// Direction is supplied on every build so preference changes apply immediately.
///
/// Besides paging and scrolling it handles (Windows reader-3/4/7/13):
/// - the reader.* keys from [DesktopShortcuts] (chapters, chapter list,
///   settings, auto-scroll, full screen, bars, back, '?' help, Ctrl zoom);
/// - mouse side buttons (back/forward turn pages) and middle click (bars);
/// - left clicks on the page, handed to [onPageClick];
/// - hiding the cursor after [kDesktopReaderCursorHideDelay] without movement.
///
/// Every callback is optional: a key whose callback is missing is left alone,
/// except bars, full screen, back and help, which have sensible defaults.
class DesktopReaderInput extends StatefulWidget {
  const DesktopReaderInput({
    super.key,
    required this.direction,
    required this.onVerticalScroll,
    required this.onPageStep,
    required this.builder,
    this.onVerticalKeyScroll,
    this.onNextChapter,
    this.onPreviousChapter,
    this.onChapterList,
    this.onSettings,
    this.onAutoScroll,
    this.onToggleBars,
    this.onToggleFullscreen,
    this.onBack,
    this.onShowHelp,
    this.onZoomBy,
    this.onZoomReset,
    this.onPageClick,
    this.deferClicks = false,
  });

  final String direction;

  /// Wheel scrolling in vertical reading; applied straight away.
  final ValueChanged<double> onVerticalScroll;
  final ValueChanged<bool> onPageStep;
  final Widget Function(bool topVisible, bool bottomVisible) builder;

  /// Keyboard and mouse-button scrolling in vertical reading (arrows a short
  /// step, PageUp/PageDown a screenful). Readers pass an animated scroll
  /// here (see desktopAnimatedScrollBy); falls back to [onVerticalScroll].
  final ValueChanged<double>? onVerticalKeyScroll;

  /// reader.nextChapter / reader.previousChapter (N / P, ] / [).
  final VoidCallback? onNextChapter;
  final VoidCallback? onPreviousChapter;

  /// reader.chapterList (C).
  final VoidCallback? onChapterList;

  /// reader.settings (S).
  final VoidCallback? onSettings;

  /// reader.autoScroll (A): start or stop auto-scroll.
  final VoidCallback? onAutoScroll;

  /// reader.toggleBars (M) and middle click. Defaults to pinning the edge
  /// bars open (see [DesktopReaderInputState.toggleBars]).
  final VoidCallback? onToggleBars;

  /// reader.fullscreen (F / F11). Defaults to toggling the window.
  final VoidCallback? onToggleFullscreen;

  /// reader.back (Backspace). Defaults to closing the reader route.
  final VoidCallback? onBack;

  /// reader.help ('?'). Defaults to the shared keyboard shortcuts overlay.
  final VoidCallback? onShowHelp;

  /// reader.zoomIn / reader.zoomOut (Ctrl+= / Ctrl+-): [factor] above 1
  /// zooms in. [focal] is the last mouse position over the reader, if any.
  final void Function(double factor, Offset? focal)? onZoomBy;

  /// reader.zoomReset (Ctrl+0).
  final VoidCallback? onZoomReset;

  /// A plain left click on the page (not a drag, not on a button), with its
  /// position inside the reader and the reader's size (reader-7).
  final void Function(Offset local, Size size)? onPageClick;

  /// Waits a double-click interval before reporting a click, and drops it if
  /// a second click follows — so double-clicking a word to select it in a
  /// novel does not also turn the page.
  final bool deferClicks;

  /// How many readers are on screen. The app shell can read it to leave the
  /// mouse Back button to the reader, which uses it to turn pages.
  static int get mountedCount => _mountedCount;
  static int _mountedCount = 0;

  /// Zoom step used by Ctrl+= / Ctrl+-.
  static const double zoomStep = 1.25;

  @override
  State<DesktopReaderInput> createState() => DesktopReaderInputState();
}

/// Keeps mouse hover changes local and lets child scrollables claim wheel input.
class DesktopReaderInputState extends State<DesktopReaderInput> {
  Timer? _hide;
  bool _top = false;
  bool _bottom = false;
  Duration? _lastWheel;
  double _wheelDelta = 0;

  /// Bars held open by M, a middle click or a click in the middle zone.
  bool _pinned = false;

  /// True once the mouse has rested long enough for its cursor to hide.
  bool _cursorHidden = false;
  Timer? _cursorTimer;

  /// Last mouse position over the reader (local), for zoom focal points.
  Offset? _lastMouse;

  /// The primary-button press that may become a page click.
  Offset? _downAt;
  Duration? _downTime;
  bool _downOnControl = false;

  /// A click waiting out the double-click interval ([DesktopReaderInput.deferClicks]).
  Timer? _clickTimer;

  /// Set when a second press arrives inside the double-click interval; the
  /// release that ends that double click is not a page click either.
  bool _swallowNextUp = false;

  /// Runs for the double-click interval after each mouse primary release;
  /// a press while it is active continues a double or triple click.
  Timer? _clickRun;

  /// Whether the edge bars are pinned open.
  bool get barsPinned => _pinned;

  @override
  void initState() {
    super.initState();
    DesktopReaderInput._mountedCount++;
    // Idempotent: makes sure the reader.* ids exist even where the app's
    // startup (DesktopPrefs.init) has not run, e.g. widget tests.
    registerDefaultDesktopShortcuts();
  }

  @override
  void didUpdateWidget(DesktopReaderInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.direction != oldWidget.direction) {
      _wheelDelta = 0;
      _lastWheel = null;
    }
  }

  @override
  void dispose() {
    DesktopReaderInput._mountedCount--;
    _hide?.cancel();
    _cursorTimer?.cancel();
    _clickTimer?.cancel();
    _clickRun?.cancel();
    super.dispose();
  }

  /// Pins or unpins both edge bars (M, middle click, middle click zone).
  void toggleBars() {
    setState(() => _pinned = !_pinned);
  }

  /// Only rebuilds when an edge changes, rather than on every mouse movement.
  void _show(bool top, bool bottom) {
    if (_top == top && _bottom == bottom) return;
    setState(() {
      _top = top;
      _bottom = bottom;
    });
  }

  /// Gives the pointer a short grace period while leaving the floating controls.
  void _leaveEdges() {
    _hide?.cancel();
    _hide = Timer(const Duration(milliseconds: 600), () {
      if (mounted) _show(false, false);
    });
  }

  /// Mouse activity: show the cursor again and restart the hide countdown.
  void _wakeCursor() {
    _cursorTimer?.cancel();
    if (_cursorHidden) setState(() => _cursorHidden = false);
    _cursorTimer = Timer(kDesktopReaderCursorHideDelay, () {
      if (!mounted) return;
      // Leave the cursor alone while a panel or dialog covers the reader.
      if (ModalRoute.of(context)?.isCurrent == false) return;
      setState(() => _cursorHidden = true);
    });
  }

  /// Mouse left the reader: the cursor belongs to whatever it is over now.
  void _cursorLeft() {
    _cursorTimer?.cancel();
    if (_cursorHidden) setState(() => _cursorHidden = false);
  }

  void _toggleBarsAction() =>
      widget.onToggleBars != null ? widget.onToggleBars!() : toggleBars();

  void _fullscreenAction() {
    if (widget.onToggleFullscreen != null) {
      widget.onToggleFullscreen!();
      return;
    }
    // Widget tests and older runners have no window channel.
    DesktopWindow.toggleFullscreen().catchError((Object _) {});
  }

  void _backAction() {
    if (widget.onBack != null) {
      widget.onBack!();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  void _helpAction() {
    if (widget.onShowHelp != null) {
      widget.onShowHelp!();
    } else {
      showKeyboardShortcutsHelp(context, scope: DesktopShortcutScope.reader);
    }
  }

  /// A screenful step for PageUp/PageDown and the mouse side buttons.
  double get _screenful =>
      0.85 * (context.size?.height ?? MediaQuery.sizeOf(context).height);

  void _keyScroll(double delta) =>
      (widget.onVerticalKeyScroll ?? widget.onVerticalScroll)(delta);

  /// Single-press actions from the reader.* shortcut ids, in priority order.
  /// A null callback leaves the key free for anything else that wants it.
  List<(String, VoidCallback?)> get _actions => [
    ('reader.nextChapter', widget.onNextChapter),
    ('reader.previousChapter', widget.onPreviousChapter),
    ('reader.chapterList', widget.onChapterList),
    ('reader.settings', widget.onSettings),
    ('reader.autoScroll', widget.onAutoScroll),
    ('reader.fullscreen', _fullscreenAction),
    ('reader.toggleBars', _toggleBarsAction),
    ('reader.back', _backAction),
    ('reader.help', _helpAction),
  ];

  /// Uses the rendered direction, including chapter and per-series overrides.
  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (ModalRoute.of(context)?.isCurrent == false) {
      return KeyEventResult.ignored;
    }
    // Zoom keys carry Ctrl, so they are matched before the modifier guard
    // below; every other reader key is a plain key.
    if (widget.onZoomBy != null) {
      if (DesktopShortcuts.matches('reader.zoomIn', event)) {
        widget.onZoomBy!(DesktopReaderInput.zoomStep, _lastMouse);
        return KeyEventResult.handled;
      }
      if (DesktopShortcuts.matches('reader.zoomOut', event)) {
        widget.onZoomBy!(1 / DesktopReaderInput.zoomStep, _lastMouse);
        return KeyEventResult.handled;
      }
    }
    if (widget.onZoomReset != null &&
        DesktopShortcuts.matches('reader.zoomReset', event)) {
      widget.onZoomReset!();
      return KeyEventResult.handled;
    }
    if (HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    // One-shot actions ignore auto-repeat, so holding N cannot skip through
    // several chapters or flicker the bars.
    for (final (id, action) in _actions) {
      if (action == null || !DesktopShortcuts.matches(id, event)) continue;
      if (event is KeyDownEvent) action();
      return KeyEventResult.handled;
    }
    final key = event.logicalKey;
    if (widget.direction == 'vertical') {
      // reader-3: arrows move a few lines, PageUp/PageDown a screenful.
      if (key == LogicalKeyboardKey.arrowDown) {
        _keyScroll(kDesktopArrowScrollStep);
      } else if (key == LogicalKeyboardKey.arrowUp) {
        _keyScroll(-kDesktopArrowScrollStep);
      } else if (key == LogicalKeyboardKey.pageDown) {
        _keyScroll(_screenful);
      } else if (key == LogicalKeyboardKey.pageUp) {
        _keyScroll(-_screenful);
      } else {
        return KeyEventResult.ignored;
      }
    } else {
      if (key == LogicalKeyboardKey.pageDown ||
          key == LogicalKeyboardKey.pageUp) {
        widget.onPageStep(key == LogicalKeyboardKey.pageDown);
      } else if (key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.arrowRight) {
        widget.onPageStep(
          (key == LogicalKeyboardKey.arrowRight) == (widget.direction != 'rtl'),
        );
      } else {
        return KeyEventResult.ignored;
      }
    }
    return KeyEventResult.handled;
  }

  /// True when the press landed on something clickable: an InkWell-style
  /// control shows the hand cursor, and Material buttons (whose cursor stays
  /// the arrow on Windows) mark themselves as buttons for accessibility.
  /// The page itself is neither.
  bool _hitsControl(PointerDownEvent event) {
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, event.position, event.viewId);
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderMouseRegion &&
          target.cursor == SystemMouseCursors.click) {
        return true;
      }
      if (target is RenderSemanticsAnnotations &&
          (target.properties.button ?? false)) {
        return true;
      }
    }
    return false;
  }

  /// Mouse buttons: side buttons turn pages, middle click shows the bars,
  /// and a left press is remembered as a possible page click (reader-7).
  void _pointerDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse) return;
    if (ModalRoute.of(context)?.isCurrent == false) return;
    final buttons = event.buttons;
    if (buttons & kBackMouseButton != 0) {
      _sideButton(forward: false);
      return;
    }
    if (buttons & kForwardMouseButton != 0) {
      _sideButton(forward: true);
      return;
    }
    if (buttons & kMiddleMouseButton != 0) {
      _toggleBarsAction();
      return;
    }
    if (buttons & kPrimaryMouseButton == 0) return;
    // A press inside the double-click interval after the previous release:
    // it is a double or triple click (word / paragraph selection), so no
    // click of the run turns the page. Timed from the last release rather
    // than the pending timer, so the third click of a triple click is
    // caught too (its timer was already cancelled by the second).
    if (widget.deferClicks && (_clickRun?.isActive ?? false)) {
      _clickTimer?.cancel();
      _swallowNextUp = true;
    }
    _downAt = event.localPosition;
    _downTime = event.timeStamp;
    _downOnControl = _hitsControl(event);
  }

  /// Back/forward side buttons: a page in paged reading, a screenful in
  /// vertical reading.
  void _sideButton({required bool forward}) {
    if (widget.direction == 'vertical') {
      _keyScroll(forward ? _screenful : -_screenful);
    } else {
      widget.onPageStep(forward);
    }
  }

  /// Turns a short, still press into a page click, unless it was on a
  /// control or on a bar that is showing.
  void _pointerUp(PointerUpEvent event, Size size) {
    // Mouse primary releases start the double-click window ([_pointerDown]).
    if (event.kind == PointerDeviceKind.mouse && _downAt != null) {
      _clickRun?.cancel();
      _clickRun = Timer(kDoubleTapTimeout, () {});
    }
    final down = _downAt;
    final downTime = _downTime;
    _downAt = null;
    _downTime = null;
    if (_swallowNextUp) {
      _swallowNextUp = false;
      return;
    }
    final onClick = widget.onPageClick;
    if (down == null || downTime == null || onClick == null) return;
    if (_downOnControl) return;
    if ((event.localPosition - down).distance > kTouchSlop / 2) return;
    if (event.timeStamp - downTime > const Duration(milliseconds: 500)) return;
    // The edge bands belong to the bars while they are showing.
    if ((_top || _pinned) && down.dy < 96) return;
    if ((_bottom || _pinned) && down.dy > size.height - 96) return;
    if (!widget.deferClicks) {
      onClick(down, size);
      return;
    }
    _clickTimer?.cancel();
    _clickTimer = Timer(kDoubleTapTimeout, () {
      if (mounted) onClick(down, size);
    });
  }

  /// Set for the duration of one wheel event's dispatch in paged reading so
  /// the PageView declines it (see [_PagedWheelGuardPhysics]).
  bool _guardPagedWheel = false;

  /// Scroll behaviour handed to the reader below; cached so hover rebuilds do
  /// not recreate every Scrollable's position.
  ScrollBehavior? _behavior;
  ScrollBehavior? _behaviorParent;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final parent = ScrollConfiguration.of(context);
    if (!identical(parent, _behaviorParent)) {
      _behaviorParent = parent;
      _behavior = parent.copyWith(
        physics: _PagedWheelGuardPhysics(
          () => _guardPagedWheel,
          parent: parent.getScrollPhysics(context),
        ),
      );
    }
  }

  /// Runs before any scrollable below sees the wheel: in paged reading the
  /// PageView must not take it, or a tilt wheel / Shift+wheel drags the page
  /// sideways and it snaps back instead of turning.
  void _beforeChildren(PointerScrollEvent event) {
    _guardPagedWheel = widget.direction != 'vertical';
  }

  /// Vertical wheels advance reading order; horizontal wheels follow page layout.
  void _wheel(PointerSignalEvent signal) {
    // Every scrollable below has registered (or declined) by now.
    _guardPagedWheel = false;
    if (signal is! PointerScrollEvent ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(signal, (event) {
      final wheel = event as PointerScrollEvent;
      if (widget.direction == 'vertical') {
        widget.onVerticalScroll(wheel.scrollDelta.dy);
        return;
      }
      final horizontal =
          wheel.scrollDelta.dx.abs() > wheel.scrollDelta.dy.abs();
      final amount = horizontal ? wheel.scrollDelta.dx : wheel.scrollDelta.dy;
      _wheelDelta += amount;
      if (_wheelDelta.abs() < 32) return;
      if (_lastWheel != null &&
          wheel.timeStamp - _lastWheel! < const Duration(milliseconds: 150)) {
        return;
      }
      var forward = _wheelDelta > 0;
      if (horizontal && widget.direction == 'rtl') forward = !forward;
      _wheelDelta = 0;
      _lastWheel = wheel.timeStamp;
      widget.onPageStep(forward);
    });
  }

  // R1: registered with the focus repair, so a lost focus comes back here.
  @override
  Widget build(BuildContext context) => DesktopRepairFocus(
    autofocus: true,
    onKeyEvent: _key,
    child: LayoutBuilder(
      builder: (context, constraints) => MouseRegion(
        // reader-13: no cursor over the page once the mouse has rested.
        cursor: _cursorHidden ? SystemMouseCursors.none : MouseCursor.defer,
        onHover: (event) {
          _lastMouse = event.localPosition;
          _wakeCursor();
          final top = event.localPosition.dy < 96;
          final bottom = event.localPosition.dy > constraints.maxHeight - 96;
          if (top || bottom) {
            _hide?.cancel();
            _show(top, bottom);
          } else {
            _leaveEdges();
          }
        },
        onExit: (_) {
          _lastMouse = null;
          _cursorLeft();
          _leaveEdges();
        },
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerSignal: _wheel,
          onPointerDown: (event) {
            _wakeCursor();
            _pointerDown(event);
          },
          onPointerMove: (_) => _wakeCursor(),
          onPointerUp: (event) => _pointerUp(event, constraints.biggest),
          child: _FirstLookWheel(
            onWheel: _beforeChildren,
            child: ScrollConfiguration(
              behavior: _behavior!,
              // Selectable text shows its own I-beam cursor, which would win
              // over the hidden one; while hidden it is hidden too. Always
              // present, so hiding never rebuilds the reader's subtree shape.
              child: DefaultSelectionStyle.merge(
                mouseCursor: _cursorHidden ? SystemMouseCursors.none : null,
                child: widget.builder(_top || _pinned, _bottom || _pinned),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Refuses user scrolling for page views (PageMetrics) while [blocking] is
/// true. Only true during a paged-reading wheel event, so touch and trackpad
/// swipes still page normally and other scroll views are unaffected.
class _PagedWheelGuardPhysics extends ScrollPhysics {
  const _PagedWheelGuardPhysics(this.blocking, {super.parent});

  final ValueGetter<bool> blocking;

  @override
  _PagedWheelGuardPhysics applyTo(ScrollPhysics? ancestor) =>
      _PagedWheelGuardPhysics(blocking, parent: buildParent(ancestor));

  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) {
    if (position is PageMetrics && blocking()) return false;
    return super.shouldAcceptUserOffset(position);
  }
}

/// Sees wheel events before its descendants do: it adds itself to the hit
/// test path ahead of its children, whereas a Listener is added after them.
class _FirstLookWheel extends SingleChildRenderObjectWidget {
  const _FirstLookWheel({required this.onWheel, required super.child});

  final ValueChanged<PointerScrollEvent> onWheel;

  @override
  _RenderFirstLookWheel createRenderObject(BuildContext context) =>
      _RenderFirstLookWheel(onWheel);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderFirstLookWheel renderObject,
  ) => renderObject.onWheel = onWheel;
}

class _RenderFirstLookWheel extends RenderProxyBox {
  _RenderFirstLookWheel(this.onWheel);

  ValueChanged<PointerScrollEvent> onWheel;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!size.contains(position)) return false;
    // Added before the children, so handleEvent runs ahead of theirs.
    result.add(BoxHitTestEntry(this, position));
    hitTestChildren(result, position: position);
    return true;
  }

  @override
  void handleEvent(PointerEvent event, BoxHitTestEntry entry) {
    if (event is PointerScrollEvent) onWheel(event);
  }
}
