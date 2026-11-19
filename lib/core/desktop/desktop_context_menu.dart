import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../ui/desktop_docked_panel.dart';
import 'desktop_chrome_colors.dart';

/// One row of a Windows context menu (or a divider between rows).
///
/// [value] is returned from [showDesktopContextMenu] when the row is picked,
/// and [onTap] runs after the menu has closed, so callers can use whichever
/// style suits them.
class DesktopMenuItem<T> {
  const DesktopMenuItem({
    required this.label,
    this.icon,
    this.value,
    this.onTap,
    this.enabled = true,
    this.destructive = false,
    this.checked,
    this.shortcut,
    this.submenu,
  }) : _divider = false;

  /// A thin separator line; it cannot be focused or picked.
  const DesktopMenuItem.divider()
    : label = '',
      icon = null,
      value = null,
      onTap = null,
      enabled = false,
      destructive = false,
      checked = null,
      shortcut = null,
      submenu = null,
      _divider = true;

  final String label;
  final IconData? icon;
  final T? value;
  final VoidCallback? onTap;
  final bool enabled, destructive;

  /// Null = not a checkable row; true/false shows (or reserves) a tick.
  final bool? checked;

  /// Keyboard hint shown on the right, e.g. 'Ctrl+C'. Display only.
  final String? shortcut;

  /// Child rows; the row opens them on hover or Right arrow.
  final List<DesktopMenuItem<T>>? submenu;

  final bool _divider;

  bool get isDivider => _divider;

  /// True for rows that keyboard navigation may land on.
  bool get _selectable => !_divider && enabled;

  bool get _hasSubmenu => submenu != null && submenu!.isNotEmpty;
}

/// Remembers where the mouse last went down, anywhere in the app.
///
/// Existing `onSecondaryTap` callbacks do not carry a position, so a menu
/// opened from them reads [lastSecondaryDown] to appear under the cursor
/// without plumbing details through every widget.
abstract final class DesktopPointer {
  static bool _installed = false;
  static Offset? _lastDown;
  static Offset? _lastSecondaryDown;

  /// Hooks the global pointer route. Safe to call more than once.
  static void install() {
    if (_installed) return;
    _installed = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
  }

  /// Global (logical) position of the most recent pointer down.
  static Offset? get lastDown => _lastDown;

  /// Global position of the most recent right-button down.
  static Offset? get lastSecondaryDown => _lastSecondaryDown;

  /// Records the position of every pointer down; other events are ignored.
  static void _onPointer(PointerEvent event) {
    if (event is! PointerDownEvent) return;
    _lastDown = event.position;
    if (event.buttons & kSecondaryMouseButton != 0) {
      _lastSecondaryDown = event.position;
    }
  }
}

/// How a menu panel is placed relative to its anchor.
enum _MenuPlacement {
  /// Top-left at a point (right-click menus).
  point,

  /// Below a rectangle, left-aligned (dropdown from a button).
  below,

  /// To the right of a rectangle, top-aligned (submenus).
  side,
}

/// Height of one menu row, the compact Windows size.
const double _rowHeight = 34;

/// Gap kept between a menu and the window edge.
const double _screenMargin = 8;

