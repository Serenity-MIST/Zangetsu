import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/models/media_item.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/stremio/stremio_poster_shape.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/poster_card.dart';
import '../../core/ui/reveal_item.dart';
import '../../core/ui/states.dart';
import '../../core/zmode/metadata_filters.dart';
import '../../core/zmode/zmode_ids.dart';
import '../../l10n/l10n.dart';
import '../search/meta_filter_sheet.dart';
import '../search/search_page_keys.dart';
import 'see_all_screen_tv.dart';

/// Full-grid view of a single home row ("See All"). Reuses the home's tap /
/// long-press handlers so an item opens the same Detail / info card.
///
/// When [onLoadMore] is provided the grid paginates: scrolling near the bottom
/// fetches the next page and appends it (infinite scroll). When it's null the
/// grid is a fixed list over [items] — byte-for-byte the pre-pagination
/// behaviour, so search / JS / non-paginating callers are unchanged.
class SeeAllScreen extends StatefulWidget {
  const SeeAllScreen({
    super.key,
    required this.title,
    required this.items,
    required this.onTap,
    this.onLongPress,
    this.tagsFor,
    this.onLoadMore,
    this.lazyFixedList = false,
    this.onSearch,
    this.filterKind,
    this.initialFilters = const MetaFilters(),
  });

  final String title;
  final List<MediaItem> items;
  final void Function(MediaItem) onTap;
  final void Function(MediaItem)? onLongPress;

  /// Optional per-item poster badges (e.g. SUB/DUB/MOVIE). When null no tags are
  /// drawn — keeps the home "See All" callers unchanged.
  final List<String> Function(MediaItem)? tagsFor;

  /// Optional next-page fetcher for infinite scroll. `page` is 1-based and the
  /// initial [items] ARE page 1, so the first call requests page 2. Returning an
  /// empty list (or only already-seen items) ends pagination. Null → fixed list.
  final Future<List<MediaItem>> Function(int page)? onLoadMore;

  /// For rows that have no server-side paging (legacy JS providers): reveal
  /// [items] in batches on scroll. No extra network — the provider already
  /// returned the whole row — but the grid behaves like an infinite list.
  final bool lazyFixedList;

  /// Optional query/filter fetcher. When set, the app bar exposes search and
  /// filters and the grid can be refreshed without leaving this page.
  final Future<MediaItemPage> Function(
    String query,
    MetaFilters filters,
    int page,
  )?
  onSearch;
  final ZKind? filterKind;
  final MetaFilters initialFilters;

  @override
  State<SeeAllScreen> createState() => _SeeAllScreenState();
}

class _SeeAllScreenState extends State<SeeAllScreen> {
  static const _lazyBatch = 24;

  late final List<MediaItem> _items = [
    ...widget.items.take(
      widget.lazyFixedList ? _lazyBatch : widget.items.length,
    ),
  ];
  final Set<String> _seen = {};
  final ScrollController _controller = ScrollController();

  /// The last page already loaded — the initial [items] are page 1.
  int _page = 1;
  bool _loading = false;
  bool _end = false;
  bool _showNextPage = false;
  bool _pageFailed = false;
  bool _searching = false;
  int _queryGeneration = 0;
  late MetaFilters _filters;
  final TextEditingController _queryController = TextEditingController();

  /// Focus of the in-page search field, so Ctrl+F can refocus it while the
  /// search is already open (shell-7).
  final FocusNode _fieldFocus = FocusNode();

  /// The first page of a query threw (search-8). Distinct from an empty
  /// answer so Windows can show an error with Retry instead of "No results".
  bool _queryFailed = false;

  /// The query behind the visible results, so Retry and closing the search
  /// know what was actually run (the field may have been cleared since).
  String _lastQuery = '';

  /// Whether the last page added anything new. Auto-filling a tall window
  /// stops when a page adds nothing, so a source that keeps answering with
  /// duplicates can't loop forever (search-2).
  bool _lastAddedFresh = true;

  /// New desktop behaviour is Windows-only; phone keeps today's flow.
  bool get _windows => defaultTargetPlatform == TargetPlatform.windows;

  /// Whether the grid grows on scroll: a pager, a search, or a fixed row
  /// revealed in batches.
  bool get _paginating =>
      widget.onLoadMore != null ||
      widget.onSearch != null ||
      widget.lazyFixedList;

  @override
  void initState() {
    super.initState();
    _filters = widget.initialFilters;
    for (final it in _items) {
      _seen.add(_keyOf(it));
    }
    if (_paginating) {
      _controller.addListener(_onScroll);
    }
    // The first page may already fit a large window with no scrollbar.
    _scheduleFill();
  }

