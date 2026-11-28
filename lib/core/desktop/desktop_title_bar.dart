import 'dart:async';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../boot_network.dart';
import '../theme/app_colors.dart';
import '../theme/theme_controller.dart';
import 'desktop_chrome_colors.dart';
import 'desktop_close_guard.dart';
import 'desktop_window.dart';
import '../ui/desktop_svg.dart';
import '../../l10n/l10n.dart';

/// Client-drawn Windows caption. Only blank areas initiate native dragging;
/// media buttons remain ordinary accessible, keyboard-focusable controls.
class DesktopTitleBar extends StatefulWidget {
  const DesktopTitleBar({super.key});
  @override
  State<DesktopTitleBar> createState() => _DesktopTitleBarState();
}

/// Tracks native maximize changes made by buttons, snapping or window gestures.
/// The runner also pushes 'maximizedChanged' into DesktopWindow.maximized;
/// reading it here covers older runners and the first frame.
class _DesktopTitleBarState extends State<DesktopTitleBar>
    with WidgetsBindingObserver {
  // Locates the maximise button for Snap Layouts.
  final _maximizeKey = GlobalKey();
  // Last rect sent to the runner, to avoid resending an unchanged one.
  Rect? _reportedRect;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_readMaximized());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Hidden caption (fullscreen, mini player): no Snap Layouts target.
    if (_reportedRect != null) {
      unawaited(DesktopWindow.reportMaximizeButtonRect(null));
    }
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    unawaited(_readMaximized());
    _scheduleRectReport();
  }

  /// Snap, Win+Up and double-click can change state outside our own button.
  Future<void> _readMaximized() async {
    final value = await DesktopWindow.isMaximized();
    if (mounted) DesktopWindow.maximized.value = value;
  }

  Future<void> _maximize() async {
    final value = await DesktopWindow.toggleMaximize();
    if (mounted) DesktopWindow.maximized.value = value;
  }

  // Reports the maximise button's rect after layout, in physical pixels
  // relative to the view, so the runner can answer HTMAXBUTTON over it.
  void _scheduleRectReport() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = _maximizeKey.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) return;
      final ratio = View.of(context).devicePixelRatio;
      final origin = box.localToGlobal(Offset.zero);
      final rect = Rect.fromLTWH(
        origin.dx * ratio,
        origin.dy * ratio,
        box.size.width * ratio,
        box.size.height * ratio,
      );
      if (rect == _reportedRect) return;
      _reportedRect = rect;
      unawaited(DesktopWindow.reportMaximizeButtonRect(rect));
    });
  }

  // Rebuilds on theme revisions so Pure black / Background colour recolour
  // the caption immediately, in step with the rest of the desktop frame.
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      ThemeController.revision,
      DesktopWindow.maximized,
      DesktopWindow.maximizeHover,
    ]),
    builder: (context, _) => _bar(context),
  );

  Widget _bar(BuildContext context) => Material(
    key: const ValueKey('desktop-title-bar-surface'),
    color: DesktopChrome.frame,
    child: SizedBox(
      height: 46,
      child: LayoutBuilder(
        builder: (context, bounds) {
          final narrow = bounds.maxWidth < 750;
          // The button moves with the window width; re-report after layout.
          _scheduleRectReport();
          final maximized = DesktopWindow.maximized.value;
          return Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (_) => unawaited(DesktopWindow.startDrag()),
                  onDoubleTap: _maximize,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(color: DesktopChrome.hairline),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 16,
                top: 0,
                bottom: 0,
                child: IgnorePointer(
                  child: Row(
                    children: [
                      Image.asset(
                        'assets/icon/logo_mark.png',
                        width: 30,
                        height: 30,
                      ),
                      if (!narrow) ...[
                        const SizedBox(width: 14),
                        const Text(
                          'ZANGETSU',
                          style: TextStyle(
                            fontSize: 11,
                            letterSpacing: 4,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                child: Row(
                  children: [
                    // Sits left of the caption buttons; ignores pointer input
                    // so dragging the window by this area still works.
                    IgnorePointer(
                      child: ConnectionPill(
                        offline: BootConnectivity.instance.offline,
                      ),
                    ),
                    // No sync icon or sync toasts: sync runs silently in the
                    // background (offline still shows via the pill above).
                    const SizedBox(width: 6),
                    _CaptionButton(
                      label: context.l10n.windowMinimize,
                      icon: 'minus',
                      onTap: DesktopWindow.minimize,
                    ),
                    _CaptionButton(
                      key: _maximizeKey,
                      label: maximized
                          ? context.l10n.restore
                          : context.l10n.windowMaximize,
                      icon: maximized ? 'copy' : 'square',
                      onTap: _maximize,
                      // Hover comes from the runner (Snap Layouts area).
                      hovered: DesktopWindow.maximizeHover.value,
                    ),
                    _CaptionButton(
                      label: context.l10n.close,
                      // Wider X so it reads the same size as the other two.
                      icon: 'caption-close',
                      // Through the guard: a click while the close
                      // question is open quits at once.
                      onTap: DesktopCloseGuard.closeButtonPressed,
                      close: true,
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}

/// Quiet status pill for an offline start. Fades in with a short slide while
/// [offline] is true, then shows "Back online" for a moment and fades away.
/// Nothing is drawn when the app started with a working network.
class ConnectionPill extends StatefulWidget {
  const ConnectionPill({super.key, required this.offline});

  /// True while the app is running without a network connection.
  final ValueListenable<bool> offline;

  @override
  State<ConnectionPill> createState() => _ConnectionPillState();
}

enum _PillState { hidden, offline, backOnline }

class _ConnectionPillState extends State<ConnectionPill> {
  _PillState _state = _PillState.hidden;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _state = widget.offline.value ? _PillState.offline : _PillState.hidden;
    widget.offline.addListener(_changed);
  }

  @override
  void didUpdateWidget(ConnectionPill old) {
    super.didUpdateWidget(old);
    if (old.offline != widget.offline) {
      old.offline.removeListener(_changed);
      widget.offline.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.offline.removeListener(_changed);
    _hideTimer?.cancel();
    super.dispose();
  }

  void _changed() {
    _hideTimer?.cancel();
    if (widget.offline.value) {
      setState(() => _state = _PillState.offline);
      return;
    }
    // Only celebrate a reconnect that follows an offline period.
    if (_state != _PillState.offline) return;
    setState(() => _state = _PillState.backOnline);
    _hideTimer = Timer(const Duration(milliseconds: 2800), () {
      if (mounted) setState(() => _state = _PillState.hidden);
    });
  }

  @override
  Widget build(BuildContext context) {
    final show = _state != _PillState.hidden;
    final online = _state == _PillState.backOnline;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, -0.25),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      child: !show
          ? const SizedBox.shrink(key: ValueKey('pill-hidden'))
          : Semantics(
              key: ValueKey('pill-${_state.name}'),
              liveRegion: true,
              label: online ? 'Back online' : 'Offline',
              child: ExcludeSemantics(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    // set-9: follow the chrome theme (Pure black, custom
                    // background, accent) instead of fixed greys.
                    // The stock background keeps the original greys.
                    color: _stockChrome
                        ? const Color(0xFF1A1A23)
                        : DesktopChrome.field,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: _stockChrome
                          ? const Color(0xFF3C2D3A)
                          : Color.alphaBlend(
                              AppColors.accent.withValues(alpha: .18),
                              DesktopChrome.hairline,
                            ),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (online)
                          const _PillDot(color: Color(0xFF6FCF97))
                        else
                          SvgPicture.asset(
                            'assets/icons/lucide/wifi-off.svg',
                            width: 13,
                            height: 13,
                            renderingStrategy: desktopSvgStrategy,
                            colorFilter: const ColorFilter.mode(
                              Color(0xFFE3C6EA),
                              BlendMode.srcIn,
                            ),
                          ),
                        const SizedBox(width: 7),
                        Text(
                          online ? 'Back online' : 'Offline',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFFE3C6EA),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

class _PillDot extends StatelessWidget {
  const _PillDot({required this.color});
  final Color color;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 13,
    height: 13,
    child: Center(
      child: DecoratedBox(
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: const SizedBox(width: 7, height: 7),
      ),
    ),
  );
}

/// Standard caption targets expose their purpose to Windows accessibility.
class _CaptionButton extends StatelessWidget {
  const _CaptionButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    this.close = false,
    this.hovered = false,
  });
  final String label;
  final String icon;
  final VoidCallback onTap;
  final bool close;

  /// Paints the hover fill when the runner reports the pointer over this
  /// button (Flutter never sees that pointer for the maximise button).
  final bool hovered;

  /// Hover fill of the non-close caption buttons: the frame lifted a little.
  /// The stock background keeps the original 0xFF303138.
  static Color get _captionHover => _stockChrome
      ? const Color(0xFF303138)
      : Color.lerp(DesktopChrome.frame, Colors.white, .12)!;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: InkWell(
      key: ValueKey('caption-$label'),
      onTap: onTap,
      // Close keeps the Windows red; the others lift off the themed frame
      // (set-9) so they follow Pure black and custom backgrounds.
      hoverColor: close ? const Color(0xFFC42B1C) : _captionHover,
      child: Container(
        width: 46,
        height: 46,
        color: hovered ? _captionHover : null,
        child: ExcludeSemantics(
          child: Center(
            child: SvgPicture.asset(
              'assets/icons/lucide/$icon.svg',
              width: 15,
              height: 15,
              renderingStrategy: desktopSvgStrategy,
              colorFilter: const ColorFilter.mode(
                Colors.white,
                BlendMode.srcIn,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// True while the background is the shipped default, so the set-9 themed
/// colours fall back to the exact original greys (as DesktopChrome does).
bool get _stockChrome =>
    AppColors.bg.toARGB32() == AppColors.defaultBg.toARGB32();
