import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'desktop_background_work.dart';
import 'desktop_close_guard.dart';
import 'desktop_window.dart';
import '../../l10n/l10n.dart';

/// Taskbar button progress states (ITaskbarList3). The order matches the
/// native runner's numeric state.
enum DesktopTaskbarState { none, normal, paused, error, indeterminate }

/// What the player shows in the Windows media overlay (SMTC).
class DesktopMediaInfo {
  const DesktopMediaInfo({
    required this.title,
    this.subtitle,
    this.artworkUrl,
    this.playing = false,
    this.position,
    this.duration,
    this.canNext = false,
    this.canPrevious = false,
  });

  /// Main line, e.g. the show title.
  final String title;

  /// Second line, e.g. 'Episode 4'.
  final String? subtitle;

  /// http(s) cover image; other schemes are ignored by Windows.
  final String? artworkUrl;
  final bool playing;
  final Duration? position;
  final Duration? duration;
  final bool canNext;
  final bool canPrevious;

  /// Channel payload for the runner.
  Map<String, Object?> toMap() => {
    'title': title,
    'subtitle': subtitle,
    'artworkUrl': artworkUrl,
    'playing': playing,
    'positionMs': position?.inMilliseconds,
    'durationMs': duration?.inMilliseconds,
    'canNext': canNext,
    'canPrevious': canPrevious,
  };
}

/// Kinds of media commands from the overlay, thumbnail buttons and media
/// keys. The order matches the native runner.
enum DesktopMediaCommandKind { play, pause, toggle, next, previous, stop, seek }

/// One media command; [position] is set for [DesktopMediaCommandKind.seek].
class DesktopMediaCommand {
  const DesktopMediaCommand(this.kind, {this.position});
  final DesktopMediaCommandKind kind;
  final Duration? position;

  @override
  String toString() => 'DesktopMediaCommand($kind, $position)';
}

/// Files and/or text dropped on the window. [position] is in logical
/// pixels relative to the Flutter view (the same space as global widget
/// coordinates), so it can be hit-tested against a RenderBox.
class DesktopDropEvent {
  const DesktopDropEvent({
    this.paths = const [],
    this.text,
    required this.position,
  });
  final List<String> paths;
  final String? text;
  final Offset position;
}

/// Dart side of the Windows runner's shell integration: launch at sign-in,
/// window placement memory, tray icon, notifications, taskbar progress,
/// thumbnail buttons, the media overlay, session lock events, restart and
/// drag-and-drop. Everything talks to the existing
/// 'com.spyou.zangetsu/window' channel; native events arrive as method
/// calls on that same channel and are handled here.
///
/// Every call is a no-op off Windows and swallows MissingPluginException,
/// so widget tests and other platforms never need a fake.
abstract final class DesktopNative {
  static const _channel = MethodChannel('com.spyou.zangetsu/window');

  static bool _initialized = false;
  static bool _launchedAtSignIn = false;
  static Completer<void> _ready = Completer<void>();

  static final _trayActions = StreamController<String>.broadcast();
  static final _notificationClicks = StreamController<String?>.broadcast();
  static final _mediaCommands =
      StreamController<DesktopMediaCommand>.broadcast();
  static final _sessionLocked = StreamController<bool>.broadcast();
  static final _drops = StreamController<DesktopDropEvent>.broadcast();
  static final ValueNotifier<Offset?> _dragPosition = ValueNotifier<Offset?>(
    null,
  );

  /// Installs the native event handler and syncs the initial window state.
  /// Called by DesktopWindow.initState; safe to call repeatedly.
  static void ensureInitialized() {
    if (_initialized) return;
    _initialized = true;
    if (!Platform.isWindows) {
      _ready.complete();
      return;
    }
    _channel.setMethodCallHandler(_handle);
    unawaited(_bootstrap());
  }

  /// Completes once the initial state (e.g. [launchedAtSignIn]) is known.
  static Future<void> get ready => _ready.future;

