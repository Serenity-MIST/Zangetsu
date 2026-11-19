// Windows: the show details saved next to a download, so the downloaded show
// page (opened from Downloads) looks the same offline as the online page.
import 'dart:convert';

import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';

import '../hive/safe_box.dart';
import '../logging/app_logger.dart';
import '../models/episode.dart';
import '../models/media_detail.dart';
import '../models/media_item.dart';
import 'download_manager.dart';
import 'download_record.dart';
import 'downloaded_show_artwork.dart';

/// JSON cache of a show's metadata, one entry per downloaded show, keyed by
/// the same source id + show id the download records use.
///
/// Everything the online page's left panel, Episodes rows and Details tab
/// show is kept: title, art, synopsis, genres, status, year, studios,
/// starring, score, popularity, favourites, tags (with spoiler flags), dates,
/// native title, synonyms, ids, and the WHOLE episode list with each
/// episode's description, air date, rating, runtime and thumbnail. Only the
/// cast cards and relations are dropped (those tabs are hidden offline).
///
/// The same data is mirrored as `<show folder>/.zangetsu/details.json` with the
/// cover, banner and episode thumbnails saved as local images beside it (see
/// [DownloadedShowArtwork]), so it survives a cleared Hive box or a moved
/// folder. The box opens lazily on first use, so nothing has to register it.
class DownloadedShowDetails {
  DownloadedShowDetails._();

  /// Hive box holding one JSON string per show.
  static const boxName = 'downloaded_show_details';

  /// Format of an entry written by [encode]. Entries without it are the
  /// older plain `MediaDetail` JSON (no episodes) and still read fine.
  static const formatVersion = 2;

  /// Writes and reads the per-folder copy and its images. Replaceable so
  /// tests can use a fake image fetcher.
  static DownloadedShowArtwork artwork = DownloadedShowArtwork();

  /// Entry key; the same pair that groups a show's downloads.
  static String keyFor(String sourceId, String showId) => '$sourceId::$showId';

  /// The box, opened on first use (self-healing via [openBoxSafely]).
  static Future<Box<String>> _box() async => Hive.isBoxOpen(boxName)
      ? Hive.box<String>(boxName)
      : await openBoxSafely<String>(boxName);

  /// Saves [detail] for the show stored under [sourceId] / [showId] and
  /// mirrors it (plus local images) into the show's download folders.
  ///
  /// [castNames] fill the Starring line when the detail itself has no cast
  /// (the online page shows the enriched cast). The new detail is MERGED
  /// over what was saved before, so a poorer detail (say, saved before the
  /// enrichment finished) never wipes richer fields. [records] are the
  /// downloads to mirror into; when null, the running download manager's
  /// records for this show are used. Never throws: a failed write only means
  /// the page falls back to the basics.
  static Future<void> save(
    MediaDetail detail, {
    required String sourceId,
    required String showId,
    List<String> castNames = const [],
    Iterable<DownloadRecord>? records,
  }) async {
    if (sourceId.isEmpty || showId.isEmpty || detail.title.trim().isEmpty) {
      return;
    }
    try {
      // Starring: the page's enriched cast when the provider gave none.
      final withCast = detail.cast.isEmpty && castNames.isNotEmpty
          ? detail.copyWith(cast: castNames)
          : detail;
      final box = await _box();
      final key = keyFor(sourceId, showId);
      final oldRaw = box.get(key);
      final merged = merge(_decodeRaw(oldRaw), _onlyRemote(withCast));
      final raw = jsonEncode(encode(merged));
      // Unchanged: skip the disk write (the backfill re-saves often).
      if (raw != oldRaw) await box.put(key, raw);
      final targets = (records ?? _managerRecords(sourceId, showId)).toList();
      if (targets.isNotEmpty) {
        await artwork.mirror(
          merged,
          sourceId: sourceId,
          showId: showId,
          records: targets,
        );
      }
    } catch (e) {
      AppLogger.instance.log(
        '[downloads] could not save show details: $e',
        level: 'W',
      );
    }
  }

