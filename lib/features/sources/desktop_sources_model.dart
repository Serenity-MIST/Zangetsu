// Data model for the Windows two-pane Sources manager
// (desktop_sources_manager.dart).
//
// The top half is pure (no GetIt, no Hive, no widgets) so filtering, pin
// order, labels and the add-repo heuristics can be unit tested. The bottom
// half, [collectDesktopSources], reads every ecosystem's manager directly.
// It deliberately does NOT go through `categorizedSources()`: that function
// drops disabled, language-filtered and NSFW sources, and a manager that
// hides disabled sources leaves no way to switch them back on.

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:zangetsu_source_bridge/zangetsu_source_bridge.dart';

import '../../core/aniyomi/aniyomi_provider.dart';
import '../../core/di/injector.dart';
import '../../core/hive/source_icon_store.dart';
import '../../core/i18n/source_languages.dart';
import '../../core/lnreader/lnreader_manager.dart';
import '../../core/mangayomi/mangayomi_manager.dart';
import '../../core/mihon/mihon_manager.dart';
import '../../core/models/provider_info.dart';
import '../../core/playback/source_health_store.dart';
import '../../core/provider/cloudstream_provider.dart';
import '../../core/provider/provider_manager.dart';
import '../../core/provider/provider_registry.dart';
import '../../core/provider/provider_repo_registry.dart';
import '../../core/stremio/stremio_manager.dart';
import 'aniyomi_repo_tab.dart' show kAniyomiReposBoxName;
import 'bloc/sources_state.dart';
import 'mihon_repo_tab.dart' show kMihonReposBoxName;
import 'sources_search_field.dart' show sourceSearchMatches;

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

/// Every extension ecosystem the app can install sources from.
enum DesktopEcosystem {
  zangetsu,
  cloudstream,
  aniyomi,
  mihon,
  lnreader,
  mangayomi,
  stremio,
}

/// Display names for [DesktopEcosystem]. Brand names, so not translated.
extension DesktopEcosystemLabel on DesktopEcosystem {
  /// The ecosystem's own name, as the old per-ecosystem screens titled it.
  String get label => switch (this) {
    DesktopEcosystem.zangetsu => 'Zangetsu',
    DesktopEcosystem.cloudstream => 'CloudStream',
    DesktopEcosystem.aniyomi => 'Aniyomi',
    DesktopEcosystem.mihon => 'Mihon',
    DesktopEcosystem.lnreader => 'LNReader',
    DesktopEcosystem.mangayomi => 'Mangayomi',
    DesktopEcosystem.stremio => 'Stremio',
  };
}

/// The filter chips above the source list. Streaming covers anime and
/// movies/TV together (one playback pool, same as the old Streaming tab).
enum DesktopSourceKind { streaming, manga, novel }

// ---------------------------------------------------------------------------
// Entries
// ---------------------------------------------------------------------------

/// One installed source, from any ecosystem, flattened to what the manager
/// draws and acts on.
@immutable
class DesktopSourceEntry {
  const DesktopSourceEntry({
    required this.id,
    required this.name,
    required this.ecosystem,
    required this.kind,
    this.lang = '',
    this.version = '',
    this.iconUrl,
    this.repoUrl = '',
    this.repoName = '',
    this.enabled = true,
    this.hasUpdate = false,
    this.updateLabel,
    this.nsfw = false,
    this.canDisable = false,
    this.contentLabel = '',
    this.registryKey = '',
    this.pkg = '',
  });

  /// The app-wide source id (`cs:…`, `ani:…`, `mihon:…`, `lnr:…`, `mg:…`,
  /// a bare Zangetsu id). For Stremio it is `stremio-addon:<addon id>`,
  /// since Stremio add-ons are not separately browsable sources.
  final String id;

  /// The source's own name, without any ecosystem prefix.
  final String name;
  final DesktopEcosystem ecosystem;
  final DesktopSourceKind kind;

  /// Language code (`en`, `all`…) or, for LNReader, the native language
  /// name the LNReader index uses. Empty when unknown.
  final String lang;

  /// Version string without a leading `v`. Empty when unknown.
  final String version;
  final String? iconUrl;