  // Sends translatable labels, reads the starting window state and turns
  // the close guard on (from now on the caption X asks Dart first).
  static Future<void> _bootstrap() async {
    try {
      // Tray and taskbar labels in the saved app language (sent once at
      // startup, so a language change shows after a restart).
      final l10n = appL10n;
      await _invoke<void>('setShellLabels', {
        'open': l10n.open,
        'pauseAll': l10n.pauseAllDownloads,
        'quit': l10n.quit,
        'previous': l10n.previous,
        'play': l10n.play,
        'pause': l10n.pause,
        'next': l10n.next,
      });
      final state = await _invoke<Object?>('getWindowState');
      if (state is Map) {
        _launchedAtSignIn = state['launchedAtSignIn'] == true;
        DesktopWindow.fullscreen.value = state['fullscreen'] == true;
        DesktopWindow.maximized.value = state['maximized'] == true;
        DesktopWindow.alwaysOnTop.value = state['alwaysOnTop'] == true;
        DesktopWindow.miniPlayer.value = state['miniPlayer'] == true;
      }
      await _invoke<void>('setCloseGuard', true);
    } on PlatformException {
      // An older runner without these methods keeps its plain behaviour.
    } finally {
      if (!_ready.isCompleted) _ready.complete();
    }
  }

  // Native -> Dart events.
  static Future<Object?> _handle(MethodCall call) async {
    final args = call.arguments;
    switch (call.method) {
      case 'fullscreenChanged':
        DesktopWindow.fullscreen.value = args == true;
      case 'maximizedChanged':
        DesktopWindow.maximized.value = args == true;
      case 'maximizeHover':
        DesktopWindow.maximizeHover.value = args == true;
      case 'miniPlayerChanged':
        DesktopWindow.miniPlayer.value = args == true;
      case 'alwaysOnTopChanged':
        DesktopWindow.alwaysOnTop.value = args == true;
      case 'closeRequested':
        // Answer at once; the guard decides (and may show a dialog) after.
        unawaited(DesktopCloseGuard.handleCloseRequest());
        return true;
      case 'trayAction':
        if (args is! String) return null;
        _trayActions.add(args);
        // Built-in behaviour for the tray menu; listeners can add more.
        if (args == 'pauseAll') unawaited(DesktopBackgroundWork.pauseAll());
        if (args == 'quit') unawaited(DesktopWindow.forceClose());
        return true;
      case 'notificationClicked':
        _notificationClicks.add(args is String ? args : null);
      case 'mediaCommand':
        final command = _parseMediaCommand(args);
        if (command != null) _mediaCommands.add(command);
      case 'sessionLockChanged':
        _sessionLocked.add(args == true);
      case 'dragUpdate':
        if (args is Map) {
          _dragPosition.value = Offset(_number(args['x']), _number(args['y']));
        }
      case 'dragLeave':
        _dragPosition.value = null;
      case 'drop':
        _dragPosition.value = null;
        if (args is Map) {
          _drops.add(
            DesktopDropEvent(
              paths: [
                for (final path in (args['paths'] as List?) ?? const [])
                  if (path is String) path,
              ],
              text: args['text'] is String ? args['text'] as String : null,
              position: Offset(_number(args['x']), _number(args['y'])),
            ),
          );
        }
    }
    return null;
  }

  /// Feeds a native event through the real handler (tests only).
  @visibleForTesting
  static Future<Object?> debugHandleNativeCall(MethodCall call) =>
      _handle(call);

  /// Forgets initialisation so a test can run [ensureInitialized] again.
  @visibleForTesting
  static void debugReset() {
    _initialized = false;
    _launchedAtSignIn = false;
    _ready = Completer<void>();
    _dragPosition.value = null;
  }

  static double _number(Object? value) => value is num ? value.toDouble() : 0;

  static DesktopMediaCommand? _parseMediaCommand(Object? args) {
    if (args is! Map) return null;
    final name = args['kind'];
    final kind = DesktopMediaCommandKind.values
        .where((value) => value.name == name)
        .firstOrNull;
    if (kind == null) return null;
    final ms = args['positionMs'];
    return DesktopMediaCommand(
      kind,
      position: ms is int ? Duration(milliseconds: ms) : null,
    );
  }

