import 'dart:async';
import 'dart:io';
import '../../core/desktop/desktop_context_menu.dart';
import '../../core/desktop/desktop_reveal.dart';
import '../../core/desktop/extension_load_failures.dart';
import '../../core/desktop/extension_runtime.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../../core/ui/settings_widgets.dart';
import '../../core/ui/desktop_settings_surface.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/lnreader/lnreader_manager.dart';
import '../../core/mangayomi/mangayomi_manager.dart';
import '../../core/mihon/mihon_manager.dart';
import '../../core/models/provider_info.dart';
import '../../core/provider/cloudstream_provider.dart';
import '../../core/provider/provider_manager.dart';
import '../../core/provider/provider_registry.dart';
import '../../core/stremio/stremio_manager.dart';
import '../../core/stremio/stremio_ref.dart';
import '../../core/provider/provider_repo_registry.dart';
import '../../core/state/active_source_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_back_button.dart';
import '../../core/tv/tv_list_focusable.dart';
import '../../core/ui/source_switcher.dart';
import 'aniyomi_sources_screen.dart';
import 'bloc/sources_state.dart';
import 'cloudstream_sources_screen.dart';
import 'stremio_sources_screen.dart';
import 'lnreader_sources_screen.dart';
import 'mangayomi_sources_screen.dart';
import 'mihon_sources_screen.dart';
import 'sources_desktop_keys.dart';
import 'sources_desktop_kit.dart'
    show DesktopProviderScope, desktopPanelsEnabled, dismissDesktopTooltips;
import 'zangetsu_sources_screen.dart';
import '../../l10n/l10n.dart';

/// Windows-only hub behaviour (src-10/13/15/16) is gated on this, so phone
/// keeps its exact layout and numbers. TV has its own view below.
bool get _windowsHub => defaultTargetPlatform == TargetPlatform.windows;

/// The folder the app runs from: where the extension engine belongs.
String get _appFolder => p.dirname(Platform.resolvedExecutable);

/// Text shown on Aniyomi/Mihon when the bundled engine files are missing.
/// Read when shown, so it follows the app language.
String get _engineMissingText => appL10n.extensionEngineNotFound;

const Widget _kChevron = Icon(
  Icons.chevron_right_rounded,
  color: AppColors.textTertiary,
  size: 22,
);

// CloudStream/Aniyomi don't have a dedicated brand color in AppColors, so we
// keep small local tints here — same "@ ~15%" recipe as AppColors.accentSoft.
const _csBlue = Color(0xFF4D9DFF);
const _aniGreen = Color(0xFF4DD68C);

/// Provider ecosystem navigation with live installed/update counts.
/// Windows settings use graphite controls; phone and TV retain their layouts.
/// Returning from a manager refreshes counts without fetching or mutating here.
class ProvidersHubScreen extends StatefulWidget {
  const ProvidersHubScreen({super.key});

  @override
  State<ProvidersHubScreen> createState() => _ProvidersHubScreenState();
}

class _ProvidersHubScreenState extends State<ProvidersHubScreen> {
  @override
  void initState() {
    super.initState();
    // src-16 (Windows): download the LNReader repo lists once so the novel
    // update count is known without opening the LNReader screen first.
    if (_windowsHub && !sl<AppMode>().isTv) _checkNovelUpdates();
  }

  /// Fire-and-forget LNReader update check; failures only mean no badge.
  void _checkNovelUpdates() {
    if (!sl.isRegistered<LnReaderManager>()) return;
    unawaited(
      sl<LnReaderManager>().checkForUpdates().catchError((Object _) {}),
    );
  }

  /// F5 on Windows: re-read the engine files, re-check novel updates and
  /// redraw every count.
  void _refresh() {
    DesktopExtensionRuntime.recheckAvailability();
    _checkNovelUpdates();
    setState(() {});
  }

  Future<void> _open(Widget screen) async {
    // Windows: fade the clicked tile's tooltip before the nested push so it
    // cannot freeze over the pushed screen (no-op off Windows).
    dismissDesktopTooltips();
    await Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // src-3 (Windows): every push of the hub gets the desktop settings look,
    // including Home's unscoped push. Rebuilds this method inside the scope.
    if (desktopPanelsEnabled && !DesktopSettingsScope.contains(context)) {
      return DesktopProviderScope(child: Builder(builder: build));
    }
    if (sl<AppMode>().isTv) return const _HubTvView();
    // src-13 (Windows): F5 refreshes; Esc falls through to the app's Back.
    // The hub has no search box, so Ctrl+F is left to the shell.
    return SourcesDesktopKeys(
      onRefresh: _refresh,
      child: _HubPhoneView(open: _open),
    );
  }
}