  /// The repository the source was installed from, when known.
  final String repoUrl;

  /// Readable name of that repository (or the ecosystem when unknown).
  final String repoName;
  final bool enabled;
  final bool hasUpdate;

  /// What the update installs (e.g. 'v15'), when known.
  final String? updateLabel;
  final bool nsfw;

  /// Whether this ecosystem has an enable/disable switch (Aniyomi, Mihon,
  /// LNReader and Mangayomi do not).
  final bool canDisable;

  /// 'Anime', 'Movies & TV', 'Manga' or 'Novel' for the footer line.
  final String contentLabel;

  /// Zangetsu only: the registry's composite key (`repo::id`).
  final String registryKey;

  /// Aniyomi / Mihon only: the extension package the source belongs to.
  final String pkg;

  /// Stremio add-ons are configured, not browsed: they have no catalogue
  /// page of their own in this app.
  bool get browsable => ecosystem != DesktopEcosystem.stremio;

  /// Pinning feeds the source switcher, which lists browsable sources only.
  bool get pinnable => browsable;

  /// Stremio add-on id (the part after `stremio-addon:`).
  String get stremioAddonId => id.startsWith(stremioAddonPrefix)
      ? id.substring(stremioAddonPrefix.length)
      : id;

  /// Prefix of the synthetic ids given to Stremio add-ons.
  static const stremioAddonPrefix = 'stremio-addon:';
}

/// One repository (or Stremio-free equivalent) added in any ecosystem.
@immutable
class DesktopRepoEntry {
  const DesktopRepoEntry({
    required this.ecosystem,
    required this.url,
    required this.name,
    this.sourceCount,
    this.updateCount = 0,
  });

  final DesktopEcosystem ecosystem;
  final String url;
  final String name;

  /// Installed sources that came from this repo, or null when the ecosystem
  /// does not record which repo a source came from (Aniyomi, Mihon,
  /// LNReader).
  final int? sourceCount;

  /// Installed sources from this repo with a pending update.
  final int updateCount;

  /// Stable id used for selection and widget keys.
  String get key => 'repo:${ecosystem.name}:$url';
}

/// Everything the manager lists, read in one pass.
@immutable
class DesktopSourcesSnapshot {
  const DesktopSourcesSnapshot({
    this.sources = const [],
    this.repos = const [],
  });

  final List<DesktopSourceEntry> sources;
  final List<DesktopRepoEntry> repos;

  /// True when there is nothing to show at all (the empty state).
  bool get isEmpty => sources.isEmpty && repos.isEmpty;

  /// Total pending updates across every installed source.
  int get updateCount => sources.where((s) => s.hasUpdate).length;
}

// ---------------------------------------------------------------------------
// Pure helpers
// ---------------------------------------------------------------------------

/// Narrows [entries] to the chip [kind] (null = All) and the search [query]
/// (name, ecosystem, repo, or an exact language code), then orders the
/// result: pinned sources first in [pinned] order, everything else by name.
///
/// Disabled and NSFW sources are KEPT: this is the manager, and a source you
/// cannot see is a source you cannot switch back on.
List<DesktopSourceEntry> filterDesktopSources(
  List<DesktopSourceEntry> entries, {
  DesktopSourceKind? kind,
  String query = '',
  List<String> pinned = const [],
}) {
  bool matches(DesktopSourceEntry e) =>
      sourceSearchMatches(query, e.name, e.lang) ||
      sourceSearchMatches(query, e.ecosystem.label) ||
      (e.repoName.isNotEmpty && sourceSearchMatches(query, e.repoName));
  final seen = <String>{};
  final visible = [
    for (final e in entries)
      if ((kind == null || e.kind == kind) && matches(e) && seen.add(e.id)) e,
  ];
  final pinIndex = {for (var i = 0; i < pinned.length; i++) pinned[i]: i};
  visible.sort((a, b) {
    final pa = a.pinnable ? pinIndex[a.id] : null;
    final pb = b.pinnable ? pinIndex[b.id] : null;
    if (pa != null && pb != null) return pa.compareTo(pb);
    if (pa != null) return -1;
    if (pb != null) return 1;
    final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return byName != 0 ? byName : a.ecosystem.index - b.ecosystem.index;
  });
  return visible;
}

