import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/anilist/anilist_service.dart';
import 'package:watch_app/core/anilist/anilist_store.dart';
import 'package:watch_app/core/desktop/desktop_oauth.dart';
import 'package:watch_app/core/discord/discord_auth.dart';
import 'package:watch_app/core/discord/discord_config.dart';
import 'package:watch_app/core/discord/discord_rpc.dart';
import 'package:watch_app/core/environment.dart';
import 'package:watch_app/core/tracker/mal_service.dart';
import 'package:watch_app/core/tracker/simkl_service.dart';

/// Proves the Windows browser sign-in path for every connection: the runner
/// is asked to register the redirect scheme BEFORE the browser opens, the
/// redirect delivered through app_links completes the login, and a waiting
/// sign-in can be cancelled. Native registry writes are covered by the
/// runner's IsAllowedUrlScheme/RegisterUrlProtocol (windows/runner/utils.cpp).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const window = MethodChannel('com.spyou.zangetsu/window');
  const launcher = MethodChannel('plugins.flutter.io/url_launcher');
  const links = MethodChannel('com.llfbandit.app_links/messages');
  const events = MethodChannel('com.llfbandit.app_links/events');

  /// Ordered log of native calls: "register:<scheme>" and "launch:<url>".
  late List<String> calls;
  late Directory dir;

  /// Delivers [uri] the way the runner's WM_COPYDATA forward reaches Dart.
  Future<void> emit(Uri uri) async {
    final delivered = Completer<void>();
    messenger.handlePlatformMessage(
      events.name,
      const StandardMethodCodec().encodeSuccessEnvelope(uri.toString()),
      (_) => delivered.complete(),
    );
    await delivered.future;
  }

  /// Launcher mock: records the URL, then (optionally) sends [redirect].
  void onLaunch(Future<void> Function(Uri url)? redirect) {
    messenger.setMockMethodCallHandler(launcher, (call) async {
      final url = Uri.parse((call.arguments as Map)['url'] as String);
      calls.add('launch:${url.scheme}');
      if (redirect != null) unawaited(redirect(url));
      return true;
    });
  }

  /// Waits (up to 5 s of real time) until the mocked browser launch has been
  /// recorded, so a check never races real file I/O done before it.
  Future<void> waitForLaunch() async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!calls.any((c) => c.startsWith('launch:')) &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  setUp(() async {
    calls = [];
    DesktopOAuth.debugIsWindowsHost = true;
    dir = await Directory.systemTemp.createTemp('desktop_oauth');
    Hive.init(dir.path);
    await AniListStore.init();
    await MalService.init();
    await SimklService.init();
    await Hive.openBox(DiscordRpc.boxName);
    messenger.setMockMethodCallHandler(links, (_) async => null);
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(window, (call) async {
      calls.add('register:${call.arguments}');
      return null;
    });
  });

  tearDown(() async {
    DesktopOAuth.debugIsWindowsHost = null;
    for (final c in [window, launcher, links, events]) {
      messenger.setMockMethodCallHandler(c, null);
    }
    await Hive.close();
    await dir.delete(recursive: true);
  });

  group('DesktopOAuth.ensureBrowserCallback', () {
    test('registers the tracker scheme by default', () async {
      expect(await DesktopOAuth.ensureBrowserCallback(), isNull);
      expect(calls, ['register:zangetsu']);
    });

    test('registers Discord\'s per-application scheme', () async {
      final scheme = DiscordAuth.redirectScheme(DiscordConfig.applicationId);
      expect(scheme, 'discord-${DiscordConfig.applicationId}');
      expect(await DesktopOAuth.ensureBrowserCallback(scheme: scheme), isNull);
      expect(calls, ['register:$scheme']);
    });

    test('reports a native registration failure', () async {
      messenger.setMockMethodCallHandler(window, (_) async {
        throw PlatformException(code: 'PROTOCOL', message: 'blocked');
      });
      expect(await DesktopOAuth.ensureBrowserCallback(), 'blocked');
    });

    test('does nothing on non-Windows hosts', () async {
      DesktopOAuth.debugIsWindowsHost = false;
      expect(await DesktopOAuth.ensureBrowserCallback(), isNull);
      expect(calls, isEmpty);
    });
  });

  test('AniList: register, browser, redirect completes the login', () async {
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) => h.resolve(
            Response(
              requestOptions: o,
              statusCode: 200,
              data: {
                'data': {
                  'Viewer': {
                    'id': 7,
                    'name': 'ani-user',
                    'avatar': {'large': 'https://a/x.png'},
                    'options': {'titleLanguage': null},
                  },
                },
              },
            ),
          ),
        ),
      );
    final service = AniListService(dio);
    addTearDown(service.dispose);
    onLaunch(
      (_) => emit(
        Uri.parse(
          '${Environment.anilistRedirectUri}'
          '#access_token=tok&token_type=Bearer&expires_in=3600',
        ),
      ),
    );
    expect(await service.connect().timeout(const Duration(seconds: 5)), isTrue);
    expect(calls, ['register:zangetsu', 'launch:https']);
    expect(service.isConnected, isTrue);
    expect(service.viewerName, 'ani-user');
    expect(service.lastConnectionError, isNull);
  });

  test(
    'MyAnimeList: register, browser, redirect completes the login',
    () async {
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (o, h) => h.resolve(
              Response(
                requestOptions: o,
                statusCode: 200,
                data: o.path.endsWith('/token')
                    ? {'access_token': 'tok', 'refresh_token': 'r'}
                    : {'name': 'mal-user'},
              ),
            ),
          ),
        );
      final service = MalService(dio);
      addTearDown(service.dispose);
      onLaunch(
        (url) => emit(
          Uri.parse(Environment.malRedirectUri).replace(
            queryParameters: {
              'code': 'c',
              'state': url.queryParameters['state']!,
            },
          ),
        ),
      );
      expect(
        await service.connect().timeout(const Duration(seconds: 5)),
        isTrue,
      );
      expect(calls, ['register:zangetsu', 'launch:https']);
      expect(service.viewerName, 'mal-user');
    },
  );

  test('Simkl: register, browser, redirect completes the login', () async {
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) => h.resolve(
            Response(
              requestOptions: o,
              statusCode: 200,
              data: o.path.endsWith('/oauth/token')
                  ? {'access_token': 'tok'}
                  : {
                      'user': {'name': 'simkl-user'},
                    },
            ),
          ),
        ),
      );
    final service = SimklService(dio);
    addTearDown(service.dispose);
    onLaunch(
      (_) => emit(
        Uri.parse(
          Environment.simklRedirectUri,
        ).replace(queryParameters: {'code': 'c'}),
      ),
    );
    expect(await service.connect().timeout(const Duration(seconds: 5)), isTrue);
    expect(calls, ['register:zangetsu', 'launch:https']);
    expect(service.viewerName, 'simkl-user');
  });

  test('a waiting tracker sign-in can be cancelled', () async {
    final service = SimklService(Dio());
    addTearDown(service.dispose);
    onLaunch(null); // the browser never comes back
    final result = service.connect();
    await pumpEventQueue();
    service.cancelConnect();
    expect(await result.timeout(const Duration(seconds: 5)), isFalse);
    expect(service.lastConnectionError, 'Sign-in cancelled.');
    // A fresh attempt is possible straight away.
    final again = service.connect();
    await pumpEventQueue();
    service.cancelConnect();
    expect(await again, isFalse);
  });

  test('registration failure stops before the browser opens', () async {
    messenger.setMockMethodCallHandler(window, (_) async {
      throw PlatformException(code: 'PROTOCOL', message: 'blocked');
    });
    final service = MalService(Dio());
    addTearDown(service.dispose);
    onLaunch(null);
    expect(await service.connect(), isFalse);
    expect(service.lastConnectionError, 'blocked');
    expect(calls, isEmpty);
  });

  test(
    'Discord: registers discord-<appId> before the browser, then cancels',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final rpc = DiscordRpc(Dio());
      onLaunch(null);
      final result = rpc.connect();
      // connect() writes its verifier/state to Hive on disk first, which can
      // outlast a single pumpEventQueue on a slow CI runner.
      await waitForLaunch();
      // Windows target has no Discord-app URI hop: straight to the browser.
      expect(calls, [
        'register:discord-${DiscordConfig.applicationId}',
        'launch:https',
      ]);
      rpc.cancelConnect();
      expect(await result.timeout(const Duration(seconds: 5)), isFalse);
      expect(rpc.lastAuthError, 'Discord login cancelled.');
      expect(Hive.box(DiscordRpc.boxName).get('codeVerifier'), isNull);
    },
  );
}
