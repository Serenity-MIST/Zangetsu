import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/models/home_section.dart';
import '../../../core/models/media_item.dart';
import '../../../core/repository/catalogue_repository.dart';
import '../../../core/error/exceptions.dart';
import '../../../core/provider/cf_solve_needed.dart';

class BrowseSourceState {
  const BrowseSourceState({
    this.sections = const [],
    this.loading = true,
    this.failed = false,
    this.searching = false,
    this.searchFailed = false,
    this.searchResults,
    this.filtersJson = '',
    this.query = '',
    this.page = 1,
    this.loadingMore = false,
    this.atEnd = false,
  });

  final List<HomeSection> sections;
  final bool loading;

  /// The source threw. Distinct from "returned nothing" — an empty catalogue
  /// is a legitimate answer and must not be dressed up as a failure.
  final bool failed;

  /// A search request is in flight.
  final bool searching;

  /// The search itself threw. Distinct from [searchResults] coming back
  /// empty, same reasoning as [failed] vs. an empty catalogue.
  final bool searchFailed;

  /// Non-null once a search has completed — the screen shows these instead
  /// of [sections] until the query is cleared. Null means "browsing", not
  /// "searched and found nothing" (that's an empty, non-null list).
  final List<MediaItem>? searchResults;

  /// The source's own filter selection currently applied, as selection JSON.
  /// Empty means unfiltered. Kept so the sheet reopens on the last choice and
  /// the app bar can show the filter as active.
  final String filtersJson;

  /// The query behind [searchResults], kept so the next page can ask for the
  /// same thing.
  final String query;

  /// Last page fetched. The first request is page 1.
  final int page;
  final bool loadingMore;

  /// No more pages: an empty page, or one whose items we already had. Sources
  /// rarely report a total, so the end is something you discover.
  final bool atEnd;

  /// Whether the screen should be showing search results/spinner/failure
  /// instead of the catalogue rows.
  bool get isSearchActive => searching || searchFailed || searchResults != null;
}

/// One source's own catalogue. Deliberately holds a [CatalogueRepository] and
/// is constructed with `SourceRepository`, never the Z Mode router: this screen
/// browses a real source by definition.
class BrowseSourceCubit extends Cubit<BrowseSourceState> {
  BrowseSourceCubit({
    required CatalogueRepository repo,
    required this.sourceId,
    this.sourceAvailable,
    Stream<void>? inventoryChanges,
    this.timeout = const Duration(seconds: 40),
  }) : _repo = repo,
       super(const BrowseSourceState()) {
    _inventorySubscription = inventoryChanges?.listen((_) => _invalidateSource());
  }
  StreamSubscription<void>? _inventorySubscription;

  /// Same-ID reinstalls retire the previous plugin's pending work too.
  void _invalidateSource() {
    if (isClosed) return;
    _requestVersion++;
    _homeVersion++;
    _catalogue = const BrowseSourceState(loading: false, failed: true);
    emit(_catalogue);
  }

  @override
  Future<void> close() async {
    await _inventorySubscription?.cancel();
    await super.close();
  }

  final CatalogueRepository _repo;
  final String sourceId;
  final bool Function()? sourceAvailable;

  /// Retire cached/in-flight content when its provider has been removed.
  /// The optional seam keeps non-source catalogue fixtures independent.
  bool checkSourceAvailability() {
    if (isClosed) return false;
    if (sourceAvailable?.call() ?? true) return true;
    _invalidateSource();
    return false;
  }

  /// Every new catalogue intent retires earlier asynchronous completions.
  int _requestVersion = 0;
  int _homeVersion = 0;
  // Base rows have their own lifetime: searching must not discard a pending
  // catalogue that Clear will need, nor may its completion replace a search.
  BrowseSourceState _catalogue = const BrowseSourceState();
  bool _current(int version) => !isClosed && version == _requestVersion && checkSourceAvailability();

  /// Capture the provider/request generation before an asynchronous title tap.
  /// Availability alone cannot distinguish a removed and reinstalled plugin.
  bool Function() retainSourceIntent() {
    final version = _requestVersion;
    return () => _current(version);
  }

  /// How long a source gets before the screen gives up on it.
  ///
  /// A source that never answers used to leave the spinner turning forever
  /// with nothing to act on — no error, no retry, no way to tell a slow site
  /// from a dead one. Generous on purpose: a first visit to a Cloudflare host
  /// pays for the challenge solve before the real request even starts.
  final Duration timeout;

  /// Native extensions throw a typed challenge instead of setting the JS
  /// host flag. Preserve its exact URL so Browse offers verification too.
  void _recordChallenge(Object error) {
    if (error is CloudflareRequiredException) {
      final host = Uri.tryParse(error.url)?.host;
      if (host != null && host.isNotEmpty) {
        CfSolveNeeded.needsSolve(host, error.url, sourceId: sourceId);
      }
    }
  }

