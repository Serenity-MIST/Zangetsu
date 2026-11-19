import '../../core/download/chapter_download.dart';
import '../../core/download/download_record.dart';
import 'desktop_download_library.dart';
import '../../l10n/l10n.dart';

/// What deleting a set of shows from the Downloads library would remove, for the
/// confirmation dialog and the follow-up report.
class BulkDeletePlan {
  const BulkDeletePlan({
    required this.shows,
    required this.videos,
    required this.chapters,
  });

  /// The shows chosen.
  final int shows;

  /// Every video and chapter download inside them (saved, queued or failed).
  final List<DownloadRecord> videos;
  final List<ChapterDownload> chapters;

  /// Downloads that are still running and would be canceled.
  int get active =>
      videos.where((r) => r.isActive).length +
      chapters.where((c) => c.isActive).length;

  /// Total items that would be deleted.
  int get items => videos.length + chapters.length;

  /// Disk space of the finished videos, when known. Chapters do not report a
  /// size, so this is a lower bound and the dialog says "at least".
  int get knownBytes => videos
      .where((r) => r.status == DownloadStatus.done)
      .fold(0, (sum, r) => sum + (r.bytesTotal > 0 ? r.bytesTotal : 0));
}

/// Builds the plan for deleting [collections]. Pure: it only reads.
BulkDeletePlan planBulkDelete(Iterable<DesktopDownloadCollection> collections) {
  final list = collections.toList();
  return BulkDeletePlan(
    shows: list.length,
    videos: [for (final c in list) ...c.videos],
    chapters: [for (final c in list) ...c.chapters],
  );
}

/// Human-readable size such as "1.4 GB" or "320 MB".
String formatBytes(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  const mb = 1024 * 1024;
  const gb = 1024 * mb;
  if (bytes < gb) return '${(bytes / mb).round()} MB';
  return '${(bytes / gb).toStringAsFixed(1)} GB';
}

/// The confirmation text for [plan]. Spells out how much is removed and that it
/// cannot be undone, and mentions running downloads that would be canceled.
/// With [recycle] (Windows, where finished files go to the Recycle Bin) it
/// says that instead of "cannot be undone", which would no longer be true.
String describeBulkDelete(BulkDeletePlan plan, {bool recycle = false}) {
  // No context here; appL10n follows the app language.
  final l10n = appL10n;
  final shows = l10n.bulkDeleteShows(plan.shows);
  final items = l10n.bulkDeleteDownloads(plan.items);
  final size = plan.knownBytes > 0
      ? l10n.bulkDeleteAtLeast(formatBytes(plan.knownBytes))
      : '';
  final active = plan.active > 0
      ? l10n.bulkDeleteActiveCanceled(plan.active)
      : '';
  if (recycle) {
    return l10n.bulkDeleteRecycle(shows, items, size, active);
  }
  return l10n.bulkDeletePermanent(shows, items, size, active);
}

/// Deletes every download in [plan] using the supplied callbacks, one show's
/// worth at a time, and returns how many items failed. A failure never stops the
/// rest: the user asked for all of them to go.
///
/// The callbacks do the real work (cancel, remove files and records), so this
/// stays testable without any storage.
Future<int> executeBulkDelete(
  BulkDeletePlan plan, {
  required Future<void> Function(List<DownloadRecord>) deleteVideos,
  required Future<void> Function(ChapterDownload) deleteChapter,
}) async {
  var failed = 0;
  try {
    await deleteVideos(plan.videos);
  } catch (_) {
    failed += plan.videos.length;
  }
  for (final chapter in plan.chapters) {
    try {
      await deleteChapter(chapter);
    } catch (_) {
      failed++;
    }
  }
  return failed;
}
