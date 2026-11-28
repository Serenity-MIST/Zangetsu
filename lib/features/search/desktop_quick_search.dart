import 'dart:async';

import '../../core/di/injector.dart';
import '../../core/mode/content_mode_cubit.dart';
import '../../core/models/media_item.dart';
import '../../core/playback/search_history.dart';
import '../../core/playback/source_health_store.dart' show SourceOutcome;
import '../../core/repository/source_repository.dart';
import '../../core/state/active_source_cubit.dart';
import '../../core/zmode/metadata_repository.dart';
import '../../core/zmode/zmode_prefs.dart';
import '../home/home_catalogue_prefs.dart';
import 'bloc/search_bloc.dart';
import 'bloc/search_event.dart';
import 'bloc/search_state.dart';
import 'installed_sources_search_section.dart';

/// Looks up titles for the Windows top-bar quick search dropdown.
///
/// Returns the matches for [query] (in relevance order, untrimmed) or throws
/// when the lookup failed. Injectable so tests can answer without a network.
typedef QuickSearchFn = Future<List<MediaItem>> Function(String query);

/// Streams the installed-sources fan-out behind the dropdown: one
/// [QuickSearchResult] per change (first results as they arrive, at most
/// [limit] titles), ending once every source answered or [limit] titles are
/// in. Cancelling the subscription stops the fan-out. Injectable for tests.
typedef QuickSourcesSearchFn =
    Stream<QuickSearchResult> Function(String query, int limit);

/// What one quick lookup produced.
class QuickSearchResult {
  const QuickSearchResult(
    this.items, {
    this.failed = false,
    this.sourceNames = const [],
    this.searching = false,
    this.pendingSources = 0,
    this.noSources = false,
  });

  /// The top matches, already capped to [DesktopQuickSearch.limit].
  final List<MediaItem> items;

  /// True when the lookup failed (network, provider error, no source).
  final bool failed;

  /// For an installed-sources lookup: the name of the source that found each
  /// of [items] (same order). Empty for a catalogue lookup.
  final List<String> sourceNames;

  /// True while more sources may still add titles (a partial answer).
  final bool searching;

  /// Sources still answering (0 once known or when not a sources lookup).
  final int pendingSources;

  /// True when no installed source of the mode is on for search.
  final bool noSources;

  /// The source name for row [i], or null (catalogue lookups).
  String? sourceNameAt(int i) => i < sourceNames.length ? sourceNames[i] : null;
}

/// Runs the small, fast lookup behind the Windows top-bar search dropdown.
///
/// It searches the same place the full results page would search, so the
/// dropdown and the page agree (see [defaultQuickSearch]). Every [run] gets a
/// serial number; a response that arrives after a newer [run] (or after
/// [cancel]) is dropped and reported as null, so a slow early answer can
/// never replace the matches for what is typed now.
///
/// When the current catalogue has no tracker behind it (novel "Browse", or
/// an installed source catalogue: [quickSearchUsesInstalledSources]), [watch]
/// searches the installed sources instead and streams partial answers.
class DesktopQuickSearch {
  DesktopQuickSearch({
    QuickSearchFn? search,
    QuickSourcesSearchFn? sourcesSearch,
    bool Function()? useSources,
    this.limit = 4,
  }) : _search = search ?? defaultQuickSearch,
       _sourcesSearch = sourcesSearch ?? defaultQuickSourcesSearch,
       _useSources = useSources ?? quickSearchUsesInstalledSources;

  final QuickSearchFn _search;

  /// The installed-sources fan-out used by [watch].
  final QuickSourcesSearchFn _sourcesSearch;

  /// Decides, per lookup, whether [watch] asks the installed sources.
  final bool Function() _useSources;

  /// How many matches the dropdown shows (the mockup shows four).
  final int limit;

  /// Bumped by every [run] and [cancel]; answers for older serials are stale.
  int _serial = 0;

