import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/download/download_record.dart';
import '../../core/models/episode.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../l10n/l10n.dart';

/// Finished downloads that belong to one show, oldest episode first.
///
/// Used when the detail page has no episode list (offline, or the source
/// returned nothing) so the shows you saved are still playable from here. A
/// record matches by the show page it was saved from, or by any shared id
/// (MAL, AniList, TMDB), or finally by its exact title. Only one copy per
/// episode is kept (the newest), so sub/dub or re-downloads do not repeat.
List<DownloadRecord> downloadsForShow(
  Iterable<DownloadRecord> records, {
  required String showUrl,
  int? malId,
  int? anilistId,
  int? tmdbId,
  String? title,
}) {
  final wanted = title?.trim().toLowerCase();
  bool belongs(DownloadRecord r) =>
      (showUrl.isNotEmpty && r.showUrl == showUrl) ||
      (malId != null && r.malId == malId) ||
      (anilistId != null && r.anilistId == anilistId) ||
      (tmdbId != null && r.tmdbId == tmdbId) ||
      (wanted != null &&
          wanted.isNotEmpty &&
          r.showTitle.trim().toLowerCase() == wanted);
  return savedDownloadEpisodes(records.where(belongs));
}

/// The finished, on-disk episodes among [records] (all of one show), one per
/// episode (the newest copy wins), in season/episode order. The downloaded
/// show page (opened from Downloads) lists exactly these.
List<DownloadRecord> savedDownloadEpisodes(Iterable<DownloadRecord> records) {
  final byEpisode = <String, DownloadRecord>{};
  for (final r in records) {
    if (r.status != DownloadStatus.done || r.filePath == null) continue;
    final key = '${r.season ?? 0}:${r.episodeNumber ?? r.episodeId}';
    final seen = byEpisode[key];
    if (seen == null || r.createdAt > seen.createdAt) byEpisode[key] = r;
  }
  return byEpisode.values.toList()
    ..sort((a, b) {
      final s = (a.season ?? 0).compareTo(b.season ?? 0);
      if (s != 0) return s;
      return (a.episodeNumber ?? 0).compareTo(b.episodeNumber ?? 0);
    });
}

/// Where Play should start in [saved]: the episode you were last on, or the
/// next one when you finished it (staying on it if it is the last), else the
/// first saved episode.
int downloadStartIndex(
  List<DownloadRecord> saved, {
  double? lastEpisode,
  bool lastFinished = false,
}) {
  if (saved.isEmpty || lastEpisode == null) return 0;
  final i = saved.indexWhere((r) => r.episodeNumber == lastEpisode);
  if (i < 0) return 0;
  return lastFinished && i + 1 < saved.length ? i + 1 : i;
}

/// The play queue for [records], in the same order, so Next episode works.
List<Episode> episodesFromDownloads(List<DownloadRecord> records) => [
  for (final r in records)
    Episode(
      id: r.episodeId,
      title: r.episodeTitle,
      number: r.episodeNumber,
      url: r.episodeUrl,
      thumbnail: r.episodeThumbnail,
      season: r.season,
    ),
];

