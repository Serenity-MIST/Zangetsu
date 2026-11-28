import 'dart:async';

import 'package:flutter/widgets.dart';

/// Windows: builds the shelves further down Home ahead of time, one small
/// step at a time, while the user is not doing anything. Once finished, a
/// scroll through the whole page builds nothing new.
///
/// It only grows [extent] (the scroll view's build-ahead distance). Each step
/// adds about one shelf, so at most one shelf is built, and at most one
/// shelf's pictures start loading, at a time. It never runs while the page
/// scrolls, and stops completely (no timer left running) while [mayRun] says
/// no; the page then starts it again with [check]. The first step waits
/// [startDelay], so opening the app is not slower.
class DesktopHomeWarmup {
  DesktopHomeWarmup({
    required double initialExtent,
    required this.mayRun,
    required this.position,
    required this.cap,
    this.logosWaiting,
    this.onFinished,
  }) : _initialExtent = initialExtent,
       extent = ValueNotifier<double>(initialExtent);

  /// Wait after the first real shelves appeared before anything is built.
  static const startDelay = Duration(milliseconds: 1500);

  /// How far one step reaches: about one shelf.
  static const step = 350.0;

  /// Pause between two steps.
  static const stepGap = Duration(milliseconds: 120);

  /// How long the page must have been still, and the retry wait while it is
  /// not (or while pictures are still loading).
  static const quiet = Duration(milliseconds: 300);

  /// A step waits while more pictures than this are still loading.
  static const maxPendingImages = 2;

  /// How many [quiet] waits (3 seconds) loading pictures may hold a step
  /// back, so one stuck picture cannot block the warm-up for good.
  static const maxImageWaits = 10;

  /// A step waits while more title logos than this are still being looked up
  /// (title artwork only). They are fetched one after another for the whole
  /// app, so titles the user opens must not queue behind far-away shelves.
  static const maxPendingLogos = 2;

  /// The scroll view's build-ahead distance in pixels.
  final ValueNotifier<double> extent;

  final double _initialExtent;

  /// Whether the warm-up may work at all now. When it says no the warm-up
  /// stops until [check]; a short pause (a scroll) is not its business.
  final bool Function() mayRun;

  /// How many title logos are still being looked up; null counts as none.
  final int Function()? logosWaiting;

  /// The page's scroll position; null before its first layout.
  final ScrollPosition? Function() position;

  /// Furthest [extent] may grow (smaller on PCs with little memory).
  final double Function() cap;

  /// Called whenever the last step has been taken.
  final VoidCallback? onFinished;

  Timer? _timer, _quietTimer;
  int _imageWaits = 0;
  bool _started = false, _finished = false, _disposed = false;

  /// True once [start] was called.
  bool get started => _started;

  /// True once every shelf (or as many as [cap] allows) is built.
  bool get finished => _finished;

  /// True while the last scroll is less than [quiet] ago.
  bool get scrolledRecently => _quietTimer != null;

  /// Starts the one-time wait before the first step.
  void start() {
    if (_started || _disposed) return;
    _started = true;
    _arm(startDelay);
  }

  /// Call when the page's content, size or visibility changed: carries on
  /// when there is (again) something left to build.
  void check() {
    if (!_started || _disposed || _timer != null) return;
    // Known to be complete: nothing to do until the content grows.
    if (_finished && _complete) return;
    _arm(stepGap);
  }

  /// Back to the small start distance, as when Home opened: call when all
  /// shelves are about to change size or content, so that only the ones near
  /// the screen are built in that one frame. [start] then begins again.
  void reset() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = null;
    _imageWaits = 0;
    _started = _finished = false;
    extent.value = _initialExtent;
  }

  /// Call on every scroll of the page (or of a shelf in it).
  void noteScroll() {
    if (_disposed) return;
    _quietTimer?.cancel();
    _quietTimer = Timer(quiet, () => _quietTimer = null);
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _quietTimer?.cancel();
    _timer = _quietTimer = null;
    extent.dispose();
  }

  void _arm(Duration after) {
    _timer?.cancel();
    _timer = Timer(after, _tick);
  }

  /// Every shelf is inside the build-ahead distance, or the cap is reached.
  bool get _complete {
    final p = position();
    if (p == null || !p.hasContentDimensions) return false;
    return extent.value >= p.maxScrollExtent || extent.value >= cap();
  }

  void _tick() {
    _timer = null;
    if (_disposed) return;
    // check() starts again once the page is back.
    if (!mayRun()) return;
    final p = position();
    if (p == null ||
        !p.hasContentDimensions ||
        scrolledRecently ||
        p.isScrollingNotifier.value) {
      return _arm(quiet);
    }
    if (_complete) {
      _finished = true;
      onFinished?.call();
      return;
    }
    // Every lookup gives up after a few seconds, so this always ends.
    if ((logosWaiting?.call() ?? 0) > maxPendingLogos) return _arm(quiet);
    if (PaintingBinding.instance.imageCache.pendingImageCount >
            maxPendingImages &&
        _imageWaits < maxImageWaits) {
      _imageWaits++;
      return _arm(quiet);
    }
    _imageWaits = 0;
    final next = extent.value + step, limit = cap();
    extent.value = next < limit ? next : limit;
    _arm(stepGap);
  }
}
