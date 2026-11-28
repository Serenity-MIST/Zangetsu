// Windows-only helper for the show page's "Switch source" recovery picker.
// Kept outside detail_screen.dart so it can be unit tested on its own.
import '../../core/zmode/match_store.dart';
import '../../core/zmode/source_matcher.dart';
import '../../core/zmode/zmode_ids.dart';

/// Pins [sourceId] to THIS title only (Windows rule ar-1: one pick must not
/// change every other show), and returns the match it found.
///
/// When the chosen source does not have the title, the shared
/// [SourceMatcher.pinTitleToSource] still pins it with an empty match. On the
/// recovery picker that is a trap: a hand-picked source that fails stops the
/// whole playback sweep, so every Play would dead-end until the user found the
/// source pill and chose Auto Resolve. So on a miss we drop the pin straight
/// away and the title goes back to Auto Resolve. Returns null on a miss so the
/// caller can tell the user why.
///
/// [SourceMatcher.pinTitleToSource] itself is left unchanged because the
/// source pill and the phone share it.
Future<SourceMatch?> desktopPinTitleOrStayOnAuto(
  SourceMatcher matcher,
  ZCanonical c,
  String sourceId, {
  required String title,
  String? altTitle,
  List<String> metadataAliases = const [],
  int? malId,
}) async {
  final m = await matcher.pinTitleToSource(
    c,
    sourceId,
    title: title,
    altTitle: altTitle,
    metadataAliases: metadataAliases,
    malId: malId,
  );
  // No match: undo the empty pin so the next Play runs the normal sweep.
  if (m == null) await matcher.clearTitlePin(c);
  return m;
}
