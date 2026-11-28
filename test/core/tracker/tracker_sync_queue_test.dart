import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/boot_network.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/tracker/tracker.dart';
import 'package:watch_app/core/tracker/tracker_hub.dart';
import 'package:watch_app/core/tracker/tracker_sync_queue.dart';

/// Tracker fake whose writes report the outcome [next] to the sync outbox,
/// the way the real services do, and count what reached it.
class _FakeTracker extends ChangeNotifier implements Tracker {
  _FakeTracker(this.displayName);

  @override
  final String displayName;

  /// Problem the next writes report; null = accepted.
  TrackerWriteProblem? next;
  final List<String> calls = [];

  void _write(String call) {
    calls.add(call);
    final p = next;
    if (p == null) {
      TrackerWriteScope.reportSent();
    } else {
      TrackerWriteScope.report(p, 'fake ${p.name}');
    }
  }

  @override
  bool get supportsReading => true;
  /// Flipped by tests to simulate a sign-out or an expired login.
  bool connected = true;

  /// Simulated "login expired" (AniList) vs a real sign-out.
  bool expired = false;

  @override
  bool get isConnected => connected;
  @override
  String? get viewerName => 'someone';
  @override
  String? get viewerAvatar => null;
  @override
  bool get autoSync => true;
  @override
  set autoSync(bool value) {}
  @override
  Future<bool> connect() async => true;
  @override
  Future<void> disconnect() async {}

  @override
  Future<void> markWatching({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    MediaKind kind = MediaKind.anime,
  }) async => _write('watching');

  @override
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
  }) async => _write('scrobble:$episode');

  @override
  Future<void> setStatus({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    required WatchStatus status,
    MediaKind kind = MediaKind.anime,
  }) async => _write('status:${status.name}');

  @override
  Future<void> removeFromList({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    String? pinnedId,
    MediaKind kind = MediaKind.anime,
  }) async => _write('remove');

  @override
  Future<TrackerEntry?> fetchEntry({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    String? pinnedId,
    MediaKind kind = MediaKind.anime,
    bool novel = false,
  }) async => null;

  @override
  Future<void> updateEntry({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    String? pinnedId,
    WatchStatus? status,
    double? score,
    int? progress,
    bool? isPrivate,
    MediaKind kind = MediaKind.anime,
  }) async => _write('update');

  @override
  Future<List<TrackerSearchResult>> searchEntries(
    String query, {
    MediaKind kind = MediaKind.anime,
  }) async => const [];

  @override
  Future<List<TrackerListItem>> fetchList() async => const [];

  @override
  Map<String, dynamic>? exportSession() => null;

  @override
  Future<void> importSession(Map<String, dynamic> session) async {}
}

