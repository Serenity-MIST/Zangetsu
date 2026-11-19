import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/desktop/desktop_chrome_colors.dart';
import '../../core/desktop/desktop_context_menu.dart';
import '../../core/desktop/desktop_multi_select.dart';
import '../../core/desktop/desktop_undo_toast.dart';
import '../../core/di/injector.dart';
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/desktop_settings_surface.dart';
import '../../core/ui/settings_widgets.dart';
import '../../core/zmode/match_store.dart';
import '../../core/zmode/zmode_ids.dart';
import '../../l10n/l10n.dart';

/// One hand-made match as the page shows it.
@visibleForTesting
class ManualMatchRow {
  const ManualMatchRow({
    required this.canonical,
    required this.match,
    required this.title,
    required this.sourceName,
  });

  final ZCanonical canonical;
  final SourceMatch match;

  /// The metadata title's name (remembered at pin time), else the source's
  /// show name for pins made before names were remembered.
  final String title;
  final String sourceName;

  /// Stable selection key: the same `'<title key>@<source>'` the store uses.
  String get key => '${canonical.key}@${match.sourceId}';
}

/// Builds the page's rows from [store], sorted by title, keeping only those
/// matching [query] (title, matched show name or source name). Public for
/// tests.
@visibleForTesting
List<ManualMatchRow> manualMatchRows(
  MatchStore store, {
  String query = '',
  String Function(String sourceId)? sourceName,
}) {
  final name = sourceName ?? (String id) => id;
  final q = query.trim().toLowerCase();
  final rows = [
    for (final e in store.pinnedMatches())
      ManualMatchRow(
        canonical: e.canonical,
        match: e.match,
        title:
            store.titleFor(e.canonical) ??
            (e.match.showTitle.isNotEmpty
                ? e.match.showTitle
                : e.canonical.key),
        sourceName: name(e.match.sourceId),
      ),
  ];
  rows.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  if (q.isEmpty) return rows;
  return [
    for (final r in rows)
      if (r.title.toLowerCase().contains(q) ||
          r.match.showTitle.toLowerCase().contains(q) ||
          r.sourceName.toLowerCase().contains(q))
        r,
  ];
}

/// The address of a match's show page on its source: the stored URL when it
/// is already absolute, else joined to the source's base URL. Null when the
/// pin names a source but no show ("a choice, not a match").
@visibleForTesting
String? manualMatchPageUrl(SourceMatch m, String baseUrl) {
  final url = m.showUrl.trim();
  if (url.isEmpty) return null;
  if (url.startsWith('http://') || url.startsWith('https://')) return url;
  if (baseUrl.isEmpty) return null;
  final base = baseUrl.endsWith('/')
      ? baseUrl.substring(0, baseUrl.length - 1)
      : baseUrl;
  return url.startsWith('/') ? '$base$url' : '$base/$url';
}

/// "Manual matches" (ar-7 Option B): every title whose source match was
/// fixed by hand through "Wrong title?", with search, multi-select
/// (Ctrl / Shift click, Ctrl+A, Esc), "Reset to Auto" (forgets the pinned
/// match so Auto Resolve decides again, with Undo) and "Open source page".
/// Reached from Settings > Source Priority.
class ManualMatchesScreen extends StatelessWidget {
  const ManualMatchesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Opened from settings pages that may sit outside the Windows settings
    // workspace: add the desktop scope so shared rows use the graphite look.
    if (defaultTargetPlatform == TargetPlatform.windows &&
        !DesktopSettingsScope.contains(context)) {
      return const DesktopSettingsScope(child: _ManualMatchesPage());
    }
    return const _ManualMatchesPage();
  }
}

class _ManualMatchesPage extends StatefulWidget {
  const _ManualMatchesPage();

  @override
  State<_ManualMatchesPage> createState() => _ManualMatchesPageState();
}

class _ManualMatchesPageState extends State<_ManualMatchesPage> {
  final _search = TextEditingController();
  final _selection = DesktopSelection<String>();
  StreamSubscription<Object?>? _watch;

  /// Rows currently on screen (after the search filter), in order.
  List<ManualMatchRow> _rows = const [];

  /// Null in tests / builds without the match store registered.
  MatchStore? get _store =>
      sl.isRegistered<MatchStore>() ? sl<MatchStore>() : null;

  SourceRepository? get _sources =>
      sl.isRegistered<SourceRepository>() ? sl<SourceRepository>() : null;

