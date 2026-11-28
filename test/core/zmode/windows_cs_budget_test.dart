// Plan item C2: on Windows a playback ("fast") ask of a CloudStream source
// gets 30 s instead of 75 s, because the engine now hands playback its first
// links early. Full asks (downloads) keep 75 s, and the phone is unchanged.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
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

/// Just enough of a source list for the resolver to be built.
class _Src implements SourceRepository {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  List<({String id, String name})> get loadedSources => const [
    (id: 'cs:Anikoto', name: 'Anikoto'),
    (id: 'ani:1', name: 'Aniyomi one'),
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
    dir = await Directory.systemTemp.createTemp('cs-budget');
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

  // The real limits: nothing injected.
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

  test('the constants are 30 s for playback and 30 s of grace', () {
    expect(PlaybackResolver.companionFastBudget, const Duration(seconds: 30));
    expect(PlaybackResolver.slowSourceGrace, const Duration(seconds: 30));
  });

  test(
    'Windows: a CloudStream playback ask gets 30 s, a full ask keeps 75 s',
    () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final r = build();
      expect(
        r.debugBudgetFor('cs:Anikoto', fast: true),
        const Duration(seconds: 30),
      );
      expect(
        r.debugBudgetFor('cs:Anikoto', fast: false),
        const Duration(seconds: 75),
      );
      // The download dialog asks for every mirror: it keeps the long limit.
      final dl = r.downloadCandidates('zm://anime/mal:100/ep/2');
      final cs = dl.singleWhere((c) => c.id == 'cs:Anikoto');
      expect(cs.budget, const Duration(seconds: 75));
    },
    // The CloudStream branch is read through dart:io's Platform, which a
    // platform override cannot change.
    skip: Platform.isWindows ? false : 'needs a Windows host',
  );

  test('Windows: other sources are untouched by the change', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final r = build();
    expect(
      r.debugBudgetFor('ani:1', fast: true),
      r.debugBudgetFor('ani:1', fast: false),
    );
    expect(
      r.debugBudgetFor('ani:1', fast: true),
      PlaybackResolver.relaxedPerSourceBudget,
    );
  });

  test('Android: a CloudStream playback ask keeps the old 75 s', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final r = build();
    expect(
      r.debugBudgetFor('cs:Anikoto', fast: true),
      const Duration(seconds: 75),
    );
    expect(
      r.debugBudgetFor('cs:Anikoto', fast: false),
      const Duration(seconds: 75),
    );
  }, skip: Platform.isWindows ? false : 'needs a Windows host');

  test('an injected companion budget still applies to both asks', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final src = _Src();
    final r = PlaybackResolver(
      matcher: SourceMatcher(
        sources: src,
        store: store,
        prefs: prefs,
        candidates: (_) => src.loadedSources,
      ),
      sources: src,
      store: store,
      prefs: prefs,
      health: health,
      candidates: (_) => src.loadedSources,
      companionBudget: const Duration(seconds: 1),
    );
    if (Platform.isWindows) {
      expect(
        r.debugBudgetFor('cs:Anikoto', fast: true),
        const Duration(seconds: 1),
      );
      expect(
        r.debugBudgetFor('cs:Anikoto', fast: false),
        const Duration(seconds: 1),
      );
    }
  });

  // The call sites, not just the numbers: a playback sweep must use the
  // short limit (so a slow CloudStream source moves to the keep-listening
  // path), while a request to one named source keeps the full limit.
  test(
    'Windows: a playback sweep uses the short limit, sourcesFrom the full one',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final src = _SlowCs();
      final r = PlaybackResolver(
        matcher: SourceMatcher(
          sources: src,
          store: store,
          prefs: prefs,
          candidates: (_) => src.loadedSources,
        ),
        sources: src,
        store: store,
        prefs: prefs,
        health: health,
        candidates: (_) => src.loadedSources,
        // Links take 60 ms: past the short limit, well inside the full one.
        companionFastBudget: const Duration(milliseconds: 5),
        companionBudget: const Duration(seconds: 5),
        slowGrace: const Duration(seconds: 5),
      )..bindTitleLookup((_) async => (title: 'FMA', alt: null, malId: 100));
      const ep = 'zm://anime/mal:100/ep/2';

      final lines = <String>[];
      final oldPrint = debugPrint;
      debugPrint = (String? m, {int? wrapWidth}) {
        if (m != null) lines.add(m);
      };
      try {
        final events = await r.resolveProgressive(ep).toList();
        expect(events.last.streams, isNotEmpty);
        expect(
          lines.any((l) => l.contains('cs:Slow answered after its budget')),
          isTrue,
          reason: 'the playback sweep did not use the short limit',
        );

        lines.clear();
        final named = await r.sourcesFrom(ep, 'cs:Slow', fast: true);
        expect(named, isNotEmpty, reason: 'sourcesFrom used the short limit');
        expect(lines.where((l) => l.contains('over ')), isEmpty);
      } finally {
        debugPrint = oldPrint;
      }
    },
    skip: Platform.isWindows ? false : 'needs a Windows host',
  );
}

/// One CloudStream source whose links arrive after 60 ms.
class _SlowCs implements SourceRepository {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  List<({String id, String name})> get loadedSources => const [
    (id: 'cs:Slow', name: 'Slow'),
  ];

  @override
  List<({String id, String name})> get pickableSources => loadedSources;

  @override
  bool hasSource(String sourceId) => true;

  @override
  Future<bool> ensureSourceLoaded(String sourceId) async => true;

  @override
  String displayName(String sourceId) => sourceId;

  @override
  Future<List<MediaItem>> search(
    String q, {
    String category = 'sub',
    String? sourceId,
  }) async => [
    MediaItem(
      id: 'a',
      title: 'FMA',
      url: 'https://a/show',
      type: ProviderType.anime,
      sourceId: sourceId ?? 'cs:Slow',
    ),
  ];

  @override
  Future<List<Episode>> episodes(
    String url, {
    String category = 'sub',
    String? sourceId,
  }) async => const [
    Episode(id: '1', title: 'E1', number: 1, url: 'https://a/1'),
    Episode(id: '2', title: 'E2', number: 2, url: 'https://a/2'),
  ];

  @override
  Future<List<VideoSource>> sources(
    String url, {
    String? sourceId,
    bool fast = false,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 60));
    return const [VideoSource(url: 'https://a/stream')];
  }
}