/// Short language tag for the list row ('EN', 'ALL', or LNReader's native
/// name unchanged). Empty when the source reports none.
String desktopLangTag(String lang) {
  final l = lang.trim();
  if (l.isEmpty) return '';
  // Codes are short and ASCII ('en', 'pt-BR', 'all'); anything longer is a
  // native language name (LNReader) and is shown as-is.
  if (l.length <= 5 && RegExp(r'^[A-Za-z-]+$').hasMatch(l)) {
    return l.toUpperCase();
  }
  return l;
}

/// Full language name for the details pane ('English', 'All languages').
String desktopLangName(String lang) {
  final l = lang.trim();
  if (l.isEmpty) return '';
  if (l.toLowerCase() == 'all' || l.toLowerCase() == 'multi') {
    return 'All languages';
  }
  final label = sourceLangLabel(l);
  return label == l ? desktopLangTag(l) : label;
}

/// The second line of a list row: 'Aniyomi · EN'.
String desktopSourceSubtitle(DesktopSourceEntry e) {
  final tag = desktopLangTag(e.lang);
  return [e.ecosystem.label, if (tag.isNotEmpty) tag].join(' · ');
}

/// Word for a health status in the details pane, or null when the source
/// was never checked (the status part is then left out).
String? desktopHealthWord(SourceHealth? status, {String working = 'Working'}) =>
    switch (status) {
      SourceHealth.ok => working,
      SourceHealth.slow => 'Slow',
      SourceHealth.dead => 'Not responding',
      null => null,
    };

/// The details-pane health line parts, in order:
/// status (if known), 'Disabled' (if so), ecosystem, version, language.
List<String> desktopHealthParts(
  DesktopSourceEntry e, {
  String? statusWord,
}) {
  final lang = desktopLangName(e.lang);
  return [
    ?statusWord,
    if (!e.enabled) 'Disabled',
    e.ecosystem.label,
    if (e.version.isNotEmpty) 'v${e.version.replaceFirst(RegExp('^v'), '')}',
    if (lang.isNotEmpty) lang,
  ];
}

/// 'today', 'yesterday', '3 days ago', or a date for older checks.
String desktopRelativeDay(DateTime when, DateTime now) {
  final a = DateTime(when.year, when.month, when.day);
  final b = DateTime(now.year, now.month, now.day);
  final days = b.difference(a).inDays;
  if (days <= 0) return 'today';
  if (days == 1) return 'yesterday';
  if (days < 30) return '$days days ago';
  return '${when.year}-${when.month.toString().padLeft(2, '0')}-'
      '${when.day.toString().padLeft(2, '0')}';
}

/// The details-pane footer: 'Repository: X · Last checked: today ·
/// Content: Anime'. Parts with nothing to say are left out.
String desktopFooterLine(
  DesktopSourceEntry e, {
  DateTime? checkedAt,
  DateTime? now,
}) {
  return [
    if (e.repoName.isNotEmpty) 'Repository: ${e.repoName}',
    if (checkedAt != null)
      'Last checked: ${desktopRelativeDay(checkedAt, now ?? DateTime.now())}',
    if (e.contentLabel.isNotEmpty) 'Content: ${e.contentLabel}',
  ].join('  ·  ');
}

/// 'CNC Repo · 1 source' for the repository list.
String desktopRepoSubtitle(DesktopRepoEntry r) {
  final count = r.sourceCount;
  return [
    r.ecosystem.label,
    if (count != null) '$count source${count == 1 ? '' : 's'}',
    if (r.updateCount > 0)
      '${r.updateCount} update${r.updateCount == 1 ? '' : 's'}',
  ].join(' · ');
}

/// Content label for a [DesktopSourceKind] when the ecosystem says no more.
String desktopKindContent(DesktopSourceKind kind) => switch (kind) {
  DesktopSourceKind.streaming => 'Anime',
  DesktopSourceKind.manga => 'Manga',
  DesktopSourceKind.novel => 'Novel',
};

