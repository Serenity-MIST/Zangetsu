// Windows Auto Resolve rules from the Source Priority work:
// - ar-9: a source switched off with "Use in Auto Resolve" is skipped by the
//   sweep (Windows only; elsewhere the old off-list stays inert).
// - ar-11: the preferred source is tried first and a miss falls back to Auto
//   Resolve instead of leaving the title empty.
// - ar-2: "Auto Resolve" on one title only clears that title's own choice.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/playback/source_health_store.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/zmode/match_store.dart';
import 'package:watch_app/core/zmode/source_matcher.dart';
import 'package:watch_app/core/zmode/source_order_prefs.dart';
import 'package:watch_app/core/zmode/source_score_store.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/core/zmode/zmode_module.dart';
import 'package:watch_app/core/zmode/zmode_source_prefs.dart';

/// Installed streaming sources; search() answers from [bySource] and throws
/// for anything else (a source that does not have the title / is dead).
class _Sources implements SourceRepository {
  _Sources(this.ids, [this.bySource = const {}]);
  final List<String> ids;
  final Map<String, List<MediaItem>> bySource;
  final searched = <String>[];

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  List<({String id, String name})> get loadedSources => [
    for (final id in ids) (id: id, name: id),
  ];
  @override
  List<({String id, String name})> get pickableSources => loadedSources;
  @override
  bool hasSource(String sourceId) => ids.contains(sourceId);
  @override
  Future<bool> ensureSourceLoaded(String sourceId) async => true;
  @override
  Future<List<MediaItem>> search(
    String query, {
    String category = 'sub',
    String? sourceId,
    // Results page (added to SourceRepository.search for "Load more").
    int page = 1,
  }) async {
    searched.add(sourceId!);
    final r = bySource[sourceId];
    if (r == null) throw StateError('no title here');
    return r;
  }
}

MediaItem _hit(String src, String title) => MediaItem(
  id: title.toLowerCase(),
  title: title,
  url: 'https://$src/$title',
  type: ProviderType.anime,
  sourceId: src,
);

void main() {
  late Directory dir;
  late SourceOrderPrefs order;
  late ZSourcePrefs picks;
  late MatchStore store;
  const fma = ZCanonical(ZKind.anime, 'mal:5114');

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('source-priority-win');
    Hive.init(dir.path);
    order = await SourceOrderPrefs.open();
    picks = await ZSourcePrefs.open();
    store = await MatchStore.open();
    sl.registerSingleton<SourceOrderPrefs>(order);
    sl.registerSingleton<ZSourcePrefs>(picks);
    sl.registerSingleton<SourceScoreStore>(await SourceScoreStore.open());
    sl.registerSingleton<SourceHealthStore>(SourceHealthStore());
  });
  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await sl.reset();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  group('Use in Auto Resolve (ar-9)', () {
    setUp(() {
      sl.registerSingleton<SourceRepository>(_Sources(['a', 'b', 'c']));
    });

    test('Windows: a switched-off source is skipped by the sweep', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await order.exclude(ZKind.anime, 'b');
      expect([for (final s in sweepCandidates(ZKind.anime)) s.id], ['a', 'c']);
      expect([for (final s in sweepList(ZKind.anime)) s.id], ['a', 'c']);
      expect([for (final s in automaticCandidates(ZKind.anime)) s.id], [
        'a',
        'c',
      ]);
      // The Settings list still shows it, so it can be switched back on.
      expect([for (final s in priorityCandidates(ZKind.anime)) s.id], [
        'a',
        'b',
        'c',
      ]);
      // And the per-title picker still offers it.
      expect(orderedCandidates(ZKind.anime).map((s) => s.id), contains('b'));
      // Off only for anime: the Movies / TV list is separate.
      expect([for (final s in sweepCandidates(ZKind.movie)) s.id], [
        'a',
        'b',
        'c',
      ]);
    });

    test('Windows: the preferred source is never skipped', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await order.exclude(ZKind.anime, 'b');
      await picks.set(ZKind.anime, 'b');
      expect(excludedForSweep(ZKind.anime), isEmpty);
    });

    test('off Windows the stored off-list stays inert', () async {
      await order.exclude(ZKind.anime, 'b');
      expect([for (final s in sweepCandidates(ZKind.anime)) s.id], [
        'a',
        'b',
        'c',
      ]);
    });
  });

  group('preferred source and per-title Auto Resolve (ar-11, ar-2)', () {
    SourceMatcher matcher(_Sources repo) => SourceMatcher(
      sources: repo,
      store: store,
      prefs: picks,
      candidates: (_) => repo.loadedSources,
    );

    test('Windows: preferred is tried first, a miss falls back', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final repo = _Sources(
        ['pref', 'other'],
        {
          'other': [_hit('other', 'FMA')],
        },
      );
      await picks.set(ZKind.anime, 'pref');
      final m = matcher(repo);
      expect(m.selectedFor(ZKind.anime), isNull);
      expect(m.preferredFor(ZKind.anime), 'pref');
      expect((await m.resolve(fma, title: 'FMA'))?.sourceId, 'other');
      expect(repo.searched, ['pref', 'other']);
      // The title itself stays on Auto Resolve.
      expect(m.sourceForTitle(fma), isNull);
    });

    test('Windows: preferred that has the title wins', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final repo = _Sources(
        ['other', 'pref'],
        {
          'pref': [_hit('pref', 'FMA')],
          'other': [_hit('other', 'FMA')],
        },
      );
      await picks.set(ZKind.anime, 'pref');
      expect((await matcher(repo).resolve(fma, title: 'FMA'))?.sourceId, 'pref');
      expect(repo.searched, ['pref']);
    });

    test('phone keeps the fixed default: a miss is reported', () async {
      final repo = _Sources(
        ['pref', 'other'],
        {
          'other': [_hit('other', 'FMA')],
        },
      );
      await picks.set(ZKind.anime, 'pref');
      expect(await matcher(repo).resolve(fma, title: 'FMA'), isNull);
      expect(repo.searched, ['pref']);
    });

    test('Windows: Auto Resolve on a title keeps the global settings',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final repo = _Sources(
        ['pref', 'other'],
        {
          'pref': [_hit('pref', 'FMA')],
          'other': [_hit('other', 'FMA')],
        },
      );
      await picks.set(ZKind.anime, 'pref');
      await picks.rememberLastGood(ZKind.manga, 'mihon:x');
      final m = matcher(repo);
      await m.pinTitleToSource(fma, 'other', title: 'FMA');
      expect(m.sourceForTitle(fma), 'other');
      await m.clearAuto(fma);
      expect(m.sourceForTitle(fma), isNull, reason: 'own choice removed');
      expect(picks.get(ZKind.anime), 'pref', reason: 'global default kept');
      expect(picks.lastGood(ZKind.manga), 'mihon:x');
    });

    test('phone: Auto Resolve still clears the kind default', () async {
      final repo = _Sources(['pref', 'other']);
      await picks.set(ZKind.anime, 'pref');
      await matcher(repo).clearAuto(fma);
      expect(picks.get(ZKind.anime), isNull);
    });
  });
}