  // Invokes a runner method; null off Windows or when the runner lacks it.
  static Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    if (!Platform.isWindows) return null;
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    }
  }

  // Like [_invoke] but also swallows runner errors, for purely cosmetic
  // calls (tray, taskbar, overlay) that must never break the caller.
  static Future<T?> _quiet<T>(String method, [Object? arguments]) async {
    try {
      return await _invoke<T>(method, arguments);
    } on PlatformException {
      return null;
    }
  }

  // ---- Launch at sign-in -------------------------------------------------

  /// Whether Windows starts Zangetsu when the user signs in.
  static Future<bool> isLaunchAtSignInEnabled() async =>
      await _invoke<bool>('isLaunchAtSignInEnabled') ?? false;

  /// Adds or removes the HKCU Run entry (`"<exe>" --autostart`). Throws a
  /// PlatformException when Windows refuses the change.
  static Future<void> setLaunchAtSignIn(bool enabled) =>
      _invoke<void>('setLaunchAtSignIn', enabled);

  /// True when this process was started by the sign-in entry. Known after
  /// [ready] completes; false before that.
  static bool get launchedAtSignIn => _launchedAtSignIn;

  // ---- Window placement ----------------------------------------------------

  /// Whether the window reopens where it was closed (default on).
  static Future<bool> rememberWindowPlacement() async =>
      await _invoke<bool>('getRememberWindowPlacement') ?? true;

  /// Turns placement memory on or off.
  static Future<void> setRememberWindowPlacement(bool enabled) =>
      _invoke<void>('setRememberWindowPlacement', enabled);

  // ---- Tray ------------------------------------------------------------------

  /// Keeps an icon in the notification area (menu: Open, Pause all
  /// downloads, Quit; click restores the window).
  static Future<void> showTray({required String tooltip}) =>
      _quiet<void>('showTray', {'tooltip': tooltip});

  /// Removes the explicit tray icon.
  static Future<void> hideTray() => _quiet<void>('hideTray');

  /// Hides the window; the tray icon stays as the way back.
  static Future<void> hideToTray() => _quiet<void>('hideToTray');

  /// Shows and focuses the window again.
  static Future<void> restoreFromTray() => _quiet<void>('restoreFromTray');

  /// 'open' | 'pauseAll' | 'quit' from the tray icon. Pause all and Quit
  /// are already carried out; listeners may react further.
  static Stream<String> get trayActions => _trayActions.stream;

  // ---- Notifications --------------------------------------------------------

  /// Shows a Windows notification (a balloon, displayed as a toast on
  /// Windows 10/11). [payload] comes back on [notificationClicks].
  static Future<void> showNotification({
    required String title,
    required String body,
    String? payload,
  }) => _quiet<void>('showNotification', {
    'title': title,
    'body': body,
    'payload': payload,
  });

  /// Payloads of clicked notifications; the window is already restored.
  static Stream<String?> get notificationClicks => _notificationClicks.stream;

  // ---- Taskbar ---------------------------------------------------------------

  /// Progress on the taskbar button; [fraction] is 0..1.
  static Future<void> setTaskbarProgress(
    DesktopTaskbarState state, [
    double fraction = 0,
  ]) => _quiet<void>('setTaskbarProgress', {
    'state': state.index,
    'fraction': fraction.clamp(0.0, 1.0),
  });

  /// Previous / Play-Pause / Next buttons under the taskbar thumbnail.
  /// Clicks arrive on [mediaCommands].
  static Future<void> setThumbButtons({
    required bool visible,
    bool playing = false,
    bool canPrevious = true,
    bool canNext = true,
  }) => _quiet<void>('setThumbButtons', {
    'visible': visible,
    'playing': playing,
    'canPrevious': canPrevious,
    'canNext': canNext,
  });

  // ---- Media overlay ---------------------------------------------------------

  /// Shows / refreshes the Windows media overlay and lock-screen controls.
  static Future<void> updateMediaSession(DesktopMediaInfo info) =>
      _quiet<void>('updateMediaSession', info.toMap());

  /// Hides the media overlay.
  static Future<void> clearMediaSession() => _quiet<void>('clearMediaSession');

  /// Commands from the overlay, thumbnail buttons and keyboard media keys.
  static Stream<DesktopMediaCommand> get mediaCommands => _mediaCommands.stream;

  // ---- Session -----------------------------------------------------------------

  /// true when Windows locks (Win+L), false when it unlocks.
  static Stream<bool> get sessionLocked => _sessionLocked.stream;

  /// Quits, then starts a fresh copy of the app (without the original
  /// arguments, so a sign-in link or --autostart is not replayed).
  static Future<void> restartApp() => _invoke<void>('restartApp');

  // ---- Drag and drop -----------------------------------------------------------

  /// Files / links dropped anywhere on the window.
  static Stream<DesktopDropEvent> get drops => _drops.stream;

  /// Pointer position of a drag over the window (logical px), or null.
  static ValueListenable<Offset?> get dragPosition => _dragPosition;

  // ---- Window commands used by DesktopWindow --------------------------------

  /// Raw runner call for DesktopWindow's own commands.
  static Future<T?> invokeWindow<T>(String method, [Object? arguments]) =>
      _invoke<T>(method, arguments);
}