/// Opens a compact graphite context menu and returns the picked item's value.
///
/// Placement: [position] (global) when given; else below [anchor]'s box like
/// a dropdown; else at the last right-click, else the last click, else the
/// centre of [context]. The menu is kept on screen. Up/Down/Enter/Esc work,
/// Right/Left open and close submenus. The picked item's `onTap` runs after
/// the menu has closed.
Future<T?> showDesktopContextMenu<T>(
  BuildContext context, {
  Offset? position,
  BuildContext? anchor,
  required List<DesktopMenuItem<T>> items,
}) async {
  if (items.every((i) => i.isDivider)) return null;
  final navigator = Navigator.of(context, rootNavigator: true);
  // The root overlay fills the window; positions are converted into it so a
  // window inset (title bar) never shifts the menu.
  final overlayBox =
      navigator.overlay!.context.findRenderObject()! as RenderBox;

  Rect anchorRect;
  _MenuPlacement placement;
  if (position != null) {
    anchorRect = Rect.fromLTWH(position.dx, position.dy, 0, 0);
    placement = _MenuPlacement.point;
  } else if (anchor != null && anchor.findRenderObject() is RenderBox) {
    final box = anchor.findRenderObject()! as RenderBox;
    anchorRect = box.localToGlobal(Offset.zero) & box.size;
    placement = _MenuPlacement.below;
  } else {
    final fallback =
        DesktopPointer.lastSecondaryDown ??
        DesktopPointer.lastDown ??
        _centreOf(context);
    anchorRect = Rect.fromLTWH(fallback.dx, fallback.dy, 0, 0);
    placement = _MenuPlacement.point;
  }
  // Global -> overlay-local.
  final topLeft = overlayBox.globalToLocal(anchorRect.topLeft);
  final localRect = topLeft & anchorRect.size;

  final picked = await navigator.push<DesktopMenuItem<T>>(
    _DesktopMenuRoute<T>(
      items: items,
      anchor: localRect,
      placement: placement,
      overlayBox: overlayBox,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    ),
  );
  if (picked == null) return null;
  // Run the callback after the route is gone so it can open dialogs freely.
  picked.onTap?.call();
  return picked.value;
}

/// Centre of [context]'s box in global coordinates (the last fallback).
Offset _centreOf(BuildContext context) {
  final box = context.findRenderObject();
  if (box is RenderBox && box.hasSize) {
    return box.localToGlobal(box.size.center(Offset.zero));
  }
  final size = MediaQuery.maybeSizeOf(context) ?? Size.zero;
  return size.center(Offset.zero);
}

/// Transparent popup route that hosts the root menu and any open submenus.
class _DesktopMenuRoute<T> extends PopupRoute<DesktopMenuItem<T>> {
  _DesktopMenuRoute({
    required this.items,
    required this.anchor,
    required this.placement,
    required this.overlayBox,
    required this.barrierLabel,
  });

  final List<DesktopMenuItem<T>> items;
  final Rect anchor;
  final _MenuPlacement placement;
  final RenderBox overlayBox;

  @override
  final String barrierLabel;

  // The menu draws its own click-away layer (which also catches right
  // clicks), so the route has no barrier colour and is not barrier-dismissed.
  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => false;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 90);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 60);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => _DesktopMenuHost<T>(
    items: items,
    anchor: anchor,
    placement: placement,
    overlayBox: overlayBox,
  );

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => FadeTransition(
    opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
    child: child,
  );
}

/// One open menu level: its rows and where it hangs.
class _MenuLevel<T> {
  _MenuLevel(this.items, this.anchor, this.placement);

  final List<DesktopMenuItem<T>> items;
  final Rect anchor;
  final _MenuPlacement placement;
  final FocusNode focusNode = FocusNode(debugLabel: 'desktop-menu-level');

  /// Index of the keyboard/hover highlight, -1 when none.
  int highlighted = -1;
}

/// Holds the stack of open menu levels (root first, deepest submenu last).
class _DesktopMenuHost<T> extends StatefulWidget {
  const _DesktopMenuHost({
    required this.items,
    required this.anchor,
    required this.placement,
    required this.overlayBox,
  });

  final List<DesktopMenuItem<T>> items;
  final Rect anchor;
  final _MenuPlacement placement;
  final RenderBox overlayBox;

  @override
  State<_DesktopMenuHost<T>> createState() => _DesktopMenuHostState<T>();
}

class _DesktopMenuHostState<T> extends State<_DesktopMenuHost<T>> {
  late final List<_MenuLevel<T>> _levels = [
    _MenuLevel<T>(widget.items, widget.anchor, widget.placement),
  ];

  @override
  void dispose() {
    for (final level in _levels) {
      level.focusNode.dispose();
    }
    super.dispose();
  }

  /// Set once the menu starts closing. The panels stay hit-testable during
  /// the short fade-out, so a quick second click or Esc must not pop again
  /// (that would close the page or dialog underneath the menu).
  bool _closing = false;

  /// Closes the whole menu without a pick.
  void _dismiss() {
    if (_closing) return;
    _closing = true;
    Navigator.of(context).pop();
  }

  /// Closes the menu with [item] as the result.
  void _pick(DesktopMenuItem<T> item) {
    if (_closing) return;
    _closing = true;
    Navigator.of(context).pop(item);
  }

