// Windows Cloudflare verification: how a verified browser session is handed
// to the extension engine (cookies + User-Agent per host), and how a failed
// or unfinished verification is reported instead of silently retried.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/desktop_cloudflare.dart';
import 'package:watch_app/core/desktop/desktop_flaresolverr.dart';
import 'package:watch_app/core/desktop/extension_runtime.dart';
import 'package:watch_app/core/mihon/mihon_extension_service.dart';
import 'package:watch_app/core/provider/cf_solve_needed.dart';
import 'package:watch_app/core/repository/source_actions.dart'
    as source_actions;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('zangetsu/mihon');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// A verified session as the Windows verification window returns it.
  Map<String, dynamic> session({String url = 'https://www.natomanga.com/'}) => {
    'verified': true,
    'url': url,
    'userAgent': 'Mozilla/5.0 Edg/142',
    'cookie': 'cf_clearance=abc',
    'cookies': [
      {
        'name': 'cf_clearance',
        'value': 'abc',
        'domain': '.natomanga.com',
        'path': '/',
        'secure': true,
        'httpOnly': true,
        'expires': 1900000000000,
      },
    ],
  };

  group('cookie and User-Agent handoff to the engine', () {
    test('one import carrying the browser cookies and UA', () {
      final imports = DesktopExtensionRuntime.verifiedSessionImports(
        'https://www.natomanga.com/manga-list/hot-manga?page=1',
        session(),
      );
      expect(imports, hasLength(1));
      final request = imports.single;
      expect(request['url'], 'https://www.natomanga.com/');
      expect(request['userAgent'], 'Mozilla/5.0 Edg/142');
      final cookie = (request['cookies'] as List).single as Map;
      expect(cookie['name'], 'cf_clearance');
      expect(cookie['domain'], '.natomanga.com');
      expect(cookie['expires'], 1900000000000);
    });

    test('a redirect to another host imports for both hosts', () {
      final imports = DesktopExtensionRuntime.verifiedSessionImports(
        'https://www.natomanga.com/manga-list/hot-manga?page=1',
        session(url: 'https://natomanga.com/'),
      );
      expect(imports.map((r) => Uri.parse('${r['url']}').host), [
        'natomanga.com',
        'www.natomanga.com',
      ]);
      // Same browser UA for each host, so neither stays challenged.
      expect(imports.every((r) => r['userAgent'] == 'Mozilla/5.0 Edg/142'), isTrue);
    });

    test('non-web addresses are never imported', () {
      final imports = DesktopExtensionRuntime.verifiedSessionImports(
        'not a url',
        session(url: 'about:blank'),
      );
      expect(imports, isEmpty);
    });

    test('expiry seconds become milliseconds for the engine', () {
      expect(browserCookieExpiryMillis(1900000000), 1900000000000);
      expect(browserCookieExpiryMillis(1900000000000), 1900000000000);
      expect(browserCookieExpiryMillis(null), isNull);
    });
  });

  group('unfinished verification is not success', () {
    tearDown(() => DesktopCloudflare.debugSolveOverride = null);

    test('closing the window reports CANCELLED', () async {
      DesktopCloudflare.debugSolveOverride = (_, _) async => null;
      await expectLater(
        DesktopExtensionRuntime.instance.invoke('mihon', 'solveCloudflare', {
          'url': 'https://www.natomanga.com/',
        }),
        throwsA(
          isA<PlatformException>().having((e) => e.code, 'code', 'CANCELLED'),
        ),
      );
    });

    test('a still-challenged page reports CANCELLED, not success', () async {
      DesktopCloudflare.debugSolveOverride = (_, _) async => {
        'verified': false,
      };
      await expectLater(
        DesktopExtensionRuntime.instance.invoke('mihon', 'solveCloudflare', {
          'url': 'https://www.natomanga.com/',
        }),
        throwsA(isA<PlatformException>()),
      );
    });

    test('newer Cloudflare interstitials are not a ready page', () {
      Map<String, Object> page(String title, String text) => {
        'ready': true,
        'body': true,
        'title': title,
        'host': 'www.natomanga.com',
        'text': text,
      };
      expect(
        verificationPageReady(page('Just a moment...', 'x' * 100)),
        isFalse,
      );
      expect(
        verificationPageReady(
          page('www.natomanga.com', 'Performing security verification'),
        ),
        isFalse,
      );
      expect(
        verificationPageReady(page('Verifying you are human', 'x' * 100)),
        isFalse,
      );
      expect(
        verificationPageReady(page('MangaNato - Read Manga', 'Hot manga')),
        isTrue,
      );
    });
  });

  group('MihonExtensionService.verifyCloudflare', () {
    setUp(() => CfSolveNeeded.clear('www.natomanga.com'));
    tearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      CfSolveNeeded.clear('www.natomanga.com');
      debugDefaultTargetPlatformOverride = null;
    });

    void flag() => CfSolveNeeded.needsSolve(
      'www.natomanga.com',
      'https://www.natomanga.com/',
      sourceId: 'mihon:1',
    );

    test('success lifts the latch and returns true', () async {
      flag();
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      expect(
        await MihonExtensionService.verifyCloudflare(
          'https://www.natomanga.com/',
        ),
        isTrue,
      );
      expect(CfSolveNeeded.sourceFlagged('mihon:1'), isFalse);
    });

    test('a closed window returns false and keeps the latch', () async {
      flag();
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(code: 'CANCELLED'),
      );
      expect(
        await MihonExtensionService.verifyCloudflare(
          'https://www.natomanga.com/',
        ),
        isFalse,
      );
      expect(CfSolveNeeded.sourceFlagged('mihon:1'), isTrue);
    });

    test('a browser that cannot start is rethrown, latch kept', () async {
      flag();
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(
          code: '0',
          message: 'Cannot create WebViewEnvironment',
        ),
      );
      await expectLater(
        MihonExtensionService.verifyCloudflare('https://www.natomanga.com/'),
        throwsA(isA<PlatformException>()),
      );
      expect(CfSolveNeeded.sourceFlagged('mihon:1'), isTrue);
    });

    test('Windows: the best-effort solve says why it failed', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final shown = <String>[];
      final previous = MihonExtensionService.onDesktopSolveFailure;
      MihonExtensionService.onDesktopSolveFailure = shown.add;
      addTearDown(
        () => MihonExtensionService.onDesktopSolveFailure = previous,
      );
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(
          code: '0',
          message: 'Cannot create WebViewEnvironment',
        ),
      );
      await MihonExtensionService.solveCloudflare('https://www.natomanga.com/');
      expect(shown, ['Cannot create WebViewEnvironment']);

      // Closing the window is not an error worth a message.
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(code: 'CANCELLED'),
      );
      await MihonExtensionService.solveCloudflare('https://www.natomanga.com/');
      expect(shown, hasLength(1));
    });
  });

  group('verifySourceChallengeWithFeedback (Windows)', () {
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    testWidgets(
      'a failed browser shows a message and does not report success',
      (tester) async {
        messenger.setMockMethodCallHandler(
          channel,
          (_) async => throw PlatformException(
            code: '0',
            message: 'Cannot create WebViewEnvironment',
          ),
        );
        late BuildContext context;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (c) {
                  context = c;
                  return const SizedBox();
                },
              ),
            ),
          ),
        );
        late bool verified;
        await tester.runAsync(() async {
          verified = await source_actions.verifySourceChallengeWithFeedback(
            context,
            'mihon:1',
            'https://www.natomanga.com/',
          );
        });
        await tester.pump();
        expect(verified, isFalse);
        expect(
          find.textContaining('Cannot create WebViewEnvironment'),
          findsOneWidget,
        );
      },
      // The Windows branch is chosen by the host OS (dart:io Platform).
      skip: !Platform.isWindows,
    );
  });

  group('browser replay', () {
    tearDown(DesktopFlareSolverr.close);

    test('requests for one site run side by side, not in a queue', () async {
      DesktopFlareSolverr.rememberVerifiedUrl('https://www.natomanga.com/');
      final gate = Completer<void>();
      var started = 0;
      DesktopFlareSolverr.browserRequestOverride = (_) async {
        started++;
        await gate.future;
        return {'status': 'ok'};
      };
      final popular = DesktopFlareSolverr.requestVerified({
        'cmd': 'request.get',
        'url': 'https://www.natomanga.com/manga-list/hot-manga?page=1',
      });
      final latest = DesktopFlareSolverr.requestVerified({
        'cmd': 'request.get',
        'url': 'https://www.natomanga.com/manga-list/latest-manga?page=1',
      });
      await Future<void>.delayed(Duration.zero);
      // Both are in the browser at once: the second does not wait (and so
      // does not run past the engine's 15s limit) behind the first.
      expect(started, 2);
      gate.complete();
      expect(await popular, {'status': 'ok'});
      expect(await latest, {'status': 'ok'});
    });

    test('a replay finishes under the engine read limit', () {
      expect(
        DesktopFlareSolverr.replayTimeout,
        lessThan(const Duration(seconds: 15)),
      );
    });
  });
}
