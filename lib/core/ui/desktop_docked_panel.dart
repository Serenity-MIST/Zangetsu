import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_mode.dart';
import '../desktop/desktop_chrome_colors.dart';
import '../di/injector.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

/// True when menus open as Windows desktop panels/dialogs instead of phone
/// bottom sheets. Uses the target platform (not the host OS) so phone tests
/// that run on a Windows host keep the phone sheets. TV never takes it.
bool get desktopPanelsEnabled =>
    defaultTargetPlatform == TargetPlatform.windows &&
    !(sl.isRegistered<AppMode>() && sl<AppMode>().isTv);

/// Colours of the graphite docked panels and dialogs. The stock background
/// keeps the original greys exactly; Pure black and a custom Background
/// colour lift off [DesktopChrome.frame] so the panels follow the theme.
abstract final class DesktopPanelColors {
  /// The original panel fill.
  static const Color stockSurface = Color(0xFF1A1B20);

  /// The original panel border / divider.
  static const Color stockEdge = Color(0xFF36373E);

  static bool get _stock =>
      AppColors.bg.toARGB32() == AppColors.defaultBg.toARGB32();

  /// Panel fill.
  static Color get surface => _stock
      ? stockSurface
      : Color.lerp(DesktopChrome.frame, Colors.white, .05)!;

  /// Panel border and dividers inside it.
  static Color get edge =>
      _stock ? stockEdge : Color.lerp(surface, Colors.white, .12)!;
}

/// Esc closes the route this sits in. The window-level Esc binding (leave
/// fullscreen, else pop the root navigator) sits above dialog routes, so
/// without this Esc would leave fullscreen instead of closing the panel.
/// Autofocus moves focus inside, so this handler sees Esc first.
class DesktopEscCloses extends StatelessWidget {
  const DesktopEscCloses({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.escape): () =>
          Navigator.of(context).maybePop(),
    },
    child: Focus(autofocus: true, child: child),
  );
}

/// Title row of a desktop panel: title, optional subtitle, close button.
class DesktopPanelTitleBar extends StatelessWidget {
  const DesktopPanelTitleBar({
    super.key,
    required this.title,
    this.subtitle,
    this.onClose,
  });

  final String title;
  final String? subtitle;

  /// Defaults to popping the panel's route.
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 12, 8, 6),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppText.headline.copyWith(
                  fontSize: 20,
                  color: AppColors.textPrimary,
                ),
              ),
              if (subtitle != null && subtitle!.isNotEmpty)
                Text(
                  subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
            ],
          ),
        ),
        IconButton(
          key: const ValueKey('desktop-panel-close'),
          tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
          onPressed: onClose ?? () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.close_rounded),
          color: AppColors.textSecondary,
        ),
      ],
    ),
  );
}

/// Windows panel: a graphite card docked to the right edge over a light
/// scrim (the same look as the in-player menus), or centred over a darker
/// scrim when [centred]. Click outside or Esc closes it. Stays inside the
/// nearest navigator so a fullscreen player stays fullscreen.
Future<T?> showDesktopDockedPanel<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  double width = 440,
  bool centred = false,
  Key? dialogKey,
}) => showDialog<T>(
  context: context,
  useRootNavigator: false,
  barrierColor: centred ? Colors.black54 : Colors.black26,
  builder: (dialogContext) => Dialog(
    key: dialogKey ?? const ValueKey('desktop-docked-panel'),
    alignment: centred ? Alignment.center : Alignment.centerRight,
    backgroundColor: DesktopPanelColors.surface,
    surfaceTintColor: Colors.transparent,
    insetPadding: const EdgeInsets.all(24),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      side: BorderSide(color: DesktopPanelColors.edge),
    ),
    clipBehavior: Clip.antiAlias,
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: width,
        maxHeight: MediaQuery.sizeOf(dialogContext).height * 0.85,
      ),
      child: DesktopEscCloses(
        // Bodies size to their content; give them the panel's full width.
        child: SizedBox(
          width: width,
          child: Material(
            type: MaterialType.transparency,
            child: Builder(builder: builder),
          ),
        ),
      ),
    ),
  ),
);
