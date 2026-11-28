/// Windows-only recovery rules for the mpv player, kept as plain functions so
/// they can be tested without a player. The player controller calls them from
/// behind its Windows checks; phones never reach them.
library;

// ── Safe second try (plan item R2) ──────────────────────────────────────────

/// How long the safe second try may take to show its first frame before the
/// player moves on. Shorter than the normal 30 s start window: the link has
/// already failed once, so this try only gets a short extra chance.
const Duration kDesktopSafeRetryWatchdog = Duration(seconds: 15);

/// mpv demuxer options for the safe second try.
///
/// The normal open adds `http_persistent=0` (for HLS) and an
/// `analyzeduration` cap to start faster on anti-leech CDNs. Either can break a
/// stream that does not need them, so the second try drops both and keeps only
/// the relaxed extension check (segments disguised as `.js`/`.css` still need
/// it to be readable at all).
const String kDesktopSafeRetryDemuxerOptions =
    'extension_picky=0,allowed_extensions=ALL';

/// Whether a link that failed before its first frame gets ONE more try with
/// the safe profile (software decoding, no audio-track trimming, default
/// demuxer options), the Windows stand-in for the phone opening a failed link
/// once in its other player.
///
///  * [alreadyRetried] is the per-open flag the player already uses for its
///    software-decoder retry, so a link is retried at most once and the retry
///    can never loop.
///  * Torrents, DRM links, local files and the offline case never retry:
///    a second try would not change anything there (or the offline path has
///    its own handling).
///  * [proxied] covers a stream already played through a local proxy, and
///    [proxySwapPending] an Aniyomi link whose own proxy fallback is about to
///    be tried; both have their own recovery.
///  * [timedOut]: the link produced no frame and no error within the start
///    window. Then it is only retried when no other mirror is left
///    ([otherMirrorLeft] false), because a silent link usually stays silent and
///    the next mirror is the better bet.
bool shouldDesktopSafeRetry({
  required bool isWindows,
  required bool alreadyRetried,
  required bool startedThisSource,
  required bool isLocalFile,
  required bool isTorrent,
  required bool isDrm,
  required bool offline,
  required bool proxied,
  required bool proxySwapPending,
  required bool timedOut,
  required bool otherMirrorLeft,
}) {
  if (!isWindows || alreadyRetried || startedThisSource) return false;
  if (isLocalFile || isTorrent || isDrm || offline) return false;
  if (proxied || proxySwapPending) return false;
  if (timedOut && otherMirrorLeft) return false;
  return true;
}

// ── Fresh links once when a link has expired (plan item R3) ─────────────────

/// Longest the one fresh re-scrape may take before the player gives up on it
/// and moves to the next source, like the phone's 15 s cap.
const Duration kDesktopFreshLinksCap = Duration(seconds: 15);

/// True when the player's error text, or one of mpv's error log lines for this
/// link, reads like an expired or refused link: HTTP 403 / 410, "forbidden",
/// "gone", "expired" or "access denied".
///
/// Web addresses are removed from the text before it is checked: mpv and
/// ffmpeg messages usually include the link, and a path or query such as
/// `.../seg/410/x.ts` or `?ep=12-403` must not count as a refused link (that
/// would cost a needless re-scrape and up to 15 s before the next source).
bool looksLikeExpiredLink({
  required String error,
  Iterable<String> logLines = const [],
}) {
  final url = RegExp(r'\b[a-z][a-z0-9+.-]*://\S+', caseSensitive: false);
  final pattern = RegExp(
    r'\b(403|410)\b|forbidden|\bgone\b|expired|access denied',
    caseSensitive: false,
  );
  bool matches(String text) => pattern.hasMatch(text.replaceAll(url, ' '));
  if (matches(error)) return true;
  return logLines.any(matches);
}

/// Whether to ask the same source for fresh links once: only on Windows, only
/// once per episode ([alreadyTried]), only after every mirror is used up
/// ([mirrorsLeft] false), never for local files, torrents or while offline,
/// and only when the failure [looksExpired] (see [looksLikeExpiredLink]).
bool shouldTryFreshLinks({
  required bool isWindows,
  required bool alreadyTried,
  required bool mirrorsLeft,
  required bool isLocalFile,
  required bool isTorrent,
  required bool offline,
  required bool looksExpired,
}) =>
    isWindows &&
    !alreadyTried &&
    !mirrorsLeft &&
    !isLocalFile &&
    !isTorrent &&
    !offline &&
    looksExpired;

/// The first link in [fresh] the player has not tried yet for this episode,
/// or null when the re-scrape only returned links that already failed.
T? firstUntriedLink<T>(
  List<T> fresh,
  Set<String> tried,
  String Function(T link) urlOf,
) {
  for (final link in fresh) {
    if (!tried.contains(urlOf(link))) return link;
  }
  return null;
}

// ── Resume mark at or past the end (plan item P5) ───────────────────────────

/// How close to the end a saved mark may sit and still count as "at the end".
const Duration kResumeAtEndSlack = Duration(seconds: 5);

/// True when a saved resume [target] is at, or within [kResumeAtEndSlack] of,
/// the video's [duration], so resuming there would only show the last few
/// seconds (or nothing). The player then starts from 0 and resets the mark.
///
/// Only a known duration counts: [duration] zero or less (not reported yet,
/// or a stream that reports none) is never treated as proof, and neither is a
/// [durationTrusted] false (a saved `.ts` download whose length mpv only
/// estimates), so a valid mark is never thrown away on a guess.
bool resumeMarkAtOrPastEnd({
  required Duration target,
  required Duration duration,
  bool durationTrusted = true,
}) {
  if (!durationTrusted) return false;
  if (target <= Duration.zero || duration <= Duration.zero) return false;
  return target + kResumeAtEndSlack >= duration;
}

/// True when the start [target] of an open is the episode's SAVED resume
/// mark, the only case the end-of-video reset ([resumeMarkAtOrPastEnd]) may
/// touch. [savedMark] is the mark the open read from the resume store (zero
/// when the open came from a server or quality switch, which reopens at the
/// live position), and [pending] the mark the player is still aiming for.
///
/// A switch near the end (during the credits, say) reopens at the live
/// position, which is not a saved mark, so it keeps its place instead of
/// restarting the episode and wiping its progress.
bool isSavedResumeTarget({
  required Duration target,
  required Duration savedMark,
  required Duration pending,
}) =>
    target > Duration.zero && target == savedMark && target == pending;
