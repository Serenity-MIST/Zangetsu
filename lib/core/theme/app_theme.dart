import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'app_colors.dart';
import 'app_text.dart';

/// Widest a Windows snackbar grows; narrower windows use the full width.
const double kDesktopSnackBarWidth = 640;

/// Windows-only snackbar look: a bounded, centred, floating graphite toast
/// instead of a bar stretched across the whole window. Null elsewhere, so the
/// phone/TV theme is untouched. A SnackBar's own width/colours still win.
SnackBarThemeData? desktopSnackBarTheme() {
  if (defaultTargetPlatform != TargetPlatform.windows) return null;
  return SnackBarThemeData(
    behavior: SnackBarBehavior.floating,
    width: kDesktopSnackBarWidth,
    backgroundColor: const Color(0xFF1F2026),
    contentTextStyle: AppText.body.copyWith(color: AppColors.textPrimary),
    actionTextColor: AppColors.accent,
    closeIconColor: AppColors.textSecondary,
    elevation: 6,
    // Setting an inset also makes the full-width strip around the toast
    // click-through (deferToChild), so the bottom of the window stays usable
    // while a snackbar is up. With a width, only top/bottom apply.
    insetPadding: const EdgeInsets.fromLTRB(16, 6, 16, 18),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
      side: const BorderSide(color: Color(0xFF36373E)),
    ),
  );
}

/// Windows-only hover tooltip look: the same dark graphite card as the
/// desktop snackbar, instead of Material's light grey bubble that clashes
/// with the dark UI. Null elsewhere, so phone/TV tooltips are unchanged.
/// A local TooltipTheme (e.g. the player's) still wins.
TooltipThemeData? desktopTooltipTheme() {
  if (defaultTargetPlatform != TargetPlatform.windows) return null;
  return TooltipThemeData(
    decoration: BoxDecoration(
      color: const Color(0xFF1F2026),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: const Color(0xFF36373E)),
      boxShadow: const [
        BoxShadow(color: Color(0x66000000), blurRadius: 12, offset: Offset(0, 4)),
      ],
    ),
    textStyle: AppText.caption.copyWith(
      color: AppColors.textPrimary,
      fontSize: 12.5,
      fontWeight: FontWeight.w600,
      height: 1.25,
    ),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    margin: const EdgeInsets.symmetric(horizontal: 12),
    waitDuration: const Duration(milliseconds: 400),
  );
}

ThemeData buildAppTheme() {
  final scheme = ColorScheme.dark(
    surface: AppColors.bg,
    primary: AppColors.textPrimary, // white primary actions
    secondary: AppColors.accent,
    onPrimary: Colors.black,
  );
  return ThemeData(
    useMaterial3: true,
    fontFamily: AppText.fontFamily,
    fontFamilyFallback: AppText.fontFamilyFallback,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.bg,
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
    ),
    // Windows only; null keeps the stock phone/TV snackbars.
    snackBarTheme: desktopSnackBarTheme(),
    // Windows only; null keeps the stock phone/TV tooltips.
    tooltipTheme: desktopTooltipTheme(),
    dividerTheme: const DividerThemeData(
      color: AppColors.hairline,
      thickness: 0.5,
      space: 0.5,
    ),
  );
}
