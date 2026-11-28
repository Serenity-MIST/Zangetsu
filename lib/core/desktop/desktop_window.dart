import 'dart:io';
import 'dart:async';
import 'desktop_back_navigation.dart';
import 'desktop_focus_repair.dart';
import 'desktop_native.dart';
import 'desktop_shortcuts.dart';
import 'desktop_smooth_scroll.dart';
import 'desktop_title_bar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../sync/sync_status.dart';
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

  /// Pinned above other windows (native 'alwaysOnTopChanged' keeps it true
  /// to the window).
  static final alwaysOnTop = ValueNotifier<bool>(false);

  /// Small always-on-top 16:9 player window in a screen corner. The title
  /// bar is hidden while it is on, as in fullscreen.
  static final miniPlayer = ValueNotifier<bool>(false);

  /// Window is maximised (reported by the runner on every size change, so
  /// Snap, Win+Up and double-click are all reflected).
  static final maximized = ValueNotifier<bool>(false);

  /// Pointer is over the maximise button. Windows owns that area for Snap
  /// Layouts, so Flutter cannot see the hover and the runner reports it.
  static final maximizeHover = ValueNotifier<bool>(false);

  /// Pins / unpins the window above other windows.
  static Future<void> setAlwaysOnTop(bool on) async {
    final applied = await DesktopNative.invokeWindow<bool>(
      'setAlwaysOnTop',
      on,
    ).catchError((Object _) => null);
    if (applied != null) alwaysOnTop.value = applied;
  }

  /// Shrinks the window to a ~480x270 always-on-top player in the
  /// bottom-right corner of its monitor (frame removed, 16:9 kept while
  /// resizing). Leaves fullscreen first.
  static Future<void> enterMiniPlayer() async {
    final entered = await DesktopNative.invokeWindow<bool>(
      'enterMiniPlayer',
    ).catchError((Object _) => null);
    if (entered != null) miniPlayer.value = entered;
  }

  /// Restores the size, position and topmost state from before the mini
  /// player.
  static Future<void> exitMiniPlayer() async {
    final still = await DesktopNative.invokeWindow<bool>(
      'exitMiniPlayer',
    ).catchError((Object _) => null);
    if (still != null) miniPlayer.value = still;
  }

  /// Same path as the caption X: runs the close guard (tray / confirm).
  static Future<void> requestClose() => close();

  /// Quits without the close guard.
  static Future<void> forceClose() async {
    await DesktopNative.invokeWindow<void>(
      'forceCloseWindow',
    ).catchError((Object _) {});
  }

  /// Tells the runner where the maximise button is (physical px relative
  /// to the view) so Windows 11 shows Snap Layouts over it. null clears it.
  static Future<void> reportMaximizeButtonRect(Rect? rect) async {
    await DesktopNative.invokeWindow<void>('setMaximizeButtonRect', {
      'x': rect?.left ?? 0,
      'y': rect?.top ?? 0,
      'w': rect?.width ?? 0,
      'h': rect?.height ?? 0,
    }).catchError((Object _) {});
  }

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

  /// Posts WM_CLOSE, so the close guard decides (same as the caption X).
  static Future<void> close() => _channel.invokeMethod<void>('closeWindow');
  static Future<bool> isMaximized() async =>
      await _channel.invokeMethod<bool>('isMaximizedWindow') ?? false;
  static Future<bool> toggleMaximize() async =>
      await _channel.invokeMethod<bool>('toggleMaximizeWindow') ?? false;

  /// Escape leaves native fullscreen first, then dismisses the current route.
  /// Without the fallback the global shortcut swallowed dialog dismissal.
  /// Inside a text field Esc only leaves the field: it must not also close
  /// the page or dialog the field sits in.
  static Future<void> handleEscape() async {
    final focus = FocusManager.instance.primaryFocus;
    final focusContext = focus?.context;
    if (focus != null &&
        focusContext != null &&
        (focusContext.widget is EditableText ||
            focusContext.findAncestorWidgetOfExactType<EditableText>() !=
                null)) {
      // Focus goes back to the page node instead of resting on the bare
      // scope (which left every page key dead, R1).
      DesktopFocusRepair.leaveTextField(focus);
      return;
    }
    if (!await exitFullscreen()) {
      await rootNavigatorKey.currentState?.maybePop();
    }
  }

  /// The one safe Back action shared by the mouse Back button and Alt+Left
  /// (shell-6): closes the top dialog / page, or lets the shell close its
  /// in-frame page. The shell's root PopScope never quits on Windows, so
  /// this can never exit the app.
  static Future<void> goBack() async {
    await rootNavigatorKey.currentState?.maybePop();
  }

  /// App-scope keyboard actions keyed by DesktopShortcuts id (shell-7), set
  /// by the shell: app.search, app.section1..9, app.mode1..4, app.settings,
  /// app.help, and optionally app.refresh. Handled here, at the window root,
  /// so they work wherever focus is; page handlers deeper in the focus tree
  /// see the key first and win (e.g. a page's own Ctrl+F).
  static Map<String, VoidCallback> _appActions = const {};

  /// Installs (or with null, removes) the shell's app-scope actions.
  static void setAppActions(Map<String, VoidCallback>? actions) {
    _appActions = actions == null ? const {} : Map.unmodifiable(actions);
  }

  /// Whether keyboard focus sits in a text field, where plain keys such as
  /// '/' and '?' are typing rather than shortcuts.
  static bool focusInTextField() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    return context.widget is EditableText ||
        context.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  /// Key handler for the window's app-scope shortcuts (Windows UI only).
  @visibleForTesting
  static KeyEventResult handleAppKey(KeyEvent event) {
    if (defaultTargetPlatform != TargetPlatform.windows) {
      return KeyEventResult.ignored;
    }
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    final plain =
        !keyboard.isControlPressed &&
        !keyboard.isAltPressed &&
        !keyboard.isMetaPressed;
    // In a text box '/', '?' and F5 belong to the field, not the app.
    if (plain && focusInTextField()) return KeyEventResult.ignored;
    // Alt+Left: same safe Back as the mouse Back button.
    if (DesktopShortcuts.matches('app.back', event)) {
      unawaited(goBack());
      return KeyEventResult.handled;
    }
    for (final entry in _appActions.entries) {
      if (DesktopShortcuts.matches(entry.key, event)) {
        entry.value();
        return KeyEventResult.handled;
      }
    }
    // acct-3: F5 / Ctrl+R that no page used runs a sync instead.
    if (DesktopShortcuts.matches('app.refresh', event) &&
        SyncStatus.onSyncRequested != null) {
      unawaited(SyncStatus.requestSync());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Mouse Back side button anywhere in the app (shell-6). Screens that
  /// handle it themselves (player, reader) get the press first; this only
  /// acts when none of them did.
  @visibleForTesting
  static void handlePointerDown(PointerDownEvent event) {
    if (defaultTargetPlatform != TargetPlatform.windows) return;
    if (!DesktopMouseBack.isBackPress(event)) return;
    if (DesktopMouseBack.handledElsewhere()) return;
    unawaited(goBack());
  }

  @override
  State<DesktopWindow> createState() => _DesktopWindowState();
}

/// Activates client chrome only after the runner confirms native support.
/// Older runners keep their real caption instead of displaying two titlebars.
class _DesktopWindowState extends State<DesktopWindow> {
  bool _chromeReady = false;

  // The window's own app-key node. Focus resting here means no page has it,
  // so DesktopFocusRepair treats it as lost (R1).
  final FocusNode _windowFocus = FocusNode(
    debugLabel: 'desktop-window-keys',
    skipTraversal: true,
  );

  // R1: re-runs the focus repair when the app comes back to the foreground
  // (a focused widget removed while away leaves focus on the root scope).
  AppLifecycleListener? _lifecycle;

  // Windows UI gate for the focus repair hooks.
  bool get _windowsUi => defaultTargetPlatform == TargetPlatform.windows;

  @override
  void initState() {
    super.initState();
    // The caption handshake goes first; then native events (fullscreen,
    // maximise, close requests, tray, drops) start flowing to Dart.
    unawaited(_configure());
    DesktopNative.ensureInitialized();
    if (_windowsUi) {
      DesktopFocusRepair.windowNode = _windowFocus;
      // Every focus change: if it left focus lost, put it back on the page.
      FocusManager.instance.addListener(DesktopFocusRepair.schedule);
      _lifecycle = AppLifecycleListener(onResume: DesktopFocusRepair.schedule);
    }
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(DesktopFocusRepair.schedule);
    _lifecycle?.dispose();
    if (identical(DesktopFocusRepair.windowNode, _windowFocus)) {
      DesktopFocusRepair.windowNode = null;
    }
    _windowFocus.dispose();
    super.dispose();
  }

  /// R1: a click outside a text field leaves it the way Esc does, handing
  /// focus back to the page (the SDK default drops it on the bare scope).
  void _tapOutside(EditableTextTapOutsideIntent intent) =>
      DesktopFocusRepair.leaveTextField(intent.focusNode);

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
            focusNode: _windowFocus,
            autofocus: true,
            // shell-7: app-wide shortcuts, reached when no deeper page
            // handled the key.
            onKeyEvent: (_, event) => DesktopWindow.handleAppKey(event),
            child: _windowsUi
                ? Actions(
                    // R1: overrides the SDK's tap-outside unfocus for
                    // every text field in the app (Windows UI only).
                    actions: <Type, Action<Intent>>{
                      EditableTextTapOutsideIntent:
                          CallbackAction<EditableTextTapOutsideIntent>(
                            onInvoke: (intent) {
                              _tapOutside(intent);
                              return null;
                            },
                          ),
                    },
                    child: _probe(),
                  )
                : _probe(),
          ),
        )
      : widget.child;

  // Mouse Back probe and listener around the window content.
  Widget _probe() => DesktopMouseBackProbe(
              // Records the top route before the press reaches any screen.
              enabled: defaultTargetPlatform == TargetPlatform.windows,
              child: Listener(
                // shell-6: mouse Back button app-wide (runs after deeper
                // Listeners such as the player's).
                onPointerDown: DesktopWindow.handlePointerDown,
                // Smooth eased mouse wheel for every scroll view in the app
                // (Windows UI only).
                child: DesktopWheelGlideScope(
                  enabled: _windowsUi,
                  child: _content(),
                ),
              ),
            );

  // Window content: the app with the client caption on top unless the
  // window is fullscreen or in the mini player.
  Widget _content() => ListenableBuilder(
              listenable: Listenable.merge([
                DesktopWindow.fullscreen,
                DesktopWindow.miniPlayer,
              ]),
              builder: (context, _) {
                // Fullscreen and the mini player both show no caption.
                final showCaption =
                    _chromeReady &&
                    !DesktopWindow.fullscreen.value &&
                    !DesktopWindow.miniPlayer.value;
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
            );
}
