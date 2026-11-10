import 'desktop_download_episode_groups.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/download/download_record.dart';
import '../../core/theme/app_colors.dart';
import '../../l10n/l10n.dart';

/// Explicit desktop batch selection. Only confirmed, still-current generations
/// reach the manager; changing selection never touches files or transfer state.
class DesktopDownloadSelection extends StatefulWidget {
  const DesktopDownloadSelection({super.key, required this.records,
      required this.rowBuilder, required this.onDelete});
  final List<DownloadRecord> records;
  final Widget Function(DownloadRecord) rowBuilder;
  final Future<void> Function(List<DownloadRecord>) onDelete;
  @override
  State<DesktopDownloadSelection> createState() => _DesktopDownloadSelectionState();
}

class _DesktopDownloadSelectionState extends State<DesktopDownloadSelection> {
  final _selected = <String, DownloadRecord>{};
  bool _selecting = false;
  bool _busy = false;

  /// Progress updates retain selection; retries with a new generation do not.
  List<DownloadRecord> get _currentSelection => widget.records.where((r) =>
      _selected[r.id]?.storageKey == r.storageKey && _selected.containsKey(r.id)).toList();

  /// Snapshot before confirmation, then revalidate after the modal await.
  Future<void> _deleteSelected() async {
    final snapshots = _currentSelection;
    if (_busy || snapshots.isEmpty) return;
    final l10n = context.l10n;
    setState(() => _busy = true);
    try {
      final confirmed = await showDialog<bool>(context: context, builder: (ctx) =>
        AlertDialog(backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          title: Text('${l10n.deleteDownload} (${snapshots.length})'),
          content: const SizedBox(width: 420, child: Text(
            'Delete the selected downloads and their saved files? Active downloads will be canceled.')),
          actions: [TextButton(autofocus: true, onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.cancel)),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l10n.delete))]));
      if (confirmed != true || !mounted) return;
      final approved = {for (final r in snapshots) r.id: r.storageKey};
      final current = widget.records.where((r) => approved.containsKey(r.id) &&
          approved[r.id] == r.storageKey).toList();
      await widget.onDelete(current);
      if (mounted) setState(() { _selected.clear(); _selecting = false; });
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Some downloads could not be removed. Please try again.')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final selected = _currentSelection;
    // Selection deliberately exposes every original record so deletion never
    // silently includes a hidden variant or historical attempt.
    final groups = _selecting ? widget.records.map((r) => [r]).toList()
        : desktopDownloadEpisodeGroups(widget.records);
    return Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(20, 12, 20, 8), child: Align(
        alignment: Alignment.centerLeft,
        child: Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (!_selecting) OutlinedButton.icon(
              onPressed: widget.records.isEmpty ? null : () => setState(() => _selecting = true),
              icon: SvgPicture.asset('assets/icons/lucide/sliders-horizontal.svg', width: 16,
                colorFilter: const ColorFilter.mode(AppColors.textSecondary, BlendMode.srcIn)),
              label: Text(l10n.selectEpisodes))
            else ...[
              Text('${selected.length} ${l10n.selected}'),
              OutlinedButton(onPressed: _busy ? null : () => setState(() {
                _selected..clear()..addEntries(widget.records.map((r) => MapEntry(r.id, r)));
              }), child: Text(l10n.selectAll)),
              TextButton(onPressed: _busy ? null : () => setState(() {
                _selected.clear(); _selecting = false;
              }), child: Text(l10n.cancel)),
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
            final row = group.length == 1 ? widget.rowBuilder(r) : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                widget.rowBuilder(r),
                ExpansionTile(key: ValueKey('download-attempts-${r.id}'),
                  title: Text('Other files and previous attempts (${group.length - 1})',
                    style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                  subtitle: const Text('Each file keeps its original source and audio information.',
                    style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                  children: [for (final attempt in group.skip(1)) Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                        child: Text('${attempt.sourceId} - ${attempt.category}',
                          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary))),
                      widget.rowBuilder(attempt),
                    ])]),
              ]);
            return Row(key: ValueKey((r.id, r.storageKey)), children: [
              if (_selecting) Padding(padding: const EdgeInsets.only(left: 12), child: Checkbox(
                semanticLabel: '${l10n.selected}: ${r.episodeTitle}',
                value: selected.any((s) => s.id == r.id), onChanged: _busy ? null : (value) => setState(() {
                  if (value == true) { _selected[r.id] = r; } else { _selected.remove(r.id); }
                }))),
              Expanded(child: row),
            ]);
          })),
    ]);
  }
}
