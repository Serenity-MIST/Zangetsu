import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/hive/safe_box.dart';

import 'lnreader_extension_service.dart';
import 'lnreader_provider.dart';
import 'lnreader_runtime.dart';

/// Owns the shared QuickJS runtime + installed-plugin metadata — the novel
/// twin of `MihonManager` (`lib/core/mihon/mihon_manager.dart`). Deliberately
/// duplicated rather than shared, same rationale as every other *Reader/
/// *Mihon twin in this codebase.
///
/// The laziness invariant this class exists to enforce: neither [init] nor
/// [installedSources] nor [get] nor [metaFor] may build the runtime or load a
/// plugin — they only ever read stored [LnReaderPluginMeta]. A cold boot (or
/// registering a `LnReaderProvider` per installed source, the way
/// `SourceRepository` does for every other provider type) must pay zero
/// LNReader runtime cost when the user never opens a novel source.
///
/// The runtime is built, and a given plugin's JS loaded, only the first time
/// [ensureLoaded] (or [callPlugin], which calls it) runs for that plugin —
/// i.e. only once a `LnReaderProvider` data method is actually invoked.
/// `runtimeBuilt` flips true synchronously the moment [ensureLoaded]
/// constructs the shared [LnReaderRuntime], before its first `await`, so the
/// laziness invariant is observable without awaiting the load to finish.
///
/// It is also a [ChangeNotifier] (src-16) so the providers hub and the
/// LNReader screen can rebuild their update badges when the latest catalog
/// or the installed set changes.
class LnReaderManager with ChangeNotifier {
  LnReaderManager({required this.service, required this.fetch});

  /// Hive box with the user-added repo index URLs (same name as
  /// `kLnReaderReposBoxName` in lnreader_sources_screen.dart; repeated here
  /// so core code does not import a feature screen).
  static const String reposBoxName = 'lnreader_repos';

  /// Newest catalog entry per plugin id from the last repo download. Empty
  /// until a catalog was recorded, so [updateCount] stays 0 until then.
  final Map<String, LnReaderPluginMeta> _latest = {};

  /// One shared in-flight [checkForUpdates] call.
  Future<void>? _checking;

  final LnReaderExtensionService service;
  final Future<LnReaderHttpResponse> Function(String url, Map init) fetch;

  LnReaderRuntime? _runtime;
  final Set<String> _loadedPluginIds = {};
  final Map<String, LnReaderProvider> _providerCache = {};

  /// True once the shared runtime has been constructed — a test seam for the
  /// laziness invariant (must stay false until [ensureLoaded] is first
  /// called).
  @visibleForTesting
  bool get runtimeBuilt => _runtime != null;

  /// Opens the `lnreader_plugins` Hive box. Does NOT build the runtime or
  /// load any plugin — see the laziness invariant above.
  Future<void> init() async {
    if (!Hive.isBoxOpen(LnReaderExtensionService.boxName)) {
      await openBoxSafely<Map>(LnReaderExtensionService.boxName);
    }
  }

  /// One `(id, name)` pair per installed plugin, straight from stored meta —
  /// what `SourceRepository` walks to register a provider per novel source.
  /// SYNC and never touches the runtime.
  List<({String id, String name})> get installedSources => [
    for (final m in service.installed()) (id: 'lnr:${m.id}', name: m.name),
  ];

  /// Looks up a [LnReaderProvider] by its `'lnr:<pluginId>'` [sourceId].
  /// SYNC — constructs (and caches) the provider straight from stored meta;
  /// never builds the runtime or loads the plugin. Returns null when the
  /// plugin isn't installed.
  LnReaderProvider? get(String sourceId) {
    final pluginId = sourceId.startsWith('lnr:')
        ? sourceId.substring(4)
        : sourceId;
    final meta = metaFor(pluginId);
    if (meta == null) return null;
    return _providerCache[pluginId] ??= LnReaderProvider(
      manager: this,
      meta: meta,
    );
  }

  /// The stored metadata for an installed plugin, or null. SYNC.
  LnReaderPluginMeta? metaFor(String pluginId) {
    for (final m in service.installed()) {
      if (m.id == pluginId) return m;
    }
    return null;
  }

  /// Number of installed plugins whose repository lists a newer version.
  /// Same name/shape as `MihonManager.updateCount`.
  int get updateCount => updates.length;

  /// The newer catalog entry for every installed plugin that has one. The
  /// returned metas are what [updateAll] installs.
  List<LnReaderPluginMeta> get updates {
    if (_latest.isEmpty) return const [];
    return [
      for (final m in service.installed())
        if (_latest[m.id] case final newer?
            when compareVersions(newer.version, m.version) > 0)
          newer,
    ];
  }

  /// True when [pluginId] is installed and a newer version is listed.
  bool hasUpdate(String pluginId) => updates.any((m) => m.id == pluginId);