  Future<void> load() async {
    if (!checkSourceAvailability()) return;
    ++_requestVersion;
    final version = ++_homeVersion;
    _catalogue = const BrowseSourceState();
    emit(_catalogue);
    try {
      final sections = await _repo.home(sourceId: sourceId).timeout(timeout);
      if (isClosed || version != _homeVersion || !checkSourceAvailability()) return;
      _catalogue = BrowseSourceState(sections: sections, loading: false);
      if (!state.isSearchActive) emit(_catalogue);
    } catch (error) {
      if (isClosed || version != _homeVersion || !checkSourceAvailability()) return;
      _catalogue = const BrowseSourceState(loading: false, failed: true);
      // This base request is still current even if Search owns the visible
      // results. Recording a target never opens a solver; Clear can offer it.
      _recordChallenge(error);
      if (!state.isSearchActive) {
        emit(_catalogue);
      }
    }
  }

  /// Runs a search scoped to [sourceId]. An empty/blank [query] just clears
  /// back to the catalogue, same as [clearSearch].
  Future<void> search(String query) async {
    if (!checkSourceAvailability()) return;
    final q = query.trim();
    if (q.isEmpty) {
      clearSearch();
      return;
    }
    final version = ++_requestVersion;
    emit(
      BrowseSourceState(
        sections: _catalogue.sections,
        loading: false,
        searching: true,
        query: q,
      ),
    );
    try {
      final results = await _repo
          .search(q, sourceId: sourceId)
          .timeout(timeout);
      if (!_current(version)) return;
      emit(
        BrowseSourceState(
          sections: _catalogue.sections,
          loading: false,
          searchResults: results,
          query: q,
        ),
      );
    } catch (error) {
      if (!_current(version)) return;
      _recordChallenge(error);
      emit(
        BrowseSourceState(
          sections: _catalogue.sections,
          loading: false,
          searchFailed: true,
          query: q,
        ),
      );
    }
  }

  /// Applies the source's own filters (genre, sort, status) with no query.
  ///
  /// [home] takes no filters, so a filtered browse has to go through search.
  /// That isn't a workaround: the extensions treat no-query-plus-filters as an
  /// ordinary search and implement it that way, so we ask for the same thing.
  Future<void> applyFilters(String filtersJson) async {
    if (!checkSourceAvailability()) return;
    if (filtersJson.isEmpty) {
      clearSearch();
      return;
    }
    final version = ++_requestVersion;
    emit(
      BrowseSourceState(
        sections: _catalogue.sections,
        loading: false,
        searching: true,
        filtersJson: filtersJson,
      ),
    );
    try {
      final res = await _repo.searchStatus(
        '',
        sourceId: sourceId,
        filtersJson: filtersJson,
      ).timeout(timeout);
      if (!_current(version)) return;
      emit(
        BrowseSourceState(
          sections: _catalogue.sections,
          loading: false,
          searchResults: res.items,
          filtersJson: filtersJson,
        ),
      );
    } catch (error) {
      if (!_current(version)) return;
      _recordChallenge(error);
      emit(
        BrowseSourceState(
          sections: _catalogue.sections,
          loading: false,
          searchFailed: true,
          filtersJson: filtersJson,
        ),
      );
    }
  }

  /// Appends the next page of whatever is on screen — a filtered browse or a
  /// text search, both of which the source pages the same way.
  ///
  /// Stops on an empty page OR one that adds nothing new: sources rarely say
  /// how many pages exist, and several answer an out-of-range page with the
  /// first one again, which would otherwise scroll forever.
  Future<void> loadMore() async {
    if (!checkSourceAvailability() || state.loadingMore || state.searching ||
        state.atEnd || state.searchResults == null) return;
    final version = _requestVersion;
    final current = state.searchResults ?? const [];
    emit(_copy(loadingMore: true));
    try {
      final res = await _repo.searchStatus(
        state.query,
        sourceId: sourceId,
        filtersJson: state.filtersJson.isEmpty ? null : state.filtersJson,
        page: state.page + 1,
      ).timeout(timeout);
      if (!_current(version)) return;
      final seen = {for (final i in current) i.url};
      final fresh = [
        for (final i in res.items)
          if (seen.add(i.url)) i,
      ];
      emit(
        _copy(
          searchResults: [...current, ...fresh],
          page: state.page + 1,
          loadingMore: false,
          atEnd: fresh.isEmpty,
        ),
      );
    } catch (_) {
      if (!_current(version)) return;
      // A failed page is not the end — the next scroll may work.
      emit(_copy(loadingMore: false));
    }
  }

  BrowseSourceState _copy({
    List<MediaItem>? searchResults,
    int? page,
    bool? loadingMore,
    bool? atEnd,
  }) => BrowseSourceState(
    sections: _catalogue.sections,
    loading: false,
    searchResults: searchResults ?? state.searchResults,
    filtersJson: state.filtersJson,
    query: state.query,
    page: page ?? state.page,
    loadingMore: loadingMore ?? state.loadingMore,
    atEnd: atEnd ?? state.atEnd,
  );

  /// Drops the search results and returns to the already-loaded catalogue
  /// rows — never re-fetches [home].
  void clearSearch() {
    if (isClosed) return;
    _requestVersion++;
    emit(_catalogue);
  }
}
