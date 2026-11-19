import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../ui/desktop_docked_panel.dart';
import 'desktop_chrome_colors.dart';
import 'desktop_sheet.dart';
import '../../l10n/l10n.dart';

/// The rounded graphite dialog frame shared by the helpers below; the same
/// look as showGraphiteSettingsChoice (radius 20, panel surface and edge).
Widget _graphiteDialog({
  required BuildContext context,
  required Widget child,
  double maxWidth = 520,
}) => Dialog(
  backgroundColor: DesktopPanelColors.surface,
  surfaceTintColor: Colors.transparent,
  insetPadding: const EdgeInsets.all(24),
  shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(20),
    side: BorderSide(color: DesktopPanelColors.edge),
  ),
  clipBehavior: Clip.antiAlias,
  child: ConstrainedBox(
    constraints: BoxConstraints(
      maxWidth: maxWidth,
      maxHeight: MediaQuery.sizeOf(context).height * 0.8,
    ),
    child: Material(type: MaterialType.transparency, child: child),
  ),
);

/// Title row with a close button, as in the graphite settings dialogs.
Widget _titleRow(BuildContext context, String title) => Row(
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
      tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
      onPressed: () => Navigator.of(context).pop(),
      icon: const Icon(Icons.close_rounded),
      color: AppColors.textSecondary,
    ),
  ],
);