/// Windows downloaded show page: the saved-file rows ([saved], built by
/// [episodesFromDownloads]) dressed with the show's saved metadata ([meta],
/// the full episode list stored with the download), so each row shows the
/// same description, air date, rating, runtime, real title and thumbnail as
/// on the online page.
///
/// An episode is matched by id (same season first), else by season +
/// number. The row keeps its own id, url, number and season, so download
/// lookups, resume marks and playback keep working. The thumbnail prefers a
/// local `file:` image from [meta], then the record's own, then [meta]'s.
List<Episode> mergeSavedEpisodeMeta(List<Episode> saved, List<Episode> meta) {
  if (saved.isEmpty || meta.isEmpty) return saved;
  final bySeasonId = <String, Episode>{};
  final byId = <String, Episode>{};
  final byNumber = <String, Episode>{};
  for (final m in meta) {
    bySeasonId.putIfAbsent('${m.season ?? 0}:${m.id}', () => m);
    byId.putIfAbsent(m.id, () => m);
    if (m.number != null) {
      byNumber.putIfAbsent('${m.season ?? 0}:${m.number}', () => m);
    }
  }
  bool has(String? v) => v != null && v.trim().isNotEmpty;
  return [
    for (final s in saved)
      if ((bySeasonId['${s.season ?? 0}:${s.id}'] ??
              byId[s.id] ??
              (s.number == null
                  ? null
                  : byNumber['${s.season ?? 0}:${s.number}']))
          case final m?)
        Episode(
          id: s.id,
          title: s.title,
          number: s.number,
          url: s.url,
          season: s.season ?? m.season,
          filler: m.filler,
          date: has(m.date) ? m.date : s.date,
          thumbnail: (has(m.thumbnail) && m.thumbnail!.startsWith('file:'))
              ? m.thumbnail
              : (has(s.thumbnail) ? s.thumbnail : m.thumbnail),
          description: has(m.description) ? m.description : s.description,
          metaTitle: has(m.metaTitle) ? m.metaTitle : s.metaTitle,
          rating: m.rating ?? s.rating,
          runtimeMinutes: m.runtimeMinutes ?? s.runtimeMinutes,
        )
      else
        s,
  ];
}

/// The cut (sub/dub) most of [records] were saved in, or null when there are
/// none. The downloaded show page opens in it so each row's download tick
/// finds its file.
String? mainDownloadCategory(Iterable<DownloadRecord> records) {
  final counts = <String, int>{};
  for (final r in records) {
    counts[r.category] = (counts[r.category] ?? 0) + 1;
  }
  if (counts.isEmpty) return null;
  return counts.entries.reduce((a, b) => b.value > a.value ? b : a).key;
}

/// Windows: the saved episodes of this show, shown in place of "No episodes
/// available" so a downloaded show is never a dead end offline.
class DesktopDownloadedEpisodes extends StatelessWidget {
  const DesktopDownloadedEpisodes({
    super.key,
    required this.records,
    required this.onPlay,
  });

  final List<DownloadRecord> records;
  final ValueChanged<int> onPlay;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      key: const ValueKey('detail-downloaded-episodes'),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      itemCount: records.length + 1,
      separatorBuilder: (_, i) => SizedBox(height: i == 0 ? 12 : 8),
      itemBuilder: (context, i) {
        if (i == 0) {
          return Row(children: [
            SvgPicture.asset('assets/icons/lucide/download.svg',
                width: 16,
                colorFilter: const ColorFilter.mode(
                    AppColors.textSecondary, BlendMode.srcIn)),
            const SizedBox(width: 8),
            Text(context.l10n.downloadedEpisodesCount(records.length),
                style: AppText.caption
                    .copyWith(color: AppColors.textSecondary)),
          ]);
        }
        final r = records[i - 1];
        final n = r.episodeNumber;
        final label = n == null
            ? r.episodeTitle
            : 'Episode ${n == n.truncateToDouble() ? n.toInt() : n}';
        final sub = r.episodeTitle.isNotEmpty && r.episodeTitle != label
            ? r.episodeTitle
            : null;
        return Material(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => onPlay(i - 1),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(children: [
                SvgPicture.asset('assets/icons/lucide/play.svg',
                    width: 18,
                    colorFilter: const ColorFilter.mode(
                        AppColors.textPrimary, BlendMode.srcIn)),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: AppText.body),
                      if (sub != null)
                        Text(sub,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.caption
                                .copyWith(color: AppColors.textTertiary)),
                    ],
                  ),
                ),
                Text(r.category.toUpperCase(),
                    style: AppText.caption
                        .copyWith(color: AppColors.textTertiary)),
              ]),
            ),
          ),
        );
      },
    );
  }
}
