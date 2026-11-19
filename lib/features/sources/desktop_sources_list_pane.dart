// Left pane of the Windows Sources manager: 'Search sources' box, the
// Streaming / Manga / Novel chips and the installed sources of that kind.
// Repositories are not listed here: they are managed in Settings > Sources
// (or '⋯ > All ecosystems…'), which an empty list links to.
//
// Purely presentational: the manager owns the selection, query and kind and
// passes callbacks down. Rows are not focusable one by one; the list has a
// single focus node and the manager moves the selection with Up / Down, so
// Enter can mean Browse rather than 'activate the focused row'.

import 'dart:async';

import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/desktop/desktop_context_menu.dart';
import '../../core/desktop/extension_load_failures.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/source_icon_tile.dart';
import '../../l10n/l10n.dart';
import 'desktop_add_repo_dialog.dart' show DesktopEngineMissingNotice;
import 'desktop_sources_model.dart';

/// Fixed height of one source row (keeps scrolling arithmetic simple).
const double kDesktopSourceRowHeight = 58;

/// Everything the list pane draws, handed down by the manager.
class DesktopSourcesListPane extends StatelessWidget {
  const DesktopSourcesListPane({
    super.key,
    required this.searchController,
    required this.searchFocus,
    required this.listFocus,
    required this.onQueryChanged,
    required this.kind,
    required this.onKindChanged,
    required this.sources,
    required this.selectedKey,
    required this.onSelectSource,
    required this.onBrowseSource,
    required this.sourceMenu,
    required this.onManageInSettings,
    required this.onContentSearch,
    required this.onMove,
    required this.onSubmit,
    required this.selectedRowKey,
    this.showEngineMissing = false,
    this.loadFailures = 0,
    this.caption,
    this.totalSources = 0,
  });

  final TextEditingController searchController;
  final FocusNode searchFocus;

  /// Focus node of the list itself (Up / Down / Enter land here).
  final FocusNode listFocus;
  final ValueChanged<String> onQueryChanged;

  /// Selected chip (Streaming, Manga or Novel; there is no 'All').
  final DesktopSourceKind kind;
  final ValueChanged<DesktopSourceKind> onKindChanged;

  /// Already filtered and ordered (pinned first).
  final List<DesktopSourceEntry> sources;

  /// `src:<id>` of the selected source.
  final String? selectedKey;
  final ValueChanged<DesktopSourceEntry> onSelectSource;
  final ValueChanged<DesktopSourceEntry> onBrowseSource;

  /// Right-click items for a source row.
  final List<DesktopMenuItem<Object?>> Function(DesktopSourceEntry) sourceMenu;

  /// Opens Settings > Sources (offered when this kind has no sources).
  final VoidCallback onManageInSettings;

  /// Opens the content search across sources (the old app-bar search).
  final VoidCallback onContentSearch;

  /// Up / Down from the search box: move the selection by [delta].
  final ValueChanged<int> onMove;

  /// Enter in the search box: browse the selected source.
  final VoidCallback onSubmit;

  /// Attached to the selected row so the manager can scroll it into view.
  final GlobalKey selectedRowKey;

  /// Aniyomi / Mihon engine files are missing (Windows).
  final bool showEngineMissing;

  /// Extensions that failed to load (banner with Details / Retry).
  final int loadFailures;

  /// Small summary under the list ('12 sources · 2 updates · Active: X').
  final String? caption;

