import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/download/download_manager.dart';
import '../../core/download/download_record.dart';
import '../../core/models/episode.dart';
import '../../l10n/app_localizations.dart';

/// Windows show page (B1): every finished download of this episode in ANY
/// cut (sub, dub or unknown), best first.
///
/// Why: on Windows a download record's id includes the cut, and the online
/// show page has no Sub/Dub switch. A show saved as Dub was therefore never
/// marked as downloaded on a page that looks it up as Sub. The download
/// manager stays cut-exact on purpose (its tests pin that); this fallback is
/// only for the show page's tick, right-click menu and Play.
///
/// Order:
///  1. Same source + show + episode id (the normal record of another cut).
///  2. Same show (show id, or MAL id when both have one) + same episode
///     number + a compatible season. This catches records found on disk,
///     whose episode id is a `file:` tag rather than the provider's id.
/// Within each step the [preferredCategory] comes first, then the newest.
///
/// Only finished records with a file path count. Whether the file is still
/// on disk is the caller's job (it needs async file access).
List<DownloadRecord> savedEpisodeAnyCutCandidates(
  Iterable<DownloadRecord> records, {
  required String sourceId,
  required String showId,
  required String episodeId,
  double? episodeNumber,
  int? season,
  int? malId,
  String? preferredCategory,
  // True only when looking for a broken copy to delete
  // ([firstBrokenSavedCopy]): keeps the stubs the normal lookup skips.
  bool keepStubs = false,
}) {
  final sameId = <DownloadRecord>[];
  final sameNumber = <DownloadRecord>[];
  for (final r in records) {
    if (r.status != DownloadStatus.done) continue;
    final path = r.filePath;
    if (path == null || path.isEmpty) continue;
    // A record whose saved size is far too small for a video episode is a
    // stub (the Frieren E9 case: 788 KB marked done), not a real copy.
    if (!keepStubs && !savedRecordSizeLooksReal(r)) continue;
    if (r.sourceId == sourceId &&
        r.showId == showId &&
        r.episodeId == episodeId) {
      sameId.add(r);
      continue;
    }
    final sameShow =
        r.showId == showId || (malId != null && r.malId == malId);
    // A season known on both sides must agree; an unknown one is allowed
    // (older records and single-season shows often have none).
    final seasonOk = season == null || r.season == null || r.season == season;
    if (sameShow &&
        seasonOk &&
        episodeNumber != null &&
        r.episodeNumber == episodeNumber) {
      sameNumber.add(r);
    }
  }
  // Preferred cut first, then the newest download.
  int best(DownloadRecord a, DownloadRecord b) {
    final pa = a.category == preferredCategory ? 0 : 1;
    final pb = b.category == preferredCategory ? 0 : 1;
    if (pa != pb) return pa.compareTo(pb);
    return b.createdAt.compareTo(a.createdAt);
  }

  sameId.sort(best);
  sameNumber.sort(best);
  return [...sameId, ...sameNumber];
}

/// The best entry of [savedEpisodeAnyCutCandidates], or null when nothing of
/// this episode is saved in any cut.
DownloadRecord? savedEpisodeAnyCut(
  Iterable<DownloadRecord> records, {
  required String sourceId,
  required String showId,
  required String episodeId,
  double? episodeNumber,
  int? season,
  int? malId,
  String? preferredCategory,
}) {
  final all = savedEpisodeAnyCutCandidates(
    records,
    sourceId: sourceId,
    showId: showId,
    episodeId: episodeId,
    episodeNumber: episodeNumber,
    season: season,
    malId: malId,
    preferredCategory: preferredCategory,
  );
  return all.isEmpty ? null : all.first;
}

/// Smallest file the Windows any-cut fallback (B1) accepts as a real saved
/// episode: 5 MB. Even a short, low-quality episode is far larger, while the
/// broken stub seen on a tester's PC (Frieren E9) was only 788 KB. Used only
/// by the fallback; the download manager and the folder scan keep their own
/// rules.
const int kMinSavedEpisodeBytes = 5 * 1024 * 1024;