  /// Records the repository catalog the LNReader screen (or
  /// [checkForUpdates]) just downloaded. Replaces the previous one; when two
  /// repos list the same plugin, the higher version wins.
  void recordCatalog(Iterable<LnReaderPluginMeta> entries) {
    _latest.clear();
    for (final m in entries) {
      final known = _latest[m.id];
      if (known == null || compareVersions(m.version, known.version) > 0) {
        _latest[m.id] = m;
      }
    }
    notifyListeners();
  }

  /// Downloads every tracked repository index and records it, so the hub can
  /// show the update count without the LNReader screen being opened. A repo
  /// that fails is skipped. Concurrent calls share one run.
  Future<void> checkForUpdates() =>
      _checking ??= _check().whenComplete(() => _checking = null);

  Future<void> _check() async {
    if (!Hive.isBoxOpen(reposBoxName)) {
      await openBoxSafely<String>(reposBoxName);
    }
    final urls = Hive.box<String>(reposBoxName).values.toList();
    if (urls.isEmpty) return;
    final lists = await Future.wait(
      urls.map((url) async {
        try {
          return await service.fetchIndex(url);
        } catch (_) {
          // An unreachable repo just contributes nothing this time.
          return const <LnReaderPluginMeta>[];
        }
      }),
    );
    recordCatalog([for (final l in lists) ...l]);
  }

  /// Installs every pending update (re-downloads the newer JS) and returns
  /// how many succeeded. A failed one keeps its badge, like Mihon.
  Future<int> updateAll() async {
    var done = 0;
    for (final meta in updates) {
      try {
        await update(meta);
        done++;
      } catch (_) {
        // Keep going; the failed plugin still shows as outdated.
      }
    }
    return done;
  }

  /// Installs [meta] over the installed copy and drops the cached provider
  /// and loaded JS so the next call runs the new version.
  Future<void> update(LnReaderPluginMeta meta) async {
    await service.install(meta);
    _providerCache.remove(meta.id);
    _loadedPluginIds.remove(meta.id);
    if (runtimeBuilt) await _runtime!.unloadPlugin(meta.id);
    notifyListeners();
  }

  /// Compares dotted version strings numerically ('1.0.10' > '1.0.9').
  /// Non-numeric parts compare as 0; missing parts count as 0.
  @visibleForTesting
  static int compareVersions(String a, String b) {
    List<int> parts(String v) => [
      for (final s in v.trim().split(RegExp(r'[.\-+]')))
        int.tryParse(s.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0,
    ];
    final x = parts(a), y = parts(b);
    for (var i = 0; i < (x.length > y.length ? x.length : y.length); i++) {
      final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
      if (d != 0) return d.sign;
    }
    return 0;
  }

  /// Builds the shared runtime (first call only) and loads [pluginId]'s JS
  /// into it (first call per plugin only) — the ONLY place besides
  /// [callPlugin] that does either. Every `LnReaderProvider` data method
  /// awaits this before touching the plugin.
  Future<void> ensureLoaded(String pluginId) async {
    if (_loadedPluginIds.contains(pluginId)) return;
    final js = service.jsFor(pluginId);
    if (js == null) {
      throw StateError('lnreader plugin "$pluginId" is not installed');
    }
    final runtime = _runtime ??= LnReaderRuntime(fetch: fetch);
    await runtime.loadPlugin(pluginId, js);
    _loadedPluginIds.add(pluginId);
  }

  /// Ensures [pluginId] is loaded, then calls `plugin[method](...args)`.
  Future<dynamic> callPlugin(
    String pluginId,
    String method,
    List<Object?> args,
  ) async {
    await ensureLoaded(pluginId);
    return _runtime!.call(pluginId, method, args);
  }

  /// Uninstalls [pluginId]: removes it from storage, drops its cached
  /// provider and loaded-id tracking, and — if the runtime has been built —
  /// evicts its JS from the runtime too. Without this, a later reinstall of
  /// the same id would keep serving the stale cached provider (`get`) or
  /// skip reloading JS (`ensureLoaded` short-circuits on `_loadedPluginIds`).
  Future<void> uninstall(String pluginId) async {
    await service.uninstall(pluginId);
    _providerCache.remove(pluginId);
    _loadedPluginIds.remove(pluginId);
    if (runtimeBuilt) await _runtime!.unloadPlugin(pluginId);
    // Update badges count installed plugins only.
    notifyListeners();
  }

  /// The plugin's own filter schema (`pluginInfo()['filters']`), forwarded
  /// verbatim into `popularNovels` as its default `filters` argument —
  /// confirmed required by the Phase-0 spike (`proven_harness.js`), not
  /// optional the way it is for e.g. Mihon search. Only valid after
  /// [ensureLoaded] has resolved for [pluginId]; returns `{}` if the plugin
  /// carries no filter schema.
  Map<String, dynamic> filtersFor(String pluginId) {
    final filters = _runtime?.pluginInfo(pluginId)['filters'];
    return filters is Map ? Map<String, dynamic>.from(filters) : {};
  }
}
