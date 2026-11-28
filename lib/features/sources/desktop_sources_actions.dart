// Actions adapter for the Windows Sources manager.
//
// One switch per ecosystem that calls the SAME code the old per-ecosystem
// screens call (managers, extension services, the Zangetsu registry the way
// SourcesBloc drives it). Nothing here invents a second install, update or
// delete path: each branch names the screen code it mirrors, so the two can
// be kept in step.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hive/hive.dart';

import '../../core/aniyomi/aniyomi_extension_service.dart';
import '../../core/aniyomi/aniyomi_provider.dart';
import '../../core/di/injector.dart';
import '../../core/hive/safe_box.dart';
import '../../core/i18n/source_languages.dart';
import '../../core/lnreader/lnreader_manager.dart';
import '../../core/mangayomi/mangayomi_manager.dart';
import '../../core/mihon/mihon_extension_service.dart';
import '../../core/mihon/mihon_manager.dart';
import '../../core/playback/pinned_sources.dart';
import '../../core/prefs/source_lang_prefs.dart';
import '../../core/provider/cloudstream_provider.dart';
import '../../core/provider/provider_manager.dart';
import '../../core/provider/provider_registry.dart';
import '../../core/provider/provider_repo_registry.dart';
import '../../core/repository/source_actions.dart' as source_actions;
import '../../core/state/active_source_cubit.dart';
import '../../core/stremio/stremio_manager.dart';
import '../../core/ui/app_dialog.dart';
import '../../l10n/l10n.dart';
import '../search/browse_source_screen.dart';
import 'aniyomi_repo_tab.dart' show kAniyomiReposBoxName;
import 'aniyomi_sources_screen.dart';
import 'cloudstream_sources_screen.dart';
import 'desktop_sources_model.dart';
import 'lnreader_sources_screen.dart';
import 'mangayomi_sources_screen.dart';
import 'mihon_repo_tab.dart' show kMihonReposBoxName;
import 'mihon_sources_screen.dart';
import 'providers_hub_screen.dart';
import 'source_health_screen.dart';
import 'source_language_sheet.dart';
import 'source_settings_screen.dart';
import 'sources_desktop_kit.dart'
    show
        DesktopProviderScope,
        dismissDesktopTooltips,
        showExtensionInstallFailure;
import 'stremio_sources_screen.dart';
import 'zangetsu_sources_screen.dart';