/// Whether a file of [bytesOnDisk] looks like a whole saved episode for the
/// any-cut fallback: at least [kMinSavedEpisodeBytes], and, when the record
/// knows its size ([bytesTotal] > 0), at least half of it (half, because the
/// recorded size can be an estimate for streamed downloads).
bool savedEpisodeSizeLooksReal({
  required int bytesOnDisk,
  required int bytesTotal,
}) {
  if (bytesOnDisk < kMinSavedEpisodeBytes) return false;
  if (bytesTotal > 0 && bytesOnDisk * 2 < bytesTotal) return false;
  return true;
}

/// Quick check on the record alone (no disk access), for the episode tick:
/// a record that wrote down a size under [kMinSavedEpisodeBytes] is a stub.
/// An unknown size (0) passes here; Play and the menu still check the real
/// file with [savedEpisodeSizeLooksReal].
bool savedRecordSizeLooksReal(DownloadRecord r) =>
    r.bytesTotal <= 0 || r.bytesTotal >= kMinSavedEpisodeBytes;

/// The first of [candidates] whose file is still on disk AND looks like a
/// whole episode, or null (B1 Play and right-click menu).
///
/// [sizeOnDisk] gives the file's real size, or null when it cannot be read
/// that way (a content URI); an unknown size is accepted, as before. A stub
/// such as the 788 KB Frieren E9 file is skipped, so Play streams the
/// episode instead of opening a broken copy.
Future<DownloadRecord?> firstRealSavedCopy(
  Iterable<DownloadRecord> candidates, {
  required Future<bool> Function(DownloadRecord r) filePresent,
  required Future<int?> Function(DownloadRecord r) sizeOnDisk,
}) async {
  for (final r in candidates) {
    if (!await filePresent(r)) continue;
    final size = await sizeOnDisk(r);
    if (size != null &&
        !savedEpisodeSizeLooksReal(bytesOnDisk: size, bytesTotal: r.bytesTotal)) {
      continue;
    }
    return r;
  }
  return null;
}

/// Whether [r] is a saved copy that must not play: its file is gone, or it
/// is far too small to be a whole episode (a stub such as the 788 KB
/// Frieren E9 file). [sizeOnDisk] works as in [firstRealSavedCopy].
Future<bool> savedCopyIsBroken(
  DownloadRecord r, {
  required Future<bool> Function(DownloadRecord r) filePresent,
  required Future<int?> Function(DownloadRecord r) sizeOnDisk,
}) async {
  if (!await filePresent(r)) return true;
  if (!savedRecordSizeLooksReal(r)) return true;
  final size = await sizeOnDisk(r);
  return size != null &&
      !savedEpisodeSizeLooksReal(bytesOnDisk: size, bytesTotal: r.bytesTotal);
}

/// Windows show page: the first of [candidates] that is broken (see
/// [savedCopyIsBroken]), or null.
///
/// Why: such a copy is not offered as a download (Play streams instead), so
/// the right-click menu had nothing to delete it with. The caller asks only
/// after no real copy was found, and offers just Delete download / Download
/// again for it, never Play offline.
Future<DownloadRecord?> firstBrokenSavedCopy(
  Iterable<DownloadRecord> candidates, {
  required Future<bool> Function(DownloadRecord r) filePresent,
  required Future<int?> Function(DownloadRecord r) sizeOnDisk,
}) async {
  for (final r in candidates) {
    if (await savedCopyIsBroken(
      r,
      filePresent: filePresent,
      sizeOnDisk: sizeOnDisk,
    )) {
      return r;
    }
  }
  return null;
}

/// One shared copy of the download list for the episode ticks (B1), rebuilt
/// at most once per download-manager change.
///
/// Why: every visible row's tick runs the any-cut lookup on each change, and
/// [DownloadManager.all] copies and sorts every record each time it is read.
/// Rows now share one list per change instead of one per row.
class SavedRecordsSnapshot {
  SavedRecordsSnapshot._(this._manager) {
    _manager.addListener(_markStale);
  }

  static SavedRecordsSnapshot? _current;

  final DownloadManager _manager;
  List<DownloadRecord>? _records;

  /// The records of [manager], reused until the manager next changes.
  static List<DownloadRecord> of(DownloadManager manager) {
    var snap = _current;
    if (snap == null || !identical(snap._manager, manager)) {
      // A new manager (app restart in tests, or a re-registered service):
      // stop listening to the old one and follow the new one.
      snap?._detach();
      snap = _current = SavedRecordsSnapshot._(manager);
    }
    return snap._records ??= manager.all;
  }

