import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/models/media_item.dart';
import '../../../core/playback/source_health_store.dart';
import '../../../core/repository/source_repository.dart';
import '../../../core/zmode/match_store.dart';
import '../../../core/zmode/source_matcher.dart';
import '../../../core/zmode/zmode_ids.dart';

/// Marks a [WrongTitleState.copyWith] argument that was not passed, so a
/// nullable field (like [WrongTitleState.failure]) can still be cleared.
const Object _keep = Object();

class WrongTitleState {
  const WrongTitleState({
    this.results = const [],
    this.loading = false,
    this.query = '',
    this.failure,
    this.hasMore = false,
    this.loadingMore = false,
    this.loadMoreFailed = false,
  });

  final List<MediaItem> results;
  final bool loading;

  /// What the running search is for. Shown while it runs, so a slow source
  /// says what it is doing instead of only spinning.
  final String query;

  /// Why the search came back with nothing, when the source FAILED rather
  /// than answered empty: [SourceOutcome.timeout], [SourceOutcome.blocked]
  /// (Cloudflare / WAF) or [SourceOutcome.error]. Null for a real empty
  /// result, so "this source does not carry it" is only said when true.
  /// Only the Windows (status-aware) search fills this in.
  final SourceOutcome? failure;

  /// True when the source may have another page of results (Windows
  /// "Load more"). Never set on phone, which keeps its single page.
  final bool hasMore;

  /// A next page is being fetched.
  final bool loadingMore;

  /// The last "Load more" failed; the button turns into a Retry.
  final bool loadMoreFailed;

  WrongTitleState copyWith({
    List<MediaItem>? results,
    bool? loading,
    String? query,
    Object? failure = _keep,
    bool? hasMore,
    bool? loadingMore,
    bool? loadMoreFailed,
  }) => WrongTitleState(
    results: results ?? this.results,
    loading: loading ?? this.loading,
    query: query ?? this.query,
    failure: identical(failure, _keep)
        ? this.failure
        : failure as SourceOutcome?,
    hasMore: hasMore ?? this.hasMore,
    loadingMore: loadingMore ?? this.loadingMore,
    loadMoreFailed: loadMoreFailed ?? this.loadMoreFailed,
  );
}

/// One fetched page and how the source answered it.
typedef _Fetched = ({List<MediaItem> items, SourceOutcome outcome});

/// Manual re-match against one source: search it and pin the right result.
/// The source can be changed from inside the sheet — a title missing from one
/// source is the most likely moment to want a different one, and backing out
/// to change it and coming back is the long way round.
class WrongTitleCubit extends Cubit<WrongTitleState> {
  WrongTitleCubit({
    required SourceRepository sources,
    required SourceMatcher matcher,
    required ZCanonical canonical,
    required String sourceId,
    bool? statusAware,
    this.searchTimeout = const Duration(seconds: 20),
  }) : _sources = sources,
       _matcher = matcher,
       _canonical = canonical,
       _sourceId = sourceId,
       // Windows uses the status-aware, paged search (ar-5 / ar-6); phone
       // and TV keep the plain search exactly as before. Target platform,
       // not host OS, so phone tests on a Windows host stay on phone.
       _statusAware =
           statusAware ?? defaultTargetPlatform == TargetPlatform.windows,
       super(const WrongTitleState());

  final SourceRepository _sources;
  final SourceMatcher _matcher;
  final ZCanonical _canonical;
  final bool _statusAware;

  /// How long one status-aware search may take before it is reported as a
  /// timeout instead of spinning forever.
  final Duration searchTimeout;

  /// The title being corrected — the sheet needs it to ask the store which
  /// result is already pinned, so that one can be marked rather than offered
  /// again as if it were a different show.
  ZCanonical get canonical => _canonical;

  /// The source this correction currently applies to.
  String _sourceId;
  String get sourceId => _sourceId;
  String? _metadataRetryQuery;
  List<String> _metadataRetryAliases = const [];
  int? _metadataRetryMalId;

  /// The last page loaded for the current query (status-aware search only).
  int _page = 1;

  /// Correct against a different source, re-running the same query against it.
  /// This only changes which source THIS correction searches — nothing is
  /// persisted until [choose] actually pins a result (see [pinManual]).
  /// Writing a kind-wide default just from browsing the dropdown was the bug
  /// this design fixes: every title started naming whichever source was last
  /// glanced at here.
  Future<void> setSource(String id) async {
    if (id == _sourceId) return;
    _sourceId = id;
    await retry();
  }

  /// Runs the current query again on the current source (the Retry button of
  /// a timeout / block / error), keeping the metadata-alias fallback when the
  /// query is still the title's own.
  Future<void> retry() => search(
    state.query,
    retryWithMetadataAliases: state.query == _metadataRetryQuery,
    metadataAliases: _metadataRetryAliases,
    malId: _metadataRetryMalId,
  );

  int _searchGeneration = 0;

