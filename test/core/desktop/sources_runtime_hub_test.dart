// sources-runtime-hub: unit tests for the Windows source runtime items
// (src-1 isolate gate, src-8 verification de-dupe, src-10 load-failure
// notice, src-11 per-action time limits, src-16 LNReader update detection).
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/desktop_cloudflare.dart';
import 'package:watch_app/core/desktop/extension_load_failures.dart';
import 'package:watch_app/core/desktop/extension_runtime.dart';
import 'package:watch_app/core/desktop/source_timeout.dart';
import 'package:watch_app/core/lnreader/lnreader_extension_service.dart';
import 'package:watch_app/core/lnreader/lnreader_manager.dart';
import 'package:watch_app/core/provider/js_engine.dart';

/// In-memory LNReader service: no Hive, installs recorded in a map.
class _FakeLnrService extends LnReaderExtensionService {
  _FakeLnrService() : super(httpGet: (_) async => '');
  final Map<String, LnReaderPluginMeta> store = {};
  final Set<String> failInstall = {};

  @override
  Future<void> install(LnReaderPluginMeta meta) async {
    if (failInstall.contains(meta.id)) throw StateError('download failed');
    store[meta.id] = meta;
  }

  @override
  List<LnReaderPluginMeta> installed() => store.values.toList();

  @override
  String? jsFor(String id) => store.containsKey(id) ? '/*js*/' : null;
}

