import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';

import '../../core/aniyomi/aniyomi_repo.dart';
import '../../core/mihon/mihon_provider.dart';
import '../../core/repository/source_actions.dart' as source_actions;
import '../../core/ui/source_icon_tile.dart';
import '../../core/di/injector.dart';
import '../../core/i18n/source_languages.dart';
import '../../core/mihon/mihon_extension_service.dart';
import '../../core/mihon/mihon_manager.dart';
import '../../core/mihon/mihon_repo.dart';
import '../../core/mihon/mihon_update.dart';
import '../../core/prefs/source_lang_prefs.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/app_dialog.dart';
import '../../core/ui/states.dart';
import 'sources_search_field.dart'; // also brings the Windows kit
import '../../l10n/l10n.dart';

/// Hive box name for persisted Mihon repo URLs.
///
/// Deliberately separate from `kAniyomiReposBoxName` ('aniyomi_repos') so the
/// two repo lists (and the extensions installed from them) never collide.
const String kMihonReposBoxName = 'mihon_repos';

// ---------------------------------------------------------------------------
// Public add-repo dialog (structural twin of AniyomiAddRepoDialog)
// ---------------------------------------------------------------------------

/// Dialog for adding a Mihon manga extension repository.
///
/// Returns the chosen repo URL (base URL without `/index.json`) via
/// [Navigator.pop(context, url)] when the user picks a recommendation or
/// submits the URL field.  Returns null on cancel.
///
/// [alreadyAddedUrls] marks repos that have already been added so they show
/// an "Added" label instead of an context.l10n.navTabsAdd button.
///
/// Structural twin of `AniyomiAddRepoDialog`
/// (`lib/features/sources/aniyomi_repo_tab.dart`) — deliberately duplicated
/// rather than shared (spec Decision 3).
class MihonAddRepoDialog extends StatefulWidget {
  const MihonAddRepoDialog({super.key, this.alreadyAddedUrls = const {}});

  final Set<String> alreadyAddedUrls;

  @override
  State<MihonAddRepoDialog> createState() => _MihonAddRepoDialogState();
}

class _MihonAddRepoDialogState extends State<MihonAddRepoDialog> {
  final _urlCtrl = TextEditingController();

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final url = _urlCtrl.text.trim();
    if (url.isNotEmpty) Navigator.pop(context, url);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(context.l10n.addMihonRepo, style: AppText.headline),
      content: SingleChildScrollView(
        // Windows: clipboard pre-fill + drop a link / file (src-12 B).
        child: DesktopAddRepoAssist(
          controller: _urlCtrl,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _urlCtrl,
                // Windows: focus the field so Enter adds a pre-filled link.
                autofocus: desktopPanelsEnabled,
                keyboardType: TextInputType.url,
                cursorColor: AppColors.accent,
                style: AppText.body.copyWith(color: AppColors.textPrimary),
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  labelText: context.l10n.repoBaseUrl,
                  hintText: context.l10n.repoBaseUrlHint,
                ),
              ),
              const SizedBox(height: 10),
              Text(context.l10n.pasteRepoBaseUrlMihon, style: AppText.caption),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
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
          onPressed: _submit,
          child: Text(context.l10n.navTabsAdd),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Public repo tab — injectable seams for tests
// ---------------------------------------------------------------------------

/// The content of the Mihon tab: one collapsible card per tracked repo, each
/// listing its manga extensions with Install / Installed actions.
///
/// [repoUrls] is the list of tracked repo base URLs (owned by the caller —
/// the Mihon sources screen, not yet built as of this widget).
/// [onRemoveRepo] removes a URL from that list.
///
/// All four optional callbacks are injectable seams for widget tests so the
/// network, native channel, and Hive are never touched:
/// - [fetchIndexFn]: replaces [MihonRepo.fetchIndex] (the manga index reader —
///   the anime `AniyomiRepo.fetchIndex` reads a different file in a different
///   shape and returns two deprecation stubs for keiyoushi).
/// - [installFn]: replaces [MihonExtensionService.installFromRepo].
/// - [uninstallFn]: replaces the default uninstall logic.
/// - [installedPkgsFn]: replaces the Hive-box installed check.
///
/// Structural twin of `AniyomiRepoTab`
/// (`lib/features/sources/aniyomi_repo_tab.dart`) — deliberately duplicated
/// rather than shared (spec Decision 3).
class MihonRepoTab extends StatefulWidget {
  const MihonRepoTab({
    super.key,
    required this.repoUrls,
    required this.onRemoveRepo,
    this.query = '',
    this.fetchIndexFn,
    this.installFn,
    this.uninstallFn,
    this.installedPkgsFn,
  });

