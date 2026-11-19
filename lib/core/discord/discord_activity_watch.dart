import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Watches whether the person is actually at the Windows app, so Discord
/// presence can stop saying "Playing Zangetsu" all day (track-12, Option A).
///
/// [idle] turns true after [idleAfter] without mouse or keyboard input;
/// [minimised] is true while the window is minimised or hidden (tray).
/// [onChanged] fires only when either flips, so the caller re-sends presence
/// once per change, never per mouse move.
class DiscordActivityWatch {
  DiscordActivityWatch({
    required this.onChanged,
    this.idleAfter = const Duration(minutes: 5),
    this.checkEvery = const Duration(seconds: 30),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _lastInput = _now();
  }

  /// Called when [idle] or [minimised] changes.
  final VoidCallback onChanged;

  /// How long without input counts as away.
  final Duration idleAfter;

  /// How often the idle time is checked (no timer per input event).
  final Duration checkEvery;

  final DateTime Function() _now;
  late DateTime _lastInput;
  bool _idle = false;
  bool _minimised = false;
  bool _installed = false;
  Timer? _timer;
  AppLifecycleListener? _lifecycle;

  /// No input for [idleAfter].
  bool get idle => _idle;

  /// Window minimised or hidden to the tray.
  bool get minimised => _minimised;

  /// Hooks pointer, keyboard and window-state events. Idempotent.
  void install() {
    if (_installed) return;
    _installed = true;
    try {
      // Global route: sees every pointer event without joining hit tests.
      GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
      HardwareKeyboard.instance.addHandler(_onKey);
      _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
    } catch (_) {
      // No binding (pure unit tests): input simply isn't watched.
    }
    _timer = Timer.periodic(checkEvery, (_) => tick());
  }

  /// Removes every hook installed by [install].
  void dispose() {
    if (!_installed) return;
    _installed = false;
    _timer?.cancel();
    _timer = null;
    try {
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
      HardwareKeyboard.instance.removeHandler(_onKey);
    } catch (_) {}
    _lifecycle?.dispose();
    _lifecycle = null;
  }

  void _onPointer(PointerEvent event) => noteInput();

  bool _onKey(KeyEvent event) {
    noteInput();
    return false; // never consume keys
  }

  void _onLifecycle(AppLifecycleState state) {
    // Windows reports a minimised (or tray-hidden) window as hidden; paused
    // and detached are treated the same. Inactive is just focus loss to
    // another window and does not count.
    final hidden =
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached;
    // Getting focus back is activity too: it restores the presence at once.
    if (state == AppLifecycleState.resumed) noteInput();
    setMinimised(hidden);
  }

  /// Records mouse/keyboard activity; clears [idle] when it was set.
  void noteInput() {
    _lastInput = _now();
    if (_idle) {
      _idle = false;
      onChanged();
    }
  }

  /// Sets [minimised]; [onChanged] fires only on a real change.
  void setMinimised(bool value) {
    if (_minimised == value) return;
    _minimised = value;
    onChanged();
  }

  /// Re-evaluates [idle] (run by the periodic timer; public for tests).
  void tick() {
    if (_idle) return;
    if (_now().difference(_lastInput) >= idleAfter) {
      _idle = true;
      onChanged();
    }
  }
}