  /// After a download finished: copies the details already saved for its
  /// show (if any) into its folder, with the images. Covers downloads queued
  /// from the player or in bulk, which never pass through [save]. Never
  /// throws.
  ///
  /// [canceled] reports that the caller (the download manager) shut down:
  /// nothing is opened after that, neither the Hive box nor folder files, so
  /// a late mirror cannot keep the download folder locked.
  static Future<void> mirrorSavedFor(
    DownloadRecord record,
    Iterable<DownloadRecord> all, {
    bool Function()? canceled,
  }) async {
    bool stop() => canceled?.call() ?? false;
    try {
      if (stop()) return;
      final saved = await read(record.sourceId, record.showId);
      if (saved == null || stop()) return;
      await artwork.mirror(
        saved,
        sourceId: record.sourceId,
        showId: record.showId,
        records: [
          for (final r in all)
            if (r.sourceId == record.sourceId && r.showId == record.showId) r,
        ],
        canceled: canceled,
      );
    } catch (e) {
      AppLogger.instance.log('[downloads] show details mirror failed: $e');
    }
  }

  /// The saved details for [sourceId] / [showId], or null when none were
  /// saved or the entry is bad. When the Hive entry is missing, the
  /// `details.json` in the folders of [records] is read instead.
  static Future<MediaDetail?> read(
    String sourceId,
    String showId, {
    Iterable<DownloadRecord> records = const [],
  }) async {
    try {
      final saved = _decodeRaw((await _box()).get(keyFor(sourceId, showId)));
      if (saved != null) return saved;
    } catch (_) {
      /* fall through to the folder copy */
    }
    if (records.isEmpty) return null;
    return artwork.readSaved(records, sourceId: sourceId, showId: showId);
  }

  /// Forgets the entry (e.g. when the last episode of a show is deleted).
  static Future<void> remove(String sourceId, String showId) async {
    try {
      await (await _box()).delete(keyFor(sourceId, showId));
    } catch (_) {
      /* nothing saved, nothing to do */
    }
  }

  // ── Codec ────────────────────────────────────────────────────────────────

  /// JSON of [detail] for storage. The episodes are written by
  /// [episodeToJson] because `Episode.toJson` leaves out the description,
  /// rating, runtime, season and real title the Episodes rows need.
  static Map<String, dynamic> encode(MediaDetail detail) => {
    'v': formatVersion,
    'detail': detail
        .copyWith(
          episodes: const [],
          castMembers: const [],
          relations: const [],
        )
        .toJson(),
    'episodes': [for (final e in detail.episodes) episodeToJson(e)],
  };

  /// Reads what [encode] wrote, or an older plain `MediaDetail` JSON. Null
  /// when [json] is not a usable entry.
  static MediaDetail? decode(Object? json) {
    try {
      if (json is! Map) return null;
      final map = json.cast<String, dynamic>();
      final inner = map['detail'];
      if (map['v'] is int && inner is Map) {
        final detail = MediaDetail.fromJson(inner.cast<String, dynamic>());
        final rawEpisodes = map['episodes'];
        final episodes = <Episode>[
          if (rawEpisodes is List)
            for (final raw in rawEpisodes) ?episodeFromJson(raw),
        ];
        return detail.copyWith(episodes: episodes);
      }
      // Older entry: a plain MediaDetail JSON.
      return MediaDetail.fromJson(map);
    } catch (_) {
      return null;
    }
  }

  /// One episode with every field the Episodes row shows.
  static Map<String, dynamic> episodeToJson(Episode e) => {
    'id': e.id,
    'title': e.title,
    'number': e.number,
    'url': e.url,
    'date': e.date,
    'thumbnail': e.thumbnail,
    'filler': e.filler,
    'season': e.season,
    'description': e.description,
    'metaTitle': e.metaTitle,
    'rating': e.rating,
    'runtimeMinutes': e.runtimeMinutes,
  }..removeWhere((_, v) => v == null);

