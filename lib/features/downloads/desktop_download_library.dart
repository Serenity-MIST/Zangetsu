import 'desktop_download_episode_groups.dart';
import '../../core/ui/artwork_quality.dart';
import '../../core/ui/progressive_artwork.dart';
import 'dart:io';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:path/path.dart' as p;
import 'desktop_download_bulk_delete.dart';
import 'download_thumbnail.dart';

import '../../core/desktop/desktop_focus_repair.dart';
import '../../core/desktop/desktop_context_menu.dart';
import '../../core/desktop/desktop_dialogs.dart' show showDesktopConfirm;
import '../../core/desktop/desktop_multi_select.dart';
import '../../core/desktop/desktop_storage.dart';
import '../../core/download/chapter_download.dart';
import '../../core/download/download_prefs.dart' show isUriPath;
import '../../core/download/download_record.dart';
import '../../core/download/download_recycle.dart';
import '../../core/mode/content_mode.dart';
import '../../core/theme/app_colors.dart';
import '../../l10n/l10n.dart';
import '../../core/di/injector.dart';
import '../../core/repository/source_repository.dart';

/// Exact offline identity: providers and reading modes may reuse a show ID.
typedef DownloadLibraryKey = ({String kind, String sourceId, String showId});

/// A presentation snapshot; authoritative records and actions stay in stores.
class DesktopDownloadCollection {
  DesktopDownloadCollection(this.key, this.title, this.cover, this.coverHeaders,
      this.videos, this.chapters,
      {this.failedVideos = const [], this.failedChapters = const []});
  final DownloadLibraryKey key;
  final String title;
  final String? cover;
  final Map<String, String>? coverHeaders;
  final List<DownloadRecord> videos;
  final List<ChapterDownload> chapters;

  /// Failed or unsupported downloads of this show. Never shown, counted or
  /// searched here (the queue panel lists them); kept so deleting the show
  /// also clears them, and so the show keeps its page and ids.
  final List<DownloadRecord> failedVideos;
  final List<ChapterDownload> failedChapters;

  /// Windows: the show posters saved next to the video files
  /// (`.zangetsu/art/poster.png`, one per folder), so the card still has a
  /// picture when the web cover cannot load or the app is offline.
  late final List<String> savedPosters = downloadSavedPosterPaths(videos);

  // Summary and detail use the same episode grouping.
  late final _episodeGroups = desktopDownloadEpisodeGroups(videos);
  int get total => _episodeGroups.length + chapters.length;
  int get saved => _episodeGroups.where((group) =>
      group.any((r) => r.status == DownloadStatus.done)).length +
      chapters.where((r) => r.status == ChapterDownloadStatus.done).length;
  int get pending => videos.where((r) => r.isActive).length +
      chapters.where((r) => r.isActive).length;
  int get newest => [...videos.map((r) => r.createdAt),
      ...chapters.map((r) => r.createdAt)].fold(0, math.max);

  /// Disk space of the finished files (dl-9): sorting by size and the
  /// "used" total in the toolbar both read this.
  int get bytes =>
      videos.where((r) => r.status == DownloadStatus.done)
          .fold(0, (sum, r) => sum + math.max(0, r.bytesTotal)) +
      chapters.where((c) => c.status == ChapterDownloadStatus.done)
          .fold(0, (sum, c) => sum + math.max(0, c.bytes));

  /// The provider page this show came from, for "Open show page" (dl-4).
  /// Files recovered from disk carry no provider page, so they are skipped.
  String? get showUrl => [...videos, ...failedVideos]
      .where((r) => !r.recoveredFromDisk && r.showUrl.isNotEmpty)
      .map((r) => r.showUrl).firstOrNull;

  /// The folder that holds this show's saved files, for "Show in Explorer"
  /// (dl-4). Null when nothing is on disk yet.
  String? get folder => desktopDownloadFolder([
    for (final r in videos)
      if (r.filePath?.isNotEmpty == true) r.filePath!,
    for (final c in chapters) ...[
      if (c.archivePath?.isNotEmpty == true) c.archivePath!,
      if (c.textPath?.isNotEmpty == true) c.textPath!,
      ...c.pagePaths.take(1),
    ],
  ]);

