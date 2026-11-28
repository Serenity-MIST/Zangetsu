import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/desktop/desktop_prefs.dart';
import 'package:watch_app/core/discord/discord_activity_watch.dart';
import 'package:watch_app/core/discord/discord_rpc.dart';
import 'package:watch_app/core/privacy/incognito_mode.dart';

/// Fails every request at once, so artwork lookups never touch the network.
class _NoNetwork implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => throw DioException(
    requestOptions: options,
    type: DioExceptionType.connectionError,
  );

  @override
  void close({bool force = false}) {}
}

// track-12: Discord presence hides when the Windows app is idle or
// minimised (never during playback) and supports "only while watching".
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('zangetsu/discord_presence');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  late Directory directory;
  late DiscordRpc rpc;
  late Dio dio;
  late DateTime clock;
  late DiscordActivityWatch watch;

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 450));

  // The last presence call: 'update' (shown) or 'clear' (hidden).
  String? lastCall() {
    final relevant = calls.where(
      (c) => c.method == 'update' || c.method == 'clear',
    );
    return relevant.isEmpty ? null : relevant.last.method;
  }

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('discord_away');
    Hive.init(directory.path);
    await Hive.openBox(DiscordRpc.boxName);
    await Hive.openBox<dynamic>(DesktopPrefs.boxName);
    dio = Dio()..httpClientAdapter = _NoNetwork();
    rpc = DiscordRpc(dio);
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  setUp(() async {
    // Connect through the phone SDK transport (a mocked channel), then act
    // as Windows: the away rules read the platform on every send.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    IncognitoMode.notifier.value = false;
    await Hive.box(DiscordRpc.boxName).putAll({
      'presenceStatus': 'online',
      'accessToken': 'fake-test-token',
      'expiresAt': DateTime.now()
          .add(const Duration(hours: 1))
          .millisecondsSinceEpoch,
      'largeImage': 'off',
      'smallImage': 'off',
      'showPaused': true,
    });
    await DesktopPrefs.setDiscordOnlyWhileWatching(false);
    await rpc.getValidAccessToken();
    await rpc.setEnabled(true);
    await Future<void>.delayed(Duration.zero);
    clock = DateTime(2026, 1, 1, 12);
    watch = DiscordActivityWatch(
      onChanged: rpc.refreshVisibility,
      idleAfter: const Duration(minutes: 5),
      now: () => clock,
    );
    rpc.debugAttachActivityWatch(watch);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    calls.clear();
  });

  tearDown(() async {
    rpc.debugAttachActivityWatch(null);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await rpc.setEnabled(false);
    await settle();
    calls.clear();
    debugDefaultTargetPlatformOverride = null;
  });

  tearDownAll(() async {
    messenger.setMockMethodCallHandler(channel, null);
    dio.close();
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('browsing clears after idle time and returns on input', () async {
    await rpc.setBrowsing(title: 'Title A');
    await settle();
    expect(lastCall(), 'update');

    clock = clock.add(const Duration(minutes: 6));
    watch.tick();
    await settle();
    expect(rpc.presenceHidden, isTrue);
    expect(lastCall(), 'clear');

    watch.noteInput();
    await settle();
    expect(rpc.presenceHidden, isFalse);
    expect(lastCall(), 'update');
  });

  test('a playing video is never hidden when idle or minimised', () async {
    await rpc.setWatching(
      title: 'Show',
      episodeLabel: 'Episode 1',
      duration: const Duration(minutes: 24),
    );
    await settle();
    calls.clear();
    clock = clock.add(const Duration(minutes: 30));
    watch.tick();
    watch.setMinimised(true);
    await settle();
    expect(rpc.presenceHidden, isFalse);
    expect(lastCall(), isNull);
  });

  test('minimising hides browsing, restoring shows it again', () async {
    await rpc.setBrowsing();
    await settle();
    watch.setMinimised(true);
    await settle();
    expect(lastCall(), 'clear');
    watch.setMinimised(false);
    await settle();
    expect(lastCall(), 'update');
  });

  test('only while watching hides browsing but shows the player', () async {
    await rpc.setBrowsing(title: 'Title B');
    await settle();
    await DesktopPrefs.setDiscordOnlyWhileWatching(true);
    rpc.refreshVisibility();
    await settle();
    expect(lastCall(), 'clear');

    await rpc.setWatching(title: 'Show', episodeLabel: 'Episode 2');
    await settle();
    expect(lastCall(), 'update');
  });

  test('phone never hides presence', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await rpc.setBrowsing(title: 'Title C');
    clock = clock.add(const Duration(minutes: 30));
    watch.tick();
    watch.setMinimised(true);
    expect(rpc.presenceHidden, isFalse);
  });
}
