import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/di/injector.dart';
import '../../core/desktop/desktop_window.dart';
import '../../core/reading/reader_prefs.dart';

/// Shared "reading comfort" side effects for both readers — keep-awake,
/// brightness override, orientation lock, and fullscreen. All four are global OS
/// state, so every knob [applyReaderComfort] can set MUST be undone by
/// [restoreReaderComfort] (call from `dispose`), the same way
/// player_screen.dart resets brightness/wakelock/orientation on the way out
/// of the player — otherwise leaving the reader can leave the phone dimmed,
/// orientation-locked, or awake behind it.
///
/// Nothing in `main.dart` locks orientation at startup, so "restore to
/// default" here means all four orientations, not a single one.
mixin ReaderComfortMixin<T extends StatefulWidget> on State<T> {
  bool? _previousWindowFullscreen;
  Future<void> _windowChanges = Future.value();

  /// Set (synchronously) as soon as the reader queues any change to the
  /// window's full screen state, so dispose knows to restore it even when
  /// the queued native call has not answered yet.
  bool _touchedWindow = false;

  /// The "Reader fullscreen" value last applied on Windows (null before the
  /// first apply), so re-applying comfort only touches the window when that
  /// setting actually changed.
  bool? _appliedFullscreenPref;

  /// Serializes changes and disposal so a late native reply cannot fullscreen
  /// the library after the reader has already closed.
  void _applyWindowFullscreen(bool? enabled) {
    if (enabled != null) _touchedWindow = true;
    _windowChanges = _windowChanges
        .then((_) async {
          _previousWindowFullscreen ??= await DesktopWindow.isFullscreen();
          await DesktopWindow.setFullscreen(
            enabled ?? _previousWindowFullscreen!,
          );
        })
        .catchError((Object _) {});
  }

  /// Windows (reader-4): F / F11 in the reader flips full screen for this
  /// session. Queued behind any pending change, and the window's state from
  /// before the reader opened is remembered so closing the reader puts it
  /// back however often it was toggled.
  void toggleReaderFullscreen() {
    _touchedWindow = true;
    _windowChanges = _windowChanges
        .then((_) async {
          final now = await DesktopWindow.isFullscreen();
          _previousWindowFullscreen ??= now;
          await DesktopWindow.setFullscreen(!now);
        })
        .catchError((Object _) {});
  }

  static const List<DeviceOrientation> _allOrientations =
      DeviceOrientation.values;

  /// Applies the current comfort prefs. Call once from `initState`, and
  /// again whenever a comfort pref changes from a settings sheet so the
  /// change takes effect immediately.
  void applyReaderComfort() {
    final prefs = sl<ReaderPrefs>();

    if (prefs.keepScreenOn) {
      WakelockPlus.enable().ignore();
    } else {
      WakelockPlus.disable().ignore();
    }

    // Desktop brightness belongs to Windows/the monitor; stored phone comfort
    // preferences must not dim a PC or call unsupported mobile plugin methods.
    if (Platform.isWindows) {
      // Only act when the setting itself changed (or on first apply): this
      // also runs when an unrelated comfort pref changes, and must not undo
      // a full screen the user just toggled with F / F11.
      if (_appliedFullscreenPref == prefs.fullscreen) return;
      _appliedFullscreenPref = prefs.fullscreen;
      // On: go full screen. Off: leave the window as the user had it, unless
      // the reader itself changed it this session (the setting was switched
      // off mid-read), in which case put the earlier state back.
      if (prefs.fullscreen) {
        _applyWindowFullscreen(true);
      } else if (_touchedWindow) {
        _applyWindowFullscreen(null);
      }
      return;
    }
    final brightness = prefs.brightness;
    if (brightness >= 0) {
      ScreenBrightness.instance
          .setApplicationScreenBrightness(brightness)
          .catchError((_) {});
    } else {
      ScreenBrightness.instance.resetApplicationScreenBrightness().catchError(
        (_) {},
      );
    }

    SystemChrome.setPreferredOrientations(_orientationsFor(prefs.orientation));

    // Bars off while reading. `immersiveSticky`, not `immersive`: a swipe from
    // an edge brings them back briefly and they hide again on their own, so a
    // reader never has to leave the page to check the time.
    SystemChrome.setEnabledSystemUIMode(
      prefs.fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
  }

  /// Undoes every side effect [applyReaderComfort] can set — call from
  /// `dispose`.
  void restoreReaderComfort() {
    WakelockPlus.disable().ignore();
    if (Platform.isWindows) {
      // Nothing to undo when the reader never touched the window.
      if (_touchedWindow) _applyWindowFullscreen(null);
      return;
    }
    ScreenBrightness.instance.resetApplicationScreenBrightness().catchError(
      (_) {},
    );
    SystemChrome.setPreferredOrientations(_allOrientations);
    // Unconditionally, even when fullscreen was off: the toggle can be flipped
    // from the settings sheet mid-session, so restoring only when the CURRENT
    // pref says so would leave the bars hidden over the rest of the app.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  List<DeviceOrientation> _orientationsFor(String orientation) {
    switch (orientation) {
      case 'portrait':
        return const [DeviceOrientation.portraitUp];
      case 'landscape':
        return const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ];
      default: // 'system' — no lock
        return _allOrientations;
    }
  }
}
