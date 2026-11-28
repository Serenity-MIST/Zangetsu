// Installed-sources results merged into a catalogue (Library scope) search in
// novel and manga mode on Windows.
//
// The catalogue (AniList-style metadata) does not know every web novel or
// manga, so a title like a long web-novel name came back as "No results" even
// though an installed LNReader / Mihon source had it. This section runs the
// SAME multi-source fan-out the sources search uses ([SearchBloc] over
// [SourceRepository], narrowed to the mode's sources) for the query the
// catalogue search ran.
//
// It renders as a continuation of the catalogue results: no heading and no
// per-source groups, just the same poster grid with the source's name as a
// small line under each title, plus one slim status line while sources are
// still answering or when some failed (retry lives in that line's menu).
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/di/injector.dart';
import '../../core/mode/content_mode.dart';
import '../../core/models/media_item.dart';
import '../../core/playback/search_history.dart';
import '../../core/playback/source_health_store.dart' show SourceOutcome;
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/poster_card.dart';
import '../../l10n/l10n.dart';
import '../../l10n/ui_strings.dart';
import '../home/home_catalogue_prefs.dart';
import 'bloc/search_bloc.dart';
import 'bloc/search_event.dart';
import 'bloc/search_state.dart';

/// Whether the installed-sources section belongs under a search.
///
/// A catalogue (Library scope) search gets it in a reading mode (novel or
/// manga), and also in anime mode when Home's catalogue has no tracker behind
/// it ([desktopCatalogueHasNoTracker]: an installed source catalogue is
/// picked). Anime/movies on AniList / MAL / TMDB / Simkl search the catalogue
/// only, exactly as before. Windows only, so phone behaviour is unchanged.
/// [platform] and [catalogueKind] are for tests; null reads the real values.
bool installedSourcesFallbackApplies({
  required bool libraryScope,
  required ContentMode mode,
  TargetPlatform? platform,
  HomeCatalogueKind? catalogueKind,
}) =>
    libraryScope &&
    (platform ?? defaultTargetPlatform) == TargetPlatform.windows &&
    (mode.isReading ||
        desktopCatalogueHasNoTracker(mode, catalogueKind: catalogueKind));

/// True when the catalogue Home shows for [mode] is not a metadata tracker
/// (AniList / MAL / TMDB / Simkl), so "searching" there really means asking
/// the installed sources:
/// * an installed source catalogue is picked on Home (any mode), or
/// * novel mode on the metadata catalogue, which the pill calls "Browse"
///   (trackers list almost no web novels).
///
/// The Stremio catalogue keeps its own search, so it never counts. Mirrors
/// `HomeScreen._desktopCurrentCatalogueId`. [catalogueKind] is for tests;
/// null reads [HomeCataloguePrefs] (prefs not opened means "metadata").
bool desktopCatalogueHasNoTracker(
  ContentMode mode, {
  HomeCatalogueKind? catalogueKind,
}) {
  final kind = catalogueKind ?? _homeCatalogueKind();
  return switch (kind) {
    HomeCatalogueKind.source => true,
    HomeCatalogueKind.stremio => false,
    HomeCatalogueKind.metadata => mode == ContentMode.novel,
  };
}

/// Home's catalogue kind, or "metadata" when the prefs cannot be read.
HomeCatalogueKind _homeCatalogueKind() {
  try {
    return HomeCataloguePrefs.catalogueKind;
  } catch (_) {
    // Prefs box not usable (early boot, tests): the default is metadata.
    return HomeCatalogueKind.metadata;
  }
}

/// One installed-source result: the title and the source that found it.
typedef InstalledSourceEntry = ({MediaItem item, String sourceName});

/// What an installed-sources fan-out ([SearchBloc] over [SourceRepository])
/// has produced so far, flattened for display. Shared by the results page
/// section and the Windows quick search dropdown so both read a run the same
/// way.
class InstalledSourcesSnapshot {
  const InstalledSourcesSnapshot({
    required this.entries,
    required this.pending,
    required this.failed,
    required this.noSources,
    required this.loading,
  });

  /// Every result, in the order the sources answered (new arrivals append).
  final List<InstalledSourceEntry> entries;

  /// Source ids queried but not answered yet.
  final List<String> pending;

  /// Sources that answered with a failure.
  final List<MapEntry<String, SourceOutcome>> failed;

  /// No installed source for the mode (or all switched off for search).
  final bool noSources;

