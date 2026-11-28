import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/hive/safe_box.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/tracker/tracker.dart';
import 'package:watch_app/features/home/lists_hub_data.dart';
import 'package:watch_app/features/home/lists_hub_models.dart';

/// Tracker whose list, account and failures the test controls.
class _FakeTracker extends ChangeNotifier implements Tracker {
  _FakeTracker(this.displayName, {this.supportsReading = true});

  @override
  final String displayName;
  @override
  final bool supportsReading;

  String? viewer = 'alice';
  List<TrackerListItem> items = const [];
  Object? failWith;
  Completer<void>? gate;
  int fetches = 0;

  @override
  bool get isConnected => viewer != null;
  @override
  String? get viewerName => viewer;
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
  Future<List<TrackerListItem>> fetchList() async {
    fetches++;
    if (gate != null) await gate!.future;
    if (failWith != null) throw failWith!;
    return items;
  }

  @override
  Future<void> markWatching({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    MediaKind kind = MediaKind.anime,
  }) async {}

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
  }) async {}

  @override
  Future<void> setStatus({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    required WatchStatus status,
    MediaKind kind = MediaKind.anime,
  }) async {}

  @override
  Future<void> removeFromList({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    String? pinnedId,
    MediaKind kind = MediaKind.anime,
  }) async {}

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
  }) async {}

  @override
  Future<List<TrackerSearchResult>> searchEntries(
    String query, {
    MediaKind kind = MediaKind.anime,
  }) async => const [];

  @override
  Map<String, dynamic>? exportSession() => null;
  @override
  Future<void> importSession(Map<String, dynamic> session) async {}
}

TrackerListItem _entry(
  String title,
  ProviderType type,
  WatchStatus status, {
  int? updated,
  String? cover,
  int? malId,
}) => TrackerListItem(
  item: MediaItem(
    id: title,
    title: title,
    url: '',
    type: type,
    sourceId: '',
    cover: cover,
    malId: malId,
  ),
  status: status,
  updatedAt: updated == null ? null : DateTime.utc(2026, 1, updated),
);

HubListSummary _of(List<HubListSummary> s, ContentMode k) =>
    s.firstWhere((x) => x.kind == k);