/// Short readable name for a repo URL: the GitHub 'owner/repo', else the
/// host, else the URL itself.
String desktopRepoNameFromUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return url;
  final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  final githubish =
      uri.host.contains('github') || uri.host.contains('jsdelivr');
  if (githubish && segs.length >= 2) {
    // raw.githubusercontent.com/<owner>/<repo>/…, github.com/<owner>/<repo>,
    // cdn.jsdelivr.net/gh/<owner>/<repo>@branch/…
    final start = segs.first == 'gh' && segs.length >= 3 ? 1 : 0;
    final repo = segs[start + 1].split('@').first;
    return '${segs[start]}/$repo';
  }
  return uri.host;
}

// ---------------------------------------------------------------------------
// Reading the managers
// ---------------------------------------------------------------------------

/// Repository box names this file reads for Aniyomi / Mihon / LNReader.
const List<String> desktopRepoBoxNames = [
  kAniyomiReposBoxName,
  kMihonReposBoxName,
  LnReaderManager.reposBoxName,
];

/// An already-open Hive box whatever its value type, or null. Hive refuses
/// `Hive.box<dynamic>` for a box opened as `Box<String>` / `Box<Map>`, so
/// the known types are tried in turn.
Box<dynamic>? desktopOpenBox(String name) {
  if (!Hive.isBoxOpen(name)) return null;
  for (final open in <Box<dynamic> Function()>[
    () => Hive.box<String>(name),
    () => Hive.box<Map>(name),
    () => Hive.box<dynamic>(name),
  ]) {
    try {
      return open();
    } catch (_) {}
  }
  return null;
}

/// URLs stored in a repo box, or empty when the box is not open. The
/// manager opens the boxes once (see `DesktopSourcesManager`), so a closed
/// box only means 'not loaded yet'.
List<String> _repoBoxUrls(String boxName) {
  if (!Hive.isBoxOpen(boxName)) return const [];
  try {
    return desktopOpenBox(boxName)?.values.map((v) => '$v').toList() ??
        const [];
  } catch (_) {
    return const [];
  }
}

/// Reads every registered ecosystem into one [DesktopSourcesSnapshot].
///
/// Every manager lookup is guarded with `sl.isRegistered` and every
/// ecosystem is read inside its own try/catch: one broken ecosystem (or a
/// test that registers only a few managers) must not blank the whole list.
DesktopSourcesSnapshot collectDesktopSources() {
  final sources = <DesktopSourceEntry>[];
  final repos = <DesktopRepoEntry>[];
  // Each reader appends to the lists above; failures are logged and skipped.
  void guarded(String what, void Function() read) {
    try {
      read();
    } catch (e) {
      debugPrint('[DesktopSources] could not read $what: $e');
    }
  }

  guarded('Zangetsu', () => _readZangetsu(sources, repos));
  guarded('CloudStream', () => _readCloudStream(sources, repos));
  guarded('Aniyomi', () => _readAniyomi(sources, repos));
  guarded('Mihon', () => _readMihon(sources, repos));
  guarded('LNReader', () => _readLnReader(sources, repos));
  guarded('Mangayomi', () => _readMangayomi(sources, repos));
  guarded('Stremio', () => _readStremio(sources));

  // A CloudStream 'mixed' provider can be reported twice; ids are unique.
  final seen = <String>{};
  return DesktopSourcesSnapshot(
    sources: [
      for (final s in sources)
        if (seen.add(s.id)) s,
    ],
    repos: repos,
  );
}

