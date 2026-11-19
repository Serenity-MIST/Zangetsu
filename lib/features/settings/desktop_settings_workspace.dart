import 'package:flutter/material.dart';

import '../../core/desktop/desktop_chrome_colors.dart';
import '../../core/desktop/desktop_shortcut_catalog.dart';
import '../../core/desktop/desktop_shortcuts.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/desktop_settings_surface.dart';
import 'desktop_settings_icon.dart';

/// One real settings destination; selection never changes a preference value.
class DesktopSettingsDestination {
  const DesktopSettingsDestination({
    required this.id,
    required this.title,
    required this.icon,
    required this.onOpen,
  });

  final String id;
  final String title;
  final IconData icon;
  final VoidCallback onOpen;
}

/// Settings-only desktop frame based on the supplied graphite reference.
/// The content navigator is supplied by the owner so leaf pages stay inside
/// this frame. Narrow windows retain a labeled-by-tooltip icon rail.
///
/// Keyboard (set-3 / set-8): Ctrl+F or Ctrl+K focuses [search] from any
/// settings page, Ctrl+1..9 jump to the first nine sections, and Up / Down
/// move through the sidebar while it has focus.
class DesktopSettingsWorkspace extends StatefulWidget {
  const DesktopSettingsWorkspace({
    super.key,
    required this.title,
    required this.selectedId,
    required this.destinations,
    required this.onExit,
    required this.child,
    this.search,
    this.onSearchShortcut,
  });

  final String title;
  final String selectedId;
  final List<DesktopSettingsDestination> destinations;
  final VoidCallback onExit;
  final Widget child;

  /// set-3: the always-visible search box. Sits in the sidebar under the
  /// title; on a narrow window (icon rail) it sits above the page instead.
  final Widget? search;

  /// Ctrl+F / Ctrl+K (`settings.search`): focus [search].
  final VoidCallback? onSearchShortcut;

  @override
  State<DesktopSettingsWorkspace> createState() =>
      _DesktopSettingsWorkspaceState();
}

class _DesktopSettingsWorkspaceState extends State<DesktopSettingsWorkspace> {
  // One focus node per sidebar item, so arrow keys and Ctrl+number can move
  // keyboard focus along with the selection.
  final Map<String, FocusNode> _nodes = {};

  @override
  void initState() {
    super.initState();
    // Idempotent; makes the settings.* and app.section* keys resolvable even
    // when the prefs box (which normally registers them) was never opened.
    registerDefaultDesktopShortcuts();
    DesktopShortcuts.changes.addListener(_onShortcutsChanged);
  }

