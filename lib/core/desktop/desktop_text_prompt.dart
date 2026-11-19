import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../ui/desktop_docked_panel.dart';
import '../../l10n/l10n.dart';

/// Asks for one line of text in the graphite Windows dialog style and
/// returns it trimmed, or null when cancelled (Esc, Cancel, close, or a
/// click outside).
///
/// Windows-only: callers keep their own phone dialog and call this when
/// [desktopPanelsEnabled] is true, so phone screens stay exactly as before.
/// Enter submits, Esc cancels, and the field has focus when it opens.
Future<String?> showDesktopTextPrompt(
  BuildContext context, {
  required String title,
  String? subtitle,
  String? label,
  String? hint,
  String? initialValue,
  String? confirmLabel,
  TextInputType? keyboardType,
  TextCapitalization textCapitalization = TextCapitalization.none,
  List<TextInputFormatter>? inputFormatters,
}) => showDialog<String>(
  context: context,
  // Stay in the nearest navigator so a fullscreen player stays fullscreen.
  useRootNavigator: false,
  builder: (_) => DesktopTextPromptDialog(
    title: title,
    subtitle: subtitle,
    label: label,
    hint: hint,
    initialValue: initialValue,
    confirmLabel: confirmLabel,
    keyboardType: keyboardType,
    textCapitalization: textCapitalization,
    inputFormatters: inputFormatters,
  ),
);

/// Body of [showDesktopTextPrompt]: title bar, one filled field, and
/// Cancel / confirm buttons, matching the Add repository dialog. Public so
/// tests can pump it directly.
class DesktopTextPromptDialog extends StatefulWidget {
  const DesktopTextPromptDialog({
    super.key,
    required this.title,
    this.subtitle,
    this.label,
    this.hint,
    this.initialValue,
    this.confirmLabel,
    this.keyboardType,
    this.textCapitalization = TextCapitalization.none,
    this.inputFormatters,
  });

  final String title;
  final String? subtitle, label, hint, initialValue, confirmLabel;
  final TextInputType? keyboardType;
  final TextCapitalization textCapitalization;
  final List<TextInputFormatter>? inputFormatters;

  @override
  State<DesktopTextPromptDialog> createState() =>
      _DesktopTextPromptDialogState();
}

class _DesktopTextPromptDialogState extends State<DesktopTextPromptDialog> {
  // Owned here (not by the caller) so it outlives the close animation.
  late final TextEditingController _text = TextEditingController(
    text: widget.initialValue ?? '',
  );

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  /// Returns the trimmed text; an empty field does nothing.
  void _submit() {
    final value = _text.text.trim();
    if (value.isEmpty) return;
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return DesktopEscCloses(
      child: Dialog(
        backgroundColor: DesktopPanelColors.surface,
        surfaceTintColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(24),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: DesktopPanelColors.edge),
        ),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DesktopPanelTitleBar(
                title: widget.title,
                subtitle: widget.subtitle,
              ),
              Divider(height: 1, color: DesktopPanelColors.edge),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: TextField(
                  key: const ValueKey('desktop-text-prompt-field'),
                  controller: _text,
                  autofocus: true,
                  keyboardType: widget.keyboardType,
                  textCapitalization: widget.textCapitalization,
                  inputFormatters: widget.inputFormatters,
                  style: AppText.body.copyWith(color: AppColors.textPrimary),
                  cursorColor: AppColors.accent,
                  decoration: InputDecoration(
                    labelText: widget.label,
                    hintText: widget.hint,
                    filled: true,
                    fillColor: AppColors.surface2,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  // Enter submits, like the confirm button.
                  onSubmitted: (_) => _submit(),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 16, 14),
                child: Row(
                  children: [
                    const Spacer(),
                    TextButton(
                      key: const ValueKey('desktop-text-prompt-cancel'),
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(l10n.cancel),
                    ),
                    const SizedBox(width: 8),
                    // Disabled until something is typed, so it never
                    // returns an empty answer.
                    ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _text,
                      builder: (context, value, _) => FilledButton(
                        key: const ValueKey('desktop-text-prompt-confirm'),
                        onPressed: value.text.trim().isEmpty ? null : _submit,
                        child: Text(widget.confirmLabel ?? l10n.ok),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
