import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/core/zmode/zmode_source_prefs.dart';

void main() {
  late Directory dir;
  late ZSourcePrefs prefs;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('zsource');
    Hive.init(dir.path);
    prefs = await ZSourcePrefs.open();
  });
  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('starts with no pick for any kind', () {
    for (final k in ZKind.values) {
      expect(prefs.get(k), isNull);
    }
  });

  test('a pick round-trips and survives a reopen', () async {
    await prefs.set(ZKind.anime, 'ani:1');
    expect(prefs.get(ZKind.anime), 'ani:1');

    await Hive.close();
    Hive.init(dir.path);
    prefs = await ZSourcePrefs.open();
    expect(prefs.get(ZKind.anime), 'ani:1');
  });

  test('kinds do not bleed into each other', () async {
    await prefs.set(ZKind.anime, 'ani:1');
    await prefs.set(ZKind.manga, 'mihon:2');
    await prefs.set(ZKind.novel, 'lnr:3');

    // The whole point: choosing an anime source must not turn up in manga.
    expect(prefs.get(ZKind.anime), 'ani:1');
    expect(prefs.get(ZKind.manga), 'mihon:2');
    expect(prefs.get(ZKind.novel), 'lnr:3');
  });

  test('movie and tv share one pick; anime keeps its own', () async {
    await prefs.set(ZKind.anime, 'ani:anime-only');
    await prefs.set(ZKind.movie, 'cs:4K HDHUB');
    // One source for anime, another that carries movies/TV: choosing the
    // movie source must not send anime through it.
    expect(prefs.get(ZKind.anime), 'ani:anime-only');
    expect(prefs.get(ZKind.tv), 'cs:4K HDHUB');
    expect(prefs.get(ZKind.movie), 'cs:4K HDHUB');
    expect(prefs.get(ZKind.manga), isNull);
  });

  test('an older shared pick still applies to anime until it is split', () async {
    // What builds before the split wrote: one streaming pick for everything.
    await Hive.box<String>(ZSourcePrefs.boxName).put('video', 'cs:Old');
    expect(prefs.get(ZKind.anime), 'cs:Old');
    // Changing Movies/TV now leaves anime on the source it already used.
    await prefs.set(ZKind.movie, 'cs:New');
    expect(prefs.get(ZKind.movie), 'cs:New');
    expect(prefs.get(ZKind.anime), 'cs:Old');
  });

  test('anime set to Auto Resolve stays on Auto', () async {
    await prefs.set(ZKind.movie, 'cs:4K HDHUB');
    await prefs.clear(ZKind.anime);
    expect(prefs.get(ZKind.anime), isNull);
    expect(prefs.get(ZKind.movie), 'cs:4K HDHUB');
  });

  test('a pick is readable before its write is awaited', () async {
    // A resolve fired straight after a Settings change must see the new pick,
    // never a half-written "Auto" left by the anime split.
    await Hive.box<String>(ZSourcePrefs.boxName).put('video', 'cs:Old');
    final pending = prefs.set(ZKind.anime, 'ani:New');
    expect(prefs.get(ZKind.anime), 'ani:New');
    expect(prefs.get(ZKind.movie), 'cs:Old');
    await pending;
  });

  test('Movies/TV set to Auto keeps the pick anime inherited', () async {
    await Hive.box<String>(ZSourcePrefs.boxName).put('video', 'cs:Old');
    await prefs.clear(ZKind.movie);
    expect(prefs.get(ZKind.movie), isNull);
    expect(prefs.get(ZKind.anime), 'cs:Old');
  });

  test('clearing one kind leaves the others alone', () async {
    await prefs.set(ZKind.anime, 'ani:1');
    await prefs.set(ZKind.manga, 'mihon:2');
    await prefs.clear(ZKind.anime);
    expect(prefs.get(ZKind.anime), isNull);
    expect(prefs.get(ZKind.manga), 'mihon:2');
  });
}