  /// Search includes individual titles without discarding sibling records.
  bool matches(String query) {
    final q = query.trim().toLowerCase();
    return q.isEmpty || title.toLowerCase().contains(q) ||
        videos.any((r) => '${r.episodeTitle} e${r.episodeNumber ?? ''}'
            .toLowerCase().contains(q)) ||
        chapters.any((r) => r.chapterTitle.toLowerCase().contains(q));
  }
}

/// The deepest folder shared by every file in [files] (dl-4). One season
/// gives its season folder; several seasons give the show folder. Phone-style
/// content:// URIs are ignored because Explorer cannot open them.
String? desktopDownloadFolder(Iterable<String> files) {
  List<String>? common;
  for (final file in files) {
    if (file.isEmpty || isUriPath(file)) continue;
    final parts = p.split(p.dirname(file));
    if (common == null) {
      common = parts;
      continue;
    }
    var i = 0;
    // Windows paths are case-insensitive, so compare folder names that way.
    while (i < common.length && i < parts.length &&
        common[i].toLowerCase() == parts[i].toLowerCase()) {
      i++;
    }
    common = common.sublist(0, i);
  }
  if (common == null || common.isEmpty) return null;
  return p.joinAll(common);
}

/// A download that failed or turned out unsupported: there is no episode to
/// show, so the library leaves it out. A finished download whose file was
/// moved is stored as failed too, but it did not fail: it stays.
bool isFailedDownload(DownloadRecord r) => !r.isSavedFileAway &&
    (r.status == DownloadStatus.failed || r.status == DownloadStatus.unsupported);

/// Pure grouping allows identity/status regressions without opening live Hive.
/// Failed entries help identify their show but are never among its episodes;
/// a show with nothing else is left out.
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
  // Snapshot provider identities before attaching files so one recovered group
  // cannot make the next group disappear from its unique provider candidate.
  final providerGroups = videoGroups.entries
      .where((e) => e.value.every((r) => !r.recoveredFromDisk)).toList();
  for (final entry in videoGroups.entries.toList()) {
    if (!entry.value.every((r) => r.recoveredFromDisk)) continue;
    final titles = entry.value.map((r) => downloadTitleKey(r.showTitle)).toSet();
    if (titles.length != 1 || titles.single.isEmpty) continue;
    final targets = providerGroups.where((candidate) =>
      candidate.key != entry.key &&
      candidate.value.every((r) => downloadTitleKey(r.showTitle) == titles.single)).toList();
    if (targets.length == 1) {
      targets.single.value.addAll(entry.value);
      videoGroups.remove(entry.key);
    }
  }
  final out = <DesktopDownloadCollection>[];
  for (final e in videoGroups.entries) {
    final all = e.value..sort((a,b) => b.createdAt.compareTo(a.createdAt));
    final failed = all.where(isFailedDownload).toList();
    final records = all.where((r) => !isFailedDownload(r)).toList();
    if (records.isEmpty) continue;
    // The newest real download's cover first: a file found on disk beside it
    // only carries a saved copy of the poster (or none at all).
    final withCover = [...records, ...failed].where((r) => r.cover?.isNotEmpty == true).toList();
    final artwork = withCover.where((r) => !r.recoveredFromDisk).firstOrNull ??
        withCover.firstOrNull;
    out.add(DesktopDownloadCollection(e.key, records.first.showTitle,
        artwork?.cover, artwork?.coverHeaders, records, const [],
        failedVideos: failed));
  }
  for (final e in chapterGroups.entries) {
    final all = e.value..sort((a,b) => b.createdAt.compareTo(a.createdAt));
    bool failed(ChapterDownload c) => c.status == ChapterDownloadStatus.failed;
    final records = all.where((c) => !failed(c)).toList();
    if (records.isEmpty) continue;
    final artwork = all.where((r) => r.cover?.isNotEmpty == true).firstOrNull;
    out.add(DesktopDownloadCollection(e.key, records.first.showTitle,
        artwork?.cover, artwork?.coverHeaders, const [], records,
        failedChapters: all.where(failed).toList()));
  }
  out.sort((a,b) {
    final recent = b.newest.compareTo(a.newest);
    return recent != 0 ? recent : a.key.toString().compareTo(b.key.toString());
  });
  return out;
}

/// Remembers the last [desktopDownloadCollections] result and only regroups
/// when the library's membership really changed (dl-7): a record added,
/// removed, re-generated or moved to another status. Progress ticks replace
/// record objects without changing any of that, so they reuse the cache and
/// the grid no longer regroups several times a second.
class DesktopDownloadCollectionsCache {
  List<Object?>? _signature;
  List<DesktopDownloadCollection>? _value;

