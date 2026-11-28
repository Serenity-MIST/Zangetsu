import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/desktop/desktop_native.dart';
import '../../core/desktop/desktop_prefs.dart';
import '../../core/desktop/desktop_shortcuts.dart';
import '../../core/desktop/desktop_window.dart';

/// Why a Windows profile relock was asked for (acct-11).
enum ProfileRelockReason {
  /// "Lock profile now": Ctrl+L (app.lockProfile) or the profile page button.
  manual,

  /// No keyboard or mouse input for DesktopPrefs.autoLockIdleMinutes.
  idle,

  /// Windows itself was locked (Win+L) and "Lock when Windows locks" is on.
  windowsLocked,
}

/// Watches for the Windows triggers that lock the active profile again
/// (acct-11 Option B): the app.lockProfile shortcut, idle time, and the
/// Windows session locking. It only decides *when*; the launch gate does the
/// locking (forget the unlock, show the picker, ask the PIN).
///
/// It registers its own HardwareKeyboard handler and global pointer route, so
/// the shell needs no changes. Everything is a no-op off Windows.
class DesktopProfileRelock {
  DesktopProfileRelock({
    required this.onLockRequested,
    DateTime Function()? clock,
    Future<bool> Function()? isWatching,
    Stream<bool>? sessionLocked,
    int Function()? idleMinutes,
    bool Function()? lockWhenWindowsLocks,
  }) : _clock = clock ?? DateTime.now,
       _isWatching = isWatching ?? _defaultIsWatching,
       _sessionLocked = sessionLocked,
       _idleMinutes = idleMinutes ?? (() => DesktopPrefs.autoLockIdleMinutes),
       _lockWhenWindowsLocks =
           lockWhenWindowsLocks ?? (() => DesktopPrefs.lockWhenWindowsLocks);

  /// Called when the profile should lock now.
  final Future<void> Function(ProfileRelockReason reason) onLockRequested;

  final DateTime Function() _clock;
  final Future<bool> Function() _isWatching;
  final Stream<bool>? _sessionLocked;
  final int Function() _idleMinutes;
  final bool Function() _lockWhenWindowsLocks;

  /// How often the idle time is checked. Coarse on purpose: the shortest
  /// auto-lock setting is 5 minutes.
  static const checkInterval = Duration(seconds: 15);

  /// The running instance, so a button elsewhere (profile page) can ask for
  /// "Lock profile now" without reaching into the gate.
  static DesktopProfileRelock? _current;

  late DateTime _lastInput = _clock();
  Timer? _timer;
  StreamSubscription<bool>? _sessionSub;
  bool _started = false;
  bool _checking = false;

  /// Asks the running gate to lock the active profile now. Returns false when
  /// nothing is listening (off Windows, or before the shell is up).
  static bool lockNow() {
    final current = _current;
    if (current == null) return false;
    unawaited(current.onLockRequested(ProfileRelockReason.manual));
    return true;
  }

  /// Starts watching. Does nothing off Windows (UI gate, so phone tests on a
  /// Windows host are unaffected).
  void start() {
    if (_started || defaultTargetPlatform != TargetPlatform.windows) return;
    _started = true;
    _current = this;
    _lastInput = _clock();
    HardwareKeyboard.instance.addHandler(_onKey);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    _timer = Timer.periodic(checkInterval, (_) => unawaited(checkIdle()));
    _sessionSub = (_sessionLocked ?? DesktopNative.sessionLocked).listen(
      onSessionLockChanged,
    );
  }

  /// Stops watching and removes every handler.
  void dispose() {
    if (!_started) return;
    _started = false;
    if (identical(_current, this)) _current = null;
    HardwareKeyboard.instance.removeHandler(_onKey);
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    _timer?.cancel();
    _sessionSub?.cancel();
  }

  /// Any key or pointer activity resets the idle clock.
  @visibleForTesting
  void recordInput() => _lastInput = _clock();

  bool _onKey(KeyEvent event) {
    recordInput();
    if (event is KeyDownEvent &&
        DesktopShortcuts.matches('app.lockProfile', event)) {
      unawaited(onLockRequested(ProfileRelockReason.manual));
      return true;
    }
    return false;
  }

  void _onPointer(PointerEvent event) => recordInput();

  /// True once the idle time reaches the auto-lock setting (0 = off).
  @visibleForTesting
  bool idleExpired() {
    final minutes = _idleMinutes();
    if (minutes <= 0) return false;
    return _clock().difference(_lastInput) >= Duration(minutes: minutes);
  }

  /// Periodic idle check. Watching something (the player keeps the screen
  /// awake) counts as activity, so a film never locks half way through.
  @visibleForTesting
  Future<void> checkIdle() async {
    if (_checking || !idleExpired()) return;
    _checking = true;
    try {
      if (await _isWatching()) {
        recordInput();
        return;
      }
      // Restart the clock so a dismissed lock is not asked again at once.
      recordInput();
      await onLockRequested(ProfileRelockReason.idle);
    } finally {
      _checking = false;
    }
  }

  /// Windows lock / unlock events from DesktopNative.sessionLocked.
  @visibleForTesting
  void onSessionLockChanged(bool locked) {
    if (!locked) {
      // Coming back from the lock screen is activity too.
      recordInput();
      return;
    }
    if (_lockWhenWindowsLocks()) {
      unawaited(onLockRequested(ProfileRelockReason.windowsLocked));
    }
  }

  /// Playback keeps a wake lock (player_screen.dart) and the mini player is
  /// only open while watching; either means "someone is watching".
  static Future<bool> _defaultIsWatching() async {
    if (DesktopWindow.miniPlayer.value) return true;
    try {
      return await WakelockPlus.enabled;
    } catch (_) {
      return false;
    }
  }
}