  void _markStale() => _records = null;

  void _detach() {
    try {
      _manager.removeListener(_markStale);
    } catch (_) {
      // The old manager may already be disposed; nothing left to undo.
    }
  }
}

/// The episode ticks' look at a finished file's real size (Windows online
/// show page), so a stub whose record looks fine on paper (for example a
/// file found on disk with no recorded size) does not show as downloaded
/// either, matching the right-click menu and Play.
///
/// Why a cache: the ticks redraw on every download progress change and must
/// not read the disk each time. Each file is looked at once, in the
/// background; [changes] tells the ticks when one turned out to be a stub.
abstract final class SavedStubCheck {
  static final _known = <String, bool>{};
  static final _asking = <String>{};

  /// Bumped when a file turned out to be a stub, so the ticks redraw.
  static final changes = ValueNotifier<int>(0);

  /// Whether [r]'s file is a stub. Null while that is not known yet: a look
  /// is started, and the tick shows as before until it ends.
  static bool? stubOnDisk(
    DownloadRecord r,
    Future<int?> Function(DownloadRecord r) sizeOnDisk,
  ) {
    final key = '${r.id}|${r.filePath}|${r.bytesTotal}';
    final known = _known[key];
    if (known != null || !_asking.add(key)) return known;
    unawaited(
      Future<int?>.sync(() => sizeOnDisk(r))
          .then(
            (size) =>
                size != null &&
                !savedEpisodeSizeLooksReal(
                  bytesOnDisk: size,
                  bytesTotal: r.bytesTotal,
                ),
            onError: (Object _) => false,
          )
          .then((stub) {
            _asking.remove(key);
            _known[key] = stub;
            if (stub) changes.value++;
          }),
    );
    return null;
  }

  /// Forgets every look (tests).
  @visibleForTesting
  static void debugReset() {
    _known.clear();
    _asking.clear();
  }
}

/// Whether the episode tick must show the finished record [r] as not
/// downloaded (Windows online page): it is a stub by its recorded size, or
/// [SavedStubCheck] found its file on disk too small. A file not looked at
/// yet shows as before until the look ends.
bool tickCopyIsStub(
  DownloadRecord? r,
  Future<int?> Function(DownloadRecord r) sizeOnDisk,
) {
  if (r == null || r.status != DownloadStatus.done) return false;
  if (!savedRecordSizeLooksReal(r)) return true;
  return SavedStubCheck.stubOnDisk(r, sizeOnDisk) == true;
}

/// Display name of a saved cut ("Sub" / "Dub"), or null when the cut is
/// unknown (files found on disk) so callers fall back to plain wording.
String? savedCutName(String category, AppLocalizations l10n) =>
    switch (category.toLowerCase()) {
      'sub' => l10n.sub,
      'dub' => l10n.dub,
      _ => null,
    };

/// Finds suggestions only, never assigns provider or language to recovered files.
/// Unknown seasons, duplicate releases and partial title matches are ambiguous.
Map<Episode, DownloadRecord> recoveredDownloadSuggestions({
  required String title,
  required List<Episode> episodes,
  required List<DownloadRecord> records,
}) {
  String key(String value) => value.toLowerCase()
      .replaceAll(RegExp(r'[_\s]+'), ' ').trim();
  final wanted = key(title);
  if (wanted.isEmpty) return const {};
  final suggestions = <Episode, DownloadRecord>{};
  for (final episode in episodes) {
    if (episode.number?.isFinite != true || episode.season == null) continue;
    final matches = records.where((r) => r.recoveredFromDisk &&
        r.status == DownloadStatus.done && r.season == episode.season &&
        r.episodeNumber == episode.number && key(r.showTitle) == wanted).toList();
    if (matches.length == 1) suggestions[episode] = matches.single;
  }
  return suggestions;
}

/// Recheck after confirmation: a missing file must remain in the download batch.
Future<List<Episode>> omitReusableDownloads(List<Episode> episodes,
    Map<Episode, DownloadRecord> approved,
    Future<bool> Function(DownloadRecord) filePresent) async {
  final pending = <Episode>[];
  for (final episode in episodes) {
    final record = approved[episode];
    if (record == null || !await filePresent(record)) pending.add(episode);
  }
  return pending;
}