  /// Grouped collections for these records, reused while nothing that the
  /// grouping or the poster counts read has changed.
  List<DesktopDownloadCollection> collections({
    required List<DownloadRecord> videos,
    required List<ChapterDownload> chapters,
  }) {
    // Every field the grouping, counts, artwork, size or folder depend on.
    // Progress is deliberately left out: posters never show it.
    final signature = <Object?>[
      for (final r in videos)
        (r.id, r.storageKey, r.status, r.sourceId, r.showId, r.showTitle,
          r.cover, r.createdAt, r.bytesTotal, r.filePath, r.recoveredFromDisk,
          r.episodeNumber, r.season, r.isSavedFileAway),
      null, // separator so a video can never pose as a chapter
      for (final c in chapters)
        (c.id, c.status, c.sourceId, c.showId, c.showTitle, c.cover,
          c.createdAt, c.bytes, c.mode, c.archivePath, c.textPath),
    ];
    final cached = _value;
    if (cached != null && listEquals(signature, _signature)) return cached;
    _signature = signature;
    return _value = desktopDownloadCollections(videos: videos, chapters: chapters);
  }
}

/// Library sort orders (dl-9).
enum DesktopDownloadSort { recent, title, size, unwatched }

/// Menu label for a sort order.
/// Uses appL10n (no context needed); it follows the app language.
String desktopDownloadSortLabel(DesktopDownloadSort sort) => switch (sort) {
  DesktopDownloadSort.recent => appL10n.sortRecent,
  DesktopDownloadSort.title => appL10n.presenceSourceTitle,
  DesktopDownloadSort.size => appL10n.subtitleSize,
  DesktopDownloadSort.unwatched => appL10n.sortMostUnwatched,
};

/// Orders [collections] for the grid (dl-9). Ties fall back to most recent
/// so the order never jumps around between rebuilds. [unwatched] counts the
/// finished but not yet watched episodes of one show.
List<DesktopDownloadCollection> sortDesktopDownloadCollections(
  List<DesktopDownloadCollection> collections,
  DesktopDownloadSort sort, {
  int Function(DesktopDownloadCollection)? unwatched,
}) {
  int recent(DesktopDownloadCollection a, DesktopDownloadCollection b) {
    final byDate = b.newest.compareTo(a.newest);
    return byDate != 0 ? byDate : a.key.toString().compareTo(b.key.toString());
  }
  // Counting unwatched reads the resume store, so do it once per show.
  final Map<DownloadLibraryKey, int> counts =
      sort == DesktopDownloadSort.unwatched && unwatched != null
      ? {for (final c in collections) c.key: unwatched(c)} : const {};
  final out = [...collections];
  out.sort((a, b) {
    final primary = switch (sort) {
      DesktopDownloadSort.recent => 0,
      DesktopDownloadSort.title =>
        a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      DesktopDownloadSort.size => b.bytes.compareTo(a.bytes),
      DesktopDownloadSort.unwatched =>
        (counts[b.key] ?? 0).compareTo(counts[a.key] ?? 0),
    };
    return primary != 0 ? primary : recent(a, b);
  });
  return out;
}

/// "84 GB used - 120 GB free on D:" for the library toolbar (dl-9). The free
/// part is left out when the drive could not be read.
String describeDownloadStorage({required int usedBytes, int? freeBytes,
    String? drive}) {
  final l10n = appL10n;
  final used = l10n.storageUsed(formatBytes(usedBytes));
  if (freeBytes == null) return used;
  if (drive == null || drive.isEmpty) {
    return l10n.storageUsedFree(used, formatBytes(freeBytes));
  }
  return l10n.storageUsedFreeOnDrive(used, formatBytes(freeBytes), drive);
}

/// Windows-only poster browser. It owns no downloads or account preferences.
class DesktopDownloadLibrary extends StatefulWidget {
  const DesktopDownloadLibrary({super.key, required this.collections,
      required this.onOpen, this.onDeleteCollections, this.trailing,
      this.header, this.onRevealCollection, this.onOpenShowPage,
      this.unwatchedCount, this.freeBytes, this.freeDrive});
  final List<DesktopDownloadCollection> collections;

  /// Optional widget at the right end of the toolbar (the save-folder pill).
  final Widget? trailing;

