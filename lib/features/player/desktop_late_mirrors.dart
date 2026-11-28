import 'package:flutter/foundation.dart';

import '../../core/models/video_source.dart';

/// Windows only (plan item R5): keep collecting mirrors after playback starts.
///
/// A playback resolve returns on the first usable link so the video starts
/// quickly, and a CloudStream source keeps finding more links in the
/// background for up to a minute. The phone reads those late links for about
/// 60 s after playback starts, so when the playing link fails later there are
/// more mirrors to fall back to. These helpers give the Windows mpv player the
/// same background poll, with a few extra rules (see [pollDesktopLateMirrors]).

/// One read of the links found so far, and whether more may still come.
typedef DesktopLateMirrorPoll =
    Future<({List<VideoSource> sources, bool done})> Function();

/// When to look again for late mirrors: quick at first, then every 10 s,
/// about 60 s in all. The same schedule the shared player already uses, and
/// about as long as the CloudStream engine keeps collecting links.
const List<Duration> kDesktopLateMirrorDelays = [
  Duration(milliseconds: 900),
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 3),
  Duration(seconds: 5),
  Duration(seconds: 8),
  Duration(seconds: 10),
  Duration(seconds: 10),
  Duration(seconds: 10),
  Duration(seconds: 10),
];

/// True on Windows desktop, where the background poll below is used. Phone,
/// TV and web keep the shared player's own poll unchanged.
bool get desktopLateMirrorsEnabled =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

/// Which poller the player uses for late mirrors.
///
/// The poller the launcher passed ([given]) always wins. On Windows, a player
/// opened without one (Continue Watching on Home, History, Search, Browse,
/// Watch Together) gets [fallback], so those plays collect late mirrors too
/// instead of only the one batch the first resolve returned. Elsewhere the
/// answer is [given], exactly as before.
T? desktopLateMirrorPoller<T extends Object>({
  required bool isWindows,
  required T? given,
  required T? fallback,
}) {
  if (given != null) return given;
  return isWindows ? fallback : null;
}

/// The background poll itself. Returns once nothing more is coming, after
/// about 60 s ([delays]), or as soon as it should stop.
///
/// * [isCurrent] says whether this poll still belongs to what is on screen:
///   false once the player closed, the episode or Sub/Dub cut changed, or a
///   newer poll (or a fresh-links swap) replaced this one. Checked before and
///   after every read, so a stopped poll never adds anything.
/// * [canPoll] (Z Mode) says whether the source that is playing is still
///   known. When it is not (the player is moving to another source), the
///   poll stops rather than letting a read start a new search of the sites.
/// * New links are only ever appended through [add], never reordered, so the
///   link playing now and its place in the list are left alone. A link
///   already in the list (same address) is never added twice.
/// * A read that fails ends the poll quietly: the player already has a
///   playable list.
Future<void> pollDesktopLateMirrors({
  required DesktopLateMirrorPoll poll,
  required bool Function() isCurrent,
  required List<VideoSource> Function() currentSources,
  required void Function(List<VideoSource> extra) add,
  bool Function()? canPoll,
  List<Duration> delays = kDesktopLateMirrorDelays,
}) async {
  for (final delay in delays) {
    await Future<void>.delayed(delay);
    if (!isCurrent()) return;
    // The list was reset (a new open is under way): nothing to add to.
    if (currentSources().isEmpty) return;
    if (canPoll != null && !canPoll()) return;
    final ({List<VideoSource> sources, bool done}) result;
    try {
      result = await poll();
    } catch (e) {
      debugPrint('[player] late mirrors · poll failed, stopping: $e');
      return;
    }
    if (!isCurrent()) return;
    // Compared with the list as it is NOW, not as it was before the read:
    // something else may have changed it while the read was running.
    final seen = currentSources().map((s) => s.url).toSet();
    final extra = result.sources.where((s) => seen.add(s.url)).toList();
    if (extra.isNotEmpty) {
      debugPrint('[player] late mirrors · ${extra.length} more found');
      add(extra);
    }
    if (result.done) return; // nothing more is coming
  }
}
