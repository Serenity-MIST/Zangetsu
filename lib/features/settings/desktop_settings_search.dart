import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';

/// Windows search surface with a persistent label and animated focus outline.
/// Search state stays with the settings controller so navigating back preserves
/// the query; this widget owns only transient visual focus.
class DesktopSettingsSearch extends StatefulWidget {
  const DesktopSettingsSearch({
    super.key,
    required this.controller,
    required this.hint,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  State<DesktopSettingsSearch> createState() => _DesktopSettingsSearchState();
}

/// Focus styling never replaces or recreates the editable field itself.
class _DesktopSettingsSearchState extends State<DesktopSettingsSearch> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
    child: Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (value) => setState(() => _focused = value),
      child: AnimatedContainer(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: const Color(0xFF14141C),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: _focused ? AppColors.accent : const Color(0xFF30303A),
          ),
          boxShadow: [
            if (_focused)
              BoxShadow(
                color: AppColors.accent.withValues(alpha: 0.07),
                blurRadius: 16,
              ),
          ],
        ),
        child: Row(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SvgPicture.asset(
                'assets/icons/lucide/search.svg',
                width: 18,
                height: 18,
                excludeFromSemantics: true,
                colorFilter: ColorFilter.mode(
                  _focused ? AppColors.accent : AppColors.textSecondary,
                  BlendMode.srcIn,
                ),
              ),
            ),
            Expanded(
              child: TextField(
                controller: widget.controller,
                onChanged: widget.onChanged,
                style: AppText.body.copyWith(color: AppColors.textPrimary),
                cursorColor: AppColors.accent,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: widget.hint,
                  hintStyle: AppText.body.copyWith(
                    color: AppColors.textSecondary,
                  ),
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 15),
                ),
              ),
            ),
            if (widget.controller.text.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: IconButton(
                  tooltip: MaterialLocalizations.of(
                    context,
                  ).clearButtonTooltip,
                  onPressed: widget.onClear,
                  icon: const Icon(Icons.close_rounded, size: 18),
                  color: AppColors.textSecondary,
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
