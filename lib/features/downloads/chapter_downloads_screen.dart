import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'download_thumbnail.dart';
import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';

import '../../core/di/injector.dart';
import '../../core/download/chapter_download.dart';
import '../../core/download/chapter_download_store.dart';
import '../../core/download/chapter_downloader.dart';
// Same Recycle Bin gate the store uses, for the 'Moved to the Recycle Bin'
// message (dl-2).
import '../../core/download/download_recycle.dart';
import '../../core/models/episode.dart';
import '../../core/mode/content_mode.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/app_dialog.dart';
import '../../core/ui/settings_widgets.dart';
import '../../core/ui/states.dart';
import '../../l10n/l10n.dart';
import '../reader/manga_reader_screen.dart';
import '../reader/novel_reader_screen.dart';
import '../../core/ui/poster_card.dart' show posterGridColumns;
import 'download_library_widgets.dart';

/// Saved chapters for one reading mode.
///
/// One screen per mode rather than a shared list: manga is pages and novels
/// are text, they're browsed in different places, and mixing them under the
/// episode downloads made the video screen read like a dumping ground.
class ChapterDownloadsScreen extends StatefulWidget {
  const ChapterDownloadsScreen({
    super.key,
    required this.mode,
    this.embedded = false,
    this.query,
    this.sourceId,
    this.showId,
  });

  final ContentMode mode;
  final bool embedded;
  final String? query;

  /// Optional exact title scope from the Windows unified offline library.
  final String? sourceId;
  final String? showId;

  @override
  State<ChapterDownloadsScreen> createState() => _ChapterDownloadsScreenState();
}

