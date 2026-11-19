// Windows-only building blocks shared by the provider (sources) screens:
// desktop settings look from any entry point (src-3), the shared toolbar
// (src-3 B), keyboard shortcuts (src-13 A), row hover / right-click menus
// (src-13 B), the 'Installed' status + '...' menu (src-6 B), install progress
// and readable failures (src-2), the 'Update all' summary (src-5) and the
// add-repo clipboard / drop helper (src-12 B).
//
// Every widget here returns its child untouched (or does nothing) off
// Windows, so phone and TV keep exactly what they show today.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/desktop/desktop_chrome_colors.dart';
import '../../core/desktop/desktop_context_menu.dart';
import '../../core/desktop/desktop_drop_target.dart';
import '../../core/desktop/desktop_native.dart';
import '../../core/provider/extension_install_failure.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart' show desktopTooltipTheme;
import '../../core/theme/app_text.dart';
import '../../core/ui/desktop_docked_panel.dart';
import '../../core/ui/desktop_settings_surface.dart';
import '../../core/ui/global_messenger.dart';
import '../../core/ui/settings_widgets.dart';
import '../../l10n/l10n.dart';

// The provider screens' part files (aniyomi / cloudstream / zangetsu) cannot
// add imports to their parent libraries, which this group does not own; they
// reach these desktop helpers through sources_search_field.dart, which
// re-exports this file. Only the few names those parts need are passed on.
export '../../core/desktop/desktop_context_menu.dart'
    show DesktopMenuItem, showDesktopContextMenu;
export '../../core/ui/desktop_docked_panel.dart' show desktopPanelsEnabled;

/// The settings-style app bar for a provider screen on Windows (a wrapper,
/// so the part files need no new import).
PreferredSizeWidget desktopSourcesAppBar(
  String title, {
  List<Widget>? actions,
}) => settingsAppBar(title, actions: actions);

// ---------------------------------------------------------------------------
// src-3 A: the desktop settings look no matter where a screen is opened from
// ---------------------------------------------------------------------------

/// Puts a provider screen inside [DesktopSettingsScope] on Windows when it
/// was pushed from outside the settings workspace (Home's 'Install sources'
/// prompt, a source catalogue, onboarding). The screens already switch to
/// their desktop layout on that scope, so the entry point no longer decides
/// which look the user gets. Pass-through off Windows and inside settings.
class DesktopProviderScope extends StatelessWidget {
  const DesktopProviderScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (desktopPanelsEnabled && !DesktopSettingsScope.contains(context)) {
      return DesktopSettingsScope(child: child);
    }
    return child;
  }
}

// ---------------------------------------------------------------------------
// src-13 A: Ctrl+F, Esc and F5 on the provider screens
// ---------------------------------------------------------------------------

/// Screen-level keys for a provider screen on Windows:
/// * Ctrl+F focuses the screen's [SourcesSearchField] and selects its text.
/// * F5 (or Ctrl+R) refreshes the repositories: [onRefresh] runs and
///   [DesktopSourcesKeysState.refreshTicks] ticks so repo lists re-fetch.
/// * Esc clears a non-empty search first; with nothing to clear it falls
///   through to the app-wide Esc, which goes back.
///
/// The search field finds this through [DesktopSourcesKeys.maybeOf], so the
/// screens do not need to plumb focus nodes. Pass-through off Windows.
class DesktopSourcesKeys extends StatefulWidget {
  const DesktopSourcesKeys({super.key, required this.child, this.onRefresh});

  final Widget child;

  /// Extra work for F5 (e.g. a bloc event). Optional: repo lists that listen
  /// to [DesktopSourcesKeysState.refreshTicks] refresh themselves.
  final VoidCallback? onRefresh;

  /// The nearest keys scope, or null (off Windows, or outside one). Does not
  /// register a dependency: the state object itself never changes.
  static DesktopSourcesKeysState? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_DesktopSourcesKeysScope>()?.state;

  @override
  State<DesktopSourcesKeys> createState() => DesktopSourcesKeysState();
}

class DesktopSourcesKeysState extends State<DesktopSourcesKeys> {
  /// Focus node the screen's search field adopts so Ctrl+F can reach it.
  final FocusNode searchFocus = FocusNode(debugLabel: 'sources-search');