/// Shows [message] on the app-level messenger, replacing any current one.
void _snack(ScaffoldMessengerState? messenger, String message) {
  if (messenger == null || !messenger.mounted) return;
  messenger
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// The installed CloudStream provider behind [entry], its repo group and the
/// catalogue entry it was installed from (null pieces when unknown).
({CloudStreamProvider? provider, CsRepoGroup? group, CsPluginMeta? meta})
_csLookup(DesktopSourceEntry entry) {
  if (!sl.isRegistered<CloudStreamManager>()) {
    return (provider: null, group: null, meta: null);
  }
  for (final g in sl<CloudStreamManager>().repoGroups) {
    for (final p in g.sources) {
      if (p.sourceId != entry.id) continue;
      final internal = (p.sourcePlugin ?? p.name).split('@').first;
      CsPluginMeta? meta;
      for (final m in g.catalog) {
        if (m.internalName == internal) {
          meta = m;
          break;
        }
      }
      return (provider: p, group: g, meta: meta);
    }
  }
  return (provider: null, group: null, meta: null);
}

/// The CloudStream plugin's internal name (the `.cs3` id without version).
String _csInternalName(CloudStreamProvider p) =>
    (p.sourcePlugin ?? p.name).split('@').first;

/// Stateless entry points the manager's buttons and menus call.
abstract final class DesktopSourceActions {
  // -------------------------------------------------------------------------
  // Navigation
  // -------------------------------------------------------------------------

  /// Opens the source's own catalogue, the same push the old Sources tab
  /// made (browse_sources_screen.dart). Stremio add-ons have no catalogue
  /// page, so they open the Stremio manager instead.
  static Future<void> browse(BuildContext context, DesktopSourceEntry entry) {
    if (!entry.browsable) {
      return openEcosystemManager(context, entry.ecosystem);
    }
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            BrowseSourceScreen(sourceId: entry.id, title: entry.name),
      ),
    );
  }

  /// The old per-ecosystem screen for [eco], in the desktop settings look.
  static Widget ecosystemScreen(DesktopEcosystem eco) => switch (eco) {
    DesktopEcosystem.zangetsu => const ZangetsuSourcesScreen(),
    DesktopEcosystem.cloudstream => const CloudStreamSourcesScreen(),
    DesktopEcosystem.aniyomi => const AniyomiSourcesScreen(),
    DesktopEcosystem.mihon => const MihonSourcesScreen(),
    DesktopEcosystem.lnreader => const LnReaderSourcesScreen(),
    DesktopEcosystem.mangayomi => const MangayomiSourcesScreen(),
    DesktopEcosystem.stremio => const StremioSourcesScreen(),
  };

  /// Pushes the old per-ecosystem manager (`Open <Ecosystem> manager…`).
  /// Keeps every capability those screens have reachable: Stremio
  /// configure / reorder / catalogue visibility, the CloudStream
  /// notify-updates switch, Zangetsu repo rename and recommended repos,
  /// install progress and cancel.
  /// Fades open tooltips first: this push lands on the settings' nested
  /// navigator, which the app-wide route observer does not watch.
  static Future<void> openEcosystemManager(
    BuildContext context,
    DesktopEcosystem eco,
  ) {
    dismissDesktopTooltips();
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DesktopProviderScope(child: ecosystemScreen(eco)),
      ),
    );
  }

  /// Pushes the old Providers hub ('All ecosystems…'), fading open
  /// tooltips first like [openEcosystemManager].
  static Future<void> openAllEcosystems(BuildContext context) {
    dismissDesktopTooltips();
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const DesktopProviderScope(child: ProvidersHubScreen()),
      ),
    );
  }

  /// Pushes the Source health screen.
  static Future<void> openHealth(BuildContext context) => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => const SourceHealthScreen()));

  // -------------------------------------------------------------------------
  // Settings, pin, activate, site, reset, languages
  // -------------------------------------------------------------------------

  /// Whether [entry] has a settings page. Zangetsu JS sources always have
  /// one (SourceSettingsScreen, as their own screen offers); Aniyomi,
  /// Mihon, CloudStream and Mangayomi ask their runtime
  /// (source_actions.hasSourceSettings). Never throws.
  static Future<bool> hasSettings(DesktopSourceEntry entry) async {
    switch (entry.ecosystem) {
      case DesktopEcosystem.zangetsu:
        return true;
      case DesktopEcosystem.stremio:
      case DesktopEcosystem.lnreader:
        return false;
      case DesktopEcosystem.cloudstream:
      case DesktopEcosystem.aniyomi:
      case DesktopEcosystem.mihon:
      case DesktopEcosystem.mangayomi:
        try {
          return await source_actions
              .hasSourceSettings(entry.id)
              .timeout(const Duration(seconds: 4));
        } catch (_) {
          return false;
        }
    }
  }

  /// Opens [entry]'s settings page.
  static Future<void> openSettings(
    BuildContext context,
    DesktopSourceEntry entry,
  ) async {
    if (entry.ecosystem == DesktopEcosystem.zangetsu) {
      // Same push as the Zangetsu screen's installed row.
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SourceSettingsScreen(
            sourceId: entry.id,
            repoUrl: entry.repoUrl,
            displayName: entry.name,
          ),
        ),
      );
      return;
    }
    await source_actions.openSourceSettings(context, entry.id, entry.name);
  }

  /// Pins / unpins [entry] in the shared pin store (source switcher order).
  static Future<void> togglePin(DesktopSourceEntry entry) =>
      PinnedSources.toggle(entry.id);

  /// Whether [entry] can become the app's active source.
  static bool canActivate(DesktopSourceEntry entry) =>
      entry.browsable && sl.isRegistered<ActiveSourceCubit>();

  /// Makes [entry] the app's active source (via sl, not context.read).
  static void makeActive(BuildContext context, DesktopSourceEntry entry) {
    if (!canActivate(entry)) return;
    sl<ActiveSourceCubit>().setSource(entry.id);
    _snack(
      ScaffoldMessenger.maybeOf(context),
      '${entry.name} is now the active source',
    );
  }

  /// Whether [entry] is the app's active source.
  static bool isActive(DesktopSourceEntry entry) =>
      sl.isRegistered<ActiveSourceCubit>() &&
      sl<ActiveSourceCubit>().state == entry.id;

  /// Whether the source has a site to open (sign in, Cloudflare).
  static bool canOpenSite(DesktopSourceEntry entry) =>
      entry.browsable && source_actions.webViewUrlFor(entry.id) != null;

  /// Opens the source's site in the in-app browser.
  static Future<void> openSite(DesktopSourceEntry entry) =>
      source_actions.openSourceWebView(entry.id);

  /// Whether the source keeps its own data that can be reset (CloudStream).
  static bool canResetData(DesktopSourceEntry entry) =>
      source_actions.canResetSourceData(entry.id);

  /// Confirms, then clears the source's own settings and cookies (same
  /// dialog as the source page's overflow menu).
  static Future<void> resetData(
    BuildContext context,
    DesktopSourceEntry entry,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final l10n = context.l10n;
    final ok = await AppDialog.confirm(
      context,
      title: l10n.reset,
      message: l10n.resetSourceDataConfirm(entry.name),
      confirmLabel: l10n.reset,
      destructive: true,
    );
    if (!ok) return;
    await source_actions.resetSourceData(entry.id);
    _snack(messenger, l10n.done);
  }

  /// The language filter that applies to [entry]'s ecosystem, if any.
  /// LNReader keeps its own native-name language sheet in its manager.
  static LangPrefs? languagePrefsFor(DesktopEcosystem eco) {
    return switch (eco) {
      DesktopEcosystem.aniyomi when sl.isRegistered<AnimeLangPrefs>() =>
        sl<AnimeLangPrefs>(),
      DesktopEcosystem.mihon when sl.isRegistered<MangaLangPrefs>() =>
        sl<MangaLangPrefs>(),
      DesktopEcosystem.mangayomi when sl.isRegistered<MangayomiLangPrefs>() =>
        sl<MangayomiLangPrefs>(),
      _ => null,
    };
  }

  /// Whether a 'Languages…' action exists for [eco].
  static bool hasLanguages(DesktopEcosystem eco) =>
      eco == DesktopEcosystem.lnreader || languagePrefsFor(eco) != null;

  /// Opens the language filter for [eco] (same sheet and 'present' codes as
  /// the old Aniyomi / Mihon / Mangayomi screens). LNReader opens its own
  /// manager, which owns its native-name language sheet.
  static Future<void> pickLanguages(
    BuildContext context,
    DesktopEcosystem eco,
  ) async {
    if (eco == DesktopEcosystem.lnreader) {
      return openEcosystemManager(context, eco);
    }
    final prefs = languagePrefsFor(eco);
    if (prefs == null) return;
    final present = switch (eco) {
      DesktopEcosystem.aniyomi => presentLangCodes(
        sl<AniyomiManager>().all,
        (p) => p is AniyomiProvider ? p.info.lang : '',
      ),
      DesktopEcosystem.mihon => presentLangCodes(
        sl<MihonManager>().all,
        (p) => p.info.lang,
      ),
      DesktopEcosystem.mangayomi when sl.isRegistered<MangayomiManager>() =>
        presentLangCodes(
          sl<MangayomiManager>().installed,
          (i) => i.source.language,
        ),
      _ => <String>{},
    };
    await showSourceLanguageSheet(context, prefs, present: present);
  }

  // -------------------------------------------------------------------------
  // Enable / disable
  // -------------------------------------------------------------------------

  /// Switches [entry] on or off (CloudStream, Zangetsu and Stremio only).
  static Future<void> setEnabled(DesktopSourceEntry entry, bool value) async {
    switch (entry.ecosystem) {
      case DesktopEcosystem.cloudstream:
        await sl<CloudStreamManager>().setEnabled(entry.id, value);
      case DesktopEcosystem.zangetsu:
        // What SourceEnabledToggled does in SourcesBloc.
        await sl<ProviderRegistry>().setEnabled(entry.registryKey, value);
      case DesktopEcosystem.stremio:
        await sl<StremioManager>().setEnabled(entry.stremioAddonId, value);
      case DesktopEcosystem.aniyomi:
      case DesktopEcosystem.mihon:
      case DesktopEcosystem.lnreader:
      case DesktopEcosystem.mangayomi:
        return;
    }
  }

  // -------------------------------------------------------------------------
  // Update
  // -------------------------------------------------------------------------

  /// Installs [entry]'s pending update and reports the result.
  static Future<void> update(
    BuildContext context,
    DesktopSourceEntry entry,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final l10n = context.l10n;
    try {
      switch (entry.ecosystem) {
        case DesktopEcosystem.zangetsu:
          await _updateZangetsu(entry.registryKey);
        case DesktopEcosystem.cloudstream:
          // _CsScreenPluginRow._update.
          final cs = _csLookup(entry);
          final p = cs.provider;
          final g = cs.group;
          if (p == null || g == null) throw StateError('Source not found');
          final u = sl<CloudStreamManager>().updateFor(
            _csInternalName(p),
            g.url,
          );
          if (u == null) throw StateError('No update available');
          await sl<CloudStreamManager>().updatePlugin(u, repoUrl: g.url);
        case DesktopEcosystem.aniyomi:
          // Aniyomi repo tab desktop install + clearUpdatesForPkg.
          final mgr = sl<AniyomiManager>();
          final u = mgr.updateFor(entry.pkg);
          if (u == null) throw StateError('No update available');
          await AniyomiExtensionService().installFromRepoOrThrow(
            u.entry,
            manager: mgr,
          );
          mgr.clearUpdatesForPkg(u.pkg);
        case DesktopEcosystem.mihon:
          final mgr = sl<MihonManager>();
          final u = mgr.updateFor(entry.pkg);
          if (u == null) throw StateError('No update available');
          await MihonExtensionService().installFromRepoOrThrow(
            u.entry,
            manager: mgr,
          );
          mgr.clearUpdatesForPkg(u.pkg);
        case DesktopEcosystem.lnreader:
          // LNReader row _update: install the newer catalogue entry.
          final mgr = sl<LnReaderManager>();
          final pluginId = entry.id.substring(4);
          final newer = mgr.updates.where((m) => m.id == pluginId).firstOrNull;
          if (newer == null) throw StateError('No update available');
          await mgr.update(newer);
        case DesktopEcosystem.mangayomi:
          final mgr = sl<MangayomiManager>();
          final newer = mgr.updates.where((s) => s.key == entry.id).firstOrNull;
          if (newer == null) throw StateError('No update available');
          await mgr.install(newer);
        case DesktopEcosystem.stremio:
          return;
      }
      _snack(messenger, l10n.updatedName(entry.name));
    } catch (e) {
      if (messenger == null || !messenger.mounted) return;
      final failure = ExtensionInstallFailure.from(e);
      showExtensionInstallFailure(
        messenger,
        message: failure.cancelled
            ? failure.reason
            : l10n.updateFailed(failure.reason),
        failure: failure,
      );
    }
  }

  /// SourcesBloc._onUpdated, without the bloc: force-reinstall one Zangetsu
  /// source from its repo's current manifest.
  static Future<void> _updateZangetsu(String key) async {
    final repos = sl<ProviderReposRegistry>();
    final repoUrl = ProviderRegistry.repoUrlOf(key);
    final sourceId = ProviderRegistry.sourceIdOf(key);
    final repo = repos.get(repoUrl);
    final source = repo?.sources.where((s) => s.id == sourceId).firstOrNull;
    if (repo == null || source == null) {
      throw StateError("Couldn't find this source's repo to update");
    }
    await _installZangetsu(repo, source);
  }

  /// The registry install SourcesBloc uses for install and update (always a
  /// fresh JS download).
  static Future<void> _installZangetsu(ProviderRepo repo, RepoSource source) =>
      sl<ProviderRegistry>().install(
        sourceId: source.id,
        fileUrl: sl<ProviderReposRegistry>().resolveFileUrl(repo, source),
        logoUrl: ProviderReposRegistry.resolveLogoUrl(repo, source) ?? '',
        repoUrl: repo.url,
        displayName: source.name,
        version: source.version,
        force: true,
      );

  // -------------------------------------------------------------------------
  // Remove
  // -------------------------------------------------------------------------

  /// Confirms, then uninstalls [entry] through its ecosystem's own path.
  /// Returns true when the source was removed.
  static Future<bool> remove(
    BuildContext context,
    DesktopSourceEntry entry,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final l10n = context.l10n;
    final ok = await AppDialog.confirm(
      context,
      title: entry.ecosystem == DesktopEcosystem.stremio
          ? 'Remove add-on?'
          : l10n.uninstallNameQuestion(entry.name),
      message: entry.ecosystem == DesktopEcosystem.zangetsu
          ? l10n.theProviderWillBeRemovedFromYourInstalledSources
          : l10n.thisRemovesTheSourceFromYourInstalledList,
      confirmLabel: l10n.uninstall,
      destructive: true,
    );
    if (!ok) return false;
    try {
      switch (entry.ecosystem) {
        case DesktopEcosystem.zangetsu:
          // SourceUninstalled -> ProviderRegistry.uninstall(key).
          await sl<ProviderRegistry>().uninstall(entry.registryKey);
        case DesktopEcosystem.cloudstream:
          // _CsScreenSourceRow._uninstall -> _uninstallCsPlugin.
          final cs = _csLookup(entry);
          final p = cs.provider;
          if (p == null) throw StateError('Source not found');
          final plugin =
              cs.meta ??
              CsPluginMeta(
                internalName: _csInternalName(p),
                name: p.displayName,
                url: '',
                version: 0,
              );
          await sl<CloudStreamManager>().uninstallPlugin(
            plugin,
            repoUrl: cs.group?.url ?? '',
          );
        case DesktopEcosystem.aniyomi:
          // _AniScreenSourceRow._confirmUninstall.
          final pkg = entry.pkg;
          if (pkg.isNotEmpty) {
            final failure = await AniyomiExtensionService.uninstall(pkg);
            if (failure != null) throw StateError(failure);
            sl<AniyomiManager>().removeWhere(
              (p) => p is AniyomiProvider && p.info.pkg == pkg,
            );
          } else {
            sl<AniyomiManager>().removeWhere((p) => p.sourceId == entry.id);
          }
        case DesktopEcosystem.mihon:
          // Mihon row _confirmUninstall: the manager entry goes either way,
          // a failure is still reported.
          final failure = await MihonExtensionService.uninstall(entry.pkg);
          sl<MihonManager>().removeWhere((p) => p.pkg == entry.pkg);
          if (failure != null) throw StateError(failure);
        case DesktopEcosystem.lnreader:
          await sl<LnReaderManager>().uninstall(entry.id.substring(4));
        case DesktopEcosystem.mangayomi:
          await sl<MangayomiManager>().uninstall(entry.id);
        case DesktopEcosystem.stremio:
          await sl<StremioManager>().remove(entry.stremioAddonId);
      }
      _snack(messenger, l10n.uninstalledName(entry.name));
      return true;
    } catch (e) {
      _snack(messenger, l10n.uninstallFailed('$e'));
      return false;
    }
  }

  // -------------------------------------------------------------------------
  // Repositories
  // -------------------------------------------------------------------------

  /// Opens (if needed) one of the String repo boxes Aniyomi, Mihon and
  /// LNReader keep their repo URLs in.
  static Future<Box<String>> _repoBox(String name) async {
    if (!Hive.isBoxOpen(name)) await openBoxSafely<String>(name);
    return Hive.box<String>(name);
  }

  /// Opens the Aniyomi / Mihon / LNReader repo boxes so the manager can list
  /// their repos. Failures leave a box closed (its repos are just not
  /// listed).
  static Future<void> openRepoBoxes() async {
    for (final name in desktopRepoBoxNames) {
      try {
        await _repoBox(name);
      } catch (_) {}
    }
  }

  /// The URLs already added for [eco] (for the ecosystem's own dialog).
  static Set<String> addedRepoUrls(DesktopEcosystem eco) {
    final box = switch (eco) {
      DesktopEcosystem.aniyomi => kAniyomiReposBoxName,
      DesktopEcosystem.mihon => kMihonReposBoxName,
      DesktopEcosystem.lnreader => LnReaderManager.reposBoxName,
      _ => null,
    };
    if (box == null) return {};
    return desktopOpenBox(box)?.values.map((v) => '$v').toSet() ?? {};
  }

  /// Adds [url] as a repository of [eco]. Returns a short success message;
  /// throws with a readable message on failure.
  static Future<String> addRepo(DesktopEcosystem eco, String url) async {
    final u = url.trim();
    if (u.isEmpty) throw const FormatException('Enter a repository link');
    switch (eco) {
      case DesktopEcosystem.zangetsu:
        // RepoAdded -> ProviderReposRegistry.fetchAndCache.
        try {
          final repo = await sl<ProviderReposRegistry>().fetchAndCache(u);
          return 'Added ${repo.displayName}';
        } on ProviderRepoException catch (e) {
          throw StateError(e.message);
        }
      case DesktopEcosystem.cloudstream:
        final count = await sl<CloudStreamManager>().addRepo(u);
        return 'Added CloudStream repository · $count plugin'
            '${count == 1 ? '' : 's'}';
      case DesktopEcosystem.aniyomi:
      case DesktopEcosystem.mihon:
      case DesktopEcosystem.lnreader:
        // _addAniyomiRepo / _addMihonRepo / LNReader _addRepo.
        final name = switch (eco) {
          DesktopEcosystem.aniyomi => kAniyomiReposBoxName,
          DesktopEcosystem.mihon => kMihonReposBoxName,
          _ => LnReaderManager.reposBoxName,
        };
        final box = await _repoBox(name);
        if (box.values.contains(u)) return 'This repository is already added';
        await box.add(u);
        if (eco == DesktopEcosystem.lnreader &&
            sl.isRegistered<LnReaderManager>()) {
          // Read the new catalogue so update badges know about it.
          unawaited(
            sl<LnReaderManager>().checkForUpdates().catchError((Object _) {}),
          );
        }
        return 'Added ${eco.label} repository';
      case DesktopEcosystem.mangayomi:
        final sources = await sl<MangayomiManager>().addRepository(
          Uri.parse(u),
        );
        return '${sources.length} sources added';
      case DesktopEcosystem.stremio:
        final addon = await sl<StremioManager>().install(u);
        return 'Installed ${addon.name}';
    }
  }
}