  /// Looks up [query]. Resolves to null when the answer went stale.
  Future<QuickSearchResult?> run(String query) async {
    final serial = ++_serial;
    try {
      final items = await _search(query);
      if (serial != _serial) return null;
      return QuickSearchResult(items.take(limit).toList(growable: false));
    } catch (_) {
      if (serial != _serial) return null;
      return const QuickSearchResult([], failed: true);
    }
  }

  /// Looks up [query] as a stream: a catalogue lookup yields once; an
  /// installed-sources lookup yields every partial answer (with
  /// [QuickSearchResult.searching] true) and then a final one. The caller
  /// cancels its subscription to drop a stale lookup, which also stops the
  /// source fan-out.
  Stream<QuickSearchResult> watch(String query) async* {
    bool sources;
    try {
      sources = _useSources();
    } catch (_) {
      // Prefs or services not ready: the catalogue lookup, as before.
      sources = false;
    }
    if (sources) {
      yield* _sourcesSearch(query, limit).map(_capped);
      return;
    }
    try {
      final items = await _search(query);
      yield QuickSearchResult(items.take(limit).toList(growable: false));
    } catch (_) {
      yield const QuickSearchResult([], failed: true);
    }
  }

  /// Caps a sources answer at [limit] titles (defensive: the fan-out
  /// already stops there).
  QuickSearchResult _capped(QuickSearchResult r) => r.items.length <= limit
      ? r
      : QuickSearchResult(
          r.items.take(limit).toList(growable: false),
          failed: r.failed,
          sourceNames: r.sourceNames.take(limit).toList(growable: false),
          searching: r.searching,
          pendingSources: r.pendingSources,
          noSources: r.noSources,
        );

  /// Drops whatever lookup is still in flight (the panel closed).
  void cancel() => _serial++;
}

/// True when the Windows quick search should ask the installed sources
/// rather than the metadata catalogue: Z Mode's catalogue search is on and
/// Home's catalogue for the current mode has no tracker behind it (novel
/// "Browse", or an installed source catalogue in any mode). Tracker
/// catalogues (AniList / MAL / TMDB / Simkl) and the Z Mode off one-source
/// lookup keep their behaviour.
bool quickSearchUsesInstalledSources() {
  if (!_libraryScope()) return false;
  if (!sl.isRegistered<ContentModeCubit>()) return false;
  return desktopCatalogueHasNoTracker(sl<ContentModeCubit>().state);
}

/// The real installed-sources fan-out for the current content mode: the
/// same [SearchBloc] setup as the results page's installed-sources section
/// (mode's sources only, search-disabled sources skipped, dead ones skipped,
/// [InstalledSourcesSearchSection.maxConcurrentSources] at once, no
/// history). Without the services (tests, early boot) it finds nothing.
Stream<QuickSearchResult> defaultQuickSourcesSearch(String query, int limit) {
  if (!sl.isRegistered<SourceRepository>() ||
      !sl.isRegistered<ContentModeCubit>() ||
      !sl.isRegistered<SearchHistory>()) {
    return Stream.value(const QuickSearchResult([], noSources: true));
  }
  final mode = sl<ContentModeCubit>().state;
  return quickSourcesSearch(
    query,
    limit: limit,
    createBloc: () => SearchBloc(
      repo: sl<SourceRepository>(),
      history: sl<SearchHistory>(),
      forceMode: mode,
      maxConcurrent: InstalledSourcesSearchSection.maxConcurrentSources,
      recordHistory: false,
      forceAllSources: true,
    ),
  );
}

