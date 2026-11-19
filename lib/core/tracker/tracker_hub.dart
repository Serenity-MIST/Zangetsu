import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

import '../anilist/anilist_service.dart';
import '../boot_network.dart';
import '../di/injector.dart';
import '../mode/content_mode.dart';
import '../models/watch_status.dart';
import '../playback/playback_prefs.dart';
import '../privacy/incognito_mode.dart';
import 'mangabaka_service.dart';
import 'tracker.dart';
import 'simkl_service.dart';
import 'simkl_playback_session.dart';
import 'tracker_sync_queue.dart';

/// Fans every list/progress write out to all connected trackers at once
/// (AniList + MyAnimeList + Simkl). Each tracker self-gates (skips when
/// disconnected / auto-sync off / type not applicable), and a failure in one
/// never blocks the others.
class TrackerHub {
  /// [syncQueue] turns on the offline outbox (track-2). Left null, the
  /// Windows app uses the shared [TrackerSyncQueue.instance] and starts it a
  /// moment after launch; phone, TV and tests keep the old fire-and-forget
  /// writes.
  TrackerHub(this.trackers, {TrackerSyncQueue? syncQueue})
    : syncQueue = syncQueue ?? (_windowsApp ? TrackerSyncQueue.instance : null) {
    final queue = this.syncQueue;
    if (queue == null) return;
    if (syncQueue != null) {
      // Injected (tests): wire it up straight away.
      queue.attach(trackers, loginExpired: trackerNeedsSignIn);
    } else {
      // App start: give boot a few seconds before the first (launch) retry,
      // so opening the box and the network calls never slow the splash.
      Timer(
        const Duration(seconds: 4),
        () => queue.attach(trackers, loginExpired: trackerNeedsSignIn),
      );
    }
  }

  final List<Tracker> trackers;

  /// Bumped after every list edit routed through the hub (setStatus,
  /// removeFromList, updateEntry) has finished, so screens such as the
  /// desktop schedule can refresh even when the edit bypassed
  /// ListStatusStore. Only listened to by Windows UI; harmless elsewhere.
  final ValueNotifier<int> listWrites = ValueNotifier(0);

  // Tells [listWrites] listeners that a list edit just completed.
  void _bumpListWrites() => listWrites.value++;

  /// For screens that write to ONE tracker directly instead of through the
  /// hub (the per-tracker entry / list sheets): call this after the write so
  /// [listWrites] listeners refresh too.
  void noteListWrite() => _bumpListWrites();

  /// Persistent outbox for failed writes, or null when it is off.
  final TrackerSyncQueue? syncQueue;

  // The real Windows app: not a widget test pretending to be Windows, and not
  // a test host pretending to be a phone. The outbox is new Windows-only
  // behaviour; phone keeps today's fire-and-forget writes.
  static bool get _windowsApp =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.windows &&
      Platform.isWindows &&
      !Platform.environment.containsKey('FLUTTER_TEST');

  Iterable<Tracker> get connected => trackers.where((t) => t.isConnected);
  bool get anyConnected => connected.isNotEmpty;

  /// Trackers that can actually sync in [mode]. A reading mode drops
  /// video-only trackers (Simkl), and a watching mode drops reading-only ones
  /// — either way the point is not to offer an account that can never sync a
  /// single title there.
  ///
  /// Display/selection only — the write paths already self-gate per
  /// [MediaKind] (see `MangaBakaService._canWrite`), so this never changes
  /// what gets synced.
  Iterable<Tracker> forMode(ContentMode mode) => mode.isReading
      ? trackers.where((t) => t.supportsReading)
      : trackers.where(trackerSupportsVideo);

  /// [forMode], narrowed to the ones the user has actually connected.
  Iterable<Tracker> connectedForMode(ContentMode mode) =>
      forMode(mode).where((t) => t.isConnected);

  /// Whether the "as you watch" writes are allowed through. Reads defensively
  /// so a context without [PlaybackPrefs] registered (tests, early startup)
  /// behaves as it always did rather than silently going quiet.
  static bool get _autoTrackOn =>
      !sl.isRegistered<PlaybackPrefs>() || sl<PlaybackPrefs>().autoTrack;

  SimklPlaybackSession? simklPlayback({
    int? malId,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    int? episode,
    int? season,
    int? seasonEpisode,
  }) {
    for (final tracker in trackers.whereType<SimklService>()) {
      return tracker.playbackSession(
        malId: malId,
        tmdbId: tmdbId,
        tmdbIsTv: tmdbIsTv,
        imdbId: imdbId,
        episode: episode,
        season: season,
        seasonEpisode: seasonEpisode,
        allowed: () => _autoTrackOn && !IncognitoMode.on,
      );
    }
    return null;
  }

