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
import 'package:watch_app/core/discord/discord_rpc.dart';
import 'package:watch_app/core/discord/discord_sdk_gateway.dart';
import 'package:watch_app/core/logging/app_logger.dart';
import 'package:watch_app/core/privacy/incognito_mode.dart';

const _channel = MethodChannel('zangetsu/discord_presence');
const _secure = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
const _old = 'fake-old-access-111';
const _fresh = 'fake-fresh-access-222';

/// Answers Discord's HTTP calls locally; nothing leaves the test.
class _Http implements HttpClientAdapter {
  /// What the refresh call answers: status and body, or an exception.
  Future<(int, Map<String, dynamic>)> Function() refresh = () async =>
      (200, _Http.good);
  static const good = <String, dynamic>{
    'access_token': _fresh,
    'refresh_token': 'fake-refresh-next',
    'expires_in': 604800,
  };
  int refreshes = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    var status = 200;
    var body = <String, dynamic>{
      'scopes': ['identify', 'sdk.social_layer_presence'],
    };
    if (options.path.endsWith('/oauth2/token')) {
      refreshes++;
      (status, body) = await refresh();
    }
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// The Windows login rules: one refresh at a time, and only a login Discord
/// declares dead ever signs the person out.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  final logs = <String>[];
  late DebugPrintCallback originalPrint;
  late Directory dir;
  late DiscordRpc rpc;
  late _Http http;
  late Dio dio;
  late DateTime clock;