  /// One page from the source. Phone: the plain search, which throws on a
  /// failure (handled by [search] exactly as before). Windows: the
  /// status-aware search with a time limit, which never throws.
  Future<_Fetched> _fetch(String query, int page) async {
    if (!_statusAware) {
      final items = await _sources.search(query, sourceId: _sourceId);
      return (items: items, outcome: SourceOutcome.ok);
    }
    try {
      return await _sources
          .searchStatus(query, sourceId: _sourceId, page: page)
          .timeout(searchTimeout);
    } on TimeoutException {
      return (items: const <MediaItem>[], outcome: SourceOutcome.timeout);
    } catch (e) {
      debugPrint('[zmode] manual search on $_sourceId failed: $e');
      return (items: const <MediaItem>[], outcome: SourceOutcome.error);
    }
  }

  /// True for outcomes where the source did not really answer.
  static bool _failed(SourceOutcome o) =>
      o == SourceOutcome.timeout ||
      o == SourceOutcome.blocked ||
      o == SourceOutcome.error;

  Future<void> search(
    String query, {
    bool retryWithMetadataAliases = false,
    List<String> metadataAliases = const [],
    int? malId,
  }) async {
    final q = query.trim();
    if (retryWithMetadataAliases) {
      _metadataRetryQuery = q;
      _metadataRetryAliases = metadataAliases;
      _metadataRetryMalId = malId;
    } else if (q != _metadataRetryQuery) {
      _metadataRetryQuery = null;
      _metadataRetryAliases = const [];
      _metadataRetryMalId = null;
    }
    final generation = ++_searchGeneration;
    _page = 1;
    // A new search forgets the last one's failure and paging.
    emit(
      state.copyWith(
        loading: true,
        query: q,
        failure: null,
        hasMore: false,
        loadingMore: false,
        loadMoreFailed: false,
      ),
    );
    try {
      final first = await _fetch(q, 1);
      if (!_isCurrentSearch(generation)) return;
      var results = _uniqueResults(first.items);
      final failed = _failed(first.outcome);
      emit(
        state.copyWith(
          results: results,
          failure: failed ? first.outcome : null,
          // Only a page that came back with results can have a next one.
          hasMore: _statusAware && !failed && first.items.isNotEmpty,
        ),
      );

      // A source that timed out or blocked will not answer the aliases
      // either; trying three more would only triple the wait.
      if (retryWithMetadataAliases &&
          !failed &&
          !_hasClearMatch(results, [q, ...metadataAliases], malId)) {
        for (final alias in _distinctAliases(q, metadataAliases).take(3)) {
          try {
            final aliasResults = await _fetch(alias, 1);
            if (!_isCurrentSearch(generation)) return;
            results = _uniqueResults([...results, ...aliasResults.items]);
            emit(state.copyWith(results: results));
            if (_hasClearMatch(results, [q, ...metadataAliases], malId)) break;
          } catch (e) {
            debugPrint('[zmode] manual alias search on $_sourceId failed: $e');
          }
        }
      }
    } catch (e) {
      debugPrint('[zmode] manual search on $_sourceId failed: $e');
      if (_isCurrentSearch(generation)) {
        emit(state.copyWith(results: const []));
      }
    } finally {
      if (_isCurrentSearch(generation)) {
        emit(state.copyWith(loading: false));
      }
    }
  }

  /// Fetches the next page of the current query and appends it (Windows
  /// "Load more", also run when the grid is scrolled to its end). Stops
  /// offering more once a page adds nothing new: some sources answer every
  /// page number with page 1 again.
  Future<void> loadMore() async {
    if (!_statusAware || !state.hasMore || state.loading || state.loadingMore) {
      return;
    }
    final generation = _searchGeneration;
    final next = _page + 1;
    emit(state.copyWith(loadingMore: true, loadMoreFailed: false));
    final page = await _fetch(state.query, next);
    // A new search (or source switch) started meanwhile: drop this page.
    if (!_isCurrentSearch(generation)) return;
    if (_failed(page.outcome)) {
      emit(state.copyWith(loadingMore: false, loadMoreFailed: true));
      return;
    }
    final merged = _uniqueResults([...state.results, ...page.items]);
    final grew = merged.length > state.results.length;
    _page = next;
    emit(state.copyWith(results: merged, loadingMore: false, hasMore: grew));
  }

  bool _isCurrentSearch(int generation) =>
      !isClosed && generation == _searchGeneration;

  static List<String> _distinctAliases(String query, List<String> aliases) {
    String key(String value) =>
        value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

    final seen = {key(query)};
    return [
      for (final alias in aliases)
        if (alias.trim().isNotEmpty && seen.add(key(alias))) alias.trim(),
    ];
  }

  bool _hasClearMatch(
    List<MediaItem> results,
    List<String> knownTitles,
    int? malId,
  ) {
    String key(String value) =>
        value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

    return results.any((result) {
      final resultTitles = [
        result.title,
        if (result.englishTitle != null) result.englishTitle!,
      ];
      return knownTitles.any(
        (title) =>
            titleIdentityMatches(result, title, wantedMalId: malId) ||
            resultTitles.any((resultTitle) => key(resultTitle) == key(title)),
      );
    });
  }

  static List<MediaItem> _uniqueResults(List<MediaItem> results) {
    final seen = <String>{};
    return [
      for (final result in results)
        if (seen.add(
          '${result.sourceId}\u0000${result.url.isEmpty ? result.id : result.url}',
        ))
          result,
    ];
  }

  Future<SourceMatch> choose(MediaItem item) =>
      _matcher.pinManual(_canonical, item);
}
