import 'dart:async';

import 'package:flutter/widgets.dart';

/// Windows: loads pictures the user has not reached yet into the normal image
/// cache, one at a time and only while nothing else is going on, so they are
/// already decoded when they scroll into view.
///
/// It keeps no pictures itself: the image cache holds them under its usual
/// limit and drops the oldest ones first. To leave room for what is on
/// screen it stops for good once the cache is [maxFill] full.
class DesktopPictureWarmer {
  DesktopPictureWarmer({required this.ready, this.mayRun});

  /// Whether a picture may be loaded now (the page is still).
  final bool Function() ready;

  /// Whether warming may work at all (page in front, window visible, online).
  /// While it says no nothing is retried; [resume] starts again. Null: yes.
  final bool Function()? mayRun;

  /// Pause between two pictures.
  static const gap = Duration(milliseconds: 60);

  /// Retry wait while [ready] says no.
  static const retry = Duration(milliseconds: 500);

  /// A picture that takes longer than this no longer holds up the next one.
  static const timeout = Duration(seconds: 8);

  /// Share of the image cache after which warming stops for good.
  static const maxFill = .6;

  /// Told about every picture that is about to be loaded.
  @visibleForTesting
  static void Function(ImageProvider picture)? debugOnLoad;

  final List<ImageProvider> _queue = [];

  /// The pictures put in front by the last [loadFirst], still waiting.
  final Set<ImageProvider> _urgent = {};
  Timer? _timer;
  ImageStream? _stream;
  ImageStreamListener? _listener;
  bool _disposed = false, _full = false;

  /// Pictures still waiting to be loaded.
  int get waiting => _queue.length;

  /// True once the image cache was full enough and warming stopped for good.
  bool get stoppedForGood => _full;

  /// Replaces what is waiting with [first] and then [pictures], in this order.
  void load(
    Iterable<ImageProvider> pictures, {
    Iterable<ImageProvider> first = const [],
  }) {
    if (_disposed || _full) return;
    _queue
      ..clear()
      ..addAll(pictures);
    _urgent.clear();
    loadFirst(first);
  }

  /// Puts [pictures] in front of everything that is waiting. They replace the
  /// ones put there before, so a banner that keeps changing while nothing may
  /// load never piles up pictures nobody needs any more.
  void loadFirst(Iterable<ImageProvider> pictures) {
    if (_disposed || _full) return;
    _queue.removeWhere(_urgent.contains);
    _urgent
      ..clear()
      ..addAll(pictures);
    _queue
      ..removeWhere(_urgent.contains)
      ..insertAll(0, _urgent);
    _wake();
  }

  /// Carries on after [mayRun] said no.
  void resume() {
    if (!_disposed) _wake();
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _queue.clear();
    _urgent.clear();
    _stopListening();
  }

  void _wake() {
    if (_timer != null || _stream != null || _queue.isEmpty) return;
    _timer = Timer(gap, _next);
  }

  void _next() {
    _timer = null;
    if (_disposed) return;
    // Already in memory (or loading): nothing to do for those.
    while (_queue.isNotEmpty && _held(_queue.first)) {
      _urgent.remove(_queue.removeAt(0));
    }
    if (_queue.isEmpty) return;
    final cache = PaintingBinding.instance.imageCache;
    if (cache.currentSizeBytes > cache.maximumSizeBytes * maxFill) {
      _full = true;
      _queue.clear();
      _urgent.clear();
      return;
    }
    // Covered, hidden or offline: resume() starts again.
    if (!(mayRun?.call() ?? true)) return;
    if (!ready()) {
      // A scroll pauses warming for a moment.
      _timer = Timer(retry, _next);
      return;
    }
    final picture = _queue.removeAt(0);
    _urgent.remove(picture);
    debugOnLoad?.call(picture);
    final stream = picture.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener((info, _) {
      info.dispose();
      _loaded();
    }, onError: (_, _) => _loaded());
    _stream = stream;
    _listener = listener;
    _timer = Timer(timeout, _loaded);
    stream.addListener(listener);
  }

  /// The picture arrived, failed or took too long: the next one, if any.
  void _loaded() {
    _timer?.cancel();
    _timer = null;
    _stopListening();
    if (!_disposed) _wake();
  }

  void _stopListening() {
    final stream = _stream, listener = _listener;
    _stream = null;
    _listener = null;
    if (stream != null && listener != null) stream.removeListener(listener);
  }

  /// True when [image] is already in the image cache. Pictures whose cache
  /// key is not known at once simply count as not held.
  bool _held(ImageProvider image) {
    Object? key;
    image
        .obtainKey(ImageConfiguration.empty)
        .then<void>((value) => key = value, onError: (Object _) {});
    final found = key;
    return found != null &&
        PaintingBinding.instance.imageCache.statusForKey(found).tracked;
  }
}