  /// Ticks on every F5; repo lists listen and re-fetch.
  final ValueNotifier<int> refreshTicks = ValueNotifier<int>(0);

  // The search field currently attached (controller + its change callback).
  TextEditingController? _searchController;
  ValueChanged<String>? _onSearchChanged;

  /// Called by the search field so Esc / Ctrl+F act on it.
  void attachSearch(TextEditingController controller, ValueChanged<String> on) {
    _searchController = controller;
    _onSearchChanged = on;
  }

  /// Called when the search field goes away.
  void detachSearch(TextEditingController controller) {
    if (_searchController != controller) return;
    _searchController = null;
    _onSearchChanged = null;
  }

  /// Moves focus to the search field and selects what is typed there.
  void focusSearch() {
    searchFocus.requestFocus();
    final c = _searchController;
    if (c != null) {
      c.selection = TextSelection(baseOffset: 0, extentOffset: c.text.length);
    }
  }

  /// F5: refresh repositories.
  void refresh() {
    refreshTicks.value++;
    widget.onRefresh?.call();
  }

  /// Clears a non-empty search. True when there was something to clear.
  bool clearSearch() {
    final c = _searchController;
    if (c == null || c.text.isEmpty) return false;
    c.clear();
    _onSearchChanged?.call('');
    return true;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    final key = event.logicalKey;
    final ctrl = keyboard.isControlPressed && !keyboard.isAltPressed;
    if (ctrl && key == LogicalKeyboardKey.keyF) {
      focusSearch();
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.f5 ||
        (ctrl && key == LogicalKeyboardKey.keyR)) {
      refresh();
      return KeyEventResult.handled;
    }
    // Esc: clear first; an empty search lets the app-wide Esc go back.
    if (key == LogicalKeyboardKey.escape && clearSearch()) {
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    searchFocus.dispose();
    refreshTicks.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!desktopPanelsEnabled) return widget.child;
    return _DesktopSourcesKeysScope(
      state: this,
      // Autofocus so a freshly opened screen gets keys before any click;
      // skipTraversal keeps Tab order unchanged.
      child: Focus(
        autofocus: true,
        skipTraversal: true,
        onKeyEvent: _onKey,
        child: widget.child,
      ),
    );
  }
}

/// Carries the keys state down to the search field and repo lists.
class _DesktopSourcesKeysScope extends InheritedWidget {
  const _DesktopSourcesKeysScope({required this.state, required super.child});

  final DesktopSourcesKeysState state;

  @override
  bool updateShouldNotify(_DesktopSourcesKeysScope oldWidget) =>
      oldWidget.state != state;
}

