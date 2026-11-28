// Windows Sources manager: ONE two-pane page for every extension ecosystem.
//
// Replaces, on Windows only, the sidebar's Sources page (Streaming / Manga /
// Novel tabs), the Providers hub and the per-ecosystem screens as the main
// way in. Those screens still exist and stay reachable from '⋯ > Open
// <Ecosystem> manager…' / 'All ecosystems…', so nothing becomes unreachable.
//
// Left: search, Streaming / Manga / Novel chips (the default follows the top
// content pill until the user picks one) and the installed sources of that
// kind. Right: the selected source. Repositories are managed in Settings >
// Sources and '⋯ > All ecosystems…', not here.
//
// The page also lives in the shell's IndexedStack, where it is built while
// hidden: it never autofocuses, and the poster row waits until the page is
// actually on screen (TickerMode) before loading anything.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../core/app_mode.dart';
import '../../core/desktop/desktop_context_menu.dart';
import '../../core/desktop/extension_load_failures.dart';
import '../../core/desktop/extension_runtime.dart';
import '../../core/di/injector.dart';
import '../../core/lnreader/lnreader_extension_service.dart';
import '../../core/lnreader/lnreader_manager.dart';
import '../../core/mangayomi/mangayomi_manager.dart';
import '../../core/mihon/mihon_manager.dart';
import '../../core/mode/content_mode.dart';
import '../../core/mode/content_mode_cubit.dart';
import '../../core/playback/pinned_sources.dart';
import '../../core/playback/source_health_store.dart';
import '../../core/prefs/source_lang_prefs.dart';
import '../../core/provider/cloudstream_provider.dart';
import '../../core/provider/provider_manager.dart';
import '../../core/provider/provider_registry.dart';
import '../../core/provider/provider_repo_registry.dart';
import '../../core/state/active_source_cubit.dart';
import '../../core/stremio/stremio_manager.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../l10n/l10n.dart';
import '../home/search_screen.dart';
import 'desktop_add_repo_dialog.dart' show DesktopEngineMissingNotice;
import 'desktop_source_detail_pane.dart';
import 'desktop_sources_actions.dart';
import 'desktop_sources_list_pane.dart';
import 'desktop_sources_model.dart';
import 'sources_desktop_kit.dart' show DesktopProviderScope;
import 'sources_screen.dart';

/// Whether the Windows manager should replace the phone/TV sources pages
/// at an entry point: Windows, and not the TV layout.
bool get useDesktopSourcesManager =>
    defaultTargetPlatform == TargetPlatform.windows &&
    !(sl.isRegistered<AppMode>() && sl<AppMode>().isTv);

/// The two-pane Sources manager (Windows).
class DesktopSourcesManager extends StatefulWidget {
  const DesktopSourcesManager({
    super.key,
    this.showBack = false,
    this.initialSourceId,
  });

  /// Draw an app bar with Back (pushed from Settings or 'Manage source').
  /// False inside the shell's sidebar page.
  final bool showBack;

  /// Source to select first (from 'Manage source').
  final String? initialSourceId;

  /// The sidebar page's chip and selected row, kept outside the page State.
  /// The shell rebuilds its pages when the profile reloads (for example
  /// after the network comes back), which used to throw the user's Manga
  /// pick away and jump back to Streaming in the middle of a task.
  static DesktopSourceKind? _rememberedKind;
  static String? _rememberedPick;

  /// Forgets the remembered chip and row between tests.
  @visibleForTesting
  static void debugResetMemory() {
    _rememberedKind = null;
    _rememberedPick = null;
  }

  @override
  State<DesktopSourcesManager> createState() => _DesktopSourcesManagerState();
}