// ---------------------------------------------------------------------------
// Phone
// ---------------------------------------------------------------------------

class _HubPhoneView extends StatelessWidget {
  const _HubPhoneView({required this.open});
  final void Function(Widget screen) open;

  @override
  Widget build(BuildContext context) {
    final mangayomi = sl.isRegistered<MangayomiManager>()
        ? sl<MangayomiManager>()
        : null;
    // Recompute the counts live when a source is installed / enabled / updated
    // while the hub is open (CS + Aniyomi managers are ChangeNotifiers). The
    // Zangetsu registry isn't a Listenable, but it can only be mutated from its
    // own screen, so its count refreshes on navigation back here anyway.
    return ListenableBuilder(
      listenable: Listenable.merge([
        sl<CloudStreamManager>(),
        sl<AniyomiManager>(),
        sl<MihonManager>(),
        if (mangayomi != null) mangayomi,
        if (sl.isRegistered<StremioManager>()) sl<StremioManager>(),
        // Windows: novel update badges and the load-failure banner.
        if (_windowsHub && sl.isRegistered<LnReaderManager>())
          sl<LnReaderManager>(),
        if (_windowsHub) ExtensionLoadFailures.failures,
      ]),
      builder: (context, _) => _body(context, mangayomi),
    );
  }

  Widget _body(BuildContext context, MangayomiManager? mangayomi) {
    final zangetsuCount = sl<ProviderRegistry>().getAll().length;
    final showCs = Platform.isAndroid || Platform.isWindows;
    // src-10 Option A (Windows): when the bundled engine files are missing,
    // Aniyomi and Mihon stay visible but disabled with an explanation,
    // instead of silently disappearing.
    final engineMissing = _windowsHub && DesktopExtensionRuntime.engineMissing;
    final showAniyomi =
        Platform.isAndroid ||
        DesktopExtensionRuntime.isAvailable ||
        engineMissing;
    // Mihon (manga extensions) boot-loads the same way Aniyomi does — the
    // load step is Android-only (M7) — so the row is gated identically.
    final showMihon =
        Platform.isAndroid ||
        DesktopExtensionRuntime.isAvailable ||
        engineMissing;
    // LNReader (novel sources) is a JS provider, same as Zangetsu — no
    // platform gate needed. Gated on registration instead, so a minimal-GetIt
    // test that never registers LnReaderManager doesn't crash reading it,
    // same purpose the Mihon platform check serves.
    final showLnReader = sl.isRegistered<LnReaderManager>();

    final csGroups = sl<CloudStreamManager>().repoGroups;
    final csInstalled = csGroups.fold<int>(0, (s, g) => s + g.sources.length);
    final csRepos = csGroups.length;
    final aniCount = sl<AniyomiManager>().all.length;
    final mihonCount = sl<MihonManager>().all.length;
    final lnrCount = showLnReader
        ? sl<LnReaderManager>().installedSources.length
        : 0;
    final mangayomiCount = mangayomi?.installed.length ?? 0;

    // Read-only pending-update counts. Zangetsu reuses SourcesState's own
    // installed-vs-manifest comparison (same result the Zangetsu screen shows);
    // CS/Aniyomi/Mihon expose an aggregate updateCount. Nothing is fetched or
    // mutated.
    final zUpdates = SourcesState(
      installed: sl<ProviderRegistry>().getAll(),
      repos: sl<ProviderReposRegistry>().getAll(),
    ).updatableKeys.length;
    final csUpdates = showCs ? sl<CloudStreamManager>().updateCount : 0;
    final aniUpdates = showAniyomi ? sl<AniyomiManager>().updateCount : 0;
    final mihonUpdates = showMihon ? sl<MihonManager>().updateCount : 0;
    // src-16 (Windows): installed novel plugins with a newer repo version.
    final lnrUpdates = _windowsHub && showLnReader
        ? sl<LnReaderManager>().updateCount
        : 0;
    // src-15 (Windows): the header totals also count pending Mangayomi
    // updates, LNReader updates and Stremio addons, which the rows below
    // already show but the header used to leave out.
    final showStremio = sl.isRegistered<StremioManager>();
    final stremioCount = showStremio
        ? sl<StremioManager>().installations.length
        : 0;
    final totalUpdates =
        zUpdates +
        csUpdates +
        aniUpdates +
        mihonUpdates +
        (_windowsHub ? (mangayomi?.updateCount ?? 0) + lnrUpdates : 0);

    final total =
        zangetsuCount +
        (showCs ? csInstalled : 0) +
        (showAniyomi ? aniCount : 0) +
        (showMihon ? mihonCount : 0) +
        (showLnReader ? lnrCount : 0) +
        mangayomiCount +
        (_windowsHub ? stremioCount : 0);
    final ecoCount =
        1 +
        (showCs ? 1 : 0) +
        (showAniyomi ? 1 : 0) +
        (showMihon ? 1 : 0) +
        (showLnReader ? 1 : 0) +
        (_windowsHub && showStremio ? 1 : 0);

    final activeId = sl<ActiveSourceCubit>().state;
    final activeName = activeId.isEmpty
        ? context.l10n.subtitleOutlineNone
        : _activeSourceLabel(activeId);
    final activeIsCs = activeId.startsWith('cs:');
    final activeIsAni = activeId.startsWith('ani:');
    final activeIsMihon = activeId.startsWith('mihon:');
    final activeIsLnReader = activeId.startsWith('lnr:');
    final activeIsMangayomi = activeId.startsWith('mg:');
    final activeIsZangetsu =
        activeId.isNotEmpty &&
        !activeIsCs &&
        !activeIsAni &&
        !activeIsMihon &&
        !activeIsLnReader &&
        !activeIsMangayomi;

    // Manga/novel sources are also Zangetsu JS providers under the hood, but
    // get their own hub entry (Task E3) so reading sources read as visibly
    // separate from streaming. sourceTypeOf is the app's one ProviderType
    // resolver (core/ui/source_switcher.dart) — reused rather than
    // re-deriving a manga/novel check here.
    bool isReadingType(ProviderType t) =>
        t == ProviderType.manga || t == ProviderType.novel;
    // Still needed after the Zangetsu reading row was dropped: a JS reading
    // source can still be installed and active, and the Zangetsu STREAMING row
    // must not light up as ACTIVE when it is.
    final activeIsReading =
        activeIsZangetsu && isReadingType(sourceTypeOf(activeId));

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar(context.l10n.providers),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          _HubHeader(
            total: total,
            // ecoCount already counts real ecosystems (incl. LnReader, our
            // desktop change); Mangayomi adds its own row when registered.
            ecoCount: ecoCount + (mangayomi == null ? 0 : 1),
            activeName: activeName,
            totalUpdates: totalUpdates,
          ),
          // src-10 Option C (Windows): extensions/plugins that failed to
          // load stay listed here (with Details and Retry) after the
          // one-time startup notice has gone.
          if (_windowsHub &&
              ExtensionLoadFailures.failures.value.isNotEmpty) ...[
            const SizedBox(height: 16),
            _LoadFailuresBanner(
              count: ExtensionLoadFailures.failures.value.length,
            ),
          ],
          const SizedBox(height: 24),
          if (mangayomi != null) ...[
            const _SectionLabel('ALL'),
            const SizedBox(height: 12),
            _EcoRow(
              icon: Icons.extension_rounded,
              title: 'Mangayomi',
              desc: 'Streaming, manga, and novel sources',
              info:
                  '$mangayomiCount sources · ${mangayomi.repositories.length} repos',
              active: activeIsMangayomi,
              updateCount: mangayomi.updateCount,
              onTap: () => open(const MangayomiSourcesScreen()),
            ),
            const SizedBox(height: 28),
          ],
          const _SectionLabel('STREAMING'),
          const SizedBox(height: 12),
          _EcoRow(
            icon: Icons.dns_rounded,
            title: context.l10n.zangetsu,
            desc: 'Built-in JS providers',
            info: '$zangetsuCount sources',
            // Reading sources are Zangetsu providers too (activeIsZangetsu
            // alone doesn't distinguish), so exclude them here — the Manga &
            // Novel row owns the badge when a reading source is active. When
            // the active source is anime/movie, activeIsReading is false and
            // this is byte-identical to plain activeIsZangetsu, as before.
            active: activeIsZangetsu && !activeIsReading,
            updateCount: zUpdates,
            onTap: () => open(const ZangetsuSourcesScreen()),
          ),
          if (sl.isRegistered<StremioManager>()) ...[
            const SizedBox(height: 12),
            _EcoRow(
              icon: Icons.movie_filter_outlined,
              title: 'Stremio',
              desc: 'Addon catalogues, links and subtitles',
              info:
                  '${sl<StremioManager>().installations.length} addon'
                  '${sl<StremioManager>().installations.length == 1 ? '' : 's'}',
              active: activeId == stremioSourceId,
              updateCount: 0,
              onTap: () => open(const StremioSourcesScreen()),
            ),
          ],
          if (showCs) ...[
            const SizedBox(height: 12),
            _EcoRow(
              icon: Icons.extension_outlined,
              title: context.l10n.cloudStream,
              desc: 'CloudStream extensions',
              info:
                  '$csInstalled sources · $csRepos repo${csRepos == 1 ? '' : 's'}',
              active: activeIsCs,
              updateCount: csUpdates,
              onTap: () => open(const CloudStreamSourcesScreen()),
            ),
          ],
          if (showAniyomi) ...[
            const SizedBox(height: 12),
            _EcoRow(
              icon: Icons.movie_filter_outlined,
              title: context.l10n.aniyomi,
              desc: 'Aniyomi extensions',
              info: '$aniCount sources',
              active: activeIsAni,
              updateCount: aniUpdates,
              disabledReason: engineMissing ? _engineMissingText : null,
              onTap: () => open(const AniyomiSourcesScreen()),
            ),
          ],
          // Reading ecosystems live under their own header so a manga/novel
          // source never reads as a streaming one. Mihon (manga) and LNReader
          // (novel) sit side by side here — the Zangetsu reading row was
          // dropped because those JS sources are search-only (no
          // popular/latest), which left Home with nothing to render.
          //
          // Guarded on showMihon || showLnReader: Mihon is Android-only and
          // LNReader is gated on registration (see showLnReader above), so
          // the header only renders when at least one row will follow it —
          // otherwise off-Android it would show as a header with no rows.
          if (showMihon || showLnReader) ...[
            const SizedBox(height: 28),
            const _SectionLabel('MANGA & NOVEL'),
            const SizedBox(height: 12),
            if (showMihon)
              _EcoRow(
                icon: Icons.menu_book_outlined,
                title: context.l10n.mihon,
                desc: 'Mihon manga extensions',
                info: '$mihonCount sources',
                active: activeIsMihon,
                updateCount: mihonUpdates,
                disabledReason: engineMissing ? _engineMissingText : null,
                onTap: () => open(const MihonSourcesScreen()),
              ),
            if (showMihon && showLnReader) const SizedBox(height: 12),
            if (showLnReader)
              _EcoRow(
                icon: Icons.auto_stories_outlined,
                title: context.l10n.lnreader,
                desc: 'Novel sources',
                info: '$lnrCount sources',
                active: activeIsLnReader,
                updateCount: lnrUpdates,
                onTap: () => open(const LnReaderSourcesScreen()),
                // Windows right-click: update every outdated novel plugin
                // straight from the hub, like Mihon's "Update all".
                extraMenu: lnrUpdates > 0
                    ? [
                        DesktopMenuItem<Object?>(
                          label: context.l10n.updateAllCount(lnrUpdates),
                          icon: Icons.system_update_alt_rounded,
                          onTap: () => _updateAllNovels(context),
                        ),
                      ]
                    : const [],
              ),
          ],
        ],
      ),
    );
  }
}

