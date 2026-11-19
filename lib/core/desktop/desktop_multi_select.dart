import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';
import '../ui/desktop_docked_panel.dart';
import 'desktop_chrome_colors.dart';

/// Explorer-style multi-selection state for a list or grid keyed by [K].
///
/// Ctrl+click toggles, Shift+click selects the range from the anchor, and
/// once a selection exists a plain click toggles too. Screens call
/// [handleClick] first and skip their normal open/play when it returns true.
class DesktopSelection<K> extends ChangeNotifier {
  final Set<K> _selected = <K>{};
  bool _selecting = false;
  K? _anchor;
  K? _lead;

  /// Selected keys (read-only view).
  Set<K> get selected => Set.unmodifiable(_selected);

  /// True while in selection mode: something is selected, or
  /// [startSelecting] was called (e.g. a "Select" toolbar button).
  bool get isActive => _selecting || _selected.isNotEmpty;

  /// Where a Shift range starts: the last key clicked without Shift.
  K? get anchor => _anchor;

  /// The far end of the last range, moved by Shift+Up/Down.
  K? get lead => _lead;

  bool isSelected(K key) => _selected.contains(key);

  /// Flips [key] and makes it the new anchor.
  void toggle(K key) {
    if (!_selected.remove(key)) _selected.add(key);
    _anchor = key;
    _lead = key;
    notifyListeners();
  }

  /// Adds [key] and makes it the new anchor.
  void select(K key) {
    _selected.add(key);
    _anchor = key;
    _lead = key;
    notifyListeners();
  }

  /// Selection becomes everything between the anchor and [to] in [ordered]
  /// (inclusive), as Shift+click does in Explorer. The anchor stays put;
  /// without a usable anchor this just selects [to].
  void selectRange(K to, List<K> ordered) {
    final end = ordered.indexOf(to);
    final start = _anchor == null ? -1 : ordered.indexOf(_anchor as K);
    if (end < 0 || start < 0) {
      select(to);
      return;
    }
    final lo = start < end ? start : end;
    final hi = start < end ? end : start;
    _selected
      ..clear()
      ..addAll(ordered.sublist(lo, hi + 1));
    _lead = to;
    notifyListeners();
  }

  /// Adds every key in [keys] (Ctrl+A).
  void selectAll(Iterable<K> keys) {
    _selected.addAll(keys);
    if (_anchor == null && _selected.isNotEmpty) _anchor = _selected.first;
    notifyListeners();
  }

  /// Empties the selection and leaves selection mode.
  void clear() {
    if (_selected.isEmpty && !_selecting && _anchor == null) return;
    _selected.clear();
    _selecting = false;
    _anchor = null;
    _lead = null;
    notifyListeners();
  }

  /// Enters selection mode with nothing selected yet.
  void startSelecting() {
    if (_selecting) return;
    _selecting = true;
    notifyListeners();
  }

  /// Handles a click on [key]; [ordered] is the on-screen order. Returns
  /// true when the click was used for selection (the caller then skips its
  /// normal action). Modifiers default to the live keyboard state.
  bool handleClick(K key, List<K> ordered, {bool? ctrl, bool? shift}) {
    final keyboard = HardwareKeyboard.instance;
    final isShift = shift ?? keyboard.isShiftPressed;
    final isCtrl =
        ctrl ?? (keyboard.isControlPressed || keyboard.isMetaPressed);
    if (isShift) {
      selectRange(key, ordered);
      return true;
    }
    if (isCtrl || isActive) {
      toggle(key);
      return true;
    }
    return false;
  }

  /// Shift+Up/Down: moves the range end by [delta] rows in [ordered].
  void _extend(int delta, List<K> ordered) {
    if (ordered.isEmpty) return;
    final from = _lead ?? _anchor;
    final i = from == null ? -1 : ordered.indexOf(from as K);
    if (i < 0) {
      select(delta > 0 ? ordered.first : ordered.last);
      return;
    }
    final next = (i + delta).clamp(0, ordered.length - 1);
    selectRange(ordered[next], ordered);
  }
}