  /// Installed sources before filtering (tells 'no matches' from 'none').
  final int totalSources;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 330,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _search(context),
          const SizedBox(height: 12),
          _chips(context),
          const SizedBox(height: 12),
          Expanded(child: _scrollArea(context)),
        ],
      ),
    );
  }

  /// 'Search sources' (Ctrl+F) with Up / Down / Enter driving the list, and
  /// the content-search button beside it.
  Widget _search(BuildContext context) => Row(
    children: [
      Expanded(
        child: CallbackShortcuts(
          // Closer to the field than the app's text-editing shortcuts, so
          // Up / Down move the selection instead of the caret.
          bindings: {
            const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                onMove(1),
            const SingleActivator(LogicalKeyboardKey.arrowUp): () => onMove(-1),
          },
          child: ValueListenableBuilder<TextEditingValue>(
            valueListenable: searchController,
            builder: (context, value, _) => TextField(
              key: const ValueKey('desktop-sources-search'),
              controller: searchController,
              focusNode: searchFocus,
              onChanged: onQueryChanged,
              onSubmitted: (_) => onSubmit(),
              style: AppText.body.copyWith(color: AppColors.textPrimary),
              cursorColor: AppColors.accent,
              decoration: InputDecoration(
                isDense: true,
                hintText: '${context.l10n.searchSources}  (Ctrl+F)',
                hintStyle: AppText.body.copyWith(color: AppColors.textTertiary),
                prefixIcon: const Icon(
                  Icons.search,
                  size: 18,
                  color: AppColors.textTertiary,
                ),
                suffixIcon: value.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '${context.l10n.clear} (Esc)',
                        icon: const Icon(Icons.close_rounded, size: 16),
                        onPressed: () {
                          searchController.clear();
                          onQueryChanged('');
                        },
                      ),
                filled: true,
                fillColor: AppColors.surface2,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: AppColors.hairline),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: AppColors.accent),
                ),
              ),
            ),
          ),
        ),
      ),
      const SizedBox(width: 6),
      IconButton(
        key: const ValueKey('desktop-sources-content-search'),
        // Translated tooltip.
        tooltip: context.l10n.desktopSearchTitlesInSources,
        onPressed: onContentSearch,
        icon: const Icon(Icons.manage_search_rounded),
        color: AppColors.textSecondary,
      ),
    ],
  );

  /// Streaming / Manga / Novel (no 'All': one kind is always picked).
  Widget _chips(BuildContext context) {
    final l10n = context.l10n;
    final options = <(DesktopSourceKind, String)>[
      (DesktopSourceKind.streaming, l10n.modeStreaming),
      (DesktopSourceKind.manga, l10n.modeManga),
      (DesktopSourceKind.novel, l10n.modeNovel),
    ];
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final (k, label) in options)
          _Chip(
            key: ValueKey('desktop-sources-chip-${k.name}'),
            label: label,
            selected: kind == k,
            onTap: () => onKindChanged(k),
          ),
      ],
    );
  }

  /// Banners, the sources (or the empty note) and the caption.
  Widget _scrollArea(BuildContext context) {
    return Focus(
      focusNode: listFocus,
      child: Builder(
        builder: (context) {
          // Only the list's own node, not a banner or button inside it.
          final listFocused = Focus.of(context).hasPrimaryFocus;
          return ListView(
            key: const ValueKey('desktop-sources-list'),
            padding: EdgeInsets.zero,
            children: [
              if (loadFailures > 0) ...[
                _LoadFailuresBanner(count: loadFailures),
                const SizedBox(height: 10),
              ],
              if (showEngineMissing) ...[
                const DesktopEngineMissingNotice(),
                const SizedBox(height: 10),
              ],
              if (sources.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  child: Text(
                    // No query: this kind simply has nothing installed.
                    // With a query: the search found nothing.
                    totalSources == 0 || searchController.text.trim().isEmpty
                        ? context.l10n.noSourcesInstalled
                        : context.l10n.noMatchesFound,
                    textAlign: TextAlign.center,
                    style: AppText.caption,
                  ),
                ),
              // Nothing of this kind installed (not just a search miss):
              // point to Settings > Sources, where repositories are managed,
              // instead of offering an Add repository button here.
              if (sources.isEmpty && searchController.text.trim().isEmpty)
                Center(
                  child: FilledButton.tonalIcon(
                    key: const ValueKey('desktop-sources-manage-settings'),
                    onPressed: onManageInSettings,
                    icon: const Icon(Icons.settings_outlined, size: 18),
                    // Translated label (English fallback in app_en.arb).
                    label: Text(context.l10n.desktopManageSourcesInSettings),
                  ),
                ),
              for (final s in sources)
                _SourceRow(
                  key: 'src:${s.id}' == selectedKey
                      ? selectedRowKey
                      : ValueKey('desktop-source-row-${s.id}'),
                  entry: s,
                  selected: 'src:${s.id}' == selectedKey,
                  focusRing: listFocused && 'src:${s.id}' == selectedKey,
                  onTap: () {
                    listFocus.requestFocus();
                    onSelectSource(s);
                  },
                  onDoubleTap: () => onBrowseSource(s),
                  menu: () => sourceMenu(s),
                ),
              if (caption != null && caption!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                  child: Text(
                    caption!,
                    key: const ValueKey('desktop-sources-caption'),
                    style: AppText.caption.copyWith(
                      color: AppColors.textTertiary,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
            ],
          );
        },
      ),
    );
  }
}

/// Filter chip in the app's tab style: accentSoft fill with accent text when
/// selected, a hairline outline otherwise.
class _Chip extends StatelessWidget {
  const _Chip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: selected ? AppColors.accentSoft : Colors.transparent,
    shape: StadiumBorder(
      side: BorderSide(
        color: selected ? Colors.transparent : const Color(0x29FFFFFF),
      ),
    ),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      hoverColor: AppColors.hairline,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
        child: Text(
          label,
          style: AppText.caption.copyWith(
            color: selected ? AppColors.accent : AppColors.textPrimary,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    ),
  );
}

/// Shared row chrome: hover fill, selected accentSoft fill with an accent
/// border, a stronger border while the list has keyboard focus, and the
/// right-click menu.
class _RowShell extends StatefulWidget {
  const _RowShell({
    required this.selected,
    required this.focusRing,
    required this.onTap,
    required this.menu,
    required this.child,
    this.onDoubleTap,
    this.height,
    this.tooltip,
  });

  final bool selected;
  final bool focusRing;
  final VoidCallback onTap;
  final VoidCallback? onDoubleTap;
  final List<DesktopMenuItem<Object?>> Function() menu;
  final Widget child;
  final double? height;
  final String? tooltip;

  @override
  State<_RowShell> createState() => _RowShellState();
}

class _RowShellState extends State<_RowShell> {
  bool _hover = false;

  /// When the previous click landed. A second click within the double-tap
  /// window counts as a double click. Tracked by hand because a
  /// GestureDetector with onDoubleTap delays every single click (selection
  /// would lag by 300 ms).
  DateTime? _lastTap;

  void _onTap() {
    final now = DateTime.now();
    final last = _lastTap;
    widget.onTap();
    if (last != null && now.difference(last) < kDoubleTapTimeout) {
      _lastTap = null;
      widget.onDoubleTap?.call();
    } else {
      _lastTap = now;
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    Widget row = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 110),
          height: widget.height,
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.accentSoft
                : _hover
                ? AppColors.hairline
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected
                  ? AppColors.accent.withValues(
                      alpha: widget.focusRing ? 0.9 : 0.45,
                    )
                  : Colors.transparent,
              width: widget.focusRing ? 1.6 : 1,
            ),
          ),
          child: widget.child,
        ),
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
    return DesktopContextMenuRegion(items: widget.menu, child: row);
  }
}