  /// Optional block between the toolbar and the grid (the active downloads
  /// panel, dl-5).
  final Widget? header;
  final ValueChanged<DesktopDownloadCollection> onOpen;

  /// Deletes whole shows (all their downloads). When null the library has no
  /// selection mode. The library confirms with the user before calling this.
  final Future<void> Function(List<DesktopDownloadCollection>)?
      onDeleteCollections;

  /// Opens the show's folder in File Explorer (right-click menu, dl-4).
  final ValueChanged<DesktopDownloadCollection>? onRevealCollection;

  /// Opens the show's provider page (right-click menu, dl-4).
  final ValueChanged<DesktopDownloadCollection>? onOpenShowPage;

  /// Finished-but-unwatched episodes of a show, for "Most unwatched" (dl-9).
  final int Function(DesktopDownloadCollection)? unwatchedCount;

  /// Free space on the download drive and its name (e.g. "D:"), for the
  /// storage line (dl-9). Null when unknown.
  final int? freeBytes;
  final String? freeDrive;
  @override
  State<DesktopDownloadLibrary> createState() => _DesktopDownloadLibraryState();
}

class _DesktopDownloadLibraryState extends State<DesktopDownloadLibrary> {
  String _query = '';
  String? _kind;
  final _search = TextEditingController();