/// Listens to the F5 ticks of the nearest [DesktopSourcesKeys] (if any) and
/// calls [onRefresh] on each one. Repo lists mix this into their state.
mixin DesktopRefreshTicks<T extends StatefulWidget> on State<T> {
  ValueNotifier<int>? _ticks;

  /// Runs on every F5 of the enclosing provider screen.
  void onDesktopRefresh();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ticks = DesktopSourcesKeys.maybeOf(context)?.refreshTicks;
    if (ticks == _ticks) return;
    _ticks?.removeListener(onDesktopRefresh);
    _ticks = ticks?..addListener(onDesktopRefresh);
  }

  @override
  void dispose() {
    _ticks?.removeListener(onDesktopRefresh);
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// src-3 B: the shared desktop toolbar (search + Add repo, no FAB / app bar tabs)
// ---------------------------------------------------------------------------

/// Toolbar at the top of a provider screen body on Windows: optional
/// Installed / Repositories switch, icon actions and an 'Add repo' button in
/// normal flow (no floating button), with the search field below.
///
/// Styled like the rest of the Windows app rather than stock Material: the
/// switch is the compact graphite pill of the top content selector (accent
/// tinted selected segment, no underline), the icon actions are graphite
/// square buttons and 'Add repo' is the secondary graphite button of the
/// sources manager (white / accent stays for primary actions). Every control
/// in the row is [kDesktopSourcesToolbarHeight] tall.
class DesktopSourcesToolbar extends StatelessWidget {
  const DesktopSourcesToolbar({
    super.key,
    this.search,
    this.tabs = const [],
    this.tabController,
    this.onTabTap,
    this.actions = const [],
    this.addLabel,
    this.onAdd,
    this.addKey,
  });

  /// Usually a [SourcesSearchField]; null when the screen lays its search
  /// field out itself (then the toolbar is just the control row).
  final Widget? search;

  /// Tab labels; empty = no tabs. Uses [tabController] or the enclosing
  /// DefaultTabController.
  final List<String> tabs;
  final TabController? tabController;
  final ValueChanged<int>? onTabTap;

  /// Extra buttons (languages, refresh...), shown before Add. Plain
  /// [IconButton]s pick up the graphite square style from this toolbar.
  final List<Widget> actions;

  /// Label of the Add button; hidden when null.
  final String? addLabel;
  final VoidCallback? onAdd;
  final Key? addKey;

  /// Key of the Installed / Repositories switch (tests and screens find the
  /// tabs through it now that there is no Material TabBar).
  static const Key tabsKey = ValueKey('desktop-sources-tabs');

  /// Graphite square style for the toolbar's icon actions (the same family
  /// as the downloads header buttons), sized to the toolbar row.
  static final ButtonStyle iconButtonStyle = IconButton.styleFrom(
    backgroundColor: AppColors.surface2,
    foregroundColor: AppColors.textSecondary,
    disabledBackgroundColor: AppColors.surface2.withValues(alpha: .5),
    disabledForegroundColor: AppColors.textSecondary.withValues(alpha: .4),
    hoverColor: Colors.white.withValues(alpha: .06),
    focusColor: Colors.white.withValues(alpha: .10),
    highlightColor: Colors.white.withValues(alpha: .10),
    iconSize: 18,
    fixedSize: const Size.square(kDesktopSourcesToolbarHeight),
    minimumSize: const Size.square(kDesktopSourcesToolbarHeight),
    padding: EdgeInsets.zero,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
      side: const BorderSide(color: Color(0x29FFFFFF)),
    ),
  );

  @override
  Widget build(BuildContext context) {
    // The secondary graphite button of the sources manager (Settings / Pin
    // to top), trimmed to the row height.
    final add = addLabel == null
        ? null
        : OutlinedButton.icon(
            key: addKey,
            onPressed: onAdd,
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.textPrimary,
              backgroundColor: AppColors.surface2,
              side: const BorderSide(color: Color(0x29FFFFFF)),
              minimumSize: const Size(0, kDesktopSourcesToolbarHeight),
              fixedSize: const Size.fromHeight(kDesktopSourcesToolbarHeight),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: AppText.body.copyWith(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            icon: const Icon(Icons.add_rounded, size: 18),
            label: Text(addLabel!),
          );
    // Icon actions and Add share one trailing group, 8px apart.
    final trailing = <Widget>[...actions, ?add];
    final segmented = tabs.isEmpty
        ? null
        : DesktopSourcesSegmentedTabs(
            key: tabsKey,
            labels: tabs,
            controller: tabController,
            onTap: onTabTap,
          );
    Widget row = LayoutBuilder(
      builder: (context, constraints) {
        final group = Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: trailing,
        );
        // Wide enough: switch on the left, actions on the right, one row.
        // Narrow windows or enlarged text wrap instead of overflowing.
        final scale = MediaQuery.textScalerOf(context).scale(1);
        final wide = constraints.maxWidth >= 560 * scale;
        if (wide && segmented != null && trailing.isNotEmpty) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Flexible (loose): the pill keeps its natural width but its
              // segments get the bounded width they need to shrink.
              Flexible(child: segmented),
              const SizedBox(width: 12),
              group,
            ],
          );
        }
        return Align(
          alignment: Alignment.centerLeft,
          child: Wrap(
            spacing: 12,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [?segmented, if (trailing.isNotEmpty) group],
          ),
        );
      },
    );
    // Plain IconButtons from the screens take the graphite square style;
    // a button that sets its own style still wins.
    row = IconButtonTheme(
      data: IconButtonThemeData(style: iconButtonStyle),
      child: row,
    );
    // Graphite tooltips on the toolbar even when the page's theme lost the
    // app's Windows tooltip theme (pushed routes, nested navigators).
    final tooltipTheme = desktopTooltipTheme();
    if (tooltipTheme != null) {
      row = TooltipTheme(data: tooltipTheme, child: row);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 12, 22, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          row,
          if (search != null) ...[const SizedBox(height: 12), search!],
        ],
      ),
    );
  }
}