  /// Drops every level deeper than [depth].
  void _truncate(int depth) {
    while (_levels.length > depth + 1) {
      final removed = _levels.removeLast();
      // Disposed after the frame, since its Focus may still be mounted now.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => removed.focusNode.dispose(),
      );
    }
  }

  /// Opens [item]'s submenu next to [rowRect] (global) as level depth+1.
  void _openSubmenu(
    int depth,
    DesktopMenuItem<T> item,
    Rect rowRect, {
    bool focus = false,
  }) {
    final local =
        widget.overlayBox.globalToLocal(rowRect.topLeft) & rowRect.size;
    setState(() {
      _truncate(depth);
      final level = _MenuLevel<T>(item.submenu!, local, _MenuPlacement.side);
      if (focus) level.highlighted = _firstSelectable(item.submenu!);
      _levels.add(level);
    });
    if (focus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _levels.length > depth + 1) {
          _levels[depth + 1].focusNode.requestFocus();
        }
      });
    }
  }

  /// Closes submenus below [depth] and gives that level the keyboard.
  void _closeTo(int depth) {
    setState(() => _truncate(depth));
    _levels[depth].focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      // Click-away layer: any button (left or right) outside the panels
      // closes the menu, like a native Windows menu.
      Positioned.fill(
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (_) => _dismiss(),
        ),
      ),
      for (var depth = 0; depth < _levels.length; depth++)
        Positioned.fill(
          child: CustomSingleChildLayout(
            delegate: _MenuLayoutDelegate(
              anchor: _levels[depth].anchor,
              placement: _levels[depth].placement,
            ),
            child: _MenuPanel<T>(
              key: ObjectKey(_levels[depth]),
              level: _levels[depth],
              depth: depth,
              autofocus: depth == 0,
              onPick: _pick,
              onDismiss: _dismiss,
              onOpenSubmenu: _openSubmenu,
              onCloseTo: _closeTo,
              onHoverRow: (d) {
                // Hovering a plain row closes any deeper submenu.
                if (_levels.length > d + 1) setState(() => _truncate(d));
              },
            ),
          ),
        ),
    ],
  );
}

/// First row index the keyboard can land on, or -1.
int _firstSelectable<T>(List<DesktopMenuItem<T>> items) =>
    items.indexWhere((i) => i._selectable);

/// Places a panel by its anchor and keeps it inside the window.
class _MenuLayoutDelegate extends SingleChildLayoutDelegate {
  _MenuLayoutDelegate({required this.anchor, required this.placement});

  final Rect anchor;
  final _MenuPlacement placement;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(
        Size(
          (constraints.maxWidth - _screenMargin * 2).clamp(0, double.infinity),
          (constraints.maxHeight - _screenMargin * 2).clamp(0, double.infinity),
        ),
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    double x;
    double y;
    switch (placement) {
      case _MenuPlacement.point:
        x = anchor.left;
        y = anchor.top;
        // Flip left/up when the menu would run off the right/bottom edge.
        if (x + childSize.width > size.width - _screenMargin) {
          x = anchor.left - childSize.width;
        }
        if (y + childSize.height > size.height - _screenMargin) {
          y = anchor.top - childSize.height;
        }
      case _MenuPlacement.below:
        x = anchor.left;
        y = anchor.bottom + 4;
        // Open above the anchor when there is no room below.
        if (y + childSize.height > size.height - _screenMargin) {
          y = anchor.top - 4 - childSize.height;
        }
      case _MenuPlacement.side:
        // Panel padding (4) lines the first submenu row up with its parent.
        x = anchor.right + 2;
        y = anchor.top - 4;
        // Open to the left of the parent when there is no room on the right.
        if (x + childSize.width > size.width - _screenMargin) {
          x = anchor.left - 2 - childSize.width;
        }
    }
    // Final clamp so nothing ever leaves the window.
    x = x.clamp(
      _screenMargin,
      (size.width - childSize.width - _screenMargin).clamp(
        _screenMargin,
        double.infinity,
      ),
    );
    y = y.clamp(
      _screenMargin,
      (size.height - childSize.height - _screenMargin).clamp(
        _screenMargin,
        double.infinity,
      ),
    );
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_MenuLayoutDelegate oldDelegate) =>
      anchor != oldDelegate.anchor || placement != oldDelegate.placement;
}

