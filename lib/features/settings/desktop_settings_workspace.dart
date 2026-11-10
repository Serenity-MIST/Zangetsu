import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/desktop_settings_surface.dart';
import 'desktop_settings_icon.dart';

/// One real settings destination; selection never changes a preference value.
class DesktopSettingsDestination {
  const DesktopSettingsDestination({
    required this.id,
    required this.title,
    required this.icon,
    required this.onOpen,
  });

  final String id;
  final String title;
  final IconData icon;
  final VoidCallback onOpen;
}

/// Settings-only desktop frame based on the supplied graphite reference.
/// The content navigator is supplied by the owner so leaf pages stay inside
/// this frame. Narrow windows retain a labeled-by-tooltip icon rail.
class DesktopSettingsWorkspace extends StatelessWidget {
  const DesktopSettingsWorkspace({
    super.key,
    required this.title,
    required this.selectedId,
    required this.destinations,
    required this.onExit,
    required this.child,
  });

  final String title;
  final String selectedId;
  final List<DesktopSettingsDestination> destinations;
  final VoidCallback onExit;
  final Widget child;

  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xFF101114),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 900;
        return Row(
          children: [
            Container(
              width: compact ? 76 : 236,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF15161A), Color(0xFF0E0F12)],
                ),
                border: Border(right: BorderSide(color: Color(0xFF292A30))),
              ),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 22, 12, 20),
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: MaterialLocalizations.of(
                            context,
                          ).backButtonTooltip,
                          onPressed: onExit,
                          icon: const Icon(Icons.arrow_back_rounded, size: 20),
                          color: AppColors.textSecondary,
                        ),
                        if (!compact) const SizedBox(width: 8),
                        if (!compact)
                          Expanded(
                            child: Text(
                              title,
                              style: AppText.headline.copyWith(
                                fontSize: 25,
                                color: AppColors.textPrimary,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Column(
                        children: [
                          for (final destination in destinations)
                            _WorkspaceDestination(
                              destination: destination,
                              selected: destination.id == selectedId,
                              compact: compact,
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: DesktopSettingsScope(
                child: Theme(
                  data: Theme.of(context).copyWith(
                    scaffoldBackgroundColor: const Color(0xFF101114),
                    canvasColor: const Color(0xFF101114),
                    dividerColor: const Color(0xFF303137),
                    // Scope form chrome to the settings navigator: controllers,
                    // validation and device settings remain with their owners.
                    inputDecorationTheme: InputDecorationTheme(
                      filled: true,
                      fillColor: const Color(0xFF17181D),
                      hoverColor: const Color(0xFF25262D),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 16,
                      ),
                      labelStyle: AppText.body.copyWith(
                        color: AppColors.textSecondary,
                      ),
                      hintStyle: AppText.caption.copyWith(
                        color: AppColors.textTertiary,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Color(0xFF36373E)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: AppColors.accent,
                          width: 1.5,
                        ),
                      ),
                      errorBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                      focusedErrorBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: Theme.of(context).colorScheme.error,
                          width: 1.5,
                        ),
                      ),
                    ),
                    dialogTheme: DialogThemeData(
                      backgroundColor: const Color(0xFF1A1B20),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                    bottomSheetTheme: BottomSheetThemeData(
                      backgroundColor: const Color(0xFF1A1B20),
                      showDragHandle: false,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                  ),
                  child: child,
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}

/// Sidebar selection uses a red edge, not a second app-wide navigation dock.
class _WorkspaceDestination extends StatefulWidget {
  const _WorkspaceDestination({
    required this.destination,
    required this.selected,
    required this.compact,
  });

  final DesktopSettingsDestination destination;
  final bool selected;
  final bool compact;

  @override
  State<_WorkspaceDestination> createState() => _WorkspaceDestinationState();
}

/// Keyboard focus remains visible independently of the pointer hover state.
class _WorkspaceDestinationState extends State<_WorkspaceDestination> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.selected || _hovered || _focused;
    final destination = widget.destination;
    final content = AnimatedContainer(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 180),
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: active ? const Color(0xFF251E23) : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        border: Border(
          left: BorderSide(
            color: widget.selected ? AppColors.accent : Colors.transparent,
            width: 3,
          ),
        ),
      ),
      child: Semantics(
        label: widget.compact ? destination.title : null,
        selected: widget.selected,
        button: true,
        child: InkWell(
          key: ValueKey('desktop-nav-${destination.id}'),
          onTap: destination.onOpen,
          onHover: (value) => setState(() => _hovered = value),
          onFocusChange: (value) => setState(() => _focused = value),
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: widget.compact ? 13 : 18,
              vertical: 15,
            ),
            child: Row(
              children: [
                DesktopSettingsIcon(
                  section: destination.id,
                  fallback: destination.icon,
                  color: widget.selected
                      ? AppColors.accent
                      : AppColors.textSecondary,
                  size: 22,
                ),
                if (!widget.compact) ...[
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      destination.title,
                      style: AppText.body.copyWith(
                        color: AppColors.textPrimary,
                        fontWeight: widget.selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    return widget.compact
        ? Tooltip(
            message: destination.title,
            excludeFromSemantics: true,
            child: content,
          )
        : content;
  }
}

/// A desktop settings action inside a shared graphite panel. The full row is
/// clickable, and trailing values remain supplied by their actual state owner.
class DesktopSettingsAction extends StatelessWidget {
  const DesktopSettingsAction({
    super.key,
    required this.title,
    required this.icon,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  final String title;
  final String? subtitle;
  final IconData icon;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: onTap,
      hoverColor: Colors.white.withValues(alpha: 0.035),
      focusColor: AppColors.accent.withValues(alpha: 0.09),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
        child: Row(
          children: [
            ExcludeSemantics(
              child: Icon(icon, color: AppColors.textSecondary, size: 23),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: AppText.body.copyWith(color: AppColors.textPrimary),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 5),
                    Text(
                      subtitle!,
                      style: AppText.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 16),
              Flexible(child: trailing!),
            ],
          ],
        ),
      ),
    ),
  );
}
