import '../../core/zmode/metadata_provider_prefs.dart';
import '../../core/lnreader/novel_cloudflare.dart';
import '../../core/error/exceptions.dart';
import 'dart:async';

import 'desktop_home_page.dart';
import 'desktop_continue_store.dart';
import 'desktop_source_catalogue_split.dart';
import '../../core/desktop/desktop_catalogue_switch.dart';
import '../../core/desktop/desktop_undo_toast.dart';
import '../../core/reading/read_store.dart';
import 'desktop_home_downloads.dart';
import '../../core/boot_network.dart';
import '../../core/download/chapter_download_store.dart';
import '../../core/download/download_manager.dart';
import '../downloads/desktop_download_library.dart';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../core/app_mode.dart';
import '../../core/aniyomi/aniyomi_image_provider.dart';
import '../../core/di/injector.dart';
import '../../core/stremio/stremio_poster_shape.dart';
import '../../core/stremio/stremio_ref.dart';
import '../../core/metadata/streaming_service.dart';
import '../../core/metadata/streaming_providers.dart';
import '../../core/ui/streaming_prefs.dart';
import '../../core/zmode/tmdb_catalogue.dart';
import '../../core/platform/apple_tv.dart';
import '../../core/mihon/mihon_extension_service.dart';
import '../../core/mihon/mihon_image_provider.dart';
import '../../core/mode/content_mode.dart';
import '../../core/ui/nav_prefs.dart';
import '../../core/mode/content_mode_cubit.dart';
import '../../core/models/watch_status.dart';
import '../../core/tracker/tracker_hub.dart';
import '../../core/notify/notification_service.dart';
import '../../core/ui/global_messenger.dart';
import '../../core/ui/artwork_quality.dart';
import '../../core/update/extension_auto_updater.dart';
import '../../core/provider/cloudstream_provider.dart';
import '../../core/provider/provider_manager.dart';
import '../../core/mangayomi/mangayomi_cloudflare.dart';
import '../../core/models/episode.dart';
import '../../core/models/home_row.dart';
import '../../core/models/home_section.dart';
import '../../core/models/media_detail.dart';
import '../../core/models/media_item.dart';
import '../../core/models/video_source.dart';
import '../../core/models/provider_info.dart';
import '../../core/playback/my_list.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/title_prefs.dart';
import '../../core/playback/watch_history.dart';
import '../../core/reading/read_history.dart';
import '../../core/repository/catalogue_repository.dart';
import '../../core/repository/source_repository.dart';
import '../../core/privacy/incognito_mode.dart';
import '../../core/state/active_source_cubit.dart';
import '../../core/tracker/tracker.dart';
import '../../core/tracker/tracker_item_url.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/zmode/zmode_prefs.dart';
import '../../l10n/l10n.dart';
import '../../core/announce/announcement.dart';
import '../announce/announcement_sheet.dart';
import '../community/community_sheet.dart';
import '../downloads/downloads_screen.dart';
import '../notify/subscriptions_screen.dart';
import '../reader/manga_reader_screen.dart';
import '../reader/novel_reader_screen.dart';
import '../settings/streaming_services_screen.dart';
import '../sources/aniyomi_repo_tab.dart' show kAniyomiReposBoxName;
import '../sources/providers_hub_screen.dart';
import '../sources/source_picker_row_actions.dart';
// Wraps the Providers hub in the desktop settings look on Windows (src-3).
import '../sources/sources_desktop_kit.dart' show DesktopProviderScope;
import '../sources/zangetsu_sources_screen.dart';
import '../update/update_dialog.dart';
import 'continue_section.dart';
import 'my_list_screen.dart';
import 'tracker_continue_section.dart';
import '../../core/ui/content_row.dart';
import '../../core/ui/banner_style.dart';
import '../../core/ui/featured_banner_edge.dart';
import '../../core/ui/featured_banner_panels.dart';
import '../../core/ui/featured_carousel.dart';
import '../../core/ui/featured_hero.dart';
import '../../core/theme/theme_controller.dart';
import '../../core/ui/poster_palette.dart';
import 'metadata_switch_sheet.dart';
import 'home_banner_header.dart';
import 'home_catalogue_prefs.dart';
import 'source_catalogue_home_content.dart';
import '../../core/ui/list_status_sheet.dart';
import '../../core/ui/media_info_sheet.dart';
import '../../core/ui/poster_card.dart';
import '../../core/ui/row_skeleton.dart';
import '../../core/ui/source_switcher.dart';
import '../../core/ui/states.dart';
import '../auth/auth_cubit.dart';
import '../auth/reconnect.dart';
import '../detail/detail_screen.dart';
import '../history/history_screen.dart';
import '../player/player_screen.dart';
import '../shell/dock_icons.dart';
import '../../core/zmode/source_matcher.dart';
import '../../core/zmode/metadata_repository.dart';
import '../../core/zmode/playback_resolver.dart';
import '../../core/zmode/zmode_ids.dart';
import 'streaming_services_row.dart';
import 'cubit/home_cubit.dart';
import 'cubit/home_rows_composer.dart';
import 'home_screen_tv.dart';
import 'genres_screen.dart';
import 'search_screen.dart';
import 'cubit/tracker_home_rows.dart' show releasedCount;
import 'see_all_screen.dart';
import '../downloads/resume_downloaded.dart';

/// Provides the [HomeCubit] (which owns the three browse rows + the carousel's
/// trending source) and kicks off the first load. The view itself stays
/// Stateful for the per-item lazy hero-description cache and the navigation
/// helpers.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, this.isTabActive = true});

  final bool isTabActive;

  @override
  Widget build(BuildContext context) {
    // Use the shared singleton so the splash can warm it before this mounts.
    return BlocProvider.value(
      value: sl<HomeCubit>(),
      child: _HomeView(isTabActive: isTabActive),
    );
  }
}

/// Launch-time checks: the GitHub update dialog, the one-time community
/// welcome and developer announcements, then the daily extension auto-update
/// (or the Android read-only source-update notification).
///
/// They run at most once per app process, from whichever host asks first.
/// Windows starts them from RootShell at launch, so a Start page other than
/// Home still gets them; phones start them when Home mounts (unchanged). The
/// static flag means Home mounting later never runs them a second time.
abstract final class AppLaunchChecks {
  static bool _started = false;

  /// Whether the checks have already been started this process.
  static bool get started => _started;

  /// Replaces the real checks in tests (no network, no dialogs).
  @visibleForTesting
  static void Function(State host)? debugRunOverride;

  /// Clears the once-per-process flag between tests.
  @visibleForTesting
  static void debugReset() {
    _started = false;
    debugRunOverride = null;
  }

  /// Starts the checks against [host] (its context shows the dialogs) unless
  /// they already started. Returns true when this call started them.
  static bool runOnce(State host) {
    if (_started || isAppleTv) return false;
    _started = true;
    final override = debugRunOverride;
    if (override != null) {
      override(host);
      return true;
    }
    // Silently check GitHub Releases; the dialog only appears if a newer,
    // non-skipped version exists. Best-effort — never blocks startup.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!host.mounted) return;
      await maybeShowUpdateDialog(host.context);
      // One-time community welcome (its own flag, independent of the per-id
      // announcement feed), then any new developer announcement — all awaited
      // in sequence so the modals never fight over the stack.
      if (host.mounted) await maybeShowCommunitySheet(host.context);
      if (host.mounted) await maybeShowAnnouncement(host.context);
    });
    unawaited(_checkSourceUpdates(host));
    return true;
  }

  /// Best-effort, non-blocking check for source updates on launch. The
  /// auto-update path applies updates (throttled to ~once a day); otherwise the
  /// READ-ONLY Android path re-fetches catalogs and posts a notification when
  /// updates exist and the user left that toggle on. Deferred a few seconds so
  /// it never competes with first content load, and fully guarded so it can
  /// NEVER affect startup or playback.
  static Future<void> _checkSourceUpdates(State host) async {
    final prefs = sl<PlaybackPrefs>();
    final autoUpdate = prefs.autoUpdateExtensions;
    // The read-only notify path below is Android-only; keep that gate unless
    // we're auto-updating (JS providers auto-update on any platform).
    if (!autoUpdate && !Platform.isAndroid) return;
    await Future<void>.delayed(const Duration(seconds: 4));
    if (!host.mounted) return;

    // Auto-update path: apply updates across all ecosystems, throttled to
    // ~once a day across launches. Best-effort — never touches startup.
    if (autoUpdate) {
      final now = DateTime.now().millisecondsSinceEpoch;
      const dayMs = 24 * 60 * 60 * 1000;
      if (now - prefs.lastExtensionUpdateMs < dayMs) return;
      await prefs.setLastExtensionUpdateMs(now);
      final updated = await ExtensionAutoUpdater.run();
      if (!host.mounted) return;
      await announceExtensionUpdates(host.context, updated);
      return;
    }

    try {
      final csManager = sl<CloudStreamManager>();
      final csCount = await csManager.checkAllUpdates();

      var aniCount = 0;
      try {
        final repoUrls = Hive.isBoxOpen(kAniyomiReposBoxName)
            ? Hive.box<String>(kAniyomiReposBoxName).values.toList()
            : const <String>[];
        if (repoUrls.isNotEmpty) {
          aniCount = await sl<AniyomiManager>().checkAllUpdates(repoUrls);
        }
      } catch (_) {
        /* aniyomi check must never break the CS check or startup */
      }

      final total = csCount + aniCount;
      if (total > 0 && csManager.notifyUpdates) {
        await NotificationService.instance.showSourceUpdates(count: total);
      }
    } catch (_) {
      /* never affects startup */
    }
  }

  /// Tells the user how many extensions the daily auto-update refreshed.
  ///
  /// Phones post a system notification. The Windows build has no notification
  /// backend for this, so it shows an in-app floating toast instead.
  @visibleForTesting
  static Future<void> announceExtensionUpdates(
    BuildContext context,
    int updated,
  ) async {
    if (updated <= 0) return;
    final body =
        '$updated extension${updated == 1 ? '' : 's'} updated to the latest version.';
    if (defaultTargetPlatform == TargetPlatform.windows) {
      final messenger =
          ScaffoldMessenger.maybeOf(context) ?? rootMessengerKey.currentState;
      messenger?.showSnackBar(
        SnackBar(
          key: const ValueKey('extensions-updated-toast'),
          content: Text(body),
          behavior: SnackBarBehavior.floating,
          width: 440,
          duration: const Duration(seconds: 4),
        ),
      );
      return;
    }
    await NotificationService.instance.showMessage(
      id: 779100,
      title: context.l10n.extensionsUpdated,
      body: body,
    );
  }
}

class _HomeView extends StatefulWidget {
  const _HomeView({required this.isTabActive});

  final bool isTabActive;

