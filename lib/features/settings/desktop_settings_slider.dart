import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/desktop_settings_row_target.dart';
import '../../core/ui/desktop_settings_surface.dart';

/// Builds the live "how big is this" sample for a slider value.
typedef DesktopSliderPreviewBuilder =
    Widget Function(BuildContext context, double value);

/// The one Windows settings slider row (the List auto-pause style the user
/// picked): icon, title, the value in the subtitle ("14 days without
/// progress · Default: 15") and a compact stepped slider on the right.
///
/// The value is held locally while dragging and [onChangeEnd] fires once on
/// release, so callers save once instead of writing Hive on every tick.
/// Rows whose effect is visual can pass [preview]; it opens under the row
/// while the slider is dragged (or adjusted with the keyboard) so the size of
/// the change is visible before it is saved.
///
/// Callers use this only on the Windows settings surface; phone and TV keep
/// their existing sliders.
class DesktopSettingsSlider extends StatefulWidget {
  const DesktopSettingsSlider({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.format,
    required this.onChangeEnd,
    this.unit,
    this.defaultValue,
    this.description,
    this.onChanged,
    this.preview,
    this.enabled = true,
    this.sliderKey,
    this.valueKey,
    this.sliderWidth = 240,
  });

  final IconData icon;
  final String title;

  /// Stored value; re-read whenever the caller rebuilds with a new one.
  final double value;
  final double min;
  final double max;

  /// Number of steps between [min] and [max]; values snap onto them.
  final int divisions;

  /// The bare number as shown ("16", "1.6"). Kept apart from [unit] so the
  /// number stays its own text (tests and screen readers can find it).
  final String Function(double value) format;

  /// Unit after the number ("px", "pages", "days without progress").
  /// A callback so it can switch between singular and plural.
  final String Function(double value)? unit;

  /// The shipped default; shown as "Default: 4 pages" so the scale is clear.
  final double? defaultValue;

  /// Optional extra explanation under the value line.
  final String? description;

  /// Live value while dragging (for callers that mirror it elsewhere).
  final ValueChanged<double>? onChanged;

  /// Fires once when the drag (or keyboard step) ends; save here.
  final ValueChanged<double> onChangeEnd;

  /// Live sample shown under the row while the slider is being adjusted.
  final DesktopSliderPreviewBuilder? preview;

  final bool enabled;

  /// Keys kept from the older sliders so existing tests still find them.
  final Key? sliderKey;
  final Key? valueKey;

  /// Slider width on a wide row; narrow rows shrink it (38% of the row).
  final double sliderWidth;

  @override
  State<DesktopSettingsSlider> createState() => _DesktopSettingsSliderState();
}

class _DesktopSettingsSliderState extends State<DesktopSettingsSlider> {
  late double _value = _snap(widget.value);
  bool _dragging = false;
  bool _hovered = false;
  bool _focused = false;

  @override
  void didUpdateWidget(DesktopSettingsSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new stored value (saved, reset, or a controlled caller) wins, but
    // never mid-drag, where it would make the thumb jump back.
    if (!_dragging && oldWidget.value != widget.value) {
      _value = _snap(widget.value);
    }
  }

  /// Rounds onto the step grid and to 2 decimals, so 1.2 + 3 x 0.1 is 1.5
  /// and the saved value is clean (17, not 17.43).
  double _snap(double v) {
    final lo = widget.min;
    final hi = widget.max;
    if (hi <= lo || widget.divisions <= 0) return v.clamp(lo, hi).toDouble();
    final step = (hi - lo) / widget.divisions;
    final steps = ((v.clamp(lo, hi) - lo) / step).round();
    final snapped = lo + steps * step;
    return double.parse(snapped.toStringAsFixed(2)).clamp(lo, hi).toDouble();
  }

  /// "16 px" style text for a value (number plus unit when one is given).
  String _withUnit(double v) {
    final unit = widget.unit?.call(v);
    final number = widget.format(v);
    return unit == null || unit.isEmpty ? number : '$number $unit';
  }