  /// The bloc is still working on the run (it may not have picked its
  /// sources yet, so [pending] can be empty while this is true).
  final bool loading;

  /// Still waiting on at least one source.
  bool get searching => !noSources && (pending.isNotEmpty || loading);

  /// Reads [state] (one run of an installed-sources [SearchBloc]).
  factory InstalledSourcesSnapshot.of(SearchState state) {
    // No installed source for this mode (or all switched off for search).
    final noSources =
        state.status == SearchStatus.error &&
        state.queriedSources.isEmpty &&
        state.failedSources.isEmpty;
    // Flatten every source's results into one list, in the order the
    // sources answered, so new arrivals append at the end instead of
    // reshuffling what is already on screen.
    final groups = List<SourceResultGroup>.of(state.groups)
      ..sort((a, b) => a.arrivalIndex.compareTo(b.arrivalIndex));
    final entries = <InstalledSourceEntry>[
      for (final g in groups)
        for (final item in g.items) (item: item, sourceName: g.sourceName),
    ];
    final landed = {for (final g in groups) g.sourceId};
    // Queried but not answered yet.
    final pending = state.queriedSources
        .where(
          (id) =>
              !landed.contains(id) &&
              !state.respondedSources.contains(id) &&
              !state.failedSources.containsKey(id),
        )
        .toList();
    return InstalledSourcesSnapshot(
      entries: entries,
      pending: pending,
      failed: state.failedSources.entries.toList(),
      noSources: noSources,
      loading:
          state.status == SearchStatus.loading && state.queriedSources.isEmpty,
    );
  }
}

/// What the results-page section has found for [query], published so the
/// page's header and empty state can count source results too (Windows).
@immutable
class InstalledSourcesProgress {
  const InstalledSourcesProgress({
    this.query = '',
    this.resultCount = 0,
    this.sourceCount = 0,
    this.searching = false,
  });

  /// The query these numbers are for ('' before anything was published).
  final String query;

  /// Titles the installed sources returned so far.
  final int resultCount;

  /// How many sources returned at least one title.
  final int sourceCount;

  /// True while the debounce is pending or any source is still answering.
  final bool searching;

  /// True when this progress belongs to [q] (trimmed compare).
  bool isFor(String q) => query.isNotEmpty && query == q.trim();

  @override
  bool operator ==(Object other) =>
      other is InstalledSourcesProgress &&
      other.query == query &&
      other.resultCount == resultCount &&
      other.sourceCount == sourceCount &&
      other.searching == searching;

  @override
  int get hashCode => Object.hash(query, resultCount, sourceCount, searching);
}

/// True when the installed sources may still turn up (or already turned up)
/// titles for [query], so a catalogue-empty or catalogue-error page holds
/// back its big "No results" / error block. Progress not yet published for
/// [query] counts as still searching, so the block never flashes first.
bool installedSourcesMayHaveResults(
  InstalledSourcesProgress progress,
  String query,
) => !progress.isFor(query) || progress.searching || progress.resultCount > 0;

/// The Windows results header's count line when the search also asks the
/// installed sources: catalogue titles plus source titles, and whether the
/// sources are still answering.
///
/// [catalogueCount] is null while the catalogue is loading (then there is no
/// count line at all); a failed catalogue passes 0 so the sources' titles
/// still count.
({int? count, bool searching}) desktopResultsCountWithSources({
  required int? catalogueCount,
  required InstalledSourcesProgress progress,
  required String query,
}) {
  if (catalogueCount == null) return (count: null, searching: false);
  final mine = progress.isFor(query);
  return (
    count: catalogueCount + (mine ? progress.resultCount : 0),
    // Not yet published for this query counts as searching.
    searching: query.trim().isNotEmpty && (!mine || progress.searching),
  );
}

/// Lists results from the user's installed sources for [query] in [mode].
///
/// Owns its own [SearchBloc] (disposed with this widget) so it never touches
/// the catalogue search's state. Query changes are debounced; the bloc drops
/// any run a newer query superseded.
class InstalledSourcesSearchSection extends StatefulWidget {
  const InstalledSourcesSearchSection({
    super.key,
    required this.query,
    required this.mode,
    required this.onOpen,
    this.catalogueEmpty = false,
    this.createBloc,
    this.debounce = const Duration(milliseconds: 400),
    this.progress,
  });

