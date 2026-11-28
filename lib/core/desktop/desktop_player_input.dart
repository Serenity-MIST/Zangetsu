import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import '../../features/settings/keyboard_shortcuts_screen.dart'
    show showKeyboardShortcutsHelp;
import 'desktop_focus_repair.dart';
import 'desktop_media_keys.dart';
import 'desktop_shortcut_catalog.dart';
import 'desktop_shortcuts.dart';
import 'desktop_window.dart';

/// Opens the '?' keyboard-shortcut overlay with the player's keys first.
/// Shared by the '?' key and the keyboard button in the player's bar.
Future<void> showPlayerShortcutsHelp(BuildContext context) =>
    showKeyboardShortcutsHelp(context, scope: DesktopShortcutScope.player);

/// Desktop transport uses the same player actions as the visible controls.
///
/// Keys come from [DesktopShortcuts] (ids `player.*`), so a remap on the
/// Keyboard shortcuts settings page applies here straight away. Optional
/// callbacks that are null leave their keys unbound.
class DesktopPlayerInput extends StatefulWidget {
  const DesktopPlayerInput({
    super.key,
    required this.child,
    required this.onPlayPause,
    required this.onSeek,
    required this.onVolume,
    required this.onMute,
    required this.onBack,
    this.hideCursor = false,
    this.seekSeconds = 10,
    this.onNextEpisode,
    this.onPreviousEpisode,
    this.onSkip,
    this.onSpeedStep,
    this.onToggleSubtitles,
    this.onJumpToFraction,
    this.onFrameStep,
    this.onSubtitleDelayStep,
    this.onMiniPlayer,
    this.onTheatre,
    this.onAlwaysOnTop,
    this.onHelp,
    this.onStop,
    this.wheelVolume = true,
  });
  final Widget child;
  final bool hideCursor;

  /// Uses the user's seek duration for keyboard and forward mouse actions.
  final int seekSeconds;
  final VoidCallback onPlayPause, onMute, onBack;
  final ValueChanged<int> onSeek;
  final ValueChanged<double> onVolume;

  /// N and the media Next key.
  final VoidCallback? onNextEpisode;

  /// P and the media Previous key.
  final VoidCallback? onPreviousEpisode;

  /// S: skip the intro / ending / recap under the playhead.
  final VoidCallback? onSkip;

  /// [ (-1) and ] (+1): one playback-speed step slower / faster.
  final ValueChanged<int>? onSpeedStep;

  /// C: subtitles on / off.
  final VoidCallback? onToggleSubtitles;

  /// 0-9: jump to 0%, 10% ... 90% of the episode (0.0 ... 0.9).
  final ValueChanged<double>? onJumpToFraction;

  /// , (-1) and . (+1): one frame back / forward (only acts while paused).
  final ValueChanged<int>? onFrameStep;

  /// G (-1) and H (+1): subtitle delay one step earlier / later.
  final ValueChanged<int>? onSubtitleDelayStep;

  /// Ctrl+M: mini player.
  final VoidCallback? onMiniPlayer;

  /// T (Windows): theatre mode on / off. Null leaves T unbound.
  final VoidCallback? onTheatre;

  /// Ctrl+T: keep the window on top.
  final VoidCallback? onAlwaysOnTop;

  /// '?': shortcut help. Null opens the shared help overlay.
  final VoidCallback? onHelp;

  /// Media Stop key. Null leaves it unbound.
  final VoidCallback? onStop;

  /// Mouse wheel anywhere over [child] changes the volume. The Windows watch
  /// page turns this off and handles the wheel over the video only (player-13).
  final bool wheelVolume;

  // Plane the Windows embedder puts unmapped virtual keys in
  // (KeyboardKeyEmbedderHandler::windowsPlane).
  static const int _windowsKeyPlane = 0x01600000000;