  @override
  void dispose() {
    DesktopShortcuts.changes.removeListener(_onShortcutsChanged);
    for (final node in _nodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  // Remapped keys take effect without leaving Settings.
  void _onShortcutsChanged() {
    if (mounted) setState(() {});
  }

  FocusNode _nodeFor(String id) =>
      _nodes.putIfAbsent(id, () => FocusNode(debugLabel: 'settings-nav-$id'));

  /// Opens the destination at [index] and moves keyboard focus onto it.
  void _openAt(int index) {
    final list = widget.destinations;
    if (index < 0 || index >= list.length) return;
    list[index].onOpen();
    _nodeFor(list[index].id).requestFocus();
  }

  /// set-8: Up / Down step through the sidebar from the selected (or focused)
  /// item; the content follows, like a list where selection follows focus.
  void _step(int delta) {
    final list = widget.destinations;
    if (list.isEmpty) return;
    var current = list.indexWhere((d) => _nodes[d.id]?.hasFocus ?? false);
    if (current < 0) {
      current = list.indexWhere((d) => d.id == widget.selectedId);
    }
    _openAt((current < 0 ? 0 : current + delta).clamp(0, list.length - 1));
  }

  /// Keys handled anywhere inside Settings.
  Map<ShortcutActivator, VoidCallback> _workspaceBindings() =>
      DesktopShortcuts.bindings({
        if (widget.onSearchShortcut != null)
          'settings.search': widget.onSearchShortcut!,
        // Ctrl+1..9 jump to sidebar sections while Settings has focus.
        for (var i = 1; i <= 9; i++) 'app.section$i': () => _openAt(i - 1),
      });

  /// Keys handled only while focus sits in the sidebar, so Up / Down keep
  /// scrolling and moving through rows on the pages themselves.
  Map<ShortcutActivator, VoidCallback> _sidebarBindings() =>
      DesktopShortcuts.bindings({
        'settings.nextSection': () => _step(1),
        'settings.previousSection': () => _step(-1),
      });

  // The frame, sidebar and content canvas follow Pure black / Background
  // colour; the rebuild scope re-runs every open settings page on a change so
  // the new background shows without leaving the page.
  @override
  Widget build(BuildContext context) => DesktopThemeRebuildScope(
    child: CallbackShortcuts(
      bindings: _workspaceBindings(),
      // Holds focus when nothing inside has it yet, so the shortcuts above
      // work as soon as Settings opens.
      child: Focus(
        autofocus: true,
        skipTraversal: true,
        debugLabel: 'desktop-settings-workspace',
        child: Builder(builder: _frame),
      ),
    ),
  );

  Widget _frame(BuildContext context) => Material(
    key: const ValueKey('desktop-settings-frame'),
    color: DesktopChrome.frame,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 900;
        final search = widget.search;
        return Row(
          children: [
            Container(
              key: const ValueKey('desktop-settings-sidebar'),
              width: compact ? 76 : 236,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: DesktopChrome.sidebarGradient,
                ),
                border: Border(
                  right: BorderSide(color: DesktopChrome.sidebarEdge),
                ),
              ),
              child: Column(
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      12,
                      22,
                      12,
                      search != null && !compact ? 12 : 20,
                    ),
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: MaterialLocalizations.of(
                            context,
                          ).backButtonTooltip,
                          onPressed: widget.onExit,
                          icon: const Icon(Icons.arrow_back_rounded, size: 20),
                          color: AppColors.textSecondary,
                        ),
                        if (!compact) const SizedBox(width: 8),
                        if (!compact)
                          Expanded(
                            child: Text(
                              widget.title,
                              style: AppText.headline.copyWith(
                                fontSize: 25,
                                color: AppColors.textPrimary,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  // set-3: search stays in view above the sections, whatever
                  // page is open.
                  if (search != null && !compact) search,
                  Expanded(
                    child: CallbackShortcuts(
                      bindings: _sidebarBindings(),
                      child: FocusTraversalGroup(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: Column(
                            children: [
                              for (final destination in widget.destinations)
                                _WorkspaceDestination(
                                  destination: destination,
                                  selected:
                                      destination.id == widget.selectedId,
                                  compact: compact,
                                  focusNode: _nodeFor(destination.id),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: DesktopSettingsScope(
                child: Theme(
                  data: _contentTheme(context),
                  child: search != null && compact
                      // Narrow window: the rail has no room for a text box,
                      // so the search bar heads the content instead.
                      ? Column(
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: search,
                            ),
                            Expanded(child: widget.child),
                          ],
                        )
                      : widget.child,
                ),
              ),
            ),
          ],
        );
      },
    ),
  );

  /// Form and dialog chrome for the settings navigator. Scoped here so
  /// controllers, validation and device settings remain with their owners.
  /// set-9: every colour derives from the frame (see GraphiteSettingsColors).
  ThemeData _contentTheme(BuildContext context) {
    final edge = GraphiteSettingsColors.dialogEdge;
    final error = Theme.of(context).colorScheme.error;
    return Theme.of(context).copyWith(
      scaffoldBackgroundColor: DesktopChrome.frame,
      canvasColor: DesktopChrome.frame,
      dividerColor: GraphiteSettingsColors.panelEdge,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: GraphiteSettingsColors.inputFill,
        hoverColor: GraphiteSettingsColors.inputHover,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        labelStyle: AppText.body.copyWith(color: AppColors.textSecondary),
        hintStyle: AppText.caption.copyWith(color: AppColors.textTertiary),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: edge),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.accent, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: error, width: 1.5),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: GraphiteSettingsColors.dialog,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: GraphiteSettingsColors.dialog,
        showDragHandle: false,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
    );
  }
}

/// Sidebar selection uses a red edge, not a second app-wide navigation dock.
class _WorkspaceDestination extends StatefulWidget {
  const _WorkspaceDestination({
    required this.destination,
    required this.selected,
    required this.compact,
    required this.focusNode,
  });

  final DesktopSettingsDestination destination;
  final bool selected;
  final bool compact;
  final FocusNode focusNode;

  @override
  State<_WorkspaceDestination> createState() => _WorkspaceDestinationState();
}

/// Keyboard focus remains visible independently of the pointer hover state.
class _WorkspaceDestinationState extends State<_WorkspaceDestination> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.selected || _hovered || _focused;
    final destination = widget.destination;
    final content = AnimatedContainer(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 180),
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        // Accent-tinted over the frame, so it follows accent and background.
        color: active
            ? DesktopChrome.selectedFill(AppColors.accent, strength: .1)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        border: Border(
          left: BorderSide(
            color: widget.selected ? AppColors.accent : Colors.transparent,
            width: 3,
          ),
        ),
      ),
      child: Semantics(
        label: widget.compact ? destination.title : null,
        selected: widget.selected,
        button: true,
        child: InkWell(
          key: ValueKey('desktop-nav-${destination.id}'),
          focusNode: widget.focusNode,
          onTap: () {
            // A clicked item takes keyboard focus (as in Windows Settings),
            // so Up / Down continue from it.
            widget.focusNode.requestFocus();
            destination.onOpen();
          },
          onHover: (value) => setState(() => _hovered = value),
          onFocusChange: (value) => setState(() => _focused = value),
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: widget.compact ? 13 : 18,
              vertical: 15,
            ),
            child: Row(
              children: [
                DesktopSettingsIcon(
                  section: destination.id,
                  fallback: destination.icon,
                  color: widget.selected
                      ? AppColors.accent
                      : AppColors.textSecondary,
                  size: 22,
                ),
                if (!widget.compact) ...[
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      destination.title,
                      style: AppText.body.copyWith(
                        color: AppColors.textPrimary,
                        fontWeight: widget.selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    return widget.compact
        ? Tooltip(
            message: destination.title,
            excludeFromSemantics: true,
            child: content,
          )
        : content;
  }
}

/// A desktop settings action inside a shared graphite panel. The full row is
/// clickable, and trailing values remain supplied by their actual state owner.
class DesktopSettingsAction extends StatelessWidget {
  const DesktopSettingsAction({
    super.key,
    required this.title,
    required this.icon,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  final String title;
  final String? subtitle;
  final IconData icon;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: onTap,
      hoverColor: Colors.white.withValues(alpha: 0.035),
      focusColor: AppColors.accent.withValues(alpha: 0.09),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
        child: Row(
          children: [
            ExcludeSemantics(
              child: Icon(icon, color: AppColors.textSecondary, size: 23),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: AppText.body.copyWith(color: AppColors.textPrimary),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 5),
                    Text(
                      subtitle!,
                      style: AppText.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 16),
              Flexible(child: trailing!),
            ],
          ],
        ),
      ),
    ),
  );
}