/// Plugin meta with just the fields the update logic reads.
LnReaderPluginMeta _meta(String id, String version) => LnReaderPluginMeta(
  id: id,
  name: id,
  site: 'https://$id.test/',
  lang: 'English',
  version: version,
  url: 'https://cdn.test/$id.js',
  iconUrl: '',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('src-1 JsEngine isolate gate', () {
    test('flutter test keeps the host-neutral default (no isolate)', () {
      // Windows turns the isolate on, but never under `flutter test`.
      expect(JsEngine.runsOffUiIsolate, isFalse);
    });
  });

  group('src-8 DesktopCloudflare.solve de-dupe', () {
    tearDown(() => DesktopCloudflare.debugSolveOverride = null);

    test('concurrent requests for one host share one window', () async {
      var opened = 0;
      final gate = Completer<Map<String, dynamic>?>();
      DesktopCloudflare.debugSolveOverride = (url, clearance) {
        opened++;
        return gate.future;
      };
      final a = DesktopCloudflare.solve('https://Site.test/a');
      final b = DesktopCloudflare.solve('https://site.test/b?x=1');
      expect(identical(a, b), isTrue);
      expect(opened, 1);
      gate.complete({'verified': true});
      expect(await a, {'verified': true});
      expect(await b, {'verified': true});
    });

    test('a different host or a sign-in browser opens its own window', () {
      var opened = 0;
      DesktopCloudflare.debugSolveOverride = (url, clearance) {
        opened++;
        return Completer<Map<String, dynamic>?>().future;
      };
      DesktopCloudflare.solve('https://one.test/');
      DesktopCloudflare.solve('https://two.test/');
      DesktopCloudflare.solve('https://one.test/', requireClearance: false);
      expect(opened, 3);
    });

    test('a settled verification lets the next challenge open again', () async {
      var opened = 0;
      DesktopCloudflare.debugSolveOverride = (url, clearance) async {
        opened++;
        return null;
      };
      await DesktopCloudflare.solve('https://again.test/');
      await DesktopCloudflare.solve('https://again.test/');
      expect(opened, 2);
    });

    test('in-flight key is the lower-case host', () {
      expect(DesktopCloudflare.inFlightKey('https://A.Test/x'), 'a.test');
      expect(
        DesktopCloudflare.inFlightKey(
          'https://a.test/',
          requireClearance: false,
        ),
        'sign-in:a.test',
      );
    });
  });

  group('src-11 per-action time limits', () {
    // Covers and lists leave room for a verified-browser replay after a
    // Cloudflare check (engine read 30s + replay up to 25s).
    test('covers 30s, lists 75s, episodes 45s, others 60s', () {
      expect(
        DesktopExtensionRuntime.timeoutFor('getImage'),
        const Duration(seconds: 30),
      );
      expect(
        DesktopExtensionRuntime.timeoutFor('search'),
        const Duration(seconds: 75),
      );
      expect(
        DesktopExtensionRuntime.timeoutFor('getPopular'),
        const Duration(seconds: 75),
      );
      expect(
        DesktopExtensionRuntime.timeoutFor('getEpisodes'),
        const Duration(seconds: 45),
      );
      expect(
        DesktopExtensionRuntime.timeoutFor('getVideoList'),
        const Duration(seconds: 60),
      );
    });

    test('time-outs are recognised however a provider wraps them', () {
      final raw = PlatformException(
        code: DesktopExtensionRuntime.timeoutCode,
        message: 'Source timed out',
      );
      expect(isSourceTimeout(raw), isTrue);
      expect(isSourceTimeout(Exception('$raw')), isTrue);
      expect(isSourceTimeout(TimeoutException('x')), isTrue);
      expect(isSourceTimeout(StateError('boom')), isFalse);
      expect(sourceFailureMessage(StateError('boom'), 'fallback'), 'fallback');
    });
  });

  group('src-14 engine availability cache', () {
    tearDown(() => DesktopExtensionRuntime.debugAvailableOverride = null);

    test('override wins and engineMissing follows it on Windows only', () {
      DesktopExtensionRuntime.debugAvailableOverride = false;
      expect(DesktopExtensionRuntime.isAvailable, isFalse);
      // recheck only clears the cache; it must not throw.
      DesktopExtensionRuntime.recheckAvailability();
      expect(DesktopExtensionRuntime.isAvailable, isFalse);
    });
  });

  group('src-10 extension load failures', () {
    setUp(() {
      ExtensionLoadFailures.debugReset();
      ExtensionLoadFailures.noticeDelay = Duration.zero;
    });
    tearDown(() {
      ExtensionLoadFailures.debugReset();
      debugDefaultTargetPlatformOverride = null;
    });

    test('collects failures, replaces by key and clears by name', () {
      const a = ExtensionLoadFailure(
        ecosystem: 'CloudStream',
        name: 'p1',
        message: 'x',
      );
      ExtensionLoadFailures.report(a);
      ExtensionLoadFailures.report(
        const ExtensionLoadFailure(
          ecosystem: 'CloudStream',
          name: 'p1',
          message: 'y',
        ),
      );
      expect(ExtensionLoadFailures.failures.value.single.message, 'y');
      ExtensionLoadFailures.clear('CloudStream', name: 'p1');
      expect(ExtensionLoadFailures.failures.value, isEmpty);
    });

    test('Retry runs the handler of each failed ecosystem', () async {
      var retried = 0;
      ExtensionLoadFailures.registerRetry('Mihon', () async {
        retried++;
        ExtensionLoadFailures.clear('Mihon');
      });
      ExtensionLoadFailures.registerRetry('Aniyomi', () async => retried += 10);
      ExtensionLoadFailures.report(
        const ExtensionLoadFailure(ecosystem: 'Mihon', name: 'd', message: 'm'),
      );
      await ExtensionLoadFailures.retryAll();
      expect(retried, 1);
      expect(ExtensionLoadFailures.failures.value, isEmpty);
    });

    test('Windows shows one notice for a burst of failures', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final shown = <int>[];
      ExtensionLoadFailures.debugShowNotice = (list) => shown.add(list.length);
      for (final id in ['a', 'b', 'c']) {
        ExtensionLoadFailures.report(
          ExtensionLoadFailure(ecosystem: 'CloudStream', name: id, message: ''),
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
      ExtensionLoadFailures.report(
        const ExtensionLoadFailure(ecosystem: 'Mihon', name: 'd', message: ''),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(shown, [3]);
    });

    test('phone never shows the notice', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      var shown = false;
      ExtensionLoadFailures.debugShowNotice = (_) => shown = true;
      ExtensionLoadFailures.report(
        const ExtensionLoadFailure(ecosystem: 'Mihon', name: 'd', message: ''),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(shown, isFalse);
    });
  });

  group('src-16 LNReader update detection', () {
    late _FakeLnrService service;
    late LnReaderManager manager;

    setUp(() {
      service = _FakeLnrService();
      manager = LnReaderManager(
        service: service,
        fetch: (url, init) async => throw StateError('no runtime in tests'),
      );
    });

    test('compares dotted versions numerically', () {
      expect(LnReaderManager.compareVersions('1.0.10', '1.0.9'), 1);
      expect(LnReaderManager.compareVersions('1.0', '1.0.0'), 0);
      expect(LnReaderManager.compareVersions('2.0.0', '10.0.0'), -1);
      expect(LnReaderManager.compareVersions('', '1.0.0'), -1);
    });

    test('no catalog recorded means no updates', () {
      service.store['a'] = _meta('a', '1.0.0');
      expect(manager.updateCount, 0);
    });

    test('newer repo versions of installed plugins count as updates', () {
      service.store['a'] = _meta('a', '1.0.0');
      service.store['b'] = _meta('b', '2.0.0');
      var notified = 0;
      manager.addListener(() => notified++);
      manager.recordCatalog([
        _meta('a', '1.0.1'),
        _meta('a', '1.2.0'), // a second repo with a higher version wins
        _meta('b', '2.0.0'), // same version: not an update
        _meta('c', '9.9.9'), // not installed: not an update
      ]);
      expect(notified, 1);
      expect(manager.updateCount, 1);
      expect(manager.updates.single.version, '1.2.0');
      expect(manager.hasUpdate('a'), isTrue);
      expect(manager.hasUpdate('b'), isFalse);
    });

    test(
      'updateAll installs the newer versions and keeps failed ones',
      () async {
        service.store['a'] = _meta('a', '1.0.0');
        service.store['b'] = _meta('b', '1.0.0');
        service.failInstall.add('b');
        manager.recordCatalog([_meta('a', '1.1.0'), _meta('b', '1.1.0')]);
        expect(await manager.updateAll(), 1);
        expect(service.store['a']!.version, '1.1.0');
        expect(manager.updates.map((m) => m.id), ['b']);
      },
    );
  });
}