class _ChapterDownloadsScreenState extends State<ChapterDownloadsScreen> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  String get _effectiveQuery => widget.query ?? _query;

  /// Show keys the user has expanded. Empty = all collapsed.
  final Set<String> _expanded = <String>{};

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _toggle(String key) => setState(() {
    if (!_expanded.remove(key)) _expanded.add(key);
  });

  bool _inScope(ChapterDownload c) => c.mode == widget.mode &&
      (widget.sourceId == null || c.sourceId == widget.sourceId) &&
      (widget.showId == null || c.showId == widget.showId);

  bool _matchesQuery(ChapterDownload c) {
    final q = _effectiveQuery.trim().toLowerCase();
    return q.isEmpty ||
        c.showTitle.toLowerCase().contains(q) ||
        c.chapterTitle.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final store = sl<ChapterDownloadStore>();
    final isNovel = widget.mode == ContentMode.novel;
    final l10n = context.l10n;
    // Only the box is watched here. The downloader fires per page, and
    // rebuilding a few thousand rows twice a second for a progress bar on one
    // of them is what made this screen crawl — the progress tiles subscribe
    // to it themselves instead.
    final content = ValueListenableBuilder<Box<Map>>(
      valueListenable: store.listenable(),
      builder: (context, box, _) {
        final all = store.all();
        if (!all.any(_inScope)) {
          return EmptyState(
            icon: isNovel ? Icons.article_outlined : Icons.menu_book_outlined,
            message: isNovel
                ? l10n.novelChaptersYouDownloadAppearHere
                : l10n.mangaChaptersYouDownloadAppearHere,
          );
        }
        if (widget.embedded) return _embeddedLibrary(all, l10n);
        final sections = _sections(all, l10n);
        return Column(
          children: [
            _searchField(),
            Expanded(
              // Lazily — a saved series can be thousands of rows, and the
              // eager ListView built every one of them before the first
              // frame.
              child: ListView.builder(
                itemCount: sections.length,
                itemBuilder: (context, i) => sections[i](),
              ),
            ),
          ],
        );
      },
    );
    return widget.embedded
        ? content
        : Scaffold(
            backgroundColor: AppColors.bg,
            appBar: settingsAppBar(
              isNovel ? l10n.novelDownloads : l10n.mangaDownloads,
            ),
            body: content,
          );
  }

  /// What's running (plus anything that failed, so it can be cleared), then
  /// what's saved grouped by show. [ChapterDownloadStore.all] is already
  /// newest-first, so filling the map in that order puts the newest show's
  /// group first for free.
  List<Widget Function()> _sections(
    List<ChapterDownload> all,
    AppLocalizations l10n, {
    bool activeOnly = false,
  }) {
    final downloader = sl<ChapterDownloader>();
    final live = Map<String, ChapterDownload>.fromEntries(
      downloader.inFlight.entries.where((e) => _inScope(e.value)),
    );
    final saved = all
        .where(_inScope)
        .where(_matchesQuery)
        .toList();

    final active = <ChapterDownload>[
      ...live.values.where(_matchesQuery),
      // Not running and not done = a run that died or errored; the box reports
      // both as failed (see ChapterDownload.fromJson).
      ...saved.where(
        (c) =>
            !live.containsKey(c.id) && c.status == ChapterDownloadStatus.failed,
      ),
    ];

    final byShow = <String, List<ChapterDownload>>{};
    for (final c in saved) {
      if (c.status != ChapterDownloadStatus.done) continue;
      (byShow['${c.sourceId}|${c.showId}'] ??= <ChapterDownload>[]).add(c);
    }

    final running = active.where((c) => live.containsKey(c.id)).length;
    final failed = active.length - running;

    return [
      if (active.isNotEmpty) ...[
        () => _sectionHeader(
          l10n.downloadingSection,
          // Cancelling a big queue an X at a time isn't realistic, so the stop
          // lives up here where it covers the lot.
          action: running > 0 ? l10n.stopAllCount(running) : null,
          onAction: running > 0 ? () => _confirmStopAll(running, l10n) : null,
          extra: failed > 0 ? l10n.clearFailedCount(failed) : null,
          onExtra: failed > 0 ? () => _clearFailed(l10n) : null,
          // Windows: re-queue every failed chapter at once (dl-10). Partial
          // pages are kept, so only what is missing is fetched again.
          retry: _desktop && failed > 0
              ? l10n.retryFailedCount(failed)
              : null,
          onRetry: _desktop && failed > 0 ? _retryFailed : null,
        ),
        for (final c in active)
          () => _ChapterProgressTile(
            id: c.id,
            fallback: c,
            compact: widget.embedded,
          ),
      ],
      if (!activeOnly && byShow.isNotEmpty) ...[
        () => _sectionHeader(l10n.downloaded),
        for (final e in byShow.entries)
          () => _ChapterGroup(
            chapters: e.value,
            // Searching reveals the matches instead of making the user expand
            // every group.
            // A Windows title-scoped view always opens its single group.
            expanded: widget.showId != null ||
                _effectiveQuery.trim().isNotEmpty ||
                _expanded.contains(e.key),
            onToggle: () => _toggle(e.key),
          ),
      ],
    ];
  }

  Widget _embeddedLibrary(List<ChapterDownload> all, AppLocalizations l10n) {
    final active = _sections(all, l10n, activeOnly: true);
    final byShow = <String, List<ChapterDownload>>{};
    for (final chapter in all) {
      if (!_inScope(chapter) ||
          chapter.status != ChapterDownloadStatus.done ||
          !_matchesQuery(chapter)) {
        continue;
      }
      (byShow['${chapter.sourceId}|${chapter.showId}'] ??= []).add(chapter);
    }
    final groups = byShow.values.toList();
    if (active.isEmpty && groups.isEmpty) {
      return EmptyState(
        icon: Icons.search_off_rounded,
        message: l10n.noDownloadsMatchYourSearch,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = posterGridColumns(context);
        final cellWidth =
            (constraints.maxWidth - 32 - 12 * (columns - 1)) / columns;
        return CustomScrollView(
          key: PageStorageKey('chapter-downloads-${widget.mode.name}'),
          slivers: [
            SliverList.builder(
              itemCount: active.length,
              itemBuilder: (context, index) => active[index](),
            ),
            if (groups.isNotEmpty) ...[
              SliverToBoxAdapter(child: _sectionHeader(l10n.downloaded)),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 16,
                    mainAxisExtent:
                        cellWidth * 1.5 +
                        MediaQuery.textScalerOf(context).scale(12) * 6.5,
                  ),
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final chapters = groups[index];
                    final head = chapters.first;
                    final bytes = chapters.fold<int>(
                      0,
                      (sum, chapter) => sum + chapter.bytes,
                    );
                    return DownloadLibraryPoster(
                      title: head.showTitle,
                      heroTag: (
                        'download-chapter',
                        widget.mode,
                        head.sourceId,
                        head.showId,
                      ),
                      cover: head.cover,
                      countLabel: '${chapters.length}',
                      sizeLabel: fmtDownloadSize(bytes),
                      deleteTooltip: l10n.deleteAllChaptersTooltip,
                      onDelete: () => _confirmDeleteChapters(context, chapters),
                      onOpen: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => _DownloadedChaptersScreen(
                            sourceId: head.sourceId,
                            showId: head.showId,
                            mode: widget.mode,
                            query: _effectiveQuery,
                          ),
                        ),
                      ),
                    );
                  }, childCount: groups.length),
                ),
              ),
            ],
            SliverToBoxAdapter(
              child: SizedBox(
                height: MediaQuery.paddingOf(context).bottom + 16,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _sectionHeader(
    String text, {
    String? action,
    VoidCallback? onAction,
    String? extra,
    VoidCallback? onExtra,
    String? retry,
    VoidCallback? onRetry,
  }) => Padding(
    padding: EdgeInsets.fromLTRB(16, 18, 8, action == null ? 4 : 0),
    child: Row(
      children: [
        Expanded(child: Text(text.toUpperCase(), style: AppText.overline)),
        // 'Retry failed (N)' sits beside 'Clear failed' (Windows, dl-10).
        if (retry != null)
          TextButton(
            onPressed: onRetry,
            child: Text(
              retry,
              style: AppText.caption.copyWith(color: AppColors.textSecondary),
            ),
          ),
        if (extra != null)
          TextButton(
            onPressed: onExtra,
            child: Text(
              extra,
              style: AppText.caption.copyWith(color: AppColors.textSecondary),
            ),
          ),
        if (action != null)
          TextButton(
            onPressed: onAction,
            child: Text(
              action,
              style: AppText.caption.copyWith(
                color: AppColors.accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
      ],
    ),
  );

  Future<void> _confirmStopAll(int n, AppLocalizations l10n) async {
    final ok = await AppDialog.confirm(
      context,
      title: l10n.stopDownloading,
      message: l10n.stopDownloadingBody(n),
      cancelLabel: l10n.keepGoing,
      confirmLabel: l10n.stopAll,
      destructive: true,
    );
    if (ok != true) return;
    final downloader = sl<ChapterDownloader>();
    if (widget.sourceId == null && widget.showId == null) {
      await downloader.cancelAll();
    } else {
      // A title-scoped desktop view must never cancel unrelated reading jobs.
      final ids = downloader.inFlight.values.where(_inScope).map((c) => c.id).toList();
      for (final id in ids) { await downloader.cancel(id); }
    }
  }

  /// Windows desktop UI only: phone keeps its original chapter rows.
  static bool get _desktop => defaultTargetPlatform == TargetPlatform.windows;

  /// Re-queues the failed chapters this view shows (dl-10). A title-scoped
  /// view only touches its own title, like Clear failed.
  Future<void> _retryFailed() async {
    final downloader = sl<ChapterDownloader>();
    if (widget.sourceId == null && widget.showId == null) {
      await downloader.retryFailed();
      return;
    }
    final failed = sl<ChapterDownloadStore>().all().where(_inScope)
        .where((c) => c.status == ChapterDownloadStatus.failed).toList();
    // Oldest first, matching the unscoped retry order.
    for (final c in failed.reversed) {
      await downloader.retry(c.id);
    }
  }

  Future<void> _clearFailed(AppLocalizations l10n) async {
    final downloader = sl<ChapterDownloader>();
    int n;
    if (widget.sourceId == null && widget.showId == null) {
      n = await downloader.clearFailed();
    } else {
      final store = sl<ChapterDownloadStore>();
      final failed = store.all().where(_inScope)
          .where((c) => c.status == ChapterDownloadStatus.failed).toList();
      n = 0;
      for (final c in failed) {
        // A retry started since the snapshot still owns its files.
        if (downloader.isBusy(c.id)) continue;
        await store.remove(c.id);
        n++;
      }
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(l10n.clearedFailedCount(n))));
  }

  Widget _searchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
      child: TextField(
        controller: _searchCtrl,
        onChanged: (v) => setState(() => _query = v),
        style: AppText.body.copyWith(color: AppColors.textPrimary),
        decoration: InputDecoration(
          isDense: true,
          hintText: context.l10n.searchDownloads,
          hintStyle: AppText.body.copyWith(color: AppColors.textTertiary),
          prefixIcon: const Icon(
            Icons.search_rounded,
            color: AppColors.textTertiary,
          ),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(
                    Icons.close_rounded,
                    color: AppColors.textTertiary,
                  ),
                  onPressed: () {
                    _searchCtrl.clear();
                    setState(() => _query = '');
                  },
                ),
          filled: true,
          fillColor: AppColors.surface,
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }
}

/// Small glyph that tells a manga chapter from a novel one at a glance.
IconData chapterIcon(ContentMode mode) =>
    mode == ContentMode.novel ? Icons.article_rounded : Icons.menu_book_rounded;

/// One chapter that's running, queued, or dead. The X cancels a live one and
/// clears a failed one — both end up dropping the record and its files.
class _ChapterProgressTile extends StatelessWidget {
  const _ChapterProgressTile({
    required this.id,
    required this.fallback,
    this.compact = false,
  });
  final bool compact;

  final String id;

  /// Shown once the chapter is no longer running — a failed one, which is the
  /// only other thing that can sit in this section.
  final ChapterDownload fallback;

  @override
  Widget build(BuildContext context) {
    // Subscribing here rather than around the whole list: the downloader ticks
    // per page, and only this row cares.
    return ListenableBuilder(
      listenable: sl<ChapterDownloader>(),
      builder: (context, _) {
        final running = sl<ChapterDownloader>().inFlight[id];
        return _tile(context, running ?? fallback, running != null);
      },
    );
  }

  static String _titleOf(AppLocalizations l10n, ChapterDownload chapter) =>
      chapter.chapterTitle.trim().isEmpty ? l10n.chapter : chapter.chapterTitle;

  static String _subtitleOf(
    AppLocalizations l10n,
    ChapterDownload chapter,
    bool live,
  ) {
    if (!live) {
      return l10n.showTitleWithError(
        chapter.showTitle,
        chapter.error ?? l10n.downloadFailedStatus,
      );
    }
    if (chapter.status == ChapterDownloadStatus.queued) {
      return l10n.showTitleQueued(chapter.showTitle);
    }
    if (chapter.pageCount > 0) {
      return '${chapter.showTitle} · '
          '${l10n.chapterPagesProgress(chapter.pagesDone, chapter.pageCount)}';
    }
    return l10n.showTitleDownloading(chapter.showTitle);
  }

  Widget _tile(BuildContext context, ChapterDownload chapter, bool live) {
    final l10n = context.l10n;
    // The X: cancels a live chapter, clears a failed one.
    final close = IconButton(
      visualDensity: VisualDensity.compact,
      tooltip: live ? l10n.cancelDownloadTooltip : l10n.removeDownloadTooltip,
      icon: const Icon(Icons.close_rounded, color: AppColors.textSecondary),
      onPressed: () => unawaited(
        live
            ? sl<ChapterDownloader>().cancel(chapter.id)
            : sl<ChapterDownloadStore>().remove(chapter.id),
      ),
    );
    // Failed rows on the Windows desktop UI also get a Retry button.
    final retryable = !live && defaultTargetPlatform == TargetPlatform.windows;
    return ListTile(
      dense: compact,
      minLeadingWidth: compact ? 28 : null,
      contentPadding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
      leading: Icon(
        live ? chapterIcon(chapter.mode) : Icons.error_outline_rounded,
        color: AppColors.accent,
        size: compact ? 21 : 26,
      ),
      title: Text(
        _titleOf(l10n, chapter),
        style: AppText.body.copyWith(
          color: AppColors.textPrimary,
          fontSize: compact ? 13 : null,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _subtitleOf(l10n, chapter, live),
            style: AppText.caption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (live) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: chapter.progress > 0 ? chapter.progress : null,
                minHeight: 3,
                color: AppColors.accent,
                backgroundColor: AppColors.surface2,
              ),
            ),
          ],
        ],
      ),
      trailing: retryable
          // Windows: a failed chapter can be retried in place (dl-10); the
          // pages it already fetched are reused.
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: l10n.retry,
                  icon: const Icon(
                    Icons.refresh_rounded,
                    color: AppColors.textSecondary,
                  ),
                  onPressed: () =>
                      unawaited(sl<ChapterDownloader>().retry(chapter.id)),
                ),
                close,
              ],
            )
          // Phone (and live rows) keep the single X exactly as before.
          : close,
    );
  }
}

