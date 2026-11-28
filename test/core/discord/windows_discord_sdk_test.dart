import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/boot_network.dart';
import 'package:watch_app/core/desktop/desktop_prefs.dart';
import 'package:watch_app/core/discord/discord_config.dart';
import 'package:watch_app/core/discord/discord_gateway.dart';
import 'package:watch_app/core/discord/discord_presence.dart';
import 'package:watch_app/core/discord/discord_rpc.dart';
import 'package:watch_app/core/discord/discord_sdk_gateway.dart';
import 'package:watch_app/core/logging/app_logger.dart';
import 'package:watch_app/core/privacy/incognito_mode.dart';

const _channel = MethodChannel('zangetsu/discord_presence');
const _fakeLogin = 'fake-access-value-123';

/// Answers Discord's HTTP calls locally; nothing leaves the test.
class _Http implements HttpClientAdapter {
  final paths = <String>[];

  /// What the external-assets calls asked for.
  final assets = <Object?>[];

  int count(String part) => paths.where((p) => p.contains(part)).length;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    paths.add(options.path);
    if (options.path.endsWith('/external-assets')) assets.add(options.data);
    final Object body = options.path.endsWith('/external-assets')
        ? [
            {'external_asset_path': 'external/poster'},
          ]
        : {
            'scopes': ['identify', 'sdk.social_layer_presence'],
          };
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Stands in for the raw gateway: records, never opens a socket.
class _RawGateway extends DiscordGateway {
  _RawGateway(super.token, {super.onAuthFailure});
  final sent = <DiscordActivity?>[];
  bool connected = false;
  int retries = 0;

  @override
  void connect() => connected = true;
  @override
  void retryNow() => retries++;
  @override
  void setPresence(DiscordActivity? activity, {String status = 'online'}) =>
      sent.add(activity);
  @override
  Future<void> clearThenClose() async {}
  @override
  Future<void> close() async {}
}

/// Moves fake time on in one-second steps, so timers armed on the way run at
/// their own time too.
Future<void> _seconds(WidgetTester tester, int seconds) async {
  for (var i = 0; i < seconds; i++) {
    await tester.pump(const Duration(seconds: 1));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  final logs = <String>[];

  /// Answers for the fake native side; no function answers null.
  Future<Object?> Function()? onAvailable;
  Future<Object?> Function()? onStart;

  int count(String method) => calls.where((c) => c.method == method).length;
  List<Map> activities() => [
    for (final c in calls)
      if (c.method == 'update') (c.arguments as Map)['activity'] as Map,
  ];

  /// What the native side would report to Dart.
  Future<void> native(String method, String value) =>
      messenger.handlePlatformMessage(
        _channel.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, value)),
        (_) {},
      );
  Future<void> status(String value) => native('status', value);