  /// Keyboard focus shows the preview too, but a mouse click that happens
  /// to focus the slider should not leave it open after the release.
  bool get _keyboardFocused =>
      _focused &&
      FocusManager.instance.highlightMode == FocusHighlightMode.traditional;

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    final duration = reduced
        ? Duration.zero
        : const Duration(milliseconds: 160);
    final showPreview =
        widget.preview != null && (_dragging || _keyboardFocused);
    // Search results can reveal this row by its title, like other rows.
    return DesktopSettingsRowTarget(
      title: widget.title,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: AnimatedContainer(
          duration: duration,
          margin: const EdgeInsets.all(4),
          // Same hover tint and focus ring as GraphiteSettingsControl rows.
          decoration: BoxDecoration(
            color: _hovered || _focused
                ? GraphiteSettingsColors.rowHover
                : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: _keyboardFocused ? AppColors.accent : Colors.transparent,
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              LayoutBuilder(
                builder: (context, constraints) => Row(
                  children: [
                    Icon(
                      widget.icon,
                      color: widget.enabled
                          ? AppColors.textSecondary
                          : AppColors.textTertiary,
                      size: 23,
                    ),
                    const SizedBox(width: 18),
                    Expanded(child: _labels()),
                    const SizedBox(width: 14),
                    SizedBox(
                      width: widget.sliderWidth.clamp(
                        0.0,
                        constraints.maxWidth * 0.38,
                      ),
                      child: _slider(context),
                    ),
                  ],
                ),
              ),
              // The explanation spans the row's full width (under the title
              // and the slider), so a narrow dialog does not stack it into a
              // tall column beside the slider.
              if (widget.description != null)
                Padding(
                  padding: const EdgeInsetsDirectional.only(start: 41, top: 6),
                  child: Text(
                    widget.description!,
                    style: AppText.caption.copyWith(
                      color: AppColors.textSecondary,
                      height: 1.45,
                    ),
                  ),
                ),
              // The live sample slides open under the row while adjusting.
              AnimatedSize(
                duration: duration,
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: showPreview
                    ? Padding(
                        key: const ValueKey('desktop-slider-preview'),
                        padding: const EdgeInsetsDirectional.only(
                          start: 41,
                          top: 12,
                        ),
                        child: _PreviewFrame(
                          child: widget.preview!(context, _value),
                        ),
                      )
                    : const SizedBox(width: double.infinity),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Title, then "value unit · Default: x unit".
  Widget _labels() {
    final unit = widget.unit?.call(_value);
    final caption = AppText.caption.copyWith(
      color: AppColors.textSecondary,
      height: 1.45,
    );
    final def = widget.defaultValue;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.title,
          style: AppText.body.copyWith(
            color: widget.enabled
                ? AppColors.textPrimary
                : AppColors.textSecondary,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 5),
        // Wrap so a long unit plus the default never overflows a narrow row.
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            // The number on its own, slightly brighter, as in the reference.
            Text(
              widget.format(_value),
              key: widget.valueKey,
              style: caption.copyWith(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            if (unit != null && unit.isNotEmpty) Text(' $unit', style: caption),
            if (def != null)
              Text(
                '  ·  Default: ${_withUnit(_snap(def))}',
                style: caption.copyWith(color: AppColors.textTertiary),
              ),
          ],
        ),
      ],
    );
  }

  /// The compact discrete slider (dotted tick track) from the reference.
  Widget _slider(BuildContext context) {
    // Ticks under ~4px apart turn into a grey smear; drop them on dense
    // ranges (font size, MegaSkip seconds) and keep the plain track.
    final dense = widget.divisions > 60;
    return Focus(
      // Tracks the slider's own focus; this node never takes focus itself.
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (f) => setState(() => _focused = f),
      child: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          activeTrackColor: AppColors.accent,
          thumbColor: AppColors.accent,
          overlayColor: AppColors.accent.withValues(alpha: 0.16),
          valueIndicatorColor: GraphiteSettingsColors.rowHover,
          activeTickMarkColor: dense ? Colors.transparent : null,
          inactiveTickMarkColor: dense ? Colors.transparent : null,
        ),
        child: Slider(
          key: widget.sliderKey,
          min: widget.min,
          max: widget.max,
          divisions: widget.divisions,
          value: _value,
          label: _withUnit(_value),
          activeColor: AppColors.accent,
          semanticFormatterCallback: _withUnit,
          onChangeStart: widget.enabled
              ? (_) => setState(() => _dragging = true)
              : null,
          onChanged: widget.enabled
              ? (v) {
                  final snapped = _snap(v);
                  setState(() => _value = snapped);
                  widget.onChanged?.call(snapped);
                }
              : null,
          onChangeEnd: widget.enabled
              ? (v) {
                  final snapped = _snap(v);
                  setState(() {
                    _value = snapped;
                    _dragging = false;
                  });
                  widget.onChangeEnd(snapped);
                }
              : null,
        ),
      ),
    );
  }
}

/// Rounded graphite box the live samples sit in.
class _PreviewFrame extends StatelessWidget {
  const _PreviewFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: GraphiteSettingsColors.inputFill,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: GraphiteSettingsColors.panelEdge),
    ),
    child: child,
  );
}

/// Ready-made live samples for the size-type settings.
abstract final class DesktopSliderPreviews {
  static const String _sample =
      'The quick brown fox jumps over the lazy dog. Pack my box with five '
      'dozen liquor jugs.';

  /// "Aa" plus a sample line at [fontSize] logical pixels.
  static Widget fontSize(double fontSize) => Row(
    key: const ValueKey('preview-font-size'),
    crossAxisAlignment: CrossAxisAlignment.baseline,
    textBaseline: TextBaseline.alphabetic,
    children: [
      Text(
        'Aa',
        style: TextStyle(
          fontSize: fontSize,
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Text(
          'The quick brown fox',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: fontSize, color: AppColors.textSecondary),
        ),
      ),
    ],
  );

  /// Three lines of body text spaced at [height] (a line-height multiplier).
  /// Held to a narrow column so the sample really wraps onto 3 lines on a
  /// wide settings page (one long line would hide the spacing).
  static Widget lineHeight(double height) => Align(
    alignment: AlignmentDirectional.centerStart,
    child: SizedBox(
      width: 260,
      child: Text(
        _sample,
        key: const ValueKey('preview-line-height'),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 13,
          height: height,
          color: AppColors.textSecondary,
        ),
      ),
    ),
  );

  /// A page outline with text inset by [margin] pixels on each side.
  /// Aligned so the 260px page keeps its width inside the stretched frame
  /// (a tight parent would otherwise widen it and shrink the visible inset).
  static Widget margin(double margin) => Align(
    alignment: AlignmentDirectional.centerStart,
    child: _marginPage(margin),
  );

  static Widget _marginPage(double margin) => Container(
    key: const ValueKey('preview-margin'),
    width: 260,
    padding: EdgeInsets.symmetric(horizontal: margin, vertical: 8),
    decoration: BoxDecoration(
      border: Border.all(color: AppColors.textTertiary),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      _sample,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
    ),
  );

  /// Two short paragraphs with a [spacing] pixel gap between them.
  static Widget paragraphSpacing(double spacing) {
    const style = TextStyle(fontSize: 11, color: AppColors.textSecondary);
    return Column(
      key: const ValueKey('preview-paragraph-spacing'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(_sample, maxLines: 2, style: style),
        SizedBox(height: spacing),
        const Text(_sample, maxLines: 2, style: style),
      ],
    );
  }
}
