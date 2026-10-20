import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import '../../core/ui/nav_prefs.dart';
import '../../l10n/ui_strings.dart';
import '../../core/desktop/desktop_window.dart';

/// Desktop navigation shares the user's mobile destinations and order.
class DesktopNavigation extends StatelessWidget {
  const DesktopNavigation({
    super.key,
    required this.tabs,
    required this.active,
    required this.onSelected,
    this.footer,
    this.expanded = true,
  });

  final List<DockTab> tabs;
  final DockTab active;
  final ValueChanged<DockTab> onSelected;
  final Widget? footer;
  final bool expanded;

  /// Shared desktop icon mapping for each configurable navigation destination.
  static IconData icon(DockTab tab) => switch (tab) {
    DockTab.home => Icons.home_rounded,
    DockTab.myList => Icons.bookmarks_rounded,
    DockTab.sources => Icons.extension_rounded,
    DockTab.search => Icons.search_rounded,
    DockTab.profile => Icons.settings_rounded,
    DockTab.downloads => Icons.download_rounded,
    DockTab.history => Icons.history_rounded,
  };

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: expanded ? 176 : 76,
      child: Material(
        color: AppColors.bg,
        child: SafeArea(
          child: Column(
            children: [
              SizedBox(
                height: 88,
                child: Center(
                  child: Text(
                    expanded ? 'ZANGETSU' : 'Z',
                    style: TextStyle(
                      fontSize: expanded ? 15 : 25,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 2,
                      color: AppColors.accent,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    for (final tab in tabs)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Tooltip(
                          message: tab.localizedLabel(context),
                          child: Material(
                            color: tab == active
                                ? AppColors.accent.withValues(alpha: .08)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(14),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(14),
                              onTap: () => onSelected(tab),
                              child: Semantics(
                                selected: tab == active,
                                button: true,
                                child: SizedBox(
                                  height: 52,
                                  child: Row(
                                    mainAxisAlignment: expanded
                                        ? MainAxisAlignment.start
                                        : MainAxisAlignment.center,
                                    children: [
                                      if (expanded) const SizedBox(width: 16),
                                      Icon(
                                        icon(tab),
                                        color: tab == active
                                            ? AppColors.accent
                                            : AppColors.textSecondary,
                                      ),
                                      if (expanded) ...[
                                        const SizedBox(width: 14),
                                        Expanded(
                                          child: Text(
                                            tab.localizedLabel(context),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontWeight: tab == active
                                                  ? FontWeight.w700
                                                  : FontWeight.w500,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (footer != null)
                Padding(padding: const EdgeInsets.all(16), child: footer!),
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: IconButton(
                  tooltip: 'Fullscreen (F11)',
                  onPressed: DesktopWindow.toggleFullscreen,
                  icon: const Icon(Icons.fullscreen_rounded),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
