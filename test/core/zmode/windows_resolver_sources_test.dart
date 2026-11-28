// Windows source-choosing rules in the playback resolver (plan 1: P1, P3,
// P6 and the "search all sources" extra list), each with its phone check.
//
// P1: a Cloudflare flag no longer locks a JS source out of every sweep on
//     Windows; only a miss behind a FRESH challenge skips it, for 3 minutes.
// P3: on Windows the preferred source outranks the last-played one.
// P6: a pick from "search all sources" survives the player's "start fresh"
//     call and is what plays.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/boot_network.dart';
import 'package:watch_app/core/desktop/desktop_source_cf_cooldown.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/playback/source_health_store.dart';
import 'package:watch_app/core/provider/cf_solve_needed.dart';
import 'package:watch_app/core/provider/js_engine.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/zmode/match_store.dart';
import 'package:watch_app/core/zmode/playback_resolver.dart';
import 'package:watch_app/core/zmode/source_matcher.dart';
import 'package:watch_app/core/zmode/source_order_prefs.dart';
import 'package:watch_app/core/zmode/source_score_store.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/core/zmode/zmode_module.dart' show switchedOffForSweep;
import 'package:watch_app/core/zmode/zmode_source_prefs.dart';

/// Every source has the show and episodes 1-3, answering at once. A source
/// listed in [challengeLeft] answers its next N searches with a Cloudflare
/// challenge (flag recorded, nothing found), like a JS provider whose search
/// page got challenged.
class _Src implements SourceRepository {
  _Src(this.ids, {Map<String, int>? challengeLeft, Set<String>? throwOnEpisodes})
    : challengeLeft = challengeLeft ?? {},
      throwOnEpisodes = throwOnEpisodes ?? {};

  final List<String> ids;
  final Map<String, int> challengeLeft;

  /// Sources whose episode list records a Cloudflare challenge and then
  /// throws, like a JS provider that cannot parse the challenge page.
  final Set<String> throwOnEpisodes;

  /// How many searches / episode lists each source was asked for.
  final searches = <String, int>{};
  int episodeCalls = 0;

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  List<({String id, String name})> get loadedSources => [
    for (final id in ids) (id: id, name: id.toUpperCase()),
  ];

  @override
  List<({String id, String name})> get pickableSources => loadedSources;

  @override
  bool hasSource(String sourceId) => true;

  @override
  Future<bool> ensureSourceLoaded(String sourceId) async => true;

  @override
  String displayName(String sourceId) => sourceId.toUpperCase();

  @override
  Future<List<MediaItem>> search(
    String q, {
    String category = 'sub',
    String? sourceId,
  }) async {
    searches[sourceId!] = (searches[sourceId] ?? 0) + 1;
    final left = challengeLeft[sourceId] ?? 0;
    if (left > 0) {
      challengeLeft[sourceId] = left - 1;
      CfSolveNeeded.needsSolve(
        '$sourceId.test',
        'https://$sourceId.test/search',
        sourceId: sourceId,
      );
      return const [];
    }
    return [
      MediaItem(
        id: sourceId,
        title: 'FMA',
        url: 'https://$sourceId/show',
        type: ProviderType.anime,
        sourceId: sourceId,
      ),
    ];
  }

  @override
  Future<List<Episode>> episodes(
    String url, {
    String category = 'sub',
    String? sourceId,
  }) async {
    episodeCalls++;
    if (throwOnEpisodes.contains(sourceId)) {
      CfSolveNeeded.needsSolve(
        '$sourceId.test',
        'https://$sourceId.test/episodes',
        sourceId: sourceId,
      );
      throw StateError('challenge page could not be parsed');
    }
    return [
      for (var n = 1; n <= 3; n++)
        Episode(
          id: '$n',
          title: 'Ep $n',
          number: n.toDouble(),
          url: 'https://$sourceId/$n',
        ),
    ];
  }

  @override
  Future<List<VideoSource>> sources(
    String episodeUrl, {
    String? sourceId,
    bool fast = false,
  }) async => [VideoSource(url: '$episodeUrl/stream')];
}

const _ep = 'zm://anime/mal:100/ep/2';

