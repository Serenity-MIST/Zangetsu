import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import 'desktop_settings_icon.dart';
import 'desktop_settings_motion.dart';

/// Presentation data supplied by the existing settings entry catalogue.
class DesktopSettingsCategory {
  const DesktopSettingsCategory({
    required this.id,
    required this.title,
    required this.summary,
    required this.icon,
    required this.onOpen,
  });

  final String id;
  final String title;
  final String summary;
  final IconData icon;
  final VoidCallback onOpen;
}

/// Non-scrolling category cards inside the hub's single existing scroll view.
///
/// Wrap lets descriptions grow with text scaling instead of clipping them to
/// a fixed grid aspect ratio. Each card retains the original category handler.
class DesktopSettingsCategoryGrid extends StatelessWidget {
  const DesktopSettingsCategoryGrid({super.key, required this.categories});

  final List<DesktopSettingsCategory> categories;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
    child: LayoutBuilder(
      builder: (context, constraints) {
        const gap = 12.0;
        final columns = (constraints.maxWidth / 300).floor().clamp(1, 3);
        final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final category in categories)
              SizedBox(
                width: width,
                child: _DesktopCategoryDestination(category: category),
              ),
          ],
        );
      },
    ),
  );
}

/// A desktop destination surface with its own visual interaction states.
/// The route callback remains independent of the presentation and animations.
class _DesktopCategoryDestination extends StatefulWidget {
  const _DesktopCategoryDestination({required this.category});

  final DesktopSettingsCategory category;

  @override
  State<_DesktopCategoryDestination> createState() =>
      _DesktopCategoryDestinationState();
}

/// Pointer and keyboard focus share a visual language without sharing state.
class _DesktopCategoryDestinationState
    extends State<_DesktopCategoryDestination> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final category = widget.category;
    final active = _hovered || _focused;
    final reduced = MediaQuery.disableAnimationsOf(context);
    final duration = reduced
        ? Duration.zero
        : const Duration(milliseconds: 180);
    final radius = BorderRadius.circular(20);
    return DesktopSettingsMotion(
      child: Semantics(
        button: true,
        child: AnimatedContainer(
          duration: duration,
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            borderRadius: radius,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                active ? const Color(0xFF29252D) : const Color(0xFF1C1C24),
                active ? const Color(0xFF1C171F) : const Color(0xFF111116),
              ],
            ),
            border: Border.all(
              color: _focused
                  ? AppColors.accent
                  : active
                  ? AppColors.accent.withValues(alpha: 0.48)
                  : const Color(0xFF30303A),
              width: _focused ? 1.5 : 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: active ? 0.30 : 0.12),
                blurRadius: active ? 22 : 8,
                offset: Offset(0, active ? 8 : 2),
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: radius,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: ValueKey('desktop-settings-${category.id}'),
              onTap: category.onOpen,
              onHover: (value) => setState(() => _hovered = value),
              onFocusChange: (value) => setState(() => _focused = value),
              hoverColor: Colors.transparent,
              focusColor: Colors.transparent,
              splashColor: AppColors.accent.withValues(alpha: 0.10),
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        AnimatedContainer(
                          duration: duration,
                          padding: const EdgeInsets.all(9),
                          decoration: BoxDecoration(
                            color: AppColors.accent.withValues(
                              alpha: active ? 0.16 : 0.08,
                            ),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: DesktopSettingsIcon(
                            section: category.id,
                            fallback: category.icon,
                            color: AppColors.accent,
                            size: 22,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(
                      category.title,
                      style: AppText.body.copyWith(
                        color: AppColors.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.25,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      category.summary,
                      style: AppText.caption.copyWith(
                        color: AppColors.textSecondary,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
