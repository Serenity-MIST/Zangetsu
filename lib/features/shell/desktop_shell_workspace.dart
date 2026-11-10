import '../../core/desktop/desktop_media_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../../core/theme/app_colors.dart';
import '../../core/ui/nav_prefs.dart';

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
  });
  final DockTab active;
  final String? activeShortcut;
  final ValueChanged<DockTab> onSelected;
  final ValueChanged<String> onSearch;
  final Widget profile;
  final Widget child;
  /// Desktop route shortcuts, separate from the shared phone dock preferences.
  final List<({String id, String label, String icon, VoidCallback onTap})> shortcuts;
  final VoidCallback? onNotifications;

  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xFF101114),
    child: Row(
      children: [
        Container(
          width: 72,
          decoration: const BoxDecoration(
            border: Border(right: BorderSide(color: Color(0xFF25262C))),
          ),
          child: SingleChildScrollView(child: Column(
            children: [
              const SizedBox(height: 18),
              for (final entry in const [
                (DockTab.home, 'Home', 'house'),
                (DockTab.myList, 'My List', 'bookmark'),
                (DockTab.sources, 'Sources', 'puzzle'),
              ]) _DesktopRailButton(id: entry.$1.name,
                controlKey: ValueKey('desktop-rail-${entry.$1.name}'),
                label: entry.$2, icon: entry.$3,
                selected: activeShortcut == null && active == entry.$1,
                onPressed: () => onSelected(entry.$1)),
              for (final shortcut in shortcuts) _DesktopRailButton(id: shortcut.id,
                controlKey: ValueKey('desktop-shortcut-${shortcut.id}'),
                label: shortcut.label, icon: shortcut.icon,
                selected: activeShortcut == shortcut.id ||
                    (shortcut.id == 'downloads' && active == DockTab.downloads && activeShortcut == null),
                onPressed: shortcut.onTap),
            ],
          )),
        ),
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
                                          maxWidth: narrow ? 340 :
                                              (bounds.maxWidth / 2 - 380).clamp(160.0, 340.0),
                                        ),
                                        child: TextField(
                                          key: const ValueKey(
                                            'desktop-shell-search',
                                          ),
                                          textInputAction:
                                              TextInputAction.search,
                                          onSubmitted: onSearch,
                                          decoration: InputDecoration(
                                            hintText: 'Search titles...',
                                            isDense: true,
                                            filled: true,
                                            fillColor: const Color(0xFF191A20),
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
                                              borderSide: const BorderSide(
                                                color: Color(0xFF30343A),
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
                                              borderSide: const BorderSide(
                                                color: Color(0xFF303138),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  if (onNotifications != null) ...[
                                    const SizedBox(width: 8),
                                    IconButton(key: const ValueKey('desktop-shell-notifications'),
                                      tooltip: 'Notifications', onPressed: onNotifications,
                                      icon: SvgPicture.asset('assets/icons/lucide/bell.svg',
                                        width: 21, height: 21, colorFilter: const ColorFilter.mode(
                                          AppColors.textSecondary, BlendMode.srcIn))),
                                  ],
                                  const SizedBox(width: 12),
                                  Tooltip(
                                    message: 'Profile',
                                    excludeFromSemantics: true,
                                    child: IconButton(
                                      key: const ValueKey(
                                        'desktop-shell-profile',
                                      ),
                                      tooltip: 'Profile',
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
              Expanded(child: child),
            ],
          ),
        ),
      ],
    ),
  );
}


/// One Windows rail treatment for primary tabs and the added destinations.
/// Explicit selected semantics and focus paint mirror the visible active page.
class _DesktopRailButton extends StatelessWidget {
  const _DesktopRailButton({required this.id, required this.controlKey,
    required this.label, required this.icon, required this.selected, required this.onPressed});
  final String id, label, icon;
  final Key controlKey;
  final bool selected;
  final VoidCallback onPressed;
  @override Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
    child: Tooltip(message: label, excludeFromSemantics: true,
      child: Semantics(key: ValueKey('desktop-selected-$id'), button: true,
        selected: selected, label: label,
        child: Material(color: selected ? const Color(0xFF321E25) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(key: controlKey, onTap: onPressed,
            borderRadius: BorderRadius.circular(12),
            hoverColor: AppColors.accent.withValues(alpha: .08),
            focusColor: AppColors.accent.withValues(alpha: .16),
            child: Container(height: 50, alignment: Alignment.center,
              decoration: BoxDecoration(border: Border(left: BorderSide(width: 3,
                color: selected ? AppColors.accent : Colors.transparent))),
              child: ExcludeSemantics(child: SvgPicture.asset(
                'assets/icons/lucide/$icon.svg', width: 22, height: 22,
                colorFilter: ColorFilter.mode(selected ? AppColors.accent : AppColors.textSecondary,
                  BlendMode.srcIn)))))))));
}
