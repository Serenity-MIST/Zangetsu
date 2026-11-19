import 'desktop_download_episode_groups.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/desktop/desktop_dialogs.dart' show showDesktopConfirm;
import '../../core/desktop/desktop_multi_select.dart';
import '../../core/download/download_record.dart';
import '../../core/download/download_recycle.dart';
import '../../core/theme/app_colors.dart';
import '../../l10n/l10n.dart';
import 'desktop_download_library.dart'
    show downloadCategoryLabel, downloadSourceLabel;

/// Tells one episode row how it takes part in selection (dl-1, dl-3). Rows
/// built by [DesktopDownloadSelection.rowBuilder] read it with [maybeOf] so
/// the builder's signature stays a plain `(record) => row`.
class DesktopDownloadRowScope extends InheritedWidget {
  const DesktopDownloadRowScope({super.key, required this.selecting,
      required this.selected, required this.onClick, required super.child});

  /// The list is in selection mode (a click toggles instead of playing).
  final bool selecting;

  /// This row is ticked.
  final bool selected;

  /// Call first on a row click. True means the click was used for selection
  /// (plain click while selecting, Ctrl-click, Shift-click range) and the
  /// row must not play.
  final bool Function() onClick;

  static DesktopDownloadRowScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DesktopDownloadRowScope>();

  @override
  bool updateShouldNotify(DesktopDownloadRowScope old) =>
      old.selecting != selecting || old.selected != selected ||
      old.onClick != onClick;
}

/// Explicit desktop batch selection. Only confirmed, still-current generations
/// reach the manager; changing selection never touches files or transfer state.
class DesktopDownloadSelection extends StatefulWidget {
  const DesktopDownloadSelection({super.key, required this.records,
      required this.rowBuilder, required this.onDelete, this.header});
  final List<DownloadRecord> records;
  final Widget Function(DownloadRecord) rowBuilder;
  final Future<void> Function(List<DownloadRecord>) onDelete;

  /// Optional block above the selection toolbar (the show summary, dl-8).
  final Widget? header;
  @override
  State<DesktopDownloadSelection> createState() => _DesktopDownloadSelectionState();
}

class _DesktopDownloadSelectionState extends State<DesktopDownloadSelection> {
  /// Shared Explorer-style selection, keyed by record id (dl-3).
  final _selection = DesktopSelection<String>();