  /// Binds every `player.*` action to its callback, honouring remaps.
  Map<ShortcutActivator, VoidCallback> _bindings(BuildContext context) {
    // New UI behaviour is gated on the target platform (tests run on a
    // Windows host that pretends to be a phone).
    final windowsUi = defaultTargetPlatform == TargetPlatform.windows;
    final actions = <String, VoidCallback>{
      'player.playPause': onPlayPause,
      'player.seekBack': () => onSeek(-seekSeconds),
      'player.seekForward': () => onSeek(seekSeconds),
      // Shift+arrows stay a fixed one-minute jump.
      'player.seekBackLong': () => onSeek(-60),
      'player.seekForwardLong': () => onSeek(60),
      'player.volumeUp': () => onVolume(5),
      'player.volumeDown': () => onVolume(-5),
      'player.mute': onMute,
      'player.fullscreen': DesktopWindow.toggleFullscreen,
      'player.exit': () async {
        if (!await DesktopWindow.exitFullscreen()) onBack();
      },
      // '?' help is Windows UI only (phone keeps no help overlay).
      if (windowsUi)
        'player.help': onHelp ?? () => showPlayerShortcutsHelp(context),
      'player.nextEpisode': ?onNextEpisode,
      'player.previousEpisode': ?onPreviousEpisode,
      'player.skip': ?onSkip,
      if (onSpeedStep != null) ...{
        'player.speedDown': () => onSpeedStep!(-1),
        'player.speedUp': () => onSpeedStep!(1),
      },
      'player.subtitles': ?onToggleSubtitles,
      if (onFrameStep != null) ...{
        'player.frameBack': () => onFrameStep!(-1),
        'player.frameForward': () => onFrameStep!(1),
      },
      if (onSubtitleDelayStep != null) ...{
        'player.subDelayDown': () => onSubtitleDelayStep!(-1),
        'player.subDelayUp': () => onSubtitleDelayStep!(1),
      },
      // Null-aware entries: an action without a callback stays unbound.
      'player.miniPlayer': ?onMiniPlayer,
      'player.theatre': ?onTheatre,
      'player.alwaysOnTop': ?onAlwaysOnTop,
    };
    final map = DesktopShortcuts.bindings(actions);
    // 0-9 share one id but each digit jumps to its own tenth.
    final jump = onJumpToFraction;
    if (jump != null) {
      for (final a in DesktopShortcuts.activatorsFor('player.jumpPercent')) {
        final digit = a.trigger.keyId - LogicalKeyboardKey.digit0.keyId; // 0..9
        if (digit < 0 || digit > 9) continue;
        map[a] = () => jump(digit / 10);
      }
    }
    // Hardware media keys while the player has focus. Each one claims the
    // press first so the same press arriving again from the Windows media
    // overlay / WM_APPCOMMAND is ignored (and vice versa).
    // A key without a callback stays unbound, so the press is not swallowed
    // and can still reach the Windows media overlay path.
    void media(
      LogicalKeyboardKey key,
      DesktopMediaKeyAction action,
      VoidCallback? run,
    ) {
      if (run == null) return;
      void fire() {
        if (DesktopMediaKeyDedupe.claim(action)) run();
      }

      map[SingleActivator(key)] = fire;
      // The Windows embedder has no logical mapping for the Next / Previous
      // track virtual keys (VK 0xB0 / 0xB1): it sends them in its "windows
      // plane" instead, so bind that id too or the real keys never match.
      final vk = switch (action) {
        DesktopMediaKeyAction.next => 0xB0,
        DesktopMediaKeyAction.previous => 0xB1,
        _ => null,
      };
      if (vk != null) {
        map[SingleActivator(LogicalKeyboardKey(_windowsKeyPlane | vk))] = fire;
      }
    }

    if (windowsUi) {
      media(
        LogicalKeyboardKey.mediaPlayPause,
        DesktopMediaKeyAction.playPause,
        onPlayPause,
      );
      media(
        LogicalKeyboardKey.mediaTrackNext,
        DesktopMediaKeyAction.next,
        onNextEpisode,
      );
      media(
        LogicalKeyboardKey.mediaTrackPrevious,
        DesktopMediaKeyAction.previous,
        onPreviousEpisode,
      );
      media(LogicalKeyboardKey.mediaStop, DesktopMediaKeyAction.stop, onStop);
    }
    return map;
  }