  /// The episode [episodeToJson] wrote, or null when [raw] is malformed.
  /// Every field is type-checked: the JSON may come from a folder on disk.
  static Episode? episodeFromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'], title = raw['title'], url = raw['url'];
    if (id is! String || title is! String || url is! String) return null;
    String? text(String k) => raw[k] is String ? raw[k] as String : null;
    final number = raw['number'], rating = raw['rating'];
    final season = raw['season'], runtime = raw['runtimeMinutes'];
    return Episode(
      id: id,
      title: title,
      url: url,
      number: number is num ? number.toDouble() : null,
      date: text('date'),
      thumbnail: text('thumbnail'),
      filler: raw['filler'] == true,
      season: season is int ? season : null,
      description: text('description'),
      metaTitle: text('metaTitle'),
      rating: rating is num ? rating.toDouble() : null,
      runtimeMinutes: runtime is int ? runtime : null,
    );
  }

  static MediaDetail? _decodeRaw(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return decode(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  // ── Merge ────────────────────────────────────────────────────────────────

  /// [fresh] over [old], keeping old values wherever [fresh] has nothing:
  /// a null number, an empty text or list, an unknown status. Episodes are
  /// [fresh]'s list (when it has one) with each episode's missing
  /// description / date / rating / runtime / title / thumbnail taken from
  /// the same episode in [old].
  static MediaDetail merge(MediaDetail? old, MediaDetail fresh) {
    if (old == null) return fresh;
    String? text(String? n, String? o) =>
        (n != null && n.trim().isNotEmpty) ? n : o;
    List<T> list<T>(List<T> n, List<T> o) => n.isNotEmpty ? n : o;
    return MediaDetail(
      id: fresh.id,
      title: fresh.title.trim().isEmpty ? old.title : fresh.title,
      englishTitle: text(fresh.englishTitle, old.englishTitle),
      cover: text(fresh.cover, old.cover),
      coverHeaders: fresh.coverHeaders ?? old.coverHeaders,
      banner: text(fresh.banner, old.banner),
      url: fresh.url,
      description: text(fresh.description, old.description),
      status: fresh.status == MediaStatus.unknown ? old.status : fresh.status,
      genres: list(fresh.genres, old.genres),
      studios: list(fresh.studios, old.studios),
      episodes: mergeEpisodes(old.episodes, fresh.episodes),
      cast: list(fresh.cast, old.cast),
      year: text(fresh.year, old.year),
      type: fresh.type,
      sourceId: fresh.sourceId,
      subCount: fresh.subCount ?? old.subCount,
      dubCount: fresh.dubCount ?? old.dubCount,
      malId: fresh.malId ?? old.malId,
      tmdbId: fresh.tmdbId ?? old.tmdbId,
      tmdbIsTv: fresh.tmdbId != null ? fresh.tmdbIsTv : old.tmdbIsTv,
      imdbId: text(fresh.imdbId, old.imdbId),
      score: fresh.score ?? old.score,
      format: text(fresh.format, old.format),
      durationMins: fresh.durationMins ?? old.durationMins,
      airingAt: fresh.airingAt ?? old.airingAt,
      nextEpisode: fresh.nextEpisode ?? old.nextEpisode,
      tags: list(fresh.tags, old.tags),
      startDate: fresh.startDate ?? old.startDate,
      endDate: fresh.endDate ?? old.endDate,
      sourceMaterial: text(fresh.sourceMaterial, old.sourceMaterial),
      country: text(fresh.country, old.country),
      popularity: fresh.popularity ?? old.popularity,
      favourites: fresh.favourites ?? old.favourites,
      nativeTitle: text(fresh.nativeTitle, old.nativeTitle),
      synonyms: list(fresh.synonyms, old.synonyms),
      isAdult: fresh.isAdult || old.isAdult,
    );
  }

  /// [fresh] episodes with blanks filled from the same episode (season + id,
  /// else id) in [old]; [old] when [fresh] is empty.
  static List<Episode> mergeEpisodes(List<Episode> old, List<Episode> fresh) {
    if (fresh.isEmpty) return old;
    if (old.isEmpty) return fresh;
    final bySeasonId = {for (final e in old) '${e.season}:${e.id}': e};
    final byId = {for (final e in old) e.id: e};
    String? text(String? n, String? o) =>
        (n != null && n.trim().isNotEmpty) ? n : o;
    return [
      for (final e in fresh)
        if ((bySeasonId['${e.season}:${e.id}'] ?? byId[e.id]) case final o?)
          e.copyWith(
            description: text(e.description, o.description),
            metaTitle: text(e.metaTitle, o.metaTitle),
            thumbnail: text(e.thumbnail, o.thumbnail),
            date: text(e.date, o.date),
            rating: e.rating ?? o.rating,
            runtimeMinutes: e.runtimeMinutes ?? o.runtimeMinutes,
            season: e.season ?? o.season,
          )
        else
          e,
    ];
  }

  /// [detail] without local `file:` images: only remote URLs are stored, the
  /// local copies are mapped in again on load ([DownloadedShowArtwork]).
  static MediaDetail _onlyRemote(MediaDetail detail) {
    bool local(String? v) => v != null && v.startsWith('file:');
    final episodes = detail.episodes.any((e) => local(e.thumbnail))
        ? [
            for (final e in detail.episodes)
              local(e.thumbnail) ? _withoutThumbnail(e) : e,
          ]
        : detail.episodes;
    return MediaDetail(
      id: detail.id,
      title: detail.title,
      englishTitle: detail.englishTitle,
      cover: local(detail.cover) ? null : detail.cover,
      coverHeaders: detail.coverHeaders,
      banner: local(detail.banner) ? null : detail.banner,
      url: detail.url,
      description: detail.description,
      status: detail.status,
      genres: detail.genres,
      studios: detail.studios,
      episodes: episodes,
      cast: detail.cast,
      year: detail.year,
      type: detail.type,
      sourceId: detail.sourceId,
      subCount: detail.subCount,
      dubCount: detail.dubCount,
      malId: detail.malId,
      tmdbId: detail.tmdbId,
      tmdbIsTv: detail.tmdbIsTv,
      imdbId: detail.imdbId,
      score: detail.score,
      format: detail.format,
      durationMins: detail.durationMins,
      airingAt: detail.airingAt,
      nextEpisode: detail.nextEpisode,
      tags: detail.tags,
      startDate: detail.startDate,
      endDate: detail.endDate,
      sourceMaterial: detail.sourceMaterial,
      country: detail.country,
      popularity: detail.popularity,
      favourites: detail.favourites,
      nativeTitle: detail.nativeTitle,
      synonyms: detail.synonyms,
      isAdult: detail.isAdult,
    );
  }

  /// [e] with its thumbnail cleared (copyWith cannot set a field to null).
  static Episode _withoutThumbnail(Episode e) => Episode(
    id: e.id,
    title: e.title,
    number: e.number,
    url: e.url,
    date: e.date,
    filler: e.filler,
    season: e.season,
    scanlator: e.scanlator,
    description: e.description,
    metaTitle: e.metaTitle,
    rating: e.rating,
    runtimeMinutes: e.runtimeMinutes,
  );

  /// This show's records in the running download manager (none in tests or
  /// before the manager exists).
  static Iterable<DownloadRecord> _managerRecords(
    String sourceId,
    String showId,
  ) {
    try {
      if (!GetIt.I.isRegistered<DownloadManager>()) return const [];
      return GetIt.I<DownloadManager>().all.where(
        (r) => r.sourceId == sourceId && r.showId == showId,
      );
    } catch (_) {
      return const [];
    }
  }
}

/// The detail a downloaded show page shows: the saved details when there
/// are some (Hive, else the folder's `details.json`), else what the download
/// records and the opening [item] know (title, cover, ids). Identity fields
/// always come from [item], so resume marks and download lookups use the
/// same keys as the records. The saved episode list is kept (the page merges
/// its descriptions, dates and thumbnails into the saved-file rows), and
/// images saved next to the downloads replace the remote URLs.
Future<MediaDetail> loadDownloadedShowDetail(
  MediaItem item, {
  Iterable<DownloadRecord> records = const [],
}) async {
  final cached = await DownloadedShowDetails.read(
    item.sourceId,
    item.id,
    records: records,
  );
  final first = records.isEmpty ? null : records.first;
  final base =
      cached ??
      MediaDetail(
        id: item.id,
        title: item.title,
        englishTitle: item.englishTitle,
        cover: item.cover ?? first?.cover,
        coverHeaders: item.coverHeaders ?? first?.coverHeaders,
        banner: item.banner,
        url: item.url,
        type: item.type,
        sourceId: item.sourceId,
        genres: item.genres,
        status: item.status ?? MediaStatus.unknown,
        malId: item.malId ?? first?.malId,
        tmdbId: item.tmdbId ?? first?.tmdbId,
        tmdbIsTv: item.tmdbIsTv || (first?.tmdbIsTv ?? false),
        imdbId: item.imdbId ?? first?.imdbId,
      );
  final cover = (base.cover ?? '').trim().isEmpty ? item.cover : base.cover;
  final detail = base.copyWith(
    id: item.id,
    url: item.url,
    sourceId: item.sourceId,
    title: base.title.trim().isEmpty ? item.title : base.title,
    cover: cover,
    coverHeaders: base.coverHeaders ?? item.coverHeaders,
  );
  if (records.isEmpty) return detail;
  // Images saved beside the downloads, so the page needs no network.
  return DownloadedShowDetails.artwork.localize(
    detail,
    records,
    sourceId: item.sourceId,
    showId: item.id,
  );
}
