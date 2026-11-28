// Windows: the download search gives Aniyomi sources the call gate's own
// limit (70 s) instead of 20 s, because time spent waiting for a gate slot
// counted against them and the dialog said "No source had this episode"
// while Anikoto was still answering. Other sources, and phone/TV, unchanged.
import 'dart:async';
import 'dart:io';

// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/aniyomi/aniyomi_call_gate.dart';
import 'package:watch_app/core/boot_network.dart';
import 'package:watch_app/core/download/download_source_search.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/playback/source_health_store.dart';
import 'package:watch_app/core/provider/js_engine.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/zmode/match_store.dart';
import 'package:watch_app/core/zmode/playback_resolver.dart';
import 'package:watch_app/core/zmode/source_matcher.dart';
import 'package:watch_app/core/zmode/zmode_source_prefs.dart';

/// Just enough of a source list for the resolver to be built.
class _Src implements SourceRepository {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  List<({String id, String name})> get loadedSources => const [
    (id: 'ani:1', name: 'Anikoto'),
    (id: 'ani:2', name: 'Aniyomi two'),
    (id: 'cs:MovieBox', name: 'MovieBox'),
  ];

  @override
  List<({String id, String name})> get pickableSources => loadedSources;

  @override
  bool hasSource(String sourceId) => true;

  @override
  String displayName(String sourceId) => sourceId;
}

