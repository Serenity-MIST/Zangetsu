import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'desktop_window.dart';

/// Client-drawn Windows caption. Only blank areas initiate native dragging;
/// media buttons remain ordinary accessible, keyboard-focusable controls.
class DesktopTitleBar extends StatefulWidget {
  const DesktopTitleBar({super.key});
  @override
  State<DesktopTitleBar> createState() => _DesktopTitleBarState();
}

/// Tracks native maximize changes made by buttons, snapping or window gestures.
class _DesktopTitleBarState extends State<DesktopTitleBar>
    with WidgetsBindingObserver {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_readMaximized());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    unawaited(_readMaximized());
  }

  /// Snap, Win+Up and double-click can change state outside our own button.
  Future<void> _readMaximized() async {
    final value = await DesktopWindow.isMaximized();
    if (mounted && value != _maximized) setState(() => _maximized = value);
  }

  Future<void> _maximize() async {
    final value = await DesktopWindow.toggleMaximize();
    if (mounted) setState(() => _maximized = value);
  }

  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xFF101114),
    child: SizedBox(
      height: 46,
      child: LayoutBuilder(
        builder: (context, bounds) {
          final narrow = bounds.maxWidth < 750;
          return Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (_) => unawaited(DesktopWindow.startDrag()),
                  onDoubleTap: _maximize,
                  child: const DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(color: Color(0xFF25262C)),
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
                    _CaptionButton(
                      label: 'Minimize',
                      icon: 'minus',
                      onTap: DesktopWindow.minimize,
                    ),
                    _CaptionButton(
                      label: _maximized ? 'Restore' : 'Maximize',
                      icon: _maximized ? 'copy' : 'square',
                      onTap: _maximize,
                    ),
                    _CaptionButton(
                      label: 'Close',
                      icon: 'x',
                      onTap: DesktopWindow.close,
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

/// Standard caption targets expose their purpose to Windows accessibility.
class _CaptionButton extends StatelessWidget {
  const _CaptionButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.close = false,
  });
  final String label;
  final String icon;
  final VoidCallback onTap;
  final bool close;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: InkWell(
      key: ValueKey('caption-$label'),
      onTap: onTap,
      hoverColor: close ? const Color(0xFFC42B1C) : const Color(0xFF303138),
      child: SizedBox(
        width: 46,
        height: 46,
        child: ExcludeSemantics(
          child: Center(
            child: SvgPicture.asset(
              'assets/icons/lucide/$icon.svg',
              width: 15,
              height: 15,
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
