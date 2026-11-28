import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/download/download_record.dart';
import 'package:watch_app/core/download/download_source_search.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/playback/source_health_store.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/zmode/match_store.dart';
import 'package:watch_app/core/zmode/playback_resolver.dart';
import 'package:watch_app/core/zmode/source_matcher.dart';
import 'package:watch_app/core/zmode/zmode_source_prefs.dart';

const _ep2 = 'zm://anime/mal:100/ep/2';
const _bLink = VideoSource(url: 'https://b/stream.mp4', label: 'B server');

/// `src-a` (the preferred/matched source) never answers its episode list;
/// `src-b` has episode 2 and links for it.
class _HangingPreferred implements SourceRepository {
  final hang = Completer<List<Episode>>();

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  List<({String id, String name})> get loadedSources => [
    (id: 'src-a', name: 'Anikoto'),
    (id: 'src-b', name: 'Backup'),
  ];

  @override
  List<({String id, String name})> get pickableSources => loadedSources;

  @override
  bool hasSource(String sourceId) => true;

  @override
  Future<bool> ensureSourceLoaded(String sourceId) async => true;

  @override
  String displayName(String sourceId) =>
      sourceId == 'src-a' ? 'Anikoto' : 'Backup';

  @override
  Future<List<MediaItem>> search(
    String q, {
    String category = 'sub',
    String? sourceId,
  }) async => [
    MediaItem(
      id: sourceId!,
      title: 'FMA',
      url: 'https://$sourceId/show',
      type: ProviderType.anime,
      sourceId: sourceId,
    ),
  ];

  @override
  Future<List<Episode>> episodes(
    String url, {
    String category = 'sub',
    String? sourceId,
  }) async {
    if (sourceId == 'src-a') return hang.future;
    return const [
      Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://b/1'),
      Episode(id: '2', title: 'Ep 2', number: 2, url: 'https://b/2'),
    ];
  }

  @override
  Future<List<VideoSource>> sources(
    String episodeUrl, {
    String? sourceId,
    bool fast = false,
  }) async => sourceId == 'src-b' ? const [_bLink] : const [];
}

DownloadSourceCandidate _c(String id, {int ms = 200, bool serial = false}) =>
    DownloadSourceCandidate(
      id: id,
      name: id,
      budget: Duration(milliseconds: ms),
      serial: serial,
    );