/// Height of every control in [DesktopSourcesToolbar]'s row (switch, icon
/// buttons, Add); in step with the search field below it.
const double kDesktopSourcesToolbarHeight = 38;

/// The Installed / Repositories switch: a compact graphite pill with an
/// accent tinted selected segment, the same look as the top content
/// selector (Anime / Movie / TV / Manga / Novel).
///
/// Follows [controller] (or the enclosing DefaultTabController), so swipes
/// in a TabBarView and an initial index stay in sync. Each segment is a
/// focusable button: Tab reaches it, Enter / Space selects it, and the
/// left / right arrow keys move the selection while one has focus.
class DesktopSourcesSegmentedTabs extends StatelessWidget {
  const DesktopSourcesSegmentedTabs({
    super.key,
    required this.labels,
    this.controller,
    this.onTap,
  });

  final List<String> labels;
  final TabController? controller;
  final ValueChanged<int>? onTap;

  // Same tinted fill as the top content pill, blended over the frame once.
  static final Color _fill = Color.alphaBlend(
    const Color(0xB324252B),
    DesktopChrome.frame,
  );

  @override
  Widget build(BuildContext context) {
    final tabs = controller ?? DefaultTabController.maybeOf(context);
    // Selects segment [i]: moves the tab controller, then tells the screen.
    // False when [i] is past either end (nothing changed).
    bool select(int i) {
      if (i < 0 || i >= labels.length) return false;
      tabs?.animateTo(i);
      onTap?.call(i);
      return true;
    }

    // Row height at normal text; grows with enlarged text instead of
    // clipping. Segments shrink (ellipsis) when the row is too narrow.
    Widget pill(int selected) => Container(
      constraints: const BoxConstraints(
        minHeight: kDesktopSourcesToolbarHeight,
      ),
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: _fill,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0x24FFFFFF)),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < labels.length; i++)
              Flexible(
                child: _SegmentButton(
                  key: ValueKey('desktop-sources-tab-$i'),
                  label: labels[i],
                  selected: i == selected,
                  onTap: () => select(i),
                  // Arrow keys step to the neighbouring segment.
                  onStep: (delta) => select(i + delta),
                ),
              ),
          ],
        ),
      ),
    );

    if (tabs == null) return pill(0);
    return AnimatedBuilder(
      animation: tabs,
      builder: (context, _) => pill(tabs.index),
    );
  }
}

/// One segment of [DesktopSourcesSegmentedTabs].
class _SegmentButton extends StatelessWidget {
  const _SegmentButton({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    required this.onStep,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// Selects the segment [delta] steps away in reading order; false when
  /// there is none (first / last segment).
  final bool Function(int delta) onStep;

  /// Arrow key [right] (else left): selects the neighbouring segment and
  /// moves keyboard focus onto it, so Enter / Space and the focus ring stay
  /// on the selected segment. Right-to-left layouts step the other way.
  KeyEventResult _arrow(BuildContext context, {required bool right}) {
    final ltr = Directionality.of(context) == TextDirection.ltr;
    if (onStep(right == ltr ? 1 : -1)) {
      primaryFocus?.focusInDirection(
        right ? TraversalDirection.right : TraversalDirection.left,
      );
    }
    // Handled even at either end, so the arrow never leaves the switch.
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    button: true,
    child: Focus(
      // Catches arrow keys bubbling up from the segment's InkWell; never
      // takes focus itself, so Tab order is just the segments.
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          return _arrow(context, right: true);
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          return _arrow(context, right: false);
        }
        return KeyEventResult.ignored;
      },
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        hoverColor: Colors.white.withValues(alpha: .05),
        focusColor: Colors.white.withValues(alpha: .10),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          // 30 + the pill's 3px padding and 1px border = the 38px row.
          constraints: const BoxConstraints(minHeight: 30),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected
                ? AppColors.accent.withValues(alpha: .18)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(
            label,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: selected ? Colors.white : AppColors.textSecondary,
            ),
          ),
        ),
      ),
    ),
  );
}