  late DebugPrintCallback originalPrint;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    DiscordSdkGateway.debugResetAvailability();
    BootConnectivity.instance.offline.value = false;
    IncognitoMode.notifier.value = false;
    calls.clear();
    logs.clear();
    onAvailable = () async => 'ok';
    onStart = null;
    originalPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      if (call.method == 'isAvailable') return onAvailable?.call();
      if (call.method == 'start') return onStart?.call();
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_channel, null);
    debugPrint = originalPrint;
    BootConnectivity.instance.offline.value = false;
    IncognitoMode.notifier.value = false;
    debugDefaultTargetPlatformOverride = null;
  });

  /// Widget tests run on fake time, but insist that platform and log hooks
  /// are back to normal before they end.
  void timedTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        debugPrint = originalPrint;
      }
    });
  }

  group('availability', () {
    test('ok is asked once and remembered', () async {
      expect(await DiscordSdkGateway.isAvailable(), isTrue);
      expect(await DiscordSdkGateway.isAvailable(), isTrue);
      expect(count('isAvailable'), 1);
      expect(logs, ['[discord] SDK available']);
    });

    test('a reason, null, an error or a missing channel mean no', () async {
      for (final (answer, text) in <(Future<Object?> Function()?, String)>[
        (() async => 'load=126', 'load=126'),
        (null, 'no answer'),
        (() async => throw PlatformException(code: 'E1'), 'E1'),
      ]) {
        DiscordSdkGateway.debugResetAvailability();
        logs.clear();
        onAvailable = answer;
        expect(await DiscordSdkGateway.isAvailable(), isFalse);
        expect(logs, ['[discord] SDK not available ($text)']);
      }
      DiscordSdkGateway.debugResetAvailability();
      messenger.setMockMethodCallHandler(_channel, null);
      expect(await DiscordSdkGateway.isAvailable(), isFalse);
    });

    timedTest('no answer within 15 s means no', (tester) async {
      onAvailable = () => Completer<Object?>().future;
      bool? answer;
      unawaited(DiscordSdkGateway.isAvailable().then((v) => answer = v));
      await tester.pump(const Duration(seconds: 14));
      expect(answer, isNull);
      await tester.pump(const Duration(seconds: 2));
      expect(answer, isFalse);
    });
  });

  group('transport', () {
    late Directory dir;
    late DiscordRpc rpc;
    late _Http http;
    late Dio dio;
    final raws = <_RawGateway>[];

    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 450));

    setUp(() async {
      raws.clear();
      dir = await Directory.systemTemp.createTemp('discord_win_sdk');
      Hive.init(dir.path);
      await Hive.openBox(DiscordRpc.boxName);
      await Hive.openBox<dynamic>(DesktopPrefs.boxName);
      await Hive.box(DiscordRpc.boxName).putAll({
        'accessToken': _fakeLogin,
        'refreshToken': 'fake-refresh-value',
        'expiresAt': DateTime.now()
            .add(const Duration(hours: 1))
            .millisecondsSinceEpoch,
      });
      http = _Http();
      dio = Dio()..httpClientAdapter = http;
      rpc = DiscordRpc(dio)
        ..debugRawGateway = (token, onAuthFailure) {
          final g = _RawGateway(token, onAuthFailure: onAuthFailure);
          raws.add(g);
          return g;
        };
      await rpc.getValidAccessToken();
    });

    tearDown(() async {
      await rpc.setEnabled(false);
      await settle();
      dio.close();
      await Hive.close();
      await dir.delete(recursive: true);
    });

    Future<void> enableAndBrowse() async {
      await rpc.setEnabled(true);
      await rpc.setBrowsing(
        title: 'Title A',
        posterUrl: 'https://example.com/a.jpg',
      );
      await settle();
    }

    test('SDK gets plain https posters and no external-assets call', () async {
      await enableAndBrowse();
      expect(raws, isEmpty);
      final start = calls.singleWhere((c) => c.method == 'start');
      expect(start.arguments, {
        'applicationId': DiscordConfig.applicationId,
        'token': _fakeLogin,
      });
      expect(
        (activities().last['assets'] as Map)['large_image'],
        'https://example.com/a.jpg',
      );
      expect(http.count('external-assets'), 0);
      expect(logs.join('\n'), isNot(contains(_fakeLogin)));
    });

    for (final (name, answer) in <(String, Future<Object?> Function()?)>[
      ('a reason', () async => 'imports'),
      ('null', null),
    ]) {
      test('$name uses the raw gateway and external assets', () async {
        onAvailable = answer;
        await enableAndBrowse();
        expect(count('start'), 0);
        expect(raws.single.connected, isTrue);
        expect(http.count('external-assets'), greaterThan(0));
        expect(raws.single.sent.last!.largeImage, 'mp:external/poster');
      });
    }

    test('a missing channel uses the raw gateway', () async {
      messenger.setMockMethodCallHandler(_channel, null);
      await enableAndBrowse();
      expect(raws.single.connected, isTrue);
    });

    test('SDK that cannot start falls back and sends it again', () async {
      onStart = () async =>
          throw PlatformException(code: 'DISCORD_SDK_UNAVAILABLE');
      await enableAndBrowse();
      await settle();
      expect(count('start'), 1);
      expect(raws.single.connected, isTrue);
      final last = raws.single.sent.last!;
      expect(last.details, 'Looking at Title A');
      expect(last.largeImage, 'mp:external/poster');
      // Remembered for this run: the next connect goes straight to raw.
      await rpc.setEnabled(false);
      await settle();
      await rpc.setEnabled(true);
      await settle();
      expect(count('start'), 1);
      expect(raws, hasLength(2));
    });

    test('a start error that is not "unavailable" keeps the SDK', () async {
      onStart = () async => throw PlatformException(code: 'DISCORD_SDK_ERROR');
      await enableAndBrowse();
      expect(raws, isEmpty);
    });

    test('a playing video is replayed at its current position', () async {
      var clock = DateTime(2026, 1, 1, 12);
      rpc.debugNow = () => clock;
      final gate = Completer<Object?>();
      onStart = () => gate.future;
      await rpc.setEnabled(true);
      final before = DateTime.now().millisecondsSinceEpoch;
      await rpc.setWatching(
        title: 'Show',
        position: const Duration(minutes: 1),
        duration: const Duration(minutes: 20),
      );
      await settle();
      clock = clock.add(const Duration(minutes: 2));
      gate.completeError(PlatformException(code: 'DISCORD_SDK_UNAVAILABLE'));
      await settle();
      await settle();
      // 3 minutes in by now: the bar starts 3 minutes before "now".
      final start = raws.single.sent.last!.startMs!;
      expect(before - start, greaterThan(170000));
      expect(before - start, lessThan(185000));
    });

    test('signed out, disabled or incognito never touch the channel', () async {
      await rpc.setBrowsing(title: 'Disabled');
      IncognitoMode.notifier.value = true;
      await rpc.setEnabled(true);
      await rpc.setBrowsing(title: 'Hidden');
      await settle();
      await rpc.setEnabled(false);
      IncognitoMode.notifier.value = false;
      await rpc.logout();
      await rpc.setEnabled(true);
      await rpc.setBrowsing(title: 'Signed out');
      await settle();
      expect(calls, isEmpty);
      expect(http.paths, isEmpty);
    });

    for (final (name, poster) in [
      ('a cover saved on this PC', 'file:///C:/covers/a.jpg'),
      ('a Windows path', r'C:\covers\a.jpg'),
      ('a link over 300 characters', 'https://e.com/${'a' * 300}.jpg'),
    ]) {
      test('$name shows the app logo', () async {
        await rpc.setEnabled(true);
        await rpc.setWatching(title: 'Show', posterUrl: poster);
        await settle();
        final assets = activities().last['assets'] as Map;
        expect(assets['large_image'], DiscordConfig.appLogoUrl);
        expect(assets['large_text'], 'Show');
        expect(assets['small_image'], DiscordConfig.appLogoUrl);
      });
    }

    test('a saved cover is not sent to Discord by the raw path', () async {
      onAvailable = () async => 'imports';
      await rpc.setEnabled(true);
      await rpc.setBrowsing(
        title: 'Title A',
        posterUrl: 'file:///C:/covers/a.jpg',
      );
      await settle();
      // Only the app logo is asked for, and shown.
      expect(http.assets, isNotEmpty);
      for (final asked in http.assets) {
        expect(asked, {
          'urls': [DiscordConfig.appLogoUrl],
        });
      }
      expect(raws.single.sent.last!.largeImage, 'mp:external/poster');
    });

    test('incognito during the availability wait: no start', () async {
      final gate = Completer<Object?>();
      onAvailable = () => gate.future;
      await rpc.setEnabled(true);
      await Future<void>.delayed(Duration.zero);
      IncognitoMode.notifier.value = true;
      gate.complete('ok');
      await settle();
      expect(count('start'), 0);
      expect(raws, isEmpty);
    });

    test('two connects at once give one start', () async {
      final gate = Completer<Object?>();
      onAvailable = () => gate.future;
      await rpc.setEnabled(true);
      rpc.onForeground();
      rpc.onForeground();
      await Future<void>.delayed(Duration.zero);
      gate.complete('ok');
      await settle();
      expect(count('start'), 1);
    });
  });

  group('watchdog', () {
    // The platform is read when the gateway is built.
    DiscordSdkGateway build(
      WidgetTester tester, {
      Future<void> Function()? onAuthFailure,
      void Function()? onUnavailable,
    }) => DiscordSdkGateway(
      _fakeLogin,
      onAuthFailure: onAuthFailure,
      onUnavailable: onUnavailable,
      now: () => tester.binding.clock.now(),
    );

    timedTest('never ready: starts again with growing waits', (tester) async {
      final g = build(tester)..connect();
      await tester.pump();
      expect(count('start'), 1);
      await _seconds(tester, 59);
      expect(count('start'), 1);
      await _seconds(tester, 2);
      expect(count('start'), 2);
      await _seconds(tester, 118);
      expect(count('start'), 2);
      await _seconds(tester, 3);
      expect(count('start'), 3);
      // 240 s, then never more than 5 minutes.
      await _seconds(tester, 241);
      expect(count('start'), 4);
      await _seconds(tester, 301);
      expect(count('start'), 5);
      await _seconds(tester, 301);
      expect(count('start'), 6);
      await g.close();
      await tester.pump(const Duration(minutes: 20));
      expect(count('start'), 6);
    });

    timedTest('ready stops the timer', (tester) async {
      final g = build(tester)..connect();
      await tester.pump();
      await status('connection:Connecting:error=0:detail=0');
      await status('connection:Ready:error=0:detail=0');
      await tester.pump(const Duration(minutes: 30));
      expect(count('start'), 1);
      expect(
        logs,
        contains('[discord] SDK status: connection:Ready:error=0:detail=0'),
      );
      await g.close();
    });

    timedTest('disconnected: again after 10 s, 60 s while connecting', (
      tester,
    ) async {
      final g = build(tester)..connect();
      await tester.pump();
      await status('connection:Ready:error=0:detail=0');
      await tester.pump(const Duration(minutes: 5));
      await status('connection:Disconnected:error=1:detail=1006');
      await _seconds(tester, 5);
      // Another report of the same fault does not push the wait out.
      await status('connection:Disconnected:error=1:detail=1006');
      await _seconds(tester, 6);
      expect(count('start'), 2);
      await status('connection:Disconnected:error=1:detail=1006');
      await status('connection:Connecting:error=0:detail=0');
      await _seconds(tester, 30);
      expect(count('start'), 2);
      await status('connection:Ready:error=0:detail=0');
      await tester.pump(const Duration(minutes: 10));
      expect(count('start'), 2);
      await g.close();
    });

    timedTest('login network error waits 10 s, then 20 s', (tester) async {
      final g = build(tester)..connect();
      await tester.pump();
      await status('token:error=1:http=0:code=0');
      await _seconds(tester, 11);
      expect(count('start'), 2);
      await status('token:error=1:http=0:code=0');
      await _seconds(tester, 11);
      expect(count('start'), 2);
      await _seconds(tester, 10);
      expect(count('start'), 3);
      // The redactor must leave the error numbers readable.
      final line = logs.firstWhere((l) => l.contains('login:error'));
      expect(AppLogger.redact(line), line);
      expect(line, contains('login:error=1:http=0:code=0'));
      await g.close();
    });

    timedTest('sessions lost right after ready wait longer', (tester) async {
      final g = build(tester)..connect();
      await tester.pump();
      var starts = 1;
      for (final wait in [10, 20, 40]) {
        await status('connection:Ready:error=0:detail=0');
        await status('connection:Disconnected:error=1:detail=0');
        await _seconds(tester, wait - 1);
        expect(count('start'), starts);
        await _seconds(tester, 2);
        expect(count('start'), ++starts);
      }
      await g.close();
    });

    timedTest('offline: waits, then recovers on retryNow', (tester) async {
      final g = build(tester)..connect();
      await tester.pump();
      BootConnectivity.instance.offline.value = true;
      await tester.pump(const Duration(minutes: 10));
      g.retryNow();
      await tester.pump(const Duration(minutes: 10));
      expect(count('start'), 1);
      BootConnectivity.instance.offline.value = false;
      g.retryNow();
      await tester.pump();
      expect(count('start'), 2);
      // Right after a start a second push does nothing.
      g.retryNow();
      await _seconds(tester, 5);
      g.retryNow();
      await tester.pump();
      expect(count('start'), 2);
      await g.close();
    });

    timedTest('retryNow does nothing while ready', (tester) async {
      final g = build(tester)..connect();
      await tester.pump();
      await status('connection:Ready:error=0:detail=0');
      await tester.pump(const Duration(minutes: 1));
      g.retryNow();
      await tester.pump();
      expect(count('start'), 1);
      await g.close();
    });

    timedTest('authFailed asks the owner; its new login replaces the wait', (
      tester,
    ) async {
      late DiscordSdkGateway g;
      var asked = 0;
      g = build(
        tester,
        onAuthFailure: () async {
          asked++;
          g.updateToken('Bearer second');
        },
      )..connect();
      await tester.pump();
      await native('authFailed', 'authFailed');
      await status('token:error=2:http=401:code=0');
      await _seconds(tester, 30);
      expect(asked, 1);
      expect(count('start'), 2);
      final second = calls.lastWhere((c) => c.method == 'start');
      expect((second.arguments as Map)['token'], 'second');
      await g.close();
    });

    timedTest('login refused while ready: never restarts, sends again with '
        'growing waits', (tester) async {
      var asked = 0;
      final g = build(tester, onAuthFailure: () async => asked++)..connect();
      g.setPresence(const DiscordActivity(name: 'Show'));
      await tester.pump();
      await status('connection:Ready:error=0:detail=0');
      calls.clear();
      var answered = -1;
      final sentAt = <int>[];
      for (var s = 0; s <= 1300; s++) {
        if (count('update') != answered) {
          answered = count('update');
          sentAt.add(s);
          // What native reports for one publish: both parts refused.
          await native('authFailed', 'authFailed');
          await status('onlineStatus:error=2:http=401:code=0');
          await native('authFailed', 'authFailed');
          await status('published:error=2:http=401:code=0');
        }
        await tester.pump(const Duration(seconds: 1));
      }
      expect(count('start'), 0);
      expect(sentAt, [0, 10, 30, 70, 150, 310, 610, 910, 1210]);
      expect(asked, 2 * sentAt.length);
      await g.close();
      await tester.pump(const Duration(minutes: 20));
      expect(count('update'), sentAt.length - 1);
    });

    timedTest('a new login that is refused too does not start over', (
      tester,
    ) async {
      final g = build(tester)..connect();
      g.setPresence(const DiscordActivity(name: 'Show'));
      await tester.pump();
      await status('connection:Ready:error=0:detail=0');
      await native('authFailed', 'authFailed');
      g.updateToken('Bearer second');
      await tester.pump();
      await status('connection:Ready:error=0:detail=0');
      calls.clear();
      await native('authFailed', 'authFailed');
      await _seconds(tester, 18);
      expect(count('update'), 0); // 20 s now, not 10
      await _seconds(tester, 3);
      expect(count('update'), 1);
      // Long after the last refusal the waits are short again.
      await tester.pump(const Duration(minutes: 11));
      await native('authFailed', 'authFailed');
      await _seconds(tester, 11);
      expect(count('update'), 2);
      expect(count('start'), 0);
      await g.close();
    });

    timedTest('sending again waits for the network', (tester) async {
      final g = build(tester)..connect();
      g.setPresence(const DiscordActivity(name: 'Show'));
      await tester.pump();
      await status('connection:Ready:error=0:detail=0');
      calls.clear();
      await native('authFailed', 'authFailed');
      BootConnectivity.instance.offline.value = true;
      await _seconds(tester, 200);
      expect(calls, isEmpty);
      BootConnectivity.instance.offline.value = false;
      await _seconds(tester, 61);
      expect(count('update'), 1);
      await g.close();
    });

    timedTest('no restart once it is clearing and closing', (tester) async {
      final g = build(tester)..connect();
      await tester.pump();
      await status('connection:Disconnected:error=1:detail=0');
      unawaited(g.clearThenClose());
      await status('connection:Disconnected:error=1:detail=0');
      g.retryNow();
      await tester.pump(const Duration(minutes: 5));
      expect(count('start'), 1);
      expect(calls.last.method, 'close');
    });

    timedTest('a missing channel at start reports unavailable', (tester) async {
      onStart = () async => throw MissingPluginException();
      var unavailable = 0;
      final g = build(tester, onUnavailable: () => unavailable++)..connect();
      await tester.pump();
      expect(unavailable, 1);
      await tester.pump(const Duration(minutes: 5));
      expect(unavailable, 1);
      await g.close();
    });
  });

  group('refused status', () {
    const activity = DiscordActivity(
      name: 'Show',
      type: 3,
      largeImage: 'https://example.com/a.jpg',
      largeText: 'Show',
      smallImage: 'https://example.com/logo.png',
      smallText: 'Watching',
    );

    Future<DiscordSdkGateway> ready(DiscordActivity a) async {
      final g = DiscordSdkGateway(_fakeLogin)..connect();
      g.setPresence(a);
      await Future<void>.delayed(Duration.zero);
      calls.clear();
      return g;
    }

    test('goes to the logo, then no images, then stops', () async {
      final g = await ready(activity);
      await status('published:error=6:http=0:code=50035');
      expect(activities().last['assets'], {
        'large_image': DiscordConfig.appLogoUrl,
        'large_text': 'Show',
      });
      await status('published:error=2:http=400:code=50035');
      expect(activities().last.containsKey('assets'), isFalse);
      expect(activities().last['name'], 'Show');
      await status('published:error=9:http=0:code=0');
      expect(activities(), hasLength(2));
      // A new status starts from its own images again.
      g.setPresence(activity);
      await Future<void>.delayed(Duration.zero);
      expect(
        (activities().last['assets'] as Map)['large_image'],
        'https://example.com/a.jpg',
      );
      await g.close();
    });

    test('login, rate limit, server and network errors do not', () async {
      final g = await ready(activity);
      for (final e in [
        'error=2:http=401:code=0',
        'error=2:http=429:code=0',
        'error=2:http=503:code=0',
        'error=1:http=0:code=0',
      ]) {
        await status('published:$e');
      }
      expect(activities(), isEmpty);
      await g.close();
    });

    test('a status without images gets none added', () async {
      final g = await ready(const DiscordActivity(name: 'Show'));
      await status('published:error=6:http=0:code=0');
      expect(activities(), isEmpty);
      await g.close();
    });
  });

  test('activity fields are cleaned up before they reach the SDK', () async {
    final g = DiscordSdkGateway(_fakeLogin)..connect();
    g.setPresence(
      DiscordActivity(
        name: 'Show',
        type: 3,
        details: 'x',
        state: 'x' * 200,
        largeImage: 'mp:external/poster',
        largeText: 'Hover',
        smallImage: 'https://example.com/${'a' * 300}.png',
        smallText: 'Hover',
        startMs: 100,
        endMs: 200,
        buttons: const [
          (label: 'One', url: 'https://example.com/1'),
          (label: 'Two', url: 'https://example.com/2'),
          (label: 'Three', url: 'https://example.com/3'),
        ],
      ),
    );
    await Future<void>.delayed(Duration.zero);
    final a = activities().single;
    expect(a.containsKey('details'), isFalse);
    expect((a['state'] as String).length, 128);
    expect(a.containsKey('assets'), isFalse);
    expect(a['timestamps'], {'start': 100, 'end': 200});
    expect(a['buttons'], ['One', 'Two']);
    expect((a['metadata'] as Map)['button_urls'], hasLength(2));
    await g.close();
  });

  test('a button link Discord would refuse is dropped, the rest stays', () {
    Map<String, dynamic> clean(List<({String label, String url})> buttons) =>
        discordSanitizeSdkActivity(
          DiscordActivity(name: 'Show', buttons: buttons).toJson('1'),
        );
    final fits = 'https://e.com/${'a' * 498}';
    expect(fits.length, 512);
    final both = clean([
      (label: 'Long', url: '${fits}b'),
      (label: 'Fits', url: fits),
    ]);
    expect(both['buttons'], ['Fits']);
    expect((both['metadata'] as Map)['button_urls'], [fits]);
    final none = clean([(label: 'Long', url: '${fits}b')]);
    expect(none.containsKey('buttons'), isFalse);
    expect(none.containsKey('metadata'), isFalse);
    expect(none['name'], 'Show');
  });

  timedTest('phones: same update as before, never asked, no timers', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final activity = DiscordActivity(
      name: 'Show',
      details: 'x',
      largeImage: 'mp:external/poster',
      largeText: 'Hover',
      state: 'y' * 200,
    );
    final g = DiscordSdkGateway(_fakeLogin)..connect();
    g.setPresence(activity);
    await tester.pump();
    expect(activities().single, activity.toJson(DiscordConfig.applicationId));
    await status('connection:Disconnected:error=1:detail=0');
    await status('published:error=6:http=0:code=0');
    g.retryNow();
    await tester.pump(const Duration(minutes: 30));
    expect(count('start'), 1);
    expect(count('update'), 1);
    expect(count('isAvailable'), 0);
    await g.close();
  });
}
