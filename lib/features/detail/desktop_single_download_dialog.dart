import 'package:flutter/material.dart';

import '../../core/download/download_manager.dart';
import '../../core/models/episode.dart';
import '../../core/models/video_source.dart';
import '../../core/theme/app_colors.dart';
import '../../l10n/l10n.dart';
import '../downloads/download_size_preview.dart';

/// The selected cut owns both its episode identity and its resolved streams.
typedef DesktopSingleDownloadChoice = ({Episode episode, String category,
  VideoSource chosen, List<VideoSource> all});

/// Never use array position to map cuts: missing dubs and specials shift lists.
Episode? matchSingleDownloadEpisode(Episode original, int season,
    Map<int, List<Episode>> candidates) {
  final pool = candidates[season] ?? const <Episode>[];
  final number = original.number;
  final matches = number != null && number.isFinite
      ? pool.where((e) => e.number == number && (e.season == null || e.season == season)).toList()
      : pool.where((e) => e.number == null && (e.season == null || e.season == season)).toList();
  // A single unnumbered movie is safe only when the cut contains one entry.
  if (number == null && pool.length != 1) return null;
  if (number != null && !number.isFinite) return null;
  return matches.length == 1 ? matches.single : null;
}

/// Windows cut/server chooser; preserves shared queue/audio verification below.
class DesktopSingleDownloadDialog extends StatefulWidget {
  const DesktopSingleDownloadDialog({super.key, required this.episode,
    required this.season, required this.initialCategory, required this.availableCategories,
    required this.resolveEpisodes, required this.resolveSources, this.previewBuilder});
  final Episode episode;
  final int season;
  final String initialCategory;
  final List<String> availableCategories;
  final Future<Map<int, List<Episode>>> Function(String) resolveEpisodes;
  final Future<List<VideoSource>> Function(Episode, String) resolveSources;
  final Widget Function(VideoSource, Episode)? previewBuilder;
  @override State<DesktopSingleDownloadDialog> createState() => _DesktopSingleDownloadDialogState();
}

class _DesktopSingleDownloadDialogState extends State<DesktopSingleDownloadDialog> {
  late String _category;
  Episode? _episode;
  List<VideoSource> _sources = [];
  VideoSource? _selected;
  String? _error;
  bool _loading = true;
  int _request = 0;
  @override void initState() { super.initState(); _category = widget.initialCategory; _load(_category); }
  @override void dispose() { _request++; super.dispose(); }

  /// Each cut switch retires both its episode lookup and stream resolution.
  Future<void> _load(String category) async {
    final request = ++_request;
    setState(() {
      _category = category; _loading = true; _sources = []; _selected = null;
      _episode = null; _error = null;
    });
    try {
      final episode = category == widget.initialCategory ? widget.episode
          : matchSingleDownloadEpisode(widget.episode, widget.season, await widget.resolveEpisodes(category));
      if (!mounted || request != _request) return;
      if (episode == null) {
        setState(() { _loading = false; _error = 'No unique matching episode is available in this cut.'; });
        return;
      }
      final sources = DownloadManager.sourcesForDownloadCategory(
          await widget.resolveSources(episode, category), category);
      if (!mounted || request != _request) return;
      setState(() {
        _episode = episode; _sources = sources; _selected = sources.firstOrNull;
        _loading = false;
        if (sources.isEmpty) _error = context.l10n.noDownloadSourcesFound;
      });
    } catch (_) {
      if (!mounted || request != _request) return;
      setState(() { _loading = false; _error = context.l10n.couldntLoadDownloadOptions; });
    }
  }

  @override Widget build(BuildContext context) {
    final l10n = context.l10n;
    final selected = _selected;
    final episode = _episode;
    final categories = {widget.initialCategory, ...widget.availableCategories};
    return Dialog(backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(constraints: BoxConstraints(maxWidth: 640,
          maxHeight: MediaQuery.sizeOf(context).height * .85),
        child: Padding(padding: const EdgeInsets.all(24), child: Column(
          mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(l10n.downloadChooseServer, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(widget.episode.title, maxLines: 2, overflow: TextOverflow.ellipsis),
            if (categories.length > 1) Padding(padding: const EdgeInsets.symmetric(vertical: 14),
              child: Wrap(spacing: 8, runSpacing: 8, children: [for (final cat in categories)
                ChoiceChip(label: Text(cat.toUpperCase()), selected: cat == _category,
                  onSelected: (_) { if (cat != _category) _load(cat); })])),
            if (_loading) const Padding(padding: EdgeInsets.symmetric(vertical: 20),
              child: LinearProgressIndicator()),
            if (_error != null) Padding(padding: const EdgeInsets.symmetric(vertical: 16), child: Text(_error!)),
            if (!_loading && _sources.isNotEmpty) Flexible(child: ListView.separated(
              shrinkWrap: true, itemCount: _sources.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                final source = _sources[i];
                final label = source.label?.trim().isNotEmpty == true ? source.label!
                    : source.quality ?? Uri.tryParse(source.url)?.host ?? l10n.serverNumber(i + 1);
                final chosen = identical(source, selected);
                return Material(color: chosen ? AppColors.surface2 : AppColors.surface,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: chosen ? AppColors.accent : AppColors.hairline)),
                  child: ListTile(title: Text(label),
                    subtitle: Text([if (source.quality != null) source.quality!,
                      if (source.audioLang != null) source.audioLang!, source.container.name].join(' - ')),
                    trailing: Icon(chosen ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                      color: chosen ? AppColors.accent : AppColors.textSecondary),
                    onTap: () => setState(() => _selected = source)));
              })),
            if (!_loading && selected != null && episode != null)
              widget.previewBuilder?.call(selected, episode) ?? DownloadSizePreview(
                source: selected, runtimeMinutes: episode.runtimeMinutes),
            const SizedBox(height: 14),
            Wrap(alignment: WrapAlignment.end, spacing: 12, runSpacing: 8, children: [
              TextButton(onPressed: () => Navigator.pop(context), child: Text(l10n.cancel)),
              FilledButton(onPressed: _loading || selected == null || episode == null ? null : () =>
                Navigator.pop(context, (episode: episode, category: _category,
                    chosen: selected, all: _sources)), child: Text(l10n.download)),
            ]),
          ]))));
  }
}