/// Saved chapters of one show — "Title · 3 chapters · 142 MB", collapsed by
/// default.
class _ChapterGroup extends StatelessWidget {
  const _ChapterGroup({
    required this.chapters,
    required this.expanded,
    required this.onToggle,
  });

  final List<ChapterDownload> chapters;
  final bool expanded;
  final VoidCallback onToggle;

  /// Reading order, not download order. Sources that give a chapter number get
  /// sorted by it; the rest fall back to the order they were saved in, oldest
  /// first, which is the closest thing to reading order we have.
  List<ChapterDownload> get ordered => _orderedChapters(chapters);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final head = chapters.first;
    final bytes = chapters.fold<int>(0, (s, c) => s + c.bytes);
    final n = chapters.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 44,
                    height: 62,
                    // No cover headers on a chapter record, so a Referer-locked
                    // cover just falls through to the placeholder.
                    child: (head.cover != null && head.cover!.isNotEmpty)
                        ? CachedNetworkImage(
                            imageUrl: head.cover!,
                            fit: BoxFit.cover,
                            // 44x62 thumb: decode small, not full poster.
                            memCacheWidth: 132,
                            errorWidget: (c, u, e) =>
                                ColoredBox(color: AppColors.surface2),
                          )
                        : ColoredBox(color: AppColors.surface2),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        head.showTitle,
                        style: AppText.headline,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        l10n.chaptersWithSize(n, fmtDownloadSize(bytes)),
                        style: AppText.caption,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(
                    Icons.delete_outline_rounded,
                    color: AppColors.textTertiary,
                    size: 22,
                  ),
                  tooltip: l10n.deleteAllChaptersTooltip,
                  onPressed: () => _confirmDeleteChapters(context, chapters),
                ),
                AnimatedRotation(
                  turns: expanded ? 0.25 : 0.0,
                  duration: const Duration(milliseconds: 180),
                  child: const Icon(
                    Icons.chevron_right_rounded,
                    color: AppColors.textTertiary,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (expanded)
          for (final c in ordered)
            _SavedChapterTile(
              chapter: c,
              onTap: () => _openReader(context, ordered, c),
            ),
        const SizedBox(height: 6),
      ],
    );
  }
}