/// One installed source: icon, name, 'Ecosystem · LANG', plus small marks
/// for pinned, update and disabled.
class _SourceRow extends StatelessWidget {
  const _SourceRow({
    super.key,
    required this.entry,
    required this.selected,
    required this.focusRing,
    required this.onTap,
    required this.onDoubleTap,
    required this.menu,
  });

  final DesktopSourceEntry entry;
  final bool selected;
  final bool focusRing;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final List<DesktopMenuItem<Object?>> Function() menu;

  @override
  Widget build(BuildContext context) {
    final dim = !entry.enabled;
    return _RowShell(
      selected: selected,
      focusRing: focusRing,
      onTap: onTap,
      onDoubleTap: onDoubleTap,
      menu: menu,
      height: kDesktopSourceRowHeight,
      tooltip: [
        entry.name,
        if (entry.version.isNotEmpty) 'v${entry.version}',
        if (entry.repoName.isNotEmpty) entry.repoName,
      ].join(' · '),
      child: Row(
        children: [
          Opacity(
            opacity: dim ? 0.5 : 1,
            child: SourceIconTile(
              name: entry.name,
              icon: entry.iconUrl,
              size: 36,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.body.copyWith(
                    color: dim
                        ? AppColors.textSecondary
                        : AppColors.textPrimary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  dim
                      ? '${desktopSourceSubtitle(entry)} · Off'
                      : desktopSourceSubtitle(entry),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption,
                ),
              ],
            ),
          ),
          if (entry.hasUpdate)
            Tooltip(
              message: context.l10n.update,
              child: Container(
                width: 8,
                height: 8,
                margin: const EdgeInsets.only(left: 6),
                decoration: BoxDecoration(
                  color: AppColors.accent,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          _PinMark(id: entry.id),
        ],
      ),
    );
  }
}

/// Filled pin shown on pinned rows (listens to the pin store via the
/// manager's rebuilds; reads the current value here).
class _PinMark extends StatelessWidget {
  const _PinMark({required this.id});

  final String id;

  @override
  Widget build(BuildContext context) {
    final pinned = _DesktopPinnedScope.of(context).contains(id);
    if (!pinned) return const SizedBox.shrink();
    return const Padding(
      padding: EdgeInsets.only(left: 6),
      child: Icon(Icons.push_pin, size: 14, color: AppColors.textTertiary),
    );
  }
}

/// Hands the pinned ids down to the rows (set by the manager).
class _DesktopPinnedScope extends InheritedWidget {
  const _DesktopPinnedScope({required this.pinned, required super.child});

  final List<String> pinned;

  static List<String> of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_DesktopPinnedScope>()
          ?.pinned ??
      const [];

  @override
  bool updateShouldNotify(_DesktopPinnedScope old) => old.pinned != pinned;
}

/// Wraps the list pane so its rows can show pin marks.
Widget desktopPinnedScope(List<String> pinned, Widget child) =>
    _DesktopPinnedScope(pinned: pinned, child: child);

/// Windows banner: how many extensions failed to load, with Details (the
/// full list) and Retry, as the old Providers hub showed it.
class _LoadFailuresBanner extends StatefulWidget {
  const _LoadFailuresBanner({required this.count});

  final int count;

  @override
  State<_LoadFailuresBanner> createState() => _LoadFailuresBannerState();
}

class _LoadFailuresBannerState extends State<_LoadFailuresBanner> {
  /// True while Retry runs.
  bool _retrying = false;

  Future<void> _retry() async {
    setState(() => _retrying = true);
    await ExtensionLoadFailures.retryAll();
    if (mounted) setState(() => _retrying = false);
  }

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('desktop-sources-load-failures'),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: AppColors.accentSoft,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.error_outline_rounded,
              size: 18,
              color: AppColors.accent,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                context.l10n.extensionsFailedToLoad(widget.count),
                style: AppText.caption.copyWith(color: AppColors.textPrimary),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => unawaited(showExtensionLoadFailures(context)),
              child: Text(context.l10n.details),
            ),
            const SizedBox(width: 6),
            FilledButton(
              onPressed: _retrying ? null : () => unawaited(_retry()),
              child: _retrying
                  ? const SizedBox.square(
                      dimension: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(context.l10n.retry),
            ),
          ],
        ),
      ],
    ),
  );
}
