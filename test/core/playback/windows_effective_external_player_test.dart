// P4: a phone backup can carry an external player id (migrated phones store
// the Android player). Windows must ignore it without changing what is
// stored; the phone keeps reading the stored value.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('windows_external_player');
    Hive.init(dir.path);
    await PlaybackPrefs.init();
    await PlaybackPrefs().setExternalPlayer(
      PlaybackPrefs.androidPlayerId,
      'Android Player',
    );
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('Windows reads a restored phone player as the built-in player', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final prefs = PlaybackPrefs();
    expect(prefs.effectiveExternalPlayerPackage, '');
    // The stored value is untouched, so a restore on a phone keeps it.
    expect(prefs.externalPlayerPackage, PlaybackPrefs.androidPlayerId);
  });

  test('the phone still uses the stored player', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(
      PlaybackPrefs().effectiveExternalPlayerPackage,
      PlaybackPrefs.androidPlayerId,
    );
  });

  test('the phone with no external player stays on the built-in one', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await PlaybackPrefs().setExternalPlayer('', '');
    expect(PlaybackPrefs().effectiveExternalPlayerPackage, '');
  });
}