  /// Shared Explorer-style selection (dl-3): Ctrl-click toggles, Shift-click
  /// selects a range, Ctrl+A / Esc / Delete come from the shortcuts widget.
  final _selection = DesktopSelection<DownloadLibraryKey>();
  bool _busy = false;
  DesktopDownloadSort _sort = DesktopDownloadSort.recent;

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
    _search.dispose();
    super.dispose();
  }

  void _onSelectionChanged() {
    if (mounted) setState(() {});
  }

  bool get _canSelect => widget.onDeleteCollections != null;
  bool get _selecting => _selection.isActive;

  /// The collections currently shown after the kind filter, search and sort.
  List<DesktopDownloadCollection> get _visible => sortDesktopDownloadCollections(
      widget.collections.where((c) =>
          (_kind == null || c.key.kind == _kind) && c.matches(_query)).toList(),
      _sort, unwatched: widget.unwatchedCount);

  /// Chosen shows that still exist (a show can vanish while selected).
  List<DesktopDownloadCollection> get _chosen => widget.collections
      .where((c) => _selection.isSelected(c.key)).toList();

  /// Un-ticking the last show leaves selection mode, like most file managers.
  void _leaveWhenEmpty() {
    if (_selection.selected.isEmpty) _selection.clear();
  }

  /// Checkbox click: always a plain toggle.
  void _toggle(DesktopDownloadCollection c) {
    _selection.toggle(c.key);
    _leaveWhenEmpty();
  }

  /// Poster click: Ctrl toggles, Shift selects a range, and while selecting
  /// a plain click toggles; otherwise the show opens.
  void _click(DesktopDownloadCollection c, List<DesktopDownloadCollection> visible) {
    if (_canSelect && !_busy &&
        _selection.handleClick(c.key, [for (final v in visible) v.key])) {
      _leaveWhenEmpty();
      return;
    }
    widget.onOpen(c);
  }

  void _selectAll() => _selection
    ..clear()
    ..selectAll(_visible.map((c) => c.key));

  void _cancelSelection() => _selection.clear();

  /// Delete key / red bin: removes the chosen shows after confirming.
  Future<void> _deleteSelected() => _confirmDelete(_chosen);

  /// Confirms, then deletes [chosen]. Always confirms: it removes files.
  Future<void> _confirmDelete(List<DesktopDownloadCollection> chosen) async {
    final delete = widget.onDeleteCollections;
    if (_busy || chosen.isEmpty || delete == null) return;
    final l10n = context.l10n;
    final plan = planBulkDelete(chosen);
    setState(() => _busy = true);
    try {
      // Shared graphite confirm (Enter deletes, Esc cancels), red Delete
      // button because it removes files. Titles come from existing l10n
      // keys so they follow the app language.
      final confirmed = await showDesktopConfirm(context,
        title: plan.shows == 1
            ? l10n.deleteDownloadQuestion
            : l10n.deleteNShows(plan.shows),
        // Windows sends finished files to the Recycle Bin, so say so.
        message: describeBulkDelete(plan, recycle: recycleDownloadDeletes),
        confirmLabel: l10n.delete,
        destructive: true);
      if (!confirmed || !mounted) return;
      await delete(chosen);
      // Deleted shows leave the selection; the rest of it is dropped too so
      // nothing stays ticked behind the user's back.
      if (mounted && chosen.any((c) => _selection.isSelected(c.key))) {
        _selection.clear();
      }
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

  /// Right-click / Menu key rows for one poster (dl-4). When the poster is
  /// part of a larger selection, Delete acts on the whole selection, as in
  /// Explorer.
  List<DesktopMenuItem<Object?>> _menuFor(DesktopDownloadCollection c) {
    final l10n = context.l10n;
    final group = _selection.isSelected(c.key) && _selection.selected.length > 1
        ? _chosen : [c];
    final reveal = widget.onRevealCollection;
    final showPage = widget.onOpenShowPage;
    return [
      DesktopMenuItem(label: l10n.open, icon: Icons.open_in_new_rounded,
        shortcut: 'Enter', onTap: () => widget.onOpen(c)),
      if (reveal != null)
        DesktopMenuItem(label: l10n.showInExplorer,
          icon: Icons.folder_open_rounded, enabled: c.folder != null,
          onTap: () => reveal(c)),
      if (showPage != null)
        DesktopMenuItem(label: l10n.openShowPage,
          icon: Icons.info_outline_rounded, enabled: c.showUrl != null,
          onTap: () => showPage(c)),
      if (_canSelect) ...[
        const DesktopMenuItem.divider(),
        DesktopMenuItem(
          label: group.length > 1 ? l10n.deleteNShows(group.length) : l10n.delete,
          icon: Icons.delete_outline_rounded, destructive: true, shortcut: 'Del',
          enabled: !_busy, onTap: () => _confirmDelete(group)),
      ],
    ];
  }

  /// "Sort by: Recent" pill that opens a dropdown of sort orders (dl-9).
  Widget _sortButton() {
    final l10n = context.l10n;
    final orders = [
      for (final s in DesktopDownloadSort.values)
        // "Most unwatched" needs watch data; hide it when none is supplied.
        if (s != DesktopDownloadSort.unwatched || widget.unwatchedCount != null) s,
    ];
    return Builder(builder: (anchor) => Tooltip(message: l10n.sortBy,
      child: InkWell(
        key: const ValueKey('downloads-sort'),
        borderRadius: BorderRadius.circular(24),
        onTap: () async {
          final picked = await showDesktopContextMenu<DesktopDownloadSort>(anchor,
            anchor: anchor, items: [
              for (final s in orders)
                DesktopMenuItem(label: desktopDownloadSortLabel(s), value: s,
                  checked: s == _sort),
            ]);
          if (picked != null && mounted) setState(() => _sort = picked);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(color: AppColors.surface,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: AppColors.textSecondary.withValues(alpha: .25))),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            SvgPicture.asset('assets/icons/lucide/arrow-up-down.svg', width: 16,
              colorFilter: const ColorFilter.mode(AppColors.textSecondary, BlendMode.srcIn)),
            const SizedBox(width: 8),
            Text('${l10n.sortBy}: ${desktopDownloadSortLabel(_sort)}',
              style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
          ])))));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final visible = _visible;
    final labels = <String?, String>{null: l10n.all, 'video': l10n.playback,
      ContentMode.manga.name: l10n.modeManga, ContentMode.novel.name: l10n.novels};
    // Disk use across the whole library, not just the filtered posters.
    final usedBytes = widget.collections.fold(0, (sum, c) => sum + c.bytes);
    final content = Column(children: [
      // One left-aligned toolbar: filters, search, sort, selection; the
      // save-folder pill sits at the far right instead of its own row.
      Padding(padding: const EdgeInsets.fromLTRB(20, 8, 20, 12), child: Row(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: Wrap(
        spacing: 12, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center,
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
          _sortButton(),
          // Selection: a bin icon starts it; once selecting, a compact bar
          // shows the count, Select all, a red bin to delete and an X to cancel.
          if (_canSelect) if (!_selecting)
            Tooltip(message: context.l10n.selectShowsToDelete,
              child: IconButton.outlined(
                key: const ValueKey('downloads-select'),
                onPressed: visible.isEmpty ? null : _selection.startSelecting,
                icon: SvgPicture.asset('assets/icons/lucide/trash-2.svg', width: 18,
                  colorFilter: const ColorFilter.mode(AppColors.textSecondary, BlendMode.srcIn))))
          else
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(color: AppColors.surface,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: AppColors.textSecondary.withValues(alpha: .25))),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text('${_selection.selected.length} ${l10n.selected}',
                  key: const ValueKey('downloads-selected-count')),
                const SizedBox(width: 4),
                TextButton(key: const ValueKey('downloads-select-all'),
                  onPressed: _busy ? null : _selectAll, child: Text(l10n.selectAll)),
                Tooltip(message: l10n.delete,
                  child: IconButton.filled(key: const ValueKey('downloads-select-delete'),
                    style: IconButton.styleFrom(backgroundColor: Colors.redAccent.shade400,
                      disabledBackgroundColor: AppColors.textSecondary.withValues(alpha: .2)),
                    onPressed: _busy || _selection.selected.isEmpty ? null : _deleteSelected,
                    icon: SvgPicture.asset('assets/icons/lucide/trash-2.svg', width: 18,
                      colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn)))),
                Tooltip(message: l10n.cancel,
                  child: IconButton(key: const ValueKey('downloads-select-cancel'),
                    onPressed: _busy ? null : _cancelSelection,
                    icon: SvgPicture.asset('assets/icons/lucide/x.svg', width: 18,
                      colorFilter: const ColorFilter.mode(AppColors.textSecondary, BlendMode.srcIn)))),
              ])),
          // Storage line (dl-9): what downloads use and what is left.
          if (widget.collections.isNotEmpty || widget.freeBytes != null)
            Text(describeDownloadStorage(usedBytes: usedBytes,
                freeBytes: widget.freeBytes, drive: widget.freeDrive),
              key: const ValueKey('downloads-storage'),
              style: const TextStyle(color: AppColors.textTertiary, fontSize: 12)),
        ])),
        if (widget.trailing != null) ...[const SizedBox(width: 12), widget.trailing!],
      ])),
      // The header (the download queue) and the poster grid share ONE
      // scroll view: the queue sits above the grid and scrolls away with
      // the page, so a long bulk queue can never sit on top of the saved
      // shows. The queue caps its own height and scrolls its rows inside.
      Expanded(child: LayoutBuilder(builder: (context, bounds) {
        // Responsive column count, never a screen-resolution assumption.
        final width = math.max(1.0, bounds.maxWidth - 40);
        final columns = math.max(1, (width / 184).floor());
        final cardWidth = (width - (columns - 1) * 16) / columns;
        final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
        return CustomScrollView(key: const PageStorageKey('desktop-download-library'),
          slivers: [
            if (widget.header != null) SliverToBoxAdapter(child: widget.header),
            if (visible.isEmpty)
              // The empty message fills what is left under the queue.
              SliverFillRemaining(hasScrollBody: false,
                child: Center(child: Text(widget.collections.isEmpty
                    ? l10n.episodesYouDownloadAppearHere
                    : l10n.noDownloadsMatchYourSearch)))
            else SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 2, 20, 24),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns, crossAxisSpacing: 16, mainAxisSpacing: 18,
                  // Windows: the art box is a true 2:3 poster (width x 1.5),
                  // the same shape as the other poster cards, so posters are
                  // never cropped. Other platforms keep the older shape.
                  mainAxisExtent: cardWidth * (defaultTargetPlatform == TargetPlatform.windows
                      ? 1.5 : 1.25) + 100 * textScale),
                delegate: SliverChildBuilderDelegate(childCount: visible.length,
                  (context, i) {
                    final c = visible[i];
                    return DesktopContextMenuRegion(
                      items: () => _menuFor(c),
                      child: _DownloadPoster(key: ValueKey(c.key), collection: c,
                        onTap: () => _click(c, visible),
                        selecting: _selecting, selected: _selection.isSelected(c.key),
                        onToggle: _canSelect && !_busy ? () => _toggle(c) : null));
                  }))),
          ]);
      })),
    ]);
    // R1: same autofocus Focus, registered with the focus repair.
    if (!_canSelect) {
      return DesktopRepairFocus(
          autofocus: true, debugLabel: 'downloads-keys', child: content);
    }
    // Ctrl+A, Esc, Delete, Shift+Up/Down and Enter, shared with the
    // episode list so both screens behave the same (dl-3).
    return DesktopSelectionShortcuts<DownloadLibraryKey>(
      selection: _selection,
      autofocus: true,
      orderedKeys: () => [for (final c in _visible) c.key],
      onDelete: _busy ? null : _deleteSelected,
      onActivate: () {
        final chosen = _chosen;
        if (chosen.length == 1) widget.onOpen(chosen.single);
      },
      // R1: a non-autofocus repair target below the selection keys, so a
      // lost focus returns here and Ctrl+A / Delete / Esc work again.
      child: DesktopRepairFocus(
          skipTraversal: true, debugLabel: 'downloads-keys', child: content));
  }
}

