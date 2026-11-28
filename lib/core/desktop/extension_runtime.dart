import 'desktop_cloudflare.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../logging/app_logger.dart';
import '../platform/app_paths.dart';
import 'desktop_extension_unsupported.dart';
import 'desktop_flaresolverr.dart';
import 'extension_load_failures.dart';

/// Authenticated, loopback-only companion for Android extension bytecode.
/// The engine is packaged beside the Windows executable and starts on demand.
class DesktopExtensionRuntime {
  DesktopExtensionRuntime._();
  static final instance = DesktopExtensionRuntime._();

  /// Companion assets stay beside the executable so releases are portable.
  static String get engineDirectory =>
      p.join(p.dirname(Platform.resolvedExecutable), 'extension-engine');

  /// Checks the required jar and Java launcher before desktop startup.
  /// The disk check runs once and is cached: this getter is read on every
  /// extension call (even per cover image), and two blocking existsSync calls
  /// each time added up. [recheckAvailability] clears it after a failed start.
  static bool get isAvailable =>
      debugAvailableOverride ?? (_available ??= _probeEngineFiles());

  /// Cached result of [_probeEngineFiles]; null until first read.
  static bool? _available;

  /// Lets tests pretend the engine files exist (or not).
  @visibleForTesting
  static bool? debugAvailableOverride;

  /// The actual disk check behind [isAvailable].
  static bool _probeEngineFiles() =>
      Platform.isWindows &&
      File(p.join(engineDirectory, 'miwayomi-all.jar')).existsSync() &&
      File(p.join(engineDirectory, 'runtime', 'bin', 'javaw.exe')).existsSync();

  /// Forgets the cached disk check so the next [isAvailable] reads the disk
  /// again. Called when the engine fails to start and before a user Retry,
  /// e.g. after the app folder was re-extracted while the app was open.
  static void recheckAvailability() => _available = null;

  /// True on Windows when the bundled engine files are missing, so the UI
  /// can explain why Aniyomi/Mihon cannot work instead of hiding them.
  static bool get engineMissing => Platform.isWindows && !isAvailable;

  /// Per-action wait for the engine's reply. A broken source used to hold a
  /// screen (or a cover) for up to 2 x 120s; each action now gets a limit
  /// that fits what it does, then fails with [timeoutCode].
  ///
  /// Cloudflare-protected sources need room: after a verification the engine
  /// may wait on its own read (30s) and then replay the request through the
  /// verified browser (up to 25s), so lists get 75s and covers 30s. Shorter
  /// limits turned a successful verification into SOURCE_TIMEOUT.
  @visibleForTesting
  static Duration timeoutFor(String method) => switch (method) {
    // Covers and image cookies: one browser replay must still fit.
    'getImage' || 'imageCookie' => const Duration(seconds: 30),
    // Browsing lists: a request plus a browser replay must fit.
    'search' ||
    'getPopular' ||
    'getLatest' ||
    'getFilterList' => const Duration(seconds: 75),
    'listSources' => const Duration(seconds: 30),
    // Detail pages, episode and chapter lists.
    'getDetails' ||
    'getEpisodes' ||
    'getChapters' ||
    'getAnimeEpisodeUpdate' ||
    'getAnimeSeasonUpdate' => const Duration(seconds: 45),
    // Installing converts the APK, and restoring loads every extension in a
    // folder: lifecycle work, not a single source request, so it keeps the
    // previous generous limit.
    'installExtension' ||
    'loadInstalled' ||
    'uninstallExtension' => const Duration(seconds: 120),
    // Everything else (video lists, pages, settings, cache clears).
    _ => const Duration(seconds: 60),
  };

  /// PlatformException code thrown when an action exceeds [timeoutFor].
  static const timeoutCode = 'SOURCE_TIMEOUT';