/// Small all-caps label that groups the ecosystem rows into Streaming vs
/// Manga & Novel. Uses the same [AppText.overline] the tracker sheet's section
/// labels use, so the hub matches the rest of the app.
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsetsDirectional.only(start: 4),
    child: Text(text, style: AppText.overline),
  );
}

/// Installs every pending LNReader plugin update and reports how many
/// succeeded (same message as Mihon's "Update all").
Future<void> _updateAllNovels(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  final l10n = context.l10n;
  final done = await sl<LnReaderManager>().updateAll();
  messenger
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Text(l10n.updatedSourcesCount(done, done == 1 ? '' : 's')),
      ),
    );
}

/// Opens the folder the app runs from, so a user can re-extract the missing
/// extension engine into it.
Future<void> _openAppFolder() async {
  await revealInExplorer(_appFolder);
}

/// Windows banner listing how many extensions/plugins failed to load, with
/// Details (the full list) and Retry (src-10 Option C).
class _LoadFailuresBanner extends StatefulWidget {
  const _LoadFailuresBanner({required this.count});

  final int count;

  @override
  State<_LoadFailuresBanner> createState() => _LoadFailuresBannerState();
}

class _LoadFailuresBannerState extends State<_LoadFailuresBanner> {
  /// True while Retry runs.
  bool _retrying = false;

