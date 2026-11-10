import 'desktop_download_episode_groups.dart';
import '../../core/ui/artwork_quality.dart';
import '../../core/ui/progressive_artwork.dart';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/download/chapter_download.dart';
import '../../core/download/download_record.dart';
import '../../core/mode/content_mode.dart';
import '../../core/theme/app_colors.dart';
import '../../l10n/l10n.dart';

/// Exact offline identity: providers and reading modes may reuse a show ID.
typedef DownloadLibraryKey = ({String kind, String sourceId, String showId});

/// A presentation snapshot; authoritative records and actions stay in stores.
class DesktopDownloadCollection {
  DesktopDownloadCollection(this.key, this.title, this.cover, this.coverHeaders,
      this.videos, this.chapters);
  final DownloadLibraryKey key;
  final String title;
  final String? cover;
  final Map<String, String>? coverHeaders;
  final List<DownloadRecord> videos;
  final List<ChapterDownload> chapters;
  // Summary and detail use the same episode grouping. Historical failures do
  // not invent missing episodes when a recovered saved file exists beside them.
  late final _episodeGroups = desktopDownloadEpisodeGroups(videos);
  int get total => _episodeGroups.length + chapters.length;
  int get saved => _episodeGroups.where((group) =>
      group.any((r) => r.status == DownloadStatus.done)).length +
      chapters.where((r) => r.status == ChapterDownloadStatus.done).length;
  int get failed => _episodeGroups.where((group) =>
      !group.any((r) => r.status == DownloadStatus.done) &&
      group.any((r) => r.status == DownloadStatus.failed ||
          r.status == DownloadStatus.unsupported)).length +
      chapters.where((r) => r.status == ChapterDownloadStatus.failed).length;
  int get pending => videos.where((r) => r.isActive).length +
      chapters.where((r) => r.isActive).length;
  int get newest => [...videos.map((r) => r.createdAt),
      ...chapters.map((r) => r.createdAt)].fold(0, math.max);

  /// Search includes individual titles without discarding sibling records.
  bool matches(String query) {
    final q = query.trim().toLowerCase();
    return q.isEmpty || title.toLowerCase().contains(q) ||
        videos.any((r) => '${r.episodeTitle} e${r.episodeNumber ?? ''}'
            .toLowerCase().contains(q)) ||
        chapters.any((r) => r.chapterTitle.toLowerCase().contains(q));
  }
}

/// Pure grouping allows identity/status regressions without opening live Hive.
List<DesktopDownloadCollection> desktopDownloadCollections({
  required List<DownloadRecord> videos,
  required List<ChapterDownload> chapters,
}) {
  final videoGroups = <DownloadLibraryKey, List<DownloadRecord>>{};
  final chapterGroups = <DownloadLibraryKey, List<ChapterDownload>>{};
  for (final r in videos) {
    final key = (kind: 'video', sourceId: r.sourceId, showId: r.showId);
    (videoGroups[key] ??= []).add(r);
  }
  for (final r in chapters) {
    final key = (kind: r.mode.name, sourceId: r.sourceId, showId: r.showId);
    (chapterGroups[key] ??= []).add(r);
  }
  // Recovered files have no provider identity. Attach them for presentation only
  // when exactly one provider collection has the same normalized title. Never
  // rewrite source/audio metadata or guess between remakes from several sources.
  String titleKey(String title) => title.toLowerCase()
      .replaceAll(RegExp(r'[_\s]+'), ' ').trim();
  // Snapshot provider identities before attaching files so one recovered group
  // cannot make the next group disappear from its unique provider candidate.
  final providerGroups = videoGroups.entries
      .where((e) => e.value.every((r) => !r.recoveredFromDisk)).toList();
  for (final entry in videoGroups.entries.toList()) {
    if (!entry.value.every((r) => r.recoveredFromDisk)) continue;
    final titles = entry.value.map((r) => titleKey(r.showTitle)).toSet();
    if (titles.length != 1 || titles.single.isEmpty) continue;
    final targets = providerGroups.where((candidate) =>
      candidate.key != entry.key &&
      candidate.value.every((r) => titleKey(r.showTitle) == titles.single)).toList();
    if (targets.length == 1) {
      targets.single.value.addAll(entry.value);
      videoGroups.remove(entry.key);
    }
  }
  final out = <DesktopDownloadCollection>[];
  for (final e in videoGroups.entries) {
    final records = e.value..sort((a,b) => b.createdAt.compareTo(a.createdAt));
    final artwork = records.where((r) => r.cover?.isNotEmpty == true).firstOrNull;
    out.add(DesktopDownloadCollection(e.key, records.first.showTitle,
        artwork?.cover, artwork?.coverHeaders, records, const []));
  }
  for (final e in chapterGroups.entries) {
    final records = e.value..sort((a,b) => b.createdAt.compareTo(a.createdAt));
    final artwork = records.where((r) => r.cover?.isNotEmpty == true).firstOrNull;
    out.add(DesktopDownloadCollection(e.key, records.first.showTitle,
        artwork?.cover, artwork?.coverHeaders, const [], records));
  }
  out.sort((a,b) {
    final recent = b.newest.compareTo(a.newest);
    return recent != 0 ? recent : a.key.toString().compareTo(b.key.toString());
  });
  return out;
}