/// Zangetsu JS providers and their repos.
void _readZangetsu(
  List<DesktopSourceEntry> out,
  List<DesktopRepoEntry> repoOut,
) {
  if (!sl.isRegistered<ProviderRegistry>()) return;
  final reg = sl<ProviderRegistry>();
  final installed = reg.getAll();
  final repos = sl.isRegistered<ProviderReposRegistry>()
      ? sl<ProviderReposRegistry>().getAll()
      : const <ProviderRepo>[];
  // Manifest types/logos and NSFW flags are cosmetic: a registry that
  // cannot answer (e.g. a test fake) still lists its sources.
  var types = const <String, String>{};
  var logos = const <String, String>{};
  var nsfw = const <String>{};
  try {
    final maps = reg.manifestMapsOf();
    types = maps.types;
    logos = maps.logos;
  } catch (_) {}
  try {
    nsfw = reg.nsfwSourceIds();
  } catch (_) {}
  final state = SourcesState(installed: installed, repos: repos);
  final updatable = state.updatableKeys;
  final manifestVersions = state.manifestVersions;
  final repoByUrl = {for (final r in repos) r.url: r};
  final langById = <String, String>{
    for (final r in repos)
      for (final s in r.sources) s.id: s.lang,
  };

  for (final e in installed) {
    final key = ProviderRegistry.providerKey(e.originRepoUrl, e.name);
    final type = types[e.name];
    final kind = switch (type) {
      'manga' => DesktopSourceKind.manga,
      'novel' => DesktopSourceKind.novel,
      _ => DesktopSourceKind.streaming,
    };
    final logo = logos[e.name] ?? e.logoUrl;
    final repo = repoByUrl[e.originRepoUrl];
    final has = updatable.contains(key);
    out.add(
      DesktopSourceEntry(
        id: e.name,
        name: e.displayName.isNotEmpty ? e.displayName : e.name,
        ecosystem: DesktopEcosystem.zangetsu,
        kind: kind,
        lang: langById[e.name] ?? '',
        version: e.version,
        iconUrl: logo.isEmpty ? null : logo,
        repoUrl: e.originRepoUrl,
        repoName:
            repo?.displayName ??
            (e.isBundled ? 'Built in' : desktopRepoNameFromUrl(e.originRepoUrl)),
        enabled: e.enabled,
        hasUpdate: has,
        updateLabel: has && manifestVersions[key] != null
            ? 'v${manifestVersions[key]}'
            : null,
        nsfw: nsfw.contains(e.name),
        canDisable: true,
        contentLabel: switch (type) {
          'anime' => 'Anime',
          'manga' => 'Manga',
          'novel' => 'Novel',
          _ => 'Movies & TV',
        },
        registryKey: key,
      ),
    );
  }
  for (final r in repos) {
    repoOut.add(
      DesktopRepoEntry(
        ecosystem: DesktopEcosystem.zangetsu,
        url: r.url,
        name: r.displayName,
        sourceCount: installed.where((e) => e.originRepoUrl == r.url).length,
        updateCount: updatable
            .where((k) => ProviderRegistry.repoUrlOf(k) == r.url)
            .length,
      ),
    );
  }
}

/// CloudStream plugins (grouped by repo in the manager).
void _readCloudStream(
  List<DesktopSourceEntry> out,
  List<DesktopRepoEntry> repoOut,
) {
  if (!sl.isRegistered<CloudStreamManager>()) return;
  final mgr = sl<CloudStreamManager>();
  final groups = mgr.repoGroups;
  // Same lookup the old picker used: loaded plugins carry no icon, only the
  // repo catalogue entry they were installed from does.
  final icons = <String, String>{};
  for (final g in groups) {
    for (final s in g.sources) {
      final internal = s.sourcePlugin?.split('@').first;
      if (internal == null) continue;
      for (final p in g.catalog) {
        if (p.internalName == internal && p.iconUrl != null) {
          icons[s.sourceId] = p.iconUrl!;
          break;
        }
      }
    }
  }
  for (final g in groups) {
    for (final p in g.sources) {
      final internal = (p.sourcePlugin ?? p.name).split('@').first;
      CsPluginMeta? meta;
      for (final m in g.catalog) {
        if (m.internalName == internal) {
          meta = m;
          break;
        }
      }
      final update = g.url.isEmpty ? null : mgr.updateFor(internal, g.url);
      final anime = p.providerType == ProviderType.anime;
      out.add(
        DesktopSourceEntry(
          id: p.sourceId,
          name: p.displayName,
          ecosystem: DesktopEcosystem.cloudstream,
          kind: DesktopSourceKind.streaming,
          lang: meta?.language ?? p.lang,
          version: meta == null ? '' : '${meta.version}',
          iconUrl: icons[p.sourceId],
          repoUrl: g.url,
          repoName: g.name.isNotEmpty ? g.name : 'CloudStream',
          enabled: mgr.isEnabled(p.sourceId),
          hasUpdate: update != null,
          updateLabel: update == null ? null : 'v${update.onlineVersion}',
          canDisable: true,
          contentLabel: anime && p.supportsMovies
              ? 'Anime, Movies & TV'
              : anime
              ? 'Anime'
              : 'Movies & TV',
        ),
      );
    }
    if (g.url.isNotEmpty) {
      repoOut.add(
        DesktopRepoEntry(
          ecosystem: DesktopEcosystem.cloudstream,
          url: g.url,
          name: g.name.isNotEmpty ? g.name : desktopRepoNameFromUrl(g.url),
          sourceCount: g.sources.length,
          updateCount: mgr.updatesFor(g.url).length,
        ),
      );
    }
  }
}

