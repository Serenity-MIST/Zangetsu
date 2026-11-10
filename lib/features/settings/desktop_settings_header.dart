import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';

/// Single desktop settings title bar, shared by hub and category destinations.
/// It provides app navigation only; native window chrome stays responsible for
/// moving, resizing and closing the Windows window.
class DesktopSettingsHeader extends StatelessWidget
    implements PreferredSizeWidget {
  const DesktopSettingsHeader(
    this.title, {
    super.key,
    required this.showBack,
    required this.onBack,
  });

  final String title;
  final bool showBack;
  final VoidCallback onBack;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xFF101016),
    child: Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFF25252E))),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: SizedBox(
        height: kToolbarHeight,
        child: Row(
          children: [
            if (showBack) ...[
              IconButton.filledTonal(
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                onPressed: onBack,
                style: IconButton.styleFrom(
                  backgroundColor: const Color(0xFF22222C),
                  foregroundColor: AppColors.textPrimary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: const Icon(Icons.arrow_back_rounded, size: 20),
              ),
              const SizedBox(width: 14),
            ],
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.body.copyWith(
                    color: AppColors.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.4,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
