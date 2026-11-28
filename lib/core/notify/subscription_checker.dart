import 'package:flutter/foundation.dart';

import '../logging/app_logger.dart';
import '../repository/catalogue_repository.dart';
import 'new_episode_inbox.dart';
import 'notification_service.dart';
import 'subscription_store.dart';

/// Tells the user that [sub] grew to [count] episodes/chapters. Returns true
/// when they were actually told (an alert raised or an inbox entry added);
/// only then does the checker record the new count (track-6).
typedef NewEpisodeDelivery = Future<bool> Function(Subscription sub, int count);

/// Re-checks each subscribed show's source for new episodes or chapters
/// (CloudStream-style) and fires a notification when the count has grown. Uses
/// the SAME [SourceRepository.episodes] call the detail page uses, so it works
/// for JS, CS, and the reading sources — Mihon and LNReader return a chapter
/// list from the same method. Best-effort — a per-show failure is swallowed so one dead
/// source can't block the rest.
class SubscriptionChecker {
  SubscriptionChecker(this._repo, this._store, {NewEpisodeDelivery? deliver})
    : _deliver = deliver ?? deliverNewEpisode;

  /// The ROUTER, not the source repository.
  ///
  /// It dispatches on the url, so a `zm://` subscription reaches the metadata
  /// catalogue, which resolves the matched source itself. Asking
  /// [SourceRepository] directly threw `Provider not loaded: zm` for every
  /// metadata title — swallowed below, so the bell stored state and was then
  /// never checked again.
  final CatalogueRepository _repo;
  final SubscriptionStore _store;

  /// How a new episode reaches the user (tests pass a fake).
  final NewEpisodeDelivery _deliver;

  /// The sweep in progress, shared by overlapping callers.
  Future<int>? _inFlight;

  /// Runs one sweep. Returns how many shows were announced as having
  /// something new (the Notifications page uses it for its "nothing new"
  /// message). Never overlaps two sweeps: a call while one runs (e.g. Check
  /// now during the timer's sweep) waits for that sweep and gets its result,
  /// instead of a misleading 0.
  Future<int> checkAll() {
    final running = _inFlight;
    if (running != null) return running;
    final sweep = _sweep();
    _inFlight = sweep;
    // Cleared when done so the next call starts a fresh sweep.
    sweep.whenComplete(() => _inFlight = null).ignore();
    return sweep;
  }

  Future<int> _sweep() async {
    var announced = 0;
    for (final sub in _store.all()) {
      // CS sources are handled by the native background worker (it can run
      // while the app is closed); skip them here to avoid double alerts.
      if (sub.sourceId.startsWith('cs:')) continue;
      try {
        final eps = await _repo
            .episodes(sub.url, sourceId: sub.sourceId)
            .timeout(const Duration(seconds: 25));
        final count = eps.length;
        if (count <= 0) continue;
        if (count > sub.lastCount) {
          // Don't alert on the very first sweep after a fresh subscribe
          // (lastCount seeded to 0) — only announce a genuine increase. The
          // first count is just the baseline, so it is recorded silently.
          if (sub.lastCount <= 0) {
            await _store.setCount(sub.sourceId, sub.url, count);
            continue;
          }
          // Only remember the new count once someone was actually told.
          // Recording it without an alert (e.g. where alerts do not
          // exist) used the new episode up silently (track-6).
          if (await _deliver(sub, count)) {
            announced++;
            await _store.setCount(sub.sourceId, sub.url, count);
          }
        }
      } catch (e) {
        // Dead/slow source — skip; retried next sweep. Logged because a
        // subscription that silently never fires is undiagnosable: the
        // `zm` breakage above sat behind this exact catch.
        AppLogger.instance.log(
          '[notify] check failed · ${sub.sourceId} · ${sub.title} · $e',
        );
      }
    }
    return announced;
  }
}

/// The real delivery. On Windows the show always goes into the in-app
/// "New episodes" inbox (track-1, the bell badge) and, when enabled, a
/// Windows notification is raised too. Elsewhere it is the system alert
/// (Android), as before.
Future<bool> deliverNewEpisode(Subscription sub, int count) async {
  var delivered = false;
  if (defaultTargetPlatform == TargetPlatform.windows) {
    await addToNewEpisodeInbox(sub, count);
    delivered = true;
  }
  try {
    final alerted = await NotificationService.instance.showNewEpisode(
      id: sub.key.hashCode & 0x7fffffff,
      title: sub.title,
      episode: count,
      payload: '${sub.sourceId}|${sub.url}',
      reading: sub.isReading,
    );
    delivered = delivered || alerted;
  } catch (e) {
    // A failed alert must not lose the inbox entry above.
    AppLogger.instance.log('[notify] alert failed · ${sub.title} · $e');
  }
  return delivered;
}

/// Adds (or refreshes) the inbox entry for [sub] now at [count]. An entry
/// still unread for the same show keeps adding up, so "3 new" stays right
/// when episodes arrive across several checks.
@visibleForTesting
Future<void> addToNewEpisodeInbox(Subscription sub, int count) async {
  var added = count - sub.lastCount;
  for (final e in NewEpisodeInbox.entries) {
    if (!e.read && e.showId == sub.url && e.sourceId == sub.sourceId) {
      added += e.count;
    }
  }
  final now = DateTime.now();
  await NewEpisodeInbox.add(
    NewEpisodeEntry(
      // Short and unique: the inbox uses it as a Hive key (max 255 chars),
      // which a long source url could exceed.
      id: '${now.microsecondsSinceEpoch}-${sub.key.hashCode & 0x7fffffff}',
      showId: sub.url,
      sourceId: sub.sourceId,
      title: sub.title,
      mode: sub.mode.name,
      count: added < 1 ? 1 : added,
      cover: sub.cover,
      at: now,
    ),
  );
}
