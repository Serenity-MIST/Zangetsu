import 'dart:async';

import '../../core/models/video_source.dart';
import '../../core/playback/source_selection.dart';

/// A pause or a reached checkpoint must never erase a saved resume position.
bool shouldResetStremioResume({
  required bool playingThroughout,
  required Duration position,
  required Duration target,
}) =>
    playingThroughout &&
    target > Duration.zero &&
    position + const Duration(seconds: 8) < target;

/// Whether a Z-mode episode should be resolved through its progressive sweep.
/// A preferred local source, when available, should be opened first instead.
bool shouldUseProgressivePlayback({
  required bool progressiveAvailable,
  required bool hasLocalSource,
}) => progressiveAvailable && !hasLocalSource;

/// Retry only a failed local codec open, once, when the user has not already
/// chosen software decoding. Network playback and other local errors are left
/// to their existing recovery paths.
bool shouldRetryWithSoftwareDecoder({
  required bool isLocalFile,
  required bool alreadyRetried,
  required bool softwareDecoderSelected,
  required String error,
}) =>
    isLocalFile &&
    !alreadyRetried &&
    !softwareDecoderSelected &&
    error.toLowerCase().contains('codec');

bool isCurrentSoftwareDecoderRetry({
  required int retryGeneration,
  required int currentGeneration,
}) => retryGeneration == currentGeneration;

bool shouldInvalidateSoftwareDecoderRetry({
  required bool retryInProgress,
  required bool openingRetry,
}) => retryInProgress && !openingRetry;

/// Return a one-open `hwdec` override for a local software fallback, or null
/// when the player's normal decoder preference should remain untouched.
String? softwareDecoderOverride({
  required bool retryWithSoftware,
  required bool fallbackActive,
  required String preferredHwdec,
}) {
  if (retryWithSoftware) return 'no';
  if (fallbackActive) return preferredHwdec;
  return null;
}

/// Polls a provider's existing resolution session briefly for late mirrors.
/// Links already returned are retained and duplicate URLs are ignored.
Future<List<VideoSource>> collectLatePlaybackMirrors({
  required List<VideoSource> initial,
  required Future<({List<VideoSource> sources, bool done})> Function() poll,
  bool Function()? isStillCurrent,
  Duration maxWait = const Duration(seconds: 3),
  Duration pollInterval = const Duration(milliseconds: 300),
}) async {
  final sources = List<VideoSource>.of(initial);
  final seen = initial.map((source) => source.url).toSet();
  if (maxWait <= Duration.zero) return sources;

  final timer = Stopwatch()..start();
  while (timer.elapsed < maxWait) {
    if (isStillCurrent != null && !isStillCurrent()) return sources;
    final remaining = maxWait - timer.elapsed;
    ({List<VideoSource> sources, bool done}) result;
    try {
      result = await poll().timeout(remaining);
    } on TimeoutException {
      continue;
    } catch (_) {
      return sources;
    }

    for (final source in result.sources) {
      if (seen.add(source.url)) sources.add(source);
    }
    if (result.done) return sources;

    final pause = maxWait - timer.elapsed;
    if (pause > Duration.zero && pollInterval > Duration.zero) {
      await Future<void>.delayed(pollInterval < pause ? pollInterval : pause);
    }
  }
  return sources;
}

/// Selects an untried mirror without switching a known audio cut.
///
/// Unknown-cut links remain eligible when a provider doesn't label its audio;
/// a known opposite cut is never chosen as an automatic startup fallback.
VideoSource? pickPlaybackFallback({
  required VideoSource failed,
  required List<VideoSource> sources,
  required Set<String> triedUrls,
  required String preferredQuality,
}) {
  final untried = sources
      .where((source) => !triedUrls.contains(source.url))
      .toList();
  if (untried.isEmpty) return null;

  final eligible = failed.kind == AudioKind.unknown
      ? untried
      : untried
            .where(
              (source) =>
                  source.kind == failed.kind ||
                  source.kind == AudioKind.unknown,
            )
            .toList();
  return pickDefault(
    eligible,
    prefer: failed.kind,
    preferQuality: preferredQuality,
  );
}

/// What the player should do when every online option has failed or stalled.
enum LocalFallbackAction {
  /// Stay on the error: the feature is off, already used, or not possible.
  none,

  /// Switch to the downloaded copy without asking.
  switchNow,

  /// Offer the downloaded copy and switch only if the viewer agrees.
  ask,
}

/// Decides whether to fall back to the downloaded copy of the episode.
///
/// [mode] is the saved setting: `'auto'`, `'ask'` or `'off'` (anything else is
/// treated as `'auto'`). The fallback only applies when the player is not
/// already on a local file, has not already tried it for this episode (so a
/// failing local file can never bounce back to the network and loop), and has
/// a way to look for the download.
LocalFallbackAction localFallbackAction({
  required String mode,
  required bool alreadyLocal,
  required bool alreadyTried,
  required bool hasFinder,
}) {
  if (alreadyLocal || alreadyTried || !hasFinder) {
    return LocalFallbackAction.none;
  }
  return switch (mode) {
    'off' => LocalFallbackAction.none,
    'ask' => LocalFallbackAction.ask,
    _ => LocalFallbackAction.switchNow,
  };
}

/// How far before a resume target a seek may land and still count as having
/// worked. Seeks in streams with sparse keyframes (an HLS-saved `.ts` can go
/// ten seconds between them) land on the keyframe before the target, so
/// demanding an exact landing makes the player seek again, land in the same
/// place, and replay the same few seconds over and over.
const Duration kResumeLandingSlack = Duration(seconds: 12);

/// True when playback is close enough to the resume [target] that seeking again
/// would only undo a good seek.
///
/// A position at or past the target always counts. Before it, the allowed gap
/// is [kResumeLandingSlack], but never more than half the target, so a mark of
/// a few seconds still gets a real seek rather than being ignored.
bool resumeSeekLanded({required Duration position, required Duration target}) {
  final half = target ~/ 2;
  final slack = half < kResumeLandingSlack ? half : kResumeLandingSlack;
  return position + slack >= target;
}

/// Whether an mpv subtitle track ([title], [language]) is the player's own copy
/// of one of the [saved] subtitles (label and language as they were passed to
/// `sub-add`). Both must match exactly, so a real embedded track, which has its
/// own language code, is never hidden by mistake.
bool isSavedSubCopy({
  required String? title,
  required String? language,
  required List<({String label, String lang})> saved,
}) {
  final t = (title ?? '').trim();
  final l = (language ?? '').trim();
  if (t.isEmpty || l.isEmpty) return false;
  return saved.any((s) => s.label.trim() == t && s.lang.trim() == l);
}