/// Runs one installed-sources fan-out for [query] on a bloc from
/// [createBloc] and streams the top [limit] titles as sources answer.
///
/// The bloc is created when the stream is listened to and closed when the
/// stream ends or the listener cancels, so a stale lookup stops querying
/// sources. The stream ends early once [limit] titles are in: the dropdown
/// only shows that many, and "See all results" runs the full search.
Stream<QuickSearchResult> quickSourcesSearch(
  String query, {
  required int limit,
  required SearchBloc Function() createBloc,
}) {
  final q = query.trim();
  SearchBloc? bloc;
  StreamSubscription<SearchState>? sub;
  late final StreamController<QuickSearchResult> out;

  // Stops listening and closes the bloc (idempotent).
  Future<void> stop() async {
    final s = sub;
    final b = bloc;
    sub = null;
    bloc = null;
    await s?.cancel();
    await b?.close();
  }

  out = StreamController<QuickSearchResult>(
    onListen: () {
      final b = bloc = createBloc();
      sub = b.stream.listen((state) {
        // Ignore anything not for this run (the bloc only runs one query).
        if (state.query.trim() != q || state.status == SearchStatus.idle) {
          return;
        }
        final snap = InstalledSourcesSnapshot.of(state);
        final top = snap.entries.take(limit).toList(growable: false);
        final done = !snap.searching || top.length >= limit;
        // Every queried source failed and nothing came back: a failure, so
        // the panel says "did not load" rather than "no matches".
        final allFailed =
            top.isEmpty &&
            snap.failed.isNotEmpty &&
            snap.failed.length >= state.queriedSources.length;
        out.add(
          QuickSearchResult(
            [for (final e in top) e.item],
            sourceNames: [for (final e in top) e.sourceName],
            searching: !done,
            pendingSources: done ? 0 : snap.pending.length,
            failed: done && allFailed,
            noSources: snap.noSources,
          ),
        );
        if (done) {
          unawaited(stop());
          unawaited(out.close());
        }
      });
      b.add(SearchRunRequested(q));
    },
    onCancel: stop,
  );
  return out.stream;
}

/// The real lookup, mirroring the scope the Search page picks.
///
/// * Library scope (Z Mode on, the same rule as `SearchScreen._scope`): the
///   metadata catalogue, which already follows the current content mode and
///   stream kind.
/// * Sources scope: ONE source rather than a fan-out over every installed
///   source, so the dropdown stays quick. It is the Home Source Catalogue's
///   source when that is shown, else the active source (the same idea as the
///   shell's `dockSearchFixedSourceId`).
///
/// Every service lookup is guarded, so a test or an early boot without the
/// service simply finds nothing.
Future<List<MediaItem>> defaultQuickSearch(String query) async {
  if (_libraryScope()) {
    if (!sl.isRegistered<MetadataRepository>()) return const [];
    final result = await sl<MetadataRepository>().searchStatus(query);
    return _itemsOrThrow(result);
  }
  final sourceId = quickSearchSourceId();
  if (sourceId == null || sourceId.isEmpty) return const [];
  if (!sl.isRegistered<SourceRepository>()) return const [];
  final result = await sl<SourceRepository>().searchStatus(
    query,
    sourceId: sourceId,
  );
  return _itemsOrThrow(result);
}

/// True when search runs against the metadata catalogue (Z Mode on).
bool _libraryScope() {
  try {
    return ZModePrefs.enabled;
  } catch (_) {
    // Prefs not opened (tests): Z Mode's default is on.
    return true;
  }
}

/// The single source the sources-scope quick search asks, or null.
String? quickSearchSourceId() {
  try {
    if (HomeCataloguePrefs.catalogueShown &&
        sl.isRegistered<ContentModeCubit>()) {
      final id = HomeCataloguePrefs.sourceIdFor(sl<ContentModeCubit>().state);
      if (id != null && id.isNotEmpty) return id;
    }
  } catch (_) {
    // Home prefs not opened yet; fall back to the active source below.
  }
  if (!sl.isRegistered<ActiveSourceCubit>()) return null;
  return sl<ActiveSourceCubit>().state;
}

/// A failed lookup with nothing to show counts as an error for the panel;
/// partial answers (some items plus a warning outcome) are still shown.
List<MediaItem> _itemsOrThrow(
  ({List<MediaItem> items, SourceOutcome outcome}) result,
) {
  // ok / empty / slow all mean the source answered; the rest are failures.
  const failures = {
    SourceOutcome.timeout,
    SourceOutcome.blocked,
    SourceOutcome.error,
  };
  if (result.items.isEmpty && failures.contains(result.outcome)) {
    throw StateError('quick search failed: ${result.outcome.name}');
  }
  return result.items;
}