  Future<void> _retry() async {
    setState(() => _retrying = true);
    await ExtensionLoadFailures.retryAll();
    if (mounted) setState(() => _retrying = false);
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.count;
    return GraphiteSettingsPanel(
      key: const ValueKey('hub-load-failures'),
      margin: EdgeInsets.zero,
      children: [
        GraphiteSettingsControl(
          icon: Icons.error_outline_rounded,
          title: context.l10n.extensionsFailedToLoad(count),
          subtitle: context.l10n.extensionSourcesMissingUntilLoad,
          onTap: () => showExtensionLoadFailures(context),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                onPressed: () => showExtensionLoadFailures(context),
                child: Text(context.l10n.details),
              ),
              const SizedBox(width: 6),
              FilledButton(
                onPressed: _retrying ? null : _retry,
                child: _retrying
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(context.l10n.retry),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Resolves an active-source id to its display name, mirroring the Settings
/// screen's `_activeLabel` (cs:/ani: prefixes route to their managers).
String _activeSourceLabel(String id) {
  if (id.startsWith('cs:')) {
    return sl<CloudStreamManager>().get(id)?.displayName ?? id;
  }
  if (id.startsWith('ani:')) {
    return sl<AniyomiManager>().get(id)?.displayName ?? id;
  }
  if (id.startsWith('mihon:')) {
    return sl<MihonManager>().get(id)?.displayName ?? id;
  }
  if (id.startsWith('lnr:')) {
    return sl.isRegistered<LnReaderManager>()
        ? (sl<LnReaderManager>().metaFor(id.substring(4))?.name ?? id)
        : id;
  }
  final e = sl<ProviderRegistry>().entryFor(id);
  if (e == null) return id;
  return e.displayName.isNotEmpty ? e.displayName : e.name;
}

/// Branded header — the app logo, the total source count and the currently
/// active source, so the screen opens with identity and real information.
class _HubHeader extends StatelessWidget {
  const _HubHeader({
    required this.total,
    required this.ecoCount,
    required this.activeName,
    required this.totalUpdates,
  });

  final int total;
  final int ecoCount;
  final String activeName;
  final int totalUpdates;

  @override
  Widget build(BuildContext context) {
    if (DesktopSettingsScope.contains(context)) {
      return GraphiteSettingsPanel(
        margin: EdgeInsets.zero,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Source library', style: AppText.headline),
                  const SizedBox(height: 8),
                  Text(
                    'Manage installed extensions and their repositories.',
                    style: AppText.caption,
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      Chip(label: Text('$total installed sources')),
                      Chip(label: Text('$ecoCount ecosystems')),
                      if (totalUpdates > 0)
                        Chip(label: Text('$totalUpdates updates available')),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text('Active source: $activeName', style: AppText.caption),
                ],
              ),
            ),
          ),
        ],
      );
    }
    return Row(
      children: [
        Container(
          width: 54,
          height: 54,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: AppColors.surface2,
            borderRadius: BorderRadius.circular(15),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.asset('assets/icon/app_icon.png', fit: BoxFit.cover),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$total sources ready',
                style: AppText.headline.copyWith(fontSize: 18),
              ),
              const SizedBox(height: 3),
              Text(
                '$ecoCount ecosystems · Active: $activeName',
                style: AppText.caption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (totalUpdates > 0) ...[
                const SizedBox(height: 7),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.download_rounded,
                      color: AppColors.accent,
                      size: 15,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      '$totalUpdates update${totalUpdates == 1 ? '' : 's'} available',
                      style: AppText.caption.copyWith(
                        color: AppColors.accent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// One ecosystem row — monochrome icon tile, title with an optional "Active"
/// tag, a description and a source/repo count line that gains an accent
/// "· N updates" note when that ecosystem has pending updates.
class _EcoRow extends StatelessWidget {
  const _EcoRow({
    required this.icon,
    required this.title,
    required this.desc,
    required this.info,
    required this.active,
    required this.updateCount,
    required this.onTap,
    this.disabledReason,
    this.extraMenu = const [],
  });

  final IconData icon;
  final String title;
  final String desc;
  final String info;
  final bool active;
  final int updateCount;
  final VoidCallback onTap;

  /// Windows: when set the row is shown disabled with this explanation and
  /// an "Open folder" button instead of opening its screen (src-10 A).
  final String? disabledReason;

  /// Windows: extra right-click menu items after "Open" (src-13 B).
  final List<DesktopMenuItem<Object?>> extraMenu;

  /// Right-click / Menu-key items for this row (Windows only).
  List<DesktopMenuItem<Object?>> _menu(BuildContext context) => [
    DesktopMenuItem<Object?>(
      label: context.l10n.open,
      icon: Icons.open_in_new_rounded,
      enabled: disabledReason == null,
      onTap: onTap,
    ),
    if (disabledReason != null)
      DesktopMenuItem<Object?>(
        label: context.l10n.openAppFolder,
        icon: Icons.folder_open_rounded,
        onTap: () => unawaited(_openAppFolder()),
      ),
    ...extraMenu,
  ];

  @override
  Widget build(BuildContext context) {
    return DesktopContextMenuRegion(
      items: () => _menu(context),
      child: _row(context),
    );
  }

  Widget _row(BuildContext context) {
    final reason = disabledReason;
    if (reason != null) return _disabledRow(context, reason);
    if (DesktopSettingsScope.contains(context)) {
      return GraphiteSettingsPanel(
        margin: EdgeInsets.zero,
        children: [
          GraphiteSettingsControl(
            icon: icon,
            title: title,
            subtitle: [
              desc,
              info,
              if (active) 'Active source',
              if (updateCount > 0)
                '$updateCount update${updateCount == 1 ? '' : 's'} available',
            ].join(' · '),
            onTap: onTap,
          ),
        ],
      );
    }
    return _phoneRow(context);
  }

  /// Windows row for an ecosystem that cannot run (engine files missing):
  /// greyed out, not tappable, with the reason and an Open folder button.
  Widget _disabledRow(BuildContext context, String reason) {
    final button = OutlinedButton.icon(
      key: ValueKey('eco-open-folder-$title'),
      onPressed: () => unawaited(_openAppFolder()),
      icon: const Icon(Icons.folder_open_rounded, size: 18),
      label: Text(appL10n.openFolder),
    );
    if (DesktopSettingsScope.contains(context)) {
      return GraphiteSettingsPanel(
        margin: EdgeInsets.zero,
        children: [
          Opacity(
            opacity: 0.85,
            child: GraphiteSettingsControl(
              icon: icon,
              title: title,
              subtitle: '$desc · $reason',
              trailing: button,
            ),
          ),
        ],
      );
    }
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: Row(
          children: [
            Opacity(
              opacity: 0.5,
              child: Icon(icon, color: AppColors.textSecondary, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: AppText.headline.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    reason,
                    style: AppText.caption.copyWith(color: AppColors.accent),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            button,
          ],
        ),
      ),
    );
  }

  Widget _phoneRow(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.surface2,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: AppColors.textSecondary, size: 24),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            style: AppText.headline,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (active) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.accent.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              'ACTIVE',
                              style: AppText.overline.copyWith(
                                color: AppColors.accent,
                                fontWeight: FontWeight.w700,
                                fontSize: 10,
                                letterSpacing: 0.4,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(desc, style: AppText.caption),
                    const SizedBox(height: 7),
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            info,
                            style: AppText.caption.copyWith(
                              color: AppColors.textTertiary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (updateCount > 0)
                          Padding(
                            padding: const EdgeInsetsDirectional.only(start: 6),
                            child: Text(
                              '· $updateCount update${updateCount == 1 ? '' : 's'}',
                              style: AppText.caption.copyWith(
                                color: AppColors.accent,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _kChevron,
            ],
          ),
        ),
      ),
    );
  }
}

String _csSubtitle() {
  final groups = sl<CloudStreamManager>().repoGroups;
  final installed = groups.fold<int>(0, (sum, g) => sum + g.sources.length);
  return '$installed installed · ${groups.length} repo${groups.length == 1 ? '' : 's'}';
}

String _aniyomiSubtitle() {
  final installed = sl<AniyomiManager>().all.length;
  return '$installed installed';
}

// ---------------------------------------------------------------------------
// TV
// ---------------------------------------------------------------------------

class _HubTvView extends StatefulWidget {
  const _HubTvView();

  @override
  State<_HubTvView> createState() => _HubTvViewState();
}

class _HubTvViewState extends State<_HubTvView> {
  Future<void> _open(Widget screen) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final mangayomi = sl.isRegistered<MangayomiManager>()
        ? sl<MangayomiManager>()
        : null;
    // Same live-count listenables as the phone hub so install/enable on an
    // ecosystem screen is reflected when the user returns (and while this
    // route is still under the stack).
    return ListenableBuilder(
      listenable: Listenable.merge([
        sl<CloudStreamManager>(),
        sl<AniyomiManager>(),
        sl<MihonManager>(),
        if (mangayomi != null) mangayomi,
        if (sl.isRegistered<StremioManager>()) sl<StremioManager>(),
      ]),
      builder: (context, _) => _body(context, mangayomi),
    );
  }

  Widget _body(BuildContext context, MangayomiManager? mangayomi) {
    final zangetsuCount = sl<ProviderRegistry>().getAll().length;
    final showCs = Platform.isAndroid || Platform.isWindows;
    final showAniyomi = Platform.isAndroid;
    final mangayomiCount = mangayomi?.installed.length ?? 0;
    var autofocusAssigned = false;

    Widget row({
      required IconData icon,
      required String title,
      required String subtitle,
      required Color tint,
      required VoidCallback onTap,
    }) {
      final autofocus = !autofocusAssigned;
      autofocusAssigned = true;
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TvListFocusable(
          autofocus: autofocus,
          semanticLabel: title,
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: tint.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: tint, size: 22),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(title, style: AppText.headline),
                      const SizedBox(height: 3),
                      Text(subtitle, style: AppText.caption),
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: AppColors.textTertiary,
                  size: 22,
                ),
              ],
            ),
          ),
        ),
      );
    }

    // Header (Back) and list are separate traversal groups so D-pad up from
    // the first ecosystem row lands on Back — not a stray focusable in the
    // title row — and down from Back enters the list at the autofocused row.
    // Mihon / LNReader stay phone-only (those screens have no TV branch).
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FocusTraversalGroup(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 48, 16),
                child: Row(
                  children: [
                    const TvBackButton(),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        context.l10n.providers,
                        style: AppText.largeTitle,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: FocusTraversalGroup(
                child: ListView(
                  // Focus rings scale slightly past the card; don't clip them.
                  clipBehavior: Clip.none,
                  padding: const EdgeInsets.fromLTRB(40, 0, 40, 48),
                  children: [
                    if (mangayomi != null)
                      row(
                        icon: Icons.extension_rounded,
                        title: 'Mangayomi',
                        subtitle: '$mangayomiCount installed',
                        tint: const Color(0xFF8B9CF6),
                        onTap: () => _open(const MangayomiSourcesScreen()),
                      ),
                    row(
                      icon: Icons.dns_rounded,
                      title: context.l10n.zangetsuProviders,
                      subtitle: '$zangetsuCount installed',
                      tint: AppColors.accent,
                      onTap: () => _open(const ZangetsuSourcesScreen()),
                    ),
                    if (sl.isRegistered<StremioManager>())
                      row(
                        icon: Icons.movie_filter_outlined,
                        title: 'Stremio',
                        subtitle:
                            '${sl<StremioManager>().installations.length} addons',
                        tint: const Color(0xFFA78BFA),
                        onTap: () => _open(const StremioSourcesScreen()),
                      ),
                    if (showCs)
                      row(
                        icon: Icons.extension_outlined,
                        title: context.l10n.cloudStream,
                        subtitle: _csSubtitle(),
                        tint: _csBlue,
                        onTap: () => _open(const CloudStreamSourcesScreen()),
                      ),
                    if (showAniyomi)
                      row(
                        icon: Icons.movie_filter_outlined,
                        title: context.l10n.aniyomi,
                        subtitle: _aniyomiSubtitle(),
                        tint: _aniGreen,
                        onTap: () => _open(const AniyomiSourcesScreen()),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
