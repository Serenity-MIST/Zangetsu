// Switching a source off means Auto Resolve stops SWEEPING it. It stays
// installed, keeps its settings, and is still offered in the per-title picker
// — turning a source off is not uninstalling it, and someone who picks it by
// hand for one show should still get it.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/zmode/source_order_prefs.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';

void main() {
  late Directory dir;
  late SourceOrderPrefs prefs;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('source-order-off');
    Hive.init(dir.path);
    prefs = await SourceOrderPrefs.open();
  });
  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('nothing is off to begin with', () {
    expect(prefs.excluded(ZKind.anime), isEmpty);
  });

  test('a source can be switched off and back on', () async {
    await prefs.exclude(ZKind.anime, 'animekai');
    expect(prefs.excluded(ZKind.anime), {'animekai'});
    await prefs.include(ZKind.anime, 'animekai');
    expect(prefs.excluded(ZKind.anime), isEmpty);
  });

  test('anime and movies/TV keep separate lists; reading kinds their own',
      () async {
    // Source Priority shows Anime and Movies / TV as two lists, so they are
    // stored as two: switching one off, reordering or changing the limit in
    // one must not change the other. Movies and TV share one.
    await prefs.exclude(ZKind.anime, 'hdhub4u');
    expect(prefs.excluded(ZKind.movie), isEmpty);
    expect(prefs.excluded(ZKind.manga), isEmpty);
    await prefs.exclude(ZKind.movie, 'animeonly');
    expect(prefs.excluded(ZKind.tv), {'animeonly'});
    expect(prefs.excluded(ZKind.anime), {'hdhub4u'});
    await prefs.exclude(ZKind.manga, 'mihon:1');
    expect(prefs.excluded(ZKind.manga), {'mihon:1'});
  });

  test('orders and limits are separate per list', () async {
    await prefs.set(ZKind.movie, ['m1', 'm2']);
    await prefs.setCap(ZKind.movie, 4);
    expect(prefs.get(ZKind.anime), isEmpty);
    expect(prefs.cap(ZKind.anime), kAutoResolveDefaultCap);
    expect(prefs.get(ZKind.tv), ['m1', 'm2']);
    expect(prefs.cap(ZKind.tv), 4);
  });

  test('the old shared video bucket seeds BOTH lists until each is saved',
      () async {
    final box = Hive.box<List>(SourceOrderPrefs.boxName);
    await box.putAll({
      'video': ['b', 'a'],
      'video:cap': [6],
      'video:off': ['x'],
    });
    for (final kind in [ZKind.anime, ZKind.movie]) {
      expect(prefs.get(kind), ['b', 'a']);
      expect(prefs.cap(kind), 6);
      expect(prefs.excluded(kind), {'x'});
    }
    // Saving the movie list takes it over without touching anime.
    await prefs.set(ZKind.movie, ['a']);
    await prefs.setCap(ZKind.movie, 12);
    expect(prefs.get(ZKind.anime), ['b', 'a']);
    expect(prefs.cap(ZKind.anime), 6);
    expect(prefs.get(ZKind.movie), ['a']);
  });

  test('an order saved before the shared bucket is still honoured', () async {
    // Written under the oldest per-kind key. Falling back to it is the
    // difference between keeping someone's order and silently resetting it.
    await Hive.box<List>(SourceOrderPrefs.boxName).put('anime', ['b', 'a']);
    expect(prefs.get(ZKind.anime), ['b', 'a']);
    expect(prefs.get(ZKind.movie), ['b', 'a']);
    // …until a new one is saved, which takes over for that list only.
    await prefs.set(ZKind.anime, ['a', 'b']);
    expect(prefs.get(ZKind.anime), ['a', 'b']);
    expect(prefs.get(ZKind.movie), ['b', 'a']);
  });

  test('the off-list survives a reorder, and order survives a switch-off',
      () async {
    // They live in one box under different keys; writing one must not clear
    // the other.
    await prefs.set(ZKind.anime, ['a', 'b', 'c']);
    await prefs.exclude(ZKind.anime, 'b');
    expect(prefs.get(ZKind.anime), ['a', 'b', 'c']);
    expect(prefs.excluded(ZKind.anime), {'b'});
  });

  test('unpin all cannot resurrect migrated video pins after reopening', () async {
    final box = Hive.box<List>(SourceOrderPrefs.boxName);
    await box.putAll({
      'anime': ['old-anime'],
      'movie': ['old-movie'],
      'anime:off': ['blocked'],
    });
    await prefs.set(ZKind.anime, ['new-pin']);
    await prefs.setCap(ZKind.anime, 17);
    await prefs.set(ZKind.manga, ['reader-pin']);
    await prefs.clear(ZKind.movie);
    await box.close();
    prefs = await SourceOrderPrefs.open();
    // Unpin all on Movies/TV clears that list only; anime keeps its own pin.
    expect(prefs.get(ZKind.anime), ['new-pin']);
    expect(prefs.get(ZKind.tv), isEmpty);
    expect(prefs.excluded(ZKind.movie), {'blocked'});
    expect(prefs.cap(ZKind.anime), 17);
    expect(prefs.cap(ZKind.tv), kAutoResolveDefaultCap);
    expect(prefs.get(ZKind.manga), ['reader-pin']);
    // And clearing anime does not revive the legacy 'anime' order either.
    await prefs.clear(ZKind.anime);
    expect(prefs.get(ZKind.anime), isEmpty);
  });

  test('reset clears both', () async {
    await prefs.set(ZKind.anime, ['a', 'b']);
    await prefs.exclude(ZKind.anime, 'b');
    await prefs.clear(ZKind.anime);
    await prefs.setExcluded(ZKind.anime, const {});
    expect(prefs.get(ZKind.anime), isEmpty);
    expect(prefs.excluded(ZKind.anime), isEmpty);
  });

  group('applySourceOrder', () {
    test('collapses duplicate candidate ids when no order is saved', () {
      // Two registry installs of the same sourceId (different repos) can both
      // appear in pickableSources before the JS runtime has loaded either —
      // Source Priority keys rows by id, so duplicates crash the screen.
      final out = applySourceOrder(
        const [
          (id: 'hianime', name: 'HiAnime'),
          (id: 'other', name: 'Other'),
          (id: 'hianime', name: 'HiAnime (again)'),
        ],
        const [],
      );
      expect(out.map((s) => s.id), ['hianime', 'other']);
      expect(out.first.name, 'HiAnime');
    });

    test('saved order also keeps each id once', () {
      final out = applySourceOrder(
        const [
          (id: 'hianime', name: 'HiAnime'),
          (id: 'hianime', name: 'HiAnime (again)'),
          (id: 'other', name: 'Other'),
        ],
        const ['other', 'hianime', 'hianime'],
      );
      expect(out.map((s) => s.id), ['other', 'hianime']);
    });
  });

  group('what Auto Resolve actually sweeps', () {
    List<({String id, String name})> pool(int n) =>
        [for (var i = 1; i <= n; i++) (id: 's$i', name: 'S$i')];

    test('untouched, EVERY source is used', () {
      // No invented default. An earlier version used the first ten until the
      // user said otherwise, which presented a preference nobody had
      // expressed — with a hundred installed, those ten were whatever
      // happened to sort first.
      final on = activeSources(pool(30), excluded: const {});
      expect(on.length, 30);
      expect(on.first.id, 's1');
      expect(on.last.id, 's30');
    });

    test('switched-off ones are dropped, order otherwise kept', () {
      final on = activeSources(pool(6), excluded: const {'s2', 's5'});
      expect(on.map((s) => s.id), ['s1', 's3', 's4', 's6']);
    });

    test('switching everything off leaves nothing to sweep', () {
      final on = activeSources(
        pool(3),
        excluded: const {'s1', 's2', 's3'},
      );
      expect(on, isEmpty);
    });
  });
}