  Box box() => Hive.box(DiscordRpc.boxName);
  int count(String method) => calls.where((c) => c.method == method).length;
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 450));
  Future<void> authFailed() => messenger.handlePlatformMessage(
    _channel.name,
    const StandardMethodCodec().encodeMethodCall(
      const MethodCall('authFailed', 'authFailed'),
    ),
    (_) {},
  );

  Future<void> login({required bool expired}) => box().putAll({
    'enabled': true,
    'accessToken': _old,
    'refreshToken': 'fake-refresh-first',
    'expiresAt': DateTime.now()
        .add(expired ? const Duration(hours: -1) : const Duration(hours: 1))
        .millisecondsSinceEpoch,
  });

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    DiscordSdkGateway.debugResetAvailability();
    BootConnectivity.instance.offline.value = false;
    IncognitoMode.notifier.value = false;
    calls.clear();
    logs.clear();
    originalPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');
    messenger.setMockMethodCallHandler(_secure, (_) async => null);
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return call.method == 'isAvailable' ? 'ok' : null;
    });
    dir = await Directory.systemTemp.createTemp('discord_win_login');
    Hive.init(dir.path);
    await Hive.openBox(DiscordRpc.boxName);
    await Hive.openBox<dynamic>(DesktopPrefs.boxName);
    await DesktopPrefs.setDiscordOnlyWhileWatching(false);
    http = _Http();
    dio = Dio()..httpClientAdapter = http;
    clock = DateTime(2026, 1, 1, 12);
    rpc = DiscordRpc(dio)..debugNow = () => clock;
  });

  tearDown(() async {
    // Nothing the app printed may hold a login.
    final printed = logs.join('\n');
    expect(printed, isNot(contains(_old)));
    expect(printed, isNot(contains(_fresh)));
    expect(printed, isNot(contains('fake-refresh')));
    await rpc.setEnabled(false);
    await settle();
    messenger.setMockMethodCallHandler(_channel, null);
    messenger.setMockMethodCallHandler(_secure, null);
    debugPrint = originalPrint;
    BootConnectivity.instance.offline.value = false;
    dio.close();
    await Hive.close();
    await dir.delete(recursive: true);
    debugDefaultTargetPlatformOverride = null;
  });

  test('expired login: connect and browsing share one refresh', () async {
    await login(expired: true);
    await rpc.start();
    await settle();
    await settle();
    expect(http.refreshes, 1);
    final start = calls.singleWhere((c) => c.method == 'start');
    expect((start.arguments as Map)['token'], _fresh);
    expect(count('update'), greaterThan(0));
    expect(box().get('refreshToken'), 'fake-refresh-next');
    // What testers send us must survive the log redactor.
    for (final l in ['login refreshed', 'login scopes (HTTP 200): identify']) {
      final line = logs.firstWhere((x) => x.contains(l));
      expect(AppLogger.redact(line), line);
    }
  });

  for (final (name, answer)
      in <(String, Future<(int, Map<String, dynamic>)> Function())>[
        (
          'a timeout',
          () async => throw DioException(
            requestOptions: RequestOptions(path: '/oauth2/token'),
            type: DioExceptionType.receiveTimeout,
          ),
        ),
        ('a server fault', () async => (500, <String, dynamic>{})),
        (
          'a rate limit',
          () async => (429, <String, dynamic>{'error': 'rate_limited'}),
        ),
        (
          'a set-up fault',
          () async => (401, <String, dynamic>{'error': 'invalid_client'}),
        ),
      ]) {
    test('$name keeps the login and connects later', () async {
      await login(expired: true);
      http.refresh = answer;
      await rpc.start();
      await settle();
      expect(rpc.loggedIn, isTrue);
      expect(rpc.enabled, isTrue);
      expect(box().get('accessToken'), _old);
      expect(box().get('refreshToken'), 'fake-refresh-first');
      expect(count('start'), 0);
      expect(logs, contains('[discord] connect again in 30s'));
      // The network comes back.
      http.refresh = () async => (200, _Http.good);
      BootConnectivity.instance.offline.value = true;
      BootConnectivity.instance.offline.value = false;
      await settle();
      expect(count('start'), 1);
    });
  }

  test('invalid_grant signs out, at startup too', () async {
    await login(expired: true);
    http.refresh = () async =>
        (400, <String, dynamic>{'error': 'invalid_grant'});
    await rpc.start();
    await settle();
    expect(rpc.loggedIn, isFalse);
    expect(rpc.enabled, isFalse);
    expect(box().get('refreshToken'), isNull);
    expect(calls.where((c) => c.method == 'start'), isEmpty);
  });

  test('an expired login that cannot be refreshed signs out', () async {
    await login(expired: true);
    await box().delete('refreshToken');
    await rpc.start();
    await settle();
    expect(rpc.loggedIn, isFalse);
    expect(http.refreshes, 0);
  });

  test('signing out during a refresh is not undone by its answer', () async {
    await login(expired: true);
    final gate = Completer<(int, Map<String, dynamic>)>();
    http.refresh = () => gate.future;
    await rpc.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await rpc.logout();
    gate.complete((200, _Http.good));
    await settle();
    expect(rpc.loggedIn, isFalse);
    expect(box().get('accessToken'), isNull);
    expect(count('start'), 0);
  });

  test('signing out just as a refresh answers stays signed out', () async {
    // Every step of the way from the answer to the saved login.
    for (var step = 0; step < 12; step++) {
      await login(expired: true);
      final gate = Completer<(int, Map<String, dynamic>)>();
      http.refresh = () => gate.future;
      final one = DiscordRpc(dio)..debugNow = () => clock;
      final asked = one.getValidAccessToken();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      gate.complete((200, _Http.good));
      for (var i = 0; i < step; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      await one.logout();
      await asked;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(one.loggedIn, isFalse, reason: 'step $step');
      expect(box().get('accessToken'), isNull, reason: 'step $step');
      expect(box().get('refreshToken'), isNull, reason: 'step $step');
      expect(box().get('expiresAt'), isNull, reason: 'step $step');
    }
  });

  test('focus during a failing refresh neither hammers nor delays', () async {
    await login(expired: true);
    http.refresh = () async => (429, <String, dynamic>{});
    await rpc.start();
    await settle();
    expect(http.refreshes, 1);
    for (var i = 0; i < 5; i++) {
      rpc.onForeground();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(http.refreshes, 1);
    // A while later focus does try again, in between the planned tries.
    clock = clock.add(const Duration(seconds: 11));
    rpc.onForeground();
    await settle();
    expect(http.refreshes, 2);
    expect(
      logs.where((l) => l.contains('connect again')),
      ['[discord] connect again in 30s'],
    );
    // And connects once the login works again.
    clock = clock.add(const Duration(seconds: 11));
    http.refresh = () async => (200, _Http.good);
    rpc.onForeground();
    await settle();
    expect(count('start'), 1);
  });

  test('a login that stays rejected is refreshed less and less', () async {
    await login(expired: false);
    await rpc.start();
    await settle();
    final at = <int>[];
    var seen = 0;
    for (var minute = 0; minute <= 240; minute++) {
      await authFailed();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      if (http.refreshes != seen) {
        seen = http.refreshes;
        at.add(minute);
      }
      clock = clock.add(const Duration(minutes: 1));
    }
    expect(at, [0, 5, 15, 35, 75, 135, 195]);
    expect(rpc.loggedIn, isTrue);
  });

  test('two authFailed give one refresh; a second soon after none', () async {
    await login(expired: false);
    await rpc.start();
    await settle();
    expect(count('start'), 1);
    final gate = Completer<(int, Map<String, dynamic>)>();
    http.refresh = () => gate.future;
    unawaited(authFailed());
    unawaited(authFailed());
    await Future<void>.delayed(const Duration(milliseconds: 50));
    gate.complete((200, _Http.good));
    await settle();
    expect(http.refreshes, 1);
    expect(count('start'), 2);
    expect(
      (calls.lastWhere((c) => c.method == 'start').arguments as Map)['token'],
      _fresh,
    );

    clock = clock.add(const Duration(minutes: 4));
    await authFailed();
    await settle();
    expect(http.refreshes, 1);
    expect(rpc.loggedIn, isTrue);
    expect(rpc.enabled, isTrue);

    clock = clock.add(const Duration(minutes: 2));
    await authFailed();
    await settle();
    expect(http.refreshes, 2);
  });

  test('authFailed with a failing refresh keeps the login', () async {
    await login(expired: false);
    await rpc.start();
    await settle();
    http.refresh = () async => (503, <String, dynamic>{});
    await authFailed();
    await settle();
    expect(rpc.loggedIn, isTrue);
    expect(rpc.enabled, isTrue);
    expect(count('start'), 1);
  });

  group('leaving the player', () {
    Future<void> watchThenLeave() async {
      await login(expired: false);
      await rpc.start();
      await rpc.setWatching(title: 'Show', episodeLabel: 'Episode 1');
      await settle();
      calls.clear();
      rpc.clear(delay: const Duration(milliseconds: 50));
      await settle();
      await settle();
    }

    test('shows Browsing again', () async {
      await watchThenLeave();
      final last = calls.lastWhere(
        (c) => c.method == 'update' || c.method == 'clear',
      );
      expect(last.method, 'update');
      expect(
        ((last.arguments as Map)['activity'] as Map)['details'],
        'Browsing',
      );
    });

    test('shows nothing with "Only while watching"', () async {
      await DesktopPrefs.setDiscordOnlyWhileWatching(true);
      await watchThenLeave();
      expect(count('update'), 0);
      expect(count('clear'), greaterThan(0));
    });

    test('shows nothing in incognito', () async {
      await login(expired: false);
      await rpc.start();
      await rpc.setWatching(title: 'Show');
      await settle();
      calls.clear();
      rpc.clear(delay: const Duration(milliseconds: 50));
      IncognitoMode.notifier.value = true;
      await settle();
      await settle();
      expect(count('update'), 0);
      expect(count('close'), 1);
    });

    test('incognito right after leaving does not bring the video back', () async {
      await login(expired: false);
      await rpc.start();
      await rpc.setWatching(
        title: 'SECRET',
        episodeLabel: 'Episode 1',
        duration: const Duration(minutes: 20),
      );
      await settle();
      rpc.clear(delay: const Duration(seconds: 2));
      IncognitoMode.notifier.value = true;
      await settle();
      calls.clear();
      IncognitoMode.notifier.value = false;
      await settle();
      await settle();
      expect('${calls.map((c) => c.arguments)}', isNot(contains('SECRET')));
      final last = calls.lastWhere((c) => c.method == 'update');
      expect(
        ((last.arguments as Map)['activity'] as Map)['details'],
        'Browsing',
      );
    });

    test('a video closed in incognito: Browsing after it', () async {
      await login(expired: false);
      await rpc.start();
      await rpc.setWatching(title: 'SECRET');
      await settle();
      IncognitoMode.notifier.value = true;
      await settle();
      rpc.clear(delay: const Duration(milliseconds: 50));
      await settle();
      calls.clear();
      IncognitoMode.notifier.value = false;
      await settle();
      await settle();
      expect('${calls.map((c) => c.arguments)}', isNot(contains('SECRET')));
      expect(count('update'), 1);
    });

    test('incognito at launch, then off: Browsing', () async {
      await login(expired: false);
      IncognitoMode.notifier.value = true;
      await rpc.start();
      await settle();
      expect(calls, isEmpty);
      IncognitoMode.notifier.value = false;
      await settle();
      await settle();
      expect(count('start'), 1);
      expect(count('update'), 1);
    });

    test('incognito off keeps a hidden paused video hidden', () async {
      await login(expired: false);
      await box().put('showPaused', false);
      await rpc.start();
      await rpc.setWatching(title: 'Show', playing: false);
      await settle();
      IncognitoMode.notifier.value = true;
      await settle();
      calls.clear();
      IncognitoMode.notifier.value = false;
      await settle();
      await settle();
      expect(count('start'), 1);
      expect(count('update'), 0);
    });

    test('a direct clear stays empty', () async {
      await login(expired: false);
      await rpc.start();
      await rpc.setWatching(title: 'Show');
      await settle();
      calls.clear();
      rpc.clear();
      await settle();
      await settle();
      expect(count('update'), 0);
      expect(count('clear'), 1);
    });
  });
}