void main() {
  late _FakeTracker mal;
  late TrackerSyncQueue queue;
  late TrackerHub hub;
  late List<String> notices;

  setUp(() {
    BootConnectivity.instance.offline.value = false;
    mal = _FakeTracker('MyAnimeList');
    notices = [];
    // In-memory queue (no Hive) with the notice captured.
    queue = TrackerSyncQueue(persist: false, notice: notices.add);
    hub = TrackerHub([mal], syncQueue: queue);
  });

  tearDown(() {
    queue.debugDetach();
    BootConnectivity.instance.offline.value = false;
  });

  test('a failed scrobble is queued, noticed once, and sent on retry', () async {
    mal.next = TrackerWriteProblem.network;
    await hub.scrobble(malId: 1, episode: 3);
    await hub.scrobble(malId: 1, episode: 4);

    // One entry per title, keeping the newest (highest) episode.
    expect(queue.entries, hasLength(1));
    expect(queue.entries.single.args['episode'], 4);
    expect(queue.healthOf('MyAnimeList').failed, isTrue);
    expect(notices, hasLength(1));

    // Connection is back: the retry sends it and clears the failure.
    mal.next = null;
    await queue.flush();
    expect(mal.calls.last, 'scrobble:4');
    expect(queue.entries, isEmpty);
    expect(queue.healthOf('MyAnimeList').failed, isFalse);
  });

  test('a lower episode never replaces a queued higher one', () async {
    mal.next = TrackerWriteProblem.network;
    await hub.scrobble(malId: 1, episode: 7);
    await hub.scrobble(malId: 1, episode: 2);
    expect(queue.entries.single.args['episode'], 7);
  });

  test('dead login marks needs sign-in and waits for a reconnect', () async {
    mal.next = TrackerWriteProblem.auth;
    await hub.setStatus(malId: 9, status: WatchStatus.completed);
    expect(queue.healthOf('MyAnimeList').needsSignIn, isTrue);
    expect(queue.entries, hasLength(1));
    expect(notices.single, contains('sign in again'));

    // Automatic retries skip it while the login is dead.
    mal.calls.clear();
    await queue.flush();
    expect(mal.calls, isEmpty);

    // After the user reconnects, the waiting write goes out.
    mal.next = null;
    await queue.signedInAgain('MyAnimeList');
    expect(mal.calls, ['status:completed']);
    expect(queue.entries, isEmpty);
    expect(queue.healthOf('MyAnimeList').needsSignIn, isFalse);
  });

  test('a refused write is recorded but not retried', () async {
    mal.next = TrackerWriteProblem.rejected;
    await hub.markWatching(malId: 5);
    expect(queue.entries, isEmpty);
    expect(queue.healthOf('MyAnimeList').failed, isTrue);
  });

  test('known offline: queued without calling the tracker', () async {
    BootConnectivity.instance.offline.value = true;
    await hub.scrobble(malId: 2, episode: 1);
    expect(mal.calls, isEmpty);
    expect(queue.entries, hasLength(1));
    // No retry while still offline.
    await queue.flush();
    expect(mal.calls, isEmpty);
  });

  test('a newer successful write drops the superseded queued one', () async {
    mal.next = TrackerWriteProblem.network;
    await hub.setStatus(malId: 4, status: WatchStatus.watching);
    expect(queue.entries, hasLength(1));
    mal.next = null;
    await hub.removeFromList(malId: 4);
    expect(queue.entries, isEmpty);
  });

  test('supersede rules', () {
    final a = TrackerSyncArgs.pack(malId: 1);
    // Removal replaces everything, and any later write replaces a removal.
    expect(
      TrackerSyncQueue.supersedes(
        TrackerSyncOp.removeFromList,
        a,
        TrackerSyncOp.scrobble,
        a,
      ),
      isTrue,
    );
    expect(
      TrackerSyncQueue.supersedes(
        TrackerSyncOp.setStatus,
        a,
        TrackerSyncOp.removeFromList,
        a,
      ),
      isTrue,
    );
    // A status change doesn't replace a pending progress update.
    expect(
      TrackerSyncQueue.supersedes(
        TrackerSyncOp.setStatus,
        a,
        TrackerSyncOp.scrobble,
        a,
      ),
      isFalse,
    );
    // Same title key across args with the same id.
    expect(
      TrackerSyncArgs.titleKey(TrackerSyncArgs.pack(malId: 1, title: 'X')),
      TrackerSyncArgs.titleKey(TrackerSyncArgs.pack(malId: 1)),
    );
  });

  test('entries survive a JSON round trip (stored in Hive)', () {
    final e = TrackerSyncEntry(
      id: '1',
      tracker: 'Simkl',
      op: TrackerSyncOp.updateEntry,
      args: TrackerSyncArgs.pack(tmdbId: 7, tmdbIsTv: true, score: 8),
      createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
    );
    final back = TrackerSyncEntry.fromJson(e.toJson())!;
    expect(back.op, TrackerSyncOp.updateEntry);
    expect(back.args['tmdbIsTv'], isTrue);
    expect(back.titleKey, e.titleKey);
  });

  test('no queue (phone): failures stay swallowed as before', () async {
    final plain = TrackerHub([mal]);
    mal.next = TrackerWriteProblem.network;
    await plain.scrobble(malId: 1, episode: 1);
    expect(plain.syncQueue, isNull);
    expect(mal.calls, ['scrobble:1']);
  });

  // A real sign-out drops the waiting writes; an expired login keeps them
  // for after the reconnect.
  test('sign-out drops the queue, an expired login keeps it', () async {
    final other = _FakeTracker('AniList');
    final q = TrackerSyncQueue(persist: false, notice: notices.add);
    final h = TrackerHub([mal, other], syncQueue: q);
    // Re-attach with the fake's own "expired" flag as the predicate.
    q.debugDetach();
    q.attach(h.trackers, loginExpired: (t) => (t as _FakeTracker).expired);
    mal.next = TrackerWriteProblem.network;
    other.next = TrackerWriteProblem.network;
    await h.scrobble(malId: 1, episode: 1);
    expect(q.pendingFor('MyAnimeList'), 1);
    expect(q.pendingFor('AniList'), 1);

    // AniList's token expires; a later notify (e.g. an auto-sync toggle)
    // must not be read as a sign-out.
    other
      ..connected = false
      ..expired = true
      ..notifyListeners();
    // MyAnimeList is really disconnected.
    mal
      ..connected = false
      ..notifyListeners();
    await Future<void>.delayed(Duration.zero);
    expect(q.pendingFor('AniList'), 1);
    expect(q.pendingFor('MyAnimeList'), 0);
    q.debugDetach();
  });
}