/// Fades out every open hover tooltip before a provider screen pushes a
/// route on a nested navigator (the settings workspace's), which the
/// app-wide route observer does not see. Without it the label of the
/// clicked row / button can freeze on top of the pushed page, because the
/// covered page stops ticking mid-fade. Does nothing off Windows.
void dismissDesktopTooltips() {
  if (desktopPanelsEnabled) Tooltip.dismissAllToolTips();
}

/// Desktop list padding (the phone keeps room for its floating button).
const EdgeInsets kDesktopSourcesListPadding = EdgeInsets.fromLTRB(
  22,
  12,
  22,
  24,
);

// ---------------------------------------------------------------------------
// src-13 B: hover highlight + right-click menu on source rows
// ---------------------------------------------------------------------------

/// Wraps one source / extension row on Windows: a soft accent highlight on
/// hover, an optional [tooltip] (full name, version) and a right-click menu
/// built from [items]. Pass-through off Windows.
class DesktopSourceRow extends StatefulWidget {
  const DesktopSourceRow({
    super.key,
    required this.child,
    this.items,
    this.tooltip,
  });

  final Widget child;

  /// Right-click (and Menu key / Shift+F10) actions; null = no menu.
  final List<DesktopMenuItem<Object?>> Function()? items;

  /// Shown after a short hover; null = none.
  final String? tooltip;

  @override
  State<DesktopSourceRow> createState() => _DesktopSourceRowState();
}

class _DesktopSourceRowState extends State<DesktopSourceRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    if (!desktopPanelsEnabled) return widget.child;
    Widget row = MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: _hover
              ? DesktopChrome.selectedFill(AppColors.accent, strength: .08)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: widget.child,
      ),
    );
    final tip = widget.tooltip;
    if (tip != null && tip.isNotEmpty) {
      row = Tooltip(
        message: tip,
        waitDuration: const Duration(milliseconds: 700),
        child: row,
      );
    }
    final items = widget.items;
    if (items == null) return row;
    return DesktopContextMenuRegion(items: items, child: row);
  }
}

/// The standard per-source actions as menu items, in a fixed order. Only
/// the actions with a callback appear. Labels reuse existing translations.
List<DesktopMenuItem<Object?>> desktopSourceMenuItems(
  BuildContext context, {
  VoidCallback? onInstall,
  VoidCallback? onUpdate,
  String? updateLabel,
  VoidCallback? onActivate,
  VoidCallback? onSettings,
  VoidCallback? onOpenSite,
  VoidCallback? onUninstall,
  String? uninstallLabel,
  List<DesktopMenuItem<Object?>> extra = const [],
}) {
  final l10n = context.l10n;
  return [
    if (onInstall != null)
      DesktopMenuItem<Object?>(
        label: l10n.install,
        icon: Icons.download_outlined,
        onTap: onInstall,
      ),
    if (onUpdate != null)
      DesktopMenuItem<Object?>(
        label: updateLabel ?? l10n.update,
        icon: Icons.system_update_alt_rounded,
        onTap: onUpdate,
      ),
    if (onActivate != null)
      DesktopMenuItem<Object?>(
        label: l10n.makeActiveSource,
        icon: Icons.radio_button_checked_rounded,
        onTap: onActivate,
      ),
    if (onSettings != null)
      DesktopMenuItem<Object?>(
        label: l10n.sourceSettings,
        icon: Icons.tune_rounded,
        onTap: onSettings,
      ),
    if (onOpenSite != null)
      DesktopMenuItem<Object?>(
        label: l10n.signInToSource,
        icon: Icons.open_in_browser_rounded,
        onTap: onOpenSite,
      ),
    ...extra,
    if (onUninstall != null) ...[
      const DesktopMenuItem<Object?>.divider(),
      DesktopMenuItem<Object?>(
        label: uninstallLabel ?? l10n.uninstall,
        icon: Icons.delete_outline_rounded,
        destructive: true,
        onTap: onUninstall,
      ),
    ],
  ];
}

