import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

import '../desktop/desktop_chrome_colors.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import 'desktop_docked_panel.dart' show DesktopPanelColors;
import 'desktop_settings_row_target.dart';
import '../../l10n/l10n.dart';

/// set-4: widest a settings content column grows, like Windows 11 Settings.
/// On a 1440p or ultrawide window a label would otherwise sit 1,500px from
/// its switch. Panels inside the settings workspace stay left-aligned at this
/// width; narrower windows are unaffected.
const double kDesktopSettingsContentMaxWidth = 920;

/// set-9: settings surface colours derived from the desktop frame colour.
///
/// These used to be fixed greys, so Pure black showed grey boxes on black and
/// a tinted Background looked like another theme. With the stock background
/// every getter returns the exact original grey, so an untouched install
/// looks the same; otherwise each is a small lift of [DesktopChrome.frame],
/// the way the sidebar selection already follows it.
abstract final class GraphiteSettingsColors {
  /// True while the background is the shipped default.
  static bool get _stock =>
      AppColors.bg.toARGB32() == AppColors.defaultBg.toARGB32();

  /// Lifts [DesktopChrome.frame] towards white by [amount].
  static Color _lift(double amount) =>
      Color.lerp(DesktopChrome.frame, Colors.white, amount)!;

  /// Panel fill gradient (top-left to bottom-right).
  static List<Color> get panelGradient => _stock
      ? const [Color(0xFF1B1C20), Color(0xFF141519)]
      : [_lift(.05), _lift(.025)];

  /// Panel border and the dividers between its rows.
  static Color get panelEdge => _stock ? const Color(0xFF303137) : _lift(.13);

  /// Row hover / focus fill: the accent over the panel, as the sidebar does.
  static Color get rowHover => _stock
      ? const Color(0xFF29252C)
      : Color.alphaBlend(AppColors.accent.withValues(alpha: .08), _lift(.06));

  /// Dialog fill and border (the shared desktop panel colours).
  static Color get dialog => DesktopPanelColors.surface;
  static Color get dialogEdge => DesktopPanelColors.edge;

  /// Search box fill and resting border.
  static Color get searchFill => _stock ? const Color(0xFF14141C) : _lift(.03);
  static Color get searchEdge => _stock ? const Color(0xFF30303A) : _lift(.13);