  /// The `importCookies` calls that hand a verified browser [session] to the
  /// engine: one for the page the browser ended on and one for the [original]
  /// address when a redirect moved to another host. The engine keeps only
  /// cookies matching each call's URL and stores the browser User-Agent for
  /// that host, so importing for the final URL alone left the requested host
  /// without its UA (and its cookies) and still challenged.
  @visibleForTesting
  static List<Map<String, dynamic>> verifiedSessionImports(
    String original,
    Map<String, dynamic> session,
  ) {
    final imports = <Map<String, dynamic>>[];
    final hosts = <String>{};
    for (final address in ['${session['url'] ?? ''}', original]) {
      final uri = Uri.tryParse(address);
      if (uri == null ||
          !{'http', 'https'}.contains(uri.scheme) ||
          uri.host.isEmpty) {
        continue;
      }
      // One import per host: the same host twice adds nothing.
      if (!hosts.add(uri.host.toLowerCase())) continue;
      imports.add({...session, 'url': address});
    }
    return imports;
  }

  Process? _process;
  Future<void>? _starting;
  int? _port;
  String? _token;

  /// Full path of the engine's own log (its stack traces land there, not in
  /// the app log). Set when the engine starts; used to point at it when an
  /// extension fails with "Stub!" (plan item B2).
  String? _engineLogPath;
  final Map<String, Set<String>> _sourceDirectories = {};
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5);

  /// Lazily starts one companion process and joins concurrent callers.
  Future<void> ensureStarted() {
    if (_starting != null) return _starting!;
    if (_process != null && _port != null) return Future.value();
    return _starting ??= _start().whenComplete(() => _starting = null);
  }

  /// Starts the authenticated engine and restores known extension folders.
  /// Startup failures close process/log resources and remain retryable.
  Future<void> _start() async {
    try {
      await _startEngine();
      // Started: an earlier "engine failed" entry is no longer true.
      ExtensionLoadFailures.clear(_engineEcosystem);
    } catch (error) {
      // Re-read the disk next time: the files may have been restored.
      recheckAvailability();
      ExtensionLoadFailures.report(
        ExtensionLoadFailure(
          ecosystem: _engineEcosystem,
          // Fixed id; translated on show by extensionFailureText.
          name: 'Aniyomi / Mihon engine',
          message: error is PlatformException
              ? (error.message ?? error.code)
              : '$error',
        ),
      );
      rethrow;
    }
  }

  /// Ecosystem label used for engine-level and folder-restore failures.
  // Fixed id; translated on show by extensionFailureText.
  static const _engineEcosystem = 'Extension engine';

  /// Public name of [_engineEcosystem] so boot reporting can avoid listing
  /// one engine problem twice.
  static const engineEcosystem = _engineEcosystem;

  /// Registers the startup-notice Retry for engine failures once.
  static bool _retryRegistered = false;

  /// Retry from the failure notice: re-read the disk and start again, which
  /// also reloads every known extension folder.
  void _registerRetry() {
    if (_retryRegistered) return;
    _retryRegistered = true;
    ExtensionLoadFailures.registerRetry(_engineEcosystem, () async {
      recheckAvailability();
      await ensureStarted();
      // Started now: re-run the boot steps that failed because of the
      // engine, so their sources are listed again (the engine restart alone
      // only reloads folders it already knew, and registers no providers).
      await runBootSteps();
    });
  }

  /// Startup boot steps (Aniyomi / Mihon in the injector) that failed, by
  /// ecosystem label. A Retry re-runs them so the sources are registered
  /// again, not just reloaded inside the engine.
  static final Map<String, Future<void> Function()> _bootSteps = {};

  /// Remembers [boot] as the way to reload and register [ecosystem]'s
  /// sources (src-10). Called by the boot-failure reporting.
  static void registerBootStep(
    String ecosystem,
    Future<void> Function() boot,
  ) => _bootSteps[ecosystem] = boot;

  /// Runs the registered boot step of [ecosystem] (or of every ecosystem when
  /// null). Each boot step catches and reports its own errors.
  static Future<void> runBootSteps([String? ecosystem]) async {
    final steps = [
      for (final entry in _bootSteps.entries)
        if (ecosystem == null || entry.key == ecosystem) entry.value,
    ];
    for (final step in steps) {
      try {
        await step();
      } catch (_) {
        // A boot step reports its own failure; never break the Retry loop.
      }
    }
  }

  /// Clears the boot-step registry between tests.
  @visibleForTesting
  static void debugResetBootSteps() => _bootSteps.clear();

  /// The actual start (see [_start]).
  Future<void> _startEngine() async {
    _registerRetry();
    if (!isAvailable) {
      throw PlatformException(
        code: 'DESKTOP_RUNTIME',
        message:
            'The Windows extension engine is missing. Extract the complete app folder.',
      );
    }
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _port = socket.port;
    await socket.close();
    final random = Random.secure();
    _token = base64UrlEncode(List.generate(32, (_) => random.nextInt(256)));
    final support = await getWritableAppDirectory();
    final flareSolverr = await DesktopFlareSolverr.ensureStarted();
    final data = Directory(p.join(support.path, 'desktop-extensions'));
    await data.create(recursive: true);
    _engineLogPath = p.join(data.path, 'extension-engine.log');
    final log = File(_engineLogPath!).openWrite(mode: FileMode.append);
    Process? process;
    try {
      process = await Process.start(
        p.join(engineDirectory, 'runtime', 'bin', 'javaw.exe'),
        [
          '-Xmx512m',
          '-Xms64m',
          '-XX:+UseSerialGC',
          '-Dfile.encoding=UTF-8',
          '-jar',
          p.join(engineDirectory, 'miwayomi-all.jar'),
          '--host',
          '127.0.0.1',
          '--port',
          '$_port',
          '--data',
          data.path,
          '--no-open',
          '--flaresolverr',
          flareSolverr.toString(),
        ],
        workingDirectory: engineDirectory,
        environment: {'ZANGETSU_TOKEN': _token!, 'ZANGETSU_PARENT_PID': '$pid'},
      );
      _process = process;
      final stderrDone = process.stderr.forEach(log.add);
      final stdoutDone = process.stdout.forEach(log.add);
      unawaited(
        process.exitCode.then((code) async {
          if (identical(_process, process)) {
            _process = null;
            _port = null;
          }
          await Future.wait([stderrDone, stdoutDone]);
          await log.close();
          AppLogger.instance.log('[desktop-extensions] engine exited ($code)');
        }),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 40));
      while (DateTime.now().isBefore(deadline)) {
        if (!identical(_process, process)) break;
        try {
          final response = await _request('/zangetsu/health');
          if (response is Map && response['service'] == 'zangetsu-extensions') {
            for (final entry in _sourceDirectories.entries) {
              for (final directory in entry.value) {
                // One folder that fails to reload must not fail the whole
                // engine start (it used to loop until the 40s deadline);
                // list it in the startup notice instead.
                try {
                  decodeResponse(
                    'loadInstalled',
                    await _request('/zangetsu/invoke', {
                      'kind': entry.key,
                      'method': 'loadInstalled',
                      'args': {'dir': directory},
                    }, timeoutFor('loadInstalled')),
                  );
                  ExtensionLoadFailures.clear(
                    _ecosystemLabel(entry.key),
                    name: directory,
                  );
                } catch (error) {
                  _reportFolderFailure(entry.key, directory, error);
                }
              }
            }
            AppLogger.instance.log('[desktop-extensions] ready');
            return;
          }
        } catch (_) {}
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      throw PlatformException(
        code: 'DESKTOP_RUNTIME',
        message:
            'The extension engine did not start. Check extension-engine.log.',
      );
    } catch (_) {
      process?.kill();
      if (process == null) await log.close();
      _process = null;
      _port = null;
      rethrow;
    }
  }

  /// Sends authenticated loopback JSON. [limit] bounds the whole exchange
  /// (reply AND body, one deadline instead of two 120s waits); health probes
  /// during startup default to a short 5s so a hung probe cannot eat the
  /// start deadline. Past the limit the request is aborted and a
  /// [timeoutCode] PlatformException is thrown.
  Future<dynamic> _request(
    String path, [
    Map<String, dynamic>? body,
    Duration limit = const Duration(seconds: 5),
  ]) async {
    final request = await _http.openUrl(
      body == null ? 'GET' : 'POST',
      Uri(scheme: 'http', host: '127.0.0.1', port: _port, path: path),
    );
    request.headers.set('X-Zangetsu-Key', _token!);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    Future<(int, String)> exchange() async {
      final response = await request.close();
      final text = await utf8.decoder.bind(response).join();
      return (response.statusCode, text);
    }

    final (int status, String text) reply;
    try {
      reply = await exchange().timeout(limit);
    } on TimeoutException {
      // Drop the connection so the engine's late reply is discarded.
      request.abort();
      throw PlatformException(
        code: timeoutCode,
        // Exception text for logs; screens show sourceFailureMessage instead.
        message: 'Source timed out',
        details: '${body?['method'] ?? path} after ${limit.inSeconds}s',
      );
    }
    if (reply.$1 != 200) {
      throw PlatformException(
        code: 'DESKTOP_RUNTIME',
        message: 'Extension engine HTTP ${reply.$1}',
      );
    }
    return jsonDecode(reply.$2);
  }

  /// Display name of an engine kind ('aniyomi' / 'mihon') for the notice.
  static String _ecosystemLabel(String kind) =>
      kind == 'mihon' ? 'Mihon' : 'Aniyomi';

  /// Lists a folder of extensions that failed to load in the startup notice,
  /// with a Retry that reloads just that folder.
  void _reportFolderFailure(String kind, String directory, Object error) {
    final ecosystem = _ecosystemLabel(kind);
    ExtensionLoadFailures.registerRetry(ecosystem, () async {
      // Only real folder entries: the same ecosystem can also hold a
      // non-folder entry (e.g. a boot-step failure) that is not a path.
      final failed = [
        for (final f in ExtensionLoadFailures.failures.value)
          if (f.ecosystem == ecosystem && p.isAbsolute(f.name)) f.name,
      ];
      var anyLoaded = false;
      for (final dir in failed) {
        try {
          await invoke(kind, 'loadInstalled', {'dir': dir});
          // Loaded now: drop it from the notice.
          ExtensionLoadFailures.clear(ecosystem, name: dir);
          anyLoaded = true;
        } catch (error) {
          // Still failing: refresh the reason and keep retrying the others.
          _reportFolderFailure(kind, dir, error);
        }
      }
      // Reloading a folder inside the engine does not register its sources
      // in the app; the boot step (when one failed) lists and registers them.
      if (anyLoaded) await runBootSteps(ecosystem);
    });
    ExtensionLoadFailures.report(
      ExtensionLoadFailure(
        ecosystem: ecosystem,
        name: directory,
        message: error is PlatformException
            ? (error.message ?? error.code)
            : '$error',
      ),
    );
  }

  /// Preserves the native method contract on Windows: verification uses local
  /// UI, while extension operations dispatch to the companion Java engine.
  Future<Object?> invoke(String kind, String method, Object? args) async {
    if (method == 'solveCloudflare' || method == 'openSourceWebView') {
      final session = await DesktopCloudflare.solve(
        '${(args as Map)['url']}',
        requireClearance: method == 'solveCloudflare',
      );
      if (session == null) {
        throw PlatformException(
          code: 'CANCELLED',
          // Exception text for logs; CANCELLED is handled quietly by callers.
          message: 'Verification cancelled',
        );
      }
      // A user may leave a sign-in browser while its site is still challenged.
      // Closing that page must not grant the extension verified-browser access.
      if (session['verified'] != true) {
        // A verification that did not pass must not look like success to the
        // caller, which would otherwise reload straight into the challenge.
        if (method == 'solveCloudflare') {
          throw PlatformException(
            code: 'CANCELLED',
            message: 'Verification not completed',
          );
        }
        return null;
      }
      // Hand the browser session to the engine for every host involved.
      for (final request in verifiedSessionImports(
        '${args['url']}',
        session,
      )) {
        await invoke(kind, 'importCookies', request);
      }
      DesktopFlareSolverr.rememberVerifiedUrl('${session['url']}');
      DesktopFlareSolverr.rememberVerifiedUrl('${args['url']}');
      await invoke(kind, 'clearHttpCache', const <String, dynamic>{});
      return null;
    }
    await ensureStarted();
    final Object? result;
    try {
      // Each action gets its own time limit (covers 15s, search 30s, ...).
      final response = await _request('/zangetsu/invoke', {
        'kind': kind,
        'method': method,
        'args': args ?? <String, dynamic>{},
      }, timeoutFor(method));
      result = decodeResponse(method, response);
    } catch (error) {
      // "Stub!" means the extension used an Android class the Windows engine
      // only has as an empty stand-in (XAnime: android.util.LruCache). The
      // stack trace naming that class is only in the engine's own log, so
      // say where to look (plan item B2).
      if (DesktopExtensionUnsupported.isStubError(error)) {
        AppLogger.instance.log(
          '[desktop-extensions] $method failed with "Stub!": the extension '
          'uses an Android feature the Windows engine does not support yet. '
          'Stack trace: '
          '${_engineLogPath ?? r'desktop-extensions\extension-engine.log'}',
        );
      }
      // A folder of installed extensions that will not load (e.g. at boot)
      // is listed in the startup notice instead of only failing silently.
      if (method == 'loadInstalled' && args is Map && args['dir'] is String) {
        _reportFolderFailure(kind, args['dir'] as String, error);
      }
      rethrow;
    }
    if (method == 'loadInstalled' && args is Map && args['dir'] is String) {
      ExtensionLoadFailures.clear(
        _ecosystemLabel(kind),
        name: args['dir'] as String,
      );
    }
    if (args is Map &&
        (method == 'loadInstalled' || method == 'installExtension')) {
      final directory = method == 'loadInstalled'
          ? args['dir']
          : p.dirname('${args['apkPath']}');
      if (directory is String && directory.isNotEmpty) {
        (_sourceDirectories[kind] ??= {}).add(directory);
      }
    }
    return result;
  }

  /// Preserve Android's channel return types, including binary image replies.
  static Object? decodeResponse(String method, dynamic response) {
    if (response is! Map) {
      throw const FormatException('Invalid extension reply');
    }
    final error = response['error'];
    if (error is Map) {
      throw PlatformException(
        code: '${error['code'] ?? 'EXTENSION'}',
        message: '${error['message'] ?? 'Extension failed'}',
        details: error['details'],
      );
    }
    final result = response['result'];
    if (method == 'getImage' && result is String) {
      return Uint8List.fromList(base64Decode(result));
    }
    return result;
  }

  /// Terminates the owned process and closes its HTTP client on shutdown.
  void dispose() {
    _process?.kill();
    _http.close(force: true);
  }
}

/// Keep Android's transport and existing tests; use the bundled desktop
/// runtime on Windows. One bridge serves manga and anime without ID remapping.
class ExtensionChannel extends MethodChannel {
  const ExtensionChannel(super.name);

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    if (!DesktopExtensionRuntime.isAvailable ||
        Platform.environment['FLUTTER_TEST'] == 'true') {
      return super.invokeMethod<T>(method, arguments);
    }
    final result = await DesktopExtensionRuntime.instance.invoke(
      name.endsWith('/mihon') ? 'mihon' : 'aniyomi',
      method,
      arguments,
    );
    return result as T?;
  }
}