class _DesktopSourcesManagerState extends State<DesktopSourcesManager> {
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'desktop-sources-search');
  late final _listFocus = FocusNode(
    debugLabel: 'desktop-sources-list',
    onKeyEvent: _onListKey,
  );

  /// Attached to the selected row, to scroll it into view.
  final _selectedRowKey = GlobalKey(debugLabel: 'desktop-sources-selected');

  String _query = '';

  /// Selected chip: Streaming, Manga or Novel (there is no 'All').
  late DesktopSourceKind _kind = _kindForMode(_currentMode());

  /// True once the user tapped a chip. From then on the pick is kept for
  /// the page's life and the top content pill no longer moves it.
  bool _kindPicked = false;

  /// Follows the top content pill while the user has not picked a chip.
  StreamSubscription<ContentMode>? _modeSub;

  /// Only the sidebar page (no initial source, no Back) uses the memory;
  /// a page opened for one source shows that source's chip instead.
  bool get _usesMemory => !widget.showBack && widget.initialSourceId == null;

  /// What the user picked: `src:<id>`. The effective selection falls back
  /// to the first row when this is gone.
  String? _picked;

  /// The last build's rows, used by the keyboard handlers.
  List<DesktopSourceEntry> _visible = const [];
  String? _effective;

  /// Set once the page has been on screen (lazy first-time work).
  bool _activated = false;

  /// The top content pill's mode (Anime when the cubit is not registered,
  /// e.g. in tests).
  static ContentMode _currentMode() => sl.isRegistered<ContentModeCubit>()
      ? sl<ContentModeCubit>().state
      : ContentMode.anime;

  /// Chip for a content mode: Anime and Movie/TV (both ContentMode.anime)
  /// map to Streaming; Manga and Novel map to themselves.
  static DesktopSourceKind _kindForMode(ContentMode mode) => switch (mode) {
    ContentMode.anime => DesktopSourceKind.streaming,
    ContentMode.manga => DesktopSourceKind.manga,
    ContentMode.novel => DesktopSourceKind.novel,
  };

  @override
  void initState() {
    super.initState();
    final initial = widget.initialSourceId;
    if (initial != null && initial.isNotEmpty) {
      _picked = 'src:$initial';
      // 'Manage source' for, say, a manga source while the pill is on
      // Anime: open on that source's chip so it is actually listed, and
      // keep that chip (treat it as picked).
      final kind = collectDesktopSources().sources
          .where((s) => s.id == initial)
          .firstOrNull
          ?.kind;
      if (kind != null) {
        _kind = kind;
        _kindPicked = true;
      }
    } else if (_usesMemory && DesktopSourcesManager._rememberedKind != null) {
      // Rebuilt sidebar page: come back on the chip and row the user had.
      _kind = DesktopSourcesManager._rememberedKind!;
      _kindPicked = true;
      _picked = DesktopSourcesManager._rememberedPick;
    }
    // The page lives in the shell's IndexedStack, so it outlives pill
    // changes: keep the default chip in step with the pill until the user
    // picks a chip themselves.
    if (sl.isRegistered<ContentModeCubit>()) {
      _modeSub = sl<ContentModeCubit>().stream.listen((mode) {
        if (!mounted || _kindPicked) return;
        final next = _kindForMode(mode);
        if (next != _kind) setState(() => _kind = next);
      });
    }
    // Aniyomi / Mihon / LNReader keep repo URLs in boxes nobody may have
    // opened yet; open them so their repositories list.
    unawaited(
      DesktopSourceActions.openRepoBoxes().then((_) {
        if (mounted) setState(() {});
      }),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // First time the page is actually visible: read the novel repo lists so
    // LNReader update badges are known (what the Providers hub did on open).
    if (!_activated && TickerMode.valuesOf(context).enabled) {
      _activated = true;
      _checkNovelUpdates();
    }
  }

  @override
  void dispose() {
    unawaited(_modeSub?.cancel());
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _listFocus.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Data
  // -------------------------------------------------------------------------

  /// Everything whose change should redraw the lists.
  Listenable _listenables() => Listenable.merge([
    if (sl.isRegistered<CloudStreamManager>()) sl<CloudStreamManager>(),
    if (sl.isRegistered<AniyomiManager>()) sl<AniyomiManager>(),
    if (sl.isRegistered<MihonManager>()) sl<MihonManager>(),
    if (sl.isRegistered<MangayomiManager>()) sl<MangayomiManager>(),
    if (sl.isRegistered<StremioManager>()) sl<StremioManager>(),
    if (sl.isRegistered<LnReaderManager>()) sl<LnReaderManager>(),
    if (sl.isRegistered<SourceHealthStore>()) sl<SourceHealthStore>(),
    for (final box in [
      ProviderRegistry.boxName,
      ProviderReposRegistry.boxName,
      LnReaderExtensionService.boxName,
      ...desktopRepoBoxNames,
    ])
      ?desktopOpenBox(box)?.listenable(),
    ExtensionLoadFailures.failures,
    if (sl.isRegistered<AnimeLangPrefs>()) sl<AnimeLangPrefs>(),
    if (sl.isRegistered<MangaLangPrefs>()) sl<MangaLangPrefs>(),
    if (sl.isRegistered<MangayomiLangPrefs>()) sl<MangayomiLangPrefs>(),
    PinnedSources.notifier,
  ]);

  /// Fire-and-forget LNReader update check; failures only mean no badge.
  void _checkNovelUpdates() {
    if (!sl.isRegistered<LnReaderManager>()) return;
    unawaited(
      sl<LnReaderManager>().checkForUpdates().catchError((Object _) {}),
    );
  }

  /// F5: re-read the engine files, re-check novel updates, redraw.
  void _refresh() {
    DesktopExtensionRuntime.recheckAvailability();
    _checkNovelUpdates();
    unawaited(DesktopSourceActions.openRepoBoxes());
    setState(() {});
  }

  // -------------------------------------------------------------------------
  // Selection and keys
  // -------------------------------------------------------------------------

  /// Row keys in list order.
  List<String> get _rowKeys => [for (final s in _visible) 'src:${s.id}'];

  /// Moves the selection by [delta] rows and scrolls it into view.
  void _move(int delta) {
    final keys = _rowKeys;
    if (keys.isEmpty) return;
    final at = _effective == null ? -1 : keys.indexOf(_effective!);
    final next = (at + delta).clamp(0, keys.length - 1);
    _select(keys[next]);
  }

  void _select(String key) {
    setState(() => _picked = key);
    // Keep the row only together with a picked chip, so a rebuild restores
    // a row that is actually listed under that chip.
    if (_usesMemory && DesktopSourcesManager._rememberedKind != null) {
      DesktopSourcesManager._rememberedPick = key;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _selectedRowKey.currentContext;
      if (ctx != null && ctx.mounted) {
        unawaited(
          Scrollable.ensureVisible(
            ctx,
            duration: const Duration(milliseconds: 120),
            alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
          ),
        );
        unawaited(
          Scrollable.ensureVisible(
            ctx,
            duration: const Duration(milliseconds: 120),
            alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
          ),
        );
      }
    });
  }

  DesktopSourceEntry? get _selectedSource {
    final key = _effective;
    if (key == null || !key.startsWith('src:')) return null;
    final id = key.substring(4);
    return _visible.where((s) => s.id == id).firstOrNull;
  }

  /// Enter: browse the selected source.
  void _submit() {
    final s = _selectedSource;
    if (s != null) unawaited(DesktopSourceActions.browse(context, s));
  }

  /// Keys while the list itself has focus.
  KeyEventResult _onListKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      _move(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _move(-1);
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.home) {
      _move(-1 << 20);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.end) {
      _move(1 << 20);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _submit();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.delete) {
      final s = _selectedSource;
      if (s != null) unawaited(_removeSource(s));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Page-wide keys: Ctrl+F, F5 / Ctrl+R, Esc. Only seen while focus is
  /// inside the page, so the shell's own keys win everywhere else.
  KeyEventResult _onPageKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final hw = HardwareKeyboard.instance;
    final ctrl = hw.isControlPressed && !hw.isAltPressed;
    final key = event.logicalKey;
    if (ctrl && key == LogicalKeyboardKey.keyF) {
      _focusSearch();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f5 ||
        (ctrl && key == LogicalKeyboardKey.keyR)) {
      _refresh();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape && _searchCtrl.text.isNotEmpty) {
      _searchCtrl.clear();
      setState(() => _query = '');
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _focusSearch() {
    _searchFocus.requestFocus();
    _searchCtrl.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _searchCtrl.text.length,
    );
  }

  // -------------------------------------------------------------------------
  // Actions
  // -------------------------------------------------------------------------

  Future<void> _removeSource(DesktopSourceEntry s) async {
    final removed = await DesktopSourceActions.remove(context, s);
    if (removed && mounted) setState(() => _picked = null);
  }

  /// Opens Settings > Sources: the same screen Settings pushes (on Windows
  /// the Providers hub, where repositories are added and removed).
  Future<void> _manageInSettings() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const SourcesScreen()));
    // Repos or sources may have changed there; redraw on return.
    if (mounted) setState(() {});
  }

  /// The old app-bar search: titles across the chip's sources.
  void _contentSearch() {
    final mode = switch (_kind) {
      DesktopSourceKind.manga => ContentMode.manga,
      DesktopSourceKind.novel => ContentMode.novel,
      DesktopSourceKind.streaming => ContentMode.anime,
    };
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SearchScreen(forceSources: true, forceMode: mode),
        ),
      ),
    );
  }

  /// Opens settings from the context menu (checks first; the menu is
  /// built synchronously).
  Future<void> _settingsFromMenu(DesktopSourceEntry s) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (await DesktopSourceActions.hasSettings(s)) {
      if (mounted) await DesktopSourceActions.openSettings(context, s);
      return;
    }
    // The settings check awaited, so bail out if the manager went away.
    if (!mounted) return;
    messenger
      ?..clearSnackBars()
      // Translated "<source> has no settings" notice.
      ..showSnackBar(
        SnackBar(
          content: Text(context.l10n.desktopSourceHasNoSettings(s.name)),
        ),
      );
  }

  /// Right-click on a source: Browse, Settings, Pin to top, Update, Remove,
  /// then the overflow extras under 'More'.
  List<DesktopMenuItem<Object?>> _sourceMenu(DesktopSourceEntry s) {
    final l10n = context.l10n;
    final pinned = PinnedSources.isPinned(s.id);
    return [
      DesktopMenuItem<Object?>(
        label: s.browsable ? 'Browse' : 'Configure',
        icon: s.browsable ? Icons.play_arrow_rounded : Icons.tune_rounded,
        shortcut: s.browsable ? 'Enter' : null,
        onTap: () => unawaited(DesktopSourceActions.browse(context, s)),
      ),
      if (s.ecosystem != DesktopEcosystem.stremio &&
          s.ecosystem != DesktopEcosystem.lnreader)
        DesktopMenuItem<Object?>(
          label: l10n.sourceSettings,
          icon: Icons.settings_outlined,
          onTap: () => unawaited(_settingsFromMenu(s)),
        ),
      if (s.pinnable)
        DesktopMenuItem<Object?>(
          label: pinned ? l10n.unpinSource : 'Pin to top',
          icon: pinned ? Icons.push_pin : Icons.push_pin_outlined,
          onTap: () => unawaited(DesktopSourceActions.togglePin(s)),
        ),
      if (s.hasUpdate)
        DesktopMenuItem<Object?>(
          label: s.updateLabel == null
              ? l10n.update
              : '${l10n.update} (${s.updateLabel})',
          icon: Icons.system_update_alt_rounded,
          onTap: () => unawaited(DesktopSourceActions.update(context, s)),
        ),
      DesktopMenuItem<Object?>(
        label: l10n.remove,
        icon: Icons.delete_outline_rounded,
        destructive: true,
        shortcut: 'Del',
        onTap: () => unawaited(_removeSource(s)),
      ),
      const DesktopMenuItem<Object?>.divider(),
      DesktopMenuItem<Object?>(
        label: l10n.moreActions,
        icon: Icons.more_horiz_rounded,
        submenu: desktopSourceOverflowItems(context, s),
      ),
    ];
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final body = Focus(
      // Pass-through: never takes focus itself, sees keys from inside.
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onPageKey,
      child: ListenableBuilder(
        listenable: _listenables(),
        builder: (context, _) => sl.isRegistered<ActiveSourceCubit>()
            ? StreamBuilder<String>(
                stream: sl<ActiveSourceCubit>().stream,
                builder: (context, _) => _content(context),
              )
            : _content(context),
      ),
    );
    return DesktopProviderScope(
      child: Scaffold(
        backgroundColor: AppColors.bg,
        appBar: widget.showBack
            ? AppBar(
                backgroundColor: AppColors.bg,
                surfaceTintColor: Colors.transparent,
                title: Text(context.l10n.sources, style: AppText.headline),
              )
            : null,
        body: body,
      ),
    );
  }

  Widget _content(BuildContext context) {
    final snap = collectDesktopSources();
    final pinned = PinnedSources.notifier.value;
    _visible = filterDesktopSources(
      snap.sources,
      kind: _kind,
      query: _query,
      pinned: pinned,
    );
    final keys = _rowKeys;
    _effective = _picked != null && keys.contains(_picked)
        ? _picked
        : (keys.isEmpty ? null : keys.first);

    final engineMissing =
        defaultTargetPlatform == TargetPlatform.windows &&
        DesktopExtensionRuntime.engineMissing;
    final failures = ExtensionLoadFailures.failures.value.length;

    // Only a truly empty install (no sources at all; repositories are not
    // shown here, so they do not count) gets the empty state: when
    // extensions failed to load, the two-pane layout keeps the failures
    // banner (Details / Retry) reachable instead.
    if (snap.sources.isEmpty && failures == 0) {
      return _EmptyState(
        onManageInSettings: () => unawaited(_manageInSettings()),
        engineMissing: engineMissing,
      );
    }

    final source = _selectedSource;

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          desktopPinnedScope(
            pinned,
            DesktopSourcesListPane(
              searchController: _searchCtrl,
              searchFocus: _searchFocus,
              listFocus: _listFocus,
              onQueryChanged: (v) => setState(() => _query = v),
              kind: _kind,
              // A tapped chip sticks: the pill stops moving it from now on.
              onKindChanged: (k) => setState(() {
                _kind = k;
                _kindPicked = true;
                // Survives the page being rebuilt (see DesktopSourcesManager._rememberedKind).
                if (_usesMemory) DesktopSourcesManager._rememberedKind = k;
              }),
              sources: _visible,
              selectedKey: _effective,
              selectedRowKey: _selectedRowKey,
              onSelectSource: (s) => _select('src:${s.id}'),
              onBrowseSource: (s) =>
                  unawaited(DesktopSourceActions.browse(context, s)),
              sourceMenu: _sourceMenu,
              onManageInSettings: () => unawaited(_manageInSettings()),
              onContentSearch: _contentSearch,
              onMove: _move,
              onSubmit: _submit,
              showEngineMissing: engineMissing,
              loadFailures: failures,
              totalSources: snap.sources.length,
              caption: _caption(snap),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Container(
              key: const ValueKey('desktop-sources-detail'),
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.hairline),
              ),
              child: source != null
                  ? DesktopSourceDetailPane(
                      key: ValueKey('detail-${source.id}'),
                      entry: source,
                      onRemoved: () => setState(() => _picked = null),
                    )
                  : Center(
                      child: Text(
                        context.l10n.noMatchesFound,
                        style: AppText.caption,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  /// '12 sources · 2 updates · Active: X' under the list.
  String _caption(DesktopSourcesSnapshot snap) {
    final n = snap.sources.length;
    final u = snap.updateCount;
    String? active;
    if (sl.isRegistered<ActiveSourceCubit>()) {
      final id = sl<ActiveSourceCubit>().state;
      active = snap.sources.where((s) => s.id == id).firstOrNull?.name;
    }
    return [
      '$n source${n == 1 ? '' : 's'}',
      if (u > 0) '$u update${u == 1 ? '' : 's'}',
      if (active != null) 'Active: $active',
    ].join(' · ');
  }
}

/// Nothing installed yet. Points to Settings > Sources, where repositories
/// are added (this page no longer offers Add repository itself).
class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.onManageInSettings,
    required this.engineMissing,
  });

  /// Opens Settings > Sources.
  final VoidCallback onManageInSettings;
  final bool engineMissing;

  @override
  Widget build(BuildContext context) => Center(
    key: const ValueKey('desktop-sources-empty'),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 440),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: AppColors.surface2,
              borderRadius: BorderRadius.circular(18),
            ),
            child: const Icon(
              Icons.extension_outlined,
              size: 34,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 18),
          Text(
            context.l10n.noSourcesInstalled,
            textAlign: TextAlign.center,
            style: AppText.headline,
          ),
          const SizedBox(height: 8),
          // Translated hint and button label (English fallback in
          // app_en.arb).
          Text(
            context.l10n.desktopSourcesManagedInSettings,
            textAlign: TextAlign.center,
            style: AppText.caption,
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            key: const ValueKey('desktop-sources-manage-settings'),
            onPressed: onManageInSettings,
            icon: const Icon(Icons.settings_outlined, size: 18),
            label: Text(context.l10n.desktopManageSourcesInSettings),
          ),
          if (engineMissing) ...[
            const SizedBox(height: 18),
            const DesktopEngineMissingNotice(),
          ],
        ],
      ),
    ),
  );
}
