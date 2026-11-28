import 'package:flutter/foundation.dart';

import '../../core/di/injector.dart';
import '../../core/download/download_source_search.dart';
import '../../core/logging/lifecycle_label.dart';
import '../../core/models/episode.dart';
import '../../core/repository/catalogue_repository.dart';
import '../../core/repository/source_repository.dart';
import '../../core/zmode/match_store.dart';
import '../../core/zmode/metadata_repository.dart';
import '../../core/zmode/playback_resolver.dart';
import '../../core/zmode/zmode_ids.dart';

/// [id] when it names a real source rather than the catalogue pseudo-source.
String? _realSource(String? id) =>
    id == null || id.isEmpty || id == ZmodeIds.sourceId ? null : id;

/// The source the show page shows as matched for a catalogue episode (pin,
/// then last played, then any saved match) — a catalogue detail's own
/// sourceId is the `zm` pseudo-source, so it cannot say this itself.
String? _matchedSource(String zmEpisodeUrl) {
  final p = ZmodeIds.parseEpisode(zmEpisodeUrl);
  if (p == null ||
      !sl.isRegistered<MatchStore>() ||
      !sl.isRegistered<SourceRepository>()) {
    return null;
  }
  return sl<MatchStore>()
      .bestFor(p.show, available: sl<SourceRepository>().hasSource)
      ?.sourceId;
}

/// The bounded, per-source link search the Windows download dialogs run for
/// [episode] in [category].
///
/// Catalogue (`zm`) episodes walk the same fallback chain playback uses —
/// [preferredSourceId] (the source the show page matched) first, then the
/// pin / last played / kind default / Source Priority order — so a preferred
/// source that hangs or has nothing no longer ends the download. Ordinary
/// source episodes have one source to ask; that ask is bounded too.
///
/// Each source's outcome goes to the log as it settles, with the window's
/// state at that moment, so a report of "no source" after minimizing can be
/// checked against what each source really did.
Stream<List<DownloadSourceStatus>> episodeDownloadSourceSearch({
  required Episode episode,
  required String category,
  required String sourceId,
  String? preferredSourceId,
}) {
  final repo = sl<CatalogueRepository>();
  final metadata = repo is MetadataRepository
      ? repo
      : ZmodeIds.isZ(episode.url) && sl.isRegistered<MetadataRepository>()
      ? sl<MetadataRepository>()
      : null;
  if (metadata != null && ZmodeIds.isZ(episode.url)) {
    final resolver = metadata.playbackResolver;
    final candidates = resolver.downloadCandidates(
      episode.url,
      preferred: _realSource(preferredSourceId) ?? _matchedSource(episode.url),
    );
    if (candidates.isNotEmpty) {
      // Windows: Aniyomi sources may wait their turn in the call gate (up to
      // two of their budgets), so the whole search gets longer than its
      // usual 90 s (see [PlaybackResolver.downloadAniyomiWallClock]).
      final gated = candidates.any(
        (c) =>
            c.skipReason == null &&
            PlaybackResolver.usesDownloadAniyomiBudget(c.id),
      );
      return searchDownloadSources(
        candidates: [
          for (final c in candidates)
            DownloadSourceCandidate(
              id: c.id,
              name: c.name,
              budget: c.budget,
              serial: c.serial,
              skipReason: c.skipReason,
              freeWorkerAfter: c.freeWorkerAfter,
              extendIf: c.extendIf,
            ),
        ],
        wallClock: gated
            ? PlaybackResolver.downloadAniyomiWallClock
            : const Duration(seconds: 90),
        onSettled: _logSettled,
        attempt: (id) async {
          final a = await resolver.attemptForDownload(
            episode.url,
            id,
            category: category,
          );
          return a == null
              ? null
              : DownloadSourceHit(
                  streams: a.streams,
                  episodeUrl: a.episodeUrl,
                  showUrl: a.showUrl,
                );
        },
      );
    }
  }
  final name = sourceId == ZmodeIds.sourceId
      ? 'Auto'
      : sl.isRegistered<SourceRepository>()
      ? sl<SourceRepository>().displayName(sourceId)
      : sourceId;
  return searchSingleDownloadSource(
    sourceId: sourceId,
    name: name,
    resolve: () => metadata != null
        ? metadata.sources(episode.url, sourceId: sourceId, category: category)
        : repo.sources(episode.url, sourceId: sourceId),
  );
}

/// One log line per source as the download search settles it.
void _logSettled(DownloadSourceStatus row, Duration elapsed) {
  final detail = row.detail == null ? '' : ' (${row.detail})';
  debugPrint(
    '[download-search] ${row.sourceId} ${row.phase.name} '
    '${elapsed.inMilliseconds}ms lifecycle=${lifecycleLabel()}$detail',
  );
}