List<ChapterDownload> _orderedChapters(List<ChapterDownload> chapters) {
  final out = [...chapters];
  final numbered = out.every((c) => c.number != null);
  out.sort(
    numbered
        ? (a, b) => a.number!.compareTo(b.number!)
        : (a, b) => a.createdAt.compareTo(b.createdAt),
  );
  return out;
}

Future<void> _confirmDeleteChapters(
  BuildContext context,
  List<ChapterDownload> chapters,
) async {
  final l10n = context.l10n;
  final ok = await AppDialog.confirm(
    context,
    title: l10n.deleteAllChapters2,
    message: l10n.removeAllChaptersOfShow(
      chapters.length,
      chapters.first.showTitle,
    ),
    confirmLabel: l10n.deleteAll,
    destructive: true,
  );
  if (ok != true) return;
  final store = sl<ChapterDownloadStore>();
  for (final c in chapters) {
    await store.remove(c.id);
  }
}

class _DownloadedChaptersScreen extends StatelessWidget {
  const _DownloadedChaptersScreen({
    required this.sourceId,
    required this.showId,
    required this.mode,
    required this.query,
  });
  final String sourceId;
  final String showId;
  final ContentMode mode;
  final String query;

  @override
  Widget build(BuildContext context) {
    final store = sl<ChapterDownloadStore>();
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        surfaceTintColor: Colors.transparent,
        title: Text(
          mode == ContentMode.novel ? l10n.novelDownloads : l10n.mangaDownloads,
          style: AppText.headline,
        ),
      ),
      body: ValueListenableBuilder<Box<Map>>(
        valueListenable: store.listenable(),
        builder: (context, _, _) {
          final q = query.trim().toLowerCase();
          final chapters = _orderedChapters(
            store
                .all()
                .where(
                  (c) =>
                      c.sourceId == sourceId &&
                      c.showId == showId &&
                      c.mode == mode &&
                      c.status == ChapterDownloadStatus.done &&
                      (q.isEmpty ||
                          c.showTitle.toLowerCase().contains(q) ||
                          c.chapterTitle.toLowerCase().contains(q)),
                )
                .toList(),
          );
          if (chapters.isEmpty) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (context.mounted &&
                  ModalRoute.of(context)?.isCurrent == true) {
                Navigator.of(context).pop();
              }
            });
            return const SizedBox.shrink();
          }
          final head = chapters.first;
          final bytes = chapters.fold<int>(0, (sum, c) => sum + c.bytes);
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: DownloadTitleSummary(
                  title: head.showTitle,
                  heroTag: ('download-chapter', mode, sourceId, showId),
                  cover: head.cover,
                  subtitle: l10n.chaptersWithSize(
                    chapters.length,
                    fmtDownloadSize(bytes),
                  ),
                  deleteTooltip: l10n.deleteAllChaptersTooltip,
                  onDelete: () => _confirmDeleteChapters(context, chapters),
                ),
              ),
              SliverList.separated(
                itemCount: chapters.length,
                itemBuilder: (context, index) => _SavedChapterTile(
                  chapter: chapters[index],
                  compact: true,
                  onTap: () => _openReader(context, chapters, chapters[index]),
                ),
                separatorBuilder: (_, _) => const Divider(
                  height: 12,
                  indent: 56,
                  endIndent: 20,
                  color: AppColors.hairline,
                ),
              ),
              SliverToBoxAdapter(
                child: SizedBox(
                  height: MediaQuery.paddingOf(context).bottom + 24,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Opens the reader on this show's saved chapters only. Paging past the last
/// downloaded one stops there rather than hitting the network — the point of
/// opening it from here is that it works offline.
void _openReader(
  BuildContext context,
  List<ChapterDownload> ordered,
  ChapterDownload tapped,
) {
  final eps = [
    for (final c in ordered)
      Episode(
        id: c.chapterId,
        title: c.chapterTitle,
        url: c.chapterUrl,
        number: c.number,
      ),
  ];
  final index = ordered.indexWhere((c) => c.id == tapped.id);
  final head = ordered.first;
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => tapped.mode == ContentMode.novel
          ? NovelReaderScreen(
              sourceId: head.sourceId,
              showId: head.showId,
              showTitle: head.showTitle,
              cover: head.cover,
              chapters: eps,
              startIndex: index < 0 ? 0 : index,
            )
          : MangaReaderScreen(
              sourceId: head.sourceId,
              showId: head.showId,
              showTitle: head.showTitle,
              cover: head.cover,
              chapters: eps,
              startIndex: index < 0 ? 0 : index,
            ),
    ),
  );
}