  /// Text field fill and hover inside settings pages (border: [dialogEdge]).
  static Color get inputFill => _stock ? const Color(0xFF17181D) : _lift(.04);
  static Color get inputHover => _stock ? const Color(0xFF25262D) : _lift(.08);
}

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
  Widget build(BuildContext context) {
    final edge = GraphiteSettingsColors.panelEdge;
    final panel = Container(
      margin: margin,
      decoration: BoxDecoration(
        // set-9: follows Pure black / Background colour.
        gradient: LinearGradient(colors: GraphiteSettingsColors.panelGradient),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: edge),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              Divider(height: 1, indent: 22, endIndent: 22, color: edge),
            children[i],
          ],
        ],
      ),
    );
    // set-4: inside the settings workspace, cap the panel at the shared
    // content width and keep it left-aligned. Panels elsewhere (Sources
    // pages, dialogs) keep their full width.
    if (!DesktopSettingsScope.contains(context)) return panel;
    final resolved = margin.resolve(Directionality.maybeOf(context));
    return Align(
      alignment: AlignmentDirectional.topStart,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: kDesktopSettingsContentMaxWidth + resolved.horizontal,
        ),
        // Fill up to the cap: Align loosens the width, and a panel whose
        // rows have no stretching child would otherwise shrink to them.
        child: SizedBox(width: double.infinity, child: panel),
      ),
    );
  }
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
  Widget build(BuildContext context) =>
      // set-2: every row can be revealed by a settings search result that
      // names its title (scroll into view, accent flash, keyboard focus).
      DesktopSettingsRowTarget(title: widget.title, child: _buildRow(context));

  Widget _buildRow(BuildContext context) {
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
          // set-9: hover follows the accent and frame colour.
          color: active ? GraphiteSettingsColors.rowHover : Colors.transparent,
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
    // set-9: dialog colours follow the frame.
    backgroundColor: GraphiteSettingsColors.dialog,
    insetPadding: const EdgeInsets.all(24),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      side: BorderSide(color: GraphiteSettingsColors.dialogEdge),
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
            Divider(height: 1, color: GraphiteSettingsColors.dialogEdge),
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
      // set-9: dialog colours follow the frame.
      backgroundColor: GraphiteSettingsColors.dialog,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: GraphiteSettingsColors.dialogEdge),
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
              Divider(height: 1, color: GraphiteSettingsColors.dialogEdge),
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
      // set-9: dialog colours follow the frame.
      backgroundColor: GraphiteSettingsColors.dialog,
      surfaceTintColor: Colors.transparent,
      constraints: const BoxConstraints(maxWidth: 480),
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: GraphiteSettingsColors.dialogEdge),
      ),
      scrollable: false,
      title: Text(title, style: AppText.headline.copyWith(fontSize: 23)),
      content: SizedBox(
        width: 360,
        child: LayoutBuilder(
          builder: (_, constraints) => SingleChildScrollView(
            // set-5: the wheel plus a hex field (type or paste '#E50914')
            // that always shows the value being picked.
            child: GraphiteColorPickerBody(
              initial: current,
              width: constraints.maxWidth,
              onChanged: (color) => selected = color,
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

/// Reads a typed or pasted colour: '#E50914', 'E50914', '#E09', 'E09' or an
/// opaque '0xFFE50914' / 'FFE50914'. Alpha is ignored (pickers are opaque).
/// Returns null for anything else.
Color? parseHexColor(String input) {
  var s = input.trim().replaceAll(RegExp(r'\s+'), '');
  if (s.startsWith('#')) s = s.substring(1);
  if (s.toLowerCase().startsWith('0x')) s = s.substring(2);
  if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(s)) return null;
  if (s.length == 3) s = s.split('').map((c) => '$c$c').join();
  if (s.length == 8) s = s.substring(2);
  if (s.length != 6) return null;
  return Color(0xFF000000 | int.parse(s, radix: 16));
}

/// '#RRGGBB' for [color], upper case, alpha dropped.
String formatHexColor(Color color) =>
    '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

/// set-5: the hue wheel with a hex field under it. The field shows the
/// current value as the wheel moves, accepts a typed value, and has a Paste
/// button, so keyboard users can set a colour without the wheel. The caller
/// owns the dialog and what Apply does; [onChanged] reports every change.
class GraphiteColorPickerBody extends StatefulWidget {
  const GraphiteColorPickerBody({
    super.key,
    required this.initial,
    required this.onChanged,
    this.width = 300,
  });

  final Color initial;
  final ValueChanged<Color> onChanged;

  /// Width the wheel draws at.
  final double width;

  @override
  State<GraphiteColorPickerBody> createState() =>
      _GraphiteColorPickerBodyState();
}

class _GraphiteColorPickerBodyState extends State<GraphiteColorPickerBody> {
  late Color _color = widget.initial;

  // The wheel's own HSV value. The picker rebuilds from this rather than from
  // [_color], because a Color loses the hue at zero brightness/saturation and
  // the wheel would snap back to red while dragging to black or white.
  late HSVColor _hsv = HSVColor.fromColor(widget.initial);
  late final TextEditingController _hex = TextEditingController(
    text: formatHexColor(widget.initial),
  );
  bool _invalid = false;

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  /// The wheel moved: show its value in the field.
  void _fromWheel(Color color) {
    setState(() {
      _color = color;
      _invalid = false;
    });
    final text = formatHexColor(color);
    if (_hex.text != text) {
      _hex.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
    widget.onChanged(color);
  }

  /// Typed or pasted text: apply it to the wheel when it is a full colour.
  void _fromText(String text, {bool reformat = false}) {
    final color = parseHexColor(text);
    if (color == null) {
      // Half-typed values are fine while typing; only flag on submit/paste.
      if (reformat) setState(() => _invalid = true);
      return;
    }
    setState(() {
      _color = color;
      // A typed colour moves the wheel to it.
      _hsv = HSVColor.fromColor(color);
      _invalid = false;
    });
    if (reformat) {
      final formatted = formatHexColor(color);
      _hex.value = TextEditingValue(
        text: formatted,
        selection: TextSelection.collapsed(offset: formatted.length),
      );
    }
    widget.onChanged(color);
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final text = (data?.text ?? '').trim();
    // Show what was pasted (cut to the field's length) so a bad paste can be
    // seen next to its error; a valid one is reformatted by _fromText.
    _hex.text = text.length > 10 ? text.substring(0, 10) : text;
    _fromText(text, reformat: true);
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ColorPicker(
        // Package landscape mode uses the window orientation rather than
        // dialog width and overflows. Its vertical layout respects bounds.
        portraitOnly: true,
        colorPickerWidth: widget.width,
        pickerColor: _color,
        pickerHsvColor: _hsv,
        onColorChanged: _fromWheel,
        // Called right after onColorChanged; keeps the exact hue (see _hsv).
        onHsvColorChanged: (hsv) => _hsv = hsv,
        enableAlpha: false,
        displayThumbColor: true,
        paletteType: PaletteType.hueWheel,
        labelTypes: const [],
        pickerAreaBorderRadius: BorderRadius.circular(12),
      ),
      const SizedBox(height: 4),
      Row(
        children: [
          // Swatch of the value being picked.
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: _color,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: GraphiteSettingsColors.dialogEdge),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              key: const ValueKey('graphite-hex-field'),
              controller: _hex,
              onChanged: _fromText,
              onSubmitted: (text) => _fromText(text, reformat: true),
              maxLength: 10,
              style: AppText.body.copyWith(
                color: AppColors.textPrimary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
              cursorColor: AppColors.accent,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[#0-9a-fA-FxX ]')),
              ],
              decoration: InputDecoration(
                labelText: context.l10n.colourHex,
                counterText: '',
                isDense: true,
                errorText: _invalid
                    ? context.l10n.enterColourLike('#E50914')
                    : null,
                filled: true,
                fillColor: GraphiteSettingsColors.inputFill,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(
                    color: GraphiteSettingsColors.dialogEdge,
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: AppColors.accent, width: 1.5),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            tooltip: context.l10n.pasteColour,
            onPressed: _paste,
            icon: const Icon(Icons.content_paste_rounded, size: 20),
            color: AppColors.textSecondary,
          ),
        ],
      ),
    ],
  );
}
