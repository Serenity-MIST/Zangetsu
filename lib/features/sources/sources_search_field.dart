import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_text_field.dart';

import 'sources_desktop_kit.dart';
import '../../l10n/l10n.dart';

// Re-exported so the provider screens' part files can use the Windows
// helpers without new imports in parent libraries this group does not own.
export 'sources_desktop_kit.dart';

/// Whether an extension/plugin row matches a search [query].
///
/// Case-insensitive substring on [name]; a query that exactly equals the
/// row's [lang] code (e.g. "en", "id") also matches. An empty/blank query
/// matches everything.
bool sourceSearchMatches(String query, String name, [String? lang]) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  if (name.toLowerCase().contains(q)) return true;
  return lang != null && lang.trim().toLowerCase() == q;
}

/// The shared search box used by the provider screens (phone + TV).
///
/// Purely presentational: the owning screen holds the [controller] and
/// rebuilds itself from [onChanged].
///
/// On TV this uses [TvTextField] so D-pad focus does **not** raise the
/// leanback IME (a bare [TextField] would steal arrows and open the
/// keyboard the moment focus lands from a source row below). OK/Select
/// opens the keyboard when the user actually wants to type.
///
/// On Windows (src-13 A) it joins the screen's [DesktopSourcesKeys], so
/// Ctrl+F focuses it, and Esc inside it clears the text first, then goes
/// back. Phone and TV are unchanged.
class SourcesSearchField extends StatefulWidget {
  const SourcesSearchField({
    super.key,
    required this.controller,
    required this.onChanged,
    this.hint = 'Search extensions',
    this.focusNode,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final String hint;

  /// Optional focus node owned by the screen (src-13), so it can focus the
  /// field directly (e.g. Ctrl+F). On Windows a [DesktopSourcesKeys] scope's
  /// node still comes first, so the shared Ctrl+F keeps working; when null
  /// the field behaves exactly as before.
  final FocusNode? focusNode;

  @override
  State<SourcesSearchField> createState() => _SourcesSearchFieldState();
}

class _SourcesSearchFieldState extends State<SourcesSearchField> {
  /// The Windows screen keys this field is attached to, if any.
  DesktopSourcesKeysState? _keys;

  /// Focus node used on Windows when no screen keys scope provides one.
  FocusNode? _ownFocus;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!desktopPanelsEnabled) return;
    final keys = DesktopSourcesKeys.maybeOf(context);
    if (keys == _keys) return;
    _keys?.detachSearch(widget.controller);
    _keys = keys?..attachSearch(widget.controller, widget.onChanged);
  }

  @override
  void didUpdateWidget(SourcesSearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-attach so Esc / Ctrl+F act on the current controller and callback.
    if (_keys != null &&
        (oldWidget.controller != widget.controller ||
            oldWidget.onChanged != widget.onChanged)) {
      _keys!
        ..detachSearch(oldWidget.controller)
        ..attachSearch(widget.controller, widget.onChanged);
    }
  }

  @override
  void dispose() {
    _keys?.detachSearch(widget.controller);
    _ownFocus?.dispose();
    super.dispose();
  }

  /// Windows Esc inside the field: clear the text, else leave the screen.
  KeyEventResult _onDesktopKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    if (widget.controller.text.isNotEmpty) {
      widget.controller.clear();
      widget.onChanged('');
    } else {
      node.unfocus();
      Navigator.of(context).maybePop();
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final onChanged = widget.onChanged;
    final isTv = sl.isRegistered<AppMode>() && sl<AppMode>().isTv;
    final desktop = desktopPanelsEnabled;
    final decoration = InputDecoration(
      // The shortcut hint teaches Ctrl+F on Windows only.
      // Key names stay as printed on the keyboard.
      hintText: desktop ? '${widget.hint} (Ctrl+F)' : widget.hint,
      hintStyle: AppText.body.copyWith(color: AppColors.textSecondary),
      prefixIcon: const Icon(
        Icons.search,
        color: AppColors.textSecondary,
        size: 20,
      ),
      suffixIcon: controller.text.isEmpty
          ? null
          : Focus(
              // Clear is tap/OK-reachable via the field itself on phone;
              // on TV keep it out of D-pad traversal so arrows stay on the
              // search field ↔ tabs ↔ list path.
              canRequestFocus: false,
              skipTraversal: true,
              descendantsAreFocusable: !isTv,
              descendantsAreTraversable: !isTv,
              child: IconButton(
                // Icon-only on Windows needs a hover label (src-13 B).
                tooltip: desktop ? context.l10n.clearSearchEsc : null,
                icon: const Icon(
                  Icons.close,
                  color: AppColors.textSecondary,
                  size: 18,
                ),
                onPressed: () {
                  controller.clear();
                  onChanged('');
                },
              ),
            ),
      isDense: true,
      filled: true,
      fillColor: AppColors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: AppColors.accent, width: 1.5),
      ),
    );

    if (isTv) {
      return TvTextField(
        controller: controller,
        onChanged: onChanged,
        style: AppText.body,
        cursorColor: AppColors.accent,
        decoration: decoration,
      );
    }

    if (desktop) {
      return Focus(
        // Only listens for Esc; the TextField keeps its own focus node.
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _onDesktopKey,
        child: TextField(
          controller: controller,
          // The keys scope's node wins so its Ctrl+F always reaches this
          // field; a screen's own node is used only outside such a scope.
          focusNode: _keys?.searchFocus ??
              widget.focusNode ??
              (_ownFocus ??= FocusNode()),
          onChanged: onChanged,
          style: AppText.body,
          cursorColor: AppColors.accent,
          decoration: decoration,
        ),
      );
    }

    return TextField(
      controller: controller,
      // Null keeps the TextField's own internal node (phone unchanged).
      focusNode: widget.focusNode,
      onChanged: onChanged,
      style: AppText.body,
      cursorColor: AppColors.accent,
      decoration: decoration,
    );
  }
}
