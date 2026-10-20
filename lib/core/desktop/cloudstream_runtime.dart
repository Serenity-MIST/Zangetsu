import 'cloudstream_settings.dart';
import 'cloudstream_browser.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cs3_engine/cs3_engine.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import '../hive/safe_box.dart';
import '../platform/app_paths.dart';
import 'cloudstream_catalog.dart';
import '../provider/cf_clearance_store.dart';
import 'extension_runtime.dart';
import 'desktop_flaresolverr.dart';
import 'desktop_cloudflare.dart';
import 'java_properties.dart';

/// Adapts the desktop CS3 protocol to Zangetsu's existing Android host contract.
/// Repository URLs are data; no repository-specific execution code is needed.
class DesktopCloudStream {
  DesktopCloudStream({
    this.engineFactory,
    this.dataDirectory,
    CloudStreamCatalog? repositoryClient,
  }) : catalog = repositoryClient ?? CloudStreamCatalog();
  final Future<Cs3Engine> Function(String)? engineFactory;
  final Directory? dataDirectory;
  static final instance = DesktopCloudStream();
  final CloudStreamCatalog catalog;
  Box<dynamic>? _box;
  Cs3Engine? _engine;
  Future<Cs3Engine>? _starting;
  Future<void> _mutation = Future.value();
  Future<dynamic> Function(MethodCall)? onEvent;
  final _links = <String, Map<String, dynamic>>{};

  /// Settings opened by the user may remain visible; unsolicited plugin UI
  /// from a background search is still closed without stealing focus.
  final Set<String> _settingsPlugins = {};

  /// Opens installed-plugin metadata without starting the Java process.
  Future<Box<dynamic>> _store() async =>
      _box ??= await openBoxSafely<dynamic>('desktop_cs_plugins');

  /// Uses the selected storage root, or an injected directory in engine tests.
  Future<Directory> _directory() async =>
      dataDirectory ?? await writableAppSubdir('cloudstream');

  /// Snapshots valid stored plugin records, tolerating unrelated Hive values.
  List<Map<String, dynamic>> get _installed => [
    for (final item in _box?.values ?? const [])
      if (item is Map) Map<String, dynamic>.from(item),
  ];

  /// Flattens plugin providers and attaches the plugin identity for dispatch.
  List<dynamic> _sources() => [
    for (final item in _installed)
      for (final provider in item['providers'] as List? ?? const [])
        if (provider is Map) {...provider, 'sourcePlugin': item['id']},
  ];

  /// Resolves a provider by plugin identity, keeping equal names in different
  /// repositories separate while accepting legacy unqualified host keys.
  ({Map<String, dynamic> entry, String name}) _providerEntry(String key) {
    final parts = key.split('\u0001');
    final name = parts.last;
    final matches = _installed.where((item) =>
        (parts.length == 1 || item['id'] == parts.first) &&
        (item['providers'] as List).any((provider) => provider['name'] == name));
    if (matches.isEmpty) throw StateError('This CloudStream extension is not installed.');
    return (entry: matches.first, name: name);
  }