void main() {
  late Directory dir;
  late MatchStore store;
  late ZSourcePrefs prefs;
  late SourceHealthStore health;
  var now = DateTime(2026, 11, 22, 12);

  Future<void> open() async {
    dir = await Directory.systemTemp.createTemp('windows-resolver-sources');
    Hive.init(dir.path);
    await SourceHealthStore.init();
    health = SourceHealthStore();
    store = await MatchStore.open();
    prefs = await ZSourcePrefs.open();
    JsEngine.debugRunsOffUiIsolateOverride = true;
    PlaybackResolver.debugResetNetworkWatch();
    CfSolveNeeded.debugReset();
    now = DateTime(2026, 11, 22, 12);
    DesktopSourceCfCooldown.clock = () => now;
  }

  Future<void> close() async {
    JsEngine.debugRunsOffUiIsolateOverride = null;
    BootConnectivity.instance.offline.value = false;
    PlaybackResolver.debugResetNetworkWatch();
    CfSolveNeeded.debugReset();
    DesktopSourceCfCooldown.clock = DateTime.now;
    await Hive.close();
    await dir.delete(recursive: true);
  }

  PlaybackResolver build(_Src src) {
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
      perSourceBudget: const Duration(seconds: 2),
      relaxedBudget: const Duration(seconds: 2),
      chosenBudget: const Duration(seconds: 2),
      slowGrace: const Duration(milliseconds: 200),
    )..bindTitleLookup((_) async => (title: 'FMA', alt: null, malId: 100));
  }

  /// The reason [id] got in a sweep that found nothing, or null if it played.
  Future<SweepReason?> reasonFor(PlaybackResolver r, String id) async {
    try {
      await r.resolveForPlayback(_ep);
      return null;
    } on EpisodeNotAvailable catch (e) {
      return e.outcomes.firstWhere((o) => o.sourceId == id).reason;
    } on NoSourceMatch catch (e) {
      return e.outcomes.firstWhere((o) => o.sourceId == id).reason;
    }
  }

  final show = ZmodeIds.parseEpisode(_ep)!.show;

  // ── P1 ───────────────────────────────────────────────────────────────────

  group('P1 Cloudflare cooldown', () {
    testWidgets('Windows: a source flagged long ago is asked again and its '
        'links win', (tester) async {
      await tester.runAsync(() async {
        await open();
        try {
          // An old challenge from some side host; nothing new since.
          CfSolveNeeded.needsSolve(
            'embed.test',
            'https://embed.test/e',
            sourceId: 'js-a',
          );
          final src = _Src(['js-a']);
          final r = build(src);
          final res = await r.resolveForPlayback(_ep);
          expect(res.match.sourceId, 'js-a');
          // The flag itself stays for the Verify UI.
          expect(CfSolveNeeded.sourceFlagged('js-a'), isTrue);
        } finally {
          await close();
        }
      });
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('Windows: progressive sweep also asks a source flagged long '
        'ago', (tester) async {
      await tester.runAsync(() async {
        await open();
        try {
          CfSolveNeeded.needsSolve(
            'embed.test',
            'https://embed.test/e',
            sourceId: 'js-a',
          );
          final r = build(_Src(['js-a']));
          final events = await r.resolveProgressive(_ep).toList();
          expect(events.first.match.sourceId, 'js-a');
        } finally {
          await close();
        }
      });
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('Windows: a miss behind a fresh challenge is skipped for 3 '
        'minutes, then asked again', (tester) async {
      await tester.runAsync(() async {
        await open();
        try {
          final src = _Src(['js-a'], challengeLeft: {'js-a': 1});
          final r = build(src);
          // 1st sweep: its own ask is challenged; reported as Cloudflare.
          expect(await reasonFor(r, 'js-a'), SweepReason.cloudflare);
          final asked = src.searches['js-a'];
          // Let the cooldown record land (it listens to the request).
          await Future<void>.delayed(const Duration(milliseconds: 20));
          // 2nd sweep inside the cooldown: skipped without asking.
          r.invalidateWinner(_ep);
          expect(await reasonFor(r, 'js-a'), SweepReason.cloudflare);
          expect(src.searches['js-a'], asked);
          // The download list reads the same rule.
          expect(r.downloadCandidates(_ep).single.skipReason, isNotNull);
          // Past 3 minutes: asked again, and this time it plays.
          now = now.add(const Duration(minutes: 3, seconds: 1));
          r.invalidateWinner(_ep);
          final res = await r.resolveForPlayback(_ep);
          expect(res.match.sourceId, 'js-a');
          expect(r.downloadCandidates(_ep).single.skipReason, isNull);
        } finally {
          await close();
        }
      });
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('Windows: once the flag is cleared (Verify or a normal '
        'answer), a cooling source is asked again at once', (tester) async {
      await tester.runAsync(() async {
        await open();
        try {
          final src = _Src(['js-a'], challengeLeft: {'js-a': 1});
          final r = build(src);
          expect(await reasonFor(r, 'js-a'), SweepReason.cloudflare);
          await Future<void>.delayed(const Duration(milliseconds: 20));
          // Still inside the 3 minutes, but the host's flag goes away.
          CfSolveNeeded.clear('js-a.test');
          r.invalidateWinner(_ep);
          final res = await r.resolveForPlayback(_ep);
          expect(res.match.sourceId, 'js-a');
        } finally {
          await close();
        }
      });
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('Windows: "search all sources" reports a cooling source as '
        'skipped, not asked', (tester) async {
      await tester.runAsync(() async {
        await open();
        try {
          final src = _Src(['js-a', 'b'], challengeLeft: {'js-a': 1});
          final r = build(src);
          // A sweep where js-a is challenged (b wins, js-a starts cooling).
          await r.resolveForPlayback(_ep);
          await Future<void>.delayed(const Duration(milliseconds: 20));
          final asked = src.searches['js-a'];
          final probes = await r.probeEach(_ep).toList();
          final a = probes.where((p) => p.sourceId == 'js-a').toList();
          expect(a, isNotEmpty);
          expect(a.every((p) => p.skipped), isTrue);
          expect(src.searches['js-a'], asked);
        } finally {
          await close();
        }
      });
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('Windows: an ask that throws right after a fresh challenge '
        'is reported as Cloudflare', (tester) async {
      await tester.runAsync(() async {
        await open();
        try {
          final r = build(_Src(['js-a'], throwOnEpisodes: {'js-a'}));
          expect(await reasonFor(r, 'js-a'), SweepReason.cloudflare);
        } finally {
          await close();
        }
      });
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('Android: an ask that throws is still reported as failed', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await open();
        try {
          final r = build(_Src(['js-a'], throwOnEpisodes: {'js-a'}));
          expect(await reasonFor(r, 'js-a'), SweepReason.failed);
        } finally {
          await close();
        }
      });
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('Windows: a native source keeps the plain flag rule', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await open();
        try {
          CfSolveNeeded.needsSolve(
            'ext.test',
            'https://ext.test/',
            sourceId: 'ani:1',
          );
          final r = build(_Src(['ani:1']));
          expect(await reasonFor(r, 'ani:1'), SweepReason.cloudflare);
        } finally {
          await close();
        }
      });
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('Android: a flagged source is still skipped (unchanged)', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await open();
        try {
          CfSolveNeeded.needsSolve(
            'embed.test',
            'https://embed.test/e',
            sourceId: 'js-a',
          );
          final src = _Src(['js-a']);
          final r = build(src);
          expect(await reasonFor(r, 'js-a'), SweepReason.cloudflare);
          expect(src.searches['js-a'], isNull);
        } finally {
          await close();
        }
      });
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  });

  // ── P3 ───────────────────────────────────────────────────────────────────

  group('P3 preferred outranks last-played', () {
    testWidgets('Windows: preferred first, then last-played', (tester) async {
      await tester.runAsync(() async {
        await open();
        try {
          final r = build(_Src(['a', 'b', 'c']));
          await store.rememberLastPlayed(show, 'c');
          await prefs.set(ZKind.anime, 'b');
          expect(r.candidatesForEpisode(_ep).map((s) => s.id), [
            'b',
            'c',
            'a',
          ]);
        } finally {
          await close();
        }
      });
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('Windows: no preferred source, last-played stays first', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await open();
        try {
          final r = build(_Src(['a', 'b', 'c']));
          await store.rememberLastPlayed(show, 'c');
          expect(r.candidatesForEpisode(_ep).map((s) => s.id), [
            'c',
            'a',
            'b',
          ]);
        } finally {
          await close();
        }
      });
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('Android: last-played still before preferred (unchanged)', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await open();
        try {
          final r = build(_Src(['a', 'b', 'c']));
          await store.rememberLastPlayed(show, 'c');
          await prefs.set(ZKind.anime, 'b');
          expect(r.candidatesForEpisode(_ep).map((s) => s.id), [
            'c',
            'b',
            'a',
          ]);
        } finally {
          await close();
        }
      });
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  });

  // ── P6 ───────────────────────────────────────────────────────────────────

  group('P6 search-all-sources pick', () {
    /// Probes the episode, picks [pick], then does what the player does
    /// before opening: invalidateWinner. Returns the first progressive event
    /// and how many episode lists were fetched after the pick.
    Future<(String, int)> pickThenOpen(_Src src, String pick) async {
      final r = build(src);
      final probes = await r.probeEach(_ep).toList();
      final picked = probes.firstWhere(
        (p) => p.sourceId == pick && p.hasEpisode,
      );
      await r.useProbed(_ep, picked);
      final before = src.episodeCalls;
      r.invalidateWinner(_ep);
      final first = await r.resolveProgressive(_ep).first;
      return (first.match.sourceId, src.episodeCalls - before);
    }

    testWidgets('Windows: the pick plays without a new sweep', (tester) async {
      await tester.runAsync(() async {
        await open();
        try {
          final (id, lists) = await pickThenOpen(_Src(['a', 'b']), 'b');
          expect(id, 'b');
          expect(lists, 0, reason: 'answered from the pick, no sweep');
        } finally {
          await close();
        }
      });
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('Windows: the pick is spared only once', (tester) async {
      await tester.runAsync(() async {
        await open();
        try {
          final src = _Src(['a', 'b']);
          final r = build(src);
          final probes = await r.probeEach(_ep).toList();
          await r.useProbed(
            _ep,
            probes.firstWhere((p) => p.sourceId == 'b' && p.hasEpisode),
          );
          r.invalidateWinner(_ep); // spared
          expect(r.resolvedSourceId(_ep), 'b');
          r.invalidateWinner(_ep); // a real Retry: cleared
          expect(r.resolvedSourceId(_ep), isNull);
        } finally {
          await close();
        }
      });
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('Android: unchanged, the open re-sweeps', (tester) async {
      await tester.runAsync(() async {
        await open();
        try {
          final (_, lists) = await pickThenOpen(_Src(['a', 'b']), 'b');
          expect(lists, greaterThan(0));
        } finally {
          await close();
        }
      });
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('extra sources (switched off for Auto Resolve) are asked '
        'after the normal list', (tester) async {
      await tester.runAsync(() async {
        await open();
        try {
          final src = _Src(['a', 'off']);
          final matcher = SourceMatcher(
            sources: src,
            store: store,
            prefs: prefs,
            candidates: (_) => src.loadedSources,
          );
          // Normal candidates leave 'off' out, like a switched-off source.
          final r = PlaybackResolver(
            matcher: matcher,
            sources: src,
            store: store,
            prefs: prefs,
            health: health,
            candidates: (_) => [(id: 'a', name: 'A')],
          )..bindTitleLookup((_) async => (title: 'FMA', alt: null, malId: 100));
          final asked = (await r
                  .probeEachWithExtra(_ep, extra: ['off'])
                  .toList())
              .where((p) => !p.checking)
              .map((p) => p.sourceId)
              .toList();
          expect(asked, ['a', 'off']);
          final plain = (await r.probeEach(_ep).toList())
              .where((p) => !p.checking)
              .map((p) => p.sourceId);
          expect(plain, ['a']);
        } finally {
          await close();
        }
      });
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    /// Registers what [switchedOffForSweep] reads, with 'off' switched off.
    Future<void> registerSwitchedOff(_Src src) async {
      final order = await SourceOrderPrefs.open();
      await order.exclude(ZKind.anime, 'off');
      final scores = await SourceScoreStore.open();
      sl
        ..registerSingleton<SourceRepository>(src)
        ..registerSingleton<SourceOrderPrefs>(order)
        ..registerSingleton<ZSourcePrefs>(prefs)
        ..registerSingleton<SourceHealthStore>(health)
        ..registerSingleton<SourceScoreStore>(scores);
    }

    testWidgets('Windows: the sheet\'s extra list is the switched-off '
        'sources', (tester) async {
      await tester.runAsync(() async {
        await open();
        try {
          await registerSwitchedOff(_Src(['a', 'off']));
          expect(switchedOffForSweep(ZKind.anime), ['off']);
        } finally {
          await sl.reset();
          await close();
        }
      });
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('Android: no extra list (the switch is not honoured there)', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await open();
        try {
          await registerSwitchedOff(_Src(['a', 'off']));
          expect(switchedOffForSweep(ZKind.anime), isEmpty);
        } finally {
          await sl.reset();
          await close();
        }
      });
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  });
}