  Future<void> markWatching({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    MediaKind kind = MediaKind.anime,
  }) async {
    // Only ever called on playback start, so there's no manual path to spare.
    if (!_autoTrackOn) return;
    if (IncognitoMode.on) return; // incognito: pause auto-tracking
    await _fan(
      TrackerSyncOp.markWatching,
      (_) => TrackerSyncArgs.pack(
        malId: malId,
        title: title,
        tmdbId: tmdbId,
        tmdbIsTv: tmdbIsTv,
        imdbId: imdbId,
        kind: kind,
      ),
      (t) => t.markWatching(
        malId: malId,
        title: title,
        tmdbId: tmdbId,
        tmdbIsTv: tmdbIsTv,
        imdbId: imdbId,
        kind: kind,
      ),
    );
  }

  Future<void> scrobble({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    required int episode,
    int? season,
    int? seasonEpisode,
    MediaKind kind = MediaKind.anime,
    bool novel = false,
    bool auto = true,
    bool simklLive = false,
  }) async {
    // [auto] false = the user asked for this one by hand ("Mark as watched"),
    // so the auto-track preference doesn't apply. Incognito still does.
    if (auto && !_autoTrackOn) return;
    if (IncognitoMode.on) return; // incognito: pause auto-scrobble
    await _fan(
      TrackerSyncOp.scrobble,
      (_) => TrackerSyncArgs.pack(
        malId: malId,
        title: title,
        tmdbId: tmdbId,
        tmdbIsTv: tmdbIsTv,
        imdbId: imdbId,
        episode: episode,
        season: season,
        seasonEpisode: seasonEpisode,
        kind: kind,
        novel: novel,
      ),
      (t) => auto && simklLive && t is SimklService
          ? Future<void>.value()
          : t.scrobble(
              malId: malId,
              title: title,
              tmdbId: tmdbId,
              tmdbIsTv: tmdbIsTv,
              imdbId: imdbId,
              episode: episode,
              season: season,
              seasonEpisode: seasonEpisode,
              kind: kind,
              novel: novel,
            ),
    );
  }

  Future<void> setStatus({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    required WatchStatus status,
    MediaKind kind = MediaKind.anime,
  }) => _fan(
    TrackerSyncOp.setStatus,
    (_) => TrackerSyncArgs.pack(
      malId: malId,
      title: title,
      tmdbId: tmdbId,
      tmdbIsTv: tmdbIsTv,
      imdbId: imdbId,
      status: status,
      kind: kind,
    ),
    (t) => t.setStatus(
      malId: malId,
      title: title,
      tmdbId: tmdbId,
      tmdbIsTv: tmdbIsTv,
      imdbId: imdbId,
      status: status,
      kind: kind,
    ),
  ).whenComplete(_bumpListWrites); // list changed: notify listeners

  Future<void> removeFromList({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    MediaKind kind = MediaKind.anime,
  }) => _fan(
    TrackerSyncOp.removeFromList,
    (_) => TrackerSyncArgs.pack(
      malId: malId,
      title: title,
      tmdbId: tmdbId,
      tmdbIsTv: tmdbIsTv,
      imdbId: imdbId,
      kind: kind,
    ),
    (t) => t.removeFromList(
      malId: malId,
      title: title,
      tmdbId: tmdbId,
      tmdbIsTv: tmdbIsTv,
      imdbId: imdbId,
      kind: kind,
    ),
  ).whenComplete(_bumpListWrites); // list changed: notify listeners

  /// Read the user's entry for one title. Queries every connected tracker in
  /// parallel and returns the FIRST that has the title on the user's list —
  /// that becomes the sheet's editable state. Falls back
  /// to the first that returned any data (so total-episodes / next-airing still
  /// show even when the title isn't on a list yet). Null when nothing matched.
  /// [pinnedIds] maps a tracker's [Tracker.displayName] to a chosen native id.
  Future<TrackerEntry?> fetchEntry({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    Map<String, String>? pinnedIds,
    MediaKind kind = MediaKind.anime,
    bool novel = false,
  }) async {
    final results = await fetchEntries(
      malId: malId,
      title: title,
      tmdbId: tmdbId,
      tmdbIsTv: tmdbIsTv,
      imdbId: imdbId,
      pinnedIds: pinnedIds,
      kind: kind,
      novel: novel,
    );
    for (final r in results) {
      if (r.onList) return r;
    }
    return results.isEmpty ? null : results.first;
  }

  /// Every connected tracker's entry for one title, in connection order, with
  /// the ones that answered nothing dropped.
  ///
  /// [fetchEntry] collapses this to a single entry — the combined sheet needs
  /// them all so it can say when two trackers disagree instead of silently
  /// overwriting one with the other.
  Future<List<TrackerEntry>> fetchEntries({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    Map<String, String>? pinnedIds,
    MediaKind kind = MediaKind.anime,
    bool novel = false,
  }) async {
    final results = await Future.wait(
      connected.map((t) async {
        try {
          return await t.fetchEntry(
            malId: malId,
            title: title,
            tmdbId: tmdbId,
            tmdbIsTv: tmdbIsTv,
            imdbId: imdbId,
            pinnedId: pinnedIds?[t.displayName],
            kind: kind,
            novel: novel,
          );
        } catch (_) {
          return null;
        }
      }),
    );
    return [
      for (final r in results) ?r,
    ];
  }