// ---------------------------------------------------------------------------
// src-6 B: a non-clickable 'Installed' check + '...' menu
// ---------------------------------------------------------------------------

/// Replaces the clickable 'Installed' button on Windows. The status is only
/// a label (clicking it no longer uninstalls); Update / Settings / Uninstall
/// live in the '...' menu, the same list the row's right-click shows.
class DesktopInstalledActions extends StatelessWidget {
  const DesktopInstalledActions({
    super.key,
    required this.items,
    this.updateAvailable = false,
  });

  final List<DesktopMenuItem<Object?>> Function() items;

  /// Shows an accent dot on the menu button when an update is waiting.
  final bool updateAvailable;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Tooltip(
        message: context.l10n.installedUseMenu,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_rounded, size: 18, color: AppColors.accent),
            const SizedBox(width: 6),
            Text(
              context.l10n.installed,
              style: AppText.caption.copyWith(color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
      const SizedBox(width: 2),
      Builder(
        builder: (buttonContext) => IconButton(
          key: const ValueKey('desktop-installed-more'),
          tooltip: context.l10n.moreActions,
          visualDensity: VisualDensity.compact,
          onPressed: () => showDesktopContextMenu<Object?>(
            buttonContext,
            anchor: buttonContext,
            items: items(),
          ),
          icon: Badge(
            isLabelVisible: updateAvailable,
            smallSize: 7,
            backgroundColor: AppColors.accent,
            child: const Icon(Icons.more_horiz_rounded, size: 20),
          ),
          color: AppColors.textSecondary,
        ),
      ),
    ],
  );
}

// ---------------------------------------------------------------------------
// src-2: install progress + readable failure
// ---------------------------------------------------------------------------

/// Determinate download bar with a Cancel button, in place of the bare row
/// spinner (src-2 B). [value] is null until the size is known.
class DesktopInstallProgress extends StatelessWidget {
  const DesktopInstallProgress({super.key, this.value, this.onCancel});

  final double? value;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final v = value;
    return SizedBox(
      width: 168,
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    key: const ValueKey('desktop-install-progress'),
                    value: v,
                    minHeight: 5,
                    color: AppColors.accent,
                    backgroundColor: AppColors.surface2,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  v == null
                      ? context.l10n.downloading
                      : v >= 1
                      ? context.l10n.installingEllipsis
                      : '${(v * 100).round()}%',
                  style: AppText.caption.copyWith(fontSize: 11),
                ),
              ],
            ),
          ),
          IconButton(
            key: const ValueKey('desktop-install-cancel'),
            tooltip: context.l10n.cancelDownload,
            visualDensity: VisualDensity.compact,
            onPressed: onCancel,
            icon: const Icon(Icons.close_rounded, size: 18),
            color: AppColors.textSecondary,
          ),
        ],
      ),
    );
  }
}

/// Fraction for [DesktopInstallProgress] from Dio's progress numbers.
double? installFraction(int received, int total) =>
    total <= 0 ? null : (received / total).clamp(0.0, 1.0);

/// Shows why an install failed (src-2 A): the readable reason in the
/// snackbar and a 'Copy details' action with the raw error for bug reports.
/// A cancelled download only says so.
void showExtensionInstallFailure(
  ScaffoldMessengerState messenger, {
  required String message,
  required ExtensionInstallFailure failure,
}) {
  messenger
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        duration: Duration(seconds: failure.cancelled ? 3 : 8),
        action: failure.cancelled
            ? null
            : SnackBarAction(
                label: appL10n.copyDetails,
                onPressed: () => Clipboard.setData(
                  ClipboardData(text: '${failure.reason}\n${failure.details}'),
                ),
              ),
      ),
    );
}

// ---------------------------------------------------------------------------
// src-5: 'Update all' summary with Details + Retry
// ---------------------------------------------------------------------------

/// One extension that failed during 'Update all'.
class ExtensionUpdateFailure {
  const ExtensionUpdateFailure({
    required this.name,
    required this.reason,
    this.details = '',
  });

  final String name;
  final String reason;
  final String details;
}

