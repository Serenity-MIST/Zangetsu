import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'desktop_window.dart';

/// Desktop transport uses the same player actions as the visible controls.
class DesktopPlayerInput extends StatelessWidget {
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
  });
  final Widget child;
  final bool hideCursor;

  /// Uses the user's seek duration for keyboard and forward mouse actions.
  final int seekSeconds;
  final VoidCallback onPlayPause, onMute, onBack;
  final ValueChanged<int> onSeek;
  final ValueChanged<double> onVolume;

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows) return child;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.space): onPlayPause,
        const SingleActivator(LogicalKeyboardKey.keyK): onPlayPause,
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            onSeek(-seekSeconds),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            onSeek(seekSeconds),
        const SingleActivator(LogicalKeyboardKey.keyJ): () =>
            onSeek(-seekSeconds),
        const SingleActivator(LogicalKeyboardKey.keyL): () =>
            onSeek(seekSeconds),
        const SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true): () =>
            onSeek(-60),
        const SingleActivator(LogicalKeyboardKey.arrowRight, shift: true): () =>
            onSeek(60),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => onVolume(5),
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => onVolume(-5),
        const SingleActivator(LogicalKeyboardKey.keyM): onMute,
        const SingleActivator(LogicalKeyboardKey.keyF):
            DesktopWindow.toggleFullscreen,
        const SingleActivator(LogicalKeyboardKey.escape): () async {
          if (!await DesktopWindow.exitFullscreen()) onBack();
        },
      },
      child: Focus(
        autofocus: true,
        child: Listener(
          onPointerSignal: (event) {
            if (event is PointerScrollEvent) {
              GestureBinding.instance.pointerSignalResolver.register(
                event,
                (_) => onVolume(event.scrollDelta.dy < 0 ? 5 : -5),
              );
            }
          },
          onPointerDown: (event) {
            if (event.kind != PointerDeviceKind.mouse) return;
            if (event.buttons & kBackMouseButton != 0) onBack();
            if (event.buttons & kForwardMouseButton != 0) onSeek(seekSeconds);
            if (event.buttons & kMiddleMouseButton != 0) onPlayPause();
          },
          child: MouseRegion(
            cursor: hideCursor ? SystemMouseCursors.none : MouseCursor.defer,
            child: child,
          ),
        ),
      ),
    );
  }
}
