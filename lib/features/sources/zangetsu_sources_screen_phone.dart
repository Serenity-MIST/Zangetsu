// Zangetsu sources — phone UI.
part of 'zangetsu_sources_screen.dart';

// ---------------------------------------------------------------------------
// Phone view
// ---------------------------------------------------------------------------

/// Source metadata and controls share a compact desktop row when there is
/// enough room. Narrow windows and enlarged text stack the same controls so
/// labels remain readable and actions never become tiny icon-only targets.
class _ZDesktopSourceRow extends StatelessWidget {
  const _ZDesktopSourceRow({required this.heading, required this.actions});
  final Widget heading;
  final Widget actions;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final wide =
            constraints.maxWidth >= 680 &&
            MediaQuery.textScalerOf(context).scale(14) <= 21;
        if (wide) {
          return Row(
            children: [
              Expanded(flex: 3, child: heading),
              const SizedBox(width: 16),
              Flexible(
                flex: 2,
                child: Align(alignment: Alignment.centerRight, child: actions),
              ),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [heading, const SizedBox(height: 12), actions],
        );
      },
    ),
  );
}

class _ZPhoneView extends StatefulWidget {
  const _ZPhoneView({this.openToRepos = false, this.scopeToReading = false});

  /// See [ZangetsuSourcesScreen.openToRepos].
  final bool openToRepos;

  /// See [ZangetsuSourcesScreen.scopeToReading].
  final bool scopeToReading;

  @override
  State<_ZPhoneView> createState() => _ZPhoneViewState();
}

class _ZPhoneViewState extends State<_ZPhoneView> {
  final _searchCtrl = TextEditingController();
  String _query = '';

