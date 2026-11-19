import '../../core/desktop/desktop_media_selector.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../../core/desktop/desktop_chrome_colors.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/theme_controller.dart';
import '../../core/ui/nav_prefs.dart';
import '../../l10n/ui_strings.dart';
import '../../l10n/l10n.dart';
import '../search/desktop_search_dropdown.dart';

/// Primary tabs on the Windows rail, in order. The shell uses the same order
/// for the Ctrl+1..N section shortcuts. History is no longer on the rail (the
/// user removed it): it opens from the Profile page and with Ctrl+H.
// The English names are fallbacks only; the rail shows the translated
// DockTab label (localizedLabel).
const desktopRailTabs = [
  (DockTab.home, 'Home', 'house'),
  (DockTab.myList, 'My List', 'bookmark'),
  // Same Lucide 'blocks' icon as Settings > Sources, so Sources looks the
  // same everywhere on Windows (the user preferred it to the puzzle piece).
  (DockTab.sources, 'Sources', 'blocks'),
];

/// Width of the Windows rail. It is always the compact icon rail now; the
/// expand toggle and the labelled width were removed.
const double kDesktopRailCollapsed = 72;

/// Windows application frame from the approved Home reference. The shell owns
/// navigation/state; this widget only presents the rail and utility actions.
class DesktopShellWorkspace extends StatelessWidget {
  const DesktopShellWorkspace({
    super.key,
    required this.active,
    required this.onSelected,
    required this.onSearch,
    required this.profile,
    required this.child,
    this.shortcuts = const [],
    this.onNotifications,
    this.activeShortcut,
    this.searchFocusNode,
    this.searchController,
    this.unreadNotifications,
  });
  final DockTab active;
  final String? activeShortcut;
  final ValueChanged<DockTab> onSelected;
  final ValueChanged<String> onSearch;
  final Widget profile;
  final Widget child;

  /// Desktop route shortcuts, separate from the shared phone dock preferences.
  final List<({String id, String label, String icon, VoidCallback onTap})>
  shortcuts;
  final VoidCallback? onNotifications;

  // Settings is no longer on the rail: it opens from the Profile page and
  // with Ctrl+, (the shell's 'app.settings' action).

  /// shell-7: lets Ctrl+F and '/' focus the top-bar search box.
  final FocusNode? searchFocusNode;
  final TextEditingController? searchController;

  /// shell-9: unread new-episode count shown as a badge on the bell.
  final ValueListenable<int>? unreadNotifications;