/// Ends an 'Update all' run (src-5 A). With no failures it shows
/// [successText] as before; otherwise 'Updated 3 of 5. 2 failed' with a
/// Details action listing each failure's reason and a Retry button that runs
/// [onRetry] for the failed ones.
void showUpdateAllSummary(
  ScaffoldMessengerState messenger, {
  required int total,
  required int done,
  required List<ExtensionUpdateFailure> failures,
  required String successText,
  Future<void> Function()? onRetry,
}) {
  messenger.clearSnackBars();
  if (failures.isEmpty) {
    messenger.showSnackBar(SnackBar(content: Text(successText)));
    return;
  }
  messenger.showSnackBar(
    SnackBar(
      content: Text(updateAllSummaryText(done: done, total: total)),
      duration: const Duration(seconds: 10),
      action: SnackBarAction(
        label: appL10n.details,
        onPressed: () {
          final context = rootNavigatorKey.currentContext;
          if (context == null) return;
          showUpdateFailuresDialog(
            context,
            failures: failures,
            onRetry: onRetry,
          );
        },
      ),
    ),
  );
}

/// 'Updated 3 of 5. 2 failed'. Uses appL10n (no context needed).
String updateAllSummaryText({required int done, required int total}) =>
    appL10n.updatedDoneOfTotal(done, total, total - done);

/// Graphite dialog listing failed updates with their reasons, plus Copy
/// details and Retry (failed only).
Future<void> showUpdateFailuresDialog(
  BuildContext context, {
  required List<ExtensionUpdateFailure> failures,
  Future<void> Function()? onRetry,
}) => showDialog<void>(
  context: context,
  builder: (dialogContext) => DesktopEscCloses(
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
        constraints: BoxConstraints(
          maxWidth: 560,
          maxHeight: MediaQuery.sizeOf(dialogContext).height * .8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DesktopPanelTitleBar(
              title: appL10n.updatesThatFailed,
              subtitle: appL10n.extensionsNotUpdated(failures.length),
            ),
            Divider(height: 1, color: DesktopPanelColors.edge),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  for (final f in failures)
                    ListTile(
                      leading: Icon(
                        Icons.error_outline_rounded,
                        color: AppColors.accent,
                      ),
                      title: Text(
                        f.name,
                        style: AppText.body.copyWith(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: Text(f.reason, style: AppText.caption),
                    ),
                ],
              ),
            ),
            Divider(height: 1, color: DesktopPanelColors.edge),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: () => Clipboard.setData(
                      ClipboardData(
                        text: [
                          for (final f in failures)
                            '${f.name}: ${f.reason}'
                                '${f.details.isEmpty ? '' : '\n  ${f.details}'}',
                        ].join('\n'),
                      ),
                    ),
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    label: Text(appL10n.copyDetails),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: Text(
                      MaterialLocalizations.of(dialogContext).closeButtonLabel,
                    ),
                  ),
                  if (onRetry != null) ...[
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      key: const ValueKey('update-failures-retry'),
                      onPressed: () {
                        Navigator.of(dialogContext).pop();
                        unawaited(onRetry());
                      },
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: Text(appL10n.retry),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  ),
);

// ---------------------------------------------------------------------------
// src-12 B: add-repo dialogs take a link from the clipboard or a drop
// ---------------------------------------------------------------------------

/// The first repo / addon link in [text], or null. `stremio://` links become
/// `https://` (what Stremio's own 'Install' buttons point at). With
/// [whole] the text must be just the link (used for the clipboard, so a
/// copied paragraph that happens to contain a link is not grabbed).
String? extractRepoLink(String? text, {bool whole = false}) {
  final raw = text?.trim();
  if (raw == null || raw.isEmpty) return null;
  if (whole && raw.contains(RegExp(r'\s'))) return null;
  final match = RegExp(r'''(https?|stremio)://[^\s"'<>]+''').firstMatch(raw);
  if (match == null) return null;
  if (whole && match.start != 0) return null;
  var link = match.group(0)!;
  if (link.startsWith('stremio://')) {
    link = 'https://${link.substring('stremio://'.length)}';
  }
  final uri = Uri.tryParse(link);
  if (uri == null || uri.host.isEmpty) return null;
  return link;
}

