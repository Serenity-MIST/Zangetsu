import 'dart:io';
import 'dart:async';
import 'desktop_title_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../ui/global_messenger.dart';

/// Installs Windows window-level shortcuts around the application navigator.
class DesktopWindow extends StatefulWidget {
  const DesktopWindow({
    super.key,
    required this.child,
    this.enableChrome = false,
  });
  final Widget child;
  final bool enableChrome;
  static final fullscreen = ValueNotifier<bool>(false);
  static const _channel = MethodChannel('com.spyou.zangetsu/window');

  /// Toggles native borderless fullscreen through the Windows runner channel.
  static Future<void> toggleFullscreen() async {
    await _channel.invokeMethod<void>('toggleFullscreen');
    fullscreen.value = await isFullscreen();
  }

  /// Reads native state so temporary reader fullscreen can restore its caller.
  static Future<bool> isFullscreen() async =>
      await _channel.invokeMethod<bool>('isFullscreen') ?? false;

  /// Sets borderless fullscreen without accidentally toggling an existing state.
  static Future<void> setFullscreen(bool enabled) async {
    await _channel.invokeMethod<void>('setFullscreen', enabled);
    fullscreen.value = enabled;
  }

  /// Exits fullscreen, returning whether the runner changed the window state.
  static Future<bool> exitFullscreen() async {
    final exited = await _channel.invokeMethod<bool>('exitFullscreen') ?? false;
    if (exited) fullscreen.value = false;
    return exited;
  }

  /// Native caption actions retain normal window manager behavior.
  static Future<void> startDrag() =>
      _channel.invokeMethod<void>('startWindowDrag');
  static Future<void> minimize() =>
      _channel.invokeMethod<void>('minimizeWindow');
  static Future<void> close() => _channel.invokeMethod<void>('closeWindow');
  static Future<bool> isMaximized() async =>
      await _channel.invokeMethod<bool>('isMaximizedWindow') ?? false;
  static Future<bool> toggleMaximize() async =>
      await _channel.invokeMethod<bool>('toggleMaximizeWindow') ?? false;

  /// Escape leaves native fullscreen first, then dismisses the current route.
  /// Without the fallback the global shortcut swallowed dialog dismissal.
  static Future<void> handleEscape() async {
    if (!await exitFullscreen()) {
      await rootNavigatorKey.currentState?.maybePop();
    }
  }

  @override
  State<DesktopWindow> createState() => _DesktopWindowState();
}

/// Activates client chrome only after the runner confirms native support.
/// Older runners keep their real caption instead of displaying two titlebars.
class _DesktopWindowState extends State<DesktopWindow> {
  bool _chromeReady = false;
  @override
  void initState() {
    super.initState();
    unawaited(_configure());
  }

  @override
  void didUpdateWidget(DesktopWindow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enableChrome != widget.enableChrome) {
      unawaited(_configure());
    }
  }

  Future<void> _configure() async {
    if (!Platform.isWindows) return;
    final requested = widget.enableChrome;
    try {
      final supported =
          await DesktopWindow._channel.invokeMethod<bool>(
            'setTitlebarHidden',
            requested,
          ) ??
          false;
      if (mounted && requested == widget.enableChrome) {
        setState(() => _chromeReady = requested && supported);
      }
    } on MissingPluginException {
      // Widget fixtures and older binaries retain the platform caption.
    }
  }

  @override
  Widget build(BuildContext context) => Platform.isWindows
      ? CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.f11):
                DesktopWindow.toggleFullscreen,
            const SingleActivator(LogicalKeyboardKey.escape):
                DesktopWindow.handleEscape,
          },
          child: Focus(
            autofocus: true,
            child: ValueListenableBuilder<bool>(
              valueListenable: DesktopWindow.fullscreen,
              builder: (context, fullscreen, _) {
                final showCaption = _chromeReady && !fullscreen;
                // Paint the caption after the Navigator: ModalRoute's
                // BlockSemantics otherwise hides earlier siblings from UIA.
                return Stack(
                  children: [
                    Positioned.fill(
                      child: Padding(
                        padding: EdgeInsets.only(top: showCaption ? 46 : 0),
                        child: widget.child,
                      ),
                    ),
                    if (showCaption)
                      const Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: DesktopTitleBar(),
                      ),
                  ],
                );
              },
            ),
          ),
        )
      : widget.child;
}