/// Asks a yes/no question. Returns true only when confirmed.
///
/// Windows: graphite dialog where Enter confirms and Esc cancels.
/// Elsewhere: a plain [AlertDialog], as phone screens use today.
Future<bool> showDesktopConfirm(
  BuildContext context, {
  required String title,
  required String message,
  String? confirmLabel,
  String? cancelLabel,
  bool destructive = false,
}) async {
  // Default button text follows the app language.
  final confirmText = confirmLabel ?? context.l10n.ok;
  final cancelText = cancelLabel ?? context.l10n.cancel;
  if (!desktopPanelsEnabled) {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(cancelText),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: destructive
                ? TextButton.styleFrom(foregroundColor: AppColors.accent)
                : null,
            child: Text(confirmText),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  final result = await showDialog<bool>(
    context: context,
    useRootNavigator: false,
    builder: (dialogContext) => _ConfirmBody(
      title: title,
      message: message,
      confirmLabel: confirmText,
      cancelLabel: cancelText,
      destructive: destructive,
    ),
  );
  return result ?? false;
}

/// Windows body of [showDesktopConfirm]. Stateful only to own the Cancel
/// button's focus node: Enter confirms, except when the user has tabbed to
/// Cancel, where Enter must cancel (as on a native Windows dialog).
class _ConfirmBody extends StatefulWidget {
  const _ConfirmBody({
    required this.title,
    required this.message,
    required this.confirmLabel,
    required this.cancelLabel,
    required this.destructive,
  });

  final String title, message, confirmLabel, cancelLabel;
  final bool destructive;

  @override
  State<_ConfirmBody> createState() => _ConfirmBodyState();
}

class _ConfirmBodyState extends State<_ConfirmBody> {
  final _cancelFocus = FocusNode(debugLabel: 'desktop-confirm-cancel');

  @override
  void dispose() {
    _cancelFocus.dispose();
    super.dispose();
  }

  /// Enter: the focused Cancel button wins, otherwise confirm.
  void _onEnter() => Navigator.of(context).pop(!_cancelFocus.hasFocus);

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    // Enter confirms and Esc cancels from anywhere in the dialog.
    bindings: {
      const SingleActivator(LogicalKeyboardKey.enter): _onEnter,
      const SingleActivator(LogicalKeyboardKey.numpadEnter): _onEnter,
      const SingleActivator(LogicalKeyboardKey.escape): () =>
          Navigator.of(context).pop(false),
    },
    child: Focus(
      autofocus: true,
      child: _graphiteDialog(
        context: context,
        maxWidth: 460,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.title,
                style: AppText.headline.copyWith(
                  fontSize: 20,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 10),
              Flexible(
                child: SingleChildScrollView(
                  child: Text(
                    widget.message,
                    style: AppText.body.copyWith(
                      color: AppColors.textSecondary,
                      height: 1.45,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              // OverflowBar keeps the buttons in one right-aligned row, and
              // stacks them (right-aligned) instead of overflowing when long
              // labels such as "Check other sources" do not fit.
              OverflowBar(
                alignment: MainAxisAlignment.end,
                overflowAlignment: OverflowBarAlignment.end,
                spacing: 8,
                overflowSpacing: 8,
                children: [
                  TextButton(
                    focusNode: _cancelFocus,
                    onPressed: () => Navigator.of(context).pop(false),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.textSecondary,
                    ),
                    child: Text(widget.cancelLabel),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    style: FilledButton.styleFrom(
                      backgroundColor: widget.destructive
                          ? const Color(0xFFD64545)
                          : AppColors.accent,
                      foregroundColor: widget.destructive
                          ? Colors.white
                          : DesktopChrome.onAccent(AppColors.accent),
                    ),
                    child: Text(widget.confirmLabel),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Single-choice picker in the graphite settings style, with an optional
/// search field. The current value has a tick; cancelling returns null.
///
/// With [searchable] the search field takes focus, Up/Down move the
/// highlight and Enter picks it. Without it, Up/Down/Enter work the same on
/// the list itself.
Future<T?> showDesktopChoiceDialog<T>(
  BuildContext context, {
  required String title,
  required List<(T, String)> options,
  T? current,
  String? description,
  Map<T, String> optionSubtitles = const {},
  Map<T, Widget> leading = const {},
  bool searchable = false,
  // Null uses the translated "Search".
  String? searchHint,
}) => showDialog<T>(
  context: context,
  useRootNavigator: false,
  builder: (dialogContext) => _graphiteDialog(
    context: dialogContext,
    child: _ChoiceBody<T>(
      title: title,
      options: options,
      current: current,
      description: description,
      optionSubtitles: optionSubtitles,
      leading: leading,
      searchable: searchable,
      searchHint: searchHint ?? context.l10n.search,
    ),
  ),
);

/// Windows: [showDesktopChoiceDialog]. Elsewhere: the caller's existing
/// phone picker, so phone screens keep exactly what they show today.
Future<T?> showAdaptiveChoice<T>(
  BuildContext context, {
  required String title,
  required List<(T, String)> options,
  T? current,
  String? description,
  Map<T, String> optionSubtitles = const {},
  Map<T, Widget> leading = const {},
  bool searchable = false,
  String? searchHint,
  required Future<T?> Function() phonePicker,
}) {
  if (!desktopPanelsEnabled) return phonePicker();
  return showDesktopChoiceDialog<T>(
    context,
    title: title,
    options: options,
    current: current,
    description: description,
    optionSubtitles: optionSubtitles,
    leading: leading,
    searchable: searchable,
    searchHint: searchHint,
  );
}

/// Content of the choice dialog: title, optional search, filtered list.
class _ChoiceBody<T> extends StatefulWidget {
  const _ChoiceBody({
    required this.title,
    required this.options,
    required this.current,
    required this.description,
    required this.optionSubtitles,
    required this.leading,
    required this.searchable,
    required this.searchHint,
  });

  final String title;
  final List<(T, String)> options;
  final T? current;
  final String? description;
  final Map<T, String> optionSubtitles;
  final Map<T, Widget> leading;
  final bool searchable;
  final String searchHint;

  @override
  State<_ChoiceBody<T>> createState() => _ChoiceBodyState<T>();
}

class _ChoiceBodyState<T> extends State<_ChoiceBody<T>> {
  final _query = TextEditingController();
  final _listFocus = FocusNode(debugLabel: 'desktop-choice-list');
  final _scroll = ScrollController();

  /// Keys of the visible rows so the highlight can be scrolled into view.
  final Map<int, GlobalKey> _rowKeys = {};

  /// Index into [_filtered] of the keyboard highlight.
  int _highlighted = 0;

  @override
  void initState() {
    super.initState();
    // Start on the current value so Enter keeps it and arrows move from it.
    final i = widget.options.indexWhere((o) => o.$1 == widget.current);
    _highlighted = i < 0 ? 0 : i;
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
  }

  @override
  void dispose() {
    _query.dispose();
    _listFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Options matching the search text (label or subtitle, case-insensitive).
  List<(T, String)> get _filtered {
    final q = _query.text.trim().toLowerCase();
    if (q.isEmpty) return widget.options;
    return [
      for (final o in widget.options)
        if (o.$2.toLowerCase().contains(q) ||
            (widget.optionSubtitles[o.$1]?.toLowerCase().contains(q) ?? false))
          o,
    ];
  }

  /// Scrolls the highlighted row into view after a keyboard move.
  void _reveal() {
    final ctx = _rowKeys[_highlighted]?.currentContext;
    if (ctx != null && mounted) {
      Scrollable.ensureVisible(
        ctx,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        duration: const Duration(milliseconds: 80),
      );
      Scrollable.ensureVisible(
        ctx,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
        duration: const Duration(milliseconds: 80),
      );
    }
  }

  void _move(int delta) {
    final n = _filtered.length;
    if (n == 0) return;
    setState(() => _highlighted = (_highlighted + delta).clamp(0, n - 1));
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
  }

  /// Picks the highlighted option (no-op when the filter matches nothing).
  void _pickHighlighted() {
    final list = _filtered;
    if (list.isEmpty) return;
    Navigator.of(context).pop(list[_highlighted.clamp(0, list.length - 1)].$1);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      _move(1);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _move(-1);
    } else if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
    } else if (!widget.searchable &&
        (key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter)) {
      // With a search field, Enter arrives through onSubmitted instead.
      _pickHighlighted();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final list = _filtered;
    _rowKeys.removeWhere((k, _) => k >= list.length);
    return Focus(
      focusNode: _listFocus,
      // Without a search field the list itself takes the keyboard.
      autofocus: !widget.searchable,
      onKeyEvent: _onKey,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _titleRow(context, widget.title),
            const SizedBox(height: 12),
            if (widget.description != null) ...[
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  widget.description!,
                  style: AppText.caption.copyWith(
                    color: AppColors.textSecondary,
                    height: 1.45,
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
            if (widget.searchable) ...[
              TextField(
                controller: _query,
                autofocus: true,
                textInputAction: TextInputAction.done,
                onChanged: (_) => setState(() => _highlighted = 0),
                onSubmitted: (_) => _pickHighlighted(),
                style: AppText.body.copyWith(color: AppColors.textPrimary),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: widget.searchHint,
                  prefixIcon: const Icon(Icons.search_rounded, size: 20),
                  filled: true,
                  fillColor: DesktopChrome.field,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: DesktopPanelColors.edge),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: DesktopPanelColors.edge),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: AppColors.accent),
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            Divider(height: 1, color: DesktopPanelColors.edge),
            const SizedBox(height: 8),
            Flexible(
              child: list.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        context.l10n.noMatches,
                        style: AppText.caption.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: _scroll,
                      shrinkWrap: true,
                      itemCount: list.length,
                      itemBuilder: (context, i) {
                        final (value, label) = list[i];
                        return Semantics(
                          selected: value == widget.current,
                          inMutuallyExclusiveGroup: true,
                          child: _ChoiceRow(
                            key: _rowKeys.putIfAbsent(i, GlobalKey.new),
                            label: label,
                            subtitle: widget.optionSubtitles[value],
                            leading: widget.leading[value],
                            selected: value == widget.current,
                            highlighted: i == _highlighted,
                            onHover: () => setState(() => _highlighted = i),
                            onTap: () => Navigator.of(context).pop(value),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One option row: optional leading widget, label/subtitle, tick on current.
class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    super.key,
    required this.label,
    required this.subtitle,
    required this.leading,
    required this.selected,
    required this.highlighted,
    required this.onHover,
    required this.onTap,
  });

  final String label;
  final String? subtitle;
  final Widget? leading;
  final bool selected, highlighted;
  final VoidCallback onHover, onTap;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    onEnter: (_) => onHover(),
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.all(3),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          // Same hover fill as GraphiteSettingsControl.
          color: highlighted ? const Color(0xFF29252C) : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            if (leading != null) ...[
              SizedBox(width: 28, child: Center(child: leading)),
              const SizedBox(width: 14),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: AppText.body.copyWith(
                      color: AppColors.textPrimary,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      subtitle!,
                      style: AppText.caption.copyWith(
                        color: AppColors.textSecondary,
                        height: 1.4,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            // Tick on the current value; empty slot keeps rows aligned.
            SizedBox(
              width: 28,
              child: selected
                  ? Icon(Icons.check_rounded, color: AppColors.accent, size: 20)
                  : null,
            ),
          ],
        ),
      ),
    ),
  );
}

/// Asks for a single line of text (new name, rename). Returns the text as
/// typed (callers trim/validate), or null when cancelled.
///
/// Windows: graphite dialog in the same frame as [showDesktopConfirm], with a
/// graphite text field; Enter submits and Esc cancels.
/// Elsewhere: the Material [AlertDialog] the phone screens already used
/// (surface background, accent Create button), so phone is unchanged.
/// Named "adaptive" because it picks the look itself; the Windows-only
/// helper in desktop_text_prompt.dart is showDesktopTextPrompt.
Future<String?> showAdaptiveTextPrompt(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  String? cancelLabel,
  String? hint,
  String initialValue = '',
}) {
  final cancelText = cancelLabel ?? context.l10n.cancel;
  return showDialog<String>(
    context: context,
    // Windows keeps it in the nearest navigator (fullscreen player rule);
    // phone keeps showDialog's default exactly as before.
    useRootNavigator: !desktopPanelsEnabled,
    // Opened from a desktop sheet: no second scrim on top of its own, the
    // same rule showAdaptiveSheet uses for nested pickers.
    barrierColor: desktopPanelsEnabled && DesktopSheetScope.of(context)
        ? Colors.transparent
        : null,
    builder: (_) => _TextPromptBody(
      title: title,
      confirmLabel: confirmLabel,
      cancelLabel: cancelText,
      hint: hint,
      initialValue: initialValue,
      desktop: desktopPanelsEnabled,
    ),
  );
}

/// Body of [showAdaptiveTextPrompt]. Stateful so the text controller is
/// owned (and disposed) by the dialog rather than leaked by the caller.
class _TextPromptBody extends StatefulWidget {
  const _TextPromptBody({
    required this.title,
    required this.confirmLabel,
    required this.cancelLabel,
    required this.hint,
    required this.initialValue,
    required this.desktop,
  });

  final String title, confirmLabel, cancelLabel, initialValue;
  final String? hint;

  /// True for the graphite Windows look, false for the phone AlertDialog.
  final bool desktop;

  @override
  State<_TextPromptBody> createState() => _TextPromptBodyState();
}

class _TextPromptBodyState extends State<_TextPromptBody> {
  late final _controller = TextEditingController(text: widget.initialValue);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit([String? v]) => Navigator.of(context).pop(v ?? _controller.text);

  void _cancel() => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) =>
      widget.desktop ? _desktop(context) : _phone(context);

  /// Phone: the same AlertDialog the callers built inline before.
  Widget _phone(BuildContext context) => AlertDialog(
    backgroundColor: AppColors.surface,
    title: Text(widget.title, style: AppText.title),
    content: TextField(
      controller: _controller,
      autofocus: true,
      style: AppText.body.copyWith(color: AppColors.textPrimary),
      decoration: InputDecoration(hintText: widget.hint),
      onSubmitted: _submit,
    ),
    actions: [
      TextButton(onPressed: _cancel, child: Text(widget.cancelLabel)),
      FilledButton(
        onPressed: _submit,
        style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
        child: Text(widget.confirmLabel),
      ),
    ],
  );

  /// Windows: graphite frame, field styled like the choice dialog's search.
  Widget _desktop(BuildContext context) {
    OutlineInputBorder border(Color c) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: c),
    );
    return CallbackShortcuts(
      // Esc cancels from anywhere; Enter is handled by the field's onSubmitted.
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _cancel},
      child: _graphiteDialog(
        context: context,
        maxWidth: 460,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.title,
                style: AppText.headline.copyWith(
                  fontSize: 20,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                key: const ValueKey('desktop-text-prompt-field'),
                controller: _controller,
                autofocus: true,
                textInputAction: TextInputAction.done,
                onSubmitted: _submit,
                style: AppText.body.copyWith(color: AppColors.textPrimary),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: widget.hint,
                  filled: true,
                  fillColor: DesktopChrome.field,
                  border: border(DesktopPanelColors.edge),
                  enabledBorder: border(DesktopPanelColors.edge),
                  focusedBorder: border(AppColors.accent),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _cancel,
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.textSecondary,
                    ),
                    child: Text(widget.cancelLabel),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _submit,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: DesktopChrome.onAccent(AppColors.accent),
                    ),
                    child: Text(widget.confirmLabel),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
