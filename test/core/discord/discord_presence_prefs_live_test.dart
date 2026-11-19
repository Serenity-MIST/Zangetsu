import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/discord/discord_rpc.dart';
import 'package:watch_app/core/privacy/incognito_mode.dart';

/// Discord settings toggles change the visible presence immediately rather
/// than on the next title page / player event. Observed through the presence
/// transport channel (same seam as discord_browsing_adversarial_test).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('zangetsu/discord_presence');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  late Directory directory;
  late DiscordRpc rpc;

  /// Waits past the 400 ms presence debounce.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 450));

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    IncognitoMode.notifier.value = false;
    directory = await Directory.systemTemp.createTemp('discord_prefs_live');
    Hive.init(directory.path);
    await Hive.openBox(DiscordRpc.boxName);
    await Hive.box(DiscordRpc.boxName).putAll({
      'accessToken': 'fake-test-token',
      'expiresAt': DateTime.now()
          .add(const Duration(hours: 1))
          .millisecondsSinceEpoch,
      'largeImage': 'off',
    });
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    rpc = DiscordRpc(Dio());
    await rpc.getValidAccessToken();
    await rpc.setEnabled(true);
    await settle();
    calls.clear();
  });

  tearDown(() async {
    await rpc.setEnabled(false);
    await settle();
    calls.clear();
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
    await Hive.close();
    await directory.delete(recursive: true);
  });

  Map? lastActivity() {
    final sent = calls.where(
      (c) => c.method == 'update' || c.method == 'clear',
    );
    if (sent.isEmpty) return null;
    return (sent.last.arguments as Map)['activity'] as Map?;
  }

  test('"Browsing shows title" re-renders the current browsing line', () async {
    await rpc.setBrowsing(title: 'Title A');
    await settle();
    expect(lastActivity()!['details'], 'Looking at Title A');
    await rpc.setPresencePref('browsingTitle', false);
    await settle();
    expect(lastActivity()!['details'], 'Browsing');
    await rpc.setPresencePref('browsingTitle', true);
    await settle();
    expect(lastActivity()!['details'], 'Looking at Title A');
  });

  test('"Show when paused" hides and restores a paused session', () async {
    await rpc.setWatching(
      title: 'Show',
      episodeLabel: 'Episode 2',
      position: const Duration(minutes: 3),
      duration: const Duration(minutes: 24),
      playing: false,
    );
    await settle();
    expect(lastActivity(), isNotNull);
    await rpc.setPresencePref('showPaused', false);
    await settle();
    expect(calls.last.method, 'clear');
    await rpc.setPresencePref('showPaused', true);
    await settle();
    expect(calls.last.method, 'update');
    expect(lastActivity()!['type'], 3);
  });

  test('a playing session is not replayed with a stale position', () async {
    await rpc.setWatching(
      title: 'Show',
      position: const Duration(minutes: 3),
      duration: const Duration(minutes: 24),
    );
    await settle();
    calls.clear();
    await rpc.setPresencePref('showPaused', false);
    await settle();
    expect(calls, isEmpty);
  });

  test('player exit forgets the session (nothing to replay)', () async {
    await rpc.setBrowsing(title: 'Title A');
    await settle();
    rpc.clear();
    await settle();
    calls.clear();
    await rpc.setPresencePref('browsingTitle', false);
    await settle();
    expect(calls, isEmpty);
  });
}