void main() {
  group('searchDownloadSources', () {
    test(
      'a hanging preferred source cannot hide a second source\'s links',
      () async {
        final snapshots = <List<DownloadSourceStatus>>[];
        await searchDownloadSources(
          candidates: [_c('pref'), _c('other')],
          attempt: (id) => id == 'pref'
              ? Completer<DownloadSourceHit?>()
                    .future // never answers
              : Future.value(const DownloadSourceHit(streams: [_bLink])),
          wallClock: const Duration(seconds: 2),
        ).forEach(snapshots.add);

        // The second source's links arrive while the preferred one is still
        // being tried — results stream in, nobody waits for the slowest.
        final firstFound = snapshots.firstWhere(
          (s) => s[1].phase == DownloadSourcePhase.found,
        );
        expect(firstFound[0].phase, DownloadSourcePhase.trying);
        // And the search ends, with the hung source reported as timed out.
        expect(snapshots.last[0].phase, DownloadSourcePhase.timedOut);
        expect(snapshots.last[1].streams, [_bLink]);
      },
    );

    test('total failure still ends, every row settled', () async {
      final last = await searchDownloadSources(
        candidates: [
          _c('a'),
          _c('b'),
          const DownloadSourceCandidate(
            id: 'cf',
            name: 'cf',
            budget: Duration(seconds: 1),
            skipReason: 'Cloudflare check needed',
          ),
        ],
        attempt: (id) =>
            id == 'a' ? Future.value(null) : Future.error(StateError('down')),
      ).last;
      expect(last.map((r) => r.phase), [
        DownloadSourcePhase.empty,
        DownloadSourcePhase.failed,
        DownloadSourcePhase.skipped,
      ]);
      expect(last.every((r) => r.settled), isTrue);
    });

    test('wall clock ends a search whose sources never answer', () async {
      final sw = Stopwatch()..start();
      final last = await searchDownloadSources(
        candidates: [_c('a', ms: 60000), _c('b', ms: 60000)],
        attempt: (_) => Completer<DownloadSourceHit?>().future,
        wallClock: const Duration(milliseconds: 150),
      ).last;
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
      expect(
        last.map((r) => r.phase),
        everyElement(DownloadSourcePhase.timedOut),
      );
    });

    test(
      'serial sources are asked one at a time; cancel stops new asks',
      () async {
        final asked = <String>[];
        final gate = Completer<DownloadSourceHit?>();
        final sub = searchDownloadSources(
          candidates: [
            _c('js1', serial: true, ms: 5000),
            _c('js2', serial: true, ms: 5000),
          ],
          attempt: (id) {
            asked.add(id);
            return gate.future;
          },
        ).listen((_) {});
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(asked, ['js1']);
        await sub.cancel();
        gate.complete(const DownloadSourceHit(streams: [_bLink]));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(asked, ['js1']);
      },
    );
  });

  group('Z-mode fallback chain for downloads', () {
    late Directory dir;
    late MatchStore store;
    late ZSourcePrefs prefs;
    late SourceHealthStore health;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('download-search');
      Hive.init(dir.path);
      await SourceHealthStore.init();
      health = SourceHealthStore();
      store = await MatchStore.open();
      prefs = await ZSourcePrefs.open();
    });

    tearDown(() async {
      await Hive.close();
      await dir.delete(recursive: true);
    });

    PlaybackResolver build(_HangingPreferred src) {
      final matcher = SourceMatcher(
        sources: src,
        store: store,
        prefs: prefs,
        candidates: (_) => src.loadedSources,
      );
      return PlaybackResolver(
        matcher: matcher,
        sources: src,
        store: store,
        prefs: prefs,
        health: health,
        candidates: (_) => src.loadedSources,
        perSourceBudget: const Duration(milliseconds: 150),
        relaxedBudget: const Duration(milliseconds: 150),
        chosenBudget: const Duration(milliseconds: 150),
        companionBudget: const Duration(milliseconds: 150),
      )..bindTitleLookup((_) async => (title: 'FMA', alt: null, malId: 100));
    }

    test(
      'preferred source first; the fallback answers with its own ids',
      () async {
        final src = _HangingPreferred();
        final r = build(src);
        final cands = r.downloadCandidates(_ep2, preferred: 'src-b');
        // The show page's matched source is asked first.
        expect(cands.map((c) => c.id), ['src-b', 'src-a']);

        final ordered = r.downloadCandidates(_ep2, preferred: 'src-a');
        final last = await searchDownloadSources(
          candidates: [
            for (final c in ordered)
              DownloadSourceCandidate(id: c.id, name: c.name, budget: c.budget),
          ],
          attempt: (id) async {
            final a = await r.attemptForDownload(_ep2, id);
            return a == null
                ? null
                : DownloadSourceHit(
                    streams: a.streams,
                    episodeUrl: a.episodeUrl,
                    showUrl: a.showUrl,
                  );
          },
        ).last;
        expect(last[0].sourceId, 'src-a');
        expect(last[0].phase, DownloadSourcePhase.timedOut);
        expect(last[1].sourceId, 'src-b');
        expect(last[1].phase, DownloadSourcePhase.found);
        expect(last[1].streams, [_bLink]);
        expect(last[1].episodeUrl, 'https://b/2');
        expect(last[1].showUrl, 'https://src-b/show');
      },
    );

    test('sourcesFrom on a hung source returns within its budget', () async {
      final r = build(_HangingPreferred());
      final got = await r
          .sourcesFrom(_ep2, 'src-a')
          .timeout(const Duration(seconds: 5));
      expect(got, isEmpty);
    });
  });

  test('picked resolve source survives a record round trip', () {
    const rec = DownloadRecord(
      id: 'x',
      sourceId: 'zm',
      showId: 's',
      showTitle: 'Show',
      showUrl: 'zm://anime/mal:100',
      episodeId: 'e2',
      episodeUrl: _ep2,
      episodeTitle: 'Ep 2',
      category: 'sub',
      quality: 'best',
      resolveSourceId: 'src-b',
      createdAt: 0,
    );
    final back = DownloadRecord.fromMap(rec.toMap());
    expect(back.resolveSourceId, 'src-b');
    expect(back.copyWith(progress: .5).resolveSourceId, 'src-b');
    expect(
      DownloadRecord.fromMap(
        {...rec.toMap()}..remove('resolveSourceId'),
      ).resolveSourceId,
      isNull,
    );
  });
}