  @override
  void initState() {
    super.initState();
    _reload();
    // Refresh when a pin changes anywhere (an Undo, a fix on a detail page).
    _watch = _store?.watch().listen((_) {
      if (mounted) setState(_reload);
    });
    _search.addListener(() => setState(_reload));
    _selection.addListener(_onSelection);
  }

  void _onSelection() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _watch?.cancel();
    _search.dispose();
    _selection
      ..removeListener(_onSelection)
      ..dispose();
    super.dispose();
  }

  /// Rebuilds [_rows] from the store and drops selections that vanished.
  void _reload() {
    final store = _store;
    _rows = store == null
        ? const []
        : manualMatchRows(
            store,
            query: _search.text,
            sourceName: (id) {
              final s = _sources;
              if (s == null) return id;
              try {
                return s.displayName(id);
              } catch (_) {
                return id;
              }
            },
          );
    final keys = {for (final r in _rows) r.key};
    final gone = _selection.selected.where((k) => !keys.contains(k)).toList();
    for (final k in gone) {
      _selection.toggle(k);
    }
  }

  List<String> _orderedKeys() => [for (final r in _rows) r.key];

  /// The rows an action applies to: the selection when [row] is part of it
  /// (or no row is given), otherwise just [row].
  List<ManualMatchRow> _targets([ManualMatchRow? row]) {
    final sel = _selection.selected;
    if (row != null && !sel.contains(row.key)) return [row];
    return [
      for (final r in _rows)
        if (sel.contains(r.key)) r,
    ];
  }

  /// Forgets the pinned match of every target so Auto Resolve picks the
  /// source again (MatchStore.forget), with an Undo that writes the titles'
  /// entries back exactly as they were.
  Future<void> _resetToAuto(List<ManualMatchRow> targets) async {
    final store = _store;
    if (store == null || targets.isEmpty) return;
    final snapshots = {
      for (final r in targets) r.canonical: store.snapshot(r.canonical),
    };
    for (final r in targets) {
      await store.forget(r.canonical, r.match.sourceId);
    }
    _selection.clear();
    if (!mounted) return;
    setState(_reload);
    showUndoToast(
      context,
      message: targets.length == 1
          ? context.l10n.titleBackOnAutoResolve(targets.single.title)
          : context.l10n.titlesBackOnAutoResolve(targets.length),
      onUndo: () async {
        for (final e in snapshots.entries) {
          await store.restore(e.key, e.value);
        }
        if (mounted) setState(_reload);
      },
    );
  }

  /// Opens the matched show's page on its source in the default browser.
  Future<void> _openSourcePage(ManualMatchRow row) async {
    final url = manualMatchPageUrl(
      row.match,
      _sources?.baseUrlFor(row.match.sourceId) ?? '',
    );
    final uri = url == null ? null : Uri.tryParse(url);
    var opened = false;
    if (uri != null) {
      try {
        opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {}
    }
    if (!opened && mounted) {
      ScaffoldMessenger.maybeOf(context)
        ?..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(context.l10n.couldntOpenSourcePage),
          ),
        );
    }
  }

  /// Items of a row's menu (right-click, Menu key / Shift+F10, or "More").
  /// Reset applies to the whole selection when the row is part of it.
  List<DesktopMenuItem<Object?>> _menuItems(ManualMatchRow row) {
    final targets = _targets(row);
    final hasPage =
        manualMatchPageUrl(
          row.match,
          _sources?.baseUrlFor(row.match.sourceId) ?? '',
        ) !=
        null;
    return [
      DesktopMenuItem(
        label: context.l10n.openSourcePage,
        icon: Icons.open_in_new_rounded,
        enabled: hasPage,
        onTap: () => _openSourcePage(row),
      ),
      const DesktopMenuItem.divider(),
      DesktopMenuItem(
        label: targets.length > 1
            ? context.l10n.resetNToAuto(targets.length)
            : context.l10n.resetToAuto,
        icon: Icons.auto_awesome_rounded,
        onTap: () => _resetToAuto(targets),
      ),
    ];
  }

  void _onRowTap(ManualMatchRow row) {
    // Ctrl / Shift click, or any click while selecting, edits the selection;
    // a plain click selects just this row, like a file list.
    if (_selection.handleClick(row.key, _orderedKeys())) return;
    _selection
      ..clear()
      ..select(row.key);
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selection.selected.length;
    return Scaffold(
      backgroundColor: settingsPageBackground(context),
      appBar: settingsAppBar(context.l10n.manualMatches),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: DesktopSelectionShortcuts<String>(
            selection: _selection,
            orderedKeys: _orderedKeys,
            onDelete: () => _resetToAuto(_targets()),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 8, 22, 4),
                  child: Text(
                    context.l10n.manualMatchesIntro,
                    style: AppText.caption.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 8, 22, 8),
                  child: TextField(
                    key: const ValueKey('manual-matches-search'),
                    controller: _search,
                    style: AppText.body.copyWith(color: AppColors.textPrimary),
                    cursorColor: AppColors.accent,
                    decoration: InputDecoration(
                      hintText: context.l10n.searchManualMatches,
                      hintStyle: AppText.body,
                      isDense: true,
                      filled: true,
                      fillColor: DesktopChrome.field,
                      prefixIcon: const Icon(
                        Icons.search_rounded,
                        size: 20,
                        color: AppColors.textTertiary,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                // Selection bar: what is selected and what can be done to it.
                if (selected > 0)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(22, 0, 22, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            context.l10n.countSelected(selected),
                            style: AppText.button.copyWith(
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ),
                        TextButton.icon(
                          key: const ValueKey('manual-matches-reset'),
                          onPressed: () => _resetToAuto(_targets()),
                          icon: const Icon(
                            Icons.auto_awesome_rounded,
                            size: 18,
                          ),
                          label: Text(context.l10n.resetToAuto),
                        ),
                        TextButton(
                          onPressed: _selection.clear,
                          child: Text(context.l10n.clearSelection),
                        ),
                      ],
                    ),
                  ),
                Expanded(child: _list()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _list() {
    if (_rows.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            _search.text.trim().isEmpty
                ? context.l10n.noManualMatchesYet
                : context.l10n.noManualMatchesForSearch,
            textAlign: TextAlign.center,
            style: AppText.body,
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(22, 0, 22, 28),
      itemCount: _rows.length,
      itemBuilder: (context, i) {
        final row = _rows[i];
        return _MatchTile(
          key: ValueKey('manual-match-${row.key}'),
          row: row,
          selected: _selection.isSelected(row.key),
          selecting: _selection.isActive,
          onTap: () => _onRowTap(row),
          onCheck: (_) => _selection.toggle(row.key),
          menuItems: () => _menuItems(row),
          onReset: () => _resetToAuto([row]),
        );
      },
    );
  }
}

/// One row: hover checkbox, title, "source · matched show", and a reset
/// button. Right-click opens the row menu; Menu key / Shift+F10 too.
class _MatchTile extends StatefulWidget {
  const _MatchTile({
    super.key,
    required this.row,
    required this.selected,
    required this.selecting,
    required this.onTap,
    required this.onCheck,
    required this.menuItems,
    required this.onReset,
  });

  final ManualMatchRow row;
  final bool selected;
  final bool selecting;
  final VoidCallback onTap;
  final ValueChanged<bool> onCheck;
  final List<DesktopMenuItem<Object?>> Function() menuItems;
  final VoidCallback onReset;

  @override
  State<_MatchTile> createState() => _MatchTileState();
}

class _MatchTileState extends State<_MatchTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final accent = AppColors.accent;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        // Shared desktop menu region: right-click at the pointer, Menu key /
        // Shift+F10 while the row has focus (pass-through off Windows).
        child: DesktopContextMenuRegion(
          items: widget.menuItems,
          child: Material(
            // Selected rows use the shared desktop selection fill.
            color: widget.selected
                ? DesktopChrome.selectedFill(accent)
                : AppColors.surface2,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: widget.onTap,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
                child: Row(
                  children: [
                    DesktopSelectionCheckbox(
                      selected: widget.selected,
                      visible: _hover || widget.selecting,
                      onChanged: widget.onCheck,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            row.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.button.copyWith(
                              color: AppColors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            row.match.showTitle.isEmpty
                                ? row.sourceName
                                : '${row.sourceName} · ${row.match.showTitle}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.caption.copyWith(
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: context.l10n.resetToAuto,
                      onPressed: widget.onReset,
                      icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                      color: AppColors.textSecondary,
                    ),
                    // Same menu from a button, opened below it, so it is
                    // reachable without a right-click (and on phone).
                    Builder(
                      builder: (anchor) => IconButton(
                        tooltip: context.l10n.more,
                        onPressed: () => showDesktopContextMenu<Object?>(
                          anchor,
                          anchor: anchor,
                          items: widget.menuItems(),
                        ),
                        icon: const Icon(Icons.more_vert_rounded, size: 18),
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