  /// Restarts the engine around a scoped properties edit so its cached Android
  /// preferences cannot overwrite the reset. Other providers' bytes are retained.
  Future<bool> _resetProvider(String key) async {
    final provider = _providerEntry(key);
    final active = _engine ?? await _starting;
    var url = '${(provider.entry['providers'] as List).firstWhere(
        (item) => item['name'] == provider.name)['mainUrl'] ?? ''}';
    if (active?.isRunning == true) {
      try {
        final current = (await active!.providers()).whereType<Map>().firstWhere(
            (item) => item['name'] == provider.name &&
                item['plugin'] == p.basenameWithoutExtension(provider.entry['path'] as String));
        url = '${current['mainUrl'] ?? url}';
      } catch (_) { /* A broken provider can still have its own state reset. */ }
      await active!.dispose();
    }
    _engine = null;
    _links.clear();
    var cleared = false;
    final file = File(p.join((await _directory()).path, 'shared_prefs', 'rebuild_preference.properties'));
    if (await file.exists()) {
      final result = removeJavaPropertyNamespace(latin1.decode(await file.readAsBytes()), provider.name);
      if (result.removed > 0) {
        final staged = File('${file.path}.reset.part');
        try {
          await staged.writeAsBytes(latin1.encode(result.text), flush: true);
          await staged.rename(file.path);
          cleared = true;
        } finally {
          if (await staged.exists()) await staged.delete();
        }
      }
    }
    final host = Uri.tryParse(url)?.host;
    if (host != null && host.isNotEmpty) {
      cleared = cleared || CfClearanceStore().restore().containsKey(host) ||
          DesktopFlareSolverr.hasVerifiedUrl(url);
      CfClearanceStore().forget(host);
      DesktopFlareSolverr.forgetVerifiedUrl(url);
      // Injected runtimes have private test data and must never touch the real
      // app browser profile. The normal app also clears this site's WebView jar.
      if (dataDirectory == null) {
        cleared = await DesktopCloudflare.clearSiteCookies(url) || cleared;
      }
    }
    await _ready();
    return cleared;
  }

  /// Joins concurrent startup calls and reuses a running engine.
  Future<Cs3Engine> _ready() async {
    if (_engine?.isRunning == true) return _engine!;
    return _starting ??= _start().whenComplete(() => _starting = null);
  }

  /// Starts the bundled runtime and restores plugins; individual restore
  /// failures are logged without preventing other installed providers loading.
  Future<Cs3Engine> _start() async {
    await _store();
    final engine = engineFactory != null
        ? await engineFactory!((await _directory()).path)
        : await Cs3Engine.start(
            dataDir: (await _directory()).path,
            java: p.join(
              DesktopExtensionRuntime.engineDirectory,
              'runtime',
              'bin',
              'javaw.exe',
            ),
          );
    engine.events.listen((event) => unawaited(_event(engine, event)));
    try {
      await engine.hello().timeout(const Duration(seconds: 20));
      if (Hive.isBoxOpen('cs_repos')) {
        final repos = Hive.box('cs_repos').get('repos') as List? ?? [];
        await engine.setRepositories([
          for (final repo in repos)
            if (repo is Map) Map<String, Object?>.from(repo),
        ]);
      }
      for (final item in _installed) {
        try {
          await engine.loadPlugin(
            item['path'] as String,
            url: item['url'] as String,
          );
        } catch (error) {
          debugPrint('[cloudstream] Could not restore ${item['id']}: $error');
        }
      }
      _engine = engine;
      return engine;
    } catch (_) {
      await engine.dispose();
      rethrow;
    }
  }

  /// Waits for installs/removals before terminating the runtime process.
  Future<void> dispose() async {
    await _mutation;
    await _engine?.dispose();
    _engine = null;
  }

  /// Bridges engine browser/repository events into Flutter. Background
  /// challenges are flagged for manual verification instead of opening tabs.
  Future<void> _event(Cs3Engine engine, Map<String, dynamic> event) async {
    try {
      if (event['event'] == 'repositoryAdded') {
        await onEvent?.call(MethodCall('onRepoAdded', event['url']));
      } else if (event['event'] == 'webRequest') {
        final rid = (event['rid'] as num).toInt();
        if (event['op'] == 'solve') {
          final url = event['url'] as String;
          final host = Uri.parse(url).host;
          final sources = _sources().where(
            (item) => Uri.tryParse('${item['mainUrl']}')?.host == host,
          );
          if (sources.isEmpty) {
            await onEvent?.call(
              MethodCall('onCfChallenge', {'host': host, 'url': url}),
            );
          } else {
            for (final source in sources) {
              await onEvent?.call(
                MethodCall('onCfChallenge', {
                  'host': host,
                  'url': url,
                  'sourceId':
                      '${source['sourcePlugin']}\u0001${source['name']}',
                }),
              );
            }
          }
          // Source matching runs many searches in the background. Flag the
          // challenge for the existing Verify action; never open surprise tabs.
          await engine.webReply(rid);
        } else if (event['op'] == 'fetch' || event['op'] == 'resolve') {
          await cloudStreamBrowserRequest(engine, event);
        } else {
          // End unsupported browser requests explicitly instead of leaving a
          // plugin awaiting an answer forever. The error remains visible.
          await engine.webAnswer(rid);
        }
      } else if (event['event'] == 'uiOpened' &&
          !_settingsPlugins.contains(event['plugin'])) {
        await engine.closeUi((event['session'] as num).toInt(), force: true);
      }
    } catch (error) {
      debugPrint('[cloudstream] Browser request failed: $error');
      if (event['rid'] is num) {
        await engine.webAnswer((event['rid'] as num).toInt());
      }
    }
  }

  /// Stable repository suffix that separates identically named plugins.
  /// This is an identity hash, not a cryptographic integrity check.
  static String repoTag(String url) {
    var hash = 0;
    for (final code in url.toLowerCase().codeUnits) {
      hash = (31 * hash + code) & 0xffffffff;
    }
    return hash.toRadixString(16);
  }

  /// Serializes storage mutations while allowing work after a failed mutation.
  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _mutation.then((_) => action());
    _mutation = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  /// Stages and loads a CS3 archive before replacing the previous version.
  /// Failed downloads/loads leave the old installation intact.
  Future<List<dynamic>> _install(Map<String, dynamic> args) async {
    final engine = await _ready();
    final name = '${args['internalName']}';
    if (!RegExp(r'^[a-zA-Z0-9_.-]+$').hasMatch(name)) {
      throw const FormatException('Invalid extension filename.');
    }
    final repo = '${args['repoUrl'] ?? ''}';
    final id = '$name@${args['version']}@${repoTag(repo)}';
    final previous = _installed
        .where(
          (item) => item['internalName'] == name && item['repoUrl'] == repo,
        )
        .toList();
    if (previous.any((item) => item['id'] == id)) return _sources();
    final directory = Directory(p.join((await _directory()).path, 'plugins'));
    await directory.create(recursive: true);
    final file = File(p.join(directory.path, '$id.cs3'));
    final partial = File('${file.path}.part');
    try {
      await catalog.client.downloadUri(
        CloudStreamCatalog.httpUri('${args['url']}'),
        partial.path,
      );
      final bytes = await partial.open();
      final header = await bytes.read(4);
      await bytes.close();
      if (header.length < 4 || header[0] != 0x50 || header[1] != 0x4b) {
        throw const FormatException(
          'The extension download is not a CS3 archive.',
        );
      }
      await partial.rename(file.path);
      final loaded = await engine.loadPlugin(file.path, url: '${args['url']}');
      await _box!.put(id, {
        ...args,
        'id': id,
        'path': file.path,
        'providers': loaded['providers'] ?? [],
        'hasSettings': loaded['hasSettings'] == true,
      });
      for (final old in previous) {
        await engine.unloadPlugin(old['path'] as String);
        await _box!.delete(old['id']);
        final oldFile = File(old['path'] as String);
        if (await oldFile.exists()) await oldFile.delete();
      }
      return _sources();
    } catch (_) {
      if (!_box!.containsKey(id) && await file.exists()) await file.delete();
      rethrow;
    } finally {
      if (await partial.exists()) await partial.delete();
    }
  }

  /// Unloads matching plugins, removes their files/records and drops link cache.
  Future<void> _remove(bool Function(Map<String, dynamic>) matches) async {
    for (final item in _installed.where(matches)) {
      if (_engine?.isRunning == true)
        await _engine!.unloadPlugin(item['path'] as String);
      await _box!.delete(item['id']);
      final file = File(item['path'] as String);
      if (await file.exists()) await file.delete();
    }
    _links.clear();
  }

  /// Dispatches the existing Android host method names to the desktop engine.
  /// Browsing starts Java lazily; installs/removals share the mutation queue.
  Future<dynamic> call(String method, [dynamic arguments]) async {
    await _store();
    final args = arguments is Map
        ? Map<String, dynamic>.from(arguments)
        : <String, dynamic>{};
    switch (method) {
      case 'listSources':
        return _sources();
      case 'addRepo':
        return catalog.fetch('${args['url']}');
      case 'installPlugin':
      case 'updatePlugin':
        return _serial(() => _install(args));
      case 'resetPluginData':
        return _serial(() => _resetProvider('${args['name']}'));
      case 'uninstallPlugin':
        return _serial(() async {
          await _remove(
            (item) =>
                item['internalName'] == args['internalName'] &&
                item['repoUrl'] == args['repoUrl'],
          );
          return _sources();
        });
      case 'deleteRepo':
        return _serial(() async {
          await _remove((item) => (args['files'] as List).contains(item['id']));
          return _sources();
        });
      case 'checkRepoUpdates':
      case 'updateRepo':
        final repo = await catalog.fetch('${args['url']}');
        final updates = <Map<String, dynamic>>[];
        for (final plugin in repo['plugins'] as List) {
          for (final installed in _installed.where(
            (item) =>
                item['repoUrl'] == args['url'] &&
                item['internalName'] == plugin['internalName'],
          )) {
            if ((plugin['version'] as num) > (installed['version'] as num)) {
              updates.add({
                ...Map<String, dynamic>.from(plugin),
                'installedVersion': installed['version'],
                'onlineVersion': plugin['version'],
              });
            }
          }
        }
        if (method == 'checkRepoUpdates') return {'outdated': updates};
        for (final update in updates) {
          await _serial(() => _install({...update, 'repoUrl': args['url']}));
        }
        return {...repo, 'sources': _sources(), 'updated': updates.length};
      case 'cancelLinks':
        _links.remove('${args['name']}|${args['data']}');
        return null;
      case 'pollLinks':
        return _links['${args['name']}|${args['data']}'] ??
            {'sources': [], 'done': true};
    }
    // Installs and resets may replace the engine or its plugin files. Browsing
    // must wait for that mutation to finish before using the shared runtime.
    await _mutation;
    final engine = await _ready();
    await engine.setClearances([
      for (final entry in CfClearanceStore().restore().entries)
        {
          'site': entry.key,
          'userAgent': entry.value.ua,
          'browserOnly': DesktopFlareSolverr.hasVerifiedUrl(
            'https://${entry.key}',
          ),
          'cookies': {
            for (final cookie in entry.value.cookie.split(';'))
              if (cookie.contains('='))
                cookie.substring(0, cookie.indexOf('=')).trim(): cookie
                    .substring(cookie.indexOf('=') + 1)
                    .trim(),
          },
        },
    ]);
    final selected = _providerEntry('${args['apiName'] ?? args['name']}');
    final name = selected.name;
    final plugin = selected.entry['path'] as String;
    switch (method) {
      case 'hasPluginSettings':
        return selected.entry['hasSettings'] == true;
      case 'openPluginSettings':
        _settingsPlugins.add(plugin);
        try {
          await showCloudStreamSettings(engine, plugin);
        } finally {
          _settingsPlugins.remove(plugin);
        }
        return null;
      case 'liveMainUrl':
        // Plugins can change domains in their settings. Query the running API
        // rather than returning the installation-time metadata snapshot.
        final provider = (await engine.providers()).whereType<Map>().firstWhere(
          (item) =>
              item['name'] == name &&
              item['plugin'] == p.basenameWithoutExtension(plugin),
          orElse: () =>
              throw StateError('CloudStream provider $name is unavailable.'),
        );
        return provider['mainUrl'];
      case 'search':
      case 'searchStatus':
        final result = await engine.search(
          name,
          '${args['query']}',
          page: (args['page'] as int?) ?? 1,
          plugin: plugin,
        );
        return method == 'search' ? result['items'] : result;
      case 'load':
        return adaptCloudStreamDetail(
          await engine.load(name, '${args['url']}', plugin: plugin),
          '${args['category'] ?? 'sub'}',
        );
      case 'loadLinks':
        final result = await engine.loadLinks(
          name,
          '${args['data']}',
          timeoutMs: 60000,
          plugin: plugin,
        );
        final mapped = adaptCloudStreamLinks(result);
        if ((mapped['sources'] as List).isEmpty && result['error'] != null)
          throw StateError('${result['error']}');
        if (_links.length >= 24) _links.remove(_links.keys.first);
        _links['${args['name']}|${args['data']}'] = mapped;
        return mapped;
      case 'getHome':
      case 'getMainPagePaged':
        // The engine selects a main-page request by its original name. Paging
        // every request merged unrelated rows and made "See all" repeat Home.
        final categoryData = '${args['data'] ?? ''}';
        final category = categoryData.isNotEmpty ? categoryData : '${args['name'] ?? ''}';
        final result = await engine.call('mainPage', {
          'provider': name,
          'plugin': plugin,
          'page': args['page'] ?? 1,
          if (method == 'getMainPagePaged') 'section': category,
        });
        final provider = (selected.entry['providers'] as List).firstWhere(
            (item) => item['name'] == name);
        final categories = (provider['sections'] as List? ?? const []).toSet();
        final sections = [
          for (final section in result['sections'] as List? ?? const [])
            if (section is Map)
              {
                'title': section['name'], 'items': section['items'] ?? [],
                if (categories.contains(section['name'])) ...{
                  'categoryName': section['name'],
                  'categoryData': section['name'],
                },
              },
        ];
        return method == 'getHome'
            ? jsonEncode(sections)
            : [for (final section in sections) ...section['items'] as List];
      default:
        throw UnsupportedError(
          'CloudStream operation $method is not available on Windows.',
        );
    }
  }
}