  final List<String> repoUrls;
  final void Function(String url) onRemoveRepo;

  /// Live search query — each repo section filters its entries by it.
  final String query;

  final Future<List<AniyomiRepoEntry>> Function(String url)? fetchIndexFn;
  final Future<void> Function(AniyomiRepoEntry entry)? installFn;
  final Future<void> Function(String pkg)? uninstallFn;
  final bool Function(String pkg)? installedPkgsFn;

  @override
  State<MihonRepoTab> createState() => _MihonRepoTabState();
}

/// Retains a refresh revision so pulling refresh really refetches each repo.
class _MihonRepoTabState extends State<MihonRepoTab>
    with DesktopRefreshTicks<MihonRepoTab> {
  /// F5 on Windows (src-13 A): same as pull-to-refresh, every repo refetches.
  @override
  void onDesktopRefresh() {
    if (mounted) setState(() => _revision++);
  }

  int _revision = 0;
  List<String> get repoUrls => widget.repoUrls;
  void Function(String) get onRemoveRepo => widget.onRemoveRepo;
  String get query => widget.query;
  Future<List<AniyomiRepoEntry>> Function(String)? get fetchIndexFn =>
      widget.fetchIndexFn;
  Future<void> Function(AniyomiRepoEntry)? get installFn => widget.installFn;
  Future<void> Function(String)? get uninstallFn => widget.uninstallFn;
  bool Function(String)? get installedPkgsFn => widget.installedPkgsFn;

  @override
  Widget build(BuildContext context) {
    if (repoUrls.isEmpty) {
      return EmptyState(
        icon: Icons.extension_outlined,
        message: context.l10n.noMihonReposAddedYetNTapAddMihonRepoToAddOne,
      );
    }
    return RefreshIndicator(
      color: AppColors.accent,
      backgroundColor: AppColors.surface,
      onRefresh: () async => setState(() => _revision++),
      child: ListView.builder(
        // Windows has no floating button to leave room for (src-3 B).
        padding: desktopPanelsEnabled
            ? kDesktopSourcesListPadding
            : const EdgeInsets.fromLTRB(16, 12, 16, 96),
        itemCount: repoUrls.length,
        itemBuilder: (_, i) => _MihonRepoSection(
          key: ValueKey('${repoUrls[i]}:$_revision'),
          url: repoUrls[i],
          onRemove: () => onRemoveRepo(repoUrls[i]),
          query: query,
          fetchIndexFn: fetchIndexFn,
          installFn: installFn,
          uninstallFn: uninstallFn,
          installedPkgsFn: installedPkgsFn,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Collapsible repo card
// ---------------------------------------------------------------------------

class _MihonRepoSection extends StatefulWidget {
  const _MihonRepoSection({
    super.key,
    required this.url,
    required this.onRemove,
    this.query = '',
    this.fetchIndexFn,
    this.installFn,
    this.uninstallFn,
    this.installedPkgsFn,
    this.managerOverride,
  });

  final String url;
  final VoidCallback onRemove;

  /// Live search query — filters the fetched entries; a non-empty query also
  /// forces the section open so matches are visible.
  final String query;
  final Future<List<AniyomiRepoEntry>> Function(String url)? fetchIndexFn;
  final Future<void> Function(AniyomiRepoEntry entry)? installFn;
  final Future<void> Function(String pkg)? uninstallFn;
  final bool Function(String pkg)? installedPkgsFn;

  /// Test seam: overrides the live `sl<MihonManager>()` lookup used for the
  /// repo's update-check / update-all / badge behavior.
  final MihonManager? managerOverride;

  @override
  State<_MihonRepoSection> createState() => _MihonRepoSectionState();
}

class _MihonRepoSectionState extends State<_MihonRepoSection> {
  List<AniyomiRepoEntry>? _entries;
  bool _fetching = true;
  String? _fetchError;
  bool _expanded = true;
  bool _checking = false;
  bool _updating = false;

  // Local installed-state cache for instant UI feedback after install/uninstall.
  final Set<String> _installedPkgs = {};

  /// Null in widget tests that don't register it — the language filter is then
  /// simply off (every entry shows), so those tests keep asserting on the full
  /// list. In the app it's always registered.
  final MangaLangPrefs? _langPrefs = sl.isRegistered<MangaLangPrefs>()
      ? sl<MangaLangPrefs>()
      : null;

  /// Null when [MihonManager] isn't DI-registered (e.g. a widget test that
  /// builds this section directly without going through the app's injector).
  MihonManager? get _manager =>
      widget.managerOverride ??
      (sl.isRegistered<MihonManager>() ? sl<MihonManager>() : null);

  @override
  void initState() {
    super.initState();
    _langPrefs?.addListener(_onLangsChanged);
    _loadInstalledState();
    _fetchCatalog();
  }

  @override
  void dispose() {
    _langPrefs?.removeListener(_onLangsChanged);
    super.dispose();
  }

  void _onLangsChanged() {
    if (mounted) setState(() {});
  }

  void _loadInstalledState() {
    if (widget.installedPkgsFn != null) return;
    try {
      if (Hive.isBoxOpen(MihonExtensionService.installedBoxName)) {
        final box = Hive.box<dynamic>(MihonExtensionService.installedBoxName);
        _installedPkgs.addAll(box.keys.cast<String>());
      }
    } catch (_) {}
  }

  bool _isInstalled(String pkg) {
    if (widget.installedPkgsFn != null) return widget.installedPkgsFn!(pkg);
    if (_installedPkgs.contains(pkg)) return true;
    try {
      if (Hive.isBoxOpen(MihonExtensionService.installedBoxName)) {
        return Hive.box<dynamic>(
          MihonExtensionService.installedBoxName,
        ).containsKey(pkg);
      }
    } catch (_) {}
    return false;
  }

  Future<void> _fetchCatalog() async {
    try {
      final fn = widget.fetchIndexFn ?? MihonRepo.fetchIndex;
      final entries = await fn(widget.url);
      if (mounted) {
        setState(() {
          _entries = entries;
          _fetching = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _fetchError = e.toString();
          _fetching = false;
        });
      }
    }
  }

  String get _repoDisplayName {
    final uri = Uri.tryParse(widget.url);
    if (uri == null) return widget.url;
    final segs = uri.pathSegments;
    if (segs.length >= 2) return '${segs[0]}/${segs[1]}';
    return uri.host;
  }

  Future<void> _confirmRemove(BuildContext context) async {
    final ok = await AppDialog.confirm(
      context,
      title: context.l10n.removeRepo,
      message:
          context.l10n.alreadyInstalledExtensionsStay +
          context.l10n.youCanAddRepoBackLater,
      confirmLabel: context.l10n.removeDownloadTooltip,
      destructive: true,
    );
    if (ok == true) widget.onRemove();
  }

  /// READ-ONLY check of this repo for extension updates via
  /// [MihonManager.checkRepoUpdates] (no download). Reports how many are
  /// available; the accent badge + "Update all" menu item then appear.
  Future<void> _checkForUpdates() async {
    final mgr = _manager;
    if (mgr == null) return;
    final messenger = ScaffoldMessenger.of(context);
    // Read before the await: the section may be gone when it returns.
    final l10n = context.l10n;
    setState(() => _checking = true);
    try {
      final list = await mgr.checkRepoUpdates(widget.url);
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(
              list.isEmpty
                  ? l10n.alreadyUpToDate
                  : list.length == 1
                  ? l10n.oneUpdate
                  : l10n.nUpdates(list.length),
            ),
          ),
        );
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  /// Installs a single entry, reporting whether it actually succeeded.
  ///
  /// [widget.installFn] is a test seam that returns `Future<void>` and throws
  /// on failure, so a non-throwing call always counts as success. The default
  /// path calls [MihonExtensionService.installFromRepo], which never throws
  /// and instead returns an empty list on failure — that emptiness is what we
  /// key success off of.
  ///
  /// The default path now uses [MihonExtensionService.installFromRepoOrThrow]
  /// so a failure carries its reason to the 'Update all' summary (src-5).
  Future<bool> _applyOne(AniyomiRepoEntry entry, MihonManager mgr) async {
    if (widget.installFn != null) {
      await widget.installFn!(entry);
      return true;
    }
    final providers = await MihonExtensionService().installFromRepoOrThrow(
      entry,
      manager: mgr,
    );
    return providers.isNotEmpty;
  }

  /// Applies every pending update for this repo (re-installs each newer entry)
  /// via [widget.installFn] or the default [MihonExtensionService.installFromRepo].
  ///
  /// Only clears a package's pending update when its install actually
  /// succeeded — a failed download must keep reporting the source as
  /// outdated rather than silently clearing the badge.
  ///
  /// [only] limits the run to those updates (the Retry of the summary).
  /// On Windows the run ends with 'Updated 3 of 5. 2 failed' and a Details
  /// list with each reason and Retry (src-5 A); phone keeps its snackbar.
  Future<void> _updateAll({List<MihonUpdate>? only}) async {
    final mgr = _manager;
    if (!mounted || mgr == null || _updating) return;
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    final updates = only ?? List<MihonUpdate>.from(mgr.updatesFor(widget.url));
    if (updates.isEmpty) return;
    setState(() => _updating = true);
    var done = 0;
    final failed = <MihonUpdate>[];
    final failures = <ExtensionUpdateFailure>[];
    try {
      for (final u in updates) {
        try {
          if (await _applyOne(u.entry, mgr)) {
            mgr.clearUpdatesForPkg(u.pkg);
            done++;
          } else {
            throw ExtensionInstallFailure.noSource(u.pkg);
          }
        } catch (e) {
          // Keep the reason instead of dropping it (it used to be `catch (_)`).
          final failure = ExtensionInstallFailure.from(e);
          failed.add(u);
          failures.add(
            ExtensionUpdateFailure(
              name: u.name,
              reason: failure.reason,
              details: failure.details,
            ),
          );
        }
      }
    } finally {
      if (mounted) setState(() => _updating = false);
    }
    final successText = l10n.updatedSourcesCount(done, done == 1 ? '' : 's');
    if (!desktopPanelsEnabled) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(successText)));
      return;
    }
    showUpdateAllSummary(
      messenger,
      total: updates.length,
      done: done,
      failures: failures,
      successText: successText,
      onRetry: () => _updateAll(only: failed),
    );
  }

  @override
  Widget build(BuildContext context) {
    final searching = widget.query.trim().isNotEmpty;
    // While searching, a fully-loaded section with zero matches disappears
    // entirely (matching the CloudStream screen's behavior).
    if (searching &&
        !_fetching &&
        _fetchError == null &&
        _filteredEntries.isEmpty) {
      return const SizedBox.shrink();
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
          // ── Header ──────────────────────────────────────────────────────
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
                                _repoDisplayName,
                                style: AppText.headline,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _fetching
                                    ? context.l10n.loading
                                    : _fetchError != null
                                    ? context.l10n.failedToLoad
                                    : '${_entries?.length ?? 0} extension'
                                          '${(_entries?.length ?? 0) == 1 ? '' : 's'}',
                                style: AppText.caption.copyWith(
                                  color: _fetchError != null
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
                // "N updates" pill when this repo has installed extensions
                // with a newer version available (tap → update all). Hidden
                // entirely when the manager isn't DI-registered (tests).
                Builder(
                  builder: (context) {
                    final mgr = _manager;
                    if (mgr == null) return const SizedBox.shrink();
                    return AnimatedBuilder(
                      animation: mgr,
                      builder: (context, _) {
                        final n = mgr.updatesFor(widget.url).length;
                        if (n == 0) return const SizedBox.shrink();
                        return Padding(
                          padding: const EdgeInsetsDirectional.only(end: 2),
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: _updateAll,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.accent.withValues(alpha: 0.16),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                n == 1 ? context.l10n.oneUpdate : '$n updates',
                                style: AppText.caption.copyWith(
                                  color: AppColors.accent,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
                PopupMenuButton<String>(
                  icon: const Icon(
                    Icons.more_vert,
                    color: AppColors.textSecondary,
                  ),
                  color: AppColors.surface2,
                  onSelected: (v) {
                    if (v == 'refresh') _fetchCatalog();
                    if (v == 'check' && !_checking) _checkForUpdates();
                    if (v == 'update_all') _updateAll();
                    if (v == 'remove') _confirmRemove(context);
                  },
                  itemBuilder: (_) {
                    // Null manager (not DI-registered) reads as "no updates":
                    // "check" stays available, "update_all" stays hidden.
                    final mgr = _manager;
                    final pendingUpdates =
                        mgr?.updatesFor(widget.url) ?? const [];
                    return [
                      PopupMenuItem(
                        value: 'refresh',
                        child: Text(
                          context.l10n.refresh,
                          style: AppText.body.copyWith(
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'check',
                        enabled: !_checking,
                        child: Text(
                          _checking
                              ? context.l10n.checkingForUpdates
                              : context.l10n.checkForUpdates,
                          style: AppText.body.copyWith(
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      if (pendingUpdates.isNotEmpty)
                        PopupMenuItem(
                          value: 'update_all',
                          child: Text(
                            context.l10n.updateAllCount(pendingUpdates.length),
                            style: AppText.body.copyWith(
                              color: AppColors.accent,
                            ),
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
                    ];
                  },
                ),
              ],
            ),
          ),
          // ── Collapsible extension list (search forces it open) ───────────
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: !(_expanded || searching)
                ? const SizedBox(width: double.infinity)
                : _buildBody(),
          ),
        ],
      ),
    );
  }

  /// The fetched entries filtered by the live search query and the language
  /// picker (when registered — off in tests, so every entry shows there).
  List<AniyomiRepoEntry> get _filteredEntries {
    final enabled = _langPrefs == null
        ? null
        : (_langPrefs.enabled ?? defaultSourceLangs());
    return [
      for (final e in _entries ?? const <AniyomiRepoEntry>[])
        if (sourceSearchMatches(widget.query, e.name, e.lang) &&
            (enabled == null || sourceLangVisible(e.lang, enabled)))
          e,
    ];
  }

  Widget _buildBody() {
    if (_fetching) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.accent,
            ),
          ),
        ),
      );
    }
    if (_fetchError != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(
          context.l10n.failedToLoadError(_fetchError!),
          textAlign: TextAlign.center,
          style: AppText.caption.copyWith(color: AppColors.textSecondary),
        ),
      );
    }
    final entries = _filteredEntries;
    if (entries.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(
          context.l10n.noExtensionsFoundInThisRepo,
          textAlign: TextAlign.center,
          style: AppText.caption,
        ),
      );
    }
    // keiyoushi ships 1,300+ extensions in one repo, so an eager Column here
    // meant ~2,700 widgets built in a single frame. Capping the height gives
    // the ListView a real viewport, so only the visible rows get built; a repo
    // whose list is shorter than the cap still sizes to its content and looks
    // exactly like it did before.
    //
    // ponytail: a capped inner scroller rather than slivers — hoisting the rows
    // into the tab's scroll view would mean rewriting it as a CustomScrollView
    // and giving up the collapse animation. Worth doing if nested scrolling
    // with several large repos open turns out to annoy people.
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.7,
      ),
      child: ListView.builder(
        padding: EdgeInsets.zero,
        shrinkWrap: true,
        itemCount: entries.length,
        itemBuilder: (context, i) {
          final entry = entries[i];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Divider(
                height: 0.5,
                thickness: 0.5,
                color: AppColors.hairline,
              ),
              _MihonExtensionRow(
                entry: entry,
                installed: _isInstalled(entry.pkg),
                installFn: widget.installFn,
                uninstallFn: widget.uninstallFn,
                onInstalled: () =>
                    setState(() => _installedPkgs.add(entry.pkg)),
                onUninstalled: () =>
                    setState(() => _installedPkgs.remove(entry.pkg)),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// One extension row
// ---------------------------------------------------------------------------

class _MihonExtensionRow extends StatefulWidget {
  const _MihonExtensionRow({
    required this.entry,
    required this.installed,
    required this.onInstalled,
    required this.onUninstalled,
    this.installFn,
    this.uninstallFn,
  });

  final AniyomiRepoEntry entry;
  final bool installed;
  final VoidCallback onInstalled;
  final VoidCallback onUninstalled;
  final Future<void> Function(AniyomiRepoEntry entry)? installFn;
  final Future<void> Function(String pkg)? uninstallFn;

  @override
  State<_MihonExtensionRow> createState() => _MihonExtensionRowState();
}

class _MihonExtensionRowState extends State<_MihonExtensionRow> {
  bool _busy = false;

  /// Windows: an install download is running (shows the progress bar).
  bool _downloading = false;

  /// Windows: download fraction, null until the size is known (src-2 B).
  double? _progress;

  /// Windows: lets the progress bar's Cancel stop the download.
  CancelToken? _cancel;

  AniyomiRepoEntry get _entry => widget.entry;

  /// Live manager (null in widget tests that don't register it).
  MihonManager? get _manager => GetIt.instance.isRegistered<MihonManager>()
      ? GetIt.instance.get<MihonManager>()
      : null;

  /// A newer version of this installed extension, if one was found.
  MihonUpdate? get _update => _manager?.updateFor(_entry.pkg);

  /// The installed source of this package, for its settings (Windows menu).
  MihonProvider? get _installedSource {
    for (final p in _manager?.all ?? const <MihonProvider>[]) {
      if (p.pkg == _entry.pkg) return p;
    }
    return null;
  }

  /// Download progress from Dio, throttled to whole percents.
  void _onProgress(int received, int total) {
    if (!mounted) return;
    final next = installFraction(received, total);
    final prev = _progress;
    if (next != null && prev != null && (next - prev).abs() < .01 && next < 1) {
      return;
    }
    setState(() => _progress = next);
  }

  /// Windows row actions: one list for the '...' menu and right-click
  /// (src-6 B / src-13 B).
  List<DesktopMenuItem<Object?>> _menuItems() {
    final installed = widget.installed;
    final update = installed ? _update : null;
    final source = installed ? _installedSource : null;
    return desktopSourceMenuItems(
      context,
      onInstall: !installed && !_busy ? _install : null,
      onUpdate: update != null && !_busy ? _install : null,
      updateLabel: update == null
          ? null
          : context.l10n.updateArrowVersion(update.availableVersion),
      onSettings: source == null
          ? null
          : () => source_actions.openSourceSettings(
              context,
              source.sourceId,
              source.info.name,
            ),
      onUninstall: installed && !_busy ? _uninstall : null,
    );
  }

  String get _meta {
    final parts = <String>[
      if (_entry.lang.isNotEmpty) _entry.lang,
      if (_entry.version.isNotEmpty) 'v${_entry.version}',
    ];
    return parts.isEmpty ? 'mihon' : parts.join(' • ');
  }

  Future<void> _install() async {
    final messenger = ScaffoldMessenger.of(context);
    // Captured BEFORE the download, alongside the messenger and for the same
    // reason: the row can be gone by the time it finishes — the user leaves,
    // or the list rebuilds — and [State.context] is `_element!`, which throws
    // once it is. Reading `context.l10n` afterwards took out the catch block
    // too, so a failed install said nothing at all instead of saying why.
    // The messenger is the app-level one, so it still shows the snackbar.
    final l10n = context.l10n;
    // Windows shows the real reason, a progress bar and Cancel (src-2).
    final desktop = desktopPanelsEnabled;
    setState(() {
      _busy = true;
      _downloading = desktop;
      _progress = null;
      // Created up front so Cancel is live from the first frame.
      _cancel = desktop && widget.installFn == null ? CancelToken() : null;
    });
    try {
      if (widget.installFn != null) {
        await widget.installFn!(_entry);
      } else {
        final mgr = _manager;
        if (desktop) {
          final cancel = _cancel ??= CancelToken();
          // Throws an ExtensionInstallFailure with the reason on failure.
          await MihonExtensionService().installFromRepoOrThrow(
            _entry,
            manager: mgr,
            onProgress: _onProgress,
            cancelToken: cancel,
          );
          // An install from the menu's Update clears the pending update.
          mgr?.clearUpdatesForPkg(_entry.pkg);
        } else {
          final providers = await MihonExtensionService().installFromRepo(
            _entry,
            manager: mgr,
          );
          // installFromRepo never throws — it returns an empty list on failure.
          // Treat "no source loaded" as a failure so we don't mislabel context.l10n.installed.
          if (providers.isEmpty) {
            throw Exception(l10n.noSourceLoaded);
          }
        }
      }
      widget.onInstalled();
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(content: Text(l10n.installedName(_entry.name))),
        );
    } catch (e) {
      if (desktop) {
        // The readable reason plus 'Copy details' (src-2 A).
        final failure = ExtensionInstallFailure.from(e);
        showExtensionInstallFailure(
          messenger,
          message: failure.cancelled
              ? failure.reason
              : l10n.installFailed(failure.reason),
          failure: failure,
        );
      } else {
        messenger
          ..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text(l10n.installFailed('$e'))));
      }
    } finally {
      _cancel = null;
      if (mounted) {
        setState(() {
          _busy = false;
          _downloading = false;
        });
      }
    }
  }

  Future<void> _uninstall() async {
    final ok = await AppDialog.confirm(
      context,
      title: context.l10n.uninstallNameQuestion(_entry.name),
      message: context.l10n.thisRemovesTheExtensionFromYourInstalledSources,
      confirmLabel: context.l10n.uninstall,
      destructive: true,
    );
    if (ok != true) return;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    // Read before the await: the row may be gone when it returns.
    final l10n = context.l10n;
    setState(() => _busy = true);
    try {
      if (widget.uninstallFn != null) {
        await widget.uninstallFn!(_entry.pkg);
      } else {
        await _defaultUninstall();
      }
      widget.onUninstalled();
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(content: Text(l10n.uninstalledName(_entry.name))),
        );
    } catch (e) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(l10n.uninstallFailed('$e'))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _defaultUninstall() async {
    // Same helper as the source tile: box entry AND the APK. The APK is what
    // actually resurrects the source — `loadInstalled` re-reads the directory
    // on every cold start — so deleting only the box entry left the extension
    // to come back on the next launch.
    final failure = await MihonExtensionService.uninstall(_entry.pkg);
    // Remove from the manager so the source disappears from the picker.
    // Unlike AniyomiManager (whose store is Map<String, BaseProvider> and so
    // needs an `is AniyomiProvider` narrowing check), MihonManager._sources is
    // already typed Map<String, MihonProvider> — removeWhere's predicate
    // takes a MihonProvider directly, so no type check is needed here.
    if (GetIt.instance.isRegistered<MihonManager>()) {
      GetIt.instance.get<MihonManager>().removeWhere(
        (p) => p.pkg == _entry.pkg,
      );
    }
    if (failure != null) {
      // A locked APK can survive cleanup on Windows. Reporting success would
      // promise removal even though the next launch can load it again.
      throw StateError(failure);
    }
  }

  @override
  Widget build(BuildContext context) {
    final installed = widget.installed;
    final desktop = desktopPanelsEnabled;
    // Windows: hover highlight, a tooltip with the full name and the same
    // actions on right-click as in the '...' menu (src-13 B).
    return DesktopSourceRow(
      items: _menuItems,
      tooltip: '${_entry.name} · $_meta',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
        child: Row(
          children: [
            // The index names the icon, so a browse row can show the real logo
            // before anything is installed.
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 12),
              child: SourceIconTile(name: _entry.name, icon: _entry.iconUrl),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          _entry.name,
                          style: AppText.headline.copyWith(fontSize: 15),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (_entry.nsfw) ...[
                        const SizedBox(width: 8),
                        _NsfwBadge(),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(_meta, style: AppText.caption),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (desktop && _downloading)
              // Determinate bar + Cancel instead of the spinner (src-2 B).
              DesktopInstallProgress(
                value: _progress,
                onCancel: _cancel == null ? null : () => _cancel?.cancel(),
              )
            else if (_busy)
              SizedBox(
                width: 96,
                height: 36,
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.accent,
                    ),
                  ),
                ),
              )
            else if (installed && desktop)
              // A status, not a button: clicking 'Installed' no longer
              // uninstalls; the actions live in the '...' menu (src-6 B).
              DesktopInstalledActions(
                items: _menuItems,
                updateAvailable: _update != null,
              )
            else if (installed)
              OutlinedButton(
                onPressed: _uninstall,
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
                onPressed: _install,
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
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// NSFW badge (local copy; mirrors the one in aniyomi_repo_tab.dart /
// sources_screen.dart)
// ---------------------------------------------------------------------------

class _NsfwBadge extends StatelessWidget {
  const _NsfwBadge();

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

// ---------------------------------------------------------------------------
// Test seam: builds a bare _MihonRepoSection with an injected MihonManager
// so widget tests can drive checkRepoUpdates()/updatesFor() without touching
// sl<MihonManager>() or the network.
// ---------------------------------------------------------------------------

@visibleForTesting
Widget debugMihonRepoSection({
  required String url,
  required MihonManager manager,
  required Future<List<AniyomiRepoEntry>> Function(String url) fetchIndexFn,
  Future<void> Function(AniyomiRepoEntry entry)? installFn,
  bool Function(String pkg)? installedPkgsFn,
}) => _MihonRepoSection(
  url: url,
  onRemove: () {},
  fetchIndexFn: fetchIndexFn,
  installFn: installFn,
  installedPkgsFn: installedPkgsFn,
  managerOverride: manager,
);
