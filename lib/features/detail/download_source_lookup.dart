import '../../core/di/injector.dart';
import '../../core/download/download_source_search.dart';
import '../../core/models/episode.dart';
import '../../core/repository/catalogue_repository.dart';
import '../../core/repository/source_repository.dart';
import '../../core/zmode/match_store.dart';
import '../../core/zmode/metadata_repository.dart';
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
      return searchDownloadSources(
        candidates: [
          for (final c in candidates)
            DownloadSourceCandidate(
              id: c.id,
              name: c.name,
              budget: c.budget,
              serial: c.serial,
              skipReason: c.skipReason,
            ),
        ],
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