  @override
  State<DesktopPlayerInput> createState() => _DesktopPlayerInputState();
}

/// Owns the player's key node, so focus can be pulled back to it: a click on
/// the video, or [DesktopFocusRepair] after a text field or the Watch
/// Together chat gave focus up. Before this the node was anonymous and
/// nothing could refocus it, so every player key stayed dead.
class _DesktopPlayerInputState extends State<DesktopPlayerInput> {
  // skipTraversal: Tab moves between the controls, never onto this wrapper.
  final FocusNode _node = FocusNode(
    debugLabel: 'desktop-player-keys',
    skipTraversal: true,
  );

  // Bindings from the last build (rebuilt on every remap).
  Map<ShortcutActivator, VoidCallback> _map = const {};

  @override
  void initState() {
    super.initState();
    // Lost focus (null / a bare scope) comes back here while the player is
    // the top route.
    DesktopFocusRepair.register(_node);
  }

  @override
  void dispose() {
    DesktopFocusRepair.unregister(_node);
    _node.dispose();
    super.dispose();
  }

  /// Runs the matching player action, unless the user is typing (Watch
  /// Together chat, a search box in a sheet): then Space, letters, arrows
  /// and Esc belong to the text field.
  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (DesktopWindow.focusInTextField()) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    for (final entry in _map.entries) {
      if (entry.key.accepts(event, keyboard)) {
        entry.value();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  /// A primary click on the video takes the keys back (unless it landed in
  /// a text field, which keeps its own focus).
  void _reclaimFocus() {
    if (DesktopWindow.focusInTextField()) return;
    if (!_node.hasFocus) _node.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    if (!Platform.isWindows) return w.child;
    // Idempotent: makes sure the player ids exist even where the app's
    // startup (DesktopPrefs.init) has not run, e.g. widget tests.
    registerDefaultDesktopShortcuts();
    return ListenableBuilder(
      // Rebuild the key map when the user remaps a player shortcut.
      listenable: DesktopShortcuts.changes,
      builder: (context, inner) {
        _map = w._bindings(context);
        return inner!;
      },
      child: Focus(
        focusNode: _node,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Listener(
          // Null when [wheelVolume] is off, so the wheel scrolls normally.
          onPointerSignal: w.wheelVolume ? (event) {
            // A horizontal touchpad gesture must not lower the volume: only
            // vertical wheel movement represents the desktop volume action.
            if (event is PointerScrollEvent && event.scrollDelta.dy != 0) {
              GestureBinding.instance.pointerSignalResolver.register(
                event,
                (_) => w.onVolume(event.scrollDelta.dy < 0 ? 5 : -5),
              );
            }
          } : null,
          onPointerDown: (event) {
            if (event.kind != PointerDeviceKind.mouse) return;
            // Windows UI: a left click anywhere over the player brings the
            // keys back to it (R1: keys stayed dead after typing in chat).
            if (defaultTargetPlatform == TargetPlatform.windows &&
                event.buttons & kPrimaryMouseButton != 0) {
              _reclaimFocus();
            }
            if (event.buttons & kBackMouseButton != 0) w.onBack();
            if (event.buttons & kForwardMouseButton != 0) {
              w.onSeek(w.seekSeconds);
            }
            if (event.buttons & kMiddleMouseButton != 0) w.onPlayPause();
          },
          child: MouseRegion(
            cursor: w.hideCursor ? SystemMouseCursors.none : MouseCursor.defer,
            child: w.child,
          ),
        ),
      ),
    );
  }
}
