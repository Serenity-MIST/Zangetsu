import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/hive/safe_box.dart';
import 'package:watch_app/core/hive/hive_key.dart';

import '../privacy/incognito_mode.dart';
import '../profiles/profile_scope.dart';

/// A saved playback position for one episode.
class ResumeMark {
  ResumeMark({
    required this.position,
    required this.duration,
    this.markedWatched = false,
    this.markedUnwatched = false,
  });
  final Duration position;
  final Duration duration;

  /// Set by hand from the episode list rather than inferred from playback.
  /// Stored separately instead of faking a position: a made-up duration would
  /// report a bogus progress fraction, and there'd be no way to tell a manual
  /// mark from a genuinely finished episode when unmarking.
  final bool markedWatched;

  /// Windows: the user explicitly marked this episode unwatched. Kept as a row
  /// (instead of deleting it) so it can veto the tracker's high-water mark,
  /// which would otherwise keep ticking the episode as watched.
  final bool markedUnwatched;

  /// True for a row that only says "user unmarked this" with no real playback
  /// behind it. Continue/resume logic must not treat it as a resume mark.
  bool get isUnwatchedOverride =>
      markedUnwatched && position == Duration.zero;

  /// Treat as watched when within the last ~8% of the runtime. An explicit
  /// unwatched override always wins.
  bool get finished =>
      !markedUnwatched &&
      (markedWatched ||
          (duration.inMilliseconds > 0 &&
              position.inMilliseconds >= duration.inMilliseconds * 0.92));
}

/// Hive-backed per-(sourceId, episodeId) resume positions.
class ResumeStore {
  ResumeStore({String? Function()? currentProfileId})
    : _currentProfileId = currentProfileId;

  final String? Function()? _currentProfileId;
  String get _profileId => _currentProfileId?.call() ?? kDefaultProfileId;

  static const String boxName = 'resume_positions';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await openBoxSafely<Map>(boxName);
    }
  }

  Box<Map> get _box => Hive.box<Map>(boxName);

  // Key includes the SHOW because providers like 4khdhub reuse episode ids
  // ('S1E3', …) across every title — without it, one show's resume position
  // collides with another's.
  String _key(String sourceId, String showId, String episodeId) =>
      profileScopedKey(_profileId, hiveKey('$sourceId::$showId::$episodeId'));

  Future<void> save(
    String sourceId,
    String showId,
    String episodeId,
    Duration position,
    Duration duration,
  ) async {
    if (IncognitoMode.on) return; // incognito: don't remember playback position
    final key = _key(sourceId, showId, episodeId);
    final prev = _box.get(key);
    final manuallyWatched = prev?['markedWatched'] == true;
    // An unwatched override survives partial replays (so the tracker can't
    // re-tick an episode being rewatched) and is dropped once playback
    // actually reaches the end, same 92% rule as [ResumeMark.finished].
    final reachedEnd =
        duration.inMilliseconds > 0 &&
        position.inMilliseconds >= duration.inMilliseconds * 0.92;
    final keepUnwatched = prev?['markedUnwatched'] == true && !reachedEnd;
    await _box.put(key, {
      'positionMs': position.inMilliseconds,
      'durationMs': duration.inMilliseconds,
      if (manuallyWatched) 'markedWatched': true,
      if (keepUnwatched) 'markedUnwatched': true,
    });
    // Logged because its ABSENCE is the interesting case. The flush runs from
    // the player's dispose(), so when Android kills the app straight out of
    // picture-in-picture it never happens and the position is silently lost —
    // a complaint that could not be checked in a shared log, because a write
    // that did happen left no more trace than one that did not.
    debugPrint(
      '[resume] saved ${position.inSeconds}s/${duration.inSeconds}s '
      '· $sourceId $episodeId',
    );
  }

  ResumeMark? get(String sourceId, String showId, String episodeId) {
    final raw = _box.get(_key(sourceId, showId, episodeId));
    if (raw == null) return null;
    final m = Map<String, dynamic>.from(raw);
    return ResumeMark(
      position: Duration(milliseconds: (m['positionMs'] as num?)?.toInt() ?? 0),
      duration: Duration(milliseconds: (m['durationMs'] as num?)?.toInt() ?? 0),
      // Absent on every mark written before this existed, which is the whole
      // point of defaulting it: an old mark keeps being judged by position.
      markedWatched: m['markedWatched'] == true,
      markedUnwatched: m['markedUnwatched'] == true,
    );
  }

  /// Windows keeps an explicit "unwatched" row instead of deleting (see
  /// [setWatched]); phone keeps its original delete behaviour unchanged.
  static bool get _keepUnwatchedOverride =>
      defaultTargetPlatform == TargetPlatform.windows;

  /// Mark an episode watched (or not) by hand, from the episode list.
  ///
  /// Unmarking clears the stale position rather than keeping it: "not
  /// watched" and "watched 4 minutes in" are different states, and keeping a
  /// stale position would leave the episode showing a progress bar it no
  /// longer deserves. On Windows the row is replaced by a zero-position
  /// override ([ResumeMark.markedUnwatched]) so a connected tracker's
  /// progress can't keep the episode ticked; elsewhere the row is deleted.
  Future<void> setWatched(
    String sourceId,
    String showId,
    String episodeId, {
    required bool watched,
  }) async {
    final key = _key(sourceId, showId, episodeId);
    if (!watched) {
      if (_keepUnwatchedOverride) {
        // Zero duration => no progress bar; the flag vetoes tracker ticks.
        await _box.put(key, {
          'positionMs': 0,
          'durationMs': 0,
          'markedUnwatched': true,
        });
      } else {
        await _box.delete(key);
      }
      return;
    }
    final raw = _box.get(key);
    final m = raw == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(raw);
    await _box.put(key, {
      // Position and duration are left as they were — a half-watched episode
      // marked watched keeps its real numbers, so unmarking it later doesn't
      // invent a position it never had.
      'positionMs': (m['positionMs'] as num?)?.toInt() ?? 0,
      'durationMs': (m['durationMs'] as num?)?.toInt() ?? 0,
      'markedWatched': true,
    });
  }
}