  @override
  State<_HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<_HomeView>
    with SingleTickerProviderStateMixin {
  /// Selects the Windows featured/header presentation and desktop interactions.
  // Presentation follows Flutter's platform so phone/desktop widget tests can
  // select their target without changing native engine platform detection.
  bool get _isDesktop => defaultTargetPlatform == TargetPlatform.windows;
  final _repo = sl<CatalogueRepository>();
  final _myList = sl<MyListStore>();
  final _sourceCatalogueController = SourceCatalogueHomeController();
  StreamSubscription<ContentMode>? _sourceCatalogueModeSubscription;
  late final ValueNotifier<bool> _sourceCatalogueSelection;
  // Per-mode pick, loaded in initState (needs the cubit) and reloaded on
  // every mode switch — a single shared id is what made manga forget anime.
  String? _sourceCatalogueSourceId;
  List<HomeSection> _sourceCatalogueSections = const [];
  bool _sourceCatalogueSelected = HomeCataloguePrefs.catalogueShown;

  /// Windows Home Continue lists (home-10): only notifies when entries are
  /// added, removed or reordered, never on a plain position save. Created on
  /// first use by the desktop Home and disposed with this state.
  DesktopContinueStore? _continueStore;
  DesktopContinueStore get _continue =>
      _continueStore ??= DesktopContinueStore.fromHistory(
        watch: sl.isRegistered<WatchHistory>() ? sl<WatchHistory>() : null,
        read: sl.isRegistered<ReadHistory>() ? sl<ReadHistory>() : null,
      );

  /// Windows (home-11 B): the last rows a source catalogue loaded, kept on
  /// screen while a refresh of the same source is in flight.
  ({String key, List<HomeSection> sections})? _lastDesktopSourceRows;

  /// Windows (home-6): ids + labels last published to the shell's catalogue
  /// switch, so it is only republished when the choices really change.
  String? _publishedCatalogueSignature;

  /// Hero metadata cache: key = "sourceId:id". Futures are stored so they're
  /// never re-fetched on carousel rotation; pre-warmed when hero items load.
  final Map<String, Future<HeroMeta?>> _metaCache = {};
  bool _heroPrewarmed = false;
  bool _resumePrewarmed = false;
  bool _openingSourceCatalogueItem = false;

  /// Poster-tinted background colour for the hero-driven adaptive wash
  /// (null → normal theme background). Fed by [FeaturedHero.onArtColor].
  final ValueNotifier<Color?> _heroTint = ValueNotifier(null);

  // ── Logo-strike mode transition ──────────────────────────────────────────
  // Tapping a mode card runs a full-screen overlay: the Zangetsu mark springs
  // in at centre behind a scrim, a red glow pulses and a steel glint sweeps the
  // blade, the mode swaps hidden at that peak, then it reveals. Self-contained —
  // see [_enterMode] / [_slashOverlay].
  late final AnimationController _slashCtrl;
  bool _slashing = false;
  bool _slashSwapped = false;
  ContentMode? _slashTarget;

  @override
  void initState() {
    super.initState();
    _sourceCatalogueSelection = HomeCataloguePrefs.sourceSelection;
    _sourceCatalogueSelection.addListener(_onSourceCatalogueSelectionChanged);
    HomeCataloguePrefs.revision.addListener(_onCatalogueRevision);
    _sourceCatalogueSourceId = HomeCataloguePrefs.sourceIdFor(
      sl<ContentModeCubit>().state,
    );
    _sourceCatalogueModeSubscription = sl<ContentModeCubit>().stream.listen((
      mode,
    ) {
      if (!mounted) return;
      if (_sourceCatalogueSelected) {
        // Reload THIS mode's saved source: the content widget resolves its
        // fallback from the id we hand it, so handing it the other mode's id
        // would persist a fallback over this mode's real pick.
        setState(() {
          _sourceCatalogueSourceId = HomeCataloguePrefs.sourceIdFor(mode);
          _sourceCatalogueSections = const [];
        });
      }
    });
    ThemeController.revision.addListener(_onThemeRevision);
    // Swap the content mode at the slash's peak (hidden behind the scrim), then
    // tear the overlay down once it finishes.
    _slashCtrl =
        AnimationController(
            vsync: this,
            duration: const Duration(milliseconds: 600),
          )
          ..addListener(() {
            if (!_slashSwapped &&
                _slashTarget != null &&
                _slashCtrl.value >= 0.5) {
              _slashSwapped = true;
              sl<ContentModeCubit>().setMode(_slashTarget!);
            }
          })
          ..addStatusListener((status) {
            if (status == AnimationStatus.completed && mounted) {
              setState(() {
                _slashing = false;
                _slashTarget = null;
              });
            }
          });
    // The splash usually pre-warms the rows; only fetch here if it didn't
    // (e.g. first run right after onboarding, or a source with no warm yet).
    // tvOS: provider JS loads AFTER the splash (runDeferredAppleTvBootTasks).
    // load() here races that step and wedges QuickJS on the first RootShell
    // frame — looks stuck on the splash after a cloud restore (onboarded=true
    // pushes Home immediately; fresh installs see Onboarding first and miss it).
    if (!isAppleTv) {
      final cubit = context.read<HomeCubit>();
      if (cubit.state.sections == null && !cubit.state.loading) cubit.load();
    }
    // Launch checks (update dialog, welcome sheets, extension updates). On
    // Windows RootShell already started them at launch, whatever the Start
    // page, so this is a no-op there; phones keep running them from Home.
    AppLaunchChecks.runOnce(this);
  }

  @override
  void dispose() {
    _sourceCatalogueModeSubscription?.cancel();
    _sourceCatalogueSelection.removeListener(
      _onSourceCatalogueSelectionChanged,
    );
    HomeCataloguePrefs.revision.removeListener(_onCatalogueRevision);
    _slashCtrl.dispose();
    ThemeController.revision.removeListener(_onThemeRevision);
    _heroTint.dispose();
    _continueStore?.dispose();
    // Home owns the shell's catalogue switch content; drop it with Home.
    // Deferred to after the frame: clearing now would rebuild the shell's
    // switcher while this tree is being torn down. Skipped if a new Home
    // published its own options in the meantime.
    if (_publishedCatalogueSignature != null) {
      final published = DesktopCatalogueSwitch.options.value;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (identical(DesktopCatalogueSwitch.options.value, published)) {
          DesktopCatalogueSwitch.clear();
        }
      });
      WidgetsBinding.instance.scheduleFrame();
    }
    super.dispose();
  }

  void _onThemeRevision() {
    if (mounted) setState(() {});
  }

  void _onSourceCatalogueSelectionChanged() {
    _refreshCatalogueSelection();
  }

  void _onCatalogueRevision() {
    _refreshCatalogueSelection();
  }

  void _refreshCatalogueSelection() {
    if (!mounted) return;
    final selected = HomeCataloguePrefs.catalogueShown;
    final sourceId = HomeCataloguePrefs.sourceIdFor(
      sl<ContentModeCubit>().state,
    );
    if (selected == _sourceCatalogueSelected &&
        sourceId == _sourceCatalogueSourceId) {
      return;
    }
    setState(() {
      _sourceCatalogueSelected = selected;
      _sourceCatalogueSourceId = sourceId;
      _sourceCatalogueSections = const [];
      if (selected && sourceId == null) {
        _sourceCatalogueSourceId = sl<ActiveSourceCubit>().state;
      }
    });
  }

  Future<void> _openHomeCataloguePicker() async {
    final selection = await showMetadataSwitchSheet(
      context,
      sourceCatalogueSelected: HomeCataloguePrefs.sourceSelected,
      stremioCatalogueSelected: HomeCataloguePrefs.stremioSelected,
    );
    if (!mounted || selection == null) return;
    final mode = sl<ContentModeCubit>().state;
    final kind = switch (selection) {
      HomeCatalogueSelection.metadata => HomeCatalogueKind.metadata,
      HomeCatalogueSelection.source => HomeCatalogueKind.source,
      HomeCatalogueSelection.stremio => HomeCatalogueKind.stremio,
    };
    if (kind == HomeCataloguePrefs.catalogueKind) return;
    await HomeCataloguePrefs.setCatalogue(mode, kind);
  }

  void _selectHomeCatalogueSource(String sourceId) {
    if (sourceId == _sourceCatalogueSourceId) return;
    setState(() {
      _sourceCatalogueSourceId = sourceId;
      _sourceCatalogueSections = const [];
    });
    unawaited(
      HomeCataloguePrefs.setSourceIdFor(sl<ContentModeCubit>().state, sourceId),
    );
  }

  void _setSourceCatalogueSections(List<HomeSection> sections) {
    if (!mounted || !_sourceCatalogueSelected) return;
    setState(() => _sourceCatalogueSections = sections);
  }

  List<MediaItem> get _sourceCatalogueHeroItems {
    final sections = _sourceCatalogueSections;
    if (sections.isEmpty) return const [];
    if (_sourceCatalogueSourceId == 'stremio') {
      return stremioHeroItems(sections);
    }
    for (final section in sections) {
      if (section.title.startsWith('Trending')) return section.items;
    }
    return sections.first.items;
  }

  /// Genres + episode count for the hero banner (lazily fetched, cached).
  ///
  /// Settles on the FIRST of two answers: the partial a metadata title hands
  /// over once its catalogue has replied, or the finished detail. A metadata
  /// title's `detail()` also pairs the title with an installed source before
  /// it returns, and that pairing searches every installed source in turn —
  /// one report spent 18 seconds on a title no source carried, with the
  /// banner's caption blank the whole time and the carousel rotating on. The
  /// caption is genres, a count and a year; the catalogue supplies all three
  /// up front, and the source is only needed for episode *urls*, which the
  /// banner never reads. Once that partial result arrives, the unused source
  /// match is abandoned so Home cannot keep provider work running underneath
  /// a detail screen.
  ///
  /// A source-backed title never calls `onPartial` — it has nothing to search
  /// for — and completes on the second branch exactly as it always did.
  Future<HeroMeta?> _heroMeta(MediaItem m) =>
      _metaCache.putIfAbsent('${m.sourceId}:${m.id}', () async {
        final first = Completer<MediaDetail?>();
        void settle(MediaDetail? d) {
          if (!first.isCompleted) first.complete(d);
        }

        // _detailOf swallows its errors, so this always settles.
        unawaited(
          _detailOf(
            m.url,
            m.sourceId,
            onPartial: settle,
            abandoned: () => first.isCompleted,
          ).then(settle),
        );
        final d = await first.future;
        if (d == null) return null;
        return HeroMeta(
          genres: d.genres,
          description: d.description,
          episodeCount: d.episodes.length,
          year: d.year,
        );
      });

  /// Warm ONLY the first hero's metadata (the slide shown first). The rest load
  /// lazily, one at a time, as the carousel rotates — each via the hero's own
  /// `FutureBuilder` on [_heroMeta] (cached). Firing ALL of them up front fired
  /// one `detail()` per hero AT ONCE; for a heavy CloudStream source (e.g.
  /// MovieBox) those N concurrent `load()`s saturated the read pool and froze
  /// the UI thread → ANR. One-at-a-time on rotation is fine even for MovieBox.
  /// Resolve the stream for the top Continue Watching row before it is tapped.
  ///
  /// It is the most-tapped thing on Home, and the caches that make a resolve
  /// instant live in memory only — so the first play after opening the app
  /// always paid full price (7.3s median across 139 plays on 2.2.0, 20s at
  /// p90). The episode url is already on the history row, so this costs one
  /// resolve and no source search.
  ///
  /// Only the first row: warming the whole rail would fire a resolve per show
  /// for shows nobody asked for. Fire-and-forget, after the frame, so it never
  /// competes with Home rendering — and a failure just means Play does the
  /// work itself, as before.
  void _prewarmResume() {
    if (_resumePrewarmed) return;
    _resumePrewarmed = true;
    final rows = sl<WatchHistory>().all();
    if (rows.isEmpty) return;
    final e = rows.first;
    if (e.episodeUrl.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ProviderManager.inBackground(() {
        // Z Mode's source id is only a catalogue pseudo-id. Use the actual
        // source remembered for this title and stop there: a speculative
        // startup warm must never turn into an Auto Resolve sweep.
        if (e.sourceId == ZmodeIds.sourceId) {
          if (!sl.isRegistered<PlaybackResolver>()) {
            return Future.value(<VideoSource>[]);
          }
          return sl<PlaybackResolver>().prewarmRememberedSource(e.episodeUrl);
        }
        return _repo.sources(e.episodeUrl, sourceId: e.sourceId, fast: true);
      }).catchError((_) => <VideoSource>[]);
    });
  }

  void _prewarmHeroMeta(List<MediaItem> items) {
    if (_heroPrewarmed || items.isEmpty) return;
    _heroPrewarmed = true;
    _prewarmResume();
    _heroMeta(items.first);
  }

  void _openDetail(MediaItem item) {
    // Only rebuild Home if this visit actually changed My List — Continue
    // Watching/Reading rows already listen to their Hive boxes, so a blanket
    // setState made every back-press rebuild the whole page for nothing.
    final listRev = _myList.revision.value;
    Navigator.push(context, DetailScreen.route(item)).then((_) {
      if (mounted && _myList.revision.value != listRev) setState(() {});
    });
  }

  Future<void> _withSourceCatalogueItem(
    MediaItem item,
    FutureOr<void> Function(MediaItem) action,
  ) async {
    if (_openingSourceCatalogueItem) return;
    _openingSourceCatalogueItem = true;
    try {
      final target = await sourceCatalogueTargetFor(item);
      if (mounted) await action(target);
    } finally {
      _openingSourceCatalogueItem = false;
    }
  }

  void _openSourceCatalogueDetail(MediaItem item) {
    unawaited(_withSourceCatalogueItem(item, _openDetail));
  }

  void _showSourceCatalogueInfo(MediaItem item) {
    unawaited(_withSourceCatalogueItem(item, _showInfo));
  }

  String _typeLabel(ProviderType t) =>
      t == ProviderType.movie ? 'Movie' : 'Anime';

  Future<MediaDetail?> _detailOf(
    String url,
    String sourceId, {
    void Function(MediaDetail partial)? onPartial,
    bool Function()? abandoned,
  }) async {
    try {
      return await _repo.detail(
        url,
        sourceId: sourceId,
        onPartial: onPartial,
        abandoned: abandoned,
      );
    } catch (_) {
      return null;
    }
  }

  /// Netflix-style long-press info card for a browse-row item.
  void _showInfo(MediaItem item) {
    showMediaInfoSheet(
      context,
      title: item.title,
      englishTitle: item.englishTitle,
      cover: item.cover,
      headers: item.coverHeaders,
      typeLabel: _typeLabel(item.type),
      subCount: item.subCount,
      dubCount: item.dubCount,
      detail: _detailOf(item.url, item.sourceId),
      inMyList: _myList.contains(item),
      onPlay: () => _playFeatured(item),
      onOpenDetail: () => _openDetail(item),
      onToggleMyList: () async {
        await showListStatusSheet(
          context,
          item: item,
          onChanged: () {
            if (mounted) setState(() {});
          },
        );
        return _myList.contains(item);
      },
    );
  }

  /// Long-press info card for a Continue Watching item — adds Resume + Remove.
  void _showContinueInfo(HistoryEntry e) {
    final stub = MediaItem(
      id: e.showId,
      title: e.showTitle,
      cover: e.cover,
      coverHeaders: e.coverHeaders,
      url: e.showUrl,
      type: ProviderType.anime,
      sourceId: e.sourceId,
    );
    final pct = (e.progress * 100).round();
    showMediaInfoSheet(
      context,
      title: e.showTitle,
      cover: e.cover,
      headers: e.coverHeaders,
      detail: _detailOf(e.showUrl, e.sourceId),
      inMyList: _myList.contains(stub),
      playLabel: 'Resume',
      progress: e.progress,
      progressLabel: e.episodeNumber != null
          ? 'Episode ${e.episodeNumber!.toInt()} · $pct% watched'
          : '$pct% watched',
      onPlay: () => _resume(e),
      onOpenDetail: () => _openDetail(stub),
      onToggleMyList: () async {
        await showListStatusSheet(
          context,
          item: stub,
          onChanged: () {
            if (mounted) setState(() {});
          },
        );
        return _myList.contains(stub);
      },
      onRemoveFromContinue: () async {
        // Tapping Remove and having the row stay put with no explanation is
        // the worst version of this: it reads as the button being broken.
        try {
          await sl<WatchHistory>().remove(e.sourceId, e.showId);
        } catch (_) {
          showGlobalSnack("Couldn't remove from Continue Watching");
          return;
        }
        if (mounted) setState(() {});
      },
    );
  }

  /// Long-press info card for a Continue Reading item — the manga/novel twin of
  /// [_showContinueInfo]: Read + Remove + My List, backed by [ReadHistory].
  void _showContinueReadingInfo(ReadEntry e) {
    final showUrl = e.detailUrl;
    final stub = MediaItem(
      id: e.showId,
      title: e.title,
      cover: e.cover,
      url: showUrl,
      type: e.type,
      sourceId: e.sourceId,
    );
    final pct = e.total > 0 ? ((e.pos / e.total) * 100).round() : 0;
    final progress = e.total > 0 ? (e.pos / e.total).clamp(0.0, 1.0) : 0.0;
    showMediaInfoSheet(
      context,
      title: e.title,
      cover: e.cover,
      detail: _detailOf(showUrl, e.sourceId),
      inMyList: _myList.contains(stub),
      playLabel: 'Read',
      progress: progress,
      progressLabel: e.chapterNumber != null
          ? 'Chapter ${e.chapterNumber!.toInt()} · $pct% read'
          : '$pct% read',
      onPlay: () => _resumeReading(e),
      onOpenDetail: () => _openDetail(stub),
      onToggleMyList: () async {
        await showListStatusSheet(
          context,
          item: stub,
          onChanged: () {
            if (mounted) setState(() {});
          },
        );
        return _myList.contains(stub);
      },
      onRemoveFromContinue: () async {
        // Tapping Remove and having the row stay put with no explanation is
        // the worst version of this: it reads as the button being broken.
        try {
          await sl<ReadHistory>().remove(e.sourceId, e.showId);
        } catch (_) {
          showGlobalSnack("Couldn't remove from Continue Reading");
          return;
        }
        if (mounted) setState(() {});
      },
    );
  }

  Future<void> _playFeatured(MediaItem item) async {
    // Manga/novel: the hero's primary action says "Read", so it must not drop
    // into the video player. Route to the title instead — Detail owns the real
    // Read button, which resolves the chapter list, picks up the saved reading
    // position and routes manga vs novel to the right reader. Duplicating that
    // here would mean re-implementing chapter resolution on Home.
    if (sl<ContentModeCubit>().state.isReading) {
      _openDetail(item);
      return;
    }
    // A metadata title only plays once a source has been paired with it. If
    // that pairing isn't known yet, go to Detail rather than into the player:
    // Detail resolves it, and when nothing matches it says so (dimmed Play,
    // "No episodes available from this source", Wrong title?). Pushing the
    // player instead just spins and fails, and that got more likely once one
    // declared source replaced the search-every-source sweep.
    //
    // `saved` is a synchronous store read, so a title you have opened before
    // still plays instantly — only the unknown ones take the detour.
    if (ZmodeIds.isZ(item.url)) {
      final c = ZmodeIds.parseShow(item.url);
      if (c == null || sl<SourceMatcher>().saved(c) == null) {
        _openDetail(item);
        return;
      }
    }
    // Fresh play: prefer a saved per-title sub/dub choice, else the global
    // default category, else 'sub'.
    final category =
        sl<TitlePrefsStore>().category(item.sourceId, item.url) ??
        sl<PlaybackPrefs>().defaultCategory;
    // Instant nav — the player resolves the episode list behind its loader.
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          sourceId: item.sourceId,
          episodesResolver: () =>
              _repo.episodes(item.url, sourceId: item.sourceId),
          resume: sl<ResumeStore>(),
          resolveSources: (u) =>
              _repo.sources(u, sourceId: item.sourceId, fast: true),
          history: sl<WatchHistory>(),
          showTitle: item.title,
          cover: item.cover,
          coverHeaders: item.coverHeaders,
          showUrl: item.url,
          downloadShowId: item.id,
          category: category,
          malId: item.malId,
          scrobbleTitle: item.type == ProviderType.anime ? item.title : null,
          tmdbId: item.tmdbId,
          tmdbIsTv: item.tmdbIsTv,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  /// Resume from Continue Watching. Navigates to the player INSTANTLY; the
  /// player resolves the episode list behind its own branded loader (no blocking
  /// pre-navigation spinner).
  Future<void> _resume(HistoryEntry e) async {
    // A downloaded episode resumes from the saved file (works offline).
    final local = await resumeFromDownload(
      context,
      e,
      onlineEpisodes: () => _repo.episodes(
        e.showUrl,
        category: e.category,
        sourceId: e.sourceId,
      ),
      onlineSources: (u) => _repo.sources(u, sourceId: e.sourceId, fast: true),
    );
    if (!mounted) return;
    if (!local) {
      await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          sourceId: e.sourceId,
          episodesResolver: () => _repo.episodes(
            e.showUrl,
            category: e.category,
            sourceId: e.sourceId,
          ),
          resumeEpisodeId: e.episodeId,
          resumeEpisodeNumber: e.episodeNumber,
          resumePosition: e.position,
          resume: sl<ResumeStore>(),
          resolveSources: (u) =>
              _repo.sources(u, sourceId: e.sourceId, fast: true),
          history: sl<WatchHistory>(),
          showTitle: e.showTitle,
          cover: e.cover,
          coverHeaders: e.coverHeaders,
          showUrl: e.showUrl,
          category: e.category,
          malId: e.malId,
          scrobbleTitle: e.malId != null ? e.showTitle : null,
        ),
      ),
    );
    }
    if (mounted) setState(() {});
  }

  /// Resume from Continue Reading. [ReadEntry] only carries the last-read
  /// CHAPTER's own url (not the show's page url — unlike [HistoryEntry],
  /// which has both), so this can't re-resolve the show's full chapter list
  /// up front the way [_resume] does for video. It reopens exactly that one
  /// chapter at its saved scroll position (restored by the reader itself via
  /// ReadStore) and passes `resolveChapters: true` — the reader fetches the
  /// full list itself in the background and lights up prev/next once it
  /// lands, without touching the chapter already on screen.
  ///
  /// Routes to [MangaReaderScreen] or [NovelReaderScreen] by [ReadEntry.type]
  /// — see [readerFor]. [ReadEntry] has no malId of its own (it's populated
  /// from the tapped MediaItem/detail at read-start, same as WatchHistory's
  /// scrobbleTitle path), so a resumed session still can't scrobble; that's
  /// an existing gap, not something this resume path can close on its own.
  Future<void> _resumeReading(ReadEntry e) async {
    final chapter = Episode(
      id: e.chapterId,
      title: e.chapterNumber != null
          ? 'Chapter ${e.chapterNumber!.toInt()}'
          : 'Chapter',
      number: e.chapterNumber,
      url: e.chapterUrl,
    );
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => readerFor(e, chapter)),
    );
    if (mounted) setState(() {});
  }

  /// Row entrance is now handled per-item by [RevealItem] (the cascade
  /// cascade). This wrapper used to fade the whole row in, which MASKED that
  /// cascade — so it's now a passthrough, kept only so its call sites are
  /// untouched. Returns [child] unchanged.
  Widget _animated(Widget child) => child;

  /// Floating brand header — always positioned on top of the hero or bg.
  Widget _buildHeader({bool edgeBanner = false}) {
    Widget sourceSwitcher() {
      if (HomeCataloguePrefs.stremioSelected) return const SizedBox.shrink();
      if (!_sourceCatalogueSelected) return const HomeSourceSwitcherSlot();
      final sourceId = _sourceCatalogueSourceId;
      if (sourceId == null) return const SizedBox.shrink();
      return SourceSwitcher(
        currentId: sourceId,
        onChanged: _selectHomeCatalogueSource,
        trailingBuilder: (id) => SourcePickerRowActions(
          sourceId: id,
          onCloudflareSolved: (solvedId) async {
            if (!mounted || solvedId != _sourceCatalogueSourceId) return;
            await _sourceCatalogueController.refresh();
          },
        ),
      );
    }

    return SafeArea(
      bottom: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // A narrow desktop window also needs the second source row; its
          // wider wordmark cannot share 320px with all header controls.
          final splitEdgeHeader =
              constraints.maxWidth < 520 && (edgeBanner || _isDesktop);
          final brand = edgeBanner
              ? IconButton(
                  tooltip: 'Zangetsu',
                  onPressed: () => _openHomeCataloguePicker(),
                  icon: Image.asset(
                    'assets/icon/logo_mark.png',
                    width: 36,
                    height: 36,
                    fit: BoxFit.contain,
                  ),
                )
              : GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _openHomeCataloguePicker(),
                  child: Padding(
                    // Only the padding is new: 22px of artwork is under the
                    // 48px minimum tap target, and vertical padding alone
                    // cannot shift a left-aligned image.
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: _isDesktop
                        ? const Text(
                            'Discover',
                            style: TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.w700,
                            ),
                          )
                        : Image.asset(
                            'assets/icon/wordmark.png',
                            height: 22,
                            fit: BoxFit.contain,
                          ),
                  ),
                );
          final actions = [
            HomeDownloadsAction(edgeBanner: edgeBanner),
            _notificationBell(context, edgeBanner: edgeBanner),
            HomeSearchAction(
              edgeBanner: edgeBanner,
              fixedSourceId: _sourceCatalogueSelected
                  ? _sourceCatalogueSourceId
                  : null,
            ),
          ];

          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: splitEdgeHeader
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: brand,
                            ),
                          ),
                          ...actions,
                        ],
                      ),
                      ValueListenableBuilder<int>(
                        valueListenable: ZModePrefs.revision,
                        builder: (context, _, _) {
                          final showSource =
                              !HomeCataloguePrefs.stremioSelected &&
                              (_sourceCatalogueSelected || !ZModePrefs.enabled);
                          return ValueListenableBuilder<bool>(
                            valueListenable: IncognitoMode.notifier,
                            builder: (context, incognito, _) {
                              if (!showSource && !incognito) {
                                return const SizedBox.shrink();
                              }
                              return Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Wrap(
                                  alignment: WrapAlignment.end,
                                  spacing: 4,
                                  runSpacing: 4,
                                  children: [
                                    if (incognito) const _IncognitoChip(),
                                    if (showSource) sourceSwitcher(),
                                  ],
                                ),
                              );
                            },
                          );
                        },
                      ),
                    ],
                  )
                : Row(
                    children: [
                      Expanded(
                        child: Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: brand,
                        ),
                      ),
                      const _IncognitoChip(),
                      ...actions,
                      sourceSwitcher(),
                    ],
                  ),
          );
        },
      ),
    );
  }

  /// Clears the adaptive tint after the current frame — [bannerBuilder] runs
  /// during build, so the notifier must not be written synchronously there.
  void _clearHeroTintSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _heroTint.value = null;
    });
  }

  /// The banner for [bannerId], with the same items and the same callbacks
  /// whichever one is showing.
  Widget _featuredBanner(String bannerId, List<MediaItem> heroItems) {
    final reading = sl<ContentModeCubit>().state.isReading;
    void toggleList(MediaItem m) {
      Future<void> showSheet(MediaItem target) => showListStatusSheet(
        context,
        item: target,
        onChanged: () {
          if (mounted) setState(() {});
        },
      );
      if (_sourceCatalogueSelected) {
        unawaited(_withSourceCatalogueItem(m, showSheet));
      } else {
        unawaited(showSheet(m));
      }
    }

    void onInfo(MediaItem m) => _sourceCatalogueSelected
        ? _openSourceCatalogueDetail(m)
        : _openDetail(m);
    void onPlay(MediaItem m) {
      if (_sourceCatalogueSelected) {
        unawaited(_withSourceCatalogueItem(m, _playFeatured));
      } else {
        unawaited(_playFeatured(m));
      }
    }

    switch (bannerId) {
      case BannerStyle.panelsId:
        _clearHeroTintSoon();
        return FeaturedBannerPanels(
          items: heroItems,
          reading: reading,
          inList: (m) => _myList.contains(m),
          onPlay: onPlay,
          onInfo: onInfo,
          onToggleList: toggleList,
          meta: _heroMeta,
        );
      case BannerStyle.edgeId:
        return FeaturedBannerEdge(
          items: heroItems,
          reading: reading,
          isActive: widget.isTabActive,
          onInfo: onInfo,
          meta: _heroMeta,
          onArtColor: ThemeController.adaptiveColour
              ? (c) => _heroTint.value = c == null
                    ? null
                    : tintFromDominant(c, blend: adaptiveColourBlend)
              : null,
          backgroundTint: ThemeController.adaptiveColour ? _heroTint : null,
        );
      default:
        // Auto-rotating carousel (up to 6 trending items)
        return FeaturedCarousel(
          items: heroItems,
          reading: reading,
          inList: (m) => _myList.contains(m),
          onPlay: onPlay,
          onInfo: onInfo,
          onToggleList: toggleList,
          meta: _heroMeta,
          style: HeroTransition.cinematic,
          onArtColor: ThemeController.adaptiveColour
              ? (c) => _heroTint.value = c == null
                    ? null
                    : tintFromDominant(c, blend: adaptiveColourBlend)
              : null,
          backgroundTint: ThemeController.adaptiveColour ? _heroTint : null,
          isActive: widget.isTabActive,
        );
    }
  }

  /// Flat bell → Notifications screen. The accent dot shows while any
  /// announcement is unseen and clears itself reactively (the screen calls
  /// markAllSeen, the Hive box updates, the listenable rebuilds).
  Widget _notificationBell(BuildContext context, {bool edgeBanner = false}) {
    void openNotifications() => Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const SubscriptionsScreen()),
    );

    Widget icon() => Stack(
      clipBehavior: Clip.none,
      children: [
        DockIcon(
          DockGlyph.bell,
          color: edgeBanner ? Colors.white : AppColors.textSecondary,
          size: 22,
        ),
        if (Hive.isBoxOpen(AnnouncementStore.boxName) &&
            AnnouncementStore().unseenCount() > 0)
          Positioned(
            top: 1,
            right: 2,
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.accent,
                border: Border.all(color: AppColors.bg, width: 1.5),
              ),
            ),
          ),
      ],
    );

    // Build the same action fresh inside the listenable's builder so its badge
    // updates when an announcement is seen.
    Widget bell() => edgeBanner
        ? IconButton(
            tooltip: context.l10n.notifications,
            style: _edgeHeaderButtonStyle(),
            onPressed: openNotifications,
            icon: icon(),
          )
        : GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: openNotifications,
            child: Padding(padding: const EdgeInsets.all(4), child: icon()),
          );
    // Rebuild the dot when the announcements box changes (e.g. markAllSeen).
    if (!Hive.isBoxOpen(AnnouncementStore.boxName)) return bell();
    return ValueListenableBuilder(
      valueListenable: Hive.box(AnnouncementStore.boxName).listenable(),
      builder: (context, _, child) => bell(),
    );
  }

  /// Builds one provider-defined browse row (poster cards). The section is
  /// already guaranteed non-empty by [SourceRepository.home].
  Widget _sectionRow(HomeSection section, {bool sourceCatalogue = false}) {
    final items = section.items;
    final aspects = items
        .map(
          (item) => stremioPosterAspect(
            item,
            landscape: posterLayout(context) == PosterCardLayout.wide,
          ),
        )
        .toList();
    final widths = [
      for (final aspect in aspects)
        aspect == null
            ? posterRowWidth(context)
            : (aspect > 1
                      ? 184
                      : aspect == 1
                      ? 144
                      : 116) *
                  posterCardScale(context),
    ];
    final heights = [
      for (var i = 0; i < items.length; i++)
        aspects[i] == null
            ? posterRowHeight(context)
            : posterCellHeight(
                widths[i],
                artAspectRatio: aspects[i],
                textScaler: MediaQuery.textScalerOf(context),
                titleInside: posterTitleInside(
                  context,
                  wide: aspects[i]! > 1,
                  item: items[i],
                ),
              ),
    ];
    return _animated(
      ContentRow(
        title: section.title,
        itemWidth: posterRowWidth(context),
        itemWidthForIndex: (i) => widths[i],
        itemHeight: heights.fold<double>(0, (a, b) => a > b ? a : b),
        itemCount: items.length,
        onSeeAll: () => _openSeeAll(section, sourceCatalogue: sourceCatalogue),
        itemBuilder: (c, i) => Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            height: heights[i],
            child: PosterCard(
              title: items[i].title,
              logoItem: items[i],
              imageUrl: items[i].cover,
              headers: items[i].coverHeaders,
              cellWidth: widths[i],
              wideOverride: aspects[i] == null ? null : aspects[i]! > 1,
              wideImageUrl: items[i].banner,
              genres: items[i].genres,
              isAdult: items[i].isAdult,
              qualityBadge: items[i].quality,
              scoreBadge: items[i].score,
              dubBadge: items[i].dubBadge,
              onTap: () => sourceCatalogue
                  ? _openSourceCatalogueDetail(items[i])
                  : _openDetail(items[i]),
              onLongPress: () => sourceCatalogue
                  ? _showSourceCatalogueInfo(items[i])
                  : _showInfo(items[i]),
            ),
          ),
        ),
      ),
    );
  }

  /// Open one streaming service's catalogue from the rail.
  ///
  /// Goes straight to the paginated grid rather than via the services screen —
  /// the rail already IS the service picker, so a stop in between would be a
  /// screen you pass through.
  Future<void> _openStreamingService(StreamingService s) async {
    final repo = sl<MetadataRepository>();
    final more = BrowseMore(
      sourceId: ZmodeIds.sourceId,
      kind: 'zm_video',
      categoryId: TmdbCatalogue.wpRowId(s.id),
    );
    List<MediaItem> first;
    try {
      first = await repo.browseMore(more, 1);
    } catch (_) {
      first = const [];
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SeeAllScreen(
          title: s.name,
          items: first,
          onTap: (m) => Navigator.push(context, DetailScreen.route(m)),
          onLoadMore: (page) => repo.browseMore(more, page),
          filterKind: ZKind.movie,
          onSearch: (query, filters, page) => repo.streamingServicePage(
            s.id,
            query: query,
            filters: filters,
            page: page,
          ),
        ),
      ),
    );
  }

  /// One row of the merged home arrangement, as a sliver. Every [HomeRow]
  /// type maps to the widget that already renders that shape — the sealed
  /// switch makes a future row type a compile error here instead of a silent
  /// gap, and the local row reuses [ContinueSection] itself so its reactive
  /// Hive/mode behaviour is identical wherever the user drags it.
  Widget _homeRowSliver(HomeRow row) => switch (row) {
    LocalContinueHomeRow() => ContinueSection(
      onResume: _resume,
      onLongPress: _showContinueInfo,
      onSeeAll: _openHistory,
      onResumeReading: _resumeReading,
      onLongPressReading: _showContinueReadingInfo,
    ),
    StreamingServicesHomeRow() => SliverToBoxAdapter(
      child: StreamingServicesRow(
        onOpen: _openStreamingService,
        onSeeAll: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => const StreamingServicesScreen(),
          ),
        ),
      ),
    ),
    ProviderHomeRow(:final section) => SliverToBoxAdapter(
      child: _sectionRow(section),
    ),
    TrackerContinueHomeRow(:final items, :final trackerName) =>
      SliverToBoxAdapter(
        child: TrackerContinueSection(
          items: items,
          trackerName: trackerName,
          onOpen: _openTrackerEntry,
          onSeeAll: () => _openTrackerList(trackerName, WatchStatus.watching),
          onLongPress: _showTrackerInfo,
        ),
      ),
    NewEpisodesHomeRow(:final items, :final trackerName) => SliverToBoxAdapter(
      child: NewEpisodesSection(
        items: items,
        trackerName: trackerName,
        onOpen: _openTrackerEntry,
        onSeeAll: () => _openNewEpisodes(items),
        onLongPress: _showTrackerInfo,
      ),
    ),
    TrackerListHomeRow(:final status, :final items, :final trackerName) =>
      SliverToBoxAdapter(
        child: TrackerListSection(
          status: status,
          items: items,
          trackerName: trackerName,
          onOpen: _openTrackerEntry,
          onSeeAll: () => _openTrackerList(trackerName, status),
          onLongPress: _showTrackerInfo,
        ),
      ),
  };

  List<Widget> _sourceCatalogueHomeSlivers(List<HomeRow> rows) {
    final slivers = <Widget>[];
    var insertedCatalogue = false;
    void insertCatalogue() {
      if (insertedCatalogue) return;
      insertedCatalogue = true;
      slivers.add(_sourceCatalogueHomeSliver());
    }

    for (final row in rows) {
      // Only the selected source contributes catalogue rows. Keep the local
      // Continue row, but do not mix AniList/MAL tracker rows into this view.
      if (row is ProviderHomeRow || row is StreamingServicesHomeRow) {
        insertCatalogue();
      } else if (row is LocalContinueHomeRow) {
        slivers.add(_homeRowSliver(row));
      }
    }
    if (!insertedCatalogue) insertCatalogue();
    return slivers;
  }

  Widget _sourceCatalogueHomeSliver() => SliverToBoxAdapter(
    child: BlocBuilder<ContentModeCubit, ContentMode>(
      bloc: sl<ContentModeCubit>(),
      builder: (context, mode) => SourceCatalogueHomeContent(
        controller: _sourceCatalogueController,
        // Fresh prefs read, not the field: the cubit emits before our stream
        // listener refreshes the field, and handing the content a stale
        // (other-mode) id here is exactly what persisted fallbacks over picks.
        initialSourceId: HomeCataloguePrefs.sourceIdFor(mode),
        onSourceSelected: (sourceId) {
          _sourceCatalogueSourceId = sourceId;
          unawaited(HomeCataloguePrefs.setSourceIdFor(mode, sourceId));
        },
        onSectionsChanged: _setSourceCatalogueSections,
        sectionBuilder: (section) =>
            _sectionRow(section, sourceCatalogue: true),
        showSourcePicker: false,
        mode: mode,
      ),
    ),
  );

  /// "See all" on New Episodes: the same entries as a grid, keeping the count
  /// badge so the reason each one is here survives the jump.
  ///
  /// A fixed list, not a paginated one — this row is computed from the library
  /// already in hand, so there is no next page to ask anyone for.
  void _openNewEpisodes(List<TrackerListItem> items) {
    final waiting = {
      for (final e in items) e.item.id: releasedCount(e) - (e.progress ?? 0),
    };
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => SeeAllScreen(
          title: context.l10n.homeRowNewEpisodes,
          items: [for (final e in items) e.item],
          onTap: _openTrackerItem,
          tagsFor: (item) => ['+${waiting[item.id] ?? 0}'],
        ),
      ),
    );
  }

  /// "See all" on a tracker row: that tracker's whole library, opened on the
  /// tab the row came from.
  ///
  /// Reuses [MyListScreen] rather than a thinner grid, the same way the lists
  /// hub does — statuses, custom lists, sort and filter all keep working, and
  /// a purpose-built screen would have quietly lost them.
  void _openTrackerList(String trackerName, WatchStatus status) {
    if (!sl.isRegistered<TrackerHub>()) return;
    Tracker? tracker;
    for (final t in sl<TrackerHub>().trackers) {
      if (t.displayName == trackerName) tracker = t;
    }
    if (tracker == null) return;
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => MyListScreen(
          initialTracker: tracker,
          // The row was built for the mode Home is in, so the library has to
          // open on the same kind rather than following the app afterwards.
          initialKind: sl<ContentModeCubit>().state,
          initialStatus: status,
        ),
      ),
    );
  }

  /// Open a tracker entry from the home rows. The stub carries no provider,
  /// but it carries the id the metadata catalogue is keyed by, so a tap opens
  /// its Detail page directly; an entry with no id falls back to a search for
  /// its own title — the same open path My List uses.
  void _openTrackerEntry(TrackerListItem entry) => _openTrackerItem(entry.item);

  /// The info sheet for a tracker row, the same one every other poster on Home
  /// opens on a long-press. Re-keyed first so the sheet can look the title up
  /// in the catalogue — a raw stub carries no resolvable url.
  void _showTrackerInfo(TrackerListItem entry) =>
      _showInfo(playableTrackerItem(entry.item) ?? entry.item);

  /// The same open, from a bare item — the See All grid hands back MediaItems.
  void _openTrackerItem(MediaItem item) {
    final playable = playableTrackerItem(item);
    if (playable != null) {
      _openDetail(playable);
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => SearchScreen(initialQuery: item.title),
      ),
    );
  }

  /// Open the full history screen ("See all"). Lands on the tab matching the
  /// current content mode — the [ContentMode] enum is ordered anime/manga/novel,
  /// the same order as the History tabs — so reading modes open on Manga/Novel.
  void _openHistory() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            HistoryScreen(initialIndex: sl<ContentModeCubit>().state.index),
      ),
    ).then((_) {
      if (mounted) setState(() {});
    });
  }

  /// Open the full-grid "See All" view of a browse row.
  void _openSeeAll(HomeSection section, {bool sourceCatalogue = false}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SeeAllScreen(
          title: section.title,
          items: section.items,
          onTap: sourceCatalogue ? _openSourceCatalogueDetail : _openDetail,
          onLongPress: sourceCatalogue ? _showSourceCatalogueInfo : _showInfo,
          // Only paginable rows carry a `more` descriptor; everything else
          // stays a fixed list. Pagination isn't part of CatalogueRepository,
          // so go to whichever repository owns the row: the metadata providers
          // stamp the Z Mode source id, everything else is a real source.
          onLoadMore: section.more == null
              ? null
              // Compare the source id, NOT ZmodeIds.isZ — that tests a zm://
              // URL, and a sourceId is never one, so every metadata row would
              // have been sent to the source repository instead.
              : (page) => section.more!.sourceId == ZmodeIds.sourceId
                    ? sl<MetadataRepository>().browseMore(section.more!, page)
                    : sl<SourceRepository>().browseMore(section.more!, page),
        ),
      ),
    ).then((_) {
      if (mounted) setState(() {});
    });
  }

  /// Shown at the top of Home when the session lapsed — cloud sync is silently
  /// off until the user reconnects. Tapping re-authenticates in place (no logout
  /// / no wipe) and then refreshes Home to surface the freshly-synced rows.
  Widget _reconnectBanner() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Material(
        color: AppColors.accentSoft,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () async {
            final ok = await showReconnectDialog(context) ?? false;
            if (ok && mounted) context.read<HomeCubit>().load();
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Icon(
                  Icons.sync_problem_rounded,
                  color: AppColors.accent,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(context.l10n.reconnectToSync, style: AppText.body),
                      Text(
                        'Your session expired — tap to sign in and sync your library.',
                        style: AppText.caption,
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  color: AppColors.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Mode shortcuts and Genres for the active catalogue.
  Widget _modeCards() {
    return BlocBuilder<ContentModeCubit, ContentMode>(
      bloc: sl<ContentModeCubit>(),
      builder: (context, current) {
        // Z Mode owns mode switching; the Windows home has its own mode
        // controls, so the switcher cards would duplicate them there too.
        final others = ZModePrefs.enabled || _isDesktop
            ? const <ContentMode>[]
            : ContentMode.values.where((m) => m != current).toList();
        // A brand new install has watched nothing and read nothing, so every
        // card below falls through to its flat fill and the row opens dead.
        // The catalogue is already loaded underneath it, so borrow from that
        // instead — one cover per card that has none of its own, handed out
        // in the order the Row draws them so no two cards land on the same
        // picture.
        final spare = _catalogueArt();
        var next = 0;
        ({String? cover, Map<String, String>? headers}) orBorrow(
          ({String? cover, Map<String, String>? headers}) own,
        ) {
          if (own.cover?.isNotEmpty ?? false) return own;
          return next < spare.length ? spare[next++] : own;
        }

        final cards = <Widget>[
          for (final m in others) _modeCard(m, orBorrow(_modeArt(m))),
          // Genres shortcut is temporarily disabled.
          // if (sl.isRegistered<MetadataRepository>() &&
          //     sl<MetadataRepository>().supportsFilters)
          //   _genresCard(orBorrow(_genresArt())),
        ];
        if (cards.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
          child: Row(
            children: [
              for (var i = 0; i < cards.length; i++) ...[
                if (i > 0) const SizedBox(width: 12),
                Expanded(child: cards[i]),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _modeCard(
    ContentMode m,
    ({String? cover, Map<String, String>? headers}) art,
  ) {
    return GestureDetector(
      onTap: _slashing ? null : () => _enterMode(m),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          height: _isDesktop ? 76 : 52,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // A cover from the user's recent content for this mode, one
              // borrowed from the catalogue when they have none, and a tint
              // of the accent only when there is no catalogue either.
              _cardBg(art, scrim: _neutralScrim, empty: _emptyTint(0.16, 0.09)),
              Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(m.icon, size: 18, color: Colors.white),
                    const SizedBox(width: 8),
                    // Flexible, not bare: at three cards on a 320px phone the
                    // label has ~68px and "Streaming" does not fit.
                    Flexible(
                      child: Text(
                        m.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.body.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                          shadows: const [
                            Shadow(color: Colors.black, blurRadius: 6),
                          ],
                        ),
                      ),
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

  /// Art for the cards to borrow when the user's own history has none — a
  /// fresh install, or a mode they have not opened yet.
  ///
  /// Comes from the rows already loaded below the cards, so it costs no fetch
  /// and is guaranteed to be something the active source can actually show.
  /// Anything the carousel directly above could rotate onto is skipped, by
  /// TITLE rather than by url. Both halves of that matter: the hero is not
  /// simply the first section (it prefers a Trending row — see
  /// [HomeState.heroItems]), and a popular show sits in several rows with
  /// different art in each, so matching urls alone still put the card on a
  /// second picture of whatever the banner was already showing.
  List<({String? cover, Map<String, String>? headers})> _catalogueArt() {
    final state = context.read<HomeCubit>().state;
    final hero = {for (final it in state.heroItems) it.title.toLowerCase()};
    final out = <({String? cover, Map<String, String>? headers})>[];
    final seen = <String>{};
    for (final s in state.sections ?? const <HomeSection>[]) {
      for (final it in s.items) {
        if (hero.contains(it.title.toLowerCase())) continue;
        final art = _itemArt(it);
        final url = art.cover;
        if (url == null || url.isEmpty || !seen.add(url)) continue;
        out.add(art);
        // Two switchers, the hub and Genres is every card the row can hold.
        if (out.length == 4) return out;
      }
    }
    return out;
  }

  /// Wide art if the item has it, else the poster. These cards are a 3:1
  /// strip and a poster cropped to that is a sliver of someone's forehead.
  ///
  /// An item from an installed extension keeps its cover and headers
  /// together: [_art] routes those through that source's own client, and a
  /// banner url would not survive the trip.
  ({String? cover, Map<String, String>? headers}) _itemArt(MediaItem it) {
    final native =
        it.coverHeaders?['x-ani-src'] != null ||
        it.coverHeaders?['x-mihon-src'] != null;
    final wide = native ? null : it.banner;
    return (cover: wide ?? it.cover, headers: it.coverHeaders);
  }

  /// A cover for the Genres card that is NOT the one on the Lists card.
  ///
  /// The Lists card always shows the last thing watched, so feeding this the
  /// same [_modeArt] put one image twice in a two-card row. Prefer something
  /// read rather than watched, else the second distinct thing watched, else
  /// nothing — at which point the tint below carries the difference.
  // ignore: unused_element
  ({String? cover, Map<String, String>? headers}) _genresArt() {
    for (final m in const [ContentMode.manga, ContentMode.novel]) {
      final a = _modeArt(m);
      if (a.cover?.isNotEmpty ?? false) return a;
    }
    if (Hive.isBoxOpen(WatchHistory.boxName)) {
      final seen = <String>{};
      for (final e in sl<WatchHistory>().all()) {
        final c = e.thumbnail ?? e.cover;
        if (c == null || c.isEmpty) continue;
        // The Lists card took the first, so hand back the second.
        if (seen.add(c) && seen.length == 2) {
          return (cover: c, headers: e.coverHeaders);
        }
      }
    }
    return (cover: null, headers: null);
  }

  /// Same card shell again, for [GenresScreen] — the genre list for whatever
  /// mode you are in, each one a way straight into a filtered Search.
  // ignore: unused_element
  Widget _genresCard(({String? cover, Map<String, String>? headers}) art) {
    return GestureDetector(
      key: const ValueKey('home_genres_card'),
      onTap: _slashing
          ? null
          : () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const GenresScreen()),
            ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          height: _isDesktop ? 76 : 52,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Accent-tinted rather than the neutral black the Lists card
              // uses: side by side at equal width, two identically scrimmed
              // cards read as one wide slab split by a gap. Not at 0.82
              // though — that buried the cover under a flat sheet of accent,
              // so the tint now sits over the art rather than in place of it.
              _cardBg(
                art,
                // Toned, not the raw accent: a light Material You accent
                // washed the card out and took the white label with it.
                scrim: [
                  _toned(0.30).withValues(alpha: 0.78),
                  Colors.black.withValues(alpha: 0.55),
                ],
                empty: _emptyTint(0.32, 0.15),
              ),
              Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.local_offer_outlined,
                      size: 18,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        context.l10n.genres,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.body.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                          shadows: const [
                            Shadow(color: Colors.black, blurRadius: 6),
                          ],
                        ),
                      ),
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

  /// A representative cover for [m] from the user's own history — last watched
  /// show (streaming) or last read manga/novel. Null when there's nothing yet.
  ({String? cover, Map<String, String>? headers}) _modeArt(ContentMode m) {
    if (m == ContentMode.anime) {
      if (!Hive.isBoxOpen(WatchHistory.boxName)) {
        return (cover: null, headers: null);
      }
      for (final e in sl<WatchHistory>().all()) {
        final c = e.thumbnail ?? e.cover;
        if (c != null && c.isNotEmpty) {
          return (cover: c, headers: e.coverHeaders);
        }
      }
      return (cover: null, headers: null);
    }
    if (!Hive.isBoxOpen(ReadHistory.boxName)) {
      return (cover: null, headers: null);
    }
    final type = m == ContentMode.manga
        ? ProviderType.manga
        : ProviderType.novel;
    for (final e in sl<ReadHistory>().all()) {
      if (e.type == type && (e.cover?.isNotEmpty ?? false)) {
        return (cover: e.cover, headers: e.coverHeaders);
      }
    }
    return (cover: null, headers: null);
  }

  /// The neutral scrim the switcher and Lists cards lay over their art, so a
  /// white icon and label stay legible whatever the cover looks like.
  static const _neutralScrim = [Color(0xCC000000), Color(0x55000000)];

  /// The accent's hue at a darkness we choose.
  ///
  /// The accent cannot be used raw here. With Material You on it is tone 80
  /// of the wallpaper palette (see [ThemeController]) — a LIGHT colour, meant
  /// for text and icons ON a dark ground. Tinting a card with it lightened
  /// the card instead of colouring it, and took the white label with it.
  /// Hue and saturation carry the theme; the lightness is this screen's.
  Color _toned(double lightness) =>
      HSLColor.fromColor(AppColors.accent).withLightness(lightness).toColor();

  /// Gradient for a card with no art behind it, [from] darkness to [to].
  ///
  /// Flat grey is what an empty history used to get — the fallback was
  /// surface2 to surface, and the scrim on top then knocked even that back,
  /// so a fresh install opened onto a row of dead slabs. These sit in the
  /// same dark range as the surfaces, just carrying the theme's colour.
  List<Color> _emptyTint(double from, double to) => [_toned(from), _toned(to)];

  /// Background for one of the 52dp cards: the art under [scrim], or the
  /// [empty] gradient alone when there is no art. The scrim is skipped in
  /// that case — it is there to tame a photograph, and over a flat fill it
  /// only muddies it.
  Widget _cardBg(
    ({String? cover, Map<String, String>? headers}) art, {
    required List<Color> scrim,
    required List<Color> empty,
  }) {
    final url = art.cover;
    if (url == null || url.isEmpty) {
      return DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: empty,
          ),
        ),
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        _art(url, art.headers),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: scrim,
            ),
          ),
        ),
      ],
    );
  }

  /// Decodes shortcut artwork for its painted desktop width, avoiding the
  /// phone's fixed 420-pixel thumbnail on wide or high-DPI windows.
  Widget _art(String url, Map<String, String>? headers) => LayoutBuilder(
    builder: (context, constraints) {
      final width = Platform.isWindows
          ? artworkDecodeWidth(
              constraints.hasBoundedWidth ? constraints.maxWidth : 420,
              MediaQuery.devicePixelRatioOf(context),
              maximum: 2048,
            )
          : 420;
      final imageUrl = Platform.isWindows ? desktopArtworkUrl(url) : url;
      if (headers?['x-ani-src'] != null || headers?['x-mihon-src'] != null) {
        return Image(
          image: ResizeImage(
            headers?['x-ani-src'] != null
                ? AniyomiImage(int.parse(headers!['x-ani-src']!), imageUrl)
                : MihonImage(int.parse(headers!['x-mihon-src']!), imageUrl),
            width: width,
          ),
          fit: BoxFit.cover,
          alignment: const Alignment(0, -0.2),
          errorBuilder: (_, _, _) => ColoredBox(color: AppColors.surface2),
        );
      }
      return CachedNetworkImage(
        imageUrl: imageUrl,
        httpHeaders: headers,
        memCacheWidth: width,
        fit: BoxFit.cover,
        alignment: const Alignment(0, -0.2),
        placeholder: (_, _) => ColoredBox(color: AppColors.surface2),
        errorWidget: (_, _, _) => ColoredBox(color: AppColors.surface2),
      );
    },
  );

  /// Kicks off the slash transition into [m]. The actual mode swap happens
  /// mid-animation via the controller listener wired in [initState].
  void _enterMode(ContentMode m) {
    if (_slashing) return;
    setState(() {
      _slashing = true;
      _slashSwapped = false;
      _slashTarget = m;
    });
    _slashCtrl.forward(from: 0);
  }

  /// Full-screen logo-strike overlay: the mark springs in at centre behind a
  /// scrim (peaking at the midpoint to hide the content swap), a red glow pulses
  /// and a steel glint sweeps the blade at the strike. Absorbs taps for its
  /// ~600ms so the switch can't be double-fired.
  Widget _slashOverlay() {
    const logoSize = 152.0;
    return Positioned.fill(
      child: AbsorbPointer(
        child: AnimatedBuilder(
          animation: _slashCtrl,
          builder: (context, _) {
            final t = _slashCtrl.value;
            // Triangular pulse: 0 at the ends, 1 at the midpoint.
            final scrim = (1 - (t * 2 - 1).abs()).clamp(0.0, 1.0);
            // Spring in (easeOutBack overshoots ~1), then a slight scale-up on
            // the way out as it fades.
            final inP = (t / 0.45).clamp(0.0, 1.0);
            final outP = ((t - 0.75) / 0.25).clamp(0.0, 1.0);
            final scale =
                0.62 + 0.38 * Curves.easeOutBack.transform(inP) + outP * 0.12;
            final logoOpacity =
                (t < 0.12
                        ? t / 0.12
                        : t > 0.8
                        ? (1 - t) / 0.2
                        : 1.0)
                    .clamp(0.0, 1.0);
            // Steel glint: a white streak that sweeps across the mark around the
            // strike (t≈0.38–0.62, peaking with the swap).
            final glintOn = t > 0.38 && t < 0.62;
            final glintP = ((t - 0.38) / 0.24).clamp(0.0, 1.0);
            final glintPulse = (1 - (glintP * 2 - 1).abs()).clamp(0.0, 1.0);

            return Stack(
              children: [
                Positioned.fill(
                  child: ColoredBox(
                    color: AppColors.bg.withValues(alpha: scrim * 0.92),
                  ),
                ),
                Center(
                  child: Opacity(
                    opacity: logoOpacity,
                    child: Transform.scale(
                      scale: scale,
                      child: SizedBox(
                        width: logoSize,
                        height: logoSize,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            // Red energy glow behind the mark.
                            SizedBox(
                              width: logoSize * 0.8,
                              height: logoSize * 0.8,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: AppColors.accent.withValues(
                                        alpha: 0.5 * scrim,
                                      ),
                                      blurRadius: 48,
                                      spreadRadius: 4,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            Image.asset(
                              'assets/icon/logo_mark.png',
                              width: logoSize,
                              height: logoSize,
                            ),
                            if (glintOn)
                              ClipRRect(
                                borderRadius: BorderRadius.circular(26),
                                child: SizedBox(
                                  width: logoSize,
                                  height: logoSize,
                                  child: Transform.translate(
                                    offset: Offset(
                                      (glintP * 2 - 1) * logoSize * 0.9,
                                      0,
                                    ),
                                    child: Transform.rotate(
                                      angle: -0.5,
                                      child: Container(
                                        width: 34,
                                        height: logoSize * 2,
                                        decoration: BoxDecoration(
                                          gradient: LinearGradient(
                                            colors: [
                                              Colors.white.withValues(alpha: 0),
                                              Colors.white.withValues(
                                                alpha: 0.85 * glintPulse,
                                              ),
                                              Colors.white.withValues(alpha: 0),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Explicit desktop catalogue selection preserves the chosen metadata
  /// provider separately from installed playback/reading sources.
  Future<void> _selectDesktopAnimeCatalogue(AnimeProvider provider) async {
    final cubit = context.read<HomeCubit>();
    await sl<MetadataProviderPrefs>().setAnime(provider);
    await HomeCataloguePrefs.setSourceSelected(false);
    if (mounted && !cubit.isClosed) {
      await cubit.load(reset: true);
    }
  }

  /// Movies/TV keep their independent metadata choice when leaving sources.
  Future<void> _selectDesktopVideoCatalogue(VideoProvider provider) async {
    final cubit = context.read<HomeCubit>();
    await sl<MetadataProviderPrefs>().setVideo(provider);
    await HomeCataloguePrefs.setSourceSelected(false);
    if (mounted && !cubit.isClosed) {
      await cubit.load(reset: true);
    }
  }

  Future<List<HomeSection>>? _newDesktopSourceFuture;
  String? _newDesktopSourceKey;

  /// Fetch source catalogue data directly. No hidden/offstage legacy view is
  /// mounted to obtain it; source selection never changes the global provider.
  Future<List<HomeSection>> _newDesktopSourceRows(ContentMode mode) {
    final repository = sl<SourceRepository>();
    final sources = repository.loadedSources
        .where(
          (source) => switch (mode) {
            ContentMode.manga => source.id.startsWith('mihon:'),
            ContentMode.novel => source.id.startsWith('lnr:'),
            ContentMode.anime =>
              !source.id.startsWith('mihon:') && !source.id.startsWith('lnr:'),
          },
        )
        .toList();
    final sourceId =
        sources.any((source) => source.id == _sourceCatalogueSourceId)
        ? _sourceCatalogueSourceId
        : sources.firstOrNull?.id;
    final key = '${mode.name}:$sourceId';
    if (key != _newDesktopSourceKey) {
      _newDesktopSourceKey = key;
      _sourceCatalogueSourceId = sourceId;
      _newDesktopSourceFuture = sourceId == null
          ? Future.value(const [])
          : repository.home(sourceId: sourceId).then((sections) {
              // Novel plugins swallow fetch failures. Convert only this site's
              // pending challenge into the same typed recovery as Mihon.
              final challenge = sourceId.startsWith('lnr:') && sections.isEmpty
                  ? NovelCloudflare.pendingForSite(
                      repository.baseUrlFor(sourceId),
                    )
                  : null;
              if (challenge != null) {
                throw CloudflareRequiredException(challenge);
              }
              // Windows (home-11 B): remembered so a later refresh of this
              // same source keeps these rows on screen while it loads.
              _lastDesktopSourceRows = (key: key, sections: sections);
              return sections;
            });
    }
    return _newDesktopSourceFuture!;
  }

  /// Maps the saved Home rows arrangement ([HomeState.rows], Settings > Home
  /// rows) onto the desktop Home: order, visibility and reset all come from
  /// the same merge the phone renders. Null before the first merge, which
  /// keeps the desktop's built-in order.
  List<DesktopHomeRow>? _desktopHomeRows(
    List<HomeRow>? rows,
    List<HomeSection> sections,
    ContentMode mode,
  ) {
    if (rows == null && !_sourceCatalogueSelected) return null;
    final out = <DesktopHomeRow>[];
    if (_sourceCatalogueSelected) {
      // Same rule as the phone: a source catalogue keeps only the Continue
      // row and the catalogue's position from the layout.
      var inserted = false;
      void insertCatalogue() {
        if (inserted) return;
        inserted = true;
        // home-11 A: the banner's titles are not repeated as a shelf.
        out.addAll(_desktopSourceShelves(sections));
      }

      // Before the first merge there is no saved layout: Continue first,
      // then the catalogue (the desktop's built-in order).
      if (rows == null) out.add(DesktopHomeRow.resume());
      for (final row in rows ?? const <HomeRow>[]) {
        if (row is LocalContinueHomeRow) {
          out.add(DesktopHomeRow.resume());
        } else if (row is ProviderHomeRow || row is StreamingServicesHomeRow) {
          insertCatalogue();
        }
      }
      insertCatalogue();
      return out;
    }
    // The phone feeds its banner from a first section it then leaves out of
    // the rows (providerRowSections), so the editor never lists it. Desktop
    // keeps that section as a shelf just above the first catalogue row, as it
    // always has, so no catalogue content disappears.
    final listed = providerRowSections(sections, isTv: false);
    final unlisted = sections.length > listed.length ? sections.first : null;
    var placedUnlisted = unlisted == null;
    void placeUnlisted() {
      if (placedUnlisted) return;
      placedUnlisted = true;
      out.add(DesktopHomeRow.shelf(unlisted!));
    }

    for (final row in rows ?? const <HomeRow>[]) {
      switch (row) {
        case LocalContinueHomeRow():
          out.add(DesktopHomeRow.resume());
        case ProviderHomeRow(:final section):
          placeUnlisted();
          out.add(DesktopHomeRow.shelf(section));
        case StreamingServicesHomeRow():
          out.add(
            DesktopHomeRow.custom(
              (context) => DesktopHomeServicesShelf(
                key: const ValueKey('desktop-home-services'),
                title: context.l10n.streamingServices,
                load: () => sl.isRegistered<StreamingProvidersService>()
                    ? sl<StreamingProvidersService>().list(
                        StreamingPrefs.region,
                      )
                    : Future.value(const <StreamingService>[]),
                onOpen: (service) => unawaited(_openStreamingService(service)),
                onAll: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const StreamingServicesScreen(),
                  ),
                ),
              ),
            ),
          );
        case TrackerContinueHomeRow(:final items, :final trackerName):
          out.add(
            _desktopTrackerShelf(
              title: context.l10n.homeRowTrackerContinue(trackerName),
              items: items,
              trackerName: trackerName,
              status: WatchStatus.watching,
              onAll: () =>
                  _openTrackerList(trackerName, WatchStatus.watching),
              progress: true,
            ),
          );
        case NewEpisodesHomeRow(:final items, :final trackerName):
          out.add(
            _desktopTrackerShelf(
              title: context.l10n.homeRowNewEpisodes,
              items: items,
              trackerName: trackerName,
              status: WatchStatus.watching,
              onAll: () => _openNewEpisodes(items),
              // Always shown: the count is why the title is in this row.
              tags: (e) => ['+${releasedCount(e) - (e.progress ?? 0)}'],
            ),
          );
        case TrackerListHomeRow(:final status, :final items, :final trackerName):
          out.add(
            _desktopTrackerShelf(
              title: trackerStatusLabel(
                context,
                status,
                reading: mode.isReading,
              ),
              items: items,
              trackerName: trackerName,
              status: status,
              onAll: () => _openTrackerList(trackerName, status),
              progress: true,
            ),
          );
      }
    }
    placeUnlisted();
    return out;
  }

  /// Windows (home-11 A): banner titles of a source catalogue
  /// (see [desktopSourceCatalogueSplit]).
  List<MediaItem> _desktopSourceFeatured(List<HomeSection> sections) =>
      desktopSourceCatalogueSplit(sections).featured;

  /// Windows (home-11 A): the shelves of a source catalogue, without the
  /// titles already in the banner. A trimmed lone section still opens the
  /// whole original section (and its paging) from See all.
  List<DesktopHomeRow> _desktopSourceShelves(List<HomeSection> sections) {
    final split = desktopSourceCatalogueSplit(sections);
    final whole = split.trimmedFrom;
    return [
      for (final s in split.shelves)
        DesktopHomeRow.shelf(
          s,
          onAll: whole == null
              ? null
              : () => _openSeeAll(whole, sourceCatalogue: true),
        ),
    ];
  }

  /// A tracker row (Continue on tracker, New episodes, a status list) as a
  /// desktop poster shelf. Opens and menus go through the tracker paths, and
  /// the episode count shows only while Poster cards > Watch progress is on.
  DesktopHomeRow _desktopTrackerShelf({
    required String title,
    required List<TrackerListItem> items,
    required String trackerName,
    required WatchStatus status,
    required VoidCallback onAll,
    bool progress = false,
    List<String> Function(TrackerListItem)? tags,
  }) {
    final entries = Map<MediaItem, TrackerListItem>.identity()
      ..addEntries(items.map((e) => MapEntry(e.item, e)));
    return DesktopHomeRow.shelf(
      HomeSection(title: title, items: [for (final e in items) e.item]),
      onOpen: _openTrackerItem,
      onAll: onAll,
      onMenu: (item) => unawaited(
        showDesktopHomeMenu(
          context,
          title: item.title,
          actions: [
            (label: 'Details', icon: 'info', run: () => _openTrackerItem(item)),
            (
              label: 'Open $trackerName list',
              icon: 'bookmark',
              run: () => _openTrackerList(trackerName, status),
            ),
          ],
        ),
      ),
      tagsFor: tags == null
          ? null
          : (item) => entries[item] == null ? const [] : tags(entries[item]!),
      progressFor: progress
          ? (item) => entries[item] == null
                ? null
                : trackerProgressSubtitle(entries[item]!)
          : null,
    );
  }

  // ── Windows Continue menu actions (home-8) ─────────────────────────────────

  /// The show behind a Continue watching card, for Details (same stub the
  /// phone info sheet uses).
  MediaItem _continueWatchItem(HistoryEntry e) => MediaItem(
    id: e.showId,
    title: e.showTitle,
    cover: e.cover,
    coverHeaders: e.coverHeaders,
    url: e.showUrl,
    type: ProviderType.anime,
    sourceId: e.sourceId,
  );

  /// The title behind a Continue reading card, for Details.
  MediaItem _continueReadItem(ReadEntry e) => MediaItem(
    id: e.showId,
    title: e.title,
    cover: e.cover,
    url: e.detailUrl,
    type: e.type,
    sourceId: e.sourceId,
  );

  /// home-8 A: removes the card at once and offers Undo, which puts the
  /// exact entry (episode + position) back.
  Future<void> _removeWatchFromContinue(HistoryEntry e) async {
    final history = sl<WatchHistory>();
    final removal = history.remove(e.sourceId, e.showId);
    if (mounted) {
      showUndoToast(
        context,
        message: context.l10n.removedFromContinueWatching,
        onUndo: () => unawaited(() async {
          // Let the remove (and its cloud delete) finish first, so the
          // restored row is the one that stays.
          try {
            await removal;
          } catch (_) {}
          await history.restore(e);
        }()),
      );
    }
    try {
      await removal;
    } catch (_) {
      showGlobalSnack(appL10n.couldntRemoveFromContinueWatching);
    }
  }

  /// home-8 A for reading: remove with Undo.
  Future<void> _removeReadingFromContinue(ReadEntry e) async {
    final history = sl<ReadHistory>();
    final removal = history.remove(e.sourceId, e.showId);
    if (mounted) {
      showUndoToast(
        context,
        message: context.l10n.removedFromContinueReading,
        onUndo: () => unawaited(() async {
          try {
            await removal;
          } catch (_) {}
          await history.save(e, flush: true);
        }()),
      );
    }
    try {
      await removal;
    } catch (_) {
      showGlobalSnack(appL10n.couldntRemoveFromContinueReading);
    }
  }

  /// home-8 B: plays the Continue episode from 0:00. The episode's own resume
  /// mark is reset too, otherwise the player would jump back to it.
  Future<void> _restartEpisode(HistoryEntry e) async {
    if (sl.isRegistered<ResumeStore>()) {
      await sl<ResumeStore>().save(
        e.sourceId,
        e.showUrl,
        e.episodeId,
        Duration.zero,
        e.duration,
      );
    }
    if (!mounted) return;
    await _resume(
      HistoryEntry(
        sourceId: e.sourceId,
        showId: e.showId,
        showTitle: e.showTitle,
        cover: e.cover,
        coverHeaders: e.coverHeaders,
        thumbnail: e.thumbnail,
        showUrl: e.showUrl,
        category: e.category,
        episodeId: e.episodeId,
        episodeNumber: e.episodeNumber,
        episodeUrl: e.episodeUrl,
        position: Duration.zero,
        duration: e.duration,
        updatedAt: e.updatedAt,
        malId: e.malId,
      ),
    );
  }

  /// home-8 B: marks the Continue episode watched (episode list tick + a
  /// finished history row, which drops the card from Continue).
  Future<void> _markEpisodeWatched(HistoryEntry e) async {
    if (sl.isRegistered<ResumeStore>()) {
      await sl<ResumeStore>().setWatched(
        e.sourceId,
        e.showUrl,
        e.episodeId,
        watched: true,
      );
    }
    // A row with no known length still has to count as finished.
    final length = e.duration > Duration.zero
        ? e.duration
        : const Duration(milliseconds: 1);
    await sl<WatchHistory>().save(
      HistoryEntry(
        sourceId: e.sourceId,
        showId: e.showId,
        showTitle: e.showTitle,
        cover: e.cover,
        coverHeaders: e.coverHeaders,
        thumbnail: e.thumbnail,
        showUrl: e.showUrl,
        category: e.category,
        episodeId: e.episodeId,
        episodeNumber: e.episodeNumber,
        episodeUrl: e.episodeUrl,
        position: length,
        duration: length,
        updatedAt: e.updatedAt,
        malId: e.malId,
      ),
      flush: true,
    );
  }

  /// home-8 B for reading: opens the Continue chapter from its first page.
  Future<void> _restartReading(ReadEntry e) async {
    if (sl.isRegistered<ReadStore>()) {
      // Unmarking clears the saved position, so the reader starts at page 1.
      await sl<ReadStore>().setRead(
        e.sourceId,
        e.showId,
        e.chapterId,
        read: false,
      );
    }
    if (!mounted) return;
    await _resumeReading(e);
  }

  /// home-8 B for reading: marks the Continue chapter read.
  Future<void> _markReadingDone(ReadEntry e) async {
    if (sl.isRegistered<ReadStore>()) {
      await sl<ReadStore>().setRead(
        e.sourceId,
        e.showId,
        e.chapterId,
        read: true,
      );
    }
    await sl<ReadHistory>().save(readEntryMarkedRead(e), flush: true);
  }

  // ── Windows catalogue choices (home-6) ─────────────────────────────────────

  /// Every catalogue Home can show in [mode]: the metadata catalogues, the
  /// generic browse catalogue and the loaded extensions. Used by the hero's
  /// "Choose catalogue" menu and published to the shell's catalogue switch.
  List<
    ({String id, String group, String label, String icon, VoidCallback run})
  >
  _desktopCatalogueChoices(ContentMode mode) {
    final catalogues = context.l10n.cataloguesGroup;
    final extensions = context.l10n.extensionsGroup;
    final meta = sl.isRegistered<MetadataProviderPrefs>();
    return [
      if (meta &&
          (mode == ContentMode.manga ||
              (mode == ContentMode.anime &&
                  ZModePrefs.streamKind == StreamKind.anime)))
        for (final provider in AnimeProvider.values)
          (
            id: 'meta:anime:${provider.name}',
            group: catalogues,
            label: provider == AnimeProvider.anilist
                ? 'AniList catalogue'
                : 'MyAnimeList catalogue',
            icon: 'blocks',
            run: () => unawaited(_selectDesktopAnimeCatalogue(provider)),
          ),
      if (meta &&
          mode == ContentMode.anime &&
          ZModePrefs.streamKind == StreamKind.movie)
        for (final provider in VideoProvider.values)
          (
            id: 'meta:video:${provider.name}',
            group: catalogues,
            label: provider == VideoProvider.tmdb
                ? 'TMDB catalogue'
                : 'Simkl catalogue',
            icon: 'blocks',
            run: () => unawaited(_selectDesktopVideoCatalogue(provider)),
          ),
      (
        id: 'browse',
        group: catalogues,
        label: 'Browse catalogue',
        icon: 'blocks',
        run: () => unawaited(HomeCataloguePrefs.setSourceSelected(false)),
      ),
      for (final source in sl<SourceRepository>().loadedSources.where(
        (source) => switch (mode) {
          ContentMode.manga => source.id.startsWith('mihon:'),
          ContentMode.novel => source.id.startsWith('lnr:'),
          ContentMode.anime =>
            !source.id.startsWith('mihon:') && !source.id.startsWith('lnr:'),
        },
      ))
        (
          id: 'source:${source.id}',
          group: extensions,
          label: source.id == stremioSourceId
              ? 'Stremio catalogue'
              : source.name,
          // Extension sources use the Settings > Sources 'blocks' icon so a
          // source looks the same in the catalogue menu and on the rail.
          icon: source.id == stremioSourceId ? 'clapperboard' : 'blocks',
          run: () {
            // Stremio is its own catalogue kind (installed addon
            // catalogues), not an ordinary source: saving it via
            // setSourceSelected would flip the kind back to "source" and
            // lose the Stremio rows.
            if (source.id == stremioSourceId) {
              unawaited(
                HomeCataloguePrefs.setCatalogue(
                  mode,
                  HomeCatalogueKind.stremio,
                ),
              );
              return;
            }
            _selectHomeCatalogueSource(source.id);
            unawaited(HomeCataloguePrefs.setSourceSelected(true));
          },
        ),
    ];
  }

  /// Compact pill name for a [_desktopCatalogueChoices] entry: just the
  /// tracker / source name ('AniList', 'MAL', 'TMDB', 'Simkl', 'Browse',
  /// 'Stremio'), without the menu's "catalogue" suffix. Extension sources
  /// already carry their plain name in [label].
  String _desktopCatalogueShortLabel(String id, String label) => switch (id) {
    'meta:anime:anilist' => 'AniList',
    'meta:anime:mal' => 'MAL',
    'meta:video:tmdb' => 'TMDB',
    'meta:video:simkl' => 'Simkl',
    'browse' => 'Browse',
    _ when id == 'source:$stremioSourceId' => 'Stremio',
    _ => label,
  };

  /// Id (in [_desktopCatalogueChoices] terms) of the catalogue on screen.
  String _desktopCurrentCatalogueId(ContentMode mode) {
    if (HomeCataloguePrefs.stremioSelected) return 'source:$stremioSourceId';
    if (_sourceCatalogueSelected) return 'source:$_sourceCatalogueSourceId';
    if (!sl.isRegistered<MetadataProviderPrefs>()) return 'browse';
    final prefs = sl<MetadataProviderPrefs>();
    if (mode == ContentMode.manga ||
        (mode == ContentMode.anime &&
            ZModePrefs.streamKind == StreamKind.anime)) {
      return 'meta:anime:${prefs.anime.name}';
    }
    if (mode == ContentMode.anime && ZModePrefs.streamKind == StreamKind.movie) {
      return 'meta:video:${prefs.video.name}';
    }
    return 'browse';
  }

  /// home-6: hands the catalogue choices to the shell's switcher. Only
  /// republished when ids, labels or the current one change, and after the
  /// frame, because the switcher's listeners rebuild other widgets.
  void _publishDesktopCatalogues(
    List<
      ({String id, String group, String label, String icon, VoidCallback run})
    >
    choices,
  ) {
    final mode = sl<ContentModeCubit>().state;
    final currentId = _desktopCurrentCatalogueId(mode);
    final signature = [
      mode.name,
      currentId,
      for (final c in choices) '${c.id}=${c.label}',
    ].join('\n');
    if (signature == _publishedCatalogueSignature) return;
    _publishedCatalogueSignature = signature;
    final options = [
      for (final c in choices)
        DesktopCatalogueOption(
          id: c.id,
          label: c.label,
          shortLabel: _desktopCatalogueShortLabel(c.id, c.label),
          group: c.group,
          // Fallback matches the Sources 'blocks' icon, not the puzzle.
          icon: desktopHomeMenuIcon(c.icon) ?? Icons.widgets_outlined,
          onSelect: c.run,
        ),
    ];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // A newer publish (or dispose) since this frame wins.
      if (!mounted || _publishedCatalogueSignature != signature) return;
      DesktopCatalogueSwitch.publish(options, currentId: currentId);
    });
  }

  /// A fresh Windows presentation consumes the existing data owners and route
  /// callbacks. None of the phone/previous desktop presentation is composed.
  ///
  /// home-10: history drives this through [DesktopContinueStore], which only
  /// notifies when Continue entries are added, removed or reordered (not on
  /// every player position save), and refreshes when Home is uncovered.
  Widget _buildNewDesktopHome() => DesktopContinueRefresher(
    store: _continue,
    child: BlocBuilder<ContentModeCubit, ContentMode>(
    bloc: sl<ContentModeCubit>(),
    builder: (context, mode) => BlocBuilder<HomeCubit, HomeState>(
      // home-10: no history listener here. Only the Continue block (and the
      // hero's play label) listen to the store via continueListenable, so a
      // history change does not rebuild the shelves and downloads of Home.
      builder: (context, state) => Builder(
        builder: (context) {
          Widget render(
            List<HomeSection> sections, {
            bool loading = false,
            String? error,
            String? sourceVerificationUrl,
          }) {
            // Direct-source failures belong to their own request, not the
            // independently loaded metadata catalogue's challenge state.
            final verificationUrl = _sourceCatalogueSelected
                ? sourceVerificationUrl
                : state.cloudflareUrl;
            // home-10: lists and lookups come precomputed from the store.
            final store = _continue;
            final readType = mode == ContentMode.manga
                ? ProviderType.manga
                : ProviderType.novel;
            final releaseRow = context.read<HomeCubit>().desktopReleaseRow;
            final releases = releaseRow?.items ?? const <TrackerListItem>[];
            // home-11 A: a source catalogue's banner titles are not repeated
            // as the first shelf (see _desktopSourceShelves).
            final featured = _sourceCatalogueSelected
                ? _desktopSourceFeatured(sections)
                : state.heroItems;
            void open(MediaItem item) => _sourceCatalogueSelected
                ? _openSourceCatalogueDetail(item)
                : _openDetail(item);
            // Map reads by show id / URL instead of a search per poster.
            HistoryEntry? historyFor(MediaItem item) => store.historyFor(item);
            ReadEntry? readingFor(MediaItem item) => store.readingFor(item);
            void play(MediaItem item) {
              final readingEntry = mode.isReading ? readingFor(item) : null;
              final videoEntry = mode.isReading ? null : historyFor(item);
              if (readingEntry != null) {
                unawaited(_resumeReading(readingEntry));
                return;
              }
              if (videoEntry != null) {
                unawaited(_resume(videoEntry));
                return;
              }
              if (_sourceCatalogueSelected) {
                unawaited(_withSourceCatalogueItem(item, _playFeatured));
              } else {
                unawaited(_playFeatured(item));
              }
            }

            void menu(MediaItem item) => unawaited(
              showDesktopHomeMenu(
                context,
                title: item.title,
                actions: [
                  (
                    label: mode.isReading ? 'Read' : 'Play',
                    icon: mode.isReading ? 'book-open' : 'play',
                    run: () => play(item),
                  ),
                  (label: 'Details', icon: 'info', run: () => open(item)),
                  (
                    label: _myList.contains(item)
                        ? 'Remove from My List'
                        : 'Add to My List',
                    icon: 'bookmark',
                    run: () => unawaited(_myList.toggle(item)),
                  ),
                ],
              ),
            );
            // Catalogue choices for the hero's "Choose catalogue" menu; the
            // same list feeds the shell's catalogue switch (home-6).
            final catalogues = _desktopCatalogueChoices(mode);
            _publishDesktopCatalogues(catalogues);
            // Rebuilds when downloads change or the offline state flips, so the
            // saved-shows shelf appears and disappears by itself.
            return ListenableBuilder(
              listenable: Listenable.merge([
                sl<DownloadManager>(),
                sl<ChapterDownloadStore>().listenable(),
                BootConnectivity.instance.offline,
              ]),
              builder: (context, _) => DesktopHomePage(
              key: ValueKey(
                'desktop-home:${mode.name}:${ZModePrefs.streamKind.name}:${_sourceCatalogueSelected ? _sourceCatalogueSourceId : 'catalogue'}',
              ),
              offline: BootConnectivity.instance.offline.value,
              onDownloads: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const DownloadsScreen()),
              ),
              downloads: desktopHomeDownloads(
                collections: desktopDownloadCollections(
                  videos: sl<DownloadManager>().all,
                  chapters: sl<ChapterDownloadStore>().all(),
                ),
                reading: mode.isReading,
                open: (collection) => Navigator.of(
                  context,
                ).push(desktopDownloadCollectionRoute(collection)),
              ),
              // Reauthentication preserves the cached account and library. Capture
              // the data owner before awaiting a dialog that may outlive Home.
              onReconnect:
                  context.watch<AuthCubit>().state.isLoggedIn &&
                      context.watch<AuthCubit>().state.needsReconnect
                  ? () async {
                      final cubit = context.read<HomeCubit>();
                      final ok = await showReconnectDialog(context) ?? false;
                      if (ok && mounted && !cubit.isClosed) {
                        await cubit.load();
                      }
                    }
                  : null,
              reconnectLabel: context.l10n.reconnectToSync,
              featured: featured,
              sections: sections,
              // Settings > Home rows: order, visibility and reset.
              rows: _desktopHomeRows(state.rows, sections, mode),
              reading: mode.isReading,
              loading: loading,
              onVerify: verificationUrl == null
                  ? null
                  : () async {
                      final cubit = context.read<HomeCubit>();
                      final sourceKey = _sourceCatalogueSelected
                          ? _newDesktopSourceKey
                          : null;
                      await MihonExtensionService.solveCloudflare(
                        verificationUrl,
                      );
                      if (!mounted) return;
                      if (sourceKey != null) {
                        // A user can switch source while verification is open.
                        // Never invalidate or reload a different selection.
                        if (_sourceCatalogueSelected &&
                            _newDesktopSourceKey == sourceKey) {
                          setState(() => _newDesktopSourceKey = null);
                        }
                      } else if (!_sourceCatalogueSelected && !cubit.isClosed) {
                        await cubit.load(reset: true);
                      }
                    },
              error: error,
              meta: _heroMeta,
              playLabel: (item) {
                final video = historyFor(item);
                final reading = readingFor(item);
                if (mode.isReading) {
                  return reading?.chapterNumber == null
                      ? 'Read now'
                      : 'Continue Ch. ${reading!.chapterNumber}';
                }
                return video?.episodeNumber == null
                    ? 'Watch now'
                    : 'Continue E${video!.episodeNumber!.toInt()}';
              },
              onOpen: open,
              onPlay: play,
              onMenu: menu,
              onSection: (section) => _openSeeAll(
                section,
                sourceCatalogue: _sourceCatalogueSelected,
              ),
              onHistory: _openHistory,
              onReleases: () => _openNewEpisodes(releases),
              onRefresh: () async {
                if (_sourceCatalogueSelected) {
                  setState(() {
                    _newDesktopSourceKey = null;
                  });
                } else {
                  // No reset: a refresh keeps the rows on screen while it
                  // fetches, and keeps them if the fetch fails (offline).
                  await context.read<HomeCubit>().load();
                }
              },
              // home-10: the Continue block rebuilds on its own when the
              // store notifies and reads the fresh lists via resumeItems.
              resume: const [],
              continueListenable: store,
              resumeItems: () => mode.isReading
                  ? [
                      for (final e in store.reading(readType))
                        DesktopHomeResume(
                          title: e.title,
                          subtitle: e.chapterNumber == null
                              ? 'Resume chapter'
                              : 'Chapter ${e.chapterNumber}',
                          image: e.cover,
                          headers: e.coverHeaders,
                          progress: e.total > 0 ? e.pos / e.total : 0,
                          open: () => unawaited(_resumeReading(e)),
                          menu: () => unawaited(
                            showDesktopHomeMenu(
                              context,
                              title: e.title,
                              actions: [
                                (
                                  label: 'Continue reading',
                                  icon: 'book-open',
                                  run: () => unawaited(_resumeReading(e)),
                                ),
                                // home-8 B: the same handy actions as video.
                                (
                                  label: context.l10n.details,
                                  icon: 'info',
                                  run: () => _openDetail(_continueReadItem(e)),
                                ),
                                (
                                  label: context.l10n.readChapterFromStart,
                                  icon: 'rotate-cw',
                                  run: () => unawaited(_restartReading(e)),
                                ),
                                (
                                  label: context.l10n.markChapterRead,
                                  icon: 'check',
                                  run: () => unawaited(_markReadingDone(e)),
                                ),
                                (
                                  label: 'Remove from Continue',
                                  icon: 'history',
                                  // home-8 A: undoable.
                                  run: () => unawaited(
                                    _removeReadingFromContinue(e),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ]
                  : [
                      for (final e in store.watched)
                        DesktopHomeResume(
                          title: e.showTitle,
                          subtitle: e.episodeNumber == null
                              ? 'Resume playback'
                              : 'Episode ${e.episodeNumber!.toInt()}',
                          image: e.thumbnail ?? e.cover,
                          headers: e.coverHeaders,
                          progress: e.progress,
                          remaining: e.duration > e.position
                              ? '${(e.duration - e.position).inMinutes}m left'
                              : null,
                          open: () => unawaited(_resume(e)),
                          menu: () => unawaited(
                            showDesktopHomeMenu(
                              context,
                              title: e.showTitle,
                              actions: [
                                (
                                  label: 'Continue watching',
                                  icon: 'play',
                                  run: () => unawaited(_resume(e)),
                                ),
                                // home-8 B: Details, Restart and Mark watched.
                                (
                                  label: context.l10n.details,
                                  icon: 'info',
                                  run: () =>
                                      _openDetail(_continueWatchItem(e)),
                                ),
                                (
                                  label: context.l10n.restartEpisode,
                                  icon: 'rotate-cw',
                                  run: () => unawaited(_restartEpisode(e)),
                                ),
                                (
                                  label: context.l10n.markEpisodeWatched,
                                  icon: 'check',
                                  run: () => unawaited(_markEpisodeWatched(e)),
                                ),
                                (
                                  label: 'Remove from Continue',
                                  icon: 'history',
                                  // home-8 A: undoable.
                                  run: () => unawaited(
                                    _removeWatchFromContinue(e),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
              // home-7: every fresh release is passed (the page shows five
              // plus "+N more"), worded for the mode, with the poster menu.
              releases: [
                for (final entry in releases)
                  DesktopHomeRelease(
                    title: entry.item.title,
                    subtitle: mode.isReading
                        ? context.l10n.chapterNAvailable('${releasedCount(entry)}')
                        : context.l10n.episodeNAvailable('${releasedCount(entry)}'),
                    image: entry.item.cover,
                    headers: entry.item.coverHeaders,
                    open: () => _openTrackerEntry(entry),
                    menu: () => unawaited(
                      showDesktopHomeMenu(
                        context,
                        title: entry.item.title,
                        actions: [
                          (
                            label: context.l10n.details,
                            icon: 'info',
                            run: () => _openTrackerEntry(entry),
                          ),
                          if (releaseRow != null)
                            (
                              label: context.l10n.openTrackerList(releaseRow.trackerName),
                              icon: 'bookmark',
                              run: () => _openTrackerList(
                                releaseRow.trackerName,
                                WatchStatus.watching,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
              // Catalogue choice is accessed from the small hero overline.
              onCatalogue: () => unawaited(
                showDesktopHomeMenu(
                  context,
                  title: 'Choose catalogue',
                  actions: [
                    for (final choice in catalogues)
                      (
                        label: choice.label,
                        icon: choice.icon,
                        run: choice.run,
                      ),
                  ],
                ),
              ),
              ),
            );
          }

          if (_sourceCatalogueSelected) {
            final future = _newDesktopSourceRows(mode);
            return FutureBuilder<List<HomeSection>>(
              future: future,
              builder: (context, snap) => render(
                // home-11 B: while a refresh of the same source loads, keep
                // its last rows on screen (with the thin progress bar)
                // instead of emptying the page.
                snap.connectionState == ConnectionState.done
                    ? (snap.data ?? const [])
                    : (_lastDesktopSourceRows?.key == _newDesktopSourceKey
                          ? _lastDesktopSourceRows!.sections
                          : const []),
                loading: snap.connectionState != ConnectionState.done,
                sourceVerificationUrl: snap.error is CloudflareRequiredException
                    ? (snap.error as CloudflareRequiredException).url
                    : null,
                error: snap.error is CloudflareRequiredException
                    ? 'This source needs website verification.'
                    : snap.hasError
                    ? 'This source could not load. Refresh to try again.'
                    : null,
              ),
            );
          }
          return render(
            state.sections ?? const [],
            loading: state.loading,
            error: state.offline
                ? 'You appear to be offline.'
                : state.cloudflareUrl != null
                ? 'This source needs website verification.'
                : null,
          );
        },
      ),
    ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (sl<AppMode>().isTv) return const HomeScreenTv();
    // Local Continue Watching/Reading stays visible signed out; cloud sync
    // still needs an account.
    final authState = context.watch<AuthCubit>().state;
    final loggedIn = authState.isLoggedIn;
    // Session lapsed (logged-in from cache only) → cloud sync is silently off.
    final needsReconnect = loggedIn && authState.needsReconnect;

    return BlocListener<ActiveSourceCubit, String>(
      listenWhen: (prev, curr) => prev != curr,
      listener: (context, _) {
        if (!mounted) return;
        _metaCache.clear();
        _heroPrewarmed = false;
        // reset:true clears the old source's rows so the switch is visible
        // immediately (skeletons), even if the new source's home is slow.
        context.read<HomeCubit>().load(reset: true);
      },
      child: _isDesktop
          ? _buildNewDesktopHome()
          : Scaffold(
              backgroundColor: AppColors.bg,
              // Extend content behind the status bar; the floating header handles
              // its own SafeArea(bottom: false).
              body: Stack(
                children: [
                  // Adaptive colour: poster-tinted wash behind everything, only
                  // while the setting is on (Theme & colour → Adaptive colour).
                  if (ThemeController.adaptiveColour)
                    PosterTintLayer(notifier: _heroTint),
                  RefreshIndicator(
                    color: AppColors.accent,
                    onRefresh: () {
                      // Pull-to-refresh is the user saying "try again", so it also
                      // re-tests a session the startup check only assumed was dead
                      // (the "Reconnect to sync" banner). force: it must not sit out
                      // the cool-off when someone deliberately pulled.
                      if (sl.isRegistered<AuthCubit>()) {
                        unawaited(
                          sl<AuthCubit>().revalidateIfFlagged(force: true),
                        );
                      }
                      if (_sourceCatalogueSelected) {
                        return _sourceCatalogueController.refresh();
                      }
                      return context.read<HomeCubit>().load();
                    },
                    child: BlocBuilder<HomeCubit, HomeState>(
                      builder: (context, state) {
                        final sections =
                            state.sections ?? const <HomeSection>[];
                        // Which sections render as rows (the phone drops a
                        // non-repeating first section so the hero isn't duplicated
                        // right below itself) is decided by the cubit's merge now —
                        // providerRowSections in home_rows_composer.dart, moved
                        // verbatim from here. This build only branches on whether a
                        // load finished at all.
                        final showSkeletons = state.loading && sections.isEmpty;
                        // The load finished but the source returned no rows — almost
                        // always a dead/blocked site (or a search-only source). Show a
                        // clear message instead of a blank screen.
                        final loadedEmpty =
                            !state.loading &&
                            state.sections != null &&
                            state.sections!.isEmpty;
                        // Manga/novel with nothing installed: the mode-switch fallback
                        // sets a matching source when one exists, so a reading mode
                        // still on a non-matching (usually stale anime) active id means
                        // nothing's installed for it — show the install guide and drop
                        // the leaking anime rows/hero. Cheap DI-free prefix check, so
                        // it's safe to run every build (unlike categorizedSources()).
                        // Anime's own zero-source case (skipped setup) has no source to
                        // load and flows through `loadedEmpty` → HomeLoadedEmptyView.
                        // Z Mode manga/novel rows come from AniList, not an installed
                        // `mihon:`/`lnr:` source, so the active-source prefix check
                        // would wrongly call a fetch that just succeeded "no sources".
                        final activeId = context
                            .read<ActiveSourceCubit>()
                            .state;
                        final noSourceForMode =
                            _sourceCatalogueSelected || ZModePrefs.enabled
                            ? false
                            : switch (sl<ContentModeCubit>().state) {
                                ContentMode.manga =>
                                  !sourceIdMatchesContentMode(
                                    activeId,
                                    ContentMode.manga,
                                  ),
                                ContentMode.novel =>
                                  !sourceIdMatchesContentMode(
                                    activeId,
                                    ContentMode.novel,
                                  ),
                                ContentMode.anime => false,
                              };
                        return Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: _isDesktop ? 20 : 0,
                          ),
                          child: CustomScrollView(
                            slivers: [
                              SliverToBoxAdapter(
                                child: Builder(
                                  builder: (context) {
                                    final heroItems = _sourceCatalogueSelected
                                        ? _sourceCatalogueHeroItems
                                        : state.heroItems;
                                    final hasHero = heroItems.isNotEmpty;
                                    if (hasHero) _prewarmHeroMeta(heroItems);
                                    // No hero (loading / empty / no source):
                                    // clear any wash left over from the last
                                    // poster.
                                    if (!hasHero || noSourceForMode) {
                                      _clearHeroTintSoon();
                                    }

                                    return HomeBannerHeader(
                                      headerAboveBanner: _isDesktop,
                                      bannerStyle: BannerStyle.current,
                                      hasHero: hasHero && !noSourceForMode,
                                      bannerBuilder: (bannerId) =>
                                          _featuredBanner(bannerId, heroItems),
                                      headerBuilder: (edgeBanner) =>
                                          _buildHeader(edgeBanner: edgeBanner),
                                    );
                                  },
                                ),
                              ),

                              // Mode shortcuts and Genres.
                              SliverToBoxAdapter(child: _modeCards()),

                              // ── Reconnect banner (session lapsed → sync is off) ───────
                              if (needsReconnect)
                                SliverToBoxAdapter(child: _reconnectBanner()),

                              // ── The arrangement ─────────────────────────────────────
                              // state.rows is the merged view of this load: the local
                              // Continue row, the tracker rows the user enabled, and the
                              // provider sections, in the saved order (Settings →
                              // Interface → Appearance → Home rows). ContinueSection renders wherever
                              // the layout puts it — the same widgets as before, just
                              // arranged. Before the first merge lands (rows null), the
                              // ContinueSection keeps its old spot above the skeletons
                              // so the loading screen is exactly today's.
                              if (state.rows case final rows?)
                                if (_sourceCatalogueSelected)
                                  ..._sourceCatalogueHomeSlivers(rows)
                                else
                                  ...rows.map(_homeRowSliver)
                              else ...[
                                ContinueSection(
                                  onResume: _resume,
                                  onLongPress: _showContinueInfo,
                                  onSeeAll: _openHistory,
                                  onResumeReading: _resumeReading,
                                  onLongPressReading: _showContinueReadingInfo,
                                ),
                                if (_sourceCatalogueSelected)
                                  _sourceCatalogueHomeSliver(),
                              ],

                              // ── Skeletons while the first load runs / empty states ───
                              // The provider rows themselves are part of state.rows
                              // above; this branch only owns the loading placeholders
                              // and the "nothing came back" views.
                              if (!_sourceCatalogueSelected &&
                                  showSkeletons &&
                                  !noSourceForMode)
                                ...List.generate(
                                  3,
                                  (_) => const SliverToBoxAdapter(
                                    child: RowSkeleton(),
                                  ),
                                )
                              else if (!_sourceCatalogueSelected &&
                                  (noSourceForMode || loadedEmpty))
                                SliverFillRemaining(
                                  hasScrollBody: false,
                                  child: HomeLoadedEmptyView(
                                    offline: state.offline,
                                    mode: sl<ContentModeCubit>().state,
                                    // Name whatever ACTUALLY answered: in Z Mode the
                                    // rows come from AniList/MAL/TMDB/Simkl, not the
                                    // active source, so blaming the source was simply
                                    // pointing at the wrong thing. The router hands
                                    // back the right name in either mode.
                                    sourceName: _repo.displayName(
                                      _repo.sourceId,
                                    ),
                                    // A metadata catalogue, not an installed source —
                                    // the "switch source at the top" advice does not
                                    // apply to it.
                                    isMetadataProvider:
                                        _repo.sourceId == ZmodeIds.sourceId,
                                    rateLimitedSeconds:
                                        state.rateLimitedSeconds,
                                    onRetry: () => context
                                        .read<HomeCubit>()
                                        .load(reset: true),
                                    // No-source guide points at the Providers hub (all
                                    // ecosystems); the source-returned-nothing case
                                    // (_SourceUnavailable) keeps its retry.
                                    onInstallSources: () =>
                                        Navigator.of(context).push(
                                          MaterialPageRoute<void>(
                                            // src-3: desktop settings look on
                                            // Windows (pass-through elsewhere).
                                            builder: (_) =>
                                                const DesktopProviderScope(
                                                  child: ProvidersHubScreen(),
                                                ),
                                          ),
                                        ),
                                    // Cloudflare-blocked source: solve, then reload after
                                    // the user closes the WebView.
                                    cloudflareUrl: state.cloudflareUrl,
                                    onSolveCloudflare:
                                        state.cloudflareUrl == null
                                        ? null
                                        : () async {
                                            if (_repo.sourceId.startsWith(
                                              'mg:',
                                            )) {
                                              await MangayomiCloudflare.solve(
                                                state.cloudflareUrl!,
                                              );
                                            } else {
                                              await MihonExtensionService.solveCloudflare(
                                                state.cloudflareUrl!,
                                              );
                                            }
                                            if (context.mounted) {
                                              context.read<HomeCubit>().load(
                                                reset: true,
                                              );
                                            }
                                          },
                                  ),
                                ),

                              // ── Bottom padding ────────────────────────────────────────
                              // Clear the floating dock, which overlays content (the
                              // shell's extendBody reserves it no space of its own).
                              SliverToBoxAdapter(
                                child: SizedBox(
                                  height: MediaQuery.paddingOf(context).bottom,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                  if (_slashing) _slashOverlay(),
                ],
              ),
            ),
    );
  }
}

/// Header download shortcut → [DownloadsScreen]. Hidden while Downloads is
/// a dock tab, so the bar and the header never offer it twice — same rule
/// as [HomeSearchAction].
class HomeDownloadsAction extends StatelessWidget {
  const HomeDownloadsAction({super.key, this.edgeBanner = false});

  final bool edgeBanner;

  @override
  Widget build(BuildContext context) {
    // Bare NavPrefs reads no Hive box and returns the default dock (no
    // Downloads) — the same guard the shell uses for widget tests.
    final prefs = sl.isRegistered<NavPrefs>() ? sl<NavPrefs>() : NavPrefs();
    return ListenableBuilder(
      listenable: prefs,
      builder: (context, _) => prefs.tabs.contains(DockTab.downloads)
          ? const SizedBox.shrink()
          : IconButton(
              icon: DockIcon(
                DockGlyph.download,
                color: edgeBanner ? Colors.white : AppColors.textSecondary,
                size: 22,
              ),
              tooltip: context.l10n.downloads,
              style: edgeBanner ? _edgeHeaderButtonStyle() : null,
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const DownloadsScreen(),
                ),
              ),
            ),
    );
  }
}

/// Opens [SearchScreen] — the Home header way in. Hidden while Search is a
/// dock tab, so the bar and the header never offer it twice. Normally Search
/// follows Z Mode; Home passes [fixedSourceId] when its Source Catalogue is
/// selected so the query stays on that source.
class HomeSearchAction extends StatelessWidget {
  const HomeSearchAction({
    super.key,
    this.edgeBanner = false,
    this.fixedSourceId,
  });

  final bool edgeBanner;
  final String? fixedSourceId;

  @override
  Widget build(BuildContext context) {
    // Bare NavPrefs reads no Hive box and returns the default dock (no
    // Search) — the same guard the shell uses for widget tests.
    final prefs = sl.isRegistered<NavPrefs>() ? sl<NavPrefs>() : NavPrefs();
    return ListenableBuilder(
      listenable: prefs,
      builder: (context, _) => prefs.tabs.contains(DockTab.search)
          ? const SizedBox.shrink()
          : IconButton(
              icon: DockIcon(
                DockGlyph.search,
                color: edgeBanner ? Colors.white : AppColors.textSecondary,
                size: 22,
              ),
              tooltip: context.l10n.search,
              style: edgeBanner ? _edgeHeaderButtonStyle() : null,
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SearchScreen(fixedSourceId: fixedSourceId),
                ),
              ),
            ),
    );
  }
}

ButtonStyle _edgeHeaderButtonStyle() => IconButton.styleFrom(
  backgroundColor: Colors.black.withValues(alpha: 0.5),
  shape: const CircleBorder(),
);

/// The header's source switcher. Hidden while Z Mode is on — the active
/// source doesn't affect anything on screen there (Home is metadata-driven)
/// and the control would be misleading. Shown with Z Mode off, where Home is
/// source-driven and this is how you change which one.
///
/// Reactive to [ZModePrefs.revision] (a [ValueListenableBuilder], not a
/// listener on [_HomeViewState]) so flipping the toggle updates this
/// immediately without needing the rest of Home to rebuild.
///
/// Extracted as its own widget — rather than inlined in [_HomeViewState]'s
/// build — so this is testable without pumping the real [HomeScreen], whose
/// `initState` fires a real network call.
class HomeSourceSwitcherSlot extends StatelessWidget {
  const HomeSourceSwitcherSlot({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: ZModePrefs.revision,
      builder: (context, _, _) => !ZModePrefs.enabled
          ? BlocBuilder<ActiveSourceCubit, String>(
              builder: (context, id) => SourceSwitcher(
                currentId: id,
                onChanged: (newId) =>
                    context.read<ActiveSourceCubit>().setSource(newId),
                trailingBuilder: (sourceId) => SourcePickerRowActions(
                  sourceId: sourceId,
                  onCloudflareSolved: (solvedId) async {
                    if (!context.mounted ||
                        context.read<ActiveSourceCubit>().state != solvedId) {
                      return;
                    }
                    await context.read<HomeCubit>().load(reset: true);
                  },
                ),
                onInstallSources: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        const ZangetsuSourcesScreen(openToRepos: true),
                  ),
                ),
              ),
            )
          : const SizedBox.shrink(),
    );
  }
}

/// Home's "provider returned no sections" branch. A reading mode with
/// literally nothing installed for it gets a message that says so, with an
/// action into the install flow — today's [_SourceUnavailable] ("couldn't
/// load, try again") is flat wrong there, since nothing failed, there's just
/// nothing set up. Anime mode (and a reading mode whose installed source
/// failed to load) keeps [_SourceUnavailable] exactly as before.
///
/// Extracted as its own widget — rather than inlined in [_HomeViewState]'s
/// build — so this decision is testable without pumping the real
/// [HomeScreen], whose `initState` fires a real network call.
class HomeLoadedEmptyView extends StatelessWidget {
  const HomeLoadedEmptyView({
    super.key,
    required this.mode,
    required this.sourceName,
    required this.onRetry,
    required this.onInstallSources,
    this.cloudflareUrl,
    this.onSolveCloudflare,
    this.cloudflareUnsupported = false,
    this.offline = false,
    this.isMetadataProvider = false,
    this.rateLimitedSeconds,
  });

  final ContentMode mode;
  final String sourceName;

  /// Whether [sourceName] is a metadata catalogue (AniList, TMDB…) rather than
  /// an installed source. They fail the same way but the remedy differs, and
  /// telling someone to "switch source at the top" when the catalogue is down
  /// points at a control that has nothing to do with it.
  final bool isMetadataProvider;

  /// Seconds until it will answer again, when the failure was a rate limit.
  final int? rateLimitedSeconds;
  final VoidCallback onRetry;

  /// Nothing reached the network. Takes priority over the no-sources guide:
  /// offering to install extensions is useless advice when the problem is the
  /// connection, and it is the wrong thing to blame.
  final bool offline;
  final VoidCallback onInstallSources;

  /// Non-null when the active source is blocked by a Cloudflare challenge;
  /// [onSolveCloudflare] opens the visible solve WebView and reloads after.
  final String? cloudflareUrl;
  final Future<void> Function()? onSolveCloudflare;
  final bool cloudflareUnsupported;

  @override
  Widget build(BuildContext context) {
    // A Cloudflare block takes priority over the no-sources guide: the source
    // IS installed, it's just gated behind a challenge the user can solve.
    if (cloudflareUrl != null &&
        (onSolveCloudflare != null || cloudflareUnsupported)) {
      return _SourceUnavailable(
        sourceName: sourceName,
        onRetry: onRetry,
        onSolveCloudflare: onSolveCloudflare,
        cloudflareUnsupported: cloudflareUnsupported,
      );
    }
    if (offline) {
      return _SourceUnavailable(
        sourceName: sourceName,
        onRetry: onRetry,
        offline: true,
      );
    }
    // Metadata catalogue (Z Mode) browses AniList/TMDB/MAL — installed
    // streaming extensions are only needed at play time, so an empty home
    // here means the catalogue fetch failed, not "nothing installed". His
    // guard, kept on top of this screen.
    if (!ZModePrefs.enabled && !hasSourcesFor(mode)) {
      return _NoSourcesGuide(mode: mode, onBrowse: onInstallSources);
    }
    return _SourceUnavailable(
      sourceName: sourceName,
      onRetry: onRetry,
      offline: offline,
      isMetadataProvider: isMetadataProvider,
      rateLimitedSeconds: rateLimitedSeconds,
    );
  }
}

/// Friendly "nothing installed for this mode yet" state — a mode-aware icon in
/// a soft accent circle, a warm one-liner, and a single rounded button into
/// Providers. Replaces the bare [EmptyState] so an empty manga/novel/streaming
/// home reads as "let's set this up" rather than an error.
class _NoSourcesGuide extends StatelessWidget {
  const _NoSourcesGuide({required this.mode, required this.onBrowse});

  final ContentMode mode;
  final VoidCallback onBrowse;

  @override
  Widget build(BuildContext context) {
    final label = mode.label; // Streaming / Manga / Novel
    final (icon, noun) = switch (mode) {
      ContentMode.anime => (Icons.live_tv_rounded, 'shows'),
      ContentMode.manga => (Icons.auto_stories_rounded, 'manga'),
      ContentMode.novel => (Icons.menu_book_rounded, 'novels'),
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(40, 24, 40, 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 104,
              height: 104,
              decoration: BoxDecoration(
                color: AppColors.accent.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 46, color: AppColors.accent),
            ),
            const SizedBox(height: 22),
            Text(
              'No $label sources yet',
              textAlign: TextAlign.center,
              style: AppText.headline.copyWith(fontSize: 20),
            ),
            const SizedBox(height: 10),
            Text(
              'Add a source from Providers and your $noun will show up here.',
              textAlign: TextAlign.center,
              style: AppText.body.copyWith(
                color: AppColors.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 26),
            FilledButton.icon(
              onPressed: onBrowse,
              icon: const Icon(Icons.add_rounded, size: 20),
              label: Text(context.l10n.browseSources),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 26,
                  vertical: 13,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(28),
                ),
                textStyle: AppText.button.copyWith(color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown on Home when the active source finished loading but returned no rows —
/// typically a dead/blocked site. Offers a retry and points to the source
/// switcher. Continue Watching (app-side) still renders above this.
class _SourceUnavailable extends StatelessWidget {
  const _SourceUnavailable({
    required this.sourceName,
    required this.onRetry,
    this.onSolveCloudflare,
    this.cloudflareUnsupported = false,
    this.offline = false,
    this.isMetadataProvider = false,
    this.rateLimitedSeconds,
  });

  final String sourceName;
  final VoidCallback onRetry;

  /// See [HomeLoadedEmptyView.isMetadataProvider].
  final bool isMetadataProvider;

  /// See [HomeLoadedEmptyView.rateLimitedSeconds].
  final int? rateLimitedSeconds;

  /// The request never left the device. Says so instead of blaming the source
  /// — telling someone in a tunnel that their extension is down is how people
  /// end up reinstalling working extensions.
  final bool offline;

  /// When set, this is a Cloudflare block (not a generic outage): show a shield
  /// + a primary "Solve Cloudflare" action that opens the visible solve WebView.
  final Future<void> Function()? onSolveCloudflare;
  final bool cloudflareUnsupported;

  static const Color _cloudflareOrange = Color(0xFFF48120);

  @override
  Widget build(BuildContext context) {
    final isCloudflare = onSolveCloudflare != null || cloudflareUnsupported;
    return Padding(
      padding: const EdgeInsets.fromLTRB(36, 40, 36, 56),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              color: isCloudflare
                  ? _cloudflareOrange.withValues(alpha: 0.14)
                  : AppColors.surface,
              shape: BoxShape.circle,
            ),
            child: Icon(
              isCloudflare
                  ? Icons.shield_rounded
                  : offline
                  ? Icons.wifi_off_rounded
                  : Icons.cloud_off_rounded,
              size: 40,
              color: isCloudflare ? _cloudflareOrange : AppColors.textTertiary,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            isCloudflare
                ? '$sourceName is protected by Cloudflare'
                : offline
                ? context.l10n.offlineTitle
                : rateLimitedSeconds != null
                ? context.l10n.providerNeedsBreather(sourceName)
                : isMetadataProvider
                ? context.l10n.providerHavingAMoment(sourceName)
                : context.l10n.sourceNotAnswering(sourceName),
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            isCloudflare
                ? cloudflareUnsupported
                      ? 'Cloudflare verification for Mangayomi sources is not '
                            'available on iOS yet. Unprotected sources still work.'
                      : 'Complete the Cloudflare check once and this source will '
                            'load normally from then on.'
                : offline
                ? "Nothing could reach the network. Check your connection "
                      "and try again — $sourceName is probably fine."
                : rateLimitedSeconds != null
                ? context.l10n.providerNeedsBreatherBody(rateLimitedSeconds!)
                : isMetadataProvider
                ? context.l10n.providerHavingAMomentBody
                : context.l10n.sourceNotAnsweringBody,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 14,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 24),
          if (isCloudflare) ...[
            if (!cloudflareUnsupported) ...[
              ElevatedButton.icon(
                onPressed: () => onSolveCloudflare!(),
                icon: const Icon(Icons.shield_rounded, size: 20),
                label: Text(context.l10n.solveCloudflare),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _cloudflareOrange,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 30,
                    vertical: 13,
                  ),
                  textStyle: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(26),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              TextButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: Text(context.l10n.retry),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.textSecondary,
                ),
              ),
            ],
          ] else
            ElevatedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 20),
              label: Text(context.l10n.retry),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(
                  horizontal: 30,
                  vertical: 13,
                ),
                textStyle: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(26),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The reader `_resumeReading` pushes for a resumed
/// [ReadEntry]: [MangaReaderScreen] for [ProviderType.manga], otherwise
/// [NovelReaderScreen] (novel, and [ReadEntry.type]'s legacy-row default).
/// Pulled out as a plain top-level function so the routing decision is
/// testable without pumping the whole [HomeScreen] (whose initState makes a
/// real update-check network call and opens community/announcement Hive
/// boxes).
Widget readerFor(ReadEntry e, Episode chapter) {
  if (e.type == ProviderType.manga) {
    return MangaReaderScreen(
      sourceId: e.sourceId,
      showId: e.showId,
      showUrl: e.detailUrl,
      showTitle: e.title,
      cover: e.cover,
      chapters: [chapter],
      startIndex: 0,
      resolveChapters: true,
    );
  }
  return NovelReaderScreen(
    sourceId: e.sourceId,
    showId: e.showId,
    showUrl: e.detailUrl,
    showTitle: e.title,
    cover: e.cover,
    chapters: [chapter],
    startIndex: 0,
    resolveChapters: true,
  );
}

/// The "nothing is being recorded" badge, shown only while incognito is on.
///
/// Accent-tinted, not grey. It marks an ACTIVE mode, and in this app's colour
/// language grey-on-grey is what a disabled control looks like — the opposite
/// of what this means. It also has to hold its own beside the wordmark and
/// four actions, which a low-contrast pill wedged against the logo did not.
///
/// Tap anywhere on it to leave incognito.
class _IncognitoChip extends StatelessWidget {
  const _IncognitoChip();

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: IncognitoMode.notifier,
    builder: (context, on, _) {
      if (!on) return const SizedBox.shrink();
      final l10n = context.l10n;
      return Padding(
        // Its own breathing room. The old chip carried a right margin only, so
        // it sat flush against the wordmark.
        padding: const EdgeInsetsDirectional.only(start: 10, end: 6),
        child: Tooltip(
          message: l10n.incognitoMode,
          child: GestureDetector(
            onTap: () => IncognitoMode.set(false),
            behavior: HitTestBehavior.opaque,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AppColors.accentSoft,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: AppColors.accent.withValues(alpha: 0.35),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.visibility_off_rounded,
                      size: 14,
                      color: AppColors.accent,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      l10n.incognito,
                      style: TextStyle(
                        fontFamily: AppText.fontFamily,
                        fontFamilyFallback: AppText.fontFamilyFallback,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2,
                        color: AppColors.accent,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
