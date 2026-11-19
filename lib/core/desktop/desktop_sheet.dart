import 'package:flutter/material.dart';

import '../ui/desktop_docked_panel.dart';

/// How a phone bottom sheet is shown on Windows.
enum DesktopSheetStyle {
  /// Centred graphite dialog (default; menus, pickers, short forms).
  dialog,

  /// Graphite card docked to the right edge (longer, browsable content).
  sidePanel,
}

/// Marks content shown by [showAdaptiveSheet] as a desktop dialog/panel.
///
/// Sheet bodies read [of] to hide phone-only bits such as drag handles and
/// bottom safe-area padding, and [showAdaptiveSheet] reads it to avoid
/// stacking a second sheet (and scrim) on top of one already open.
class DesktopSheetScope extends InheritedWidget {
  const DesktopSheetScope({super.key, required super.child});

  /// True inside a sheet presented the desktop way.
  static bool of(BuildContext c) =>
      c.dependOnInheritedWidgetOfExactType<DesktopSheetScope>() != null;

  @override
  bool updateShouldNotify(DesktopSheetScope oldWidget) => false;
}

/// Shows a bottom sheet on phone and a graphite dialog/panel on Windows.
///
/// Off Windows (and on TV) every argument goes to [showModalBottomSheet]
/// unchanged, so phone behaviour is exactly what it was. On Windows,
/// [desktopStyle] picks a centred dialog or a right-docked panel, a
/// [DesktopPanelTitleBar] is added when [title] is set, and Esc closes it.
/// A sheet opened from inside another desktop sheet always opens as a
/// centred dialog without its own scrim, so pickers never stack shades.
Future<T?> showAdaptiveSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  String? title,
  String? subtitle,
  DesktopSheetStyle desktopStyle = DesktopSheetStyle.dialog,
  double desktopWidth = 520,
  bool isScrollControlled = false,
  // Nullable like showModalBottomSheet's, so a phone sheet that does not
  // pass it still follows the theme's drag-handle setting.
  bool? showDragHandle,
  bool useRootNavigator = false,
  bool useSafeArea = false,
  bool isDismissible = true,
  Color? backgroundColor,
  ShapeBorder? shape,
  BoxConstraints? constraints,
}) {
  if (!desktopPanelsEnabled) {
    // Phone / TV: today's bottom sheet, untouched.
    return showModalBottomSheet<T>(
      context: context,
      builder: builder,
      isScrollControlled: isScrollControlled,
      showDragHandle: showDragHandle,
      useRootNavigator: useRootNavigator,
      useSafeArea: useSafeArea,
      isDismissible: isDismissible,
      backgroundColor: backgroundColor,
      shape: shape,
      constraints: constraints,
    );
  }

  final nested = DesktopSheetScope.of(context);
  // The body: optional title bar above the caller's content, which is told
  // (via DesktopSheetScope) that it is on desktop.
  Widget body(BuildContext dialogContext) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (title != null) DesktopPanelTitleBar(title: title, subtitle: subtitle),
      Flexible(
        child: DesktopSheetScope(child: Builder(builder: builder)),
      ),
    ],
  );

  if (desktopStyle == DesktopSheetStyle.sidePanel && !nested && isDismissible) {
    // The shared docked panel already handles Esc and click-away.
    return showDesktopDockedPanel<T>(
      context,
      width: desktopWidth,
      builder: body,
    );
  }

  return showDialog<T>(
    context: context,
    // Stays in the nearest navigator so a fullscreen player stays fullscreen
    // (same rule as showDesktopDockedPanel).
    useRootNavigator: false,
    barrierDismissible: isDismissible,
    // A nested picker sits over a sheet that already dims the page.
    barrierColor: nested ? Colors.transparent : Colors.black54,
    builder: (dialogContext) {
      final content = ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: desktopWidth,
          maxHeight: MediaQuery.sizeOf(dialogContext).height * 0.85,
        ),
        child: SizedBox(
          width: desktopWidth,
          child: Material(
            type: MaterialType.transparency,
            child: Builder(builder: body),
          ),
        ),
      );
      return Dialog(
        key: const ValueKey('desktop-adaptive-sheet'),
        alignment: desktopStyle == DesktopSheetStyle.sidePanel && !nested
            ? Alignment.centerRight
            : Alignment.center,
        backgroundColor: DesktopPanelColors.surface,
        surfaceTintColor: Colors.transparent,
        // A nested picker gets a shadow so it reads above its parent sheet.
        elevation: nested ? 16 : null,
        insetPadding: const EdgeInsets.all(24),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: DesktopPanelColors.edge),
        ),
        clipBehavior: Clip.antiAlias,
        // Esc closes only sheets the caller allows to be dismissed; others
        // still take focus so their own keys work.
        child: isDismissible
            ? DesktopEscCloses(child: content)
            : Focus(autofocus: true, child: content),
      );
    },
  );
}