/// Aniyomi extensions. No enable/disable switch exists for them.
void _readAniyomi(
  List<DesktopSourceEntry> out,
  List<DesktopRepoEntry> repoOut,
) {
  if (!sl.isRegistered<AniyomiManager>()) return;
  final mgr = sl<AniyomiManager>();
  for (final p in mgr.all) {
    final ani = p is AniyomiProvider ? p : null;
    final update = ani == null ? null : mgr.updateFor(ani.info.pkg);
    out.add(
      DesktopSourceEntry(
        id: p.sourceId,
        name: p.displayName,
        ecosystem: DesktopEcosystem.aniyomi,
        kind: DesktopSourceKind.streaming,
        lang: ani?.info.lang ?? '',
        version: ani?.info.version ?? '',
        iconUrl: ani == null ? null : SourceIconStore.urlFor(ani.info.pkg),
        repoName: 'Aniyomi',
        hasUpdate: update != null,
        updateLabel: update == null ? null : 'v${update.availableVersion}',
        nsfw: ani?.info.nsfw ?? false,
        contentLabel: 'Anime',
        pkg: ani?.info.pkg ?? '',
      ),
    );
  }
  for (final url in _repoBoxUrls(kAniyomiReposBoxName)) {
    repoOut.add(
      DesktopRepoEntry(
        ecosystem: DesktopEcosystem.aniyomi,
        url: url,
        name: desktopRepoNameFromUrl(url),
        updateCount: mgr.updatesFor(url).length,
      ),
    );
  }
}

/// Mihon manga extensions.
void _readMihon(List<DesktopSourceEntry> out, List<DesktopRepoEntry> repoOut) {
  if (!sl.isRegistered<MihonManager>()) return;
  final mgr = sl<MihonManager>();
  for (final p in mgr.all) {
    final update = mgr.updateFor(p.pkg);
    out.add(
      DesktopSourceEntry(
        id: p.sourceId,
        name: p.displayName,
        ecosystem: DesktopEcosystem.mihon,
        kind: DesktopSourceKind.manga,
        lang: p.info.lang,
        version: p.info.version,
        iconUrl: SourceIconStore.urlFor(p.pkg),
        repoName: 'Mihon',
        hasUpdate: update != null,
        updateLabel: update == null ? null : 'v${update.availableVersion}',
        nsfw: p.info.nsfw,
        contentLabel: 'Manga',
        pkg: p.pkg,
      ),
    );
  }
  for (final url in _repoBoxUrls(kMihonReposBoxName)) {
    repoOut.add(
      DesktopRepoEntry(
        ecosystem: DesktopEcosystem.mihon,
        url: url,
        name: desktopRepoNameFromUrl(url),
        updateCount: mgr.updatesFor(url).length,
      ),
    );
  }
}