  @override
  void dispose() {
    _controller.dispose();
    _queryController.dispose();
    _fieldFocus.dispose();
    super.dispose();
  }

  /// search-2 Option A (Windows): after a page lands, if the grid can't
  /// scroll yet (or is less than half a screen from the end), fetch the next
  /// page right away. Scroll notifications never fire on a list that fits,
  /// so without this a maximised window looked complete when it wasn't.
  void _scheduleFill() {
    if (!_windows || !_paginating) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _loading || _end || _pageFailed || _queryFailed) return;
      if (!_lastAddedFresh || !_controller.hasClients) return;
      final pos = _controller.position;
      if (pos.extentAfter < pos.viewportDimension * 0.5) _loadMore();
    });
  }

  /// Dedupe key — prefer the stable id, fall back to the url.
  String _keyOf(MediaItem m) => m.id.isNotEmpty ? m.id : m.url;

  void _onScroll() {
    if (_loading || _pageFailed || _end || !_controller.hasClients) return;
    final pos = _controller.position;
    if (pos.pixels >= pos.maxScrollExtent * 0.8) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    final loader = widget.onLoadMore;
    if ((loader == null && widget.onSearch == null && !widget.lazyFixedList) ||
        _loading ||
        _end) {
      return;
    }
    final generation = _queryGeneration;
    setState(() {
      _loading = true;
      _pageFailed = false;
      _showNextPage = false;
    });
    List<MediaItem> next = const [];
    MediaItemPage? searchPage;
    try {
      if (widget.onSearch != null) {
        searchPage = await widget.onSearch!(
          _queryController.text.trim(),
          _filters,
          _page + 1,
        );
        next = searchPage.items;
      } else if (loader != null) {
        next = await loader(_page + 1);
      } else if (widget.lazyFixedList) {
        next = widget.items.skip(_items.length).take(_lazyBatch).toList();
      }
    } catch (_) {
      if (!_windows) {
        next = const [];
      } else {
        if (!mounted || generation != _queryGeneration) return;
        // Windows: a failed request is not a successful empty page. Keep the
        // same page number and expose a retry instead of ending the list.
        setState(() {
          _loading = false;
          _pageFailed = true;
          _showNextPage = true;
        });
        return;
      }
    }
    if (!mounted || generation != _queryGeneration) return;
    final fresh = <MediaItem>[];
    for (final it in next) {
      final k = _keyOf(it);
      if (_seen.add(k)) fresh.add(it);
    }
    setState(() {
      _loading = false;
      _lastAddedFresh = fresh.isNotEmpty;
      if (searchPage != null) {
        _page += 1;
        _items.addAll(fresh);
        _end = !searchPage.hasMore;
        _showNextPage = searchPage.hasMore;
      } else if (fresh.isEmpty) {
        // Nothing new (empty page or all duplicates) → we've hit the end.
        _end = true;
      } else {
        _items.addAll(fresh);
        _page += 1;
      }
    });
    // Keep filling a tall window until it can scroll (Windows only).
    _scheduleFill();
  }

  Future<void> _runQuery(String query) async {
    final search = widget.onSearch;
    if (search == null) return;
    final generation = ++_queryGeneration;
    setState(() {
      _items.clear();
      _seen.clear();
      _page = 1;
      _end = false;
      _loading = true;
      _pageFailed = false;
      _showNextPage = false;
      _queryFailed = false;
      _lastQuery = query.trim();
    });
    var first = const MediaItemPage(items: <MediaItem>[], hasMore: false);
    var failed = false;
    try {
      first = await search(query.trim(), _filters, 1);
    } catch (_) {
      first = const MediaItemPage(items: <MediaItem>[], hasMore: false);
      // search-8: remember the failure so Windows shows an error, not
      // "No results" (offline users otherwise think the title doesn't exist).
      failed = true;
    }
    if (!mounted || generation != _queryGeneration) return;
    final fresh = <MediaItem>[];
    for (final item in first.items) {
      if (_seen.add(_keyOf(item))) fresh.add(item);
    }
    setState(() {
      _items.addAll(fresh);
      _loading = false;
      _end = !first.hasMore;
      _showNextPage = first.hasMore;
      _queryFailed = failed;
      _lastAddedFresh = fresh.isNotEmpty;
    });
    _scheduleFill();
  }

  Future<void> _openFilters() async {
    final kind = widget.filterKind;
    if (kind == null) return;
    final picked = await showMetaFilterSheet(
      context,
      kind,
      _filters,
      showStatus: false,
    );
    if (!mounted || picked == null) return;
    setState(() => _filters = picked);
    await _runQuery(_queryController.text);
  }

  /// Opens the in-page search field.
  void _beginSearch() {
    setState(() => _searching = true);
    // Windows: the page's key listener (SearchPageKeys) already holds focus
    // in this route, and autofocus never steals focus from a focused scope,
    // so put the cursor in the new field explicitly once it is built.
    if (_windows) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _searching) _fieldFocus.requestFocus();
      });
    }
  }

  void _toggleSearch() {
    if (!_searching) {
      _beginSearch();
      return;
    }
    // On Windows Esc may already have cleared the text, so also look at the
    // query that is actually on screen before deciding to reset the grid.
    final hadQuery = _queryController.text.trim().isNotEmpty ||
        (_windows && _lastQuery.isNotEmpty);
    _queryController.clear();
    if (_windows) {
      // Hand focus back to what had it before the field (the page's key
      // listener), so Ctrl+F / Esc keep working after the search closes.
      // Unfocusing the whole scope would leave the page deaf to keys.
      _fieldFocus.unfocus(
        disposition: UnfocusDisposition.previouslyFocusedChild,
      );
    } else {
      FocusScope.of(context).unfocus();
    }
    setState(() => _searching = false);
    if (hadQuery) _runQuery('');
  }

  /// Ctrl+F on Windows (shell-7): open this page's search, or put the cursor
  /// back in it (text selected) when it is already open.
  void _openSearch() {
    if (!_searching) {
      _beginSearch();
      return;
    }
    _fieldFocus.requestFocus();
    _queryController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _queryController.text.length,
    );
  }

  /// Page-level Esc on Windows: an open in-page search closes before the
  /// app-wide Esc gets to go back.
  bool _escapeSearch() {
    if (!_searching) return false;
    _toggleSearch();
    return true;
  }

  /// One poster cell. [height] is the phone per-card height; null on
  /// Windows, where the grid delegate sizes the cell itself.
  Widget _cell(int i, double cellW, double? aspect, double? height) {
    final item = _items[i];
    final card = PosterCard(
      title: item.title,
      logoItem: item,
      imageUrl: item.cover,
      wideImageUrl: item.banner,
      genres: item.genres,
      isAdult: item.isAdult,
      headers: item.coverHeaders,
      tags: widget.tagsFor?.call(item) ?? const [],
      qualityBadge: item.quality,
      scoreBadge: item.score,
      dubBadge: item.dubBadge,
      cellWidth: cellW,
      wideOverride: aspect == null ? null : aspect > 1,
      onTap: () => widget.onTap(item),
      onLongPress: widget.onLongPress == null
          ? null
          : () => widget.onLongPress!(item),
    );
    // Windows: the card fills its delegate-sized cell, the same way the
    // source browser's desktop grid lays PosterCards out.
    if (height == null) return RevealItem(index: i, child: card);
    return RevealItem(
      index: i,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(height: height, child: card),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (sl<AppMode>().isTv) {
      return SeeAllScreenTv(
        title: widget.title,
        items: widget.items,
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        tagsFor: widget.tagsFor,
        onLoadMore: widget.onLoadMore,
        onSearch: widget.onSearch,
        filterKind: widget.filterKind,
        initialFilters: widget.initialFilters,
      );
    }
    final cellW = posterGridCellWidth(context);
    final windows = _windows;
    final landscape = posterLayout(context) == PosterCardLayout.wide;
    // search-12 Option B: on Windows the desktop grid delegate sizes every
    // cell itself, so the per-card aspect/height pass over ALL items (which
    // re-ran on every page and setState) is skipped; each built cell works
    // out its own aspect lazily in the item builder instead.
    final aspects = windows
        ? const <double?>[]
        : [
            for (final item in _items)
              stremioPosterAspect(item, landscape: landscape),
          ];
    final heights = windows
        ? const <double>[]
        : [
            for (var i = 0; i < aspects.length; i++)
              aspects[i] == null
                  ? cellW / posterGridAspect(context)
                  : posterCellHeight(
                      cellW,
                      artAspectRatio: aspects[i],
                      textScaler: MediaQuery.textScalerOf(context),
                      titleInside: posterTitleInside(
                        context,
                        wide: aspects[i]! > 1,
                        item: _items[i],
                      ),
                    ),
          ];
    final gridHeight = heights.fold<double>(0, (a, b) => a > b ? a : b);

    final paginating = _paginating;
    // A trailing spinner cell spanning the full row while a page is loading.
    final showSpinner = paginating && _loading;
    // search-2 Option B (Windows): a 'Load more' fallback whenever the list
    // can still page, in case auto-fill / scrolling didn't trigger.
    final showLoadMore = windows && paginating && !_end && _items.isNotEmpty;
    final scaffold = Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: _searching
            ? SearchFieldEscape(
                // search-1 Option A: Esc clears, then closes the search.
                controller: _queryController,
                onClose: _toggleSearch,
                child: TextField(
                  key: const ValueKey('see-all-search-field'),
                  controller: _queryController,
                  focusNode: _fieldFocus,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  style: AppText.body.copyWith(color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    hintText: context.l10n.search2,
                    border: InputBorder.none,
                    isDense: true,
                  ),
                  onSubmitted: _runQuery,
                ),
              )
            : Text(widget.title, style: AppText.headline),
        actions: widget.onSearch == null
            ? null
            : [
                IconButton(
                  key: const ValueKey('see-all-search'),
                  tooltip: context.l10n.search2,
                  onPressed: _toggleSearch,
                  icon: Icon(
                    _searching ? Icons.close_rounded : Icons.search_rounded,
                  ),
                ),
                IconButton(
                  key: const ValueKey('see-all-filter'),
                  tooltip: context.l10n.filters,
                  onPressed: _openFilters,
                  icon: Icon(
                    Icons.filter_list_rounded,
                    color: _filters.isEmpty ? null : AppColors.accent,
                  ),
                ),
              ],
      ),
      body: windows && _queryFailed && _items.isEmpty && !_loading
          // search-8 Option B (Windows): the same EmptyState error panel the
          // source page uses, with Retry, instead of a misleading
          // "No results".
          ? EmptyState(
              key: const ValueKey('see-all-error'),
              icon: Icons.cloud_off_rounded,
              message: context.l10n.somethingWentWrong,
              actionLabel: context.l10n.retry,
              onAction: () => _runQuery(_lastQuery),
            )
          : widget.onSearch != null && _items.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_loading)
                    const CircularProgressIndicator()
                  else
                    Text(context.l10n.noResults),
                  if (_showNextPage && !_loading) ...[
                    const SizedBox(height: 12),
                    TextButton.icon(
                      key: const ValueKey('see-all-next-page'),
                      onPressed: _loadMore,
                      icon: const Icon(Icons.arrow_forward_rounded),
                      label: Text(context.l10n.next),
                    ),
                  ],
                ],
              ),
            )
          : GridView.builder(
              controller: paginating ? _controller : null,
              padding: const EdgeInsets.all(16),
              cacheExtent: 800,
              // Windows keeps the adaptive desktop delegate; elsewhere use
              // upstream's per-item artwork height.
              gridDelegate: windows
                  ? posterGridDelegate(context)
                  : SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: posterGridColumns(context),
                      childAspectRatio: gridHeight > 0
                          ? cellW / gridHeight
                          : posterGridAspect(context),
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 16,
                    ),
              itemCount: _items.length,
              itemBuilder: (context, i) => windows
                  ? _cell(
                      i,
                      cellW,
                      stremioPosterAspect(_items[i], landscape: landscape),
                      null,
                    )
                  : _cell(i, cellW, aspects[i], heights[i]),
            ),
      // Bottom loading indicator while the next page is in flight. Only rendered
      // in the paginating configuration, so non-paginating callers are unchanged.
      bottomNavigationBar: showSpinner && _items.isNotEmpty
          ? const SizedBox(
              height: 48,
              child: Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          : _showNextPage && _items.isNotEmpty
          ? SizedBox(
              height: 56,
              child: Center(
                child: TextButton.icon(
                  key: const ValueKey('see-all-next-page'),
                  onPressed: _loadMore,
                  icon: Icon(_pageFailed ? Icons.refresh_rounded : Icons.arrow_forward_rounded),
                  label: Text(_pageFailed ? context.l10n.retry : context.l10n.next),
                ),
              ),
            )
          : showLoadMore
          ? SizedBox(
              height: 56,
              child: Center(
                child: TextButton.icon(
                  key: const ValueKey('see-all-load-more'),
                  onPressed: _loadMore,
                  icon: Icon(
                    _pageFailed
                        ? Icons.refresh_rounded
                        : Icons.expand_more_rounded,
                  ),
                  label: Text(
                    _pageFailed
                        ? context.l10n.retry
                        : context.l10n.loadMore,
                  ),
                ),
              ),
            )
          : null,
    );
    // Windows: Ctrl+F opens this page's own search (shell-7) and Esc closes
    // it before going back (search-1). Pass-through elsewhere.
    return SearchPageKeys(
      onSearch: widget.onSearch == null ? null : _openSearch,
      onEscape: _escapeSearch,
      child: scaffold,
    );
  }
}