  /// Write status/score/progress for one title to EVERY connected tracker at
  /// once (the sheet's Apply). Not gated by incognito — this is an explicit,
  /// deliberate edit, not passive auto-tracking.
  Future<void> updateEntry({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    Map<String, String>? pinnedIds,
    WatchStatus? status,
    double? score,
    int? progress,
    bool? isPrivate,
    MediaKind kind = MediaKind.anime,
  }) async {
    if (isPrivate != null) {
      for (final tracker in connected.whereType<AniListService>()) {
        await tracker.updateEntry(
          malId: malId,
          title: title,
          pinnedId: pinnedIds?[tracker.displayName],
          isPrivate: isPrivate,
          kind: kind,
        );
      }
      if (status == null && score == null && progress == null) {
        _bumpListWrites(); // privacy-only edit still changed the entry
        return;
      }
    }
    await _fan(
      TrackerSyncOp.updateEntry,
      // Each tracker stores its own pinned id, so the replay hits the same
      // entry the user picked.
      (t) => TrackerSyncArgs.pack(
        malId: malId,
        title: title,
        tmdbId: tmdbId,
        tmdbIsTv: tmdbIsTv,
        imdbId: imdbId,
        pinnedId: pinnedIds?[t.displayName],
        status: status,
        score: score,
        progress: progress,
        kind: kind,
      ),
      (t) => t.updateEntry(
        malId: malId,
        title: title,
        tmdbId: tmdbId,
        tmdbIsTv: tmdbIsTv,
        imdbId: imdbId,
        pinnedId: pinnedIds?[t.displayName],
        status: status,
        score: score,
        progress: progress,
        kind: kind,
      ),
    ).whenComplete(_bumpListWrites); // list changed: notify listeners
  }

  /// Candidate matches from every connected tracker (the match-fixer), in
  /// connection order.
  Future<List<TrackerSearchResult>> searchEntries(
    String query, {
    MediaKind kind = MediaKind.anime,
  }) async {
    final lists = await Future.wait(
      connected.map((t) async {
        try {
          return await t.searchEntries(query, kind: kind);
        } catch (_) {
          return const <TrackerSearchResult>[];
        }
      }),
    );
    return [for (final l in lists) ...l];
  }

  /// Runs [op] on every connected tracker at once; one tracker failing never
  /// blocks the rest. With the outbox on, failures are no longer swallowed:
  /// each tracker's outcome goes to [syncQueue], which keeps failed writes
  /// (described by [op] and [args]) for retry and tracks needs-sign-in.
  Future<void> _fan(
    TrackerSyncOp op,
    Map<String, dynamic> Function(Tracker t) args,
    Future<void> Function(Tracker) call,
  ) async {
    final queue = syncQueue;
    if (queue != null) {
      // An AniList login that expired no longer counts as connected, so the
      // write would vanish. Keep it and flag "needs sign-in" instead.
      for (final t in trackers.where(trackerNeedsSignIn)) {
        try {
          await queue.record(
            t,
            op,
            args(t),
            TrackerWriteReport()
              ..note(TrackerWriteProblem.auth, 'Sign-in expired'),
          );
        } catch (e) {
          debugPrint('[trackers] could not queue for ${t.displayName}: $e');
        }
      }
    }
    await Future.wait(
      connected.map((t) async {
        if (queue == null) {
          // Phone / TV / tests: the original best-effort behaviour.
          try {
            await call(t);
          } catch (_) {/* one tracker failing must not block the rest */}
          return;
        }
        // Known offline: don't wait out a timeout, just keep it for later.
        if (BootConnectivity.instance.offline.value) {
          await queue.queueOffline(t, op, args(t));
          return;
        }
        final report = await TrackerWriteScope.run(() => call(t));
        if (!report.ok) {
          debugPrint(
            '[trackers] ${t.displayName} ${op.name} failed '
            '(${report.problem!.name}): ${report.detail}',
          );
        }
        try {
          await queue.record(t, op, args(t), report);
        } catch (e) {
          debugPrint('[trackers] could not record sync outcome: $e');
        }
      }),
    );
  }
}

/// Whether this tracker has an anime/film library at all. The mirror of
/// [Tracker.supportsReading]: false for MangaBaka, which is reading-only.
///
/// A function rather than another getter on [Tracker] on purpose — the
/// interface is `implements`-only, so a new member would force every other
/// tracker and every test fake to declare it, for one exception. If a second
/// reading-only tracker ever lands, add it here.
bool trackerSupportsVideo(Tracker t) => t is! MangaBakaService;

/// Whether [t] was connected but its saved login has expired and can't be
/// refreshed (AniList). MAL's dead refresh token is caught per write instead
/// and shows up in [TrackerSyncQueue.healthOf].
bool trackerNeedsSignIn(Tracker t) =>
    t is AniListService && !t.isConnected && t.signInExpired;
