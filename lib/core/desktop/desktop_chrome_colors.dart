import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme/app_colors.dart';
import '../theme/theme_controller.dart';

/// Windows chrome colours derived from the Theme & colour settings.
///
/// The desktop frame (title bar, rail) and the Home canvas used to be fixed
/// greys, so Pure black and a custom Background colour changed page bodies
/// but left a grey frame around them. These getters follow [AppColors.bg]
/// and are read during build, so a widget that rebuilds on
/// `ThemeController.revision` picks up a change immediately. With the stock
/// background they return the exact original greys, so an untouched install
/// looks the same as before.
abstract final class DesktopChrome {
  /// The original desktop frame grey (title bar, rail, settings canvas).
  static const Color stockFrame = Color(0xFF101114);

  /// The original desktop Home canvas.
  static const Color stockCanvas = Color(0xFF0D1013);

  /// The original frame hairline (title bar bottom, rail edge).
  static const Color stockHairline = Color(0xFF25262C);

  /// True while the background is the shipped default (no Pure black, no
  /// custom Background colour).
  static bool get _stock =>
      AppColors.bg.toARGB32() == AppColors.defaultBg.toARGB32();

  /// True while Pure black is in effect.
  static bool get _black => AppColors.bg.toARGB32() == 0xFF000000;

  /// Frame behind the title bar and side rail. Pure black stays black; a
  /// custom background gets a slight lift so the frame still reads as chrome.
  static Color get frame => _stock
      ? stockFrame
      : _black
      ? AppColors.bg
      : Color.lerp(AppColors.bg, Colors.white, .025)!;

  /// Page canvas for the desktop Home.
  static Color get canvas => _stock ? stockCanvas : AppColors.bg;

  /// Divider between the frame and content.
  static Color get hairline =>
      _stock ? stockHairline : Color.lerp(frame, Colors.white, .1)!;

  /// Original settings sidebar gradient and its edge.
  static const Color stockSidebarTop = Color(0xFF15161A);
  static const Color stockSidebarBottom = Color(0xFF0E0F12);
  static const Color stockSidebarEdge = Color(0xFF292A30);

  /// Original search field fill in the shell's top bar.
  static const Color stockField = Color(0xFF191A20);

  /// Settings sidebar gradient. Stock keeps the original greys; otherwise it
  /// is a gentle lift of [frame] so Pure black / a custom colour reach it.
  static List<Color> get sidebarGradient => _stock
      ? const [stockSidebarTop, stockSidebarBottom]
      : [Color.lerp(frame, Colors.white, .02)!, frame];

  /// Right edge of the settings sidebar.
  static Color get sidebarEdge => _stock ? stockSidebarEdge : hairline;

  /// Text field fill sitting on the frame (shell search box).
  static Color get field =>
      _stock ? stockField : Color.lerp(frame, Colors.white, .045)!;

  /// Fill behind a selected/hovered navigation item: the current accent at a
  /// low strength over [frame], so it follows both the accent and background.
  static Color selectedFill(Color accent, {double strength = .16}) =>
      Color.alphaBlend(accent.withValues(alpha: strength), frame);

  /// Readable text/icon colour on top of an [accent] fill: dark on light
  /// accents (Amber, Cyan, Emerald), white on the rest.
  static Color onAccent(Color accent) =>
      accent.computeLuminance() > .4 ? const Color(0xFF0B0B0F) : Colors.white;
}

/// Re-runs every build below it when the theme revision changes.
///
/// Pages read [AppColors.bg] and [DesktopChrome] during build, and many of
/// them are const or sit in a nested navigator the root repaint observer does
/// not see, so a Pure black / Background colour change would otherwise only
/// show after leaving the page. Theme changes are rare user actions, so a
/// full subtree rebuild (what a locale change does) is cheap enough. State
/// is kept: only builds re-run, nothing is recreated.
class DesktopThemeRebuildScope extends StatefulWidget {
  const DesktopThemeRebuildScope({super.key, required this.child});

  final Widget child;

  @override
  State<DesktopThemeRebuildScope> createState() =>
      _DesktopThemeRebuildScopeState();
}

class _DesktopThemeRebuildScopeState extends State<DesktopThemeRebuildScope> {
  @override
  void initState() {
    super.initState();
    ThemeController.revision.addListener(_rebuildSubtree);
  }

  @override
  void dispose() {
    ThemeController.revision.removeListener(_rebuildSubtree);
    super.dispose();
  }

  void _rebuildSubtree() {
    if (!mounted) return;
    // A bump that lands mid-frame waits for the frame to finish, since
    // marking elements dirty during build is not allowed.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => _rebuildSubtree());
      return;
    }
    void mark(Element element) {
      element.markNeedsBuild();
      element.visitChildren(mark);
    }

    (context as Element).visitChildren(mark);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
