import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

import '../theme/app_colors.dart';
import '../theme/app_text.dart';

/// Marks the Windows settings content navigator. Shared controls opt into the
/// desktop design only here, leaving mobile, TV and unrelated app pages alone.
class DesktopSettingsScope extends InheritedWidget {
  const DesktopSettingsScope({super.key, required super.child});

  static bool contains(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DesktopSettingsScope>() !=
      null;

  @override
  bool updateShouldNotify(DesktopSettingsScope oldWidget) => false;
}

/// Rounded graphite grouping for nested desktop settings, matching the
/// supplied reference rather than individual phone-style preference cards.
class GraphiteSettingsPanel extends StatelessWidget {
  const GraphiteSettingsPanel({
    super.key,
    required this.children,
    this.margin = const EdgeInsets.symmetric(horizontal: 22),
  });

  final List<Widget> children;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) => Container(
    margin: margin,
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        colors: [Color(0xFF1B1C20), Color(0xFF141519)],
      ),
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: const Color(0xFF303137)),
    ),
    clipBehavior: Clip.antiAlias,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0)
            const Divider(
              height: 1,
              indent: 22,
              endIndent: 22,
              color: Color(0xFF303137),
            ),
          children[i],
        ],
      ],
    ),
  );
}

/// A new desktop preference row with full labels and bounded value controls.
/// Taps and trailing widgets belong to their existing state/service owners.
class GraphiteSettingsControl extends StatefulWidget {
  const GraphiteSettingsControl({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.leading,
    this.onTap,
    this.destructive = false,
    this.previewFontFamily,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget? leading;
  final VoidCallback? onTap;
  final bool destructive;

  /// Loaded font used by font choices only; unfetched families stay unset.
  final String? previewFontFamily;

  @override
  State<GraphiteSettingsControl> createState() =>
      _GraphiteSettingsControlState();
}

/// Focus and hover remain independent, with no motion when it is disabled.
class _GraphiteSettingsControlState extends State<GraphiteSettingsControl> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final active = _hovered || _focused;
    final reduced = MediaQuery.disableAnimationsOf(context);
    final duration = reduced
        ? Duration.zero
        : const Duration(milliseconds: 160);
    return AnimatedScale(
      scale: active && !reduced ? 1.008 : 1,
      duration: duration,
      curve: Curves.easeOutCubic,
      child: AnimatedContainer(
        duration: duration,
        margin: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF29252C) : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: _focused ? AppColors.accent : Colors.transparent,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.onTap,
            onHover: (value) => setState(() => _hovered = value),
            onFocusChange: (value) => setState(() => _focused = value),
            child: LayoutBuilder(
              builder: (context, constraints) => Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 16,
                ),
                child: Row(
                  children: [
                    ExcludeSemantics(
                      child:
                          widget.leading ??
                          Icon(
                            widget.icon,
                            color: widget.destructive
                                ? AppColors.accent
                                : AppColors.textSecondary,
                            size: 23,
                          ),
                    ),
                    const SizedBox(width: 18),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.title,
                            style: AppText.body.copyWith(
                              fontFamily: widget.previewFontFamily,
                              color: widget.destructive
                                  ? AppColors.accent
                                  : AppColors.textPrimary,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          if (widget.subtitle != null) ...[
                            const SizedBox(height: 5),
                            Text(
                              widget.subtitle!,
                              style: AppText.caption.copyWith(
                                fontFamily: widget.previewFontFamily,
                                color: AppColors.textSecondary,
                                height: 1.45,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (widget.trailing != null) ...[
                      const SizedBox(width: 14),
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: constraints.maxWidth * 0.38,
                        ),
                        child: widget.trailing!,
                      ),
                    ],
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

/// Desktop value selection uses a bounded, centered rounded dialog. The caller
/// owns persistence; cancellation returns null and never changes a preference.
Future<T?> showGraphiteSettingsChoice<T>(
  BuildContext context, {
  required String title,
  required List<(T, String)> options,
  required T current,
  String? description,
  Map<T, String> optionDescriptions = const {},
  Map<T, String> previewFontFamilies = const {},
  Set<T> downloadableOptions = const {},
}) => showDialog<T>(
  context: context,
  useRootNavigator: false,
  builder: (dialogContext) => Dialog(
    backgroundColor: const Color(0xFF1A1B20),
    insetPadding: const EdgeInsets.all(24),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      side: const BorderSide(color: Color(0xFF36373E)),
    ),
    clipBehavior: Clip.antiAlias,
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: 520,
        maxHeight: MediaQuery.sizeOf(dialogContext).height * 0.8,
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: AppText.headline.copyWith(
                      fontSize: 22,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: MaterialLocalizations.of(
                    dialogContext,
                  ).closeButtonTooltip,
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  icon: const Icon(Icons.close_rounded),
                  color: AppColors.textSecondary,
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (description != null) ...[
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  description,
                  style: AppText.caption.copyWith(
                    color: AppColors.textSecondary,
                    height: 1.45,
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
            const Divider(height: 1, color: Color(0xFF36373E)),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final (value, label) in options)
                    Semantics(
                      checked: value == current,
                      inMutuallyExclusiveGroup: true,
                      child: GraphiteSettingsControl(
                        icon: value == current
                            ? Icons.radio_button_checked_rounded
                            : Icons.radio_button_unchecked_rounded,
                        title: label,
                        subtitle: optionDescriptions[value],
                        previewFontFamily: previewFontFamilies[value],
                        // Keep download availability visible without fetching a
                        // font merely to display the picker.
                        trailing:
                            value != current &&
                                downloadableOptions.contains(value)
                            ? const Icon(Icons.download_outlined, size: 18)
                            : null,
                        onTap: () => Navigator.of(dialogContext).pop(value),
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
);

/// Multi-selection for settings that already save on dismissal. The caller
/// retains the working set and persists it in its existing canonical order.
/// There is deliberately no Cancel label implying that edits are discarded.
Future<void> showGraphiteSettingsMultiChoice<T>(
  BuildContext context, {
  required String title,
  required String description,
  required List<(T, String)> options,
  required Set<T> selected,
}) => showDialog<void>(
  context: context,
  useRootNavigator: false,
  builder: (dialogContext) => StatefulBuilder(
    builder: (context, update) => Dialog(
      backgroundColor: const Color(0xFF1A1B20),
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: Color(0xFF36373E)),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 520,
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: AppText.headline.copyWith(fontSize: 22),
                    ),
                  ),
                  IconButton(
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(description, style: AppText.caption),
              const SizedBox(height: 16),
              const Divider(height: 1, color: Color(0xFF36373E)),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final (value, label) in options)
                      Semantics(
                        checked: selected.contains(value),
                        child: GraphiteSettingsControl(
                          icon: selected.contains(value)
                              ? Icons.check_box_outlined
                              : Icons.check_box_outline_blank,
                          title: label,
                          onTap: () => update(() {
                            if (!selected.add(value)) selected.remove(value);
                          }),
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
);

/// Bounded desktop color editing shared by accent and reader appearance.
/// Cancel returns null; callers own persistence and profile/service updates.
Future<Color?> showGraphiteSettingsColorChoice(
  BuildContext context, {
  required String title,
  required Color current,
  required String applyLabel,
}) {
  var selected = current;
  return showDialog<Color>(
    context: context,
    useRootNavigator: false,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: const Color(0xFF1A1B20),
      surfaceTintColor: Colors.transparent,
      constraints: const BoxConstraints(maxWidth: 480),
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: Color(0xFF36373E)),
      ),
      scrollable: false,
      title: Text(title, style: AppText.headline.copyWith(fontSize: 23)),
      content: SizedBox(
        width: 360,
        child: LayoutBuilder(
          builder: (_, constraints) => SingleChildScrollView(
            child: ColorPicker(
              // Package landscape mode uses the window orientation rather than
              // dialog width and overflows. Its vertical layout respects bounds.
              portraitOnly: true,
              colorPickerWidth: constraints.maxWidth,
              pickerColor: current,
              onColorChanged: (color) => selected = color,
              enableAlpha: false,
              displayThumbColor: true,
              paletteType: PaletteType.hueWheel,
              labelTypes: const [],
              pickerAreaBorderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(
            MaterialLocalizations.of(dialogContext).cancelButtonLabel,
          ),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(selected),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.accent,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          child: Text(applyLabel),
        ),
      ],
    ),
  );
}
