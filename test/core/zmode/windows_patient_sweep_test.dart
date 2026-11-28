import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/aniyomi/aniyomi_call_gate.dart';
import 'package:watch_app/core/boot_network.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/playback/source_health_store.dart';
import 'package:watch_app/core/provider/js_engine.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/zmode/match_store.dart';
import 'package:watch_app/core/zmode/playback_resolver.dart';
import 'package:watch_app/core/zmode/source_matcher.dart';
import 'package:watch_app/core/zmode/zmode_source_prefs.dart';

/// src-a is slow (past its budget); src-b answers at once but never has the
/// episode. Mirrors the log: every quick source empty, the slow one working.
class _Src implements SourceRepository {
  _Src({required this.aDelay, this.slowId = 'src-a'});

  final Duration aDelay;

  /// Id of the slow source ("ani:…" stands in for an Aniyomi source).
  final String slowId;

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  List<({String id, String name})> get loadedSources => [
    (id: slowId, name: 'Slowpoke'),
    (id: 'src-b', name: 'Quickdraw'),
  ];

  @override
  List<({String id, String name})> get pickableSources => loadedSources;

  @override
  bool hasSource(String sourceId) => true;

  @override
  Future<bool> ensureSourceLoaded(String sourceId) async => true;

  @override
  String displayName(String sourceId) =>
      sourceId == slowId ? 'Slowpoke' : 'Quickdraw';

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
    if (sourceId == slowId) {
      await Future<void>.delayed(aDelay);
      return [
        for (var n = 1; n <= 9; n++)
          Episode(
            id: '$n',
            title: 'Ep $n',
            number: n.toDouble(),
            url: 'https://a/$n',
          ),
      ];
    }
    return const [
      Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://b/1'),
    ];
  }

  @override
  Future<List<VideoSource>> sources(
    String episodeUrl, {
    String? sourceId,
    bool fast = false,
  }) async => const [VideoSource(url: 'https://a/stream')];
}

