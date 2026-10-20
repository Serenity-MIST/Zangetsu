import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../ui/global_messenger.dart';

/// Installs Windows window-level shortcuts around the application navigator.
class DesktopWindow extends StatelessWidget {
  const DesktopWindow({super.key, required this.child});
  final Widget child;
  static const _channel = MethodChannel('com.spyou.zangetsu/window');

  /// Toggles native borderless fullscreen through the Windows runner channel.
  static Future<void> toggleFullscreen() =>
      _channel.invokeMethod<void>('toggleFullscreen');

  /// Reads native state so temporary reader fullscreen can restore its caller.
  static Future<bool> isFullscreen() async =>
      await _channel.invokeMethod<bool>('isFullscreen') ?? false;

  /// Sets borderless fullscreen without accidentally toggling an existing state.
  static Future<void> setFullscreen(bool enabled) =>
      _channel.invokeMethod<void>('setFullscreen', enabled);

  /// Exits fullscreen, returning whether the runner changed the window state.
  static Future<bool> exitFullscreen() async =>
      await _channel.invokeMethod<bool>('exitFullscreen') ?? false;

  /// Escape leaves native fullscreen first, then dismisses the current route.
  /// Without the fallback the global shortcut swallowed dialog dismissal.
  static Future<void> handleEscape() async {
    if (!await exitFullscreen()) {
      await rootNavigatorKey.currentState?.maybePop();
    }
  }

  @override
  Widget build(BuildContext context) => Platform.isWindows
      ? CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.f11): toggleFullscreen,
            const SingleActivator(LogicalKeyboardKey.escape): handleEscape,
          },
          child: Focus(autofocus: true, child: child),
        )
      : child;
}