void main() {
  late Directory dir;
  final now = DateTime(2026, 11, 17, 9);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('lists_hub_data_test');
    Hive.init(dir.path);
    hiveBoxDir = dir.path;
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    try {
      await dir.delete(recursive: true);
    } catch (_) {
      // Windows can briefly hold the handle; the temp dir is disposable.
    }
  });

  ListsHubDataImpl make(
    List<Tracker> trackers, {
    HubAiringFetcher? airing,
    String Function()? profile,
  }) => ListsHubDataImpl(
    trackers: () => trackers,
    airingToday: airing ?? ({required isOnYourList}) async => const [],
    currentProfileId: profile,
    clock: () => now,
  );

  test('counts per kind follow the list screen split', () async {
    final t = _FakeTracker('AniList')
      ..items = [
        _entry('A', ProviderType.anime, WatchStatus.watching),
        _entry('M', ProviderType.movie, WatchStatus.planning),
        _entry('B', ProviderType.anime, WatchStatus.completed),
        _entry('C', ProviderType.anime, WatchStatus.dropped),
        _entry('Mg', ProviderType.manga, WatchStatus.watching),
        _entry('Mg2', ProviderType.manga, WatchStatus.planning),
        _entry('N', ProviderType.novel, WatchStatus.completed),
      ];
    final data = make([t]);
    final s = await data.refreshSummaries(t);

    expect(s.map((x) => x.kind), [
      ContentMode.anime,
      ContentMode.manga,
      ContentMode.novel,
    ]);
    final anime = _of(s, ContentMode.anime);
    // Movies count under anime, as on the list screen's anime tab.
    expect([anime.active, anime.planned, anime.completed], [1, 1, 1]);
    final manga = _of(s, ContentMode.manga);
    expect([manga.active, manga.planned, manga.completed], [1, 1, 0]);
    final novel = _of(s, ContentMode.novel);
    expect([novel.active, novel.planned, novel.completed], [0, 0, 1]);
    expect(data.lastError, isNull);
    expect(data.lastUpdated, now);
  });

  test('video-only tracker gets only the anime tile', () async {
    final t = _FakeTracker('Simkl', supportsReading: false);
    final s = await make([t]).refreshSummaries(t);
    expect(s.map((x) => x.kind), [ContentMode.anime]);
  });

  test('covers: up to three, newest update first, undated last', () async {
    final t = _FakeTracker('AniList')
      ..items = [
        _entry('a', ProviderType.anime, WatchStatus.watching, cover: 'u0'),
        _entry(
          'b',
          ProviderType.anime,
          WatchStatus.watching,
          updated: 2,
          cover: 'u2',
        ),
        _entry(
          'c',
          ProviderType.anime,
          WatchStatus.watching,
          updated: 9,
          cover: 'u9',
        ),
        _entry('d', ProviderType.anime, WatchStatus.watching, updated: 20),
        _entry(
          'e',
          ProviderType.anime,
          WatchStatus.watching,
          updated: 5,
          cover: 'u5',
        ),
      ];
    final s = await make([t]).refreshSummaries(t);
    expect(_of(s, ContentMode.anime).covers, ['u9', 'u5', 'u2']);
  });

  test('cache round-trips through a fresh instance', () async {
    final t = _FakeTracker('AniList')
      ..items = [
        _entry('a', ProviderType.anime, WatchStatus.watching, cover: 'x'),
      ];
    final first = make([t]);
    await first.refreshSummaries(t);
    await Hive.close();

    final second = make([t]);
    expect(second.cachedSummaries(t), isNull, reason: 'box not open yet');
    await second.ensureLoaded();
    final cached = second.cachedSummaries(t)!;
    expect(_of(cached, ContentMode.anime).active, 1);
    expect(_of(cached, ContentMode.anime).covers, ['x']);
    expect(second.lastUpdated, now);
  });

  test('failed refresh keeps the cache and sets lastError', () async {
    final t = _FakeTracker('AniList')
      ..items = [_entry('a', ProviderType.anime, WatchStatus.watching)];
    final data = make([t]);
    await data.refreshSummaries(t);

    t.failWith = Exception('offline');
    final s = await data.refreshSummaries(t);
    expect(_of(s, ContentMode.anime).active, 1);
    expect(_of(data.cachedSummaries(t)!, ContentMode.anime).active, 1);
    expect(data.lastError, contains('offline'));

    // An empty read over a non-empty cache is treated as a failure too.
    t
      ..failWith = null
      ..items = const [];
    await data.refreshSummaries(t);
    expect(_of(data.cachedSummaries(t)!, ContentMode.anime).active, 1);
    expect(data.lastError, isNotNull);

    t.items = [_entry('b', ProviderType.anime, WatchStatus.planning)];
    await data.refreshSummaries(t);
    expect(data.lastError, isNull);
  });

  test('concurrent refreshes share one fetch', () async {
    final t = _FakeTracker('AniList')..gate = Completer<void>();
    final data = make([t]);
    await data.ensureLoaded();
    final a = data.refreshSummaries(t);
    final b = data.refreshSummaries(t);
    expect(identical(a, b), isTrue);
    t.gate!.complete();
    await Future.wait([a, b]);
    expect(t.fetches, 1);

    var airingCalls = 0;
    final gate = Completer<void>();
    final d2 = make(
      [t],
      airing: ({required isOnYourList}) async {
        airingCalls++;
        await gate.future;
        return const [];
      },
    );
    final x = d2.refreshAiringToday();
    final y = d2.refreshAiringToday();
    gate.complete();
    await Future.wait([x, y]);
    expect(airingCalls, 1);
  });

  test('scoped per tracker account and per profile', () async {
    var profile = 'default';
    final t = _FakeTracker('AniList')
      ..items = [_entry('a', ProviderType.anime, WatchStatus.watching)];
    final data = make([t], profile: () => profile);
    await data.refreshSummaries(t);
    expect(data.cachedSummaries(t), isNotNull);

    t.viewer = 'bob';
    expect(data.cachedSummaries(t), isNull, reason: 'other account');
    t.viewer = null;
    expect(data.cachedSummaries(t), isNull, reason: 'disconnected');
    expect(await data.refreshSummaries(t), isEmpty);

    t.viewer = 'alice';
    profile = 'kids';
    expect(data.cachedSummaries(t), isNull, reason: 'other profile');
    expect(data.lastUpdated, isNull);
    profile = 'default';
    expect(data.cachedSummaries(t), isNotNull);
  });

  test('airing: sorted, tagged from list, cached per day', () async {
    final t = _FakeTracker('AniList')
      ..items = [
        _entry('Frieren', ProviderType.anime, WatchStatus.watching, malId: 7),
        _entry('Dandadan', ProviderType.anime, WatchStatus.planning),
      ];
    List<HubAiringItem> rows(bool Function(MediaItem, String) on) {
      MediaItem m(String title, {int? mal}) => MediaItem(
        id: title,
        title: title,
        url: '',
        type: ProviderType.anime,
        sourceId: '',
        malId: mal,
      );
      HubAiringItem row(String title, int hour, {int? mal}) => HubAiringItem(
        title: title,
        episode: 3,
        airingAt: DateTime(2026, 11, 17, hour),
        item: m('$title (catalogue)', mal: mal),
        onYourList: on(m('$title (catalogue)', mal: mal), title),
      );
      return [
        row('Late show', 22),
        row('Sousou no Frieren', 18, mal: 7),
        row('DAN DA DAN', 12),
      ];
    }

    var fail = false;
    final data = make(
      [t],
      airing: ({required isOnYourList}) async {
        if (fail) throw Exception('down');
        return rows(isOnYourList);
      },
    );
    final got = await data.refreshAiringToday();
    expect(t.fetches, 1, reason: 'list index loaded before tagging');
    expect(got.map((r) => r.title), [
      'DAN DA DAN',
      'Sousou no Frieren',
      'Late show',
    ]);
    expect(got.map((r) => r.onYourList), [true, true, false]);

    final cached = data.cachedAiringToday()!;
    expect(cached.map((r) => r.onYourList), [true, true, false]);
    expect(cached[1].item?.malId, 7);

    // Another account: tags are recomputed, never read back from cache.
    t.viewer = 'bob';
    expect(data.cachedAiringToday()!.any((r) => r.onYourList), isFalse);
    t.viewer = 'alice';

    fail = true;
    final kept = await data.refreshAiringToday();
    expect(kept, hasLength(3));
    expect(data.lastError, contains('down'));
  });

  test('account switch mid-fetch never saves under the old account', () async {
    final t = _FakeTracker('AniList')
      ..items = [_entry('a', ProviderType.anime, WatchStatus.watching)];
    final data = make([t]);
    await data.ensureLoaded();
    t.gate = Completer<void>();
    final pending = data.refreshSummaries(t);
    // Bob signs in while Alice's read is in flight; the read returns Bob's.
    t
      ..viewer = 'bob'
      ..items = [
        _entry('b1', ProviderType.anime, WatchStatus.watching),
        _entry('b2', ProviderType.anime, WatchStatus.watching),
      ];
    t.gate!.complete();
    final got = await pending;
    // Re-read for Bob and saved under Bob, never under Alice.
    expect(_of(got, ContentMode.anime).active, 2);
    expect(_of(data.cachedSummaries(t)!, ContentMode.anime).active, 2);
    t.viewer = 'alice';
    expect(data.cachedSummaries(t), isNull, reason: "Bob's list not saved");
  });

  test('hung fetches time out and keep the cache', () async {
    final t = _FakeTracker('AniList')
      ..items = [_entry('a', ProviderType.anime, WatchStatus.watching)];
    final data = ListsHubDataImpl(
      trackers: () => [t],
      airingToday: ({required isOnYourList}) => Completer<
        List<HubAiringItem>
      >().future,
      clock: () => now,
      fetchTimeout: const Duration(milliseconds: 50),
      airingTimeout: const Duration(milliseconds: 50),
    );
    await data.refreshSummaries(t);
    t.gate = Completer<void>(); // never completes
    final s = await data.refreshSummaries(t);
    expect(_of(s, ContentMode.anime).active, 1);
    expect(data.lastError, contains('TimeoutException'));
    expect(await data.refreshAiringToday(), isEmpty);
  });

  test('error of a disconnected account no longer counts', () async {
    final t = _FakeTracker('AniList')..failWith = Exception('boom');
    final data = make([t]);
    await data.refreshSummaries(t);
    expect(data.lastError, contains('boom'));
    t.viewer = null;
    expect(data.lastError, isNull);
  });

  test('live-action entry with the same title does not tag the anime', () async {
    final t = _FakeTracker('Simkl', supportsReading: false)
      ..items = [_entry('One Piece', ProviderType.movie, WatchStatus.watching)];
    final data = make(
      [t],
      airing: ({required isOnYourList}) async {
        final m = MediaItem(
          id: 'x',
          title: 'ONE PIECE',
          url: '',
          type: ProviderType.anime,
          sourceId: '',
          malId: 21,
        );
        return [
          HubAiringItem(
            title: 'ONE PIECE',
            episode: 1100,
            airingAt: DateTime(2026, 11, 17, 10),
            item: m,
            onYourList: isOnYourList(m, 'ONE PIECE'),
          ),
        ];
      },
    );
    final rows = await data.refreshAiringToday();
    expect(rows.single.onYourList, isFalse);
    expect(data.cachedAiringToday()!.single.onYourList, isFalse);
  });

  test('romaji alt title (englishTitle) matches a romaji list entry', () async {
    final t = _FakeTracker('AniList')
      ..items = [
        _entry('Sousou no Frieren', ProviderType.anime, WatchStatus.watching),
      ];
    final data = make(
      [t],
      airing: ({required isOnYourList}) async {
        final m = MediaItem(
          id: 'mal:1',
          title: "Frieren: Beyond Journey's End",
          englishTitle: 'Sousou no Frieren',
          url: '',
          type: ProviderType.anime,
          sourceId: '',
          malId: 1,
        );
        return [
          HubAiringItem(
            title: m.title,
            episode: 2,
            airingAt: DateTime(2026, 11, 17, 10),
            item: m,
            onYourList: isOnYourList(m, m.title),
          ),
        ];
      },
    );
    expect((await data.refreshAiringToday()).single.onYourList, isTrue);
    expect(data.cachedAiringToday()!.single.onYourList, isTrue);
  });

  test('box closed elsewhere is reopened instead of throwing', () async {
    final t = _FakeTracker('AniList')
      ..items = [_entry('a', ProviderType.anime, WatchStatus.watching)];
    final data = make([t]);
    await data.refreshSummaries(t);
    await Hive.close();
    expect(data.cachedSummaries(t), isNull);
    await data.ensureLoaded();
    expect(data.cachedSummaries(t), isNotNull);
  });

  test('airing cache from another day is not shown', () async {
    var clock = DateTime(2026, 11, 16, 23);
    final data = ListsHubDataImpl(
      trackers: () => const [],
      airingToday: ({required isOnYourList}) async => [
        HubAiringItem(title: 'x', episode: 1, airingAt: clock),
      ],
      clock: () => clock,
    );
    await data.refreshAiringToday();
    expect(data.cachedAiringToday(), hasLength(1));
    clock = DateTime(2026, 11, 17, 1);
    expect(data.cachedAiringToday(), isNull);
  });
}
