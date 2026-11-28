import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/desktop_settings_surface.dart';
import 'desktop_settings_motion.dart';
import 'desktop_settings_workspace.dart';

/// Desktop profile destination; live account/profile state is supplied by its
/// owner, so presentation cannot modify or duplicate account persistence.
class DesktopSettingsProfile extends StatelessWidget {
  const DesktopSettingsProfile({
    super.key,
    required this.avatar,
    required this.title,
    required this.subtitle,
    required this.onOpen,
  });

  final Widget avatar;
  final String title;
  final String subtitle;
  final VoidCallback onOpen;

  /// True while the background is the shipped default: keep the original
  /// plum-tinted greys exactly.
  static bool get _stock =>
      AppColors.bg.toARGB32() == AppColors.defaultBg.toARGB32();

  /// Card fill: the accent over the settings panel colours.
  static List<Color> get _gradient => _stock
      ? const [Color(0xFF241B25), Color(0xFF15151D)]
      : [
          Color.alphaBlend(
            AppColors.accent.withValues(alpha: .08),
            GraphiteSettingsColors.panelGradient.first,
          ),
          GraphiteSettingsColors.panelGradient.last,
        ];

  /// Card border: a faint accent edge over the panel edge.
  static Color get _edge => _stock
      ? const Color(0xFF3C2D3A)
      : Color.alphaBlend(
          AppColors.accent.withValues(alpha: .18),
          GraphiteSettingsColors.panelEdge,
        );

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    // Same left edge and width as the panels under it.
    child: DesktopSettingsColumn(
      child: DesktopSettingsMotion(
        child: Semantics(
          button: true,
          child: DecoratedBox(
            decoration: BoxDecoration(
              // set-9: accent-tinted card that follows Pure black / Background.
              gradient: LinearGradient(colors: _gradient),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: _edge),
            ),
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(20),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onOpen,
                hoverColor: AppColors.accent.withValues(alpha: 0.06),
                focusColor: AppColors.accent.withValues(alpha: 0.12),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 14,
                  ),
                  child: Row(
                    children: [
                      ExcludeSemantics(child: avatar),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: AppText.body.copyWith(
                                color: AppColors.textPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              subtitle,
                              style: AppText.caption.copyWith(
                                color: AppColors.textSecondary,
                                height: 1.4,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