  /// Optional: receives what the section has found for [query] (count,
  /// still searching), so the page header and empty state can include the
  /// installed sources. Owned by the caller; updated after frames and on
  /// bloc events, never during a build.
  final ValueNotifier<InstalledSourcesProgress>? progress;

  /// The query the catalogue search ran. Blank shows nothing.
  final String query;

  /// Which sources to fan out over (novel → LNReader etc, manga → Mihon etc).
  final ContentMode mode;

  /// Opens a result's detail page for its own source.
  final ValueChanged<MediaItem> onOpen;

  /// True when the catalogue found nothing. Only then does an all-empty
  /// sources run say so; under catalogue hits it stays silent.
  final bool catalogueEmpty;

  /// Test seam: builds the section's bloc. Production leaves it null.
  final SearchBloc Function(ContentMode mode)? createBloc;

  /// Wait after the last query change before searching.
  final Duration debounce;

  /// How many sources are queried at once.
  static const int maxConcurrentSources = 4;

  /// Height reserved under each poster for the source-name line (before
  /// text scaling).
  static const double sourceLineHeight = 18;

  @override
  State<InstalledSourcesSearchSection> createState() =>
      _InstalledSourcesSearchSectionState();
}

class _InstalledSourcesSearchSectionState
    extends State<InstalledSourcesSearchSection> {
  late SearchBloc _bloc;
  Timer? _debounce;

  /// Feeds [InstalledSourcesSearchSection.progress] from the bloc's states.
  StreamSubscription<SearchState>? _blocSub;

  /// The query last handed to the bloc; results are only shown for it.
  String _runQuery = '';

  @override
  void initState() {
    super.initState();
    _bloc = _buildBloc();
    _listen();
    _schedule();
  }

  /// Republishes progress on every bloc state (bloc events never arrive
  /// during a build, so the page's listeners can rebuild right away).
  void _listen() {
    _blocSub?.cancel();
    _blocSub = _bloc.stream.listen((_) => _publish());
  }

  /// A source fan-out that never writes history (the catalogue search already
  /// did) and never narrows to the active source.
  SearchBloc _buildBloc() =>
      widget.createBloc?.call(widget.mode) ??
      SearchBloc(
        repo: sl<SourceRepository>(),
        history: sl<SearchHistory>(),
        forceMode: widget.mode,
        maxConcurrent: InstalledSourcesSearchSection.maxConcurrentSources,
        recordHistory: false,
        forceAllSources: true,
      );

  @override
  void didUpdateWidget(covariant InstalledSourcesSearchSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mode != widget.mode) {
      // Different mode, different sources: start over with a fresh bloc.
      _bloc.close();
      _bloc = _buildBloc();
      _listen();
      _runQuery = '';
      _schedule();
    } else if (oldWidget.query.trim() != widget.query.trim()) {
      _schedule();
    }
  }

  /// Debounces the next run so fast typing or quick re-submits only search
  /// once. The bloc's run counter cancels any run still in flight.
  void _schedule() {
    _debounce?.cancel();
    final q = widget.query.trim();
    // Called from initState / didUpdateWidget (inside a build), so the
    // "searching" progress goes out after this frame.
    _publishAfterFrame();
    if (q.isEmpty) return;
    _debounce = Timer(widget.debounce, () {
      if (!mounted) return;
      setState(() => _runQuery = q);
      _bloc.add(SearchRunRequested(q));
      _publish();
    });
  }

  /// What the section has for the current query, in progress terms.
  InstalledSourcesProgress _currentProgress() {
    final q = widget.query.trim();
    if (q.isEmpty) return const InstalledSourcesProgress();
    final state = _bloc.state;
    // Same "is the bloc on this query yet" rule the build uses.
    final current =
        _runQuery == q &&
        state.query.trim() == _runQuery &&
        state.status != SearchStatus.idle;
    if (!current) return InstalledSourcesProgress(query: q, searching: true);
    final snap = InstalledSourcesSnapshot.of(state);
    return InstalledSourcesProgress(
      query: q,
      resultCount: snap.entries.length,
      sourceCount: {for (final e in snap.entries) e.sourceName}.length,
      searching: snap.searching,
    );
  }

  /// Pushes the current progress to the caller's notifier (if any).
  void _publish() {
    final notifier = widget.progress;
    if (notifier == null || !mounted) return;
    notifier.value = _currentProgress();
  }

  /// [_publish] once the current frame is done (safe from build phases).
  void _publishAfterFrame() {
    if (widget.progress == null) return;
    SchedulerBinding.instance.addPostFrameCallback((_) => _publish());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _blocSub?.cancel();
    _bloc.close();
    // Leaving mid-search must not leave the page waiting forever: after this
    // frame, mark this query as no longer searching (keeping its counts).
    final notifier = widget.progress;
    final q = widget.query.trim();
    if (notifier != null && q.isNotEmpty) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        try {
          final v = notifier.value;
          if (v.isFor(q) && v.searching) {
            notifier.value = InstalledSourcesProgress(
              query: q,
              resultCount: v.resultCount,
              sourceCount: v.sourceCount,
            );
          }
        } catch (_) {
          // The page disposed its notifier along with this section.
        }
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.query.trim().isEmpty) return const SizedBox.shrink();
    return BlocBuilder<SearchBloc, SearchState>(
      bloc: _bloc,
      builder: (context, state) {
        // Still waiting for the debounce, or the bloc has not caught up with
        // the newest query yet: a slim "searching" line, not stale results.
        final current =
            _runQuery == widget.query.trim() &&
            state.query.trim() == _runQuery &&
            state.status != SearchStatus.idle;
        if (!current) {
          return _frame(status: _searchingStatus(const []), grid: null);
        }

        // Flattened results, pending and failed sources (shared with the
        // quick search dropdown).
        final snap = InstalledSourcesSnapshot.of(state);

        // No installed source for this mode (or all switched off for search):
        // nothing to offer, so the section stays out of the way.
        if (snap.noSources) return const SizedBox.shrink();

        final entries = snap.entries;
        final pending = snap.pending;
        final failed = snap.failed;

        // One slim status line: "searching" wins while anything is still
        // answering; otherwise the failure summary; otherwise nothing.
        Widget? status;
        if (snap.searching) {
          status = _searchingStatus(pending, failedCount: failed.length);
        } else if (failed.isNotEmpty) {
          status = _failedStatus(failed);
        } else if (entries.isEmpty && widget.catalogueEmpty) {
          // Catalogue and sources both came up empty: say so quietly.
          status = Text(
            'None of your installed sources found it either.',
            key: const ValueKey('installed_sources_none'),
            style: AppText.caption,
          );
        }

        if (status == null && entries.isEmpty) return const SizedBox.shrink();
        return _frame(
          status: status,
          grid: entries.isEmpty ? null : _grid(entries),
        );
      },
    );
  }

  /// Optional status line above the merged grid, with the catalogue grid's
  /// side padding so both read as one list.
  Widget _frame({Widget? status, Widget? grid}) {
    return Padding(
      key: const ValueKey('installed_sources_section'),
      // The catalogue grid ends without a trailing gap, so the top padding
      // supplies the same row gap its own rows use (see
      // DesktopPosterGridDelegate) and the grid reads as one continuous list.
      padding: const EdgeInsets.only(top: 28, bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (status != null)
            Padding(
              key: const ValueKey('installed_sources_status'),
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: status,
            ),
          ?grid,
        ],
      ),
    );
  }

  /// Small spinner + "Searching N sources…". Hovering lists which sources
  /// are still answering. [failedCount] tacks on how many already failed.
  Widget _searchingStatus(List<String> pending, {int failedCount = 0}) {
    final label = pending.isEmpty
        ? 'Searching your sources…'
        : 'Searching ${pending.length} '
              '${pending.length == 1 ? 'source' : 'sources'}…'
              '${failedCount > 0 ? ' · $failedCount failed' : ''}';
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(strokeWidth: 1.6),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            label,
            style: AppText.caption.copyWith(fontSize: 12),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
    if (pending.isEmpty) return row;
    return Tooltip(message: pending.map(_nameOf).join('\n'), child: row);
  }

  /// "N sources failed" as a compact menu button: hover shows which and why,
  /// clicking opens a menu to retry one source or all of them.
  Widget _failedStatus(List<MapEntry<String, SourceOutcome>> failed) {
    final l10n = context.l10n;
    final reasons = [
      for (final f in failed)
        '${_nameOf(f.key)} · ${sourceOutcomeLabel(l10n, f.value)}',
    ];
    return PopupMenuButton<String>(
      key: const ValueKey('installed_sources_failed_menu'),
      tooltip: reasons.join('\n'),
      // Menu value: a source id, or '' for "retry all".
      onSelected: (id) {
        final ids = id.isEmpty ? failed.map((f) => f.key) : [id];
        for (final i in ids) {
          _bloc.add(SearchRetryRequested(i));
        }
      },
      itemBuilder: (context) => [
        for (var i = 0; i < failed.length; i++)
          PopupMenuItem<String>(
            key: ValueKey('installed_sources_retry_${failed[i].key}'),
            value: failed[i].key,
            child: Row(
              children: [
                const Icon(Icons.refresh_rounded, size: 16),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    '${l10n.retry} ${reasons[i]}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        if (failed.length > 1)
          PopupMenuItem<String>(
            key: const ValueKey('installed_sources_retry_all'),
            value: '',
            child: Text('${l10n.retry} all'),
          ),
      ],
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.error_outline_rounded,
            size: 14,
            color: AppColors.textTertiary,
          ),
          const SizedBox(width: 6),
          Text(
            '${failed.length} ${failed.length == 1 ? 'source' : 'sources'} '
            'failed',
            style: AppText.caption.copyWith(fontSize: 12),
          ),
          const SizedBox(width: 6),
          Text(
            l10n.retry,
            style: AppText.caption.copyWith(
              fontSize: 12,
              color: AppColors.accent,
            ),
          ),
        ],
      ),
    );
  }

  /// Readable name for a source id (the repository knows the labels).
  String _nameOf(String id) {
    try {
      return sl<SourceRepository>().displayName(id);
    } catch (_) {
      return id; // Tests without a registered repository.
    }
  }

  /// The merged results: the catalogue grid's own delegate (same columns,
  /// card size and gaps), each cell a little taller for the source line.
  Widget _grid(List<InstalledSourceEntry> entries) {
    final extra = MediaQuery.textScalerOf(
      context,
    ).scale(InstalledSourcesSearchSection.sourceLineHeight);
    final cellW = posterGridCellWidth(context);
    return GridView.builder(
      key: const ValueKey('installed_sources_grid'),
      // Lives inside the search screen's scroll view: size to content and
      // let the outer list do the scrolling.
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      gridDelegate: _ExtraHeightGridDelegate(
        posterGridDelegate(context),
        extra: extra,
      ),
      itemCount: entries.length,
      itemBuilder: (context, i) {
        final e = entries[i];
        final item = e.item;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The poster exactly as the catalogue draws it (title below).
            Expanded(
              child: PosterCard(
                title: item.title,
                logoItem: item,
                imageUrl: item.cover,
                wideImageUrl: item.banner,
                genres: item.genres,
                isAdult: item.isAdult,
                headers: item.coverHeaders,
                cellWidth: cellW,
                onTap: () => widget.onOpen(item),
              ),
            ),
            // Which installed source found it, as a quiet line under the
            // title instead of a separate group heading.
            SizedBox(
              height: extra,
              child: Align(
                alignment: Alignment.bottomLeft,
                child: Text(
                  e.sourceName,
                  key: ValueKey('installed_sources_source_${item.id}'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption.copyWith(fontSize: 11, height: 1.2),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Wraps a poster grid delegate and makes every cell [extra] taller, keeping
/// its column count, cell width and row gap. Lets the merged source results
/// match the catalogue grid while fitting a source-name line under each
/// title.
class _ExtraHeightGridDelegate extends SliverGridDelegate {
  const _ExtraHeightGridDelegate(this.base, {required this.extra});

  /// The catalogue's own delegate ([posterGridDelegate]).
  final SliverGridDelegate base;

  /// Added height per cell.
  final double extra;

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    final layout = base.getLayout(constraints);
    // Both the desktop and phone poster delegates produce regular tiles; any
    // other layout is used unchanged (the source line may then be clipped).
    if (layout is! SliverGridRegularTileLayout) return layout;
    return SliverGridRegularTileLayout(
      crossAxisCount: layout.crossAxisCount,
      mainAxisStride: layout.mainAxisStride + extra,
      crossAxisStride: layout.crossAxisStride,
      childMainAxisExtent: layout.childMainAxisExtent + extra,
      childCrossAxisExtent: layout.childCrossAxisExtent,
      reverseCrossAxis: layout.reverseCrossAxis,
    );
  }

  @override
  bool shouldRelayout(covariant _ExtraHeightGridDelegate oldDelegate) =>
      extra != oldDelegate.extra ||
      base.runtimeType != oldDelegate.base.runtimeType ||
      base.shouldRelayout(oldDelegate.base);
}