/// One graphite menu panel with keyboard handling for its level.
class _MenuPanel<T> extends StatefulWidget {
  const _MenuPanel({
    super.key,
    required this.level,
    required this.depth,
    required this.autofocus,
    required this.onPick,
    required this.onDismiss,
    required this.onOpenSubmenu,
    required this.onCloseTo,
    required this.onHoverRow,
  });

  final _MenuLevel<T> level;
  final int depth;
  final bool autofocus;
  final ValueChanged<DesktopMenuItem<T>> onPick;
  final VoidCallback onDismiss;
  final void Function(
    int depth,
    DesktopMenuItem<T> item,
    Rect rowRect, {
    bool focus,
  })
  onOpenSubmenu;
  final ValueChanged<int> onCloseTo;
  final ValueChanged<int> onHoverRow;

  @override
  State<_MenuPanel<T>> createState() => _MenuPanelState<T>();
}

class _MenuPanelState<T> extends State<_MenuPanel<T>> {
  /// Row keys, used to find a row's rectangle when opening its submenu.
  late final List<GlobalKey> _rowKeys = List.generate(
    widget.level.items.length,
    (_) => GlobalKey(),
  );

  List<DesktopMenuItem<T>> get _items => widget.level.items;

  /// Global rectangle of row [index].
  Rect? _rowRect(int index) {
    final box = _rowKeys[index].currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  /// Moves the highlight by [delta], skipping dividers and disabled rows.
  void _move(int delta) {
    if (_items.isEmpty) return;
    var i = widget.level.highlighted;
    for (var n = 0; n < _items.length; n++) {
      i = (i + delta) % _items.length;
      if (i < 0) i += _items.length;
      if (_items[i]._selectable) break;
    }
    setState(() => widget.level.highlighted = i);
  }

  /// Picks row [index], or opens its submenu when it has one.
  void _activate(int index, {bool fromKeyboard = false}) {
    if (index < 0 || index >= _items.length) return;
    final item = _items[index];
    if (!item._selectable) return;
    if (item._hasSubmenu) {
      final rect = _rowRect(index);
      if (rect != null) {
        widget.onOpenSubmenu(widget.depth, item, rect, focus: fromKeyboard);
      }
      return;
    }
    widget.onPick(item);
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
    } else if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space) {
      _activate(widget.level.highlighted, fromKeyboard: true);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      final i = widget.level.highlighted;
      if (i >= 0 && _items[i]._hasSubmenu) {
        _activate(i, fromKeyboard: true);
      }
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      // Left closes this submenu; on the root it does nothing.
      if (widget.depth > 0) widget.onCloseTo(widget.depth - 1);
    } else if (key == LogicalKeyboardKey.escape) {
      // Esc backs out one level, closing the menu from the root.
      if (widget.depth > 0) {
        widget.onCloseTo(widget.depth - 1);
      } else {
        widget.onDismiss();
      }
    } else if (key == LogicalKeyboardKey.tab) {
      // Tab never escapes into the page behind the menu.
      _move(HardwareKeyboard.instance.isShiftPressed ? -1 : 1);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height - _screenMargin * 2;
    // Reserve a tick column when any row is checkable so labels line up.
    final hasChecks = _items.any((i) => i.checked != null);
    final hasIcons = _items.any((i) => i.icon != null);
    return Focus(
      focusNode: widget.level.focusNode,
      autofocus: widget.autofocus,
      onKeyEvent: _onKey,
      child: Material(
        type: MaterialType.card,
        color: DesktopPanelColors.surface,
        elevation: 10,
        shadowColor: Colors.black,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: DesktopPanelColors.edge),
        ),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: 200,
            maxWidth: 340,
            maxHeight: maxHeight < 0 ? 0 : maxHeight,
          ),
          child: IntrinsicWidth(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < _items.length; i++)
                    if (_items[i].isDivider)
                      Divider(
                        height: 9,
                        thickness: 1,
                        indent: 8,
                        endIndent: 8,
                        color: DesktopPanelColors.edge,
                      )
                    else
                      _MenuRow<T>(
                        key: _rowKeys[i],
                        item: _items[i],
                        highlighted: widget.level.highlighted == i,
                        reserveCheck: hasChecks,
                        reserveIcon: hasIcons,
                        onHover: () {
                          if (!_items[i]._selectable) return;
                          setState(() => widget.level.highlighted = i);
                          if (_items[i]._hasSubmenu) {
                            _activate(i);
                          } else {
                            widget.onHoverRow(widget.depth);
                          }
                        },
                        onTap: () => _activate(i),
                      ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A single 34px menu row: tick, icon, label, shortcut hint, chevron.
class _MenuRow<T> extends StatelessWidget {
  const _MenuRow({
    super.key,
    required this.item,
    required this.highlighted,
    required this.reserveCheck,
    required this.reserveIcon,
    required this.onHover,
    required this.onTap,
  });

  final DesktopMenuItem<T> item;
  final bool highlighted, reserveCheck, reserveIcon;
  final VoidCallback onHover, onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = item.enabled;
    // Destructive rows use the accent, matching GraphiteSettingsControl.
    final Color fg = !enabled
        ? AppColors.textTertiary
        : item.destructive
        ? AppColors.accent
        : AppColors.textPrimary;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => onHover(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onTap : null,
        child: Container(
          height: _rowHeight,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: highlighted && enabled
                ? DesktopChrome.selectedFill(AppColors.accent)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              if (reserveCheck)
                SizedBox(
                  width: 24,
                  child: item.checked == true
                      ? Icon(Icons.check_rounded, size: 16, color: fg)
                      : null,
                ),
              if (reserveIcon)
                SizedBox(
                  width: 28,
                  child: item.icon == null
                      ? null
                      : Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: Icon(
                            item.icon,
                            size: 18,
                            color: item.destructive && enabled
                                ? AppColors.accent
                                : enabled
                                ? AppColors.textSecondary
                                : AppColors.textTertiary,
                          ),
                        ),
                ),
              Expanded(
                child: Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.body.copyWith(fontSize: 13.5, color: fg),
                ),
              ),
              if (item.shortcut != null) ...[
                const SizedBox(width: 24),
                Text(
                  item.shortcut!,
                  style: AppText.caption.copyWith(
                    fontSize: 12,
                    color: AppColors.textTertiary,
                  ),
                ),
              ],
              if (item._hasSubmenu) ...[
                const SizedBox(width: 12),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: enabled
                      ? AppColors.textSecondary
                      : AppColors.textTertiary,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Gives [child] a Windows context menu: right-click opens it at the
/// pointer, and the Menu key or Shift+F10 opens it at the child's centre
/// while something inside has keyboard focus. Off Windows (and on TV) the
/// child is returned untouched.
class DesktopContextMenuRegion extends StatelessWidget {
  const DesktopContextMenuRegion({
    super.key,
    required this.child,
    required this.items,
    this.enabled = true,
  });

  final Widget child;

  /// Built lazily when the menu opens, so rows reflect current state.
  final List<DesktopMenuItem<Object?>> Function() items;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (!enabled || !desktopPanelsEnabled) return child;
    return Focus(
      // A pass-through node: it never takes focus itself, it only sees keys
      // bubbling up from a focused descendant.
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final key = event.logicalKey;
        final menuKey =
            key == LogicalKeyboardKey.contextMenu ||
            (key == LogicalKeyboardKey.f10 &&
                HardwareKeyboard.instance.isShiftPressed);
        if (!menuKey) return KeyEventResult.ignored;
        final ctx = node.context;
        if (ctx == null) return KeyEventResult.ignored;
        showDesktopContextMenu<Object?>(
          ctx,
          position: _centreOf(ctx),
          items: items(),
        );
        return KeyEventResult.handled;
      },
      child: Builder(
        builder: (regionContext) => GestureDetector(
          // Children that handle their own right-click win the gesture arena
          // (they are deeper), so this only fires where nothing else does.
          behavior: HitTestBehavior.deferToChild,
          onSecondaryTapUp: (details) => showDesktopContextMenu<Object?>(
            regionContext,
            position: details.globalPosition,
            items: items(),
          ),
          child: child,
        ),
      ),
    );
  }
}