/// LNReader novel plugins.
void _readLnReader(
  List<DesktopSourceEntry> out,
  List<DesktopRepoEntry> repoOut,
) {
  if (!sl.isRegistered<LnReaderManager>()) return;
  final mgr = sl<LnReaderManager>();
  final updates = {for (final m in mgr.updates) m.id: m};
  for (final s in mgr.installedSources) {
    final pluginId = s.id.substring(4);
    final meta = mgr.metaFor(pluginId);
    final newer = updates[pluginId];
    final icon = meta?.iconUrl ?? '';
    out.add(
      DesktopSourceEntry(
        id: s.id,
        name: s.name,
        ecosystem: DesktopEcosystem.lnreader,
        kind: DesktopSourceKind.novel,
        lang: meta?.lang ?? '',
        version: meta?.version ?? '',
        iconUrl: icon.isEmpty ? null : icon,
        repoName: 'LNReader',
        hasUpdate: newer != null,
        updateLabel: newer == null ? null : 'v${newer.version}',
        contentLabel: 'Novel',
      ),
    );
  }
  for (final url in _repoBoxUrls(LnReaderManager.reposBoxName)) {
    repoOut.add(
      DesktopRepoEntry(
        ecosystem: DesktopEcosystem.lnreader,
        url: url,
        name: desktopRepoNameFromUrl(url),
      ),
    );
  }
}

/// Mangayomi sources (any content type).
void _readMangayomi(
  List<DesktopSourceEntry> out,
  List<DesktopRepoEntry> repoOut,
) {
  if (!sl.isRegistered<MangayomiManager>()) return;
  final mgr = sl<MangayomiManager>();
  final updates = {for (final u in mgr.updates) u.key: u};
  for (final item in mgr.installed) {
    final s = item.source;
    final kind = switch (s.contentType) {
      MangayomiContentType.manga => DesktopSourceKind.manga,
      MangayomiContentType.novel => DesktopSourceKind.novel,
      MangayomiContentType.video => DesktopSourceKind.streaming,
    };
    final newer = updates[s.key];
    out.add(
      DesktopSourceEntry(
        id: s.key,
        name: s.name,
        ecosystem: DesktopEcosystem.mangayomi,
        kind: kind,
        lang: s.language,
        version: s.version,
        iconUrl: s.iconUrl?.toString(),
        repoUrl: s.repository.toString(),
        repoName: desktopRepoNameFromUrl(s.repository.toString()),
        hasUpdate: newer != null,
        updateLabel: newer == null ? null : 'v${newer.version}',
        nsfw: s.isNsfw,
        contentLabel: desktopKindContent(kind),
      ),
    );
  }
  for (final uri in mgr.repositories) {
    repoOut.add(
      DesktopRepoEntry(
        ecosystem: DesktopEcosystem.mangayomi,
        url: uri.toString(),
        name: desktopRepoNameFromUrl(uri.toString()),
        sourceCount: mgr.installed
            .where((i) => i.source.repository == uri)
            .length,
        updateCount: mgr.updates.where((u) => u.repository == uri).length,
      ),
    );
  }
}

/// Stremio add-ons. Each add-on is its own 'repository', so no repo rows.
void _readStremio(List<DesktopSourceEntry> out) {
  if (!sl.isRegistered<StremioManager>()) return;
  for (final i in sl<StremioManager>().installations) {
    out.add(
      DesktopSourceEntry(
        id: '${DesktopSourceEntry.stremioAddonPrefix}${i.id}',
        name: i.name,
        ecosystem: DesktopEcosystem.stremio,
        kind: DesktopSourceKind.streaming,
        version: i.version,
        iconUrl: i.logo,
        repoName: 'Stremio add-on',
        enabled: i.enabled,
        canDisable: true,
        contentLabel: 'Movies & TV',
      ),
    );
  }
}

/// Last-known health record for [id], or null when never checked (or when
/// the store is not registered, e.g. in tests).
SourceHealthRecord? desktopHealthRecordOf(String id) {
  if (!sl.isRegistered<SourceHealthStore>()) return null;
  try {
    return sl<SourceHealthStore>().recordOf(id);
  } catch (_) {
    return null;
  }
}

/// Last-known health status for [id], or null when never checked.
SourceHealth? desktopHealthOf(String id) {
  if (desktopHealthRecordOf(id) == null) return null;
  return sl<SourceHealthStore>().statusOf(id);
}