  /// The file generation each id had when it was ticked. A retry that
  /// replaces the file drops out of the selection instead of being deleted.
  final _generations = <String, String>{};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _selection.addListener(_onSelectionChanged);
  }

  @override
  void dispose() {
    _selection
      ..removeListener(_onSelectionChanged)
      ..dispose();
    super.dispose();
  }

  /// Remembers the generation of newly ticked rows and forgets unticked ones.
  void _onSelectionChanged() {
    final chosen = _selection.selected;
    _generations.removeWhere((id, _) => !chosen.contains(id));
    for (final r in widget.records) {
      if (chosen.contains(r.id)) _generations.putIfAbsent(r.id, () => r.storageKey);
    }
    if (mounted) setState(() {});
  }

  bool get _selecting => _selection.isActive;

  /// Progress updates retain selection; retries with a new generation do not.
  List<DownloadRecord> get _currentSelection => widget.records.where((r) =>
      _selection.isSelected(r.id) && _generations[r.id] == r.storageKey).toList();

  /// Rows in on-screen order, for Shift ranges and Ctrl+A.
  List<String> get _orderedIds => [
    for (final group in _groups) ...group.map((r) => r.id),
  ];

  /// Selection deliberately exposes every original record so deletion never
  /// silently includes a hidden variant or historical attempt.
  List<List<DownloadRecord>> get _groups => _selecting
      ? widget.records.map((r) => [r]).toList()
      : desktopDownloadEpisodeGroups(widget.records);

  /// Snapshot before confirmation, then revalidate after the modal await.
  Future<void> _deleteSelected() async {
    final snapshots = _currentSelection;
    if (_busy || snapshots.isEmpty) return;
    final l10n = context.l10n;
    setState(() => _busy = true);
    try {
      // Shared graphite confirm (Enter deletes, Esc cancels), red Delete
      // button because it removes files.
      final confirmed = await showDesktopConfirm(context,
        title: '${l10n.deleteDownload} (${snapshots.length})',
        // Windows sends finished files to the Recycle Bin.
        message: recycleDownloadDeletes
            ? l10n.deleteSelectedDownloadsRecycle
            : l10n.deleteSelectedDownloadsPermanent,
        confirmLabel: l10n.delete,
        destructive: true);
      if (!confirmed || !mounted) return;
      final approved = {for (final r in snapshots) r.id: r.storageKey};
      final current = widget.records.where((r) => approved.containsKey(r.id) &&
          approved[r.id] == r.storageKey).toList();
      await widget.onDelete(current);
      if (mounted) _selection.clear();
    } catch (_) {
      // Tell the user some files stayed behind instead of failing silently.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.someDownloadsNotRemoved)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Wraps [row] so it knows whether it is selected and can route its click
  /// through the shared selection first (dl-1).
  Widget _scoped(DownloadRecord r, Widget row) => DesktopDownloadRowScope(
    selecting: _selecting,
    selected: _selection.isSelected(r.id),
    // While a delete runs the click is swallowed in selection mode (never
    // plays a row that is being deleted) and acts normally otherwise.
    onClick: () => _busy ? _selecting : _selection.handleClick(r.id, _orderedIds),
    child: row);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final selected = _currentSelection;
    final groups = _groups;
    return DesktopSelectionShortcuts<String>(
      selection: _selection,
      autofocus: true,
      orderedKeys: () => _orderedIds,
      onDelete: _busy ? null : _deleteSelected,
      child: Column(children: [
      ?widget.header,
      Padding(padding: const EdgeInsets.fromLTRB(20, 12, 20, 8), child: Align(
        alignment: Alignment.centerLeft,
        child: Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (!_selecting) OutlinedButton.icon(
              onPressed: widget.records.isEmpty ? null : _selection.startSelecting,
              // A tick icon: the sliders icon belongs to download settings.
              icon: SvgPicture.asset('assets/icons/lucide/circle-check.svg', width: 16,
                colorFilter: const ColorFilter.mode(AppColors.textSecondary, BlendMode.srcIn)),
              label: Text(l10n.selectEpisodes))
            else ...[
              Text('${selected.length} ${l10n.selected}'),
              OutlinedButton(onPressed: _busy ? null : () => _selection.selectAll(
                  widget.records.map((r) => r.id)),
                child: Text(l10n.selectAll)),
              TextButton(onPressed: _busy ? null : _selection.clear,
                child: Text(l10n.cancel)),
              FilledButton(onPressed: _busy || selected.isEmpty ? null : _deleteSelected,
                child: Text('${l10n.delete} (${selected.length})')),
            ],
          ]))),
      Expanded(child: widget.records.isEmpty
        ? Center(child: Text(l10n.episodesYouDownloadAppearHere))
        : ListView.separated(padding: const EdgeInsets.only(bottom: 20),
          itemCount: groups.length, separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final group = groups[i];
            final r = group.first;
            final row = group.length == 1 ? _scoped(r, widget.rowBuilder(r)) : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _scoped(r, widget.rowBuilder(r)),
                ExpansionTile(key: ValueKey('download-attempts-${r.id}'),
                  title: Text(context.l10n.otherFilesAndAttempts(group.length - 1),
                    style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                  subtitle: Text(context.l10n.eachFileKeepsSource,
                    style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                  children: [for (final attempt in group.skip(1)) Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      // Readable source name and Subbed/Dubbed instead of
                      // internal codes like "cs:12345 - sub" (dl-12).
                      Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                        child: Text('${downloadSourceLabel(attempt.sourceId, [attempt])} - ${downloadCategoryLabel(attempt.category)}',
                          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary))),
                      _scoped(attempt, widget.rowBuilder(attempt)),
                    ])]),
              ]);
            return Row(key: ValueKey((r.id, r.storageKey)), children: [
              if (_selecting) Padding(padding: const EdgeInsets.only(left: 12), child: Checkbox(
                semanticLabel: '${l10n.selected}: ${r.episodeTitle}',
                value: selected.any((s) => s.id == r.id), onChanged: _busy ? null : (value) {
                  if (value == true && _selection.isSelected(r.id)) {
                    // Ticked earlier but the file was replaced since:
                    // re-approve the current generation.
                    setState(() => _generations[r.id] = r.storageKey);
                  } else if ((value == true) != _selection.isSelected(r.id)) {
                    _selection.toggle(r.id);
                  }
                })),
              Expanded(child: row),
            ]);
          })),
    ]));
  }
}
