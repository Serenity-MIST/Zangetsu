import 'desktop_cloudflare.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../logging/app_logger.dart';
import '../platform/app_paths.dart';
import 'desktop_flaresolverr.dart';

/// Authenticated, loopback-only companion for Android extension bytecode.
/// The engine is packaged beside the Windows executable and starts on demand.
class DesktopExtensionRuntime {
  DesktopExtensionRuntime._();
  static final instance = DesktopExtensionRuntime._();

  /// Companion assets stay beside the executable so releases are portable.
  static String get engineDirectory =>
      p.join(p.dirname(Platform.resolvedExecutable), 'extension-engine');

  /// Checks the required jar and Java launcher before desktop startup.
  static bool get isAvailable =>
      Platform.isWindows &&
      File(p.join(engineDirectory, 'miwayomi-all.jar')).existsSync() &&
      File(p.join(engineDirectory, 'runtime', 'bin', 'javaw.exe')).existsSync();

  Process? _process;
  Future<void>? _starting;
  int? _port;
  String? _token;
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
    final log = File(
      p.join(data.path, 'extension-engine.log'),
    ).openWrite(mode: FileMode.append);
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
                decodeResponse(
                  'loadInstalled',
                  await _request('/zangetsu/invoke', {
                    'kind': entry.key,
                    'method': 'loadInstalled',
                    'args': {'dir': directory},
                  }),
                );
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

  /// Sends authenticated loopback JSON with bounded response/body waits.
  Future<dynamic> _request(String path, [Map<String, dynamic>? body]) async {
    final request = await _http.openUrl(
      body == null ? 'GET' : 'POST',
      Uri(scheme: 'http', host: '127.0.0.1', port: _port, path: path),
    );
    request.headers.set('X-Zangetsu-Key', _token!);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close().timeout(
      const Duration(seconds: 120),
    );
    final text = await utf8.decoder
        .bind(response)
        .join()
        .timeout(const Duration(seconds: 120));
    if (response.statusCode != 200) {
      throw PlatformException(
        code: 'DESKTOP_RUNTIME',
        message: 'Extension engine HTTP ${response.statusCode}',
      );
    }
    return jsonDecode(text);
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
          message: 'Verification cancelled',
        );
      }
      // A user may leave a sign-in browser while its site is still challenged.
      // Closing that page must not grant the extension verified-browser access.
      if (session['verified'] != true) return null;
      // The verified site may not issue cf_clearance (or any cookie). The
      // extension still needs the browser's User-Agent for its next request.
      await invoke(kind, 'importCookies', session);
      DesktopFlareSolverr.rememberVerifiedUrl('${session['url']}');
      DesktopFlareSolverr.rememberVerifiedUrl('${args['url']}');
      await invoke(kind, 'clearHttpCache', const <String, dynamic>{});
      return null;
    }
    await ensureStarted();
    final response = await _request('/zangetsu/invoke', {
      'kind': kind,
      'method': method,
      'args': args ?? <String, dynamic>{},
    });
    final result = decodeResponse(method, response);
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