/// Windows-only poster browser. It owns no downloads or account preferences.
class DesktopDownloadLibrary extends StatefulWidget {
  const DesktopDownloadLibrary({super.key, required this.collections,
      required this.onOpen});
  final List<DesktopDownloadCollection> collections;
  final ValueChanged<DesktopDownloadCollection> onOpen;
  @override
  State<DesktopDownloadLibrary> createState() => _DesktopDownloadLibraryState();
}

class _DesktopDownloadLibraryState extends State<DesktopDownloadLibrary> {
  String _query = '';
  String? _kind;
  final _search = TextEditingController();
  @override
  void dispose() { _search.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final visible = widget.collections.where((c) =>
        (_kind == null || c.key.kind == _kind) && c.matches(_query)).toList();
    final labels = <String?, String>{null: l10n.all, 'video': l10n.playback,
      ContentMode.manga.name: l10n.modeManga, ContentMode.novel.name: l10n.novels};
    return Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(20, 14, 20, 12), child: Wrap(
        spacing: 16, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Wrap(spacing: 8, runSpacing: 8, children: [for (final e in labels.entries)
            ChoiceChip(label: Text(e.value), selected: _kind == e.key,
              onSelected: (_) => setState(() => _kind = e.key))]),
          ConstrainedBox(constraints: const BoxConstraints(maxWidth: 340),
            child: TextField(controller: _search,
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(hintText: l10n.searchDownloads,
                prefixIcon: Padding(padding: const EdgeInsets.all(13), child:
                  SvgPicture.asset('assets/icons/lucide/search.svg', width: 18,
                    colorFilter: const ColorFilter.mode(AppColors.textSecondary, BlendMode.srcIn))),
                filled: true, fillColor: AppColors.surface,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                isDense: true))),
        ])),
      Expanded(child: visible.isEmpty
        ? Center(child: Text(widget.collections.isEmpty
            ? l10n.episodesYouDownloadAppearHere : l10n.noDownloadsMatchYourSearch))
        : LayoutBuilder(builder: (context, bounds) {
            // Responsive column count, never a screen-resolution assumption.
            final width = math.max(1.0, bounds.maxWidth - 40);
            final columns = math.max(1, (width / 184).floor());
            final cardWidth = (width - (columns - 1) * 16) / columns;
            final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
            return GridView.builder(key: const PageStorageKey('desktop-download-library'),
              padding: const EdgeInsets.fromLTRB(20, 2, 20, 24),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns, crossAxisSpacing: 16, mainAxisSpacing: 18,
                mainAxisExtent: cardWidth * 1.25 + 100 * textScale),
              itemCount: visible.length, itemBuilder: (context, i) =>
                _DownloadPoster(key: ValueKey(visible[i].key), collection: visible[i], onOpen: () => widget.onOpen(visible[i])));
          })),
    ]);
  }
}

/// Focusable poster with restrained hover motion and honest saved/error counts.
class _DownloadPoster extends StatefulWidget {
  const _DownloadPoster({super.key, required this.collection, required this.onOpen});
  final DesktopDownloadCollection collection;
  final VoidCallback onOpen;
  @override
  State<_DownloadPoster> createState() => _DownloadPosterState();
}

class _DownloadPosterState extends State<_DownloadPoster> {
  bool _hover = false;
  bool _focus = false;
  @override
  Widget build(BuildContext context) {
    final c = widget.collection;
    final active = _hover || _focus;
    final reduced = MediaQuery.disableAnimationsOf(context);
    final icon = c.key.kind == 'video' ? 'circle-play' : 'book-open';
    final fallback = Center(child: SvgPicture.asset('assets/icons/lucide/$icon.svg',
      width: 32, height: 32, colorFilter: const ColorFilter.mode(AppColors.textSecondary, BlendMode.srcIn)));
    return AnimatedContainer(duration: reduced ? Duration.zero : const Duration(milliseconds: 150),
      decoration: BoxDecoration(color: active ? AppColors.surface2 : AppColors.surface,
        borderRadius: BorderRadius.circular(14), border: Border.all(
          color: active ? AppColors.accent : Colors.white.withValues(alpha: .08))),
      clipBehavior: Clip.antiAlias,
      child: Material(color: Colors.transparent, child: InkWell(
        onTap: widget.onOpen,
        onHover: (v) => setState(() => _hover = v),
        onFocusChange: (v) => setState(() => _focus = v),
        borderRadius: BorderRadius.circular(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(child: ColoredBox(color: AppColors.surface2,
            child: c.cover?.isNotEmpty == true ? LayoutBuilder(builder: (context, box) =>
              ProgressiveArtwork(
                preview: ResizeImage(CachedNetworkImageProvider(artworkPreviewUrl(c.cover!), headers: c.coverHeaders), width: 96),
                full: ResizeImage(CachedNetworkImageProvider(desktopArtworkUrl(c.cover!), headers: c.coverHeaders),
                  width: artworkDecodeWidth(box.maxWidth, MediaQuery.devicePixelRatioOf(context))),
                fallback: fallback)) : fallback)),
          Padding(padding: const EdgeInsets.all(12), child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(c.title, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(context.l10n.ofTotalDownloaded(c.saved, c.total),
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
              const SizedBox(height: 4),
              Text('${c.videos.any((r) => r.recoveredFromDisk) && c.videos.any((r) => !r.recoveredFromDisk) ? 'Saved episodes' : c.key.sourceId}${c.failed > 0 ? ' - ${c.failed} failed' : ''}${c.pending > 0 ? ' - ${c.pending} active' : ''}',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: c.failed > 0 ? AppColors.accent : AppColors.textTertiary, fontSize: 11)),
            ])),
        ]))));
  }
}