/// Focusable poster with restrained hover motion and honest saved counts.
class _DownloadPoster extends StatefulWidget {
  const _DownloadPoster({super.key, required this.collection, required this.onTap,
      this.selecting = false, this.selected = false, this.onToggle});
  final DesktopDownloadCollection collection;

  /// Click / Enter: the library decides between opening and selecting.
  final VoidCallback onTap;

  /// Selection mode shows the checkbox; [selected] draws the accent border.
  final bool selecting, selected;

  /// Toggles this poster's selection; null when selection is unavailable.
  final VoidCallback? onToggle;
  @override
  State<_DownloadPoster> createState() => _DownloadPosterState();
}

/// The picture file a saved cover points to (a `file:` link), or null when
/// the cover is a web picture. A link that cannot be read as a path counts
/// as no file.
File? _localCover(String cover) {
  final uri = Uri.tryParse(cover);
  if (uri == null || uri.scheme != 'file') return null;
  try {
    return File(DesktopStorage.relocatedAppPath(File.fromUri(uri).path));
  } catch (_) {
    return null;
  }
}

class _DownloadPosterState extends State<_DownloadPoster> {
  bool _hover = false;
  bool _focus = false;

  /// Set once this card was drawn while offline with a saved poster.
  bool _preferSaved = false;
  @override
  Widget build(BuildContext context) {
    final c = widget.collection;
    final active = _hover || _focus;
    final reduced = MediaQuery.disableAnimationsOf(context);
    final icon = c.key.kind == 'video' ? 'circle-play' : 'book-open';
    final fallback = Center(child: SvgPicture.asset('assets/icons/lucide/$icon.svg',
      width: 32, height: 32, colorFilter: const ColorFilter.mode(AppColors.textSecondary, BlendMode.srcIn)));
    final bytes = c.bytes;
    return AnimatedContainer(duration: reduced ? Duration.zero : const Duration(milliseconds: 150),
      decoration: BoxDecoration(color: active || widget.selected ? AppColors.surface2 : AppColors.surface,
        borderRadius: BorderRadius.circular(14), border: Border.all(
          width: widget.selected ? 2 : 1,
          color: widget.selected || active ? AppColors.accent : Colors.white.withValues(alpha: .08))),
      clipBehavior: Clip.antiAlias,
      child: Material(color: Colors.transparent, child: InkWell(
        onTap: widget.onTap,
        onHover: (v) => setState(() => _hover = v),
        onFocusChange: (v) => setState(() => _focus = v),
        borderRadius: BorderRadius.circular(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(child: Stack(fit: StackFit.expand, children: [
            ColoredBox(color: AppColors.surface2,
            child: c.cover?.isNotEmpty == true || c.savedPosters.isNotEmpty
                ? ValueListenableBuilder<bool>(
                valueListenable: downloadArtworkOffline,
                builder: (context, offline, _) {
              // Offline: the saved poster opens at once. A card drawn offline
              // keeps it, so the network coming back never swaps the picture.
              if (offline && c.savedPosters.isNotEmpty) _preferSaved = true;
              return LayoutBuilder(builder: (context, box) {
              // Decode at the real screen pixels of the tile and fetch the
              // smallest CDN size that covers them (sharp, but not a
              // several-megabyte original for a small tile).
              final decode = desktopArtworkDecodeWidth(box.maxWidth, MediaQuery.devicePixelRatioOf(context));
              final fitWhole = defaultTargetPlatform == TargetPlatform.windows;
              // The saved posters, then [next] when none of them opens.
              Widget savedOr(Widget next, {String? except}) => SavedArtwork(
                paths: [for (final path in c.savedPosters)
                  if (except == null || !p.equals(path, except)) path],
                fallback: next, decodeWidth: decode, fitWhole: fitWhole);
              final cover = c.cover;
              if (cover == null || cover.isEmpty) return savedOr(fallback);
              // A show known only from files on disk has its poster saved
              // next to them (file: link). The web image loader cannot read
              // that, so the card stayed blank; open the file instead.
              final local = _localCover(cover);
              if (local != null) {
                return ProgressiveArtwork(
                  preview: ResizeImage(FileImage(local), width: decode),
                  full: null,
                  fitWhole: fitWhole,
                  fallback: savedOr(fallback, except: local.path));
              }
              final previewUrl = artworkPreviewUrl(cover);
              final fullUrl = desktopArtworkUrl(cover, targetWidth: decode);
              // Same URL for both: the preview already has enough pixels, so
              // load it once at the full decode width.
              final staged = previewUrl != fullUrl;
              Widget webOr(Widget next) => ProgressiveArtwork(
                preview: ResizeImage(CachedNetworkImageProvider(previewUrl, headers: c.coverHeaders),
                  width: staged ? 96 : decode),
                full: staged
                    ? ResizeImage(CachedNetworkImageProvider(fullUrl, headers: c.coverHeaders), width: decode)
                    : null,
                // Windows: art that is not poster-shaped is shown whole over
                // a soft blurred copy instead of being cropped.
                fitWhole: fitWhole,
                fallback: next);
              // Online: the web cover, and the saved poster only when it
              // fails (no swap while it loads). Offline: the saved poster
              // first, the web cover (maybe still cached) only after it.
              return _preferSaved ? savedOr(webOr(fallback)) : webOr(savedOr(fallback));
            });
            }) : fallback),
            // Selection checkbox, shown only in selection mode.
            if (widget.selecting) Positioned(top: 8, left: 8, child: DecoratedBox(
              decoration: BoxDecoration(color: Colors.black.withValues(alpha: .55),
                borderRadius: BorderRadius.circular(8)),
              child: Checkbox(
                key: ValueKey('select-${c.key.showId}'),
                semanticLabel: context.l10n.selectNamed(c.title),
                value: widget.selected,
                onChanged: widget.onToggle == null ? null : (_) => widget.onToggle!()))),
          ])),
          Padding(padding: const EdgeInsets.all(12), child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(c.title, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              // Size next to the count so "Sort by size" is easy to read (dl-9).
              Text('${context.l10n.ofTotalDownloaded(c.saved, c.total)}${bytes > 0 ? ' - ${formatBytes(bytes)}' : ''}',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
              const SizedBox(height: 4),
              Text('${c.videos.any((r) => r.recoveredFromDisk) && [...c.videos, ...c.failedVideos].any((r) => !r.recoveredFromDisk) ? context.l10n.savedEpisodes : downloadSourceLabel(c.key.sourceId, c.videos)}${c.pending > 0 ? ' - ${context.l10n.countActive(c.pending)}' : ''}',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: AppColors.textTertiary, fontSize: 11)),
            ])),
        ]))));
  }
}