/// Keyboard for a [DesktopSelection]: Ctrl+A selects all, Esc clears (and
/// is only consumed when something is selected, so Esc still goes back
/// otherwise), Shift+Up/Down extend, Delete and Enter call back. Works while
/// focus is anywhere inside [child]. Off Windows the child is returned.
class DesktopSelectionShortcuts<K> extends StatelessWidget {
  const DesktopSelectionShortcuts({
    super.key,
    required this.selection,
    required this.orderedKeys,
    required this.child,
    this.onDelete,
    this.onActivate,
    this.autofocus = false,
  });

  final DesktopSelection<K> selection;

  /// Take focus on first build so the keys work before anything is clicked
  /// (extra to the shared spec; defaults off).
  final bool autofocus;

  /// Current on-screen order, read when a key is pressed.
  final List<K> Function() orderedKeys;
  final Widget child;

  /// Delete key with a non-empty selection.
  final VoidCallback? onDelete;

  /// Enter with a non-empty selection.
  final VoidCallback? onActivate;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    // Typing in a search box inside the list keeps its own keys.
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (focusContext != null &&
        (focusContext.widget is EditableText ||
            focusContext.findAncestorWidgetOfExactType<EditableText>() !=
                null)) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    final key = event.logicalKey;
    final ctrl = keyboard.isControlPressed;
    final shift = keyboard.isShiftPressed;
    if (ctrl && key == LogicalKeyboardKey.keyA) {
      selection.selectAll(orderedKeys());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (!selection.isActive) return KeyEventResult.ignored;
      selection.clear();
      return KeyEventResult.handled;
    }
    if (shift && key == LogicalKeyboardKey.arrowDown) {
      selection._extend(1, orderedKeys());
      return KeyEventResult.handled;
    }
    if (shift && key == LogicalKeyboardKey.arrowUp) {
      selection._extend(-1, orderedKeys());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.delete &&
        onDelete != null &&
        selection.selected.isNotEmpty) {
      onDelete!();
      return KeyEventResult.handled;
    }
    if ((key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter) &&
        onActivate != null &&
        selection.selected.isNotEmpty) {
      onActivate!();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    if (!desktopPanelsEnabled) return child;
    // Sees keys from any focused descendant; it can hold focus itself (for
    // [autofocus]) but Tab never stops on it.
    return Focus(
      autofocus: autofocus,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: child,
    );
  }
}

/// Small round-cornered checkbox shown on a card/row in selection mode.
/// Fades in when [visible] (hover or selection mode) or [selected].
class DesktopSelectionCheckbox extends StatelessWidget {
  const DesktopSelectionCheckbox({
    super.key,
    required this.selected,
    required this.visible,
    this.onChanged,
    this.size = 22,
  });

  final bool selected;
  final bool visible;
  final ValueChanged<bool>? onChanged;
  final double size;

  @override
  Widget build(BuildContext context) {
    final shown = visible || selected;
    final accent = AppColors.accent;
    return IgnorePointer(
      ignoring: !shown,
      child: AnimatedOpacity(
        opacity: shown ? 1 : 0,
        duration: const Duration(milliseconds: 120),
        child: Semantics(
          checked: selected,
          button: true,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onChanged == null ? null : () => onChanged!(!selected),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: size,
                height: size,
                decoration: BoxDecoration(
                  // Accent fill when ticked; dark glass with a light ring
                  // otherwise so it reads on any artwork.
                  color: selected
                      ? accent
                      : Colors.black.withValues(alpha: .45),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: selected ? accent : Colors.white70,
                    width: 1.5,
                  ),
                ),
                child: selected
                    ? Icon(
                        Icons.check_rounded,
                        size: size * .72,
                        color: DesktopChrome.onAccent(accent),
                      )
                    : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