/// Converts CS3 details to the app's host payload, including movie data URLs
/// and the requested sub/dub episode list without discarding other metadata.
Map<String, dynamic> adaptCloudStreamDetail(
  Map<String, dynamic> result,
  String category,
) {
  final episodes = [
    for (final item in result['episodes'] as List? ?? const [])
      if (item is Map) Map<String, dynamic>.from(item),
  ];
  final sub = episodes.where((item) => item['dub'] != 'Dubbed').toList();
  final dub = episodes.where((item) => item['dub'] == 'Dubbed').toList();
  return {
    ...result,
    'syncData': result['syncIds'],
    'subCount': sub.length,
    'dubCount': dub.length,
    'episodes': episodes.isEmpty && result['dataUrl'] != null
        ? [
            {'name': result['name'], 'episode': 1, 'data': result['dataUrl']},
          ]
        : category == 'dub' && dub.isNotEmpty
        ? dub
        : sub.isNotEmpty
        ? sub
        : dub,
  };
}

/// Preserves stream/subtitle fields while adding the legacy HLS and DRM keys.
Map<String, dynamic> adaptCloudStreamLinks(Map<String, dynamic> result) => {
  'sources': [
    for (final link in result['links'] as List? ?? const [])
      if (link is Map)
        {
          ...link,
          'isM3u8': link['type'] == 'M3U8',
          if (link['drm'] is Map) 'drmKid': link['drm']['kid'],
          if (link['drm'] is Map) 'drmKey': link['drm']['key'],
        },
  ],
  'subtitles': result['subtitles'] ?? [],
  'done': true,
};