  /// User-toggled escape hatch out of the reading-only scope. Only consulted
  /// when [ZangetsuSourcesScreen.scopeToReading] is true; irrelevant (and
  /// never surfaced) otherwise.
  bool _showAll = false;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Desktop toolbar keeps navigation and repository creation in normal flow.
  /// A narrow workspace stacks actions instead of hiding them under a FAB.
  Widget _desktopToolbar(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(22, 12, 22, 0),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final tabs = SizedBox(
          width: 300,
          child: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: context.l10n.installed),
              Tab(text: context.l10n.repositories),
            ],
          ),
        );
        final add = FilledButton.icon(
          key: const ValueKey('desktop-add-zangetsu-repo'),
          onPressed: () => _showAddRepoDialog(context),
          icon: const Icon(Icons.add, size: 18),
          label: Text(context.l10n.addZangetsuRepo),
        );
        return Align(
          alignment: Alignment.centerLeft,
          child: Wrap(
            spacing: 20,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: constraints.maxWidth < 300 ? constraints.maxWidth : 300,
                child: tabs,
              ),
              add,
            ],
          ),
        );
      },
    ),
  );

  @override
  Widget build(BuildContext context) {
    final readingOnly = widget.scopeToReading && !_showAll;
    final desktop = DesktopSettingsScope.contains(context);
    return BlocListener<SourcesBloc, SourcesState>(
      listenWhen: (a, b) =>
          b.notice != null &&
          (a.notice != b.notice || a.noticeSeq != b.noticeSeq),
      listener: (context, state) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(state.notice!)));
      },
      child: DefaultTabController(
        length: 2,
        initialIndex: widget.openToRepos ? 1 : 0,
        child: Scaffold(
          backgroundColor: AppColors.bg,
          appBar: desktop
              ? settingsAppBar(
                  widget.scopeToReading
                      ? 'Manga & Novel providers'
                      : context.l10n.zangetsuProviders,
                )
              : AppBar(
                  title: Text(
                    widget.scopeToReading
                        ? 'Manga & Novel providers'
                        : context.l10n.zangetsuProviders,
                    style: AppText.barTitle,
                  ),
                  bottom: TabBar(
                    indicatorColor: AppColors.accent,
                    indicatorSize: TabBarIndicatorSize.label,
                    labelColor: AppColors.textPrimary,
                    unselectedLabelColor: AppColors.textSecondary,
                    labelStyle: AppText.headline,
                    unselectedLabelStyle: AppText.headline,
                    dividerHeight: 0,
                    tabs: [
                      Tab(text: context.l10n.installed),
                      Tab(text: context.l10n.repositories),
                    ],
                  ),
                ),
          floatingActionButton: desktop
              ? null
              : FloatingActionButton.extended(
                  backgroundColor: AppColors.accent,
                  foregroundColor: Colors.white,
                  onPressed: () => _showAddRepoDialog(context),
                  icon: const Icon(Icons.add),
                  label: Text(
                    context.l10n.addZangetsuRepo,
                    style: AppText.button.copyWith(color: Colors.white),
                  ),
                ),
          body: Column(
            children: [
              if (desktop) _desktopToolbar(context),
              Padding(
                padding: desktop
                    ? const EdgeInsets.fromLTRB(22, 12, 22, 0)
                    : const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: SourcesSearchField(
                  controller: _searchCtrl,
                  onChanged: (q) => setState(() => _query = q),
                ),
              ),
              // Scoped-entry affordance (Task E3 fix round 1): only shown
              // when opened from the Manga & Novel row. Guarantees the user
              // can always reach every installed source, scoped or not.
              if (widget.scopeToReading)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _showAll
                              ? context.l10n.showingEveryInstalledProvider
                              : context.l10n.showingMangaNovelProviders,
                          style: AppText.caption,
                        ),
                      ),
                      TextButton(
                        onPressed: () => setState(() => _showAll = !_showAll),
                        child: Text(
                          _showAll
                              ? context.l10n.mangaNovelOnly
                              : context.l10n.showAllProviders,
                        ),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: TabBarView(
                  children: [
                    ListView(
                      padding: desktop
                          ? const EdgeInsets.fromLTRB(22, 12, 22, 24)
                          : const EdgeInsets.fromLTRB(16, 12, 16, 96),
                      children: [
                        _ZInstalledSection(
                          query: _query,
                          readingOnly: readingOnly,
                        ),
                      ],
                    ),
                    ListView(
                      padding: desktop
                          ? const EdgeInsets.fromLTRB(22, 12, 22, 24)
                          : const EdgeInsets.fromLTRB(16, 12, 16, 96),
                      children: [_ZReposSection(query: _query)],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> _showAddRepoDialog(BuildContext context) {
  final bloc = context.read<SourcesBloc>();
  // Root dialog routes do not inherit the content navigator's scope marker.
  // Capture it explicitly so the form keeps its Windows presentation.
  final desktop = DesktopSettingsScope.contains(context);
  return showDialog<void>(
    context: context,
    builder: (_) => desktop
        ? DesktopSettingsScope(child: _ZAddRepoDialog(bloc: bloc))
        : _ZAddRepoDialog(bloc: bloc),
  );
}

/// Installed zone body for phone — the JS provider groups by origin repo.
/// Hides when empty with an empty-state line + hint.
class _ZInstalledSection extends StatelessWidget {
  const _ZInstalledSection({this.query = '', this.readingOnly = false});

  final String query;

  /// Task E3 fix round 1: when true, only manga/novel entries are shown
  /// (the Manga & Novel hub row's scoped view). Default false is today's
  /// unfiltered behavior, unchanged.
  final bool readingOnly;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<SourcesBloc, SourcesState>(
      buildWhen: (a, b) => a.installed != b.installed || a.repos != b.repos,
      builder: (context, state) {
        final entries = state.installed
            .where(
              (e) => sourceSearchMatches(
                query,
                e.displayName.isNotEmpty ? e.displayName : e.name,
              ),
            )
            .where((e) => !readingOnly || _isReadingEntry(e))
            .toList();
        if (entries.isEmpty) {
          return EmptyState(
            icon: Icons.dns_rounded,
            message: query.trim().isEmpty
                ? (readingOnly
                      ? context.l10n.noMangaNovelProvidersInstalled
                      : context.l10n.noProvidersInstalled)
                : context.l10n.noInstalledProvidersMatchQuery(query.trim()),
          );
        }
        // Group by origin repo. Bundled first, then repos alphabetically by
        // their resolved display name.
        final groups = <String, List<ProviderRegistryEntry>>{};
        for (final e in entries) {
          final key = e.originRepoUrl.isEmpty
              ? kBundledRepoUrl
              : e.originRepoUrl;
          groups.putIfAbsent(key, () => []).add(e);
        }
        final repoByUrl = {for (final r in state.repos) r.url: r};
        String nameFor(String repoUrl) {
          if (repoUrl == kBundledRepoUrl) return context.l10n.builtIn;
          final repo = repoByUrl[repoUrl];
          if (repo != null) return repo.displayName;
          // Fall back to a display name snapshotted on an entry, else the URL.
          final snap = groups[repoUrl]!
              .map((e) => e.displayName)
              .firstWhere((n) => n.isNotEmpty, orElse: () => repoUrl);
          return snap;
        }

        final keys = groups.keys.toList()
          ..sort((a, b) {
            if (a == kBundledRepoUrl) return -1;
            if (b == kBundledRepoUrl) return 1;
            return nameFor(a).toLowerCase().compareTo(nameFor(b).toLowerCase());
          });

        return Column(
          children: [
            for (final key in keys)
              _ZInstalledGroup(
                title: nameFor(key),
                repoUrl: key,
                searching: query.trim().isNotEmpty,
                entries: groups[key]!
                  ..sort((a, b) {
                    final an = a.displayName.isNotEmpty
                        ? a.displayName
                        : a.name;
                    final bn = b.displayName.isNotEmpty
                        ? b.displayName
                        : b.name;
                    return an.toLowerCase().compareTo(bn.toLowerCase());
                  }),
              ),
          ],
        );
      },
    );
  }
}

/// sourceTypeOf is the app's one ProviderType resolver — reused here for the
/// Manga & Novel scoped view rather than re-derived.
bool _isReadingEntry(ProviderRegistryEntry e) {
  final t = sourceTypeOf(e.name);
  return t == ProviderType.manga || t == ProviderType.novel;
}

/// Repositories zone body for phone — repo rows with browse/install.
class _ZReposSection extends StatelessWidget {
  const _ZReposSection({this.query = ''});

  final String query;

  @override
  Widget build(BuildContext context) {
    final searching = query.trim().isNotEmpty;
    return BlocBuilder<SourcesBloc, SourcesState>(
      buildWhen: (a, b) => a.repos != b.repos || a.installed != b.installed,
      builder: (context, state) {
        // Search: keep only repos with at least one matching source.
        final all = !searching
            ? state.repos
            : [
                for (final r in state.repos)
                  if (r.sources.any(
                    (s) => sourceSearchMatches(query, s.name, s.lang),
                  ))
                    r,
              ];
        if (all.isEmpty) {
          return EmptyState(
            icon: Icons.cloud_off_rounded,
            message: searching
                ? context.l10n.noProvidersMatchQuery(query.trim())
                : context.l10n.noReposAddedYetTap(context.l10n.addRepo),
          );
        }
        final installedKeys = state.installedKeys;
        final updatableKeys = state.updatableKeys;
        return Column(
          children: [
            for (final repo in all)
              _ZRepoSection(
                repo: repo,
                installedKeys: installedKeys,
                updatableKeys: updatableKeys,
                query: query,
              ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Lifted verbatim from sources_screen.dart — Installed tab widgets.
// (renamed with a Z prefix to avoid collisions with the originals)
// ---------------------------------------------------------------------------

class _ZInstalledGroup extends StatefulWidget {
  const _ZInstalledGroup({
    required this.title,
    required this.repoUrl,
    required this.entries,
    this.searching = false,
  });

  final String title;
  final String repoUrl;
  final List<ProviderRegistryEntry> entries;

  /// True while a search query is active — the group stays expanded so its
  /// matches are visible.
  final bool searching;

  @override
  State<_ZInstalledGroup> createState() => _ZInstalledGroupState();
}

class _ZInstalledGroupState extends State<_ZInstalledGroup> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final entries = widget.entries;
    if (DesktopSettingsScope.contains(context)) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: GraphiteSettingsPanel(
          margin: EdgeInsets.zero,
          children: [
            GraphiteSettingsControl(
              key: ValueKey('desktop-source-group-${widget.repoUrl}'),
              icon: _expanded || widget.searching
                  ? Icons.folder_open_outlined
                  : Icons.folder_outlined,
              title: widget.title,
              subtitle: '${entries.length} installed sources',
              onTap: () => setState(() => _expanded = !_expanded),
            ),
            if (_expanded || widget.searching)
              for (final entry in entries) _ZInstalledRow(entry: entry),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 8, 8),
            child: Row(
              children: [
                AnimatedRotation(
                  turns: _expanded ? 0 : -0.25,
                  duration: const Duration(milliseconds: 200),
                  child: const Icon(
                    Icons.expand_more,
                    color: AppColors.textTertiary,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    widget.title.toUpperCase(),
                    style: AppText.overline.copyWith(
                      color: AppColors.textTertiary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '${entries.length}',
                  style: AppText.overline.copyWith(
                    color: AppColors.textTertiary,
                  ),
                ),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          // A live search forces the group open so matches are visible.
          child: !(_expanded || widget.searching)
              ? const SizedBox(width: double.infinity)
              : Container(
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    children: [
                      for (var i = 0; i < entries.length; i++) ...[
                        if (i > 0)
                          const Divider(
                            height: 0.5,
                            thickness: 0.5,
                            color: AppColors.hairline,
                          ),
                        _ZInstalledRow(entry: entries[i]),
                      ],
                    ],
                  ),
                ),
        ),
        const SizedBox(height: 18),
      ],
    );
  }
}

class _ZInstalledRow extends StatelessWidget {
  const _ZInstalledRow({required this.entry});
  final ProviderRegistryEntry entry;

  String get _key =>
      ProviderRegistry.providerKey(entry.originRepoUrl, entry.name);

  Future<void> _confirmRemove(BuildContext context) async {
    final bloc = context.read<SourcesBloc>();
    final name = entry.displayName.isNotEmpty ? entry.displayName : entry.name;
    final ok = await AppDialog.confirm(
      context,
      title: context.l10n.removeNameQuestion(name),
      message: context.l10n.theProviderWillBeRemovedFromYourInstalledSources,
      confirmLabel: context.l10n.removeDownloadTooltip,
      destructive: true,
    );
    if (ok != true) return;
    bloc.add(SourceUninstalled(_key, displayName: name));
  }

  /// Desktop actions wrap below long source labels instead of squeezing
  /// the title between a touch switch and several unlabeled icon buttons.
  Widget _desktopRow(
    BuildContext context,
    String name,
    String meta,
    String? logo,
    bool hasUpdate,
    String? newVersion,
  ) => _ZDesktopSourceRow(
    heading: Row(
      children: [
        SourceIconTile(name: name, icon: logo),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                style: AppText.body.copyWith(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 4),
              Text(meta, style: AppText.caption),
            ],
          ),
        ),
      ],
    ),
    actions: Wrap(
      spacing: 12,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              label: '$name enabled',
              child: Switch(
                key: ValueKey('desktop-source-enabled-$_key'),
                value: entry.enabled,
                onChanged: (value) => context.read<SourcesBloc>().add(
                  SourceEnabledToggled(_key, enabled: value),
                ),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              entry.enabled ? 'Enabled' : 'Disabled',
              style: AppText.caption,
            ),
          ],
        ),
        if (hasUpdate)
          OutlinedButton.icon(
            onPressed: () =>
                context.read<SourcesBloc>().add(SourceUpdated(_key)),
            icon: const Icon(Icons.download_outlined, size: 18),
            label: Text('Update to v$newVersion'),
          ),
        OutlinedButton.icon(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => SourceSettingsScreen(
                sourceId: entry.name,
                repoUrl: entry.originRepoUrl,
                displayName: name,
              ),
            ),
          ),
          icon: const Icon(Icons.tune_outlined, size: 18),
          label: Text(context.l10n.sourceSettings),
        ),
        if (!entry.isBundled)
          TextButton.icon(
            onPressed: () => _confirmRemove(context),
            icon: const Icon(Icons.delete_outline, size: 18),
            label: Text(context.l10n.navTabsRemove),
          ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final bundled = entry.isBundled;
    final name = entry.displayName.isNotEmpty ? entry.displayName : entry.name;
    final state = context.read<SourcesBloc>().state;
    final hasUpdate = state.hasUpdate(_key);
    final newVersion = state.manifestVersions[_key];
    final meta = hasUpdate
        ? 'repo • v${entry.version} → v$newVersion'
        : '${bundled ? 'built-in' : 'repo'} • v${entry.version}';
    // Manifest first, install-time snapshot as the offline fallback.
    final saved = entry.logoUrl;
    final logo = state.manifestLogos[_key] ?? (saved.isEmpty ? null : saved);
    if (DesktopSettingsScope.contains(context)) {
      return _desktopRow(context, name, meta, logo, hasUpdate, newVersion);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 6, 8),
      child: Row(
        children: [
          // The repo manifest's `logo`, with the install-time snapshot as the
          // offline fallback. Letter tile when neither has one.
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 12),
            child: SourceIconTile(name: name, icon: logo),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: AppText.headline.copyWith(fontSize: 15),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  meta,
                  style: AppText.caption.copyWith(
                    color: hasUpdate ? AppColors.accent : null,
                  ),
                ),
              ],
            ),
          ),
          if (hasUpdate)
            IconButton(
              tooltip: 'Update to v$newVersion',
              icon: const Icon(Icons.download_rounded, size: 20),
              color: AppColors.accent,
              onPressed: () =>
                  context.read<SourcesBloc>().add(SourceUpdated(_key)),
            ),
          Switch.adaptive(
            value: entry.enabled,
            activeThumbColor: AppColors.accent,
            onChanged: (v) => context.read<SourcesBloc>().add(
              SourceEnabledToggled(_key, enabled: v),
            ),
          ),
          IconButton(
            tooltip: context.l10n.sourceSettings,
            icon: const Icon(Icons.tune_rounded, size: 20),
            color: AppColors.textSecondary,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => SourceSettingsScreen(
                  sourceId: entry.name,
                  repoUrl: entry.originRepoUrl,
                  displayName: name,
                ),
              ),
            ),
          ),
          if (!bundled)
            IconButton(
              tooltip: context.l10n.navTabsRemove,
              icon: const Icon(Icons.delete_outline_rounded, size: 20),
              color: AppColors.textSecondary,
              onPressed: () => _confirmRemove(context),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Lifted verbatim from sources_screen.dart — Repos tab widgets.
// ---------------------------------------------------------------------------

class _ZRepoSection extends StatefulWidget {
  const _ZRepoSection({
    required this.repo,
    required this.installedKeys,
    required this.updatableKeys,
    this.query = '',
  });

  final ProviderRepo repo;
  final Set<String> installedKeys;
  final Set<String> updatableKeys;

  /// Live search query — filters the source rows; a non-empty query also
  /// forces the section open so matches are visible.
  final String query;

  @override
  State<_ZRepoSection> createState() => _ZRepoSectionState();
}

class _ZRepoSectionState extends State<_ZRepoSection> {
  bool _expanded = true;

  ProviderRepo get repo => widget.repo;
  Set<String> get installedKeys => widget.installedKeys;
  Set<String> get updatableKeys => widget.updatableKeys;

  int get _updateCount => repo.sources
      .where(
        (s) => updatableKeys.contains(
          ProviderRegistry.providerKey(repo.url, s.id),
        ),
      )
      .length;

  Future<void> _remove(BuildContext context) async {
    final bloc = context.read<SourcesBloc>();
    final ok = await AppDialog.confirm(
      context,
      title: context.l10n.removeRepo,
      message:
          context.l10n.alreadyInstalledSourcesFromRepoStay(repo.displayName) +
          context.l10n.youCanAddRepoBackLater,
      confirmLabel: context.l10n.removeDownloadTooltip,
      destructive: true,
    );
    if (ok != true) return;
    bloc.add(RepoRemoved(repo.url, displayName: repo.displayName));
  }

  /// Desktop repositories expose common actions directly and retain normal
  /// keyboard focus instead of hiding refresh/removal in a phone overflow menu.
  Widget _desktopRepository(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: GraphiteSettingsPanel(
      margin: EdgeInsets.zero,
      children: [
        GraphiteSettingsControl(
          key: ValueKey('desktop-repository-${repo.url}'),
          icon: _expanded || widget.query.trim().isNotEmpty
              ? Icons.folder_open_outlined
              : Icons.folder_outlined,
          title: repo.displayName,
          subtitle:
              '${repo.sources.length} sources'
              '${_updateCount > 0 ? ' · $_updateCount updates available' : ''}',
          onTap: () => setState(() => _expanded = !_expanded),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 0, 22, 14),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  key: ValueKey('desktop-repository-refresh-${repo.url}'),
                  onPressed: () =>
                      context.read<SourcesBloc>().add(RepoRefreshed(repo.url)),
                  icon: const Icon(Icons.refresh_outlined, size: 18),
                  label: Text(context.l10n.checkForUpdates),
                ),
                if (_updateCount > 0)
                  FilledButton.icon(
                    onPressed: () =>
                        context.read<SourcesBloc>().add(RepoUpdated(repo.url)),
                    icon: const Icon(Icons.download_outlined, size: 18),
                    label: Text(context.l10n.updateAllCount(_updateCount)),
                  ),
                TextButton.icon(
                  onPressed: () => _remove(context),
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: Text(context.l10n.removeRepo2),
                ),
              ],
            ),
          ),
        ),
        if (_expanded || widget.query.trim().isNotEmpty)
          if (repo.sources.isEmpty)
            Padding(
              padding: const EdgeInsets.all(22),
              child: Text(
                context.l10n.noSourcesInThisRepoYet,
                style: AppText.caption,
              ),
            )
          else
            for (final source in repo.sources.where(
              (source) =>
                  (!source.nsfw || sl<PlaybackPrefs>().nsfwSources) &&
                  sourceSearchMatches(widget.query, source.name, source.lang),
            ))
              _ZRepoSourceRow(
                repo: repo,
                source: source,
                installed: installedKeys.contains(
                  ProviderRegistry.providerKey(repo.url, source.id),
                ),
                hasUpdate: updatableKeys.contains(
                  ProviderRegistry.providerKey(repo.url, source.id),
                ),
              ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (DesktopSettingsScope.contains(context)) {
      return _desktopRepository(context);
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _expanded = !_expanded),
                    child: Row(
                      children: [
                        AnimatedRotation(
                          turns: _expanded ? 0 : -0.25,
                          duration: const Duration(milliseconds: 200),
                          child: const Icon(
                            Icons.expand_more,
                            color: AppColors.textSecondary,
                            size: 22,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                repo.displayName,
                                style: AppText.headline,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _updateCount > 0
                                    ? '${repo.sources.length} sources • $_updateCount update${_updateCount == 1 ? '' : 's'}'
                                    : '${repo.sources.length} sources',
                                style: AppText.caption.copyWith(
                                  color: _updateCount > 0
                                      ? AppColors.accent
                                      : AppColors.textTertiary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_updateCount > 0)
                  TextButton.icon(
                    onPressed: () =>
                        context.read<SourcesBloc>().add(RepoUpdated(repo.url)),
                    icon: const Icon(Icons.download_rounded, size: 18),
                    label: Text(context.l10n.updateAllCount(_updateCount)),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.accent,
                    ),
                  ),
                PopupMenuButton<String>(
                  icon: const Icon(
                    Icons.more_vert,
                    color: AppColors.textSecondary,
                  ),
                  color: AppColors.surface2,
                  onSelected: (v) {
                    if (v == 'remove') _remove(context);
                    if (v == 'update') {
                      context.read<SourcesBloc>().add(RepoUpdated(repo.url));
                    }
                    if (v == 'refresh') {
                      context.read<SourcesBloc>().add(RepoRefreshed(repo.url));
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'refresh',
                      child: Text(
                        context.l10n.checkForUpdates,
                        style: AppText.body.copyWith(
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                    if (_updateCount > 0)
                      PopupMenuItem(
                        value: 'update',
                        child: Text(
                          'Update all ($_updateCount)',
                          style: AppText.body.copyWith(color: AppColors.accent),
                        ),
                      ),
                    PopupMenuItem(
                      value: 'remove',
                      child: Text(
                        context.l10n.removeRepo2,
                        style: AppText.body.copyWith(
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // Collapsible source list.
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            // A live search forces the section open so matches are visible.
            child: !(_expanded || widget.query.trim().isNotEmpty)
                ? const SizedBox(width: double.infinity)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (repo.sources.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Text(
                            context.l10n.noSourcesInThisRepoYet,
                            textAlign: TextAlign.center,
                            style: AppText.caption,
                          ),
                        )
                      else
                        // Hide NSFW sources unless the Privacy toggle is on;
                        // a live search also filters by name/lang.
                        for (final source in repo.sources.where(
                          (s) =>
                              (!s.nsfw || sl<PlaybackPrefs>().nsfwSources) &&
                              sourceSearchMatches(widget.query, s.name, s.lang),
                        )) ...[
                          const Divider(
                            height: 0.5,
                            thickness: 0.5,
                            color: AppColors.hairline,
                          ),
                          _ZRepoSourceRow(
                            repo: repo,
                            source: source,
                            installed: installedKeys.contains(
                              ProviderRegistry.providerKey(repo.url, source.id),
                            ),
                            hasUpdate: updatableKeys.contains(
                              ProviderRegistry.providerKey(repo.url, source.id),
                            ),
                          ),
                        ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// Small context.l10n.nsfw chip shown next to a source flagged 18+ in its manifest.
class _ZNsfwBadge extends StatelessWidget {
  const _ZNsfwBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.5)),
      ),
      child: Text(
        context.l10n.nsfw,
        style: AppText.overline.copyWith(
          color: AppColors.accent,
          fontWeight: FontWeight.w700,
          fontSize: 9,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _ZRepoSourceRow extends StatelessWidget {
  const _ZRepoSourceRow({
    required this.repo,
    required this.source,
    required this.installed,
    required this.hasUpdate,
  });

  final ProviderRepo repo;
  final RepoSource source;
  final bool installed;
  final bool hasUpdate;

  String get _key => ProviderRegistry.providerKey(repo.url, source.id);

  void _install(BuildContext context) {
    context.read<SourcesBloc>().add(
      SourceInstalled(repo: repo, source: source),
    );
  }

  void _update(BuildContext context) {
    context.read<SourcesBloc>().add(SourceUpdated(_key));
  }

  Future<void> _uninstall(BuildContext context) async {
    final bloc = context.read<SourcesBloc>();
    final ok = await AppDialog.confirm(
      context,
      title: context.l10n.uninstallNameQuestion(source.name),
      message: context.l10n.theProviderWillBeRemovedFromYourInstalledSources,
      confirmLabel: context.l10n.uninstall,
      destructive: true,
    );
    if (ok != true) return;
    bloc.add(SourceUninstalled(_key, displayName: source.name));
  }

  /// Readable desktop source metadata and explicit install/update/uninstall
  /// actions share their original bloc handlers and confirmation flow.
  Widget _desktopSource(BuildContext context) => _ZDesktopSourceRow(
    heading: Row(
      children: [
        SourceIconTile(
          name: source.name,
          icon: ProviderReposRegistry.resolveLogoUrl(repo, source),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                source.name,
                style: AppText.body.copyWith(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 4),
              Text(
                '${source.lang} · v${source.version}',
                style: AppText.caption,
              ),
              if (source.nsfw) const _ZNsfwBadge(),
            ],
          ),
        ),
      ],
    ),
    actions: Wrap(
      spacing: 12,
      runSpacing: 8,
      children: [
        if (!installed)
          FilledButton.icon(
            onPressed: () => _install(context),
            icon: const Icon(Icons.add, size: 18),
            label: Text(context.l10n.install),
          )
        else ...[
          if (hasUpdate)
            FilledButton.icon(
              onPressed: () => _update(context),
              icon: const Icon(Icons.download_outlined, size: 18),
              label: Text(context.l10n.update),
            ),
          OutlinedButton.icon(
            onPressed: () => _uninstall(context),
            icon: const Icon(Icons.delete_outline, size: 18),
            label: Text(context.l10n.uninstall),
          ),
        ],
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (DesktopSettingsScope.contains(context)) {
      return _desktopSource(context);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      child: Row(
        children: [
          // The manifest may declare a `logo`, relative to itself.
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 12),
            child: SourceIconTile(
              name: source.name,
              icon: ProviderReposRegistry.resolveLogoUrl(repo, source),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        source.name,
                        style: AppText.headline.copyWith(fontSize: 15),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (source.nsfw) ...[
                      const SizedBox(width: 8),
                      const _ZNsfwBadge(),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '${source.lang} • v${source.version}',
                  style: AppText.caption,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (installed && hasUpdate)
            FilledButton.icon(
              onPressed: () => _update(context),
              icon: const Icon(Icons.download_rounded, size: 18),
              label: Text(context.l10n.update),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                elevation: 0,
                minimumSize: const Size(96, 36),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            )
          else if (installed)
            OutlinedButton(
              onPressed: () => _uninstall(context),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.textSecondary,
                side: BorderSide(
                  color: AppColors.textSecondary.withValues(alpha: 0.4),
                ),
                minimumSize: const Size(96, 36),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: Text(context.l10n.installed),
            )
          else
            FilledButton(
              onPressed: () => _install(context),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                elevation: 0,
                minimumSize: const Size(96, 36),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: Text(context.l10n.install),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Lifted verbatim from sources_screen.dart — Add-repo dialog.
// ---------------------------------------------------------------------------

class _ZAddRepoDialog extends StatefulWidget {
  const _ZAddRepoDialog({required this.bloc});

  final SourcesBloc bloc;

  @override
  State<_ZAddRepoDialog> createState() => _ZAddRepoDialogState();
}

class _ZAddRepoDialogState extends State<_ZAddRepoDialog> {
  final _urlCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _urlCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) {
      setState(() => _error = context.l10n.enterManifestUrl);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    final name = _nameCtrl.text.trim();
    // The bloc emits the "Added …" notice on success; on failure it returns
    // the message so we can render it inline and keep the dialog open.
    final error = await widget.bloc.addRepo(
      url,
      customName: name.isEmpty ? null : name,
    );
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _loading = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final desktop = DesktopSettingsScope.contains(context);
    return AlertDialog(
      constraints: desktop
          ? BoxConstraints(
              maxWidth: 560,
              maxHeight: MediaQuery.sizeOf(context).height * .85,
            )
          : null,
      shape: desktop
          ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))
          : null,
      insetPadding: desktop
          ? const EdgeInsets.all(24)
          : const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      backgroundColor: AppColors.surface,
      title: Text(context.l10n.addRepo, style: AppText.headline),
      content: SizedBox(
        width: desktop ? 480 : null,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _nameCtrl,
                enabled: !_loading,
                cursorColor: AppColors.accent,
                style: AppText.body.copyWith(color: AppColors.textPrimary),
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  labelText: context.l10n.customNameOptional,
                  hintText: context.l10n.leaveBlankToUseTheRepoSOwnName,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _urlCtrl,
                enabled: !_loading,
                autofocus: true,
                keyboardType: TextInputType.url,
                cursorColor: AppColors.accent,
                style: AppText.body.copyWith(color: AppColors.textPrimary),
                decoration: InputDecoration(
                  labelText: context.l10n.manifestUrl,
                  hintText: context.l10n.manifestUrlHint,
                ),
              ),
              const SizedBox(height: 10),
              Text(context.l10n.pasteRepoIndexJsonUrl, style: AppText.caption),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: AppText.caption.copyWith(color: AppColors.accent),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _loading ? null : () => Navigator.of(context).pop(),
          child: Text(
            context.l10n.cancel,
            style: AppText.body.copyWith(color: AppColors.textSecondary),
          ),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.accent,
            foregroundColor: Colors.white,
          ),
          onPressed: _loading ? null : _submit,
          child: _loading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : Text(context.l10n.navTabsAdd),
        ),
      ],
    );
  }
}
