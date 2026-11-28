// acct-1 (Windows): signing out keeps each account's local library in a
// per-account snapshot, signing the same account back in restores it, and a
// different account never sees it.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/profiles/account_local_data.dart';

void main() {
  late Directory dir;

  // Two stand-in library boxes: one typed like the stores (Box<Map>), one
  // untyped like the shared sync-metadata box.
  const listBox = 'test_list';
  const metaBox = 'test_meta';

  Future<void> clearLive() async {
    await Hive.box<Map>(listBox).clear();
    await Hive.box<dynamic>(metaBox).clear();
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('acctdata');
    Hive.init(dir.path);
    await Hive.openBox<Map>(listBox);
    await Hive.openBox<dynamic>(metaBox);
    AccountLocalData.boxes = const [listBox, metaBox];
  });

  tearDown(() async {
    AccountLocalData.boxes = AccountLocalData.libraryBoxes;
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('same account signing back in gets its library back', () async {
    await AccountLocalData.onSignedIn('User-A', clearLive: clearLive);
    await Hive.box<Map>(listBox).put('show1', {'title': 'One'});
    await Hive.box<dynamic>(metaBox).put('pending', ['show1']);

    expect(await AccountLocalData.onSignedOut(), isTrue);
    await clearLive(); // what the app does right after the snapshot
    expect(Hive.box<Map>(listBox).isEmpty, isTrue);
    expect(await AccountLocalData.owner(), isNull);

    final restored = await AccountLocalData.onSignedIn(
      'User-A',
      clearLive: clearLive,
    );
    expect(restored, isTrue);
    expect(Hive.box<Map>(listBox).get('show1'), {'title': 'One'});
    expect(Hive.box<dynamic>(metaBox).get('pending'), ['show1']);
    expect(await AccountLocalData.owner(), 'User-A');
    // The snapshot is consumed once restored.
    expect(await AccountLocalData.hasSnapshot('User-A'), isFalse);
  });

  test('a different account starts clean', () async {
    await AccountLocalData.onSignedIn('a', clearLive: clearLive);
    await Hive.box<Map>(listBox).put('show1', {'title': 'One'});
    await AccountLocalData.onSignedOut();
    await clearLive();

    final restored = await AccountLocalData.onSignedIn(
      'b',
      clearLive: clearLive,
    );
    expect(restored, isFalse);
    expect(Hive.box<Map>(listBox).isEmpty, isTrue);
    // A's library is still kept for A.
    expect(await AccountLocalData.hasSnapshot('a'), isTrue);
  });

  test('switching accounts without a sign-out keeps the first apart', () async {
    await AccountLocalData.onSignedIn('a', clearLive: clearLive);
    await Hive.box<Map>(listBox).put('show1', {'title': 'One'});

    await AccountLocalData.onSignedIn('b', clearLive: clearLive);
    expect(Hive.box<Map>(listBox).isEmpty, isTrue, reason: 'b starts clean');

    await AccountLocalData.onSignedOut();
    await clearLive();
    await AccountLocalData.onSignedIn('a', clearLive: clearLive);
    expect(Hive.box<Map>(listBox).get('show1'), {'title': 'One'});
  });

  test('guest data made while signed out survives the restore', () async {
    await AccountLocalData.onSignedIn('a', clearLive: clearLive);
    await Hive.box<Map>(listBox).put('show1', {'title': 'One'});
    await AccountLocalData.onSignedOut();
    await clearLive();
    await Hive.box<Map>(listBox).put('guest', {'title': 'Guest'});

    await AccountLocalData.onSignedIn('a', clearLive: clearLive);
    expect(Hive.box<Map>(listBox).keys, containsAll(['show1', 'guest']));
  });

  test('signing in again as the owner changes nothing', () async {
    await AccountLocalData.onSignedIn('a', clearLive: clearLive);
    await Hive.box<Map>(listBox).put('show1', {'title': 'One'});
    var cleared = false;
    final restored = await AccountLocalData.onSignedIn(
      'a',
      clearLive: () async => cleared = true,
    );
    expect(restored, isFalse);
    expect(cleared, isFalse);
    expect(Hive.box<Map>(listBox).get('show1'), {'title': 'One'});
  });

  test('a guest sign-out saves nothing', () async {
    expect(await AccountLocalData.onSignedOut(), isFalse);
  });

  // Boot restore and the auth listener can both adopt the same account at
  // once; the calls must run one after the other, so the snapshot is
  // restored exactly once and neither call fails on a deleted box.
  test('two sign-ins at once for the same account restore once', () async {
    await AccountLocalData.onSignedIn('a', clearLive: clearLive);
    await Hive.box<Map>(listBox).put('show1', {'title': 'One'});
    await AccountLocalData.onSignedOut();
    await clearLive();

    final results = await Future.wait([
      AccountLocalData.onSignedIn('a', clearLive: clearLive),
      AccountLocalData.onSignedIn('a', clearLive: clearLive),
    ]);
    expect(results, [isTrue, isFalse]);
    expect(Hive.box<Map>(listBox).get('show1'), {'title': 'One'});
    expect(await AccountLocalData.owner(), 'a');
  });
}