void main() {
  late Directory dir;
  late MatchStore store;
  late ZSourcePrefs prefs;
  late SourceHealthStore health;

  Future<void> open() async {
    dir = await Directory.systemTemp.createTemp('patient-sweep');
    Hive.init(dir.path);
    await SourceHealthStore.init();
    health = SourceHealthStore();
    store = await MatchStore.open();
    prefs = await ZSourcePrefs.open();
    JsEngine.debugRunsOffUiIsolateOverride = true;
    PlaybackResolver.debugResetNetworkWatch();
  }

  Future<void> close() async {
    JsEngine.debugRunsOffUiIsolateOverride = null;
    BootConnectivity.instance.offline.value = false;
    PlaybackResolver.debugResetNetworkWatch();
    await Hive.close();
    await dir.delete(recursive: true);
  }

  PlaybackResolver build(_Src src, {Duration? slowGrace}) {
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
      // Scaled-down stand-ins for the real 20s budget and 45s grace.
      perSourceBudget: const Duration(milliseconds: 60),
      relaxedBudget: const Duration(milliseconds: 60),
      chosenBudget: const Duration(milliseconds: 60),
      slowGrace: slowGrace ?? const Duration(seconds: 2),
    )..bindTitleLookup((_) async => (title: 'FMA', alt: null, malId: 100));
  }

  /// The reason the sweep for [ep] gave for src-a, or null when it played.
  Future<SweepReason?> reasonFor(
    PlaybackResolver r,
    int ep, {
    String id = 'src-a',
  }) async {
    try {
      await r.resolveForPlayback('zm://anime/mal:100/ep/$ep');
      return null;
    } on EpisodeNotAvailable catch (e) {
      return e.outcomes.firstWhere((o) => o.sourceId == id).reason;
    }
  }

  testWidgets('Windows: a slow source past its budget still plays instead of '
      '"episode not available"', (tester) async {
    await tester.runAsync(() async {
      await open();
      try {
        final r = build(_Src(aDelay: const Duration(milliseconds: 300)));
        final res = await r.resolveForPlayback('zm://anime/mal:100/ep/2');
        expect(res.match.sourceId, 'src-a');
      } finally {
        await close();
      }
    });
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('Windows: the progressive sweep also waits for the slow source', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await open();
      try {
        final r = build(_Src(aDelay: const Duration(milliseconds: 300)));
        final events = await r
            .resolveProgressive('zm://anime/mal:100/ep/2')
            .toList();
        expect(events.last.done, isTrue);
        expect(events.last.match.sourceId, 'src-a');
      } finally {
        await close();
      }
    });
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('Android: unchanged — the slow source is cut off at its budget', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await open();
      try {
        final r = build(_Src(aDelay: const Duration(milliseconds: 300)));
        await expectLater(
          r.resolveForPlayback('zm://anime/mal:100/ep/2'),
          throwsA(isA<EpisodeNotAvailable>()),
        );
      } finally {
        await close();
      }
    });
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
    'Windows: one failed slow try does not skip the source; two in a row do',
    (tester) async {
      await tester.runAsync(() async {
        await open();
        try {
          // Never answers inside budget + grace.
          final r = build(
            _Src(aDelay: const Duration(milliseconds: 800)),
            slowGrace: const Duration(milliseconds: 150),
          );
          expect(await reasonFor(r, 2), SweepReason.timedOut);
          // Let the first try's strike land.
          await Future<void>.delayed(const Duration(milliseconds: 100));
          // One strike: still asked.
          expect(await reasonFor(r, 3), SweepReason.timedOut);
          await Future<void>.delayed(const Duration(milliseconds: 100));
          // Two strikes in a row: now on the skip list.
          expect(await reasonFor(r, 4), SweepReason.cooldown);
          // Let the slow requests still in flight finish before teardown.
          await Future<void>.delayed(const Duration(milliseconds: 900));
        } finally {
          await close();
        }
      });
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'Windows: failures while the network goes offline and back are not '
    'held against the source',
    (tester) async {
      await tester.runAsync(() async {
        await open();
        try {
          final r = build(
            _Src(aDelay: const Duration(milliseconds: 800)),
            slowGrace: const Duration(milliseconds: 150),
          );
          final first = reasonFor(r, 2);
          // The connection drops and comes back during the sweep.
          BootConnectivity.instance.offline.value = true;
          BootConnectivity.instance.offline.value = false;
          expect(await first, SweepReason.timedOut);
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(await reasonFor(r, 3), SweepReason.timedOut);
          await Future<void>.delayed(const Duration(milliseconds: 100));
          // Still not skipped: both failures fell in the network change.
          expect(await reasonFor(r, 4), SweepReason.timedOut);
          await Future<void>.delayed(const Duration(milliseconds: 900));
        } finally {
          await close();
        }
      });
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'Android: unchanged — one timeout puts the source on the skip list',
    (tester) async {
      await tester.runAsync(() async {
        await open();
        try {
          final r = build(_Src(aDelay: const Duration(milliseconds: 300)));
          expect(await reasonFor(r, 2), SweepReason.timedOut);
          expect(await reasonFor(r, 3), SweepReason.cooldown);
          await Future<void>.delayed(const Duration(milliseconds: 400));
        } finally {
          await close();
        }
      });
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'Windows: an Aniyomi source is not skipped for time spent queued in the '
    'Aniyomi gate',
    (tester) async {
      await tester.runAsync(() async {
        await open();
        // Fill the shared gate's two slots and queue a third call, as a
        // wave of three Aniyomi sources does.
        final hold = Completer<String?>();
        final busy = [
          for (var i = 0; i < 3; i++)
            AniyomiCallGate.instance.run('busy $i', () => hold.future),
        ];
        try {
          final r = build(
            _Src(aDelay: const Duration(milliseconds: 800), slowId: 'ani:slow'),
            slowGrace: const Duration(milliseconds: 150),
          );
          expect(await reasonFor(r, 2, id: 'ani:slow'), SweepReason.timedOut);
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(await reasonFor(r, 3, id: 'ani:slow'), SweepReason.timedOut);
          await Future<void>.delayed(const Duration(milliseconds: 100));
          // Without the queue check this third try would be "cooldown".
          expect(await reasonFor(r, 4, id: 'ani:slow'), SweepReason.timedOut);
          await Future<void>.delayed(const Duration(milliseconds: 900));
        } finally {
          hold.complete(null);
          await Future.wait(busy);
          await close();
        }
      });
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