/// One saved chapter — tapping reads it offline.
class _SavedChapterTile extends StatelessWidget {
  const _SavedChapterTile({
    required this.chapter,
    required this.onTap,
    this.compact = false,
  });
  final bool compact;

  final ChapterDownload chapter;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListTile(
      dense: compact,
      minLeadingWidth: compact ? 28 : null,
      onTap: onTap,
      contentPadding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
      // Windows keeps its scoped-header artwork tile; other platforms use the
      // upstream chapter thumbnail.
      leading: defaultTargetPlatform == TargetPlatform.windows
          ? SizedBox(width: 72, height: 48, child: DownloadThumbnail(
              thumbnail: chapter.thumbnail, cover: chapter.cover, headers: chapter.coverHeaders,
              fallback: Center(child: Icon(chapterIcon(chapter.mode), color: AppColors.accent, size: 26))))
          : (chapter.thumbnail?.trim().isNotEmpty ?? false)
          ? ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: SizedBox(
                width: compact ? 30 : 36,
                height: compact ? 40 : 48,
                child: CachedNetworkImage(
                  imageUrl: chapter.thumbnail!,
                  fit: BoxFit.cover,
                  memCacheWidth: 110,
                  placeholder: (c, u) => ColoredBox(color: AppColors.surface2),
                  errorWidget: (c, u, e) =>
                      ColoredBox(color: AppColors.surface2),
                ),
              ),
            )
          : Icon(
              chapterIcon(chapter.mode),
              color: AppColors.accent,
              size: compact ? 21 : 26,
            ),
      title: Text(
        chapter.chapterTitle.trim().isEmpty
            ? l10n.chapter
            : chapter.chapterTitle,
        style: AppText.body.copyWith(
          color: AppColors.textPrimary,
          fontSize: compact ? 13 : null,
          fontWeight: compact ? FontWeight.w600 : null,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        chapter.bytes > 0 ? fmtDownloadSize(chapter.bytes) : l10n.downloaded,
        style: AppText.caption,
      ),
      trailing: IconButton(
        visualDensity: VisualDensity.compact,
        tooltip: l10n.delete,
        icon: const Icon(
          Icons.delete_outline_rounded,
          color: AppColors.textTertiary,
        ),
        onPressed: () {
          // Windows: the store sends the files to the Recycle Bin (dl-2);
          // say so, so the user knows where to restore them from. Uses the
          // same gate as the store so the message never claims a recycle
          // that did not happen (phone, tests, unfinished chapters).
          final messenger =
              recycleDownloadDeletes &&
                  chapter.status == ChapterDownloadStatus.done
              ? ScaffoldMessenger.maybeOf(context)
              : null;
          unawaited(
            sl<ChapterDownloadStore>().remove(chapter.id).then((_) {
              messenger
                ?..clearSnackBars()
                ..showSnackBar(
                  SnackBar(
                    content: Text(appL10n.movedToRecycleBin),
                  ),
                );
            }),
          );
        },
      ),
    );
  }
}

String fmtDownloadSize(int bytes) {
  if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)} GB';
  if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(0)} MB';
  if (bytes >= 1 << 10) return '${(bytes / (1 << 10)).toStringAsFixed(0)} KB';
  return '$bytes B';
}