void main() {
  late Directory dir;
  late MatchStore store;
  late ZSourcePrefs prefs;
  late SourceHealthStore health;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ani-dl-budget');
    Hive.init(dir.path);
    await SourceHealthStore.init();
    health = SourceHealthStore();
    store = await MatchStore.open();
    prefs = await ZSourcePrefs.open();
    JsEngine.debugRunsOffUiIsolateOverride = true;
    PlaybackResolver.debugResetNetworkWatch();
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    JsEngine.debugRunsOffUiIsolateOverride = null;
    BootConnectivity.instance.offline.value = false;
    PlaybackResolver.debugResetNetworkWatch();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  PlaybackResolver build() {
    final src = _Src();
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
    );
  }

  test('the download limits are the gate limit and 150 s overall', () {
    expect(
      PlaybackResolver.downloadAniyomiBudget,
      AniyomiCallGate.defaultCallTimeout,
    );
    expect(
      PlaybackResolver.downloadAniyomiWallClock,
      const Duration(seconds: 150),
    );
  });

  test('Windows: Aniyomi download candidates get the gate limit', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final dl = build().downloadCandidates(
      'zm://anime/mal:100/ep/1',
      preferred: 'ani:2',
    );
    // The preferred (chosen) one and the plain one alike.
    for (final id in ['ani:1', 'ani:2']) {
      expect(
        dl.singleWhere((c) => c.id == id).budget,
        PlaybackResolver.downloadAniyomiBudget,
        reason: id,
      );
    }
    expect(PlaybackResolver.usesDownloadAniyomiBudget('ani:1'), isTrue);
    expect(PlaybackResolver.usesDownloadAniyomiBudget('cs:MovieBox'), isFalse);
  });

  test(
    'Windows: a CloudStream download candidate keeps its own 75 s',
    () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final dl = build().downloadCandidates('zm://anime/mal:100/ep/1');
      expect(
        dl.singleWhere((c) => c.id == 'cs:MovieBox').budget,
        const Duration(seconds: 75),
      );
    },
    // The CloudStream branch reads dart:io's Platform.
    skip: Platform.isWindows ? false : 'needs a Windows host',
  );

  test('Android: Aniyomi download candidates keep the playback budget', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final r = build();
    final dl = r.downloadCandidates('zm://anime/mal:100/ep/1');
    expect(
      dl.singleWhere((c) => c.id == 'ani:1').budget,
      r.debugBudgetFor('ani:1', fast: false),
    );
    expect(PlaybackResolver.usesDownloadAniyomiBudget('ani:1'), isFalse);
  });

  group('queued in the gate (fake time)', () {
    // Two gate slots, three Aniyomi sources asked at once, each call takes
    // 30 s once it has a slot. The third waits 30 s for a slot, then runs
    // 30 s: it answers 60 s after the search asked it.
    List<DownloadSourceStatus> run(Duration budget) {
      late List<DownloadSourceStatus> last;
      fakeAsync((async) {
        final gate = AniyomiCallGate();
        final search = searchDownloadSources(
          candidates: [
            for (final id in ['ani:1', 'ani:2', 'ani:3'])
              DownloadSourceCandidate(id: id, name: id, budget: budget),
          ],
          // Only ani:3 has the episode, like the one Anikoto mirror that
          // answers after the others came up empty.
          attempt: (id) => gate
              .run('getVideoList|$id', () async {
                await Future<void>.delayed(const Duration(seconds: 30));
                return id == 'ani:3' ? 'links' : null;
              })
              .then(
                (r) => r == null
                    ? null
                    : const DownloadSourceHit(
                        streams: [VideoSource(url: 'https://a/ep1.mp4')],
                      ),
              ),
          wallClock: PlaybackResolver.downloadAniyomiWallClock,
        );
        search.listen((rows) => last = rows);
        async.elapse(const Duration(seconds: 200));
      });
      return last;
    }

    test('the old 20 s limit threw the queued source away', () {
      final rows = run(PlaybackResolver.relaxedPerSourceBudget);
      expect(rows.last.phase, DownloadSourcePhase.timedOut);
      expect(rows.where((r) => r.phase == DownloadSourcePhase.found), isEmpty);
    });

    test('the gate limit waits the queue out and finds the links', () {
      final rows = run(PlaybackResolver.downloadAniyomiBudget);
      expect(rows[0].phase, DownloadSourcePhase.empty);
      expect(rows[1].phase, DownloadSourcePhase.empty);
      expect(rows[2].phase, DownloadSourcePhase.found);
    });
  });

  test('Windows: Aniyomi candidates free their worker and may be extended', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final r = build();
    final dl = r.downloadCandidates('zm://anime/mal:100/ep/1');
    final ani = dl.singleWhere((c) => c.id == 'ani:1');
    expect(ani.freeWorkerAfter, r.debugBudgetFor('ani:1', fast: false));
    expect(ani.extendIf, isNotNull);
    final cs = dl.singleWhere((c) => c.id == 'cs:MovieBox');
    expect(cs.freeWorkerAfter, isNull);
    expect(cs.extendIf, isNull);
  });

  group('shared workers (fake time)', () {
    // The Re:ZERO case: three Aniyomi sources fill the three workers, and
    // the gate hangs, so none of them answers. MovieBox, behind them, has
    // the episode.
    ({Duration? movieBoxAskedAt, List<DownloadSourceStatus> rows}) run({
      Duration? freeWorkerAfter,
    }) {
      Duration? askedAt;
      late List<DownloadSourceStatus> last;
      fakeAsync((async) {
        final start = async.elapsed;
        final search = searchDownloadSources(
          candidates: [
            for (final id in ['ani:1', 'ani:2', 'ani:3'])
              DownloadSourceCandidate(
                id: id,
                name: id,
                budget: PlaybackResolver.downloadAniyomiBudget,
                freeWorkerAfter: freeWorkerAfter,
              ),
            const DownloadSourceCandidate(
              id: 'cs:MovieBox',
              name: 'MovieBox',
              budget: Duration(seconds: 75),
            ),
          ],
          attempt: (id) {
            if (id.startsWith('ani:')) {
              return Completer<DownloadSourceHit?>().future; // hangs
            }
            askedAt = async.elapsed - start;
            return Future<DownloadSourceHit?>.delayed(
              const Duration(seconds: 2),
              () => const DownloadSourceHit(
                streams: [VideoSource(url: 'https://m/ep1.mp4')],
              ),
            );
          },
          wallClock: PlaybackResolver.downloadAniyomiWallClock,
        );
        search.listen((rows) => last = rows);
        async.elapse(const Duration(seconds: 200));
      });
      return (movieBoxAskedAt: askedAt, rows: last);
    }

    test('without freeing, MovieBox waited for the 70 s Aniyomi limit', () {
      final r = run();
      expect(r.movieBoxAskedAt, PlaybackResolver.downloadAniyomiBudget);
    });

    test('with freeing, MovieBox is asked at 20 s as before', () {
      final r = run(freeWorkerAfter: PlaybackResolver.relaxedPerSourceBudget);
      expect(r.movieBoxAskedAt, PlaybackResolver.relaxedPerSourceBudget);
      expect(r.rows[3].phase, DownloadSourcePhase.found);
      // The Aniyomi asks still ran their whole limit before timing out.
      expect(r.rows.take(3).map((x) => x.phase).toSet(), {
        DownloadSourcePhase.timedOut,
      });
    });

    test('an Aniyomi answer after its worker moved on is still taken', () {
      late List<DownloadSourceStatus> last;
      fakeAsync((async) {
        searchDownloadSources(
          candidates: [
            DownloadSourceCandidate(
              id: 'ani:1',
              name: 'ani:1',
              budget: PlaybackResolver.downloadAniyomiBudget,
              freeWorkerAfter: PlaybackResolver.relaxedPerSourceBudget,
            ),
            const DownloadSourceCandidate(
              id: 'cs:x',
              name: 'x',
              budget: Duration(seconds: 75),
            ),
          ],
          parallel: 1,
          attempt: (id) => id == 'cs:x'
              ? Future<DownloadSourceHit?>.value(null)
              : Future<DownloadSourceHit?>.delayed(
                  const Duration(seconds: 50),
                  () => const DownloadSourceHit(
                    streams: [VideoSource(url: 'https://a/ep1.mp4')],
                  ),
                ),
          wallClock: PlaybackResolver.downloadAniyomiWallClock,
        ).listen((rows) => last = rows);
        async.elapse(const Duration(seconds: 200));
      });
      expect(last[0].phase, DownloadSourcePhase.found);
      expect(last[1].phase, DownloadSourcePhase.empty);
    });
  });

  group('two gated calls in a row (fake time)', () {
    // A busy gate: two other calls hold both slots for 60 s. The dialog's
    // ask waits for a slot, then needs an episode list (30 s) and a video
    // list (30 s), each through the gate. It answers 120 s after it was
    // asked, past one 70 s limit.
    List<DownloadSourceStatus> run({required bool extend}) {
      late List<DownloadSourceStatus> last;
      fakeAsync((async) {
        final clock = async.getClock(DateTime(2026));
        final gate = AniyomiCallGate(now: clock.now);
        for (final k in ['busy1', 'busy2']) {
          unawaited(
            gate.run(k, () async {
              await Future<void>.delayed(const Duration(seconds: 60));
              return null;
            }),
          );
        }
        final askedFrom = clock.now();
        searchDownloadSources(
          candidates: [
            DownloadSourceCandidate(
              id: 'ani:1',
              name: 'ani:1',
              budget: PlaybackResolver.downloadAniyomiBudget,
              extendIf: extend ? (at) => gate.queuedSince(askedFrom) : null,
            ),
          ],
          attempt: (id) async {
            await gate.run('getEpisodes|$id', () async {
              await Future<void>.delayed(const Duration(seconds: 30));
              return 'eps';
            });
            final links = await gate.run('getVideoList|$id', () async {
              await Future<void>.delayed(const Duration(seconds: 30));
              return 'links';
            });
            return links == null
                ? null
                : const DownloadSourceHit(
                    streams: [VideoSource(url: 'https://a/ep1.mp4')],
                  );
          },
          wallClock: PlaybackResolver.downloadAniyomiWallClock,
        ).listen((rows) => last = rows);
        async.elapse(const Duration(seconds: 200));
      });
      return last;
    }

    test('one 70 s limit still cut a queued two-call ask off', () {
      expect(run(extend: false).single.phase, DownloadSourcePhase.timedOut);
    });

    test('one more limit while the gate was queueing finds the links', () {
      expect(run(extend: true).single.phase, DownloadSourcePhase.found);
    });
  });
}