/// Pulls a link out of a dropped file: an Internet shortcut (`.url`), a text
/// file, or a JSON file with a top-level `url` / `manifestUrl` / `repoUrl`.
/// Null when the file holds none (or is too big to be a link file).
Future<String?> repoLinkFromFile(String path) async {
  try {
    final file = File(path);
    if (!await file.exists() || await file.length() > 512 * 1024) return null;
    final text = await file.readAsString();
    final lower = path.toLowerCase();
    if (lower.endsWith('.url')) {
      final line = LineSplitter.split(text).firstWhere(
        (l) => l.trim().toUpperCase().startsWith('URL='),
        orElse: () => '',
      );
      return extractRepoLink(line.trim().substring(line.isEmpty ? 0 : 4));
    }
    if (lower.endsWith('.json')) {
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        for (final key in const ['url', 'manifestUrl', 'repoUrl']) {
          final value = decoded[key];
          if (value is String) return extractRepoLink(value);
        }
      }
      return null;
    }
    return extractRepoLink(text);
  } catch (_) {
    return null;
  }
}

/// Wraps an add-repo / add-addon form on Windows (src-12 B):
/// * when it opens with an empty field, a link alone on the clipboard is
///   filled in (selected, so typing replaces it), with a small note;
/// * a link dragged from a browser, or a `.url` / `.json` / `.txt` file
///   dragged from Explorer, fills the field.
/// Pass-through off Windows.
class DesktopAddRepoAssist extends StatefulWidget {
  const DesktopAddRepoAssist({
    super.key,
    required this.controller,
    required this.child,
    this.onFilled,
  });

  /// The URL field's controller.
  final TextEditingController controller;
  final Widget child;

  /// Called after a link was put into the field (e.g. to clear an error).
  final VoidCallback? onFilled;

  @override
  State<DesktopAddRepoAssist> createState() => _DesktopAddRepoAssistState();
}

class _DesktopAddRepoAssistState extends State<DesktopAddRepoAssist> {
  bool _hover = false;

  /// Note under the form: where the link came from, or why a drop failed.
  String? _note;

  @override
  void initState() {
    super.initState();
    if (desktopPanelsEnabled) unawaited(_prefillFromClipboard());
  }

  Future<void> _prefillFromClipboard() async {
    if (widget.controller.text.trim().isNotEmpty) return;
    ClipboardData? data;
    try {
      data = await Clipboard.getData(Clipboard.kTextPlain);
    } catch (_) {
      return;
    }
    final link = extractRepoLink(data?.text, whole: true);
    // The user may have started typing while the clipboard was read.
    if (link == null || !mounted || widget.controller.text.isNotEmpty) return;
    _fill(link, context.l10n.filledFromClipboard);
  }

  void _fill(String link, String note) {
    widget.controller.value = TextEditingValue(
      text: link,
      selection: TextSelection(baseOffset: 0, extentOffset: link.length),
    );
    setState(() => _note = note);
    widget.onFilled?.call();
  }

  Future<void> _onDrop(DesktopDropEvent event) async {
    String? link = extractRepoLink(event.text);
    if (link == null && event.paths.isNotEmpty) {
      link = await repoLinkFromFile(event.paths.first);
    }
    if (!mounted) return;
    if (link == null) {
      setState(() => _note = context.l10n.noRepoLinkInDrop);
      return;
    }
    _fill(link, context.l10n.linkTakenFromDrop);
  }

  @override
  Widget build(BuildContext context) {
    if (!desktopPanelsEnabled) return widget.child;
    return DesktopDropTarget(
      acceptText: true,
      acceptFiles: true,
      onHoverChanged: (hover) => setState(() => _hover = hover),
      onDrop: (event) => unawaited(_onDrop(event)),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _hover ? AppColors.accent : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            widget.child,
            const SizedBox(height: 8),
            Text(
              _hover
                  ? context.l10n.dropLinkHere
                  : _note ?? context.l10n.youCanAlsoDragLink,
              key: const ValueKey('add-repo-assist-note'),
              style: AppText.caption.copyWith(
                color: _hover ? AppColors.accent : AppColors.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
