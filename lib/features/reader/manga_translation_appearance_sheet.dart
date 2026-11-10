import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

import '../../core/reading/reader_prefs.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/desktop_settings_surface.dart';
import '../../l10n/l10n.dart';

/// Translation appearance state shared by the mobile sheet and a separately
/// composed desktop editor; both retain the same preference ownership.
class MangaTranslationAppearanceSheet extends StatefulWidget {
  const MangaTranslationAppearanceSheet({super.key, required this.prefs});

  final ReaderPrefs prefs;

  @override
  State<MangaTranslationAppearanceSheet> createState() =>
      _MangaTranslationAppearanceSheetState();
}

class _MangaTranslationAppearanceSheetState
    extends State<MangaTranslationAppearanceSheet> {
  late double _fontSize;
  late double _backgroundOpacity;
  late Color _textColor;
  late Color _backgroundColor;

  @override
  void initState() {
    super.initState();
    _fontSize = widget.prefs.mangaTranslationFontSize;
    _backgroundOpacity = widget.prefs.mangaTranslationBackgroundOpacity;
    _textColor = widget.prefs.mangaTranslationTextColor;
    _backgroundColor = widget.prefs.mangaTranslationBackgroundColor;
  }

  Future<void> _pickColor({required bool textColor}) async {
    final initialColor = textColor ? _textColor : _backgroundColor;
    var pickedColor = initialColor;
    final l10n = context.l10n;
    final desktop = DesktopSettingsScope.contains(context);
    // The color wheel assumes 300px by default. Size it to the dialog's real
    // content constraints, including narrow desktop windows and text scaling.
    Widget picker(double width) => SingleChildScrollView(
      child: ColorPicker(
        colorPickerWidth: width,
        // The package selects a wide two-column layout from the WINDOW's
        // orientation, even inside a narrow dialog. Keep its vertical layout.
        portraitOnly: desktop,
        pickerColor: initialColor,
        onColorChanged: (color) => pickedColor = color,
        enableAlpha: false,
        displayThumbColor: true,
        paletteType: PaletteType.hueWheel,
        labelTypes: const [],
        pickerAreaBorderRadius: BorderRadius.circular(12),
      ),
    );
    final result = desktop
        ? await showGraphiteSettingsColorChoice(
            context,
            title: l10n.customColour,
            current: initialColor,
            applyLabel: l10n.apply,
          )
        : await showDialog<Color>(
            context: context,
            useRootNavigator: !DesktopSettingsScope.contains(context),
            builder: (dialogContext) => AlertDialog(
              backgroundColor: AppColors.surface,
              title: Text(l10n.customColour, style: AppText.headline),
              content: desktop
                  ? SizedBox(
                      width: 360,
                      child: LayoutBuilder(
                        builder: (_, constraints) =>
                            picker(constraints.maxWidth),
                      ),
                    )
                  : picker(300),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: Text(
                    l10n.cancel,
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, pickedColor),
                  child: Text(
                    l10n.apply,
                    style: TextStyle(color: AppColors.accent),
                  ),
                ),
              ],
            ),
          );
    if (result == null || !mounted) return;

    setState(() {
      if (textColor) {
        _textColor = result;
      } else {
        _backgroundColor = result;
      }
    });
    if (textColor) {
      await widget.prefs.setMangaTranslationTextColor(result);
    } else {
      await widget.prefs.setMangaTranslationBackgroundColor(result);
    }
  }

  Future<void> _reset() async {
    setState(() {
      _fontSize = ReaderPrefs.defaultMangaTranslationFontSize;
      _textColor = ReaderPrefs.defaultMangaTranslationTextColor;
      _backgroundColor = ReaderPrefs.defaultMangaTranslationBackgroundColor;
      _backgroundOpacity = ReaderPrefs.defaultMangaTranslationBackgroundOpacity;
    });
    await Future.wait([
      widget.prefs.setMangaTranslationFontSize(_fontSize),
      widget.prefs.setMangaTranslationTextColor(_textColor),
      widget.prefs.setMangaTranslationBackgroundColor(_backgroundColor),
      widget.prefs.setMangaTranslationBackgroundOpacity(_backgroundOpacity),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (DesktopSettingsScope.contains(context)) return _desktopEditor(context);
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.textTertiary.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.mangaTranslationAppearance,
                    style: AppText.headline,
                  ),
                ),
                TextButton(
                  onPressed: () => unawaited(_reset()),
                  child: Text(l10n.resetToDefaults),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(l10n.mangaTranslationPreview, style: AppText.caption),
            const SizedBox(height: 8),
            Container(
              key: const ValueKey('manga-translation-appearance-preview'),
              width: double.infinity,
              constraints: const BoxConstraints(minHeight: 64),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _backgroundColor.withValues(alpha: _backgroundOpacity),
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Text(
                l10n.mangaTranslationPreview,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _textColor,
                  fontSize: _fontSize,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 12),
            _colorTile(
              key: const ValueKey('manga-translation-appearance-text-color'),
              title: l10n.textColour,
              color: _textColor,
              onTap: () => _pickColor(textColor: true),
            ),
            _colorTile(
              key: const ValueKey(
                'manga-translation-appearance-background-color',
              ),
              title: l10n.mangaTranslationBackgroundColour,
              color: _backgroundColor,
              onTap: () => _pickColor(textColor: false),
            ),
            _sliderRow(
              key: const ValueKey('manga-translation-appearance-size'),
              title: l10n.fontSize,
              value: _fontSize,
              min: 8,
              max: 32,
              divisions: 24,
              format: (value) => '${value.round()} px',
              onChanged: (value) => setState(() => _fontSize = value),
              onChangeEnd: widget.prefs.setMangaTranslationFontSize,
            ),
            _sliderRow(
              key: const ValueKey('manga-translation-appearance-opacity'),
              title: l10n.mangaTranslationBackgroundOpacity,
              value: _backgroundOpacity,
              min: 0,
              max: 1,
              divisions: 20,
              format: (value) => '${(value * 100).round()}%',
              onChanged: (value) => setState(() => _backgroundOpacity = value),
              onChangeEnd: widget.prefs.setMangaTranslationBackgroundOpacity,
            ),
            const SizedBox(height: 8),
            Text(
              l10n.mangaTranslationAppearanceFitNote,
              style: AppText.caption.copyWith(color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  /// A bounded desktop inspector, with its preview separated from controls.
  /// The containing dialog supplies the viewport; scrolling occurs on overflow.
  Widget _desktopEditor(BuildContext context) {
    final l10n = context.l10n;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.mangaTranslationAppearance,
                  style: AppText.headline.copyWith(fontSize: 23),
                ),
              ),
              IconButton(
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(l10n.mangaTranslationAppearanceSubtitle, style: AppText.caption),
          const SizedBox(height: 20),
          Container(
            key: const ValueKey('manga-translation-appearance-preview'),
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: _backgroundColor.withValues(alpha: _backgroundOpacity),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.hairline),
            ),
            child: Text(
              l10n.mangaTranslationPreview,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _textColor,
                fontSize: _fontSize,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 20),
          GraphiteSettingsPanel(
            margin: EdgeInsets.zero,
            children: [
              _desktopColorControl(
                key: const ValueKey('manga-translation-appearance-text-color'),
                title: l10n.textColour,
                color: _textColor,
                textColor: true,
              ),
              _desktopColorControl(
                key: const ValueKey(
                  'manga-translation-appearance-background-color',
                ),
                title: l10n.mangaTranslationBackgroundColour,
                color: _backgroundColor,
                textColor: false,
              ),
              _desktopSlider(
                key: const ValueKey('manga-translation-appearance-size'),
                title: l10n.fontSize,
                value: _fontSize,
                min: 8,
                max: 32,
                divisions: 24,
                display: '${_fontSize.round()} px',
                onChanged: (v) => setState(() => _fontSize = v),
                onEnd: widget.prefs.setMangaTranslationFontSize,
              ),
              _desktopSlider(
                key: const ValueKey('manga-translation-appearance-opacity'),
                title: l10n.mangaTranslationBackgroundOpacity,
                value: _backgroundOpacity,
                min: 0,
                max: 1,
                divisions: 20,
                display: '${(_backgroundOpacity * 100).round()}%',
                onChanged: (v) => setState(() => _backgroundOpacity = v),
                onEnd: widget.prefs.setMangaTranslationBackgroundOpacity,
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(l10n.mangaTranslationAppearanceFitNote, style: AppText.caption),
          const SizedBox(height: 12),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton.icon(
              onPressed: () => unawaited(_reset()),
              icon: const Icon(Icons.restart_alt_rounded, size: 18),
              label: Text(l10n.resetToDefaults),
            ),
          ),
        ],
      ),
    );
  }

  /// Full-row keyboard/mouse action with a color sample as its current value.
  Widget _desktopColorControl({
    required Key key,
    required String title,
    required Color color,
    required bool textColor,
  }) => GraphiteSettingsControl(
    key: key,
    icon: Icons.palette_outlined,
    title: title,
    onTap: () => _pickColor(textColor: textColor),
    trailing: Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.hairline),
      ),
    ),
  );

  /// The preview follows dragging; persistence retains the original release
  /// callback so a pointer movement does not produce a disk write per frame.
  Widget _desktopSlider({
    required Key key,
    required String title,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String display,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onEnd,
  }) => Padding(
    padding: const EdgeInsets.fromLTRB(22, 18, 22, 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: AppText.body),
        const SizedBox(height: 4),
        Text(display, style: AppText.caption),
        Slider(
          key: key,
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          label: display,
          semanticFormatterCallback: (_) => display,
          onChanged: onChanged,
          onChangeEnd: onEnd,
        ),
      ],
    ),
  );

  Widget _colorTile({
    required Key key,
    required String title,
    required Color color,
    required VoidCallback onTap,
  }) {
    return ListTile(
      key: key,
      contentPadding: EdgeInsets.zero,
      title: Text(title, style: AppText.body),
      trailing: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.hairline),
        ),
      ),
      onTap: onTap,
    );
  }

  Widget _sliderRow({
    required Key key,
    required String title,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String Function(double) format,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onChangeEnd,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(title, style: AppText.body)),
            Text(format(value), style: AppText.caption),
          ],
        ),
        Slider(
          key: key,
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
          onChangeEnd: onChangeEnd,
        ),
      ],
    );
  }
}