  // Rebuilds on theme revisions so Pure black, Background colour and the
  // accent recolour the rail and top bar live, like the title bar does.
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: ThemeController.revision,
    builder: (context, _, _) => _frame(context),
  );

  // Left rail: the compact icon rail, destinations only. The Settings gear
  // and the expand / collapse chevron were removed at the user's request.
  // A plain Container: other tests read its decoration by key.
  // Takes the context for the translated labels.
  Widget _rail(BuildContext context) => Container(
    key: const ValueKey('desktop-shell-rail'),
    width: kDesktopRailCollapsed,
    decoration: BoxDecoration(
      color: DesktopChrome.frame,
      border: Border(right: BorderSide(color: DesktopChrome.hairline)),
    ),
    child: SingleChildScrollView(
      child: Column(
        children: [
          const SizedBox(height: 18),
          for (final entry in desktopRailTabs)
            _DesktopRailButton(
              id: entry.$1.name,
              controlKey: ValueKey('desktop-rail-${entry.$1.name}'),
              label: entry.$1.localizedLabel(context),
              icon: entry.$3,
              selected: activeShortcut == null && active == entry.$1,
              onPressed: () => onSelected(entry.$1),
            ),
          for (final shortcut in shortcuts)
            _DesktopRailButton(
              id: shortcut.id,
              controlKey: ValueKey('desktop-shortcut-${shortcut.id}'),
              label: shortcut.label,
              icon: shortcut.icon,
              selected:
                  activeShortcut == shortcut.id ||
                  (shortcut.id == 'downloads' &&
                      active == DockTab.downloads &&
                      activeShortcut == null),
              onPressed: shortcut.onTap,
            ),
        ],
      ),
    ),
  );

  // Bell with an unread badge (shell-9).
  Widget _bell(BuildContext context) {
    final button = SvgPicture.asset(
      'assets/icons/lucide/bell.svg',
      width: 21,
      height: 21,
      colorFilter: const ColorFilter.mode(
        AppColors.textSecondary,
        BlendMode.srcIn,
      ),
    );
    final unread = unreadNotifications;
    return IconButton(
      key: const ValueKey('desktop-shell-notifications'),
      tooltip: context.l10n.settingsSectionNotifications,
      onPressed: onNotifications,
      icon: unread == null
          ? button
          : ValueListenableBuilder<int>(
              valueListenable: unread,
              builder: (context, count, child) => Badge(
                key: const ValueKey('desktop-shell-notifications-badge'),
                isLabelVisible: count > 0,
                backgroundColor: AppColors.accent,
                textColor: Colors.white,
                label: Text(count > 99 ? '99+' : '$count'),
                child: child,
              ),
              child: button,
            ),
    );
  }

  Widget _frame(BuildContext context) => Material(
    key: const ValueKey('desktop-shell-frame'),
    color: DesktopChrome.frame,
    child: Row(
      children: [
        _rail(context),
        Expanded(
          child: Column(
            children: [
              LayoutBuilder(
                builder: (context, bounds) {
                  // Keep search and the pill on one row at desktop widths. At
                  // narrow sizes use two compact rows instead of overlapping.
                  final narrow = bounds.maxWidth < 1100;
                  return SizedBox(
                    height: narrow ? 108 : 56,
                    child: Stack(
                      children: [
                        Positioned(
                          top: narrow ? 52 : 0,
                          left: 0,
                          right: 0,
                          child: SizedBox(
                            height: 56,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Align(
                                      alignment: Alignment.centerRight,
                                      child: ConstrainedBox(
                                        // Reserve the centered media pill and the utility
                                        // buttons before sizing the search field.
                                        constraints: BoxConstraints(
                                          maxWidth: narrow
                                              ? 340
                                              : (bounds.maxWidth / 2 - 380)
                                                    .clamp(160.0, 340.0),
                                        ),
                                        // Quick results dropdown under the box
                                        // (Windows only; pass-through else).
                                        child: DesktopSearchDropdown(
                                        controller: searchController,
                                        focusNode: searchFocusNode,
                                        onSeeAll: onSearch,
                                        child: TextField(
                                          key: const ValueKey(
                                            'desktop-shell-search',
                                          ),
                                          // shell-7: Ctrl+F and '/' focus it.
                                          focusNode: searchFocusNode,
                                          controller: searchController,
                                          textInputAction:
                                              TextInputAction.search,
                                          onSubmitted: onSearch,
                                          // R1: a non-null callback stops the
                                          // SDK from dropping focus on the
                                          // bare scope after Enter (that left
                                          // the page keys dead). Esc or a
                                          // click elsewhere leaves the box.
                                          onEditingComplete: () {},
                                          decoration: InputDecoration(
                                            hintText: context.l10n.searchTitlesEllipsis,
                                            isDense: true,
                                            filled: true,
                                            fillColor: DesktopChrome.field,
                                            contentPadding:
                                                const EdgeInsets.symmetric(
                                                  horizontal: 14,
                                                  vertical: 10,
                                                ),
                                            prefixIcon: Padding(
                                              padding: const EdgeInsets.all(11),
                                              child: SvgPicture.asset(
                                                'assets/icons/lucide/search.svg',
                                                width: 18,
                                                height: 18,
                                                colorFilter:
                                                    const ColorFilter.mode(
                                                      AppColors.textSecondary,
                                                      BlendMode.srcIn,
                                                    ),
                                              ),
                                            ),
                                            hintStyle: TextStyle(
                                              fontSize: 12,
                                              color: AppColors.textSecondary,
                                            ),
                                            enabledBorder: OutlineInputBorder(
                                              borderRadius:
                                                  BorderRadius.circular(11),
                                              // set-9: themed edge (the frame
                                              // lifted), not a fixed grey.
                                              borderSide: BorderSide(
                                                color: _searchEdge(
                                                  const Color(0xFF30343A),
                                                ),
                                              ),
                                            ),
                                            focusedBorder: OutlineInputBorder(
                                              borderRadius:
                                                  BorderRadius.circular(11),
                                              borderSide: BorderSide(
                                                color: AppColors.accent,
                                              ),
                                            ),
                                            border: OutlineInputBorder(
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                              borderSide: BorderSide(
                                                color: _searchEdge(
                                                  const Color(0xFF303138),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  // acct-3's sync icon lives in the title bar
                                  // (DesktopTitleBar), as the user chose.
                                  if (onNotifications != null) ...[
                                    const SizedBox(width: 8),
                                    _bell(context),
                                  ],
                                  const SizedBox(width: 12),
                                  Tooltip(
                                    message: context.l10n.profile,
                                    excludeFromSemantics: true,
                                    child: IconButton(
                                      key: const ValueKey(
                                        'desktop-shell-profile',
                                      ),
                                      tooltip: context.l10n.profile,
                                      onPressed: () =>
                                          onSelected(DockTab.profile),
                                      icon: profile,
                                      padding: EdgeInsets.zero,
                                      constraints:
                                          const BoxConstraints.tightFor(
                                            width: 38,
                                            height: 38,
                                          ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          top: 6,
                          left: 0,
                          right: 0,
                          child: Align(
                            alignment: Alignment.topCenter,
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: bounds.maxWidth < 454
                                    ? bounds.maxWidth - 24
                                    : 430,
                              ),
                              child: const DesktopMediaSelector(),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
              // Tab pages re-read the background on a theme change too.
              Expanded(child: DesktopThemeRebuildScope(child: child)),
            ],
          ),
        ),
      ],
    ),
  );
}

/// One Windows rail treatment for primary tabs and the added destinations.
/// Explicit selected semantics and focus paint mirror the visible active page.
/// The rail is icon-only, so the label shows as a hover tooltip.
class _DesktopRailButton extends StatelessWidget {
  const _DesktopRailButton({
    required this.id,
    required this.controlKey,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onPressed,
  });
  final String id, label, icon;
  final Key controlKey;
  final bool selected;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.accent : AppColors.textSecondary;
    // Icon only, centred in the rail.
    final content = Center(
      child: SvgPicture.asset(
        'assets/icons/lucide/$icon.svg',
        width: 22,
        height: 22,
        colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
      ),
    );
    final button = Semantics(
      key: ValueKey('desktop-selected-$id'),
      button: true,
      selected: selected,
      label: label,
      // Selected tint follows the accent and the frame instead of fixed coral.
      child: Material(
        color: selected
            ? DesktopChrome.selectedFill(AppColors.accent)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          key: controlKey,
          onTap: onPressed,
          borderRadius: BorderRadius.circular(12),
          hoverColor: AppColors.accent.withValues(alpha: .08),
          focusColor: AppColors.accent.withValues(alpha: .16),
          child: Container(
            height: 50,
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  width: 3,
                  color: selected ? AppColors.accent : Colors.transparent,
                ),
              ),
            ),
            child: ExcludeSemantics(child: content),
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
      // Hover tooltip names the icon (Semantics already carries the label).
      child: Tooltip(message: label, excludeFromSemantics: true, child: button),
    );
  }
}

/// set-9: top-bar search border. The stock background keeps [stock] (the
/// original grey); other backgrounds lift the themed frame instead.
Color _searchEdge(Color stock) =>
    AppColors.bg.toARGB32() == AppColors.defaultBg.toARGB32()
    ? stock
    : Color.lerp(DesktopChrome.frame, Colors.white, .12)!;
