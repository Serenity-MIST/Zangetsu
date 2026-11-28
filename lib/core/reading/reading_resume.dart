import '../models/episode.dart';
import '../models/provider_info.dart';
import 'chapter_nav.dart';
import 'read_history.dart';

/// Finds this title's latest synced position without confusing equal provider IDs.
/// Canonical metadata IDs survive a source change; ordinary IDs belong only to
/// their original source. Manga and novels remain separate even with equal IDs.
ReadEntry? readingHistoryForTitle(
  Iterable<ReadEntry> entries, {
  required String sourceId,
  required String showId,
  required ProviderType type,
}) {
  final canonical = RegExp(r'^(?:al|mal):\d+$').hasMatch(showId);
  ReadEntry? newest;
  for (final entry in entries) {
    if (entry.type != type || entry.showId != showId) continue;
    if (entry.sourceId != sourceId && !canonical) continue;
    if (newest == null || entry.updatedMs > newest.updatedMs) newest = entry;
  }
  return newest;
}

/// Maps cloud chapter identity onto the current provider's chapter list.
/// Source refreshes and mobile/desktop adapters may use different IDs/URLs, so
/// the actual chapter number is the final stable fallback, never its row index.
int? readingHistoryChapter(List<Episode> chapters, ReadEntry entry) {
  var index = entry.chapterUrl.isEmpty
      ? -1
      : chapters.indexWhere((chapter) => chapter.url == entry.chapterUrl);
  if (index < 0 && entry.chapterId.isNotEmpty) {
    index = chapters.indexWhere((chapter) => chapter.id == entry.chapterId);
  }
  final number = entry.chapterNumber;
  if (index < 0 && number != null && number.isFinite) {
    index = chapters.indexWhere((chapter) => chapter.number == number);
  }
  return index < 0 ? null : index;
}

/// Selects Continue's target, advancing completed chapters within their group.
/// If a source dropped that chapter, choose the next numbered chapter rather
/// than silently restarting the title. Tracker counts mean chapters completed.
({int index, bool hasResume}) readingHistoryTarget(
  List<Episode> chapters, {
  ReadEntry? entry,
  int? completedChapters,
}) {
  if (chapters.isEmpty) return (index: 0, hasResume: false);
  if (entry != null) {
    final index = readingHistoryChapter(chapters, entry);
    if (index != null) {
      return (
        index: entry.finished
            ? (chapters[index].number == null
                      ? adjacentChapterIndex(chapters, index, step: 1)
                      : _nextNumberedChapter(
                          chapters,
                          chapters[index].number!,
                          group: scanlatorLabel(chapters[index].scanlator),
                        )) ??
                  index
            : index,
        hasResume: true,
      );
    }
    final number = entry.chapterNumber;
    if (number != null && number.isFinite) {
      final next = _nextNumberedChapter(chapters, number);
      if (next != null) return (index: next, hasResume: true);
    }
  }
  if (completedChapters != null && completedChapters > 0) {
    final next = _nextNumberedChapter(chapters, completedChapters.toDouble());
    if (next != null) return (index: next, hasResume: true);
    int? highest;
    for (var i = 0; i < chapters.length; i++) {
      final number = chapters[i].number;
      if (number != null &&
          number.isFinite &&
          (highest == null || number > chapters[highest].number!)) {
        highest = i;
      }
    }
    if (highest != null) return (index: highest, hasResume: true);
  }
  return (index: 0, hasResume: false);
}

/// Chooses by chapter number, independent of a provider's newest-first order.
/// Prefer the reader's release group while it still has a subsequent chapter.
int? _nextNumberedChapter(
  List<Episode> chapters,
  double after, {
  String? group,
}) {
  int? any;
  int? sameGroup;
  for (var i = 0; i < chapters.length; i++) {
    final number = chapters[i].number;
    if (number == null || !number.isFinite || number <= after) continue;
    if (any == null || number < chapters[any].number!) any = i;
    if (group != null &&
        scanlatorLabel(chapters[i].scanlator) == group &&
        (sameGroup == null || number < chapters[sameGroup].number!)) {
      sameGroup = i;
    }
  }
  return sameGroup ?? any;
}