/// Readable source name for a download card instead of the raw id ("zm",
/// "cs:...", "ani:..."). Auto Resolve downloads name the source the files
/// actually came from (most common pick), or "Auto Resolve" when unknown.
String downloadSourceLabel(String sourceId, List<DownloadRecord> videos) {
  var id = sourceId;
  if (sourceId == 'zm') {
    final counts = <String, int>{};
    for (final r in videos) {
      final from = r.resolveSourceId;
      if (from != null && from.isNotEmpty && from != 'zm') {
        counts[from] = (counts[from] ?? 0) + 1;
      }
    }
    if (counts.isEmpty) return 'Auto Resolve';
    id = (counts.entries.toList()..sort((a, b) => b.value - a.value)).first.key;
  }
  final name = sl.isRegistered<SourceRepository>()
      ? sl<SourceRepository>().displayName(id)
      : id;
  // Unknown or uninstalled source: drop the internal prefix at least.
  if (name == id) {
    final colon = id.indexOf(':');
    return colon >= 0 ? id.substring(colon + 1) : id;
  }
  return name;
}

/// "Subbed" / "Dubbed" for a download's audio category instead of the raw
/// code (dl-12). Unknown categories are shown as they are.
String downloadCategoryLabel(String category) =>
    switch (category.trim().toLowerCase()) {
      'sub' => appL10n.subbed,
      'dub' => appL10n.dubbed,
      // Unknown codes are kept exactly as stored, not lowercased.
      _ => category,
    };
