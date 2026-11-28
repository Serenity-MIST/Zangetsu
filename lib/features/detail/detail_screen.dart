import 'desktop_existing_downloads.dart';
import 'desktop_source_pick.dart';
import 'desktop_offline_episodes.dart';
import 'desktop_batch_download_dialog.dart';
import 'desktop_single_download_dialog.dart';
import 'download_source_lookup.dart';
import '../downloads/download_size_preview.dart';
import '../../core/download/download_server_preference.dart';
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:hive_flutter/hive_flutter.dart';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cue/cue.dart';
import 'package:flutter/cupertino.dart' show CupertinoPicker;
import 'package:flutter/foundation.dart'
    show ValueListenable, defaultTargetPlatform, TargetPlatform, listEquals;
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:video_player/video_player.dart' as preview;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/zmode/season_chain.dart';
import '../../core/zmode/metadata_provider_prefs.dart';
import '../../core/ui/adaptive_layout.dart';
import '../../core/ui/poster_card.dart';
import '../../core/metadata/title_badges.dart';
import 'letterbox_detector.dart';
import '../../core/ui/backdrop_focus.dart';
import '../../core/ui/image_fade.dart';
import '../../core/ui/detail_prefs.dart';
import '../../core/ui/poster_palette.dart';
import '../../core/ui/mobile_hero_art.dart';
import '../../core/ui/tmdb_hero_banner.dart';
import '../../core/ui/progressive_artwork.dart';
import '../../core/metadata/synopsis.dart';
import '../../core/models/film.dart';
import '../../core/mode/content_mode_cubit.dart';
import '../../core/zmode/metadata_filters.dart';
import '../../core/zmode/zmode_module.dart';
import '../../core/zmode/zmode_prefs.dart';
import '../../core/theme/theme_controller.dart';
import '../../core/ui/app_dialog.dart';
import '../../core/ui/app_toast.dart';
import '../../core/download/download_size_estimate.dart';
import '../../core/download/download_prefs.dart';
import '../../core/download/windows_download_storage.dart';
import '../../core/storage/storage_info.dart';
import 'open_related.dart';
import '../../core/ui/episode_unavailable_dialog.dart';
import '../../core/zmode/playback_resolver.dart';
import 'episode_sources_sheet.dart';
import '../downloads/downloads_screen.dart';
import '../downloads/episode_download_icon.dart';
import '../downloads/episode_download_source_sheet.dart';
import '../auth/auth_cubit.dart';
import 'epub_export_sheet.dart';
import 'chapter_download_range_sheet.dart';
import 'stremio_episode_links_sheet.dart';
import 'chapter_download_selection.dart';
import '../../core/ui/jump_prompt.dart';
import '../../core/app_mode.dart';
import '../../core/cache/app_image_cache.dart';
import '../../core/di/injector.dart';
import '../../core/discord/discord_rpc.dart';
import '../../core/mihon/mihon_extension_service.dart';
import '../../core/mangayomi/mangayomi_cloudflare.dart';
import '../../core/metadata/episode_metadata_service.dart';
import '../../core/metadata/metadata_enrichment.dart';
import '../../core/metadata/title_logo_service.dart';
import '../../core/notify/cs_notify.dart';
import '../../core/notify/notification_service.dart';
import '../../core/notify/subscription_store.dart';
import '../../core/share/share_link.dart';
import '../../core/download/chapter_download.dart';
import '../../core/download/chapter_download_store.dart';
import '../../core/download/chapter_downloader.dart';
import '../../core/download/download_manager.dart';
import '../../core/download/download_record.dart';
import '../../core/mode/content_mode.dart';
import '../../core/models/episode.dart';
import '../../core/models/episode_title.dart';
import '../../core/models/media_detail.dart';
import 'chapter_meta.dart';
import '../../core/tv/tv_episode_range_chips.dart';
import 'episode_filter.dart';
// The Episodes header's "Select" button (not in episode_filter's re-export).
import 'detail_episodes_desktop.dart' show EpisodeSelectButton;
import 'desktop_hover_link.dart';
import '../player/desktop_floating_player.dart';
import '../player/player_lifecycle.dart';
import 'trailer_route_lifecycle.dart';
import '../../core/models/media_item.dart';
import '../../core/models/media_extras.dart';
import '../../core/models/person.dart';
import '../home/search_screen.dart';
import 'title_search_popup.dart';
import '../people/person_page.dart';
import '../../core/models/video_source.dart';
import '../../core/models/provider_info.dart';
import '../../core/models/watch_status.dart';
import '../../core/playback/filler_service.dart';
import '../../core/playback/list_status_store.dart';
import '../../core/privacy/incognito_mode.dart';
import '../../core/playback/my_list.dart';
import '../../core/playback/library_repair.dart';
import '../../core/ui/episode_player_sheet.dart';
import '../../core/ui/list_status_sheet.dart';
import '../../core/ui/tracker_list_sheet.dart';
import '../../core/ui/tracker_sync_sheet.dart';
import '../../core/tracker/airing_countdown.dart';
import '../../core/tracker/tracker.dart';
import '../../core/tracker/tracker_binding_store.dart';
import '../../core/tracker/tracker_hub.dart';
import '../../core/stremio/stremio_manager.dart';
import '../../core/stremio/stremio_ref.dart';
import '../../core/stremio/stremio_stream_mapping.dart';
import '../../core/playback/playback_prefs.dart';
import '../player/mpv_player_pool.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/title_prefs.dart';
import '../../core/playback/watch_history.dart';
import '../../core/provider/cf_solve_needed.dart';
import '../../core/provider/cloudstream_provider.dart';
import '../../core/provider/provider_manager.dart';
import '../../core/provider/provider_registry.dart';
import '../../core/reading/chapter_nav.dart';
import '../../core/reading/read_history.dart';
import '../../core/reading/read_store.dart';
import '../../core/reading/reading_resume.dart';
import '../../core/logging/app_logger.dart';
import '../../core/repository/catalogue_repository.dart';
import '../../core/repository/source_actions.dart' as source_actions;
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/trailer/trailer_service.dart';
import '../../core/tv/tv_back_button.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/tv/tv_list_focusable.dart';
import '../../core/zmode/metadata_repository.dart';
import '../../core/zmode/source_matcher.dart';
import '../../core/ui/source_switcher.dart';
import '../sources/zangetsu_sources_screen.dart';
import '../../core/zmode/match_store.dart';
import '../../core/zmode/zmode_ids.dart';
import '../../core/aniyomi/aniyomi_image_provider.dart';
import '../../core/mihon/mihon_image_provider.dart';
import '../../core/ui/badge.dart';
import '../../core/ui/route_observer.dart';
import '../../core/ui/states.dart';
import '../player/player_screen.dart';
import '../player/episode_player_route.dart';
import '../player/tv_playback_launch.dart';
import '../reader/manga_reader_screen.dart';
import '../reader/novel_reader_screen.dart';
import '../trailer/trailer_screen.dart';
import 'cubit/detail_cubit.dart';
import 'wrong_title_sheet.dart';
import 'desktop_detail_actions.dart';
import '../../core/download/downloaded_show_details.dart';
// Windows desktop helpers: right-click menus, confirm dialogs, Explorer
// reveal and the remappable page shortcuts.
import '../../core/desktop/desktop_focus_repair.dart';
import '../../core/desktop/desktop_context_menu.dart';
import '../../core/desktop/desktop_dialogs.dart';
import '../../core/desktop/desktop_reveal.dart';
import '../../core/desktop/desktop_shortcuts.dart';
// src-11: "Source timed out" wording for the Windows load-failure banner.
import '../../core/desktop/source_timeout.dart';
import '../../l10n/l10n.dart';

part 'detail_hero.dart';
part 'detail_native_trailer.dart';
part 'detail_info.dart';
part 'detail_episodes.dart';
part 'detail_sheets.dart';
part 'detail_tabs.dart';
part 'detail_skeleton.dart';

part 'detail_screen_tv.dart';

Future<void> _changeEpisodeVersion(
  BuildContext context,
  String category,
) async {
  final switched = await context.read<DetailCubit>().setCategory(category);
  if (!switched && context.mounted) {
    showAppToast(context, context.l10n.somethingWentWrong);
  }
}

/// Windows desktop layout/behaviour gate. Uses the target platform rather than
/// the host OS so phone widget tests run on a Windows machine (Android
/// target) still take the phone path, while the real Windows app is unchanged.
bool get _windowsDesktopUi => defaultTargetPlatform == TargetPlatform.windows;

/// Last-resort friendly name for a [sourceId] that's neither a loaded JS nor CS
/// provider (e.g. its source was uninstalled): drop the `cs:` prefix and the
/// `@version@tag` file-id suffix so the detail screen never shows "cs:X@31".
String _friendlySourceId(String sourceId) {
  var s = sourceId.startsWith('cs:')
      ? sourceId.substring(3)
      : sourceId.startsWith('ani:')
      ? sourceId.substring(4)
      : sourceId;
  final at = s.indexOf('@');
  if (at > 0) s = s.substring(0, at);
  return s;
}

/// "Source · Repo" label for the detail screen, so the user can see which repo
/// a source came from. Falls back to just the name when no repo is resolvable.
/// The catalogue behind a recorded origin name, or null when it names a source
/// (or a provider this build does not know).
PreferredProvider? _preferFromName(String? name) => switch (name) {
  'AniList' => PreferredProvider.anilist,
  'MyAnimeList' => PreferredProvider.mal,
  'TMDB' => PreferredProvider.tmdb,
  'Simkl' => PreferredProvider.simkl,
  _ => null,
};

String _sourceLabel(
  String sourceId, {
  String? url,
  PreferredProvider? prefer,
  String? savedFrom,
}) {
  // Zangetsu Mode's pseudo source: the provider that answers for THIS title,
  // not the raw "zm" id — and keyed on the title's own kind, since the mode
  // you happen to be browsing in may be a different one entirely.
  if (sourceId == ZmodeIds.sourceId) {
    // A title opened from a tracker is READ from that tracker's catalogue, so
    // the name has to follow the same rule — otherwise the page says
    // MyAnimeList over data that came from AniList.
    switch (prefer) {
      case PreferredProvider.anilist:
        return 'AniList';
      case PreferredProvider.mal:
        return 'MyAnimeList';
      case PreferredProvider.tmdb:
        return 'TMDB';
      case PreferredProvider.simkl:
        return 'Simkl';
      case null:
        break;
    }
    // What it was saved from beats the current setting: your list should not
    // relabel itself because you changed provider afterwards.
    if (savedFrom != null && savedFrom.isNotEmpty) return savedFrom;
    final repo = sl<MetadataRepository>();
    final c = url == null ? null : ZmodeIds.parseShow(url);
    return c == null ? repo.displayName(sourceId) : repo.nameForKind(c.kind);
  }
  // Aniyomi sources (ani:<id>) resolve to their extension's display name;
  // otherwise the detail screen would show the raw "ani:4383278740…" id.
  if (sourceId.startsWith('ani:')) {
    final name = sl<SourceRepository>().displayName(sourceId);
    return name == sourceId ? _friendlySourceId(sourceId) : name;
  }
  final js = sl<ProviderRegistry>().entryFor(sourceId);
  if (js != null) {
    final name = js.displayName.isNotEmpty ? js.displayName : js.name;
    final repo = _repoLabelFromUrl(js.originRepoUrl);
    return repo != null ? '$name · $repo' : name;
  }
  final cs = sl<CloudStreamManager>().get(sourceId);
  if (cs is CloudStreamProvider) {
    // A disambiguated source's displayName already carries its repo tag, so
    // don't append the repo twice.
    final repo = cs.disambiguate
        ? null
        : sl<CloudStreamManager>().repoNameForSourceId(sourceId);
    return repo != null ? '${cs.displayName} · $repo' : cs.displayName;
  }
  return cs?.displayName ?? _friendlySourceId(sourceId);
}

/// Short repo label from a manifest URL (GitHub repo name, else owner, else
/// host). Null for bundled/blank URLs. Mirrors the source switcher's logic.
String? _repoLabelFromUrl(String? repoUrl) {
  if (repoUrl == null || repoUrl.isEmpty || repoUrl.startsWith('bundled://')) {
    return null;
  }
  try {
    final u = Uri.parse(repoUrl);
    final segs = u.pathSegments.where((s) => s.isNotEmpty).toList();
    if (u.host.contains('github')) {
      if (segs.length >= 2) return segs[1];
      if (segs.isNotEmpty) return segs.first;
    }
    return u.host.isEmpty ? null : u.host;
  } catch (_) {
    return null;
  }
}

/// Shown instead of the detail body when the title's source needs a
/// Cloudflare challenge solved — the Detail-path counterpart of Home's
/// Cloudflare-blocked state (`_SourceUnavailable` in home_screen.dart), so a
/// title opened from AniList/TMDB (Z Mode) offers the same solve instead of
/// failing silently. Uses the SAME solver Home does and reloads on success.
class _DetailCloudflareBlocked extends StatefulWidget {
  const _DetailCloudflareBlocked({
    required this.url,
    this.isMangayomi = false,
    this.canonical,
    this.title,
    this.altTitle,
    this.malId,
  });

  final String url;

  /// Mangayomi (`mg:`) sources keep their own cookie jar, so they need
  /// MangayomiCloudflare's solver rather than the shared source verifier.
  final bool isMangayomi;

  /// Windows: the title's catalogue match, shown for manga so another source
  /// can be picked. The remaining fields describe the same title.
  final ZCanonical? canonical;
  final String? title;
  final String? altTitle;
  final int? malId;

  @override
  State<_DetailCloudflareBlocked> createState() =>
      _DetailCloudflareBlockedState();
}

class _DetailCloudflareBlockedState extends State<_DetailCloudflareBlocked> {
  static const Color _cloudflareOrange = Color(0xFFF48120);

  bool _solving = false;

  Future<void> _solve() async {
    setState(() => _solving = true);
    // Matching flags both JS and native providers. Send the solved session
    // to the cookie jar used by the source that raised the challenge.
    final host = Uri.tryParse(widget.url)?.host ?? '';
    if (_windowsDesktopUi) {
      // Windows: show why a verification browser failed instead of letting
      // the error escape, and reload only after it really passed.
      try {
        final verified = await source_actions
            .verifySourceChallengeWithFeedback(
              context,
              widget.isMangayomi
                  ? (CfSolveNeeded.sourceForHost(host) ?? 'mg:')
                  : (CfSolveNeeded.sourceForHost(host) ?? ''),
              widget.url,
            );
        if (mounted && verified) context.read<DetailCubit>().load();
      } finally {
        if (mounted) setState(() => _solving = false);
      }
      return;
    }
    if (widget.isMangayomi) {
      await MangayomiCloudflare.solve(widget.url);
    } else if (CfSolveNeeded.hostFlagged(host)) {
      await sl<ProviderManager>().solveCloudflareForHost(host, widget.url);
    } else {
      await MihonExtensionService.solveCloudflare(widget.url);
    }
    if (!mounted) return;
    setState(() => _solving = false);
    context.read<DetailCubit>().load();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(36, 40, 36, 56),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                color: _cloudflareOrange.withValues(alpha: 0.14),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.shield_rounded,
                size: 40,
                color: _cloudflareOrange,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'This source is protected by Cloudflare',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              _windowsDesktopUi
                  ? 'Verify this source, then retry. You can also choose '
                        'another installed source.'
                  : 'Complete the Cloudflare check once and this title will '
                        'load normally from then on.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 14,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 24),
            if (widget.canonical?.kind == ZKind.manga && widget.title != null)
              MatchLine(
                canonical: widget.canonical!,
                title: widget.title!,
                altTitle: widget.altTitle,
                malId: widget.malId,
              ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _solving ? null : _solve,
              icon: _solving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.shield_rounded, size: 20),
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
              ),
            ),
          ],
        ),
      ),
    );
  }
}

SearchScreen detailTitleSearchScreen({
  required String title,
  required String sourceId,
  required TitleSearchChoice choice,
}) => SearchScreen(
  initialQuery: title,
  forceSources: choice == TitleSearchChoice.searchAll,
  fixedSourceId:
      choice == TitleSearchChoice.search && sourceId == stremioSourceId
      ? stremioSourceId
      : null,
);

class DetailScreen extends StatelessWidget {
  const DetailScreen({
    super.key,
    required this.item,
    this.prefer,
    this.initialTab = 0,
    this.downloads,
  });
  final MediaItem item;

  /// Which page opens first: 0 Overview, 1 Episodes (or Chapters), 2 Comments.
  final int initialTab;

  /// Read this title from a specific metadata catalogue. Set when it was
  /// opened from a tracker that has one, so an AniList library entry shows
  /// AniList's page even when MyAnimeList is the app-wide choice.
  final PreferredProvider? prefer;

  /// Windows downloaded show page (opened from Downloads): returns this
  /// show's download records, re-read whenever the downloads change. When
  /// set the page lists only the saved episodes, reads its details from the
  /// cache saved with the downloads and never goes online by itself.
  final List<DownloadRecord> Function()? downloads;

  /// Opens with a Cue spring while the lightweight tapped-title preview shows.
  static Route<void> route(MediaItem item, {PreferredProvider? prefer}) =>
      _CueDetailRoute(
        pageBuilder: (_, _, _) => DetailScreen(item: item, prefer: prefer),
      );

  /// Windows: the show page in its downloaded mode (see [downloads]).
  static Route<void> downloadsRoute(
    MediaItem item, {
    required List<DownloadRecord> Function() downloads,
  }) => _CueDetailRoute(
    pageBuilder: (_, _, _) => DetailScreen(item: item, downloads: downloads),
  );

  @override
  Widget build(BuildContext context) {
    final downloads = this.downloads;
    if (downloads != null) {
      // Downloaded mode: no link repair (that needs the network), the cubit
      // reads the saved details and opens in the cut the files were saved in.
      return BlocProvider(
        key: ValueKey('downloads::${item.sourceId}::${item.id}'),
        create: (_) => DetailCubit(
          repo: sl<CatalogueRepository>(),
          url: item.url,
          sourceId: item.sourceId,
          prefs: sl<TitlePrefsStore>(),
          seedItem: item,
          localCategory: mainDownloadCategory(
            savedDownloadEpisodes(downloads()),
          ),
          localDetail: () =>
              loadDownloadedShowDetail(item, records: downloads()),
        )..load(),
        child: _DetailView(item: item, downloads: downloads),
      );
    }
    // Windows: repairs a saved title's broken source link before opening.
    if (_windowsDesktopUi) {
      return _RecoverableSavedDetail(item: item, prefer: prefer);
    }
    return BlocProvider(
      create: (_) => DetailCubit(
        repo: sl<CatalogueRepository>(),
        url: item.url,
        sourceId: item.sourceId,
        prefs: sl<TitlePrefsStore>(),
        seedMalId: item.malId,
        seedType: item.type,
        // An explicit preference (opened from a tracker) wins; otherwise a
        // saved title is READ from wherever it was saved, so the page and its
        // label agree instead of one naming AniList over MAL's data.
        prefer: prefer ?? _preferFromName(item.savedFrom),
      )..load(),
      child: _DetailView(item: item, prefer: prefer, initialTab: initialTab),
    );
  }
}

/// Repairs a saved title's unavailable source link before opening its detail.
class _RecoverableSavedDetail extends StatefulWidget {
  const _RecoverableSavedDetail({required this.item, this.prefer});
  final MediaItem item;
  final PreferredProvider? prefer;
  @override
  State<_RecoverableSavedDetail> createState() =>
      _RecoverableSavedDetailState();
}

/// Runs recovery once and preserves the original item when lookup fails.
class _RecoverableSavedDetailState extends State<_RecoverableSavedDetail> {
  late MediaItem item = repairedLibraryItem(widget.item);
  bool attempted = false;
  bool repairing = false;

  @override
  void initState() {
    super.initState();
    if (sl.isRegistered<SourceRepository>() &&
        !ZmodeIds.isZ(item.url) &&
        !sl<SourceRepository>().hasSource(item.sourceId)) {
      repairing = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _recover());
    }
  }

  /// Looks up the canonical title and persists the repaired saved-library link.
  /// Non-library items and failed lookups continue through the normal retry UI.
  Future<void> _recover() async {
    if (attempted || !mounted) return;
    attempted = true;
    final original = item;
    if (!sl.isRegistered<MyListStore>() ||
        !sl<MyListStore>().contains(original) ||
        !sl.isRegistered<MetadataRepository>() ||
        ZmodeIds.isZ(original.url)) {
      if (mounted) setState(() => repairing = false);
      return;
    }
    setState(() => repairing = true);
    try {
      final canonical = await sl<MetadataRepository>()
          .canonicalFor(original)
          .timeout(const Duration(seconds: 25));
      if (canonical != null && mounted) {
        final repaired = await sl<MyListStore>().repairLink(
          original,
          canonical,
        );
        if (mounted) setState(() => item = repaired);
      }
    } catch (_) {
      /* keep the original entry and its normal retry UI */
    }
    if (mounted) setState(() => repairing = false);
  }

  @override
  Widget build(BuildContext context) {
    if (repairing) {
      return Scaffold(
        backgroundColor: AppColors.bg,
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return BlocProvider(
      key: ValueKey('${item.sourceId}::${item.url}'),
      create: (_) => DetailCubit(
        repo: sl<CatalogueRepository>(),
        url: item.url,
        sourceId: item.sourceId,
        prefs: sl<TitlePrefsStore>(),
        seedMalId: item.malId,
        seedType: item.type,
        seedItem: item,
        prefer: widget.prefer ?? _preferFromName(item.savedFrom),
      )..load(),
      child: BlocListener<DetailCubit, DetailState>(
        listenWhen: (_, state) =>
            state.status == DetailStatus.error && state.cloudflareUrl == null,
        listener: (_, _) => _recover(),
        child: _DetailView(item: item, prefer: widget.prefer),
      ),
    );
  }
}

class _CueDetailRoute extends PageRouteBuilder<void>
    with CueModalRouteMixin<void> {
  _CueDetailRoute({required super.pageBuilder})
    : super(
        transitionDuration: Duration(milliseconds: _windowsDesktopUi ? 340 : 350),
        reverseTransitionDuration: Duration(
          milliseconds: _windowsDesktopUi ? 260 : 220,
        ),
        // A fade, not a slide: the page eases in over 350ms on a long soft
        // curve and leaves in 220ms. The curve is applied by the motion below,
        // so the animation value is already shaped when it reaches here.
        // Windows keeps its slide in from the right.
        transitionsBuilder: (_, animation, _, child) => _windowsDesktopUi
            ? SlideTransition(
                position: Tween(
                  begin: const Offset(1, 0),
                  end: Offset.zero,
                ).animate(animation),
                child: child,
              )
            : FadeTransition(opacity: animation, child: child),
      );

  @override
  CueMotion get motion => _windowsDesktopUi
      ? const Spring.smooth()
      : const CueMotion.curved(
          Duration(milliseconds: 350),
          curve: Cubic(0.5, 0, 0.14, 1),
        );

  @override
  CueMotion? get reverseMotion => _windowsDesktopUi
      ? const Spring.snappy()
      : const CueMotion.easeIn(Duration(milliseconds: 220));

  @override
  AnimationStatusListener? get onAnimationStatusChanged => null;

  @override
  bool get hideOnPushNext => false;
}

// ─────────────────────────────────────────────────────────────────────────────
// _DetailView — StatefulWidget for the scroll-driven app-bar title fade and the
// four-tab layout (Episodes / Cast / Relations / Details). The scroll position
// and TabController are pure UI state and stay widget-level; everything
// data-related (detail / category / season / desc-expand) lives in DetailCubit
// and is consumed via BlocBuilder below.
// ─────────────────────────────────────────────────────────────────────────────

class _DetailView extends StatefulWidget {
  const _DetailView({
    required this.item,
    this.prefer,
    this.initialTab = 0,
    this.downloads,
  });
  final MediaItem item;
  final int initialTab;

  /// The catalogue this title was opened from, so the name matches the data.
  final PreferredProvider? prefer;

  /// Windows downloaded show page; see [DetailScreen.downloads].
  final List<DownloadRecord> Function()? downloads;

  @override
  State<_DetailView> createState() => _DetailViewState();
}

class _DetailViewState extends State<_DetailView>
    with TickerProviderStateMixin {
  /// Windows compact hero extent, also used by collapse tracking and skeletons.
  static const double _expandedHeight = 200;

  /// Banner height: tall, scaling with the screen width (about 490px on a
  /// typical phone). Set from the screen size each time the page builds.
  double _heroHeight = 320;
  static double _heroFor(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final h = (size.width * 1.25).clamp(380.0, 560.0);
    if (!isTabletLayout(context)) return h;
    // Tablet: the same banner, but never taller than ~60% of the screen so
    // Play and the source row are still on screen without scrolling.
    if (isWideTabletLayout(context)) {
      // Wide: a shorter banner, so the buttons and the tabs start on screen.
      return (size.height * 0.45).clamp(300.0, 560.0);
    }
    return h.clamp(380.0, math.max(380.0, size.height * 0.6));
  }

  /// Tablet only. Below ~840dp wide: the same single column as the phone,
  /// centred at a readable width. Wider: everything shares one left edge (title
  /// on the banner, a left column of buttons, then the tabs and content across
  /// the width). A phone gets [slivers] back as is.
  List<Widget> _tabletSlivers(BuildContext context, List<Widget> slivers) {
    if (!isTabletLayout(context)) return slivers;
    if (isWideTabletLayout(context) && slivers.length >= 3) {
      // Wide: one left-aligned column of buttons under the banner, on the same
      // edge as the title above and the tabs below.
      final inset =
          wideSideInset(context) - 16; // the blocks carry their own 16
      return [
        for (var i = 0; i < slivers.length; i++)
          if (i > 0 &&
              i < slivers.length - 1 &&
              slivers[i] is SliverToBoxAdapter &&
              (slivers[i] as SliverToBoxAdapter).child != null)
            SliverToBoxAdapter(
              child: Align(
                alignment: Alignment.topLeft,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: 520 + inset),
                  child: Padding(
                    padding: EdgeInsets.only(left: inset),
                    child: (slivers[i] as SliverToBoxAdapter).child,
                  ),
                ),
              ),
            )
          else
            slivers[i],
      ];
    }
    return [
      for (final s in slivers)
        if (s is SliverToBoxAdapter && s.child != null)
          SliverToBoxAdapter(child: tabletColumn(context, s.child!))
        else
          s,
    ];
  }

  /// The tab pages as the NestedScrollView body.
  Widget _tabletBody(BuildContext context, Widget pages) {
    if (!isTabletLayout(context)) return pages;
    if (isWideTabletLayout(context)) {
      // The tabs' own 16 + this gives the same left edge as everything above.
      final w = MediaQuery.sizeOf(context).width;
      final side = math.max(0.0, (w - kWideContentWidth) / 2) + 16;
      return Padding(
        padding: EdgeInsets.symmetric(horizontal: side),
        child: pages,
      );
    }
    return tabletColumn(context, pages);
  }

  bool _showAppBarTitle = false;
  bool _hasEntered = false;
  Animation<double>? _routeAnimation;

  // The episode url we've already kicked a background source-prefetch for, so we
  // don't re-fire it on every rebuild (see _maybePrefetch).
  String? _prefetchedEpUrl;
  bool _stremioSheetOpen = false;
  final Map<(String, String), Future<ReadEntry?>> _cloudReadHistoryLookups = {};
  final Set<(String, String)> _cloudReadHistoryChecked = {};

  /// How long the viewer must stay on the screen before a source resolve is
  /// started for them. Long enough that a back-and-forth browse never starts
  /// one, short enough that a viewer reading the page still gets the warm menu.
  static const Duration _prefetchStayDelay = Duration(milliseconds: 700);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animation = ModalRoute.of(context)?.animation;
    if (identical(animation, _routeAnimation)) return;
    _routeAnimation?.removeStatusListener(_onRouteStatusChanged);
    _routeAnimation = animation;
    if (animation == null || animation.status == AnimationStatus.completed) {
      _hasEntered = true;
    } else {
      animation.addStatusListener(_onRouteStatusChanged);
    }
  }

  void _onRouteStatusChanged(AnimationStatus status) {
    if (status != AnimationStatus.completed || _hasEntered || !mounted) return;
    setState(() => _hasEntered = true);
  }

  // ── Windows downloaded show page (opened from Downloads) ──────────────────
  /// True when this page shows a downloaded show: only its saved episodes,
  /// Episodes + Details tabs, "Show online" in place of Download, no trailer
  /// and no Auto Resolve row.
  bool get _fromDownloads => widget.downloads != null;

  /// Index of the Details tab: last of two in downloaded mode, else fourth.
  int get _detailsTab => _fromDownloads ? 1 : 3;

  /// The saved episodes listed in downloaded mode, newest copy per episode.
  List<DownloadRecord> _savedEpisodes = const [];

  /// What [_savedEpisodes] was built from, so progress ticks of unrelated
  /// downloads never rebuild the page.
  List<Object?> _savedSignature = const [];

  /// The fields of [saved] that change what the list shows.
  static List<Object?> _signatureOf(List<DownloadRecord> saved) => [
    for (final r in saved) (r.id, r.filePath, r.status, r.episodeTitle),
  ];

  /// Re-reads this show's saved episodes after a download change; repaints
  /// only when the list really changed, and leaves the page (like the old
  /// downloads page did) once the last episode is gone.
  void _onDownloadsChanged() {
    final read = widget.downloads;
    if (read == null || !mounted) return;
    final saved = savedDownloadEpisodes(read());
    final signature = _signatureOf(saved);
    if (listEquals(signature, _savedSignature)) return;
    final hadEpisodes = _savedEpisodes.isNotEmpty;
    setState(() {
      _savedEpisodes = saved;
      _savedSignature = signature;
    });
    if (hadEpisodes && saved.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ModalRoute.of(context)?.isCurrent == true) {
          Navigator.of(context).maybePop();
        }
      });
    }
  }

  /// Plays saved episode [index] straight from disk, with the other saved
  /// episodes queued after it. Downloaded mode never streams.
  void _playSaved(int index) {
    final saved = _savedEpisodes;
    if (index < 0 || index >= saved.length) return;
    unawaited(
      launchDownloadedEpisode(
        context,
        saved[index],
        episodes: episodesFromDownloads(saved),
        startIndex: index,
      ),
    );
  }

  /// Deletes the saved files of [episodes] (the selection's Delete) after
  /// one confirm. The manager recycles the files on Windows.
  Future<void> _deleteSaved(List<Episode> episodes) async {
    final ids = {for (final e in episodes) e.id};
    final records = [
      for (final r in _savedEpisodes)
        if (ids.contains(r.episodeId)) r,
    ];
    if (records.isEmpty) return;
    // Same wording as the Downloads page's own selection delete.
    final ok = await showDesktopConfirm(
      context,
      title: '${context.l10n.deleteDownload} (${records.length})',
      message: context.l10n.deleteSelectedDownloadsRecycle,
      confirmLabel: context.l10n.delete,
      destructive: true,
    );
    if (!ok || !mounted) return;
    await sl<DownloadManager>().deleteAll(records);
    if (mounted) showAppToast(context, context.l10n.downloadDeleted);
  }

  /// "Show online": the normal show page for the same title.
  void _openOnline() {
    unawaited(Navigator.of(context).push(DetailScreen.route(widget.item)));
  }

  /// Whether this show has downloads; looked up once per page (build runs
  /// often), and set by [_cacheDetailsOnDownload] when one is queued here.
  bool? _showHasDownloads;

  /// Downloaded mode: the muted alternative-title line the online page shows
  /// beside the buttons (its romaji line), from the saved metadata: the
  /// first English/synonym title written in Latin script that differs from
  /// the header title. Null when there is none.
  Widget? _savedAltTitleLine(MediaDetail detail) {
    final shown = detail.title.trim().toLowerCase();
    final latin = RegExp(r'^[\x00-ɏḀ-ỿ\s\p{P}]+$', unicode: true);
    for (final raw in [detail.englishTitle, ...detail.synonyms]) {
      final t = raw?.trim() ?? '';
      if (t.isEmpty || t.toLowerCase() == shown || !latin.hasMatch(t)) {
        continue;
      }
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Text(
          t,
          key: const ValueKey('downloaded-alt-title'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppText.caption.copyWith(
            color: AppColors.textSecondary,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }
    return null;
  }

  /// What the last backfill saved (see [_detailsSignatureOf]); a save only
  /// happens when the loaded metadata grew since.
  String? _savedDetailsSignature;

  /// Debounce for the backfill, so a burst of enrichment patches saves once.
  Timer? _detailsSaveTimer;

  /// Online page only (Windows): keeps the full metadata a downloaded show
  /// page needs (Details fields, every episode's description / date /
  /// rating / thumbnail, images) for shows that have downloads. Runs once
  /// the episodes and the enrichment are in, and again (debounced, 2 s)
  /// whenever later patches add more, so older downloads are filled in too.
  void _cacheDetailsForDownloads(MediaDetail detail, DetailState state) {
    if (_fromDownloads || !_windowsDesktopUi) return;
    if (state.status != DetailStatus.success ||
        state.episodesLoading ||
        state.extrasLoading) {
      return;
    }
    if (!sl.isRegistered<DownloadManager>()) return;
    final item = widget.item;
    _showHasDownloads ??= sl<DownloadManager>().all.any(
      (r) => r.sourceId == item.sourceId && r.showId == item.id,
    );
    if (_showHasDownloads != true) return;
    final cast = [for (final c in state.cast) c.name];
    final signature = _detailsSignatureOf(detail, cast);
    if (signature == _savedDetailsSignature) return;
    _savedDetailsSignature = signature;
    // The save itself needs no widget, so leaving the page early still runs
    // it (see dispose).
    void save() {
      _pendingDetailsSave = null;
      unawaited(
        DownloadedShowDetails.save(
          detail,
          sourceId: item.sourceId,
          showId: item.id,
          castNames: cast,
        ),
      );
    }

    _pendingDetailsSave = save;
    _detailsSaveTimer?.cancel();
    _detailsSaveTimer = Timer(const Duration(seconds: 2), save);
  }

  /// The debounced save still waiting on [_detailsSaveTimer], if any.
  VoidCallback? _pendingDetailsSave;

  /// A cheap fingerprint of how complete [detail] is: changes when episodes,
  /// their descriptions / thumbnails / ratings, tags, score or the synopsis
  /// arrive, so the backfill re-saves only then.
  static String _detailsSignatureOf(MediaDetail detail, List<String> cast) {
    var described = 0, thumbs = 0, rated = 0;
    for (final e in detail.episodes) {
      if ((e.description ?? '').isNotEmpty) described++;
      if ((e.thumbnail ?? '').isNotEmpty) thumbs++;
      if (e.rating != null) rated++;
    }
    return [
      detail.title,
      detail.episodes.length,
      described,
      thumbs,
      rated,
      detail.tags.length,
      detail.score,
      detail.popularity,
      detail.favourites,
      detail.description?.length,
      detail.genres.length,
      detail.studios.length,
      detail.cover,
      detail.banner,
      cast.length,
    ].join('|');
  }

  /// Saves the details right when a download is queued, so its downloaded
  /// show page has them even if this page is never opened again. Windows.
  void _cacheDetailsOnDownload(MediaDetail detail) {
    if (!_windowsDesktopUi || _fromDownloads) return;
    // Later enrichment patches now keep this show's saved details current.
    _showHasDownloads = true;
    List<String> cast = const [];
    try {
      cast = [for (final c in context.read<DetailCubit>().state.cast) c.name];
    } catch (_) {
      /* no cubit above: provider cast only */
    }
    unawaited(
      DownloadedShowDetails.save(
        detail,
        sourceId: widget.item.sourceId,
        showId: widget.item.id,
        castNames: cast,
      ),
    );
  }

  Timer? _prefetchTimer;

  // Filler episode numbers (from Tenrai by MAL id), for the "Filler" badge in the
  // episode list. Fetched once per malId; empty for non-anime / unlisted shows.
  Set<int> _fillerEps = const {};
  int? _fillerForMal;
  void _ensureFiller(int? malId) {
    if (malId == _fillerForMal) return;
    _fillerForMal = malId;
    _fillerEps = malId == null
        ? const {}
        : FillerService.instance.peekCache(malId) ?? const {};
    if (malId == null) return;
    FillerService.instance.fillerEpisodes(malId).then((s) {
      if (mounted && _fillerForMal == malId && s.isNotEmpty) {
        setState(() => _fillerEps = s);
      }
    });
  }

  // Outer scroll position (the hero/header viewport). We listen to THIS instead
  // of a NotificationListener: the listener also fires for the inner TabBarView
  // lists (whose pixels start at 0), which flipped the title back OFF as soon as
  // you scrolled deeper into the episode list. NestedScrollView.controller drives
  // the OUTER viewport only, so its offset stays past the threshold once the hero
  // has collapsed — the title stays visible no matter how far the body scrolls.
  /// How far the page has been pulled down past its top, in px (0 at rest).
  /// The banner zooms with it, then eases back when the finger lifts.
  final ValueNotifier<double> _pull = ValueNotifier<double>(0);
  double _pullFrom = 0;
  late final AnimationController _pullBack =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 280),
      )..addListener(() {
        _pull.value =
            _pullFrom * (1 - Curves.easeOutCubic.transform(_pullBack.value));
      });

  static const double _maxPull = 160;

  bool _onScrollNotification(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    if (n is OverscrollNotification &&
        n.overscroll < 0 &&
        n.dragDetails != null) {
      // Pulling down while already at the top: the page does not move, the
      // banner grows instead. Halved, so it feels like pulling on rubber.
      _pullBack.stop();
      _pull.value = (_pull.value - n.overscroll * 0.55).clamp(0, _maxPull);
    } else if (n is ScrollEndNotification && _pull.value > 0) {
      _pullFrom = _pull.value;
      _pullBack.forward(from: 0);
    }
    return false;
  }

  late final ScrollController _scrollController = ScrollController()
    ..addListener(_onScroll);

  // Downloaded mode has only Episodes + Details (no Cast / Relations).
  late final TabController _tabController = TabController(
    // Phone: Overview / Episodes / Comments pages. Windows keeps its tabs:
    // Episodes / Cast / Relations / Details (Episodes + Details downloaded).
    animationDuration: _windowsDesktopUi ? null : Duration.zero,
    initialIndex: _windowsDesktopUi ? 0 : widget.initialTab.clamp(0, 2),
    length: _windowsDesktopUi ? (_fromDownloads ? 2 : 4) : 3,
    vsync: this,
  );

  // ── Windows page keys (show-8) and failure retry (show-14) ────────────────
  /// Focus for the page-level keys, autofocused so Enter/Space/D/Ctrl+1..4
  /// work as soon as the page opens. Nested widgets (episode list, text
  /// fields, buttons) still see their keys first.
  final FocusScopeNode _pageKeysFocus = FocusScopeNode(
    debugLabel: 'detail-page-keys',
  );

  /// What the desktop Play / Download buttons currently do, refreshed on every
  /// body build so the keys never disagree with the buttons (null = disabled).
  VoidCallback? _keyPlay;
  VoidCallback? _keyDownload;

  /// While rate-limited, the earliest time a retry is worth sending. Set from
  /// `rate_limited:<secs>` the first time a failure is shown.
  DateTime? _retryNotBefore;

  /// The error [_retryNotBefore] was armed for, so a rebuild does not restart
  /// the countdown. Cleared on every new load so a repeat failure re-arms.
  String? _retryArmedFor;

  // ── My List (status-organised library) ────────────────────────────────────
  final MyListStore _myList = sl<MyListStore>();
  final ListStatusStore _listStatus = sl<ListStatusStore>();
  late WatchStatus? _status = _listStatus.statusOf(widget.item);
  late bool _inMyList = _status != null || _myList.contains(widget.item);

  // ── Trailer (metadata-API lookup) ─────────────────────────────────────────
  // Resolved lazily once per detail load and cached so the hero player doesn't
  // refetch on every rebuild. Yields a YouTube id or null; once it resolves the
  // hero swaps its static cover backdrop for an autoplaying, muted, looping
  // player (Netflix-style).
  Future<String?>? _trailerFuture;

  /// Poster-tinted background colour for the adaptive wash (null → normal
  /// theme background). Extraction runs once per hero-art URL.
  final ValueNotifier<Color?> _tint = ValueNotifier(null);
  String? _tintUrl;

  /// Windows (B3): the page's latest episodes by season, fed to an open batch
  /// download dialog so it grows with the page (a long show loads 56, then
  /// 104 episodes). Updated after the frame, never during build.
  final ValueNotifier<Map<int, List<Episode>>> _batchEpisodesLive =
      ValueNotifier(const {});
  int _batchEpisodesPublished = -1;

  /// Hands [bySeason] to [_batchEpisodesLive] when the episode count changed.
  /// Windows only; the phone's bottom sheet keeps its snapshot as before.
  void _publishBatchEpisodes(Map<int, List<Episode>> bySeason) {
    if (!_windowsDesktopUi) return;
    final count = batchEpisodeCount(bySeason);
    if (count == _batchEpisodesPublished) return;
    _batchEpisodesPublished = count;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _batchEpisodesLive.value = bySeason;
    });
  }

  /// Official TMDB title logo (null → plain text title). Resolved once per
  /// page when the Title artwork toggle is on; the service caches hits in
  /// memory + Hive, so repeat opens don't pop.
  String? _logoUrl;

  /// TMDB backdrop for an AniList anime (keyed by item id), once resolved —
  /// AniList's own `bannerImage` is often missing or low-res. No entry keeps
  /// today's banner.
  final Map<String, String> _tmdbBanners = {};

  /// Resolve once; only the hero listens for the result.
  void _resolveTrailer(MediaDetail detail) {
    _trailerFuture ??= sl<TrailerService>().youtubeId(
      title: detail.title,
      englishTitle: detail.englishTitle,
      type: detail.type,
      year: detail.year,
    );
  }

  /// Watch progress that arrives after the page opened (cloud sync runs after
  /// the splash, or a resume saved by the player) refreshes Continue at once.
  final List<Listenable> _progressListenables = [];
  Timer? _progressDebounce;

  void _listenForProgress() {
    for (final name in [WatchHistory.boxName, ResumeStore.boxName]) {
      if (!Hive.isBoxOpen(name)) continue;
      final l = Hive.box<Map>(name).listenable();
      l.addListener(_onProgressChanged);
      _progressListenables.add(l);
    }
  }

  // Sync writes many rows at once; rebuild once when the burst settles.
  void _onProgressChanged() {
    _progressDebounce?.cancel();
    _progressDebounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() {});
    });
  }

  @override
  void initState() {
    super.initState();
    // R1: lost focus (a text field left, a sheet closed) comes back to the
    // page keys. No-op off Windows (the scope is not even built there).
    DesktopFocusRepair.register(_pageKeysFocus);
    _tint.addListener(_onTintChanged);
    ThemeController.revision.addListener(_onThemeRevision);
    // Windows: progress that arrives later (cloud sync) refreshes Continue.
    if (_windowsDesktopUi) _listenForProgress();
    // Downloaded mode: list the saved episodes now and follow deletes.
    if (_fromDownloads && sl.isRegistered<DownloadManager>()) {
      _savedEpisodes = savedDownloadEpisodes(widget.downloads!());
      _savedSignature = _signatureOf(_savedEpisodes);
      sl<DownloadManager>().addListener(_onDownloadsChanged);
    }
    _loadLogo();
    // The phone banner only; the Windows card uses its own hero art.
    if (!_windowsDesktopUi) _loadTmdbBanner();
    _schedulePlayerWarmup();
    // Discord Rich Presence: "Looking at <title>" while this detail is open.
    // Windows: not while a video plays in the floating mini player; that
    // keeps showing "Watching".
    if (sl.isRegistered<DiscordRpc>() &&
        !DesktopFloatingPlayer.instance.isActive) {
      sl<DiscordRpc>().setBrowsing(
        title: widget.item.title,
        posterUrl: widget.item.cover,
      );
    }
  }

  Timer? _playerWarmupTimer;
  MpvPlayerPool? _playerWarmupPool;

  void _schedulePlayerWarmup() {
    if (!sl.isRegistered<MpvPlayerPool>() ||
        sl<AppMode>().isTv ||
        widget.item.type == ProviderType.manga ||
        widget.item.type == ProviderType.novel) {
      return;
    }
    // Do not construct a native core during the detail-page transition.
    _playerWarmupTimer = Timer(_prefetchStayDelay, () {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route?.isCurrent != true ||
          (route?.animation != null &&
              route!.animation!.status != AnimationStatus.completed)) {
        return;
      }
      final prefs = sl<PlaybackPrefs>();
      // P4: the effective value ignores a phone player id carried over by a
      // backup, so Windows always warms up its own mpv player.
      if (prefs.effectiveExternalPlayerPackage.isNotEmpty) return;
      _playerWarmupPool = sl<MpvPlayerPool>();
      _playerWarmupPool!.warmUp(libass: prefs.styledSubtitles);
    });
  }

  /// Repaint the pinned app bar in the new tint: it paints the same wash as the
  /// body, so the bar must follow the extracted colour to stay opaque.
  void _onTintChanged() {
    if (mounted) setState(() {});
  }

  /// Any theme change rebuilds: picks up the Title artwork toggle being
  /// flipped while this page is open (on → resolve the logo, off → text).
  void _onThemeRevision() {
    if (!mounted) return;
    if (!ThemeController.titleLogo) {
      if (_logoUrl != null) setState(() => _logoUrl = null);
      return;
    }
    if (_logoUrl == null) {
      _loadLogo();
    } else {
      setState(() {});
    }
  }

  /// Stremio title search stays in its addon catalogue.
  Future<void> _onTitleTap(String title) async {
    final req = await showTitleSearchPopup(context, title);
    if (!mounted || req == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => detailTitleSearchScreen(
          title: title,
          sourceId: widget.item.sourceId,
          choice: req,
        ),
      ),
    );
  }

  /// Plain-text titles (the Title artwork toggle only swaps in a logo once
  /// one has actually resolved — and back to text if it fails to load).
  Widget _headerTitleText(String title) => Text(
    title,
    textAlign: _windowsDesktopUi ? null : TextAlign.center,
    style: AppText.largeTitle.copyWith(
      // Smaller on Windows, where the header sits in a narrow info pane.
      fontSize: _windowsDesktopUi ? 23 : 28,
    ),
    maxLines: 2,
    overflow: TextOverflow.ellipsis,
  );

  Widget _barTitleText(String title) => Text(
    title,
    style: AppText.headline,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
  );

  /// Best-effort TMDB title-logo lookup (no-op unless the toggle is on).
  /// Stays text until (and unless) a logo resolves; a genuine "no logo"
  /// simply never sets [_logoUrl].
  Future<void> _loadLogo({String? failedUrl}) async {
    if (!ThemeController.titleLogo) return;
    if (!sl.isRegistered<TitleLogoService>()) return;
    if (failedUrl != null && failedUrl != _logoUrl) return;
    final item = widget.item;
    try {
      final service = sl<TitleLogoService>();
      final url = failedUrl == null
          ? await service.logoFor(item)
          : await service.fallbackFor(item, failedUrl);
      if (!mounted ||
          !ThemeController.titleLogo ||
          widget.item.id != item.id ||
          widget.item.sourceId != item.sourceId) {
        return;
      }
      if (_logoUrl != url && (url != null || failedUrl != null)) {
        setState(() => _logoUrl = url);
      }
    } catch (_) {}
  }

  /// Best-effort TMDB backdrop lookup for an AniList anime. No-op for every
  /// other provider — their own banner is already good.
  void _loadTmdbBanner() {
    final item = widget.item;
    loadTmdbBanners(
      [item],
      _tmdbBanners,
      context: context,
      mounted: () =>
          mounted &&
          widget.item.id == item.id &&
          widget.item.sourceId == item.sourceId,
      onResolved: (id, url) => setState(() => _tmdbBanners[id] = url),
    );
  }

  @override
  void dispose() {
    _progressDebounce?.cancel();
    for (final l in _progressListenables) {
      l.removeListener(_onProgressChanged);
    }
    if (_fromDownloads && sl.isRegistered<DownloadManager>()) {
      sl<DownloadManager>().removeListener(_onDownloadsChanged);
    }
    _routeAnimation?.removeStatusListener(_onRouteStatusChanged);
    _playerWarmupTimer?.cancel();
    final prepared = _playerWarmupPool;
    if (prepared != null) unawaited(prepared.clear());
    // Leaving before the stay-delay elapsed: no viewer is here to warm a menu
    // for, so the pending resolve never starts.
    _prefetchTimer?.cancel();
    // A details backfill still in its debounce: run it now rather than lose
    // it (it needs no widget and never throws).
    _detailsSaveTimer?.cancel();
    _pendingDetailsSave?.call();
    // Back to generic "Browsing" when leaving the detail.
    if (sl.isRegistered<DiscordRpc>() &&
        !DesktopFloatingPlayer.instance.isActive) {
      sl<DiscordRpc>().setBrowsing();
    }
    _pullBack.dispose();
    _pull.dispose();
    _scrollController.dispose();
    _tint.removeListener(_onTintChanged);
    ThemeController.revision.removeListener(_onThemeRevision);
    _tint.dispose();
    _batchEpisodesLive.dispose();
    _tabController.dispose();
    // R1: stop offering this scope to the focus repair.
    DesktopFocusRepair.unregister(_pageKeysFocus);
    _pageKeysFocus.dispose();
    super.dispose();
  }

  /// Windows (show-8 / show-14): page keys. Typing in a text field always
  /// wins; Enter/Space only fire when no specific control has focus (a
  /// focused button or row activates itself instead).
  KeyEventResult _onPageKey(FocusNode node, KeyEvent event) {
    if (!_windowsDesktopUi || event is KeyUpEvent) {
      return KeyEventResult.ignored;
    }
    final focus = FocusManager.instance.primaryFocus;
    final typing =
        focus?.context?.findAncestorStateOfType<EditableTextState>() != null;
    if (typing) return KeyEventResult.ignored;

    // F5 (app.refresh): retry a failed load. Otherwise leave F5 to the
    // episode list's own refresh and the app.
    if (DesktopShortcuts.matches('app.refresh', event) && _isLoadFailed()) {
      _retryLoad();
      return KeyEventResult.handled;
    }

    // Nothing more specific focused: the page node itself or a bare scope.
    final pageFocused = focus == null || focus == node || focus is FocusScopeNode;
    if (pageFocused && DesktopShortcuts.matches('show.play', event)) {
      final play = _keyPlay;
      if (play == null) return KeyEventResult.ignored;
      // A held key repeats: start playback once.
      if (event is KeyDownEvent) play();
      return KeyEventResult.handled;
    }
    if (DesktopShortcuts.matches('show.download', event)) {
      final download = _keyDownload;
      if (download == null) return KeyEventResult.ignored;
      if (event is KeyDownEvent) download();
      return KeyEventResult.handled;
    }
    // Ctrl+1..4: Episodes / More like this / Cast / Details tabs.
    for (var i = 1; i <= _tabController.length; i++) {
      if (DesktopShortcuts.matches('show.tab$i', event)) {
        _revealTab(i - 1);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  /// True while the page shows a failed load (banner or error state).
  bool _isLoadFailed() {
    if (!mounted) return false;
    return context.read<DetailCubit>().state.status == DetailStatus.error;
  }

  /// Windows (show-14): arms the rate-limit countdown for [error] once per
  /// failure, so the banner's Retry and F5 wait for the same moment.
  void _armRetry(String? error) {
    if (error == _retryArmedFor) return;
    _retryArmedFor = error;
    final secs = _limitSeconds(error);
    _retryNotBefore = secs == null
        ? null
        : DateTime.now().add(Duration(seconds: secs));
  }

  /// Windows (show-14): run the initial fetch again. While rate-limited it
  /// only says how long is left, since the request would be refused anyway.
  void _retryLoad() {
    if (!_isLoadFailed()) return;
    final wait = _retryNotBefore?.difference(DateTime.now());
    if (wait != null && wait > Duration.zero) {
      _snack(context.l10n.tryAgainInSeconds(wait.inSeconds + 1));
      return;
    }
    _retryArmedFor = null;
    _retryNotBefore = null;
    unawaited(context.read<DetailCubit>().load());
  }

  /// Background-resolve [epUrl]'s sources once for this title, so the next Play
  /// reuses the work.
  ///
  /// Only start after the viewer has demonstrably stayed on the page. The
  /// prefetch is scoped to the selected source; Z Mode only prefetches when a
  /// source is already matched, so opening a detail page never starts an
  /// Auto Resolve sweep across every installed provider.
  void _maybePrefetch(String epUrl, String sourceId) {
    if (sourceId == stremioSourceId) return;
    if (_prefetchedEpUrl == epUrl) return;
    final zMode = sourceId == ZmodeIds.sourceId;
    if (zMode && _zModeMatchedSource() == null) return;
    _prefetchedEpUrl = epUrl;
    _prefetchTimer?.cancel();
    _prefetchTimer = Timer(_prefetchStayDelay, () {
      if (!mounted) return;
      if (zMode) {
        final matched = _zModeMatchedSource();
        ProviderManager.inBackground(
          () => sl<CatalogueRepository>().sources(
            epUrl,
            sourceId: matched?.sourceId ?? sourceId,
            fast: true,
          ),
        ).catchError((_) => <VideoSource>[]);
        return;
      }

      sl<SourceRepository>().prefetch(epUrl, sourceId: sourceId);
    });
  }

  /// The source already matched to this title, or null when none is — a local
  /// lookup, no network.
  SourceMatch? _zModeMatchedSource() {
    if (!sl.isRegistered<MatchStore>()) return null;
    final c = ZmodeIds.parseShow(widget.item.url);
    if (c == null) return null;
    return sl<MatchStore>().bestFor(c, available: sl<SourceRepository>().hasSource);
  }

  // ── Scroll-driven app-bar title fade. PRESERVED EFFECT — reads the outer
  // NestedScrollView offset (Sozo Read's pattern). The title fades in as the
  // hero scrolls past and STAYS in while the body scrolls. ──────────────────
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final shouldShow =
        _scrollController.offset >
        ((_windowsDesktopUi ? _expandedHeight : _heroHeight) -
            kToolbarHeight -
            24);
    if (shouldShow != _showAppBarTitle) {
      setState(() => _showAppBarTitle = shouldShow);
    }
  }

  /// Switch to [index] AND collapse the header so the tab's content is actually
  /// in view — otherwise tapping "… more"/"Read more" silently changes a tab
  /// that's still below the fold (feels like nothing happened). Animates both
  /// for a smooth transition into the Cast / Details tab.
  void _revealTab(int index) {
    _tabController.animateTo(index);
    if (_windowsDesktopUi && MediaQuery.sizeOf(context).width >= 980) return;
    if (_scrollController.hasClients) {
      final target = _scrollController.position.maxScrollExtent;
      if (_scrollController.offset < target - 1) {
        _scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 380),
          curve: Curves.easeOutCubic,
        );
      }
    }
  }

  // ── The 5-icon action row wiring ──────────────────────────────────────────

  /// Open the "Add to List" status sheet (Plan / Watching / Completed / Paused
  /// / Dropped / Remove). Works locally for any title; for anime with a MAL id
  /// and AniList connected, the choice is also pushed to AniList.
  Future<void> _openListSheet(MediaDetail detail) async {
    await showListStatusSheet(
      context,
      item: widget.item,
      malId: detail.malId ?? widget.item.malId,
      tmdbId: detail.tmdbId ?? widget.item.tmdbId,
      tmdbIsTv: detail.tmdbIsTv,
      imdbId: detail.imdbId ?? widget.item.imdbId,
      onChanged: () {
        if (!mounted) return;
        setState(() {
          _status = _listStatus.statusOf(widget.item);
          _inMyList = _status != null || _myList.contains(widget.item);
        });
      },
    );
  }

  // Tracker-driven episode grey-out: the connected tracker's watched-episode
  // count, fetched once after the detail loads (null until then / no match).
  int? _trackerProgress;

  /// Whether any connected tracker has this title on a list. Drives the
  /// Tracking action's icon — separate from [_trackerProgress] because a title
  /// can be tracked at episode 0 (Planning), which is still "tracked".
  bool _tracked = false;

  /// Next episode to air, from the tracker entry fetched for progress. Null
  /// for a finished show, a movie, or a title with no tracker match — the row
  /// hides rather than claiming it doesn't know.
  int? _nextAiringEpisode;
  DateTime? _nextAiringAt;
  bool _trackerFetchStarted = false;

  /// The main reading CTA can await the initial tracker chapter lookup.
  Future<void>? _trackerProgressLookup;

  /// Fetch the connected tracker's episode progress once, so episodes already
  /// watched on AniList/MAL/Simkl grey out even if never played in-app.
  /// Best-effort and additive — a null result changes nothing on screen.
  void _maybeFetchTrackerProgress(MediaDetail detail) {
    if (_trackerFetchStarted) return;
    _trackerFetchStarted = true;
    final hub = sl<TrackerHub>();
    if (!hub.anyConnected) return;
    final isAnime = detail.type == ProviderType.anime;
    final reading =
        detail.type == ProviderType.manga || detail.type == ProviderType.novel;
    final pins = sl<TrackerBindingStore>().get(
      TrackerBindingStore.keyOf(widget.item.sourceId, widget.item.url),
    );
    _trackerProgressLookup = hub
        .fetchEntry(
          malId: detail.malId ?? widget.item.malId,
          title: (isAnime || reading) ? detail.title : null,
          tmdbId: detail.tmdbId ?? widget.item.tmdbId,
          tmdbIsTv: detail.tmdbIsTv,
          imdbId: detail.imdbId ?? widget.item.imdbId,
          pinnedIds: pins.isEmpty ? null : pins,
          kind: reading ? MediaKind.manga : MediaKind.anime,
          novel: detail.type == ProviderType.novel,
        )
        .then((e) {
          if (!mounted) return;
          // Same response the progress comes from — the airing fields were already
          // being fetched and thrown away, so showing them costs no extra request.
          // Both null for a finished show, a movie, or a title we couldn't match.
          final ep = e?.nextAiringEpisode;
          final at = e?.nextAiringAt;
          final p = e?.progress;
          final onList = e?.onList ?? false;
          if (p == null || p <= 0) {
            setState(() {
              _tracked = onList;
              if (ep != null && at != null) {
                _nextAiringEpisode = ep;
                _nextAiringAt = at;
              }
            });
            return;
          }
          setState(() {
            _tracked = onList;
            _trackerProgress = p;
            _nextAiringEpisode = ep;
            _nextAiringAt = at;
          });
        })
        .catchError((Object _) {
          // Tracker outages must leave local/cloud resume available.
        });
  }

  /// Whether the Tracking button should show for [detail]. Only when a tracker
  /// is connected AND it can actually track this title: anime/manga/novel →
  /// always (AniList/MAL resolve by malId or title regardless); movies &
  /// live-action TV → only Simkl, and only with a tmdb/imdb id to key on.
  /// Keeps the button out of the way for everyone else.
  bool _trackingAvailable(MediaDetail detail) {
    final hub = sl<TrackerHub>();
    if (!hub.anyConnected) return false;
    if (detail.type == ProviderType.anime ||
        detail.type == ProviderType.manga ||
        detail.type == ProviderType.novel) {
      return true;
    }
    final simklOn = hub.connected.any((t) => t.displayName == 'Simkl');
    final hasId =
        (detail.tmdbId ?? widget.item.tmdbId) != null ||
        ((detail.imdbId ?? widget.item.imdbId)?.isNotEmpty ?? false);
    return simklOn && hasId;
  }

  /// Open the tracker list — one row per connected tracker, showing what each
  /// one matched, with "Sync all at once" for the original write-to-everything
  /// editor. Anime resolves by MAL id or title; movies/TV via Simkl's
  /// tmdb/imdb id; manga/novel by malId or title (AniList/MAL manga lists).
  /// Returns the applied progress so grey-out can update immediately.
  Future<void> _openTrackingSheet(MediaDetail detail) async {
    final reading =
        detail.type == ProviderType.manga || detail.type == ProviderType.novel;
    final applied = await showTrackerListSheet(
      context,
      title: detail.title,
      isAnime: detail.type == ProviderType.anime,
      reading: reading,
      malId: detail.malId ?? widget.item.malId,
      tmdbId: detail.tmdbId ?? widget.item.tmdbId,
      tmdbIsTv: detail.tmdbIsTv,
      imdbId: detail.imdbId ?? widget.item.imdbId,
      bindingKey: TrackerBindingStore.keyOf(
        widget.item.sourceId,
        widget.item.url,
      ),
    );
    if (applied != null && mounted && applied > (_trackerProgress ?? 0)) {
      setState(() => _trackerProgress = applied);
    }
    // The sheet can add tracking or remove it, so the icon has to be re-read
    // rather than inferred from [applied] (a removal applies nothing).
    if (!mounted) return;
    _trackerFetchStarted = false;
    _maybeFetchTrackerProgress(detail);
  }

  /// Open a related title.
  ///
  /// Used to search the CURRENT source for it, always. That works for a
  /// sequel, and never for a manga's anime adaptation: the manga source it
  /// asked has no anime in it, so the tap answered "not on this source" for
  /// exactly the links people most want to follow. [openRelatedTitle] picks
  /// the source or the metadata page by what the relation actually is.
  Future<void> _openRelation(MediaRelation r) => openRelatedTitle(
    context,
    title: r.title,
    romaji: r.romaji,
    cover: r.cover,
    isReading: r.isReading,
    malId: r.malId,
    anilistId: r.anilistId,
    tmdbId: r.tmdbId,
    tmdbIsTv: r.tmdbIsTv,
    sourceId: widget.item.sourceId,
    fromReadingPage:
        widget.item.type == ProviderType.manga ||
        widget.item.type == ProviderType.novel,
  );

  void _share(MediaDetail detail, String sourceName) {
    // Windows (show-11 B): most desktop users want the link copied, not the
    // OS share flyout, so Share opens a small menu with every choice.
    if (_windowsDesktopUi) {
      unawaited(_showDesktopShareMenu(detail));
      return;
    }
    // Native OS share sheet with a Zangetsu deep link: on tap it opens the app
    // straight to this title (on its source) if installed, else the Zangetsu
    // site to download. The link carries the item, so sourceName is unused now.
    SharePlus.instance.share(
      ShareParams(text: ShareLink.shareText(widget.item)),
    );
  }

  /// Windows Share menu: Copy link / Copy title / Open source page / Share
  /// via Windows. Opens at the click (DesktopPointer fallback).
  Future<void> _showDesktopShareMenu(MediaDetail detail) {
    final title = detail.title.isNotEmpty ? detail.title : widget.item.title;
    // Grey out the source page row when there is no page to open.
    final hasWebPage = _sourceWebUrl() != null;
    return showDesktopContextMenu<void>(
      context,
      items: [
        DesktopMenuItem(
          label: context.l10n.copyLink,
          icon: Icons.link_rounded,
          onTap: () => _copyToClipboard(
            ShareLink.forItem(widget.item),
            context.l10n.linkCopied,
          ),
        ),
        DesktopMenuItem(
          label: context.l10n.copyTitle,
          icon: Icons.title_rounded,
          onTap: () => _copyToClipboard(title, context.l10n.titleCopied),
        ),
        DesktopMenuItem(
          label: context.l10n.openSourcePage,
          icon: Icons.public_rounded,
          enabled: hasWebPage,
          onTap: () => unawaited(_openSourceSite()),
        ),
        const DesktopMenuItem<void>.divider(),
        DesktopMenuItem(
          label: context.l10n.shareViaWindows,
          icon: Icons.ios_share_rounded,
          onTap: () => unawaited(
            SharePlus.instance.share(
              ShareParams(text: ShareLink.shareText(widget.item)),
            ),
          ),
        ),
      ],
    );
  }

  /// Copies [text] and confirms with a toast.
  Future<void> _copyToClipboard(String text, String done) async {
    await Clipboard.setData(ClipboardData(text: text));
    _snack(done);
  }

  /// Globe — open the source's web page in the system browser. Falls back to
  /// a snackbar when no usable URL can be derived.
  Future<void> _openSourceSite() async {
    final url = _sourceWebUrl();
    if (url == null) {
      _snack(context.l10n.noWebPageForThisSource);
      return;
    }
    final ok = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && mounted) _snack(context.l10n.couldNotOpenSourceSite);
  }

  /// Best-effort web URL for the title. Absolute item URLs (CloudStream/JS)
  /// pass through; Aniyomi items store a relative path, so join it onto the
  /// source's base site (mirroring the native `baseUrl + anime.url`).
  String? _sourceWebUrl() {
    final u = widget.item.url.trim();
    if (u.isEmpty) return null;
    if (u.startsWith('http://') || u.startsWith('https://')) return u;
    // Z Mode: the item is a metadata title (`zm://anime/mal:123`) and its
    // sourceId is the pseudo id `zm`, so the join below found no base URL and
    // the globe only ever said "no web page for this source". The title does
    // live on a real source — the one Auto Resolve matched — so open that.
    final c = ZmodeIds.parseShow(u);
    if (c != null) return _matchedSourceWebUrl(c);
    final base = sl<SourceRepository>().baseUrlFor(widget.item.sourceId).trim();
    if (base.isEmpty) return null;
    if (base.endsWith('/') && u.startsWith('/')) return base + u.substring(1);
    return base + u;
  }

  /// The matched source's own page for a Z Mode title, or null when nothing
  /// has matched it yet — in which case the existing snackbar is the honest
  /// answer, because there genuinely is no page to open.
  ///
  /// The join is [source_actions.joinChapterUrl] rather than a second copy of
  /// the one above: it is already tested, and it refuses a `showUrl` carrying
  /// javascript:/file:/intent:, which matters because that value comes from a
  /// third-party extension.
  String? _matchedSourceWebUrl(ZCanonical c) {
    if (!sl.isRegistered<MatchStore>()) return null;
    final m = sl<MatchStore>().bestFor(c, available: sl<SourceRepository>().hasSource);
    if (m == null) return null;
    return source_actions.joinChapterUrl(
      sl<SourceRepository>().baseUrlFor(m.sourceId),
      m.showUrl,
    );
  }

  bool get _subscribed =>
      sl<SubscriptionStore>().contains(widget.item.sourceId, widget.item.url);

  /// Toggle new-episode (or new-chapter) alerts for this show. On subscribe we
  /// seed the baseline to the current count so only FUTURE ones alert.
  Future<void> _toggleSubscribe(MediaDetail detail) async {
    final store = sl<SubscriptionStore>();
    final item = widget.item;
    final reading =
        detail.type == ProviderType.manga || detail.type == ProviderType.novel;
    // Read before the first await: nothing below needs a fresh BuildContext,
    // and grabbing it up front avoids holding context across the async gaps.
    final l10n = context.l10n;
    if (_subscribed) {
      await store.remove(item.sourceId, item.url);
      _snack(l10n.notificationsOffFor(item.title));
    } else {
      await store.add(
        Subscription(
          sourceId: item.sourceId,
          url: item.url,
          title: item.title.isNotEmpty ? item.title : detail.title,
          cover: item.cover,
          coverHeaders: item.coverHeaders,
          lastCount: detail.episodes.length,
          mode: detail.type == ProviderType.novel
              ? ContentMode.novel
              : detail.type == ProviderType.manga
              ? ContentMode.manga
              : ContentMode.anime,
        ),
      );
      // Windows has no notification permission to ask for: alerts land in
      // the in-app inbox (and Windows notifications), so confirm directly.
      if (!_windowsDesktopUi) {
        await NotificationService.instance.init(); // ask for permission now
      }
      _snack(
        _windowsDesktopUi || await NotificationService.instance.canShowAlerts
            ? reading
                  ? l10n.youllBeNotifiedOfNewChaptersFor(item.title)
                  : l10n.youllBeNotifiedOfNewEpisodesFor(item.title)
            : l10n.allowNotificationsForAlerts,
      );
    }
    // Mirror CS subs to native so the background worker picks up the change.
    await CsNotify.sync(store.all());
    if (mounted) setState(() {});
  }

  /// Every transient message on this screen. A toast rather than a SnackBar:
  /// the bar docks to the bottom edge under the floating dock, pushes the
  /// layout around, and one is still on screen while the next arrives.
  void _snack(String msg) {
    if (!mounted) return;
    showAppToast(context, msg);
  }

  // ── Cross-source player launch — PRESERVED EXACTLY ────────────────────────

  /// Resolve every mirror for an episode, behind a blocking spinner.
  ///
  /// Deliberately not the fast path. Fast returns on the first usable link and
  /// leaves the rest resolving in the background, so a chooser built from it
  /// often shows one server out of several — you'd be picking from a list that
  /// isn't finished. Waiting costs a few seconds and shows the real choice.
  Future<List<VideoSource>> _resolveWithProgress(
    Episode ep, {
    bool fast = false,
  }) async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      // Through the router, like every other playback path on this screen.
      // Asking SourceRepository directly worked on a source page and could
      // never work on a metadata one: `zm` is a pseudo source with nothing to
      // resolve, so Play mirror always reported "no sources" for a title that
      // played perfectly from the same row. The router hands a zm:// url to
      // MetadataRepository, which resolves it to the real source's episode
      // first — exactly what Play already does.
      return await sl<CatalogueRepository>().sources(
        ep.url,
        sourceId: widget.item.sourceId,
        fast: fast,
      );
    } catch (_) {
      // A dead source shouldn't leave a spinner on screen; the caller reports
      // the empty result as "no sources found".
      return const [];
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }
  }

  /// Feeds late mirrors into an open Play-mirror sheet. CloudStream keeps
  /// resolving after the first link; everything else reports done at once, so
  /// this ends on the first poll for them. Capped so it can never spin.
  Future<void> _pollMoreMirrors(
    Episode ep,
    ValueNotifier<List<VideoSource>> live,
    ValueNotifier<bool> loadingMore,
    bool Function() closed,
  ) async {
    final repo = sl<CatalogueRepository>();
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    try {
      while (!closed() && DateTime.now().isBefore(deadline)) {
        final r = await repo.polledSources(
          ep.url,
          sourceId: widget.item.sourceId,
        );
        if (closed()) return;
        final seen = {for (final s in live.value) s.url};
        final fresh = r.sources.where((s) => !seen.contains(s.url)).toList();
        if (fresh.isNotEmpty) live.value = [...live.value, ...fresh];
        if (r.done) return;
        await Future<void>.delayed(const Duration(milliseconds: 900));
      }
    } finally {
      if (!closed()) loadingMore.value = false;
    }
  }

  /// Push a manual watched mark out to whichever trackers are connected.
  ///
  /// Only whole episode numbers: tracker progress is an integer, so a "12.5"
  /// recap or special would either round into a real episode or be rejected.
  /// Same fan-out the player uses when you finish an episode normally.
  Future<void> _scrobbleUpTo(Episode ep, MediaDetail detail) async {
    final n = ep.number;
    if (n == null || n <= 0 || n != n.truncateToDouble()) return;
    // Same kind mapping as the entry fetch above: a manga/novel mark must go
    // out as manga (plus the novel flag), with the title attached. Omitting
    // either made manual manga marks resolve as anime with no title fallback,
    // so AniList missed and MangaBaka refused while Simkl logged a false ok.
    final reading =
        detail.type == ProviderType.manga || detail.type == ProviderType.novel;
    await sl<TrackerHub>().scrobble(
      malId: detail.malId ?? widget.item.malId,
      title: detail.title,
      tmdbId: widget.item.tmdbId,
      tmdbIsTv: widget.item.tmdbIsTv,
      imdbId: widget.item.imdbId,
      episode: n.toInt(),
      season: ep.season,
      seasonEpisode: seasonEpisodeOf(detail.episodes, ep),
      kind: reading ? MediaKind.manga : MediaKind.anime,
      novel: detail.type == ProviderType.novel,
      // Asked for by hand, so it goes out even with auto-tracking off.
      auto: false,
    );
  }

  /// Open the source picker for this title from the empty episode list.
  ///
  /// A source that has gone quiet leaves a catalogue title with no episodes
  /// and a dimmed Play, and the only way out was knowing that the source name
  /// above is tappable. Same picker, same effect — [SourceMatcher.chooseSource]
  /// is what the source row itself calls.
  Future<void> _switchSource() async {
    final c = ZmodeIds.parseShow(widget.item.url);
    if (c == null || !sl.isRegistered<SourceMatcher>()) return;
    final matcher = sl<SourceMatcher>();
    final cubit = context.read<DetailCubit>();
    SourceSwitcher(
      currentId: matcher.sourceForTitle(c) ?? '',
      onChanged: (_) {},
      onInstallSources: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const ZangetsuSourcesScreen(openToRepos: true),
        ),
      ),
    ).showPicker(
      context,
      onPick: (id) async {
        if (_windowsDesktopUi) {
          // Windows (ar-1): pin THIS title only, exactly like the source pill
          // above (SourceSelectCubit.selectSource -> pinTitleToSource).
          // chooseSource re-pointed the kind-wide default, which silently
          // switched Auto Resolve off for every other title of this kind.
          final d = cubit.state.detail;
          final title = (d?.title.isNotEmpty ?? false)
              ? d!.title
              : widget.item.title;
          // P2: a source that lacks this title is NOT left pinned (an empty
          // hand-picked pin dead-ends every Play); the title stays on Auto
          // Resolve instead. See desktop_source_pick.dart.
          final m = await desktopPinTitleOrStayOnAuto(
            matcher,
            c,
            id,
            title: title,
            altTitle: d?.englishTitle ?? widget.item.englishTitle,
            metadataAliases: [
              if (d?.englishTitle != null) d!.englishTitle!,
              if (d?.nativeTitle != null) d!.nativeTitle!,
              ...?d?.synonyms,
            ],
            malId: d?.malId ?? widget.item.malId,
          );
          // No match: say why, and that the title keeps using Auto Resolve,
          // then refresh below so the page shows what it resolves to now.
          if (m == null && mounted) {
            _snack(
              context.l10n.desktopSourceLacksTitleStayAuto(
                sl<SourceRepository>().displayName(id),
              ),
            );
          }
        } else {
          await matcher.chooseSource(c, id);
        }
        // dropCache: false — the source just switched TO was never in it.
        cubit.refresh(dropCache: false);
      },
    );
  }

  /// Windows: what is saved for [ep] in [category], for the right-click
  /// menu's download rows. A finished file wins (it is what the menu can act
  /// on); else a queued/active record reads as in progress; else nothing.
  Future<({EpisodeDownloadMenuState state, DownloadRecord? record})>
  _episodeDownloadState(Episode ep, MediaDetail detail, String category) async {
    if (!sl.isRegistered<DownloadManager>()) {
      return (state: EpisodeDownloadMenuState.unavailable, record: null);
    }
    final manager = sl<DownloadManager>();
    // Downloaded show page: the row IS a saved file, whatever cut it was
    // saved in, so the menu always offers Play offline / folder / delete.
    if (_fromDownloads) {
      for (final r in _savedEpisodes) {
        if (r.episodeId == ep.id && r.season == ep.season) {
          return (state: EpisodeDownloadMenuState.done, record: r);
        }
      }
    }
    // Same lookup the batch dialog and _confirmExistingDownloads use.
    final saved = await manager.finishedForEpisode(
      sourceId: widget.item.sourceId,
      showId: widget.item.id,
      episodeId: ep.id,
      episodeUrl: ep.url,
      episodeNumber: ep.number,
      malId: detail.malId ?? widget.item.malId,
      category: category,
      season: ep.season,
    );
    if (saved != null) {
      // Windows online page: a stub is not a real download, so it gets the
      // broken rows (Download again / Delete) instead of the finished ones.
      if (await _isBrokenHere(saved)) {
        return (state: EpisodeDownloadMenuState.broken, record: saved);
      }
      return (state: EpisodeDownloadMenuState.done, record: saved);
    }
    final rec = manager.recordFor(
      widget.item.sourceId,
      widget.item.id,
      ep.id,
      category: category,
    );
    final active = switch (rec?.status) {
      DownloadStatus.downloading ||
      DownloadStatus.paused ||
      DownloadStatus.queued ||
      DownloadStatus.resolving => true,
      _ => false,
    };
    // B1: nothing in this cut, but the episode may be saved in another one
    // (a Dub download on a page that looks things up as Sub). The menu then
    // still offers Play offline / Show in folder / Delete for that file.
    if (!active) {
      final other = await _savedInAnyCut(ep, detail, category);
      if (other != null) {
        return (state: EpisodeDownloadMenuState.done, record: other);
      }
      // No real copy anywhere, but a broken one (a stub, or a file found on
      // disk that is too small) may still be saved. It is not shown as
      // downloaded, yet the menu must still be able to delete it.
      final broken = await _brokenInAnyCut(ep, detail, category);
      if (broken != null) {
        return (state: EpisodeDownloadMenuState.broken, record: broken);
      }
    }
    return (
      state: active
          ? EpisodeDownloadMenuState.inProgress
          : EpisodeDownloadMenuState.none,
      record: rec,
    );
  }

  /// Windows (B1): a finished download of [ep] saved in ANY cut whose file is
  /// still on disk, or null. Used only after the cut-exact lookup found
  /// nothing; the download manager itself stays cut-exact. Off on the phone
  /// and on the downloaded show page (which already ignores the cut).
  Future<DownloadRecord?> _savedInAnyCut(
    Episode ep,
    MediaDetail detail,
    String category,
  ) async {
    if (!_windowsDesktopUi || _fromDownloads) return null;
    if (!sl.isRegistered<DownloadManager>()) return null;
    final manager = sl<DownloadManager>();
    final candidates = savedEpisodeAnyCutCandidates(
      manager.all,
      sourceId: widget.item.sourceId,
      showId: widget.item.id,
      episodeId: ep.id,
      episodeNumber: ep.number,
      season: ep.season,
      malId: detail.malId ?? widget.item.malId,
      preferredCategory: category,
    );
    // Only a file that is on disk and big enough to be a real episode counts,
    // so a broken stub (Frieren E9, 788 KB) streams instead of playing.
    return firstRealSavedCopy(
      candidates,
      filePresent: manager.filePresent,
      sizeOnDisk: _savedFileSize,
    );
  }

  /// Windows: a broken saved copy of [ep] in any cut (file gone, or a stub),
  /// or null. Asked only after [_savedInAnyCut] found no real copy, so the
  /// right-click menu can still offer Delete download for it. Same scope as
  /// [_savedInAnyCut]: off on the phone and the downloaded show page.
  Future<DownloadRecord?> _brokenInAnyCut(
    Episode ep,
    MediaDetail detail,
    String category,
  ) async {
    if (!_windowsDesktopUi || _fromDownloads) return null;
    if (!sl.isRegistered<DownloadManager>()) return null;
    final manager = sl<DownloadManager>();
    final candidates = savedEpisodeAnyCutCandidates(
      manager.all,
      sourceId: widget.item.sourceId,
      showId: widget.item.id,
      episodeId: ep.id,
      episodeNumber: ep.number,
      season: ep.season,
      malId: detail.malId ?? widget.item.malId,
      preferredCategory: category,
      keepStubs: true,
    );
    return firstBrokenSavedCopy(
      candidates,
      filePresent: manager.filePresent,
      sizeOnDisk: _savedFileSize,
    );
  }

  /// Windows online page: whether [saved] (a cut-exact finished copy) is
  /// broken, a stub or a file that is gone, and so counts as not downloaded:
  /// Play streams, the batch dialog does not mark it, and Download fetches
  /// it again instead of saying it is already there. Always false on the
  /// phone, the TV and the downloaded show page.
  Future<bool> _isBrokenHere(DownloadRecord saved) async {
    if (!_windowsDesktopUi || _fromDownloads) return false;
    if (!sl.isRegistered<DownloadManager>()) return false;
    return savedCopyIsBroken(
      saved,
      filePresent: sl<DownloadManager>().filePresent,
      sizeOnDisk: _savedFileSize,
    );
  }

  /// A saved file's real size, or null when it cannot be read that way (a
  /// content URI, or the file is unreadable).
  static Future<int?> _savedFileSize(DownloadRecord r) async {
    final fp = r.filePath;
    if (fp == null || isUriPath(fp)) return null;
    try {
      return await File(fp).length();
    } catch (_) {
      return null;
    }
  }

  /// Windows: delete a finished download after a graphite confirm, since the
  /// file is gone for good. Repaints so the row's tick clears.
  Future<void> _deleteDownloadWithConfirm(
    DownloadRecord rec,
    String label,
  ) async {
    final ok = await showDesktopConfirm(
      context,
      title: context.l10n.deleteDownloadQuestion,
      message: context.l10n.downloadedFileWillBeDeleted(label),
      confirmLabel: context.l10n.delete,
      destructive: true,
    );
    if (!ok || !mounted) return;
    await sl<DownloadManager>().delete(rec);
    if (!mounted) return;
    setState(() {});
    _snack(context.l10n.downloadDeleted);
  }

  /// Windows (show-1): the film Download button found a finished file, so
  /// offer what people want for one instead of a new source search. Returns
  /// true when the menu handled the click (including dismissing it).
  Future<bool> _manageFinishedDownload(
    Episode ep,
    MediaDetail detail,
    String category,
  ) async {
    final found = await _episodeDownloadState(ep, detail, category);
    final rec = found.record;
    if (!mounted || rec == null) return false;
    final label = detail.title.isNotEmpty ? detail.title : widget.item.title;
    if (found.state == EpisodeDownloadMenuState.broken) {
      // A broken stub: the same rows as the episode's right-click menu
      // (fetch it again, look at it, delete it), never Play offline.
      await showDesktopContextMenu<void>(
        context,
        items: [
          DesktopMenuItem(
            label: context.l10n.download,
            icon: Icons.download_rounded,
            onTap: () =>
                unawaited(_pickSourceAndDownload(ep, detail, category)),
          ),
          DesktopMenuItem(
            label: context.l10n.showInFolder,
            icon: Icons.folder_open_rounded,
            onTap: () async {
              final path = rec.filePath;
              final shown = path != null && await revealInExplorer(path);
              if (!shown && mounted) {
                _snack(context.l10n.couldntFindDownloadedFile);
              }
            },
          ),
          DesktopMenuItem(
            label: context.l10n.deleteDownload,
            icon: Icons.delete_outline_rounded,
            destructive: true,
            onTap: () => unawaited(_deleteDownloadWithConfirm(rec, label)),
          ),
        ],
      );
      return true;
    }
    if (found.state != EpisodeDownloadMenuState.done) return false;
    await showDesktopContextMenu<void>(
      context,
      items: [
        DesktopMenuItem(
          label: context.l10n.playOffline,
          icon: Icons.play_arrow_rounded,
          onTap: () {
            if (mounted) unawaited(launchDownloadedEpisode(context, rec));
          },
        ),
        DesktopMenuItem(
          label: context.l10n.showInFolder,
          icon: Icons.folder_open_rounded,
          onTap: () async {
            final path = rec.filePath;
            final shown = path != null && await revealInExplorer(path);
            if (!shown && mounted) _snack(context.l10n.couldntFindDownloadedFile);
          },
        ),
        DesktopMenuItem(
          label: context.l10n.deleteDownload,
          icon: Icons.delete_outline_rounded,
          destructive: true,
          onTap: () => unawaited(_deleteDownloadWithConfirm(rec, label)),
        ),
        const DesktopMenuItem<void>.divider(),
        // Another cut or quality: the normal picker (it still skips a cut
        // that is already saved, with its own message).
        DesktopMenuItem(
          label: context.l10n.downloadAgain,
          icon: Icons.download_rounded,
          onTap: () => unawaited(_pickSourceAndDownload(ep, detail, category)),
        ),
      ],
    );
    return true;
  }

  /// Long-press an episode or chapter → the actions menu.
  ///
  /// Streaming gets the player rows too (choosing where it plays, this once —
  /// Settings keeps owning the standing default, so trying VLC on one episode
  /// doesn't quietly rewire every later tap). Reading gets only the marking
  /// rows, because a chapter resolves to the reader.
  ///
  /// Dismissing does nothing — a long-press that started playback on its own
  /// would be a trap.
  Future<void> _pickPlayerFor(
    List<Episode> episodes,
    int index,
    MediaDetail detail,
    String category,
  ) async {
    if (index < 0 || index >= episodes.length) return;
    final ep = episodes[index];
    final label = ep.title.trim().isNotEmpty
        ? ep.title.trim()
        : context.l10n.episodeLabel(ep.number?.toInt() ?? index + 1);
    final prefs = sl<PlaybackPrefs>();

    final resume = sl<ResumeStore>();
    final hub = sl<TrackerHub>();
    final isReading =
        detail.type == ProviderType.novel || detail.type == ProviderType.manga;
    final read = sl<ReadStore>();
    // Chapters keep their read state in ReadStore, episodes in ResumeStore —
    // and the two are keyed DIFFERENTLY. Reading keys by item.id (what the
    // chapter list and the reader both use), video by item.url. Writing a
    // chapter under the video key stored it somewhere nothing reads, so the
    // row never dimmed.
    final readShowId = widget.item.id;
    // Same pairing as the chapter list: the real source, not `zm`.
    final readSource = detail.sourceId.isNotEmpty
        ? detail.sourceId
        : widget.item.sourceId;
    bool markedDone(Episode e) {
      if (isReading) return read.finished(readSource, readShowId, e.id);
      final mark = resume.get(widget.item.sourceId, widget.item.url, e.id);
      // Phone keeps the original local-mark-only rule.
      if (!_windowsDesktopUi) return mark?.finished ?? false;
      // Windows: the exact rule the row's tick uses, so a row ticked only by
      // tracker progress offers "Mark as unwatched", and an unwatched
      // override offers "Mark as watched".
      return episodeShowsWatched(
        mark: mark,
        episodeNumber: e.number?.toInt(),
        trackerProgress: _trackerProgress,
        hasMultipleSeasons: seasonsOf(detail.episodes).length > 1,
      );
    }
    // Windows: the right-click menu also carries download rows, picked from
    // what is actually saved for this episode (finished file, queued, none).
    final download = _windowsDesktopUi && !isReading
        ? await _episodeDownloadState(ep, detail, category)
        : (state: EpisodeDownloadMenuState.unavailable, record: null);
    if (!mounted) return;
    final action = await showEpisodeActionSheet(
      context,
      reading: isReading,
      canOpenInBrowser:
          isReading &&
          source_actions.canOpenInBrowser(widget.item.sourceId, ep.url),
      episodeLabel: label,
      // Only meaningful for streaming, and the reading sheet has no row to
      // put it on — so don't go asking which external player is configured
      // for something that opens the reader.
      currentPlayerLabel: isReading
          ? ''
          : (prefs.effectiveExternalPlayerPackage.isEmpty
                ? context.l10n.builtIn
                : (prefs.externalPlayerLabel.isEmpty
                      ? context.l10n.external
                      : prefs.externalPlayerLabel)),
      isWatched: markedDone(ep),
      tracksToServices: hub.anyConnected,
      // Metadata titles only, and only when there is something to survey: a
      // source-backed title already IS one source, and a row that opens an
      // empty dialog is worse than no row.
      // Downloaded show page: no source survey ("Where to watch" is the
      // per-episode Auto Resolve, hidden there like the page's own row).
      canSurveySources:
          !_fromDownloads &&
          ZmodeIds.isZ(ep.url) &&
          sl<PlaybackResolver>().candidatesForEpisode(ep.url).isNotEmpty,
      downloadState: download.state,
    );
    if (action == null || !mounted) return;

    switch (action) {
      // ── Windows menu rows ─────────────────────────────────────────────────
      case EpisodeAction.play:
        // Exactly what a click on the row does (downloaded show page: the
        // saved file, never a stream).
        if (_fromDownloads) {
          _playSaved(index);
          return;
        }
        await _openPlayer(episodes, index, detail, category);

      case EpisodeAction.download:
        await _downloadSingle(ep, detail, category);

      case EpisodeAction.showInFolder:
        final path = download.record?.filePath;
        final shown = path != null && await revealInExplorer(path);
        if (!shown && mounted) {
          showAppToast(context, context.l10n.couldntFindDownloadedFile);
        }

      case EpisodeAction.deleteDownload:
        final rec = download.record;
        if (rec == null) return;
        await _deleteDownloadWithConfirm(rec, label);

      case EpisodeAction.pickPlayer:
        final choice = await showEpisodePlayerSheet(
          context,
          episodeLabel: label,
          defaultPackage: prefs.effectiveExternalPlayerPackage,
        );
        if (choice == null || !mounted) return;
        await _openPlayer(
          episodes,
          index,
          detail,
          category,
          playerOverride: choice,
        );
      case EpisodeAction.reloadLinks:
        // Drop the prefetch too, or the next fast resolve consumes it before
        // it ever looks at the resolved cache and hands back the same dead
        // links — the reload would look like it did nothing.
        sl<SourceRepository>().invalidateSources(
          ep.url,
          sourceId: widget.item.sourceId,
          includePrefetch: true,
        );
        // Deliberately no playback: you reload because the links died, and the
        // next thing you usually want is a different mirror. Auto-playing
        // takes that choice away and tends to fail again on the same source.
        // Re-primes in the background so the play you do make is still quick.
        // (SourceRepository.prefetch has no metadata-catalogue equivalent and
        // throws for the zm pseudo source, so skip it there.)
        if (widget.item.sourceId != ZmodeIds.sourceId) {
          sl<SourceRepository>().prefetch(
            ep.url,
            sourceId: widget.item.sourceId,
          );
        }
        if (!mounted) return;
        showAppToast(context, context.l10n.linksReloaded);

      case EpisodeAction.playMirror:
        if (usesStremioLinks(widget.item.sourceId)) {
          await _openPlayer(episodes, index, detail, category);
          return;
        }
        // Fast resolve: cached/prefetched links are instant, a cold one returns
        // on the first usable link. The sheet opens with that and the rest of
        // the mirrors are added as they land (see _pollMoreMirrors).
        final sources = await _resolveWithProgress(ep, fast: true);
        if (!mounted) return;
        if (sources.isEmpty) {
          showAppToast(context, context.l10n.noSourcesFoundForThisEpisode);
          return;
        }
        final live = ValueNotifier<List<VideoSource>>(sources);
        final loadingMore = ValueNotifier<bool>(true);
        var closed = false;
        unawaited(_pollMoreMirrors(ep, live, loadingMore, () => closed));
        final picked = await showMirrorSheet(
          context,
          episodeLabel: label,
          sources: sources,
          live: live,
          loadingMore: loadingMore,
        );
        closed = true;
        live.dispose();
        loadingMore.dispose();
        if (picked == null || !mounted) return;
        // The pick applies to this episode and nothing else — no label saved.
        // Remembering it meant re-finding the mirror by label on the next
        // open, and when that list came back without it the language fallback
        // quietly started a different server: pick vidplay, get vidstream.
        // Choosing again per episode is the honest trade.
        await _openPlayer(
          episodes,
          index,
          detail,
          category,
          initialSource: picked,
        );

      case EpisodeAction.whereToWatch:
        // Same sheet the "not on <source>" row opens, reachable for ANY
        // episode: knowing which of your sources carries an episode is useful
        // long before one of them comes up short.
        if (!await _sweepForEpisode(ep)) return;
        if (!mounted) return;
        await _openPlayer(episodes, index, detail, category);

      case EpisodeAction.openInBrowser:
        // Ask the source where this chapter lives; falls back to the plain
        // join when it can't say (see resolveChapterWebUrl).
        await source_actions.openUrlInSourceWebView(
          await source_actions.resolveChapterWebUrl(
                widget.item.sourceId,
                ep.url,
              ) ??
              '',
          title: detail.title,
        );

      case EpisodeAction.toggleWatched:
        final nowWatched = !markedDone(ep);
        if (isReading) {
          // readSource, not item.sourceId: for a metadata title item.sourceId
          // is the `zm` pseudo-source while the chapter list and reader key by
          // the real source — writing under `zm` stored the mark where nothing
          // reads, so the row never dimmed until tracker progress arrived.
          await read.setRead(readSource, readShowId, ep.id, read: nowWatched);
        } else {
          await resume.setWatched(
            widget.item.sourceId,
            widget.item.url,
            ep.id,
            watched: nowWatched,
          );
        }
        // Only forward when marking. Trackers store a high-water mark, not a
        // set, so there's no "unwatch episode 12" to send — dropping progress
        // back would be a guess at what the user wanted their list to say.
        if (!mounted) return;
        // Repaint FIRST from the already-saved mark. The tracker fan-out below
        // can stall on retries/backoff, and awaiting it here is what left the
        // row un-dimmed until the next rebuild.
        setState(() {});
        // Fire-and-forget: _scrobbleUpTo touches no context/setState, and
        // TrackerHub._fan already swallows per-tracker errors.
        if (nowWatched) unawaited(_scrobbleUpTo(ep, detail));
        showAppToast(
          context,
          isReading
              ? (nowWatched
                    ? context.l10n.markedAsRead
                    : context.l10n.markedUnread)
              : (nowWatched
                    ? context.l10n.markedAsWatched
                    : context.l10n.markedUnwatched),
        );

      case EpisodeAction.markAboveWatched:
        // Everything up to and including the one held: you came back
        // mid-season and want the backlog cleared, and excluding the episode
        // you pressed would mean marking it separately every time.
        for (var i = 0; i <= index; i++) {
          if (isReading) {
            // Same key pairing as toggleWatched above: the real source.
            await read.setRead(
              readSource,
              readShowId,
              episodes[i].id,
              read: true,
            );
          } else {
            await resume.setWatched(
              widget.item.sourceId,
              widget.item.url,
              episodes[i].id,
              watched: true,
            );
          }
        }
        // One tracker write for the highest episode, not one per episode —
        // progress is a high-water mark, so the rest are implied and firing
        // twelve updates would just rate-limit the account.
        if (!mounted) return;
        // Same repaint-first reasoning as toggleWatched above: the mark is
        // saved, so paint it now and let the tracker write finish behind.
        setState(() {});
        unawaited(_scrobbleUpTo(ep, detail));
        showAppToast(
          context,
          isReading
              ? context.l10n.markedChaptersAsRead(index + 1)
              : context.l10n.markedEpisodesAsWatched(index + 1),
        );
    }
  }

  /// Pick a link, then check that the episode and addon are still valid.
  Future<VideoSource?> _pickStremioSource(
    List<Episode> episodes,
    int index,
    MediaDetail detail, {
    // Cut used for playback; the Windows "Download this link" entry saves
    // the link under the same category.
    String? category,
  }) async {
    if (_stremioSheetOpen ||
        index < 0 ||
        index >= episodes.length ||
        !StremioRef.isRef(episodes[index].url)) {
      return null;
    }
    final ref = StremioRef.parse(episodes[index].url);
    final manager = sl<StremioManager>();
    final revision = manager.byId(ref.installationId)?.revision;
    if (!manager.canOpen(ref)) {
      _snack('This addon is no longer installed');
      return null;
    }
    _stremioSheetOpen = true;
    try {
      final title = episodes[index].title.isEmpty
          ? detail.title
          : '${detail.title} · ${episodes[index].title}';
      final picked = await showStremioEpisodeLinksSheet(
        context,
        manager: manager,
        ref: ref,
        title: title,
        bannerUrl: detail.banner ?? detail.cover,
        bannerHeaders: detail.coverHeaders,
        // Windows (show-9): right-click "Download this link" queues that
        // exact link instead of playing it.
        onDownloadLink: _windowsDesktopUi && category != null
            ? (source) => _enqueueStremioLink(
                episodes[index],
                detail,
                source,
                category,
              )
            : null,
      );
      if (!mounted || picked == null) return null;
      if (!manager.canOpen(ref, revision: revision)) {
        _snack('Addon changed — pick the link again');
        return null;
      }
      if (index >= episodes.length ||
          StremioRef.parse(episodes[index].url) != ref) {
        _snack('Episode changed — pick the link again');
        return null;
      }
      return picked;
    } catch (_) {
      if (mounted) _snack('Could not open Stremio links');
      return null;
    } finally {
      _stremioSheetOpen = false;
    }
  }

  /// Windows (show-9): queues one picked Stremio link as a download, the
  /// same way the single-download path enqueues a chosen source.
  void _enqueueStremioLink(
    Episode episode,
    MediaDetail detail,
    VideoSource source,
    String category,
  ) {
    if (!mounted) return;
    final item = widget.item;
    // Windows: keep the details for the downloaded show page.
    _cacheDetailsOnDownload(detail);
    unawaited(
      sl<DownloadManager>().enqueueSource(
        sourceId: item.sourceId,
        showId: item.id,
        showTitle: detail.title,
        cover: detail.cover ?? item.cover,
        coverHeaders: detail.coverHeaders ?? item.coverHeaders,
        showUrl: item.url,
        category: category,
        episode: episode,
        source: source,
        qualityLabel: source.quality ?? 'auto',
        // Only this link: Stremio links carry their own headers and expiry.
        fallbacks: [source],
        nowMs: DateTime.now().millisecondsSinceEpoch,
        malId: detail.malId ?? item.malId,
        anilistId: item.anilistId,
        tmdbId: detail.tmdbId ?? item.tmdbId,
        tmdbIsTv: detail.tmdbIsTv || item.tmdbIsTv,
        imdbId: detail.imdbId ?? item.imdbId,
      ),
    );
    _snack(context.l10n.addedToDownloads);
  }

  Future<void> _openPlayer(
    List<Episode> episodes,
    int index,
    MediaDetail detail,
    String category, {

    /// Set only by the long-press sheet: play this one episode in this player,
    /// ignoring the Settings default. Null keeps the existing behaviour.
    PlayerChoice? playerOverride,

    /// A mirror picked from the long-press menu, opened instead of the
    /// adaptive default. One-shot — the cubit clears it after this episode.
    VideoSource? initialSource,

    /// The main Read/Continue action rechecks cloud progress before choosing a
    /// chapter. Explicit chapter-row taps must keep the viewer's chosen chapter.
    bool resumeReading = false,
  }) async {
    // Live channels always use the Android player: it decrypts DRM channels and
    // has live controls, mpv has neither. iOS has no other player, so it stays
    // on mpv. An explicit long-press choice still wins.
    if (detail.isLive &&
        playerOverride == null &&
        Platform.isAndroid &&
        !sl<AppMode>().isTv) {
      playerOverride = (package: PlaybackPrefs.androidPlayerId, label: '');
    }
    // A finished download of this exact episode plays from disk — no sweep,
    // no links, no waiting. Exact keys first, then the source episode URL,
    // then MAL id + number — so a file saved from a source page is still
    // found from the metadata page and back.
    if (initialSource == null && index >= 0 && index < episodes.length) {
      final ep = episodes[index];
      final exactCopy = await sl<DownloadManager>().finishedForEpisode(
        sourceId: widget.item.sourceId,
        showId: widget.item.id,
        episodeId: ep.id,
        episodeUrl: ep.url,
        malId: detail.malId ?? widget.item.malId,
        episodeNumber: ep.number,
        category: category,
        season: ep.season,
      );
      // Windows online page: a broken stub streams instead of playing.
      final exact = exactCopy != null && await _isBrokenHere(exactCopy)
          ? null
          : exactCopy;
      // B1 (user's decision, 2026-11-22): when only another cut is saved,
      // Windows plays that file rather than streaming, and says so, because
      // the audio language differs from what the page asked for. The phone
      // never gets here (_savedInAnyCut returns null off Windows).
      final otherCut = exact == null
          ? await _savedInAnyCut(ep, detail, category)
          : null;
      final dl = exact ?? otherCut;
      if (otherCut != null && mounted) {
        final cut = savedCutName(otherCut.category, context.l10n);
        if (cut != null && otherCut.category != category) {
          _snack(context.l10n.desktopPlayingDownloadedCut(cut));
        }
      }
      if (dl != null) {
        if (!mounted) return;
        await launchDownloadedEpisode(
          context,
          dl,
          episodes: episodes,
          startIndex: index,
          fallbackResolveSources: (url) => sl<CatalogueRepository>().sources(
            url,
            sourceId: widget.item.sourceId,
            fast: true,
          ),
          pollSources: (url) => sl<CatalogueRepository>().polledSources(
            url,
            sourceId: widget.item.sourceId,
          ),
          playerOverride: playerOverride?.package,
          // Returning early skips the My List add below, so hand over this
          // page's item and the saved-file path adds the same entry.
          listItem: widget.item,
        );
        return;
      }
    }
    if (!mounted) return;
    if (usesStremioLinks(widget.item.sourceId, initialSource: initialSource)) {
      final picked = await _pickStremioSource(
        episodes,
        index,
        detail,
        category: category,
      );
      if (!mounted || picked == null) return;
      await _openPlayer(
        episodes,
        index,
        detail,
        category,
        playerOverride: playerOverride,
        initialSource: picked,
      );
      return;
    }
    // Only another app needs a link choice before launch; both in-app players
    // keep their automatic launch.
    final playerPackage =
        playerOverride?.package ?? sl<PlaybackPrefs>().effectiveExternalPlayerPackage;
    if (initialSource == null &&
        index >= 0 &&
        index < episodes.length &&
        playerPackage.isNotEmpty &&
        playerPackage != PlaybackPrefs.androidPlayerId) {
      final ep = episodes[index];
      final sources = await _resolveWithProgress(ep);
      if (!mounted) return;
      if (sources.isEmpty) {
        showAppToast(context, context.l10n.noSourcesFoundForThisEpisode);
        return;
      }
      final picked = await showMirrorSheet(
        context,
        episodeLabel: ep.title.isEmpty
            ? detail.title
            : '${detail.title} · ${ep.title}',
        sources: sources,
      );
      if (picked == null || !mounted) return;
      await _openPlayer(
        episodes,
        index,
        detail,
        category,
        playerOverride: playerOverride,
        initialSource: picked,
      );
      return;
    }
    // The catalogue lists this episode but the one source we checked stops
    // short of it (see [Episode.unavailable]). Say which source, and let the
    // viewer decide whether to spend the sweep — asking every installed
    // source in turn is what measured 23 seconds of frozen UI, so it is
    // offered rather than imposed. Falling through means they asked for it.
    //
    // Every play path funnels through this method, so this one check covers
    // the row tap, the grid tile, the Play button and resume.

    // Opening something other than where they left off? Offer to look at it
    // without moving their place. Asked here, before the reading/video split,
    // so all three kinds behave the same. Dismissing means "never mind" —
    // neither answer is assumed, and nothing opens.
    final reading =
        detail.type == ProviderType.novel ||
        detail.type == ProviderType.manga ||
        widget.item.type == ProviderType.novel ||
        widget.item.type == ProviderType.manga;
    final readingSourceId = _readingSourceId(detail);
    if (reading) {
      await _loadCloudReadHistory(readingSourceId);
      if (resumeReading) await _trackerProgressLookup;
      if (!mounted) return;
    }
    final resume = reading
        ? _readResumeIndex(episodes, sourceId: readingSourceId)
        : (index: _resumeIndex(episodes), hasResume: _hasVideoResume(episodes));
    if (reading && resumeReading) index = resume.index;
    if (index >= 0 && index < episodes.length && !episodes[index].available) {
      final sweep = await showEpisodeUnavailable(
        context,
        episodes[index],
        reading:
            detail.type == ProviderType.novel ||
            detail.type == ProviderType.manga,
      );
      if (!sweep || !mounted) return;
      // They asked for it, so do it HERE rather than by dropping them into
      // the player and letting it find out. Falling through only happens once
      // something playable is known to exist — and the resolver caches that
      // winner, so the player then opens straight onto it.
      if (!await _sweepForEpisode(episodes[index])) return;
      if (!mounted) return;
    }
    var peek = false;
    if (shouldAskBeforeJump(
      resumeIndex: resume.index,
      targetIndex: index,
      hasResume: resume.hasResume,
      askEnabled: jumpPromptEnabled,
    )) {
      final choice = await showJumpPrompt(context, reading: reading);
      if (choice == null || !mounted) return; // dismissed — open nothing
      peek = choice == JumpChoice.peek;
    }

    // Reading types never touch the player — route to the reader instead.
    // Both tap paths (Play button + episode-row onTap) call this same
    // function, so gating it here covers both in one place. Safety-critical:
    // a manga/novel title must never try to resolve video sources. Checks
    // BOTH the loaded detail's type and the search-result item's type —
    // provider JSON isn't normalized, so a source that disagrees between the
    // two still can't reach the player.
    final t = detail.type;
    final it = widget.item.type;
    if (t == ProviderType.novel ||
        t == ProviderType.manga ||
        it == ProviderType.novel ||
        it == ProviderType.manga) {
      // Same auto-add as the video path below — reading titles route out
      // through this early return, so without this they never got it.
      if (sl<AuthCubit>().state.isLoggedIn &&
          sl<PlaybackPrefs>().autoAddToMyList &&
          !IncognitoMode.on &&
          !_myList.contains(widget.item)) {
        _myList.add(widget.item);
        _listStatus.setStatus(widget.item, WatchStatus.watching);
      }
      await _openReader(episodes, index, detail, peek: peek);
      return;
    }

    // Auto-add this title to My List (as Watching) on play, if the user opted
    // in — mirrors the tracker auto-scrobble. Skipped in incognito and when it's
    // already listed; fire-and-forget so it never delays playback.
    if (sl<AuthCubit>().state.isLoggedIn &&
        sl<PlaybackPrefs>().autoAddToMyList &&
        !IncognitoMode.on &&
        !_myList.contains(widget.item)) {
      _myList.add(widget.item);
      _listStatus.setStatus(widget.item, WatchStatus.watching);
    }

    // The player uses these counts to offer its own version switch.
    final available = <String>[
      if ((detail.subCount ?? 0) > 0) 'sub',
      if ((detail.dubCount ?? 0) > 0) 'dub',
    ];
    final availableCategories = available.isEmpty ? [category] : available;

    // Titles with a picker launch the version shown in the episode list.
    final preferred =
        sl<TitlePrefsStore>().category(widget.item.sourceId, widget.item.url) ??
        sl<PlaybackPrefs>().defaultCategory;
    final launchCategory =
        !showSubDubFor(detail) && availableCategories.contains(preferred)
        ? preferred
        : category;

    // Scrobble ids. A movie-typed title from a movie source (e.g. MovieBox) may
    // actually be anime — resolve its MAL id here so AniList/MAL scrobble. We
    // await the detail's in-flight promotion (started on load); if Play beat it,
    // resolve inline. Best-effort — a miss just leaves it a movie.
    var malId = detail.malId ?? widget.item.malId;
    var scrobbleTitle = detail.type == ProviderType.anime ? detail.title : null;
    if (malId == null && detail.type == ProviderType.movie) {
      try {
        final promoted =
            await (context.read<DetailCubit>().animePromotion ??
                sl<MetadataEnrichment>().promoteMovieToAnimeMalId(detail));
        if (promoted != null) {
          malId = promoted;
          scrobbleTitle = detail.title;
        }
      } catch (_) {
        /* leave as a movie */
      }
    }
    if (!mounted) return;

    Navigator.of(context)
        .push(
          episodePlayerRoute(
            nativeHandoff:
                Platform.isAndroid &&
                stremioPlayerPackage(
                      widget.item.sourceId,
                      initialSource,
                      playerOverride?.package ??
                          sl<PlaybackPrefs>().effectiveExternalPlayerPackage,
                    ) ==
                    PlaybackPrefs.androidPlayerId,
            builder: (_) => PlayerScreen(
              playerOverride: playerOverride?.package,
              initialSource: initialSource,
              sourceId: widget.item.sourceId,
              episodes: episodes,
              startIndex: index,
              resume: sl<ResumeStore>(),
              resolveSources: (u) => sl<CatalogueRepository>().sources(
                u,
                sourceId: widget.item.sourceId,
                fast: true,
              ),
              // The resolve above returns on the first usable link so playback
              // starts fast; the remaining mirrors keep resolving natively. This
              // lets the Sources sheet pick them up once they land.
              pollSources: (u) => sl<CatalogueRepository>().polledSources(
                u,
                sourceId: widget.item.sourceId,
              ),
              history: sl<WatchHistory>(),
              showTitle: detail.title,
              showDescription: detail.description,
              cover: detail.cover ?? widget.item.cover,
              loadingLogo: _logoUrl ?? widget.item.titleLogo,
              loadingBackdrop: detail.banner ?? widget.item.banner,
              coverHeaders: detail.coverHeaders ?? widget.item.coverHeaders,
              showUrl: widget.item.url,
              downloadShowId: widget.item.id,
              category: launchCategory,
              malId: malId,
              scrobbleTitle: scrobbleTitle,
              tmdbId: detail.tmdbId ?? widget.item.tmdbId,
              tmdbIsTv: detail.tmdbIsTv,
              imdbId: detail.imdbId ?? widget.item.imdbId,
              availableCategories: availableCategories,
              peek: peek,
              isMovie: detail.isFilm,
            ),
          ),
          // Same reason as the reader's [_refreshAfterReading]: ResumeStore has no
          // change notification and this push was fire-and-forget, so a finished
          // episode stayed un-greyed until something else rebuilt the screen.
          //
          // Unlike the reader there is no key mismatch here — the player writes
          // under (item.sourceId, item.url) and the list reads the same pair — so
          // this is the whole fix. The list is a SliverList.builder, so the
          // rebuild touches the visible rows, not the full episode count.
        )
        .then(_refreshAfterReading);
  }

  /// Asks every installed source for this episode and shows them answering.
  /// True once the viewer has picked one that can play it.
  ///
  /// A sheet rather than a spinner: the sweep takes seconds on a real library,
  /// and if someone is going to wait they should see who is being asked, which
  /// sources have it, and get to take one — rather than watch a spinner and be
  /// handed whichever source happened to answer first.
  Future<bool> _sweepForEpisode(Episode ep) async {
    final picked = await showEpisodeSourcesSheet(context, episode: ep);
    if (picked == null || !mounted) return false;
    // Hand the resolver the result the sheet already has, so opening the
    // player doesn't repeat the work the viewer just watched happen.
    await sl<PlaybackResolver>().useProbed(ep.url, picked);
    return mounted;
  }

  /// Routes a reading-type title (manga/novel) to its reader instead of the
  /// player. [chapters] mirrors [_openPlayer]'s `episodes` list; [index] is
  /// the tapped/resume chapter. Prefers `detail.type`; falls back to
  /// `widget.item.type` for the disagreeing-provider-JSON case the guard
  /// above also covers, so a mismatch still lands on the right reader
  /// instead of silently doing nothing.
  /// Re-read the chapter list's state after the reader closes.
  ///
  /// [ReadStore] is a plain Hive box with no change notification, and the push
  /// below was fire-and-forget, so a chapter finished in the reader stayed
  /// un-dimmed until something else happened to rebuild this screen — leaving
  /// on the app and coming back showed it correctly, which is what made it
  /// look like the read was not being saved. It always was.
  ///
  /// Deliberately scoped to the READER only. The video player push has the
  /// same shape, but episodes read their state from [ResumeStore] through a
  /// different path; changing that is a separate job and not worth risking
  /// here.
  void _refreshAfterReading(Object? _) {
    if (mounted) setState(() {});
  }

  Future<void> _openReader(
    List<Episode> chapters,
    int index,
    MediaDetail detail, {
    bool peek = false,
  }) async {
    final readingType =
        (detail.type == ProviderType.novel || detail.type == ProviderType.manga)
        ? detail.type
        : widget.item.type;
    // Cloud history syncs the last chapter position, while ReadStore is local.
    // Bridge it once before opening the reader, using this provider's chapter
    // ID. Never overwrite an existing local mark or save a look-ahead preview.
    final sourceId = _readingSourceId(detail);
    final entry = _readingHistoryEntry(sourceId);
    final positions = sl<ReadStore>();
    if (!peek &&
        entry != null &&
        !entry.finished &&
        entry.total > 0 &&
        index >= 0 &&
        index < chapters.length &&
        readingHistoryChapter(chapters, entry) == index &&
        (positions.get(sourceId, widget.item.id, chapters[index].id) == null ||
            entry.updatedMs >
                positions.updatedMs(
                  sourceId,
                  widget.item.id,
                  chapters[index].id,
                ))) {
      await positions.save(
        sourceId,
        widget.item.id,
        chapters[index].id,
        pos: entry.pos.clamp(0, entry.total),
        total: entry.total,
      );
      if (!mounted) return;
    }
    switch (readingType) {
      case ProviderType.novel:
        Navigator.of(context)
            .push(
              MaterialPageRoute(
                builder: (_) => NovelReaderScreen(
                  sourceId: _readingSourceId(detail),
                  // item.id, NOT detail.id: the chapter list and the action
                  // sheet both read this title's marks under item.id, so writing
                  // them under the source's own id put them where nothing looks.
                  // In Z Mode the two differ (canonical `mal:…` vs the matched
                  // source's show id), which is why a chapter dimmed on some
                  // titles and never on others.
                  showId: widget.item.id,
                  showUrl: widget.item.url,
                  showTitle: detail.title,
                  cover: detail.cover ?? widget.item.cover,
                  chapters: chapters,
                  startIndex: index,
                  malId: detail.malId ?? widget.item.malId,
                  peek: peek,
                ),
              ),
            )
            .then(_refreshAfterReading);
        return;
      case ProviderType.manga:
        Navigator.of(context)
            .push(
              MaterialPageRoute(
                builder: (_) => MangaReaderScreen(
                  sourceId: _readingSourceId(detail),
                  // item.id, NOT detail.id: the chapter list and the action
                  // sheet both read this title's marks under item.id, so writing
                  // them under the source's own id put them where nothing looks.
                  // In Z Mode the two differ (canonical `mal:…` vs the matched
                  // source's show id), which is why a chapter dimmed on some
                  // titles and never on others.
                  showId: widget.item.id,
                  showUrl: widget.item.url,
                  showTitle: detail.title,
                  cover: detail.cover ?? widget.item.cover,
                  chapters: chapters,
                  startIndex: index,
                  malId: detail.malId ?? widget.item.malId,
                  peek: peek,
                ),
              ),
            )
            .then(_refreshAfterReading);
        return;
      case ProviderType.anime:
      case ProviderType.movie:
        return; // unreachable — _openPlayer only calls this for reading types
    }
  }

  /// Push the in-app trailer player for a resolved YouTube id.
  void _openTrailer(String videoId) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => TrailerScreen(videoId: videoId)));
  }

  /// Netflix-style download label for the FIRST episode of the current season,
  /// e.g. "Download S1:E1". Falls back to a plain "Download" when there are no
  /// episodes to reference. (No downloads yet — label only; the button snacks.)
  String _downloadLabel(
    AppLocalizations l10n,
    List<Episode> seasonEps,
    bool hasMultipleSeasons,
    int currentSeason,
  ) {
    if (seasonEps.isEmpty) return l10n.download;
    final first = seasonEps.first;
    final epNum = first.number?.toInt() ?? 1;
    if (hasMultipleSeasons) {
      return l10n.downloadSeasonEpisode(currentSeason, epNum);
    }
    return l10n.downloadEpisodeLabel(epNum);
  }

  /// Whether video progress exists at all for this title — the jump prompt has
  /// nothing to protect on a title that's never been opened, and
  /// [_resumeIndex] alone can't say, since it returns 0 both for "start over"
  /// and for "you stopped in episode 1".
  bool _hasVideoResume(List<Episode> eps) {
    final store = sl<ResumeStore>();
    for (final e in eps) {
      // An "unwatched" override row is not progress (see _isResumeMark).
      if (_isResumeMark(store.get(widget.item.sourceId, widget.item.url, e.id))) {
        return true;
      }
    }
    return false;
  }

  /// Whether a stored row counts as real progress for Continue/resume. A
  /// zero-position "Mark as unwatched" override (Windows) only exists to veto
  /// tracker ticks, so it must not become the Continue target.
  static bool _isResumeMark(ResumeMark? mark) =>
      mark != null && !mark.isUnwatchedOverride;

  /// A film shows "Movie · 1h 52m" where an episode list would be.
  String? _filmMeta(MediaDetail detail) {
    if (!detail.isFilm) return null;
    final m = detail.durationMins;
    if (m == null || m <= 0) return context.l10n.movie;
    return m >= 60
        ? '${context.l10n.movie} · ${m ~/ 60}h ${m % 60}m'
        : '${context.l10n.movie} · $m min';
  }

  /// Walk episodes and return the best resume target index. PRESERVED.
  int _resumeIndex(List<Episode> eps) {
    final store = sl<ResumeStore>();
    int? highestMarked;
    for (int j = 0; j < eps.length; j++) {
      final mark = store.get(widget.item.sourceId, widget.item.url, eps[j].id);
      if (_isResumeMark(mark)) {
        highestMarked = j;
      }
    }
    if (highestMarked == null) return 0;
    final mark = store.get(
      widget.item.sourceId,
      widget.item.url,
      eps[highestMarked].id,
    )!;
    if (!mark.finished) return highestMarked;
    if (highestMarked + 1 < eps.length) return highestMarked + 1;
    return highestMarked;
  }

  /// Which episode Play opens, and whether that reads as "Continue". Local
  /// playback wins when present (unchanged behaviour); with NO local marks it
  /// falls back to the connected tracker's watched count — resume the first
  /// episode beyond it — so a title you've only progressed on AniList/MAL/Simkl
  /// still says "Continue". Single-season only, same limit as the grey-out.
  ({int index, bool hasResume}) _resumeTarget(List<Episode> eps) {
    if (eps.isEmpty) return (index: 0, hasResume: false);
    final store = sl<ResumeStore>();
    final hasLocal = eps.any(
      (e) => _isResumeMark(
        store.get(widget.item.sourceId, widget.item.url, e.id),
      ),
    );
    if (hasLocal) return (index: _resumeIndex(eps), hasResume: true);
    // Watch history next: it is already on this PC, while the tracker answer
    // below arrives over the network a moment later. A title opened from My
    // List often carries a different source/url than the one you watched on,
    // so match by url, id, MAL id or title rather than by source.
    final history = _historyFor(widget.item);
    final watchedNumber = history?.episodeNumber;
    if (history != null && watchedNumber != null) {
      final j = eps.indexWhere((e) => e.number == watchedNumber);
      if (j >= 0) {
        final next = history.finished && j + 1 < eps.length ? j + 1 : j;
        return (index: next, hasResume: true);
      }
    }
    final p = _trackerProgress;
    if (p != null && p > 0 && seasonsOf(eps).length <= 1) {
      // An episode the user marked unwatched at/below the tracker's count is
      // the real gap, so Continue starts there rather than past the count.
      for (var j = 0; j < eps.length; j++) {
        final n = eps[j].number?.toInt();
        if (n == null || n > p) continue;
        final mark = store.get(widget.item.sourceId, widget.item.url, eps[j].id);
        if (mark?.markedUnwatched ?? false) return (index: j, hasResume: true);
      }
      for (var j = 0; j < eps.length; j++) {
        final n = eps[j].number?.toInt();
        if (n != null && n > p) return (index: j, hasResume: true);
      }
    }
    return (index: 0, hasResume: false);
  }

  /// The newest watch-history entry for [item] (history is newest first),
  /// matched across sources by page url, show id, MAL id or exact title.
  HistoryEntry? _historyFor(MediaItem item) {
    if (!sl.isRegistered<WatchHistory>()) return null;
    final title = item.title.trim().toLowerCase();
    // History is only a hint for where to resume, so an unreadable store
    // (its Hive box not open yet, as in widget tests) just means "no entry"
    // instead of breaking the whole page build.
    final List<HistoryEntry> entries;
    try {
      entries = sl<WatchHistory>().all();
    } catch (_) {
      return null;
    }
    for (final e in entries) {
      if (e.showUrl == item.url ||
          e.showId == item.id ||
          (item.malId != null && e.malId == item.malId) ||
          (title.isNotEmpty && e.showTitle.trim().toLowerCase() == title)) {
        return e;
      }
    }
    return null;
  }

  /// Reading counterpart of [_resumeTarget]: walks the chapters for the
  /// highest one carrying a saved reading position (per-chapter, from
  /// [ReadStore] — the reader's own scroll/page progress), advancing past it
  /// once it's finished — same rule [_resumeIndex] applies to video resume
  /// marks. Keyed the same way [NovelReaderScreen] saves them: showId is
  /// [MediaItem.id], not the show url (see `_openReader`).
  ///
  /// With NO local mark (e.g. this device never opened a chapter, or the
  /// reader's per-chapter position was never saved) it falls back to
  /// [ReadHistory] — the cloud-synced last-read chapter — the same way
  /// [_resumeTarget] falls back to the tracker's watched count for video.
  /// Only when both come up empty does this say "start over" (chapter 0).
  String _readingSourceId(MediaDetail detail) =>
      detail.sourceId.isNotEmpty ? detail.sourceId : widget.item.sourceId;

  /// Source-specific chapter IDs may change, but a canonical title ID does not.
  /// Use the newest matching history across sources only for canonical titles;
  /// plain provider IDs must never collide with another source's title.
  ReadEntry? _readingHistoryEntry(String sourceId) {
    final history = sl<ReadHistory>();
    final exact = history.get(sourceId, widget.item.id);
    if (!RegExp(r'^(?:al|mal):\d+$').hasMatch(widget.item.id)) return exact;
    return readingHistoryForTitle(
      history.all(),
      sourceId: sourceId,
      showId: widget.item.id,
      type: widget.item.type,
    );
  }

  ({int index, bool hasResume}) _readResumeIndex(
    List<Episode> chapters, {
    required String sourceId,
  }) {
    if (chapters.isEmpty) return (index: 0, hasResume: false);
    final store = sl<ReadStore>();
    int? highestMarked;
    for (var j = 0; j < chapters.length; j++) {
      if (store.get(sourceId, widget.item.id, chapters[j].id) != null) {
        highestMarked = j;
      }
    }
    final entry = _readingHistoryEntry(sourceId);
    final synced = readingHistoryTarget(chapters, entry: entry);
    if (highestMarked != null) {
      // A local mark from yesterday must not hide progress synced from the
      // phone today. Manual "mark read" actions also carry a timestamp, so a
      // newer deliberate local change still wins. Legacy marks use zero.
      if (entry != null &&
          synced.hasResume &&
          entry.updatedMs >
              store.updatedMs(
                sourceId,
                widget.item.id,
                chapters[highestMarked].id,
              )) {
        return synced;
      }
      if (!store.finished(
        sourceId,
        widget.item.id,
        chapters[highestMarked].id,
      )) {
        return (index: highestMarked, hasResume: true);
      }
      // Not highestMarked + 1: a multi-group source lists every group's
      // release in one list, so the next ROW is the same chapter again from
      // another group. Stay with the group that was read.
      final next =
          adjacentChapterIndex(chapters, highestMarked, step: 1) ??
          highestMarked;
      return (index: next, hasResume: true);
    }
    return readingHistoryTarget(
      chapters,
      entry: entry,
      completedChapters: _trackerProgress,
    );
  }

  Future<ReadEntry?> _loadCloudReadHistory(String sourceId) {
    final history = sl<ReadHistory>();
    final showId = widget.item.id;
    final key = (sourceId, showId);
    final pending = _cloudReadHistoryLookups[key];
    if (pending != null) return pending;
    if (!_cloudReadHistoryChecked.add(key)) {
      return Future.value(history.get(sourceId, showId));
    }

    final future = () async {
      try {
        final entry = await history.refreshFromCloud(sourceId, showId);
        if (entry != null && mounted) setState(() {});
        return entry;
      } catch (_) {
        return null;
      } finally {
        _cloudReadHistoryLookups.remove(key);
      }
    }();
    _cloudReadHistoryLookups[key] = future;
    return future;
  }

  // ── Downloads ─────────────────────────────────────────────────────────────

  /// The main Download button. A single movie/episode goes straight to the
  /// server picker; a multi-episode title opens the batch sheet (season chips +
  /// tappable episode selection + quality).
  Future<void> _openDownloadSheet({
    required MediaDetail detail,
    required String category,
    required Map<int, List<Episode>> episodesBySeason,
    required int initialSeason,
  }) async {
    final total = episodesBySeason.values.fold<int>(0, (a, b) => a + b.length);
    if (total == 0) {
      _snack(context.l10n.noEpisodesToDownload);
      return;
    }
    if (total == 1) {
      // Windows: a finished film opens its file menu instead of re-searching.
      if (_windowsDesktopUi &&
          await _manageFinishedDownload(
            episodesBySeason.values.first.first,
            detail,
            category,
          )) {
        return;
      }
      if (!mounted) return;
      await _pickSourceAndDownload(
        episodesBySeason.values.first.first,
        detail,
        category,
      );
      return;
    }
    // Sub/Dub the title actually offers; the sheet only shows the toggle when
    // there's more than one. Defaults to the page's current category (seeded
    // from the per-title remembered choice).
    final availableCategories = <String>[
      if ((detail.subCount ?? 0) > 0) 'sub',
      if ((detail.dubCount ?? 0) > 0) 'dub',
    ];
    if (_windowsDesktopUi) {
      // Windows: centered batch dialog instead of the phone bottom sheet.
      // Same record type, so _startDownload (with its existing-file check)
      // enqueues exactly like the phone path.
      final choice = await showDialog<DesktopBatchDownloadChoice>(
        context: context,
        builder: (_) => DesktopBatchDownloadDialog(
          title: detail.title,
          episodesBySeason: episodesBySeason,
          // B3: grows with the page while the dialog is open.
          liveEpisodesBySeason: _batchEpisodesLive,
          initialSeason: initialSeason,
          initialCategory: category,
          availableCategories: availableCategories,
          coverUrl: detail.cover ?? widget.item.cover ?? '',
          coverHeaders: detail.coverHeaders ?? widget.item.coverHeaders,
          wideCoverUrl: _desktopWideEpisodeArt(widget.item, detail),
          resolve: (ep) => sl<CatalogueRepository>().sources(
            ep.url,
            sourceId: widget.item.sourceId,
          ),
          resolveEpisodes: _episodesByCategory,
          downloadedIds: (cut, eps) => _downloadedEpisodeIds(detail, cut, eps),
          estimateSize: _estimateBatchEpisodeSize,
          readFreeBytes: () =>
              windowsDownloadFreeBytes(sl<DownloadPrefs>().locationUri),
          // Bounded first-episode probe with the playback fallback chain.
          searchSources: (ep, cut) => episodeDownloadSourceSearch(
            episode: ep,
            category: cut,
            sourceId: widget.item.sourceId,
            preferredSourceId: detail.sourceId,
          ),
        ),
      );
      if (choice == null || !mounted) return;
      _startDownload(
        detail,
        choice.category,
        choice.quality,
        choice.episodes,
        server: choice.server,
        // Each episode then resolves from the source the probe settled on.
        resolveSourceId: _pickedResolveSource(choice.sourceId),
      );
      return;
    }
    final res =
        await showModalBottomSheet<
          ({
            String quality,
            String category,
            List<Episode> episodes,
            VideoSource? server,
          })
        >(
          context: context,
          backgroundColor: AppColors.surface,
          isScrollControlled: true,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          builder: (_) => _DownloadSheet(
            // Phone-only Minimal wheel (Settings → Interface). TV stays on the
            // well-tested Classic grid regardless of the pref.
            minimal:
                !sl<AppMode>().isTv &&
                sl<PlaybackPrefs>().batchDownloadStyle == 'minimal',
            title: detail.title,
            episodesBySeason: episodesBySeason,
            initialSeason: initialSeason,
            initialCategory: category,
            availableCategories: availableCategories,
            coverUrl: detail.cover ?? widget.item.cover ?? '',
            coverHeaders: detail.coverHeaders ?? widget.item.coverHeaders,
            resolve: (ep) => sl<CatalogueRepository>().sources(
              ep.url,
              sourceId: widget.item.sourceId,
            ),
            resolveEpisodes: _episodesByCategory,
          ),
        );
    if (res == null || !mounted) return;
    _startDownload(
      detail,
      res.category,
      res.quality,
      res.episodes,
      server: res.server,
    );
  }

  /// One-episode size probe for the Windows batch dialog, sharing the host
  /// cooldown admission that DownloadSizePreview uses.
  static Future<DownloadSizeEstimate?> _estimateBatchEpisodeSize(
    VideoSource source,
    Episode episode,
    String quality,
  ) async {
    final prefs = sl<DownloadPrefs>();
    final estimator = DownloadSizeEstimator(
      cooldownUntil: (uri) => prefs.hostCooldownUntil(uri),
      onRateLimited: (uri, hint) => prefs.rememberHostCooldown(uri, hint),
    );
    try {
      return await estimator.estimate(
        source,
        runtimeMinutes: episode.runtimeMinutes,
        quality: quality == 'best' ? null : quality,
      );
    } finally {
      estimator.dispose();
    }
  }

  /// Episode ids already saved for [category], using the same lookup as
  /// [_confirmExistingDownloads] so the batch dialog marks what it would skip.
  Future<Set<String>> _downloadedEpisodeIds(
    MediaDetail detail,
    String category,
    List<Episode> episodes,
  ) async {
    final manager = sl<DownloadManager>();
    final ids = <String>{};
    for (final ep in episodes) {
      final saved = await manager.finishedForEpisode(
        sourceId: widget.item.sourceId,
        showId: widget.item.id,
        episodeId: ep.id,
        episodeUrl: ep.url,
        episodeNumber: ep.number,
        malId: detail.malId ?? widget.item.malId,
        category: category,
        season: ep.season,
      );
      if (saved != null && !await _isBrokenHere(saved)) ids.add(ep.id);
    }
    return ids;
  }

  /// Re-resolve a title's episodes for a given sub/dub [category] (without
  /// touching the detail page's own toggle), grouped by season.
  Future<Map<int, List<Episode>>> _episodesByCategory(String category) async {
    final d = await sl<CatalogueRepository>().detail(
      widget.item.url,
      category: category,
      sourceId: widget.item.sourceId,
    );
    // Best-effort per-episode descriptions on a category switch. Prefer the
    // cubit's resolved detail (promoted malId for movie-source anime).
    var eps = d.episodes;
    if (mounted) {
      final cd = context.read<DetailCubit>().state.detail ?? d;
      eps = await sl<EpisodeMetadataService>().enrich(
        episodes: eps,
        type: cd.type,
        malId: cd.malId,
        tmdbId: cd.tmdbId,
        tmdbIsTv: cd.tmdbIsTv,
      );
    }
    final byS = <int, List<Episode>>{};
    for (final e in eps) {
      (byS[seasonOf(e) ?? 1] ??= <Episode>[]).add(e);
    }
    if (byS.isEmpty) byS[1] = eps;
    return byS;
  }

  /// Per-episode / movie download → resolve sources, let the user pick a
  /// server/mirror, then download that exact url + headers.
  Future<void> _downloadSingle(
    Episode ep,
    MediaDetail detail,
    String category,
  ) => _pickSourceAndDownload(ep, detail, category);

  /// Manga/novel chapter → straight to the chapter downloader. No source
  /// picker here: a chapter has one url, not a list of mirrors to choose from.
  Future<void> _downloadChapter(Episode ep, MediaDetail detail) =>
      _downloadChapters([ep], detail);

  /// Same thing for a batch — one queue write for the lot rather than one per
  /// chapter, which is what a "download all" on a long series needs.
  Future<void> _downloadChapters(List<Episode> eps, MediaDetail detail) {
    final item = widget.item;
    // The SOURCE that owns these chapters, not the item's id. A metadata
    // title's item is the `zm` pseudo-source, and the queue later asks
    // `pages(chapterUrl, sourceId:)` — with `zm` that reaches the source
    // registry, which has no such source, so every manga download failed.
    // The reader already opens with `detail.sourceId` for the same reason.
    final sourceId = detail.sourceId.isNotEmpty
        ? detail.sourceId
        : item.sourceId;
    return sl<ChapterDownloader>().enqueueMany(
      chapters: eps,
      sourceId: sourceId,
      showId: item.id,
      showTitle: detail.title,
      cover: detail.cover ?? item.cover,
      coverHeaders: detail.coverHeaders ?? item.coverHeaders,
      mode: detail.type == ProviderType.novel
          ? ContentMode.novel
          : ContentMode.manga,
    );
  }

  Future<void> _pickSourceAndDownload(
    Episode ep,
    MediaDetail detail,
    String category,
  ) async {
    final item = widget.item;
    _SingleDownloadChoice? res;
    // Windows: the real source the picked links came from, so retries of a
    // catalogue (`zm`) download ask that same source again.
    String? resolveSourceId;
    if (_windowsDesktopUi) {
      final choice = await showDialog<DesktopSingleDownloadChoice>(context: context,
        builder: (_) => DesktopSingleDownloadDialog(episode: ep, season: seasonOf(ep) ?? 1,
          initialCategory: category, availableCategories: [
            if ((detail.subCount ?? 0) > 0) 'sub', if ((detail.dubCount ?? 0) > 0) 'dub'],
          resolveEpisodes: _episodesByCategory,
          // Bounded per-source search with the playback fallback chain; the
          // show page's matched source is asked first.
          searchSources: (episode, cut) => episodeDownloadSourceSearch(
            episode: episode, category: cut, sourceId: item.sourceId,
            preferredSourceId: detail.sourceId),
          resolveSources: (episode, cut) {
            final repo = sl<CatalogueRepository>();
            // Metadata episode URLs are shared across cuts; pass intent directly.
            // Ordinary source URLs already identify their sub/dub episode.
            final metadata = repo is MetadataRepository ? repo
                : ZmodeIds.isZ(episode.url) && sl.isRegistered<MetadataRepository>()
                    ? sl<MetadataRepository>() : null;
            return metadata != null
                ? metadata.sources(episode.url, sourceId: item.sourceId, category: cut)
                : repo.sources(episode.url, sourceId: item.sourceId);
          }));
      if (choice == null || !mounted) return;
      final pending = await _confirmExistingDownloads(detail, choice.category, [choice.episode]);
      if (!mounted || pending.isEmpty) return;
      // Adapt the desktop dialog's pick to the shared single-download record
      // so both paths enqueue the same way.
      res = (
        chosen: choice.chosen,
        all: choice.all,
        episode: choice.episode,
        category: choice.category,
      );
      resolveSourceId = _pickedResolveSource(choice.sourceId);
    } else {
      res = await showModalBottomSheet<_SingleDownloadChoice>(
        context: context,
        backgroundColor: AppColors.surface,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (_) => _SourcePickerSheet(
          title: ep.title.trim().isNotEmpty ? ep.title : detail.title,
          category: category,
          episode: ep,
          availableCategories: [
            if ((detail.subCount ?? 0) > 0) 'sub',
            if ((detail.dubCount ?? 0) > 0) 'dub',
          ],
          resolveEpisodes: _episodesByCategory,
          resolve: (episode) => sl<CatalogueRepository>().sources(
            episode.url,
            sourceId: item.sourceId,
          ),
        ),
      );
    }
    if (res == null || !mounted) return;
    if (resolveSourceId != null) {
      sl<DownloadManager>().hintResolveSource(sourceId: item.sourceId,
        showId: item.id, episodeIds: [res.episode.id], category: res.category,
        resolveSourceId: resolveSourceId);
    }
    if (_windowsDesktopUi) {
      // Windows: the link was picked by hand in the server dialog, so retries
      // stay on that exact server and SUB/DUB kind (no silent switch).
      sl<DownloadManager>().hintPinnedServer(sourceId: item.sourceId,
        showId: item.id, episodeId: res.episode.id, category: res.category);
    }
    // Windows: keep the details for the downloaded show page.
    _cacheDetailsOnDownload(detail);
    unawaited(
      sl<DownloadManager>().enqueueSource(
        sourceId: item.sourceId,
        showId: item.id,
        showTitle: detail.title,
        cover: detail.cover ?? item.cover,
        coverHeaders: detail.coverHeaders ?? item.coverHeaders,
        showUrl: item.url,
        category: res.category,
        episode: res.episode,
        source: res.chosen,
        qualityLabel: res.chosen.quality ?? 'auto',
        fallbacks: res.all,
        nowMs: DateTime.now().millisecondsSinceEpoch,
        malId: detail.malId ?? item.malId,
        anilistId: item.anilistId,
        tmdbId: detail.tmdbId ?? item.tmdbId,
        tmdbIsTv: detail.tmdbIsTv || item.tmdbIsTv,
        imdbId: detail.imdbId ?? item.imdbId,
      ),
    );
    _snack(context.l10n.addedToDownloads);
  }

  /// A picked source worth saving on the record: only for catalogue (`zm`)
  /// titles, whose record key stays on the catalogue entry (so the show page
  /// still finds it) while re-resolves ask the source the links came from.
  String? _pickedResolveSource(String? picked) =>
      picked != null && picked.isNotEmpty && picked != widget.item.sourceId &&
          (widget.item.sourceId == ZmodeIds.sourceId || ZmodeIds.isZ(widget.item.url))
      ? picked
      : null;

  /// Unknown-language recovered files require an explicit reuse choice. This
  /// only filters this request; it never relabels media or changes its owner.
  Future<List<Episode>> _confirmExistingDownloads(MediaDetail detail,
      String category, List<Episode> episodes) async {
    if (!_windowsDesktopUi) return episodes;
    final manager = sl<DownloadManager>();
    final remaining = <Episode>[];
    final recovered = <Episode, DownloadRecord>{};
    final suggestions = recoveredDownloadSuggestions(title: detail.title,
        episodes: episodes, records: manager.all);
    for (final ep in episodes) {
      final saved = await manager.finishedForEpisode(sourceId: widget.item.sourceId,
        showId: widget.item.id, episodeId: ep.id, episodeUrl: ep.url,
        episodeNumber: ep.number, malId: detail.malId ?? widget.item.malId,
        category: category, season: ep.season);
      // A broken stub is not "already downloaded": it is fetched again.
      if (saved != null && !await _isBrokenHere(saved)) continue;
      remaining.add(ep);
      final candidate = suggestions[ep];
      if (candidate != null && await manager.filePresent(candidate)) recovered[ep] = candidate;
    }
    if (!mounted) return const [];
    if (recovered.isEmpty) {
      if (remaining.isEmpty) _snack(context.l10n.desktopEpisodesAlreadyDownloaded);
      return remaining;
    }
    // show-13: say "Dubbed"/"Subbed" rather than the raw category id.
    final label = category == 'dub'
        ? context.l10n.dubbed
        : category == 'sub'
        ? context.l10n.subbed
        : category;
    final reuse = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: Text(context.l10n.existingDownloadedEpisodes),
      content: Text(context.l10n.recoveredFilesQuestion(recovered.length, label)),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false),
          child: Text(context.l10n.downloadSelectedVersion)),
        FilledButton(onPressed: () => Navigator.pop(context, true),
          child: Text(context.l10n.useExistingFiles))]));
    if (!mounted || reuse == null) return const [];
    return reuse ? omitReusableDownloads(remaining, recovered, manager.filePresent) : remaining;
  }

  /// Windows online page: removes the broken stub saved under the same key
  /// as each of [episodes] (its file goes to the Recycle Bin), so the new
  /// download can take its place. The download manager skips a key whose
  /// finished file is still there, however small, so without this Download
  /// on a broken episode did nothing.
  Future<void> _dropBrokenCopies(
    MediaDetail detail,
    String category,
    List<Episode> episodes,
  ) async {
    if (!_windowsDesktopUi || _fromDownloads) return;
    final manager = sl<DownloadManager>();
    for (final ep in episodes) {
      final saved = await manager.finishedForEpisode(
        sourceId: widget.item.sourceId,
        showId: widget.item.id,
        episodeId: ep.id,
        episodeUrl: ep.url,
        episodeNumber: ep.number,
        malId: detail.malId ?? widget.item.malId,
        category: category,
        season: ep.season,
      );
      if (saved == null || !await _isBrokenHere(saved)) continue;
      final atKey = manager.recordFor(
        widget.item.sourceId,
        widget.item.id,
        ep.id,
        category: category,
      );
      final sameKey = atKey != null && atKey.id == saved.id;
      if (sameKey) await manager.delete(saved);
    }
  }

  Future<void> _startDownload(
    MediaDetail detail,
    String category,
    String quality,
    List<Episode> episodes, {
    VideoSource? server,
    String? resolveSourceId,
  }) async {
    episodes = await _confirmExistingDownloads(detail, category, episodes);
    if (!mounted || episodes.isEmpty) return;
    await _dropBrokenCopies(detail, category, episodes);
    if (!mounted) return;
    final item = widget.item;
    if (resolveSourceId != null) {
      // Each queued episode re-resolves from the source the probe settled on.
      sl<DownloadManager>().hintResolveSource(
        sourceId: item.sourceId,
        showId: item.id,
        episodeIds: episodes.map((e) => e.id),
        category: category,
        resolveSourceId: resolveSourceId,
      );
    }
    // Windows: keep the details for the downloaded show page.
    _cacheDetailsOnDownload(detail);
    unawaited(
      sl<DownloadManager>().enqueueEpisodes(
        sourceId: item.sourceId,
        showId: item.id,
        showTitle: detail.title,
        cover: detail.cover ?? item.cover,
        coverHeaders: detail.coverHeaders ?? item.coverHeaders,
        showUrl: item.url,
        category: category,
        quality: quality,
        episodes: episodes,
        serverPreference: server == null
            ? null
            : DownloadServerPreference.fromSource(server),
        nowMs: DateTime.now().millisecondsSinceEpoch,
        malId: detail.malId ?? item.malId,
        anilistId: item.anilistId,
        tmdbId: detail.tmdbId ?? item.tmdbId,
        tmdbIsTv: detail.tmdbIsTv || item.tmdbIsTv,
        imdbId: detail.imdbId ?? item.imdbId,
      ),
    );
    _snack(
      episodes.length == 1
          ? context.l10n.addedToDownloads
          : context.l10n.downloadingNEpisodes(episodes.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (sl<AppMode>().isTv) {
      return DetailScreenTv(
        item: widget.item,
        onPrefetchEpisode: Platform.isAndroid
            ? (episodeUrl) => _maybePrefetch(episodeUrl, widget.item.sourceId)
            : null,
      );
    }
    // Windows: the desktop page, wrapped in the page-keys scope (show-8).
    if (_windowsDesktopUi) {
      if (!_hasEntered) {
        return _DetailOpeningPreview(
          item: widget.item,
          heroHeight: _expandedHeight,
        );
      }
      // A scope, not a plain Focus: when a child gives focus back with
      // unfocus(disposition: scope) (the episode list does when a selection
      // ends), primary focus lands on this node, so Enter/Space still reach
      // _onPageKey instead of stopping at the route's scope above it.
      return FocusScope(
        node: _pageKeysFocus,
        autofocus: true,
        onKeyEvent: _onPageKey,
        child: _buildDesktopPage(context),
      );
    }
    _heroHeight = _heroFor(context);
    if (!_hasEntered) {
      if (context.read<DetailCubit>().state.status == DetailStatus.loading) {
        return const _DetailLoading();
      }
      return _DetailOpeningPreview(item: widget.item, heroHeight: _heroHeight);
    }
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Stack(
        children: [
          // Adaptive colour: poster-tinted wash behind the scroll view, only
          // while the setting is on. The NestedScrollView's own background is
          // transparent, so the tint shows through the body; the pinned bars
          // paint that same tint themselves so content never shows through.
          if (ThemeController.adaptiveColour)
            PosterTintLayer(
              notifier: _tint,
              duration: detailAdaptiveColourDuration,
            ),
          Material(
            type: MaterialType.transparency,
            child: BlocBuilder<DetailCubit, DetailState>(
              builder: (context, state) {
                // Loading and loaded are two different screens; crossfade
                // between them so the page never blinks from one to the other.
                // Everything after loading shares one key, so ordinary updates
                // (cast arriving, a source switch) do not replay the fade.
                Widget phase() {
                  if (state.status == DetailStatus.loading) {
                    // Nothing is shown until there is something real to show:
                    // the whole screen is the page colour and one centred loader.
                    return const _DetailLoading();
                  }
                  if (state.cloudflareUrl != null) {
                    return _DetailCloudflareBlocked(
                      url: state.cloudflareUrl!,
                      isMangayomi:
                          widget.item.sourceId.startsWith('mg:') ||
                          (state.detail?.sourceId.startsWith('mg:') ?? false),
                    );
                  }
                  if (state.status == DetailStatus.error ||
                      state.detail == null) {
                    // The row you tapped already carried a title and a cover, so a
                    // failed fetch does not have to blank the page — keep what we
                    // have and say what is missing over it. A rate limit especially:
                    // it passes on its own, and the wait is the useful part.
                    final fallback = _detailFromItem(widget.item);
                    if (fallback != null) {
                      return Stack(
                        children: [
                          _buildBody(
                            context,
                            state,
                            fallback,
                            sourceMetadataReady: false,
                          ),
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: _LoadFailureBanner(
                              service: _sourceLabel(
                                widget.item.sourceId,
                                url: widget.item.url,
                                savedFrom: widget.item.savedFrom,
                              ),
                              // Same distinction Home draws: a metadata catalogue and
                              // an installed source fail alike but read differently.
                              isMetadataProvider:
                                  widget.item.sourceId == ZmodeIds.sourceId,
                              error: state.error,
                            ),
                          ),
                        ],
                      );
                    }
                    // Offline is not the title failing: saying "failed to load this
                    // title" over a dropped connection sends people hunting a
                    // problem that isn't there.
                    final offline = state.error == 'offline';
                    return EmptyState(
                      icon: offline
                          ? Icons.wifi_off_rounded
                          : Icons.error_outline,
                      message: offline
                          ? '${context.l10n.offlineTitle}\n${context.l10n.offlineBody}'
                          : _limitSeconds(state.error) != null
                          ? context.l10n.providerNeedsBreatherBody(
                              _limitSeconds(state.error)!,
                            )
                          : context.l10n.failedToLoadThisTitle,
                    );
                  }
                  return _buildBody(context, state, state.detail!);
                }

                return AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  switchInCurve: Curves.easeOut,
                  switchOutCurve: Curves.easeIn,
                  layoutBuilder: (current, previous) => Stack(
                    fit: StackFit.expand,
                    children: [...previous, ?current],
                  ),
                  child: KeyedSubtree(
                    key: ValueKey(state.status == DetailStatus.loading),
                    child: phase(),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// Seconds left on a rate limit, or null when [error] is anything else.
  static int? _limitSeconds(String? error) =>
      error != null && error.startsWith('rate_limited:')
      ? int.tryParse(error.substring('rate_limited:'.length))
      : null;

  /// A page built from the row that was tapped, so a failed fetch keeps the
  /// cover and title instead of blanking. Null when the item itself is too
  /// thin to render anything worth keeping.
  MediaDetail? _detailFromItem(MediaItem item) {
    if (item.title.isEmpty) return null;
    return MediaDetail(
      id: item.id,
      title: item.title,
      englishTitle: item.englishTitle,
      cover: item.cover,
      coverHeaders: item.coverHeaders,
      banner: item.banner,
      url: item.url,
      type: item.type,
      sourceId: item.sourceId,
      malId: item.malId,
      tmdbId: item.tmdbId,
      tmdbIsTv: item.tmdbIsTv,
    );
  }

  Widget _buildBody(
    BuildContext context,
    DetailState state,
    MediaDetail detail, {
    bool sourceMetadataReady = true,
  }) {
    final item = widget.item;
    final logoUrl = _logoUrl;
    final cubit = context.read<DetailCubit>();
    final category = state.category;
    final selectedSeason = state.selectedSeason;
    final eps = detail.episodes;
    final store = sl<ResumeStore>();
    // Manga/novel: no player, no sub/dub, no video downloads — drives the
    // Play→Read relabel and hides the download affordances below.
    final isReading =
        detail.type == ProviderType.novel || detail.type == ProviderType.manga;
    // Kick the (cached, once-per-malId) filler lookup for the "Filler" badge.
    _ensureFiller(detail.malId ?? item.malId);
    // Kick the (once-per-detail) tracker-progress lookup for grey-out.
    _maybeFetchTrackerProgress(detail);

    // Resume / play button logic. Local playback first; else fall back to the
    // tracker's watched count (see _resumeTarget). Local case is unchanged.
    // Reading titles use their OWN progress store instead — _resumeTarget's
    // ResumeStore never carries a mark for a chapter, so it would always
    // (harmlessly but wrongly) say "start over".
    final resume = _resumeTarget(eps);
    final readingSourceId = _readingSourceId(detail);
    if (isReading) unawaited(_loadCloudReadHistory(readingSourceId));
    final readResume = isReading
        ? _readResumeIndex(eps, sourceId: readingSourceId)
        : null;
    final resumeIdx = isReading ? readResume!.index : resume.index;
    // Warm the episode Play/Continue will start, but only after the viewer has
    // remained on the detail page. Reading providers do not resolve video.
    if (!isReading && eps.isNotEmpty) {
      _maybePrefetch(eps[resumeIdx].url, item.sourceId);
    }
    final hasAnyMark = eps.any(
      (e) => store.get(item.sourceId, item.url, e.id) != null,
    );
    final episodeNum = eps.isNotEmpty
        ? (eps[resumeIdx].number?.toInt() ?? resumeIdx + 1)
        : 1;
    final buttonLabel = isReading
        ? (readResume!.hasResume
              ? context.l10n.continueLabel
              : context.l10n.read)
        : (resume.hasResume
              ? (detail.isFilm
                    ? context.l10n.continueLabel
                    : context.l10n.continueEpisode(episodeNum))
              : context.l10n.play);

    // AniList anime: the TMDB backdrop we've resolved, if any, over AniList's
    // own (often missing/low-res) banner. Every other provider is unchanged.
    final banner = detail.type == ProviderType.anime
        ? (_tmdbBanners[widget.item.id] ?? detail.banner ?? item.banner)
        : (detail.banner ?? item.banner);

    // The plain backdrop first, as on Home: the title is drawn over it, so a
    // picture with the title printed in would show it twice. A poster only when
    // there is no backdrop.
    final heroBackdrop = banner ?? item.landscapePoster;
    final heroIsBackdrop = heroBackdrop?.trim().isNotEmpty == true;
    final coverUrl =
        homeHeroArt(detail.cover ?? item.cover, heroBackdrop) ?? '';
    final coverHeaders = detail.coverHeaders ?? item.coverHeaders;
    final hasCover = coverUrl.isNotEmpty;

    final tintPoster = (detail.cover ?? item.cover)?.trim();
    final tintBackdrop = banner?.trim();
    final tintArt = adaptiveArtUrl(tintPoster, tintBackdrop);
    if (ThemeController.adaptiveColour &&
        tintArt != null &&
        _tintUrl != tintArt) {
      _tintUrl = tintArt;
      final sampleArt = adaptiveSampleUrl(
        tintArt,
        backdrop:
            (tintPoster == null || tintPoster.isEmpty) &&
            tintBackdrop != null &&
            tintBackdrop.isNotEmpty,
      );
      unawaited(
        extractAdaptiveColor(sampleArt, coverHeaders).then((c) {
          if (!mounted || _tintUrl != tintArt) return;
          _tint.value = c == null
              ? null
              : tintFromDominant(c, blend: adaptiveColourBlend);
        }),
      );
    }

    // The hero handles the lookup result without rebuilding the page.
    _resolveTrailer(detail);

    // Season data. PRESERVED.
    final seasonSet = seasonsOf(eps);
    final hasMultipleSeasons = seasonSet.length > 1;
    final currentSeason = hasMultipleSeasons
        ? (seasonSet.contains(selectedSeason)
              ? selectedSeason
              : seasonSet.first)
        : 1;
    final seasonEps = hasMultipleSeasons
        ? episodesInSeason(eps, currentSeason)
        : eps;

    // Episodes grouped by season for the download sheet's season chips.
    final episodesBySeason = <int, List<Episode>>{};
    if (hasMultipleSeasons) {
      for (final e in eps) {
        (episodesBySeason[seasonOf(e) ?? 1] ??= <Episode>[]).add(e);
      }
    } else {
      episodesBySeason[1] = eps;
    }

    // ── Status label (used by the Details tab) ────────────────
    final statusStr = statusLabel(detail.status);

    // ── Download button label: "Download S{season}:E{n}" when we can derive
    // the first episode of the current season, else a plain "Download". ──────
    final downloadLabel = detail.isFilm
        ? context.l10n.download
        : _downloadLabel(
            context.l10n,
            seasonEps,
            hasMultipleSeasons,
            currentSeason,
          );

    // Friendly provider name + its origin repo, so the user can tell which repo
    // a source came from. JS providers live in the registry; CloudStream sources
    // live in the CS manager — without the CS lookup this fell back to the raw
    // sourceId ("cs:Provider@31@tag"), leaking the file-id suffix.
    final sourceName = _sourceLabel(
      item.sourceId,
      url: item.url,
      prefer: widget.prefer ?? _preferFromName(item.savedFrom),
      savedFrom: item.savedFrom,
    );

    // The title (or logo) and up to three genres. Drawn ON the banner, over
    // its fade, so the picture runs under the title.
    final wide = isWideTabletLayout(context);
    final Widget titleBlock = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: wide
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      children: [
        // Tapping the title opens the search popup (Cue pop-in):
        // pre-filled query, "Search" or "Search all sources".
        GestureDetector(
          onTap: () => _onTitleTap(detail.title),
          // Official title logo when the toggle resolved one —
          // grows in smoothly instead of shoving Play down.
          child: AnimatedSize(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
            alignment: wide ? Alignment.topLeft : Alignment.topCenter,
            child: _logoUrl != null
                // Compact natural-size box (never full-width), centred.
                ? ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxHeight: 72,
                      maxWidth: 260,
                    ),
                    child: CachedNetworkImage(
                      imageUrl: logoUrl!,
                      fit: BoxFit.contain,
                      alignment: wide ? Alignment.centerLeft : Alignment.center,
                      fadeInDuration: const Duration(milliseconds: 250),
                      errorWidget: (_, _, _) => _headerTitleText(detail.title),
                      errorListener: widget.item.sourceId == stremioSourceId
                          ? (_) => _loadLogo(failedUrl: logoUrl)
                          : null,
                    ),
                  )
                : _headerTitleText(detail.title),
          ),
        ),
        // Up to three genres under the title, as one quiet line.
        AnimatedSize(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          alignment: wide ? Alignment.topLeft : Alignment.topCenter,
          child: detail.genres.isEmpty
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    detail.genres.take(3).join(' \u2022 '),
                    textAlign: wide ? TextAlign.left : TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.body.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
        ),
        // Quality / 18+ tags, when there are any. No year line.
        if ((item.quality ?? '').trim().isNotEmpty || detail.isAdult)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if ((item.quality ?? '').trim().isNotEmpty)
                  _MetaBadge(item.quality!.trim().toUpperCase()),
                if ((item.quality ?? '').trim().isNotEmpty && detail.isAdult)
                  const SizedBox(width: 8),
                if (detail.isAdult) const _MetaBadge('18+'),
              ],
            ),
          ),
      ],
    );

    // Built once here; _tabletBody decides how it is wrapped (phone: as is).
    final detailPages = _FadePages(
      controller: _tabController,
      children: [
        // ── Overview: cast, seasons/relations and details as rows ───────────
        _OverviewTab(
          // Cast and relations arrive on their own request, after the page is
          // already up — and before the source resolve has even started.
          loading: state.extrasLoading || state.episodesLoading,
          cast: state.cast.isNotEmpty
              ? state.cast
              : [for (final n in detail.cast) CastMember(name: n)],
          onOpenPerson: (ref) => Navigator.of(
            context,
          ).push(PersonPage.route(ref, sourceId: widget.item.sourceId)),
          relations: state.relations,
          seasons: state.seasons,
          onOpenRelation: _openRelation,
          synopsis: cleanSynopsis(detail.description) ?? '',
          genres: detail.genres,
          year: detail.year,
          runtimeMins: detail.durationMins,
          badges: state.badges,
          onRetryExtras: cubit.retryExtras,
          score: detail.score,
          // Tappable only on a metadata title, same rule the old Details tab used.
          onGenre: detail.sourceId == ZmodeIds.sourceId
              ? (g) => _browseBy(context, MetaFilters(genres: [g]))
              : null,
          castLabel: isReading ? context.l10n.characters : context.l10n.cast,
          details: _DetailsTab(
            sourceName: sourceName,
            statusStr: statusStr,
            reading: isReading,
            genres: detail.genres,
            studios: detail.studios,
            episodeCount: eps.length,
            isMovie: detail.isFilm,
            year: detail.year,
            description: cleanSynopsis(detail.description),
            detail: detail,
            embedded: true,
          ),
        ),
        // ── Episodes ──────────────────────────────────────────────────────
        _EpisodesTab(
          loading: state.episodesLoading,
          category: state.category,
          versionPicker: showSubDubFor(detail)
              ? SegmentedButton<String>(
                  showSelectedIcon: false,
                  style: SegmentedButton.styleFrom(
                    backgroundColor: AppColors.surface2,
                    foregroundColor: AppColors.textSecondary,
                    selectedBackgroundColor: AppColors.accentSoft,
                    selectedForegroundColor: AppColors.textPrimary,
                    side: const BorderSide(color: AppColors.hairline),
                    textStyle: AppText.caption.copyWith(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 7),
                    minimumSize: const Size(36, 28),
                  ),
                  segments: [
                    ButtonSegment(value: 'sub', label: Text(context.l10n.sub)),
                    ButtonSegment(value: 'dub', label: Text(context.l10n.dub)),
                  ],
                  selected: {category},
                  onSelectionChanged: (selection) =>
                      _changeEpisodeVersion(context, selection.single),
                )
              : null,
          eps: eps,
          seasonEps: seasonEps,
          fillerEps: _fillerEps,
          hasMultipleSeasons: hasMultipleSeasons,
          seasonSet: seasonSet,
          currentSeason: currentSeason,
          onSelectSeason: cubit.selectSeason,
          coverUrl: coverUrl,
          coverHeaders: coverHeaders,
          sourceId: item.sourceId,
          // Downloads name the source that has the files; progress above
          // stays on the canonical id.
          downloadSourceId: detail.sourceId.isNotEmpty
              ? detail.sourceId
              : item.sourceId,
          showId: item.id,
          showUrl: item.url,
          resumeIndex: _resumeIndex,
          hasAnyMark: hasAnyMark,
          trackerProgress: _trackerProgress,
          nextAiringEpisode: _nextAiringEpisode,
          nextAiringAt: _nextAiringAt,
          onOpen: (fullIndex) => _openPlayer(eps, fullIndex, detail, category),
          // Reading has no player to pick, but it does have the marking
          // rows — gating the whole menu on the player is what hid them.
          onEpisodeMenu: (fullIndex) =>
              _pickPlayerFor(eps, fullIndex, detail, category),
          onRefresh: cubit.refresh,
          onDownload: (ep) => isReading
              ? _downloadChapter(ep, detail)
              : _downloadSingle(ep, detail, category),
          onDownloadMany: isReading
              ? (eps) => _downloadChapters(eps, detail)
              : null,
          resumeChapter: readResume == null || eps.isEmpty
              ? null
              : eps[readResume.index],
          // Only a catalogue title has another source to fall back on.
          onSwitchSource: ZmodeIds.isZ(item.url) ? _switchSource : null,
          isReading: isReading,
          filmMeta: _filmMeta(detail),
          filmTitle: detail.title,
          hasScheduledVideos: detail.hasScheduledVideos,
        ),
        // ── Comments: not built yet ─────────────────────────────────────────
        _emptyTab(Icons.forum_outlined, context.l10n.watchComingSoon),
      ],
    );

    return NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      // The banner does the stretching, so the stock overscroll glow stays off.
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(overscroll: false),
        child: ValueListenableBuilder<double>(
          valueListenable: _pull,
          builder: (context, pull, _) => NestedScrollView(
            controller: _scrollController,
            headerSliverBuilder: (context, _) => _tabletSlivers(context, [
              // ── 1. Hero: backdrop + overlapping poster + status/total ──────────
              SliverAppBar(
                // Pulled down: the banner gets taller and everything under it is
                // pushed down with it, so the whole page stretches.
                expandedHeight: _heroHeight + pull,
                pinned: true,
                // iOS-style chip with its own background (no top fade needed).
                // Padded to sit 14px off the edge, mirroring the top-right
                // trailer controls.
                leadingWidth: 62,
                leading: const Padding(
                  padding: EdgeInsets.only(left: 14),
                  child: _DetailBackButton(),
                ),
                // Opaque while adaptive colour is on, painted in the same wash as the
                // body, so the pinned bar hides scrolled content instead of letting
                // it show through (a transparent bar read as an unfinished page).
                // Flat theme bg otherwise, exactly as before.
                backgroundColor: ThemeController.adaptiveColour
                    ? (_tint.value ?? AppColors.bg)
                    : AppColors.bg,
                surfaceTintColor: Colors.transparent,
                shadowColor: Colors.transparent,
                centerTitle: true,
                titleSpacing: 0,
                // As wide as the back button, so the title sits in the middle of
                // the whole screen and not just of the space after the button.
                actions: const [SizedBox(width: 62)],
                // PRESERVED EFFECT: title fades in once the hero scrolls past.
                title: AnimatedOpacity(
                  opacity: _showAppBarTitle ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  // Mini title logo in the collapsed bar; plain text until (and
                  // unless) one resolves.
                  child: _logoUrl != null
                      ? Align(
                          alignment: Alignment.center,
                          child: CachedNetworkImage(
                            imageUrl: logoUrl!,
                            height: 24,
                            fit: BoxFit.contain,
                            alignment: Alignment.center,
                            fadeInDuration: const Duration(milliseconds: 250),
                            errorWidget: (_, _, _) =>
                                _barTitleText(detail.title),
                            errorListener:
                                widget.item.sourceId == stremioSourceId
                                ? (_) => _loadLogo(failedUrl: logoUrl)
                                : null,
                          ),
                        )
                      : _barTitleText(detail.title),
                ),
                flexibleSpace: LayoutBuilder(
                  builder: (context, box) {
                    // 1 while the banner is fully open, 0 once it is the thin bar.
                    final topPad = MediaQuery.paddingOf(context).top;
                    final min = kToolbarHeight + topPad;
                    final max = _heroHeight + topPad;
                    final open = ((box.maxHeight - min) / (max - min)).clamp(
                      0.0,
                      1.0,
                    );
                    return Stack(
                      fit: StackFit.expand,
                      clipBehavior: Clip.none,
                      children: [
                        FlexibleSpaceBar(
                          collapseMode: CollapseMode.parallax,
                          background: RepaintBoundary(
                            child: _Hero(
                              coverUrl: coverUrl,
                              // A backdrop is wide and needs more pixels than a tall
                              // poster to fill the hero. Capped at 2000 so a poster
                              // fallback stays small.
                              imageDecodeWidth: heroIsBackdrop
                                  ? math.min(heroDecodeMaxWidth, 2000)
                                  : mobileHeroDecodeWidth(item.sourceId, 800),
                              coverHeaders: coverHeaders,
                              hasCover: hasCover,
                              tint: ThemeController.adaptiveColour
                                  ? _tint
                                  : null,
                              trailer: _trailerFuture,
                              // Pause the trailer once the hero has scrolled past (reuses
                              // the same signal that fades in the app-bar title).
                              collapsed: _showAppBarTitle,
                              onTapFullscreen: _openTrailer,
                              pull: _pull,
                            ),
                          ),
                        ),
                        // Over the CURRENT visible banner, so its bottom edge is
                        // always faded into the page, even while it collapses.
                        Positioned.fill(
                          child: _HeroFade(
                            tint: ThemeController.adaptiveColour ? _tint : null,
                          ),
                        ),
                        // Title and genres on the banner. They fade away as the
                        // banner closes up into the top bar.
                        Positioned.fill(
                          child: Opacity(
                            opacity: ((open - 0.35) / 0.45).clamp(0.0, 1.0),
                            child: Padding(
                              padding: EdgeInsets.fromLTRB(
                                wide ? wideSideInset(context) : 16,
                                0,
                                16,
                                wide ? 20 : 10,
                              ),
                              child: OverflowBox(
                                alignment: wide
                                    ? Alignment.bottomLeft
                                    : Alignment.bottomCenter,
                                minHeight: 0,
                                maxHeight: 400,
                                child: titleBlock,
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),

              // ── 3. White Play + gray Download buttons (full-width, stacked) ─────
              // (The hero banner autoplays the trailer; tap it for fullscreen.)
              //
              // Each button carries its own 16px side padding (rather than one
              // Padding wrapping the whole Column) so the Z Mode selector below
              // can sit as a plain last child: it already supplies its own 16px
              // side padding (it's normally a top-level sliver child), and a
              // shared wrapper would double that indent.
              SliverToBoxAdapter(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                      child: Row(
                        children: [
                          Expanded(
                            child: _PlayButton(
                              pill: true,
                              loading: state.episodesLoading,
                              label: buttonLabel,
                              icon: isReading
                                  ? Icons.menu_book_rounded
                                  : Icons.play_arrow_rounded,
                              onPressed: eps.isNotEmpty
                                  ? () => _openPlayer(
                                      eps,
                                      resumeIdx,
                                      detail,
                                      category,
                                    )
                                  : null,
                            ),
                          ),
                          // Reading downloads are out of scope for this plan.
                          if (!isReading) ...[
                            const SizedBox(width: 10),
                            _DownloadButton(
                              iconOnly: true,
                              // Gated exactly like Play: with no episodes there is
                              // nothing to download, and leaving it live on a title
                              // no source matched just moves the dead end one tap
                              // later.
                              loading: state.episodesLoading,
                              label: downloadLabel,
                              onPressed: eps.isEmpty
                                  ? null
                                  : () => _openDownloadSheet(
                                      detail: detail,
                                      category: category,
                                      episodesBySeason: episodesBySeason,
                                      initialSeason: currentSeason,
                                    ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    // Z Mode: matched source + "Wrong title?", kept with the
                    // actions it controls instead of under the synopsis.
                    // The first frame may be built from the tapped catalogue card,
                    // which has no synonyms/native title. Don't start a canonical
                    // source search until full metadata arrives: resolve() shares
                    // in-flight work by title id, so an early search would make the
                    // later alias-aware lookup reuse the incomplete one.
                    // Same late-arrival growth as the meta line above.
                    AnimatedSize(
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOut,
                      alignment: Alignment.topCenter,
                      child:
                          sourceMetadataReady && ZmodeIds.isZ(widget.item.url)
                          ? MatchLine(
                              canonical: ZmodeIds.parseShow(widget.item.url)!,
                              title: detail.title,
                              altTitle: detail.englishTitle,
                              malId: detail.malId,
                              metadataAliases: [
                                if (detail.englishTitle != null)
                                  detail.englishTitle!,
                                if (detail.nativeTitle != null)
                                  detail.nativeTitle!,
                                ...detail.synonyms,
                              ],
                            )
                          : const SizedBox.shrink(),
                    ),
                  ],
                ),
              ),

              // ── 6. Icon-over-label action row (My List / Trailer / Share / Web) ─
              // "Trailer" is a CloudStream-style result action (recloudstream's
              // result fragment exposes a Trailer button); it opens the fullscreen
              // TrailerScreen and only appears once a trailer id has resolved.
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 20, 8, 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _IconAction(
                        icon: _inMyList
                            ? Icons.check_rounded
                            : Icons.add_rounded,
                        active: _inMyList,
                        // Reading-aware: a manga on your list is "Reading", not
                        // "Watching". Display only — the stored status is still
                        // WatchStatus.watching, so My List and the trackers are
                        // untouched, and reading:false returns the plain label
                        // unchanged for anime.
                        label: _status == null
                            ? context.l10n.myList
                            : shortLabelFor(_status!, reading: isReading),
                        tooltip: _inMyList
                            ? context.l10n.changeStatus
                            : context.l10n.addToMyList,
                        onTap: () => _openListSheet(detail),
                      ),
                      if (Platform.isAndroid &&
                          (_subscribed ||
                              (!state.episodesLoading && eps.isNotEmpty)))
                        _IconAction(
                          icon: _subscribed
                              ? Icons.notifications_active_rounded
                              : Icons.notifications_none_rounded,
                          active: _subscribed,
                          label: context.l10n.notify,
                          tooltip: _subscribed
                              ? context.l10n.stopAlerts
                              : (isReading
                                    ? context.l10n.notifyOnNewChapters
                                    : context.l10n.notifyOnNewEpisodes),
                          onTap: () => _toggleSubscribe(detail),
                        ),
                      if (_trackingAvailable(detail))
                        _IconAction(
                          icon: _tracked
                              ? Icons.published_with_changes_rounded
                              : Icons.sync_rounded,
                          active: _tracked,
                          label: context.l10n.tracking,
                          tooltip: _tracked
                              ? context.l10n.trackedEditStatusScoreProgress
                              : context.l10n.syncStatusScoreProgress,
                          onTap: () => _openTrackingSheet(detail),
                        ),
                      _IconAction(
                        icon: Icons.ios_share_rounded,
                        label: context.l10n.share,
                        tooltip: context.l10n.share,
                        onTap: () => _share(detail, sourceName),
                      ),
                      _IconAction(
                        icon: Icons.public_rounded,
                        label: context.l10n.web,
                        tooltip: context.l10n.openSourceSite,
                        onTap: _openSourceSite,
                      ),
                      // Novel only — a manga chapter is images, not text, and
                      // there's nothing to put in an EPUB.
                      if (detail.type == ProviderType.novel)
                        _IconAction(
                          icon: Icons.output,
                          label: context.l10n.epub,
                          tooltip: context.l10n.exportAsEpub,
                          onTap: () => showEpubExportSheet(
                            context,
                            sourceId: detail.sourceId.isNotEmpty
                                ? detail.sourceId
                                : item.sourceId,
                            showTitle: detail.title,
                            chapters: eps,
                          ),
                        ),
                    ],
                  ),
                ),
              ),

              // ── 7. Pinned tab bar ───────────────────────────────────────────────
              SliverPersistentHeader(
                pinned: true,
                delegate: _TabBarDelegate(
                  _ChipTabs(
                    controller: _tabController,
                    labels: [
                      context.l10n.overview,
                      isReading
                          ? context.l10n.chapters
                          : (detail.isFilm
                                ? context.l10n.movie
                                : context.l10n.episodes),
                    ],
                    trailingLabel: context.l10n.watchComments,
                    trailingIcon: Icons.forum_outlined,
                  ),
                  tint: ThemeController.adaptiveColour ? _tint : null,
                ),
              ),
            ]),
            body: _tabletBody(context, detailPages),
          ),
        ),
      ),
    );
  }

  /// Windows: the desktop page itself (everything [build] returns once the
  /// opening preview is done), wrapped by [build] in the page-keys scope.
  Widget _buildDesktopPage(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Stack(
        children: [
          // Adaptive colour: poster-tinted wash behind the scroll view, only
          // while the setting is on. The NestedScrollView's own background is
          // transparent, so the tint shows through the body; the pinned bars
          // paint that same tint themselves so content never shows through.
          if (ThemeController.adaptiveColour)
            PosterTintLayer(
              notifier: _tint,
              duration: detailAdaptiveColourDuration,
            ),
          Material(
            type: MaterialType.transparency,
            child: BlocBuilder<DetailCubit, DetailState>(
              builder: (context, state) {
                if (state.status == DetailStatus.loading) {
                  // A new fetch: a failure after it re-arms the retry countdown.
                  _retryArmedFor = null;
                  // The row that was tapped already carried a title, a cover and a
                  // year, and a full-screen skeleton throws all of that away to
                  // animate a blank page. Frames prove the app is NOT stuck here -
                  // 18ms median, 90th 23ms, while tapping through screens - it is
                  // responsive and simply showing nothing new, because the episodes
                  // are a source resolve that has not come back yet. The perceived
                  // hang is the empty screen, not the wait.
                  //
                  // So paint what we already know, immediately, and let the episode
                  // tab carry its own loading skeleton for the part genuinely still
                  // in flight. A viewer who backs out before the resolve returns sees
                  // the title they tapped either way, and nobody stares at a
                  // placeholder for a source sweep.
                  final partial = _detailFromItem(widget.item);
                  if (partial != null) {
                    return _buildDesktopBody(
                      context,
                      state.copyWith(
                        status: DetailStatus.success,
                        detail: partial,
                        // Nothing is known yet, so the episode tab shows its skeleton
                        // rather than an empty list reading as "this source has no
                        // episodes".
                        episodesLoading: true,
                      ),
                      partial,
                      sourceMetadataReady: false,
                    );
                  }
                  // Not const: the hero height is platform-dependent (shorter on Windows).
                  return _DetailSkeleton(heroHeight: _expandedHeight);
                }
                if (state.cloudflareUrl != null) {
                  return _DetailCloudflareBlocked(
                    url: state.cloudflareUrl!,
                    isMangayomi:
                        widget.item.sourceId.startsWith('mg:') ||
                        (state.detail?.sourceId.startsWith('mg:') ?? false),
                    canonical: ZmodeIds.parseShow(widget.item.url),
                    title: state.detail?.title ?? widget.item.title,
                    altTitle:
                        state.detail?.englishTitle ?? widget.item.englishTitle,
                    malId: state.detail?.malId ?? widget.item.malId,
                  );
                }
                if (state.status == DetailStatus.error ||
                    state.detail == null) {
                  // The row you tapped already carried a title and a cover, so a
                  // failed fetch does not have to blank the page — keep what we
                  // have and say what is missing over it. A rate limit especially:
                  // it passes on its own, and the wait is the useful part.
                  final fallback = _detailFromItem(widget.item);
                  // Windows (show-14): start the rate-limit countdown that the
                  // banner's Retry and F5 share.
                  if (_windowsDesktopUi) _armRetry(state.error);
                  if (fallback != null) {
                    return Stack(
                      children: [
                        _buildDesktopBody(
                          context,
                          state,
                          fallback,
                          sourceMetadataReady: false,
                        ),
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: _LoadFailureBanner(
                            service: _sourceLabel(
                              widget.item.sourceId,
                              url: widget.item.url,
                              savedFrom: widget.item.savedFrom,
                            ),
                            // Same distinction Home draws: a metadata catalogue and
                            // an installed source fail alike but read differently.
                            isMetadataProvider:
                                widget.item.sourceId == ZmodeIds.sourceId,
                            error: state.error,
                            // Windows: stays until dismissed, with Retry.
                            persistent: _windowsDesktopUi,
                            onRetry: _windowsDesktopUi ? _retryLoad : null,
                            retryNotBefore: _retryNotBefore,
                          ),
                        ),
                      ],
                    );
                  }
                  // Offline is not the title failing: saying "failed to load this
                  // title" over a dropped connection sends people hunting a
                  // problem that isn't there.
                  final offline = state.error == 'offline';
                  return EmptyState(
                    icon: offline
                        ? Icons.wifi_off_rounded
                        : Icons.error_outline,
                    message: offline
                        ? '${context.l10n.offlineTitle}\n${context.l10n.offlineBody}'
                        : _limitSeconds(state.error) != null
                        ? context.l10n.providerNeedsBreatherBody(
                            _limitSeconds(state.error)!,
                          )
                        // Windows (src-11): a time-out says so; Retry below.
                        : _windowsDesktopUi
                        ? sourceFailureMessage(
                            state.error,
                            context.l10n.failedToLoadThisTitle,
                          )
                        : context.l10n.failedToLoadThisTitle,
                    // Windows (show-14): no cached page to keep, so the Retry
                    // lives here instead of on the banner. While rate-limited
                    // it only says how long is left (same rule as F5).
                    actionLabel: _windowsDesktopUi ? context.l10n.retry : null,
                    onAction: _windowsDesktopUi ? _retryLoad : null,
                  );
                }
                return _buildDesktopBody(context, state, state.detail!);
              },
            ),
          ),
        ],
      ),
    );
  }

  /// Windows: the desktop detail layout (compact hero card, info pane,
  /// Episodes / Cast / Relations / Details tabs).
  Widget _buildDesktopBody(
    BuildContext context,
    DetailState state,
    MediaDetail detail, {
    bool sourceMetadataReady = true,
  }) {
    final item = widget.item;
    final logoUrl = _logoUrl;
    final cubit = context.read<DetailCubit>();
    final category = state.category;
    final selectedSeason = state.selectedSeason;
    // Downloaded mode lists the saved files, not the source's episodes, each
    // dressed with the show's saved episode metadata (description, date,
    // rating, runtime, local thumbnail) so rows look like the online page.
    final eps = _fromDownloads
        ? mergeSavedEpisodeMeta(
            episodesFromDownloads(_savedEpisodes),
            detail.episodes,
          )
        : detail.episodes;
    final store = sl<ResumeStore>();
    // Online page of a show with downloads: keep its details for the
    // downloaded show page (only once the full metadata is in; re-saved,
    // debounced, when later enrichment adds more).
    if (sourceMetadataReady) _cacheDetailsForDownloads(detail, state);
    // Manga/novel: no player, no sub/dub, no video downloads — drives the
    // Play→Read relabel and hides the download affordances below.
    final isReading =
        detail.type == ProviderType.novel || detail.type == ProviderType.manga;
    // Kick the (cached, once-per-malId) filler lookup for the "Filler" badge.
    _ensureFiller(detail.malId ?? item.malId);
    // Kick the (once-per-detail) tracker-progress lookup for grey-out.
    _maybeFetchTrackerProgress(detail);

    // Resume / play button logic. Local playback first; else fall back to the
    // tracker's watched count (see _resumeTarget). Local case is unchanged.
    // Reading titles use their OWN progress store instead — _resumeTarget's
    // ResumeStore never carries a mark for a chapter, so it would always
    // (harmlessly but wrongly) say "start over".
    final resume = _resumeTarget(eps);
    final readingSourceId = _readingSourceId(detail);
    if (isReading) unawaited(_loadCloudReadHistory(readingSourceId));
    final readResume = isReading
        ? _readResumeIndex(eps, sourceId: readingSourceId)
        : null;
    final resumeIdx = isReading ? readResume!.index : resume.index;
    // Warm the episode Play/Continue will start, but only after the viewer has
    // remained on the detail page. Reading providers do not resolve video.
    // Downloaded mode plays from disk, so there is nothing to warm.
    if (!isReading && eps.isNotEmpty && !_fromDownloads) {
      _maybePrefetch(eps[resumeIdx].url, item.sourceId);
    }
    // Override-only "unwatched" rows don't count (see _isResumeMark).
    final hasAnyMark = eps.any(
      (e) => _isResumeMark(store.get(item.sourceId, item.url, e.id)),
    );
    final episodeNum = eps.isNotEmpty
        ? (eps[resumeIdx].number?.toInt() ?? resumeIdx + 1)
        : 1;
    // Windows: with no episode list (offline, or the source returned none),
    // this show's downloads stand in for both the Play button and the list.
    // Target platform (not the host OS) so phone widget tests run on a
    // Windows machine still take the phone path.
    final offlineSaved =
        defaultTargetPlatform == TargetPlatform.windows &&
            eps.isEmpty &&
            !isReading
        ? downloadsForShow(
            sl<DownloadManager>().all,
            showUrl: item.url,
            malId: detail.malId ?? item.malId,
            anilistId: item.anilistId,
            tmdbId: detail.tmdbId ?? item.tmdbId,
            title: detail.title.isNotEmpty ? detail.title : item.title,
          )
        : const <DownloadRecord>[];
    HistoryEntry? lastWatched;
    if (offlineSaved.isNotEmpty && sl.isRegistered<WatchHistory>()) {
      final urls = {item.url, for (final r in offlineSaved) r.showUrl};
      for (final e in sl<WatchHistory>().all()) {
        if (urls.contains(e.showUrl)) {
          lastWatched = e;
          break;
        }
      }
    }
    final offlineStart = downloadStartIndex(
      offlineSaved,
      lastEpisode: lastWatched?.episodeNumber,
      lastFinished: lastWatched?.finished ?? false,
    );
    final offlineLabel = offlineSaved.isEmpty
        ? null
        : (lastWatched != null
              ? context.l10n.continueEpisode(
                  offlineSaved[offlineStart].episodeNumber?.toInt() ??
                      offlineStart + 1)
              : context.l10n.play);
    final buttonLabel = offlineLabel ?? (isReading
        ? (readResume!.hasResume
              ? context.l10n.continueLabel
              : context.l10n.read)
        : (resume.hasResume
              ? (detail.isFilm
                    ? context.l10n.continueLabel
                    : context.l10n.continueEpisode(episodeNum))
              : context.l10n.play));

    // Tall phone hero: prefer TMDB's portrait art; other sources stay as-is.
    final coverUrl =
        mobileHeroArt(
          detail.cover ?? item.cover,
          detail.banner ?? item.banner ?? item.landscapePoster,
          sourceId: detail.sourceId,
        ) ??
        '';
    final coverHeaders = detail.coverHeaders ?? item.coverHeaders;
    final hasCover = coverUrl.isNotEmpty;

    final tintPoster = (detail.cover ?? item.cover)?.trim();
    final tintBackdrop = (detail.banner ?? item.banner)?.trim();
    final tintArt = adaptiveArtUrl(tintPoster, tintBackdrop);
    if (ThemeController.adaptiveColour &&
        tintArt != null &&
        _tintUrl != tintArt) {
      _tintUrl = tintArt;
      final sampleArt = adaptiveSampleUrl(
        tintArt,
        backdrop:
            (tintPoster == null || tintPoster.isEmpty) &&
            tintBackdrop != null &&
            tintBackdrop.isNotEmpty,
      );
      unawaited(
        extractAdaptiveColor(sampleArt, coverHeaders).then((c) {
          if (!mounted || _tintUrl != tintArt) return;
          _tint.value = c == null
              ? null
              : tintFromDominant(c, blend: adaptiveColourBlend);
        }),
      );
    }

    // The hero handles the lookup result without rebuilding the page.
    // Downloaded mode shows the cover/banner instead of a trailer.
    if (!_fromDownloads) _resolveTrailer(detail);

    // Season data. PRESERVED.
    final seasonSet = seasonsOf(eps);
    final hasMultipleSeasons = seasonSet.length > 1;
    final currentSeason = hasMultipleSeasons
        ? (seasonSet.contains(selectedSeason)
              ? selectedSeason
              : seasonSet.first)
        : 1;
    final seasonEps = hasMultipleSeasons
        ? episodesInSeason(eps, currentSeason)
        : eps;

    // Episodes grouped by season for the download sheet's season chips.
    final episodesBySeason = <int, List<Episode>>{};
    if (hasMultipleSeasons) {
      for (final e in eps) {
        (episodesBySeason[seasonOf(e) ?? 1] ??= <Episode>[]).add(e);
      }
    } else {
      episodesBySeason[1] = eps;
    }
    // B3: keep an open Windows batch dialog in step with this list.
    _publishBatchEpisodes(episodesBySeason);

    // ── Status label (used by the meta line and Details tab) ────────────────
    final statusStr = statusLabel(detail.status);

    // ── Netflix-style meta line: "2010 · 10 Seasons · Completed" ────────────
    // Join only what we actually HAVE with " · " (no faked rating/HD/CC).
    // Seasons when multi-season, else episode count.
    //
    // Three items, and that is the whole line. It is ONE line with an
    // ellipsis, so a fourth does not add anything — it pushes the end off the
    // edge and shows less than three did. Score, format and per-episode
    // duration each got a turn here and each cost more than it paid; they
    // live in the Details tab now, where there is room to read them.
    final metaParts = <String>[];
    if ((detail.year ?? '').isNotEmpty) metaParts.add(detail.year!);
    // A film has no episode count to fill the middle slot, so its run time
    // takes it — there it IS the thing worth knowing before pressing play.
    // Downloaded mode: the show's episode count from the saved metadata (same
    // as online), not just how many files are saved. Also used by the
    // run-time slot below and the Details tab's Episodes row.
    final shownCount = _fromDownloads && detail.episodes.length > eps.length
        ? detail.episodes.length
        : eps.length;
    if (!isReading &&
        (detail.isFilm || shownCount <= 1) &&
        (detail.durationMins ?? 0) > 0) {
      metaParts.add('${detail.durationMins}m');
    }
    if (!detail.isFilm && hasMultipleSeasons) {
      metaParts.add(context.l10n.seasonCount(seasonSet.length));
    } else if (!detail.isFilm && eps.isNotEmpty) {
      metaParts.add(
        isReading
            ? context.l10n.chapterCount(shownCount)
            : context.l10n.episodeCount(shownCount),
      );
    }
    if (statusStr.isNotEmpty) metaParts.add(statusStr);
    final metaLine = metaParts.join('  ·  ');

    // ── Download button label: "Download S{season}:E{n}" when we can derive
    // the first episode of the current season, else a plain "Download". ──────
    // Windows: a plain "Download" — it opens the batch dialog where the
    // episodes are picked, so naming one episode here would mislead.
    final downloadLabel = detail.isFilm || _windowsDesktopUi
        ? context.l10n.download
        : _downloadLabel(
            context.l10n,
            seasonEps,
            hasMultipleSeasons,
            currentSeason,
          );

    // ── Windows Play / Download actions (show-8) ────────────────────────────
    // Built once so the desktop buttons and the page keys (Enter/Space, D)
    // always do exactly the same thing. Null = the button is disabled.
    final VoidCallback? desktopPlay = eps.isEmpty
        ? (offlineSaved.isEmpty
              ? null
              : () => unawaited(
                  launchDownloadedEpisode(
                    context,
                    offlineSaved[offlineStart],
                    episodes: episodesFromDownloads(offlineSaved),
                    startIndex: offlineStart,
                  ),
                ))
        // Downloaded mode: Continue plays the saved file, never a stream.
        : _fromDownloads
        ? () => _playSaved(resumeIdx)
        : () => _openPlayer(
            eps,
            resumeIdx,
            detail,
            category,
            resumeReading: isReading,
          );
    // Downloaded mode has no Download button (and so no D key).
    final VoidCallback? desktopDownload =
        isReading || eps.isEmpty || _fromDownloads
        ? null
        : () => _openDownloadSheet(
            detail: detail,
            category: category,
            episodesBySeason: episodesBySeason,
            initialSeason: currentSeason,
          );
    if (_windowsDesktopUi) {
      // Keys stay dead while the episode list is still loading, like the
      // buttons (they show a spinner then).
      _keyPlay = state.episodesLoading ? null : desktopPlay;
      _keyDownload = state.episodesLoading ? null : desktopDownload;
    }

    // ── Starring / Creators (Genres fallback) muted lines ───────────────────
    // Prefer enriched cast (AniList/TMDB) when available, else the provider's.
    final castNames = state.cast.isNotEmpty
        ? state.cast.map((c) => c.name).toList()
        : detail.cast;
    final starring = castNames.isNotEmpty ? castNames.take(3).join(', ') : null;
    final starringMore = castNames.length > 3;
    final creators = detail.studios.isNotEmpty
        ? detail.studios.join(', ')
        : null;
    // For anime (or anything without cast) surface Genres instead of an empty
    // Starring line — never show an empty label.
    final genresLine = (starring == null && detail.genres.isNotEmpty)
        ? detail.genres.take(4).join(', ')
        : null;

    // Friendly provider name + its origin repo, so the user can tell which repo
    // a source came from. JS providers live in the registry; CloudStream sources
    // live in the CS manager — without the CS lookup this fell back to the raw
    // sourceId ("cs:Provider@31@tag"), leaking the file-id suffix.
    final sourceName = _sourceLabel(
      item.sourceId,
      url: item.url,
      prefer: widget.prefer ?? _preferFromName(item.savedFrom),
      savedFrom: item.savedFrom,
    );

    // Built as a list (not inline in NestedScrollView) so the Windows wide
    // layout below can split the header between two panes.
    final headerSlivers = <Widget>[
        // ── 1. Hero: backdrop + overlapping poster + status/total ──────────
        SliverAppBar(
          expandedHeight: _expandedHeight,
          pinned: true,
          // iOS-style chip with its own background (no top fade needed).
          // Padded to sit 14px off the edge, mirroring the top-right
          // trailer controls.
          leadingWidth: 62,
          leading: const Padding(
            padding: EdgeInsets.only(left: 14),
            child: _DetailBackButton(),
          ),
          // Opaque while adaptive colour is on, painted in the same wash as the
          // body, so the pinned bar hides scrolled content instead of letting
          // it show through (a transparent bar read as an unfinished page).
          // Flat theme bg otherwise, exactly as before.
          backgroundColor: ThemeController.adaptiveColour
              ? (_tint.value ?? AppColors.bg)
              : AppColors.bg,
          surfaceTintColor: Colors.transparent,
          shadowColor: Colors.transparent,
          centerTitle: false,
          titleSpacing: 0,
          // PRESERVED EFFECT: title fades in once the hero scrolls past.
          title: AnimatedOpacity(
            opacity: _showAppBarTitle ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            // Mini title logo in the collapsed bar; plain text until (and
            // unless) one resolves.
            child: _logoUrl != null
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: CachedNetworkImage(
                      imageUrl: logoUrl!,
                      height: 24,
                      fit: BoxFit.contain,
                      alignment: Alignment.centerLeft,
                      fadeInDuration: const Duration(milliseconds: 250),
                      errorWidget: (_, _, _) => _barTitleText(detail.title),
                      errorListener: widget.item.sourceId == stremioSourceId
                          ? (_) => _loadLogo(failedUrl: logoUrl)
                          : null,
                    ),
                  )
                : _barTitleText(detail.title),
          ),
          flexibleSpace: FlexibleSpaceBar(
            collapseMode: CollapseMode.parallax,
            background: RepaintBoundary(
              child: _Hero(
                title: detail.title,
                onTitleTap: () => _onTitleTap(detail.title),
                coverUrl: coverUrl,
                imageDecodeWidth: mobileHeroDecodeWidth(item.sourceId, 800),
                coverHeaders: coverHeaders,
                hasCover: hasCover,
                tint: ThemeController.adaptiveColour ? _tint : null,
                trailer: _trailerFuture,
                // Pause the trailer once the hero has scrolled past (reuses
                // the same signal that fades in the app-bar title).
                collapsed: _showAppBarTitle,
                onTapFullscreen: _openTrailer,
              ),
            ),
          ),
        ),

        // ── 2. Title + meta line (Netflix header) ──────────────────────────
        SliverToBoxAdapter(
          child: RepaintBoundary(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Tapping the title opens the search popup (Cue pop-in):
                  // pre-filled query, "Search" or "Search all sources".
                  GestureDetector(
                    onTap: () => _onTitleTap(detail.title),
                    // Official title logo when the toggle resolved one —
                    // grows in smoothly instead of shoving Play down.
                    child: AnimatedSize(
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOut,
                      alignment: Alignment.topCenter,
                      child: _logoUrl != null
                          // Compact natural-size box (never full-width): the
                          // logo fades in exactly where it lands — no
                          // centre-then-left snap while loading.
                          ? ConstrainedBox(
                              constraints: const BoxConstraints(
                                maxHeight: 56,
                                maxWidth: 220,
                              ),
                              child: CachedNetworkImage(
                                imageUrl: logoUrl!,
                                fit: BoxFit.contain,
                                alignment: Alignment.centerLeft,
                                fadeInDuration: const Duration(
                                  milliseconds: 250,
                                ),
                                errorWidget: (_, _, _) =>
                                    _headerTitleText(detail.title),
                                errorListener:
                                    widget.item.sourceId == stremioSourceId
                                    ? (_) => _loadLogo(failedUrl: logoUrl)
                                    : null,
                              ),
                            )
                          : _headerTitleText(detail.title),
                    ),
                  ),
                  // Late metadata grows this block instead of shoving Play
                  // down a frame — that shove read as open-transition jitter.
                  AnimatedSize(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOut,
                    alignment: Alignment.topCenter,
                    child: metaLine.isNotEmpty
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      metaLine,
                                      style: AppText.body.copyWith(
                                        color: AppColors.textSecondary,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  // What the source claims it serves — "4K", "HD",
                                  // "CAM". Only CloudStream reports one, so it is
                                  // usually absent.
                                  if ((item.quality ?? '')
                                      .trim()
                                      .isNotEmpty) ...[
                                    const SizedBox(width: 8),
                                    _MetaBadge(
                                      item.quality!.trim().toUpperCase(),
                                    ),
                                  ],
                                  if (detail.isAdult) ...[
                                    const SizedBox(width: 8),
                                    const _MetaBadge('18+'),
                                  ],
                                ],
                              ),
                            ],
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          ),
        ),

        // ── 3. White Play + gray Download buttons (full-width, stacked) ─────
        // (The hero banner autoplays the trailer; tap it for fullscreen.)
        //
        // Each button carries its own 16px side padding (rather than one
        // Padding wrapping the whole Column) so the Z Mode selector below
        // can sit as a plain last child: it already supplies its own 16px
        // side padding (it's normally a top-level sliver child), and a
        // shared wrapper would double that indent.
        SliverToBoxAdapter(
          // Windows: desktop action strip (Play/Download/source side by side);
          // phone keeps upstream's stacked buttons.
          child: _windowsDesktopUi
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: DesktopDetailActions(
                    play: _PlayButton(
                      loading: state.episodesLoading,
                      label: buttonLabel,
                      icon: isReading
                          ? Icons.menu_book_rounded
                          : Icons.play_arrow_rounded,
                      onPressed: desktopPlay,
                    ),
                    // Downloaded mode: "Show online" opens the normal page
                    // (disabled for files recovered from disk, which have no
                    // page to open).
                    download: _fromDownloads
                        ? _ShowOnlineButton(
                            onPressed: widget.item.url.isEmpty
                                ? null
                                : _openOnline,
                          )
                        : isReading
                        ? null
                        : _DownloadButton(
                            loading: state.episodesLoading,
                            label: downloadLabel,
                            onPressed: desktopDownload,
                          ),
                    // No Auto Resolve / Wrong title row for downloaded files;
                    // only its alternative (romaji) title line, as plain text.
                    source: _fromDownloads
                        ? _savedAltTitleLine(detail)
                        : !_fromDownloads &&
                            sourceMetadataReady &&
                            ZmodeIds.isZ(widget.item.url)
                        ? MatchLine(
                            canonical: ZmodeIds.parseShow(widget.item.url)!,
                            title: detail.title,
                            altTitle: detail.englishTitle,
                            malId: detail.malId,
                            metadataAliases: [
                              if (detail.englishTitle != null)
                                detail.englishTitle!,
                              if (detail.nativeTitle != null) detail.nativeTitle!,
                              ...detail.synonyms,
                            ],
                            compact: true,
                          )
                        : null,
                  ),
                )
              : Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
                child: _PlayButton(
                  loading: state.episodesLoading,
                  label: buttonLabel,
                  icon: isReading
                      ? Icons.menu_book_rounded
                      : Icons.play_arrow_rounded,
                  onPressed: eps.isNotEmpty
                      ? () => _openPlayer(
                          eps,
                          resumeIdx,
                          detail,
                          category,
                          resumeReading: isReading,
                        )
                      : null,
                ),
              ),
              // Reading downloads are out of scope for this plan.
              if (!isReading)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: _DownloadButton(
                    // Gated exactly like Play above: with no episodes there is
                    // nothing to download, and leaving it live on a title no
                    // source matched just moves the dead end one tap later.
                    loading: state.episodesLoading,
                    label: downloadLabel,
                    onPressed: eps.isEmpty
                        ? null
                        : () => _openDownloadSheet(
                            detail: detail,
                            category: category,
                            episodesBySeason: episodesBySeason,
                            initialSeason: currentSeason,
                          ),
                  ),
                ),
              // Z Mode: matched source + "Wrong title?", kept with the
              // actions it controls instead of under the synopsis.
              // The first frame may be built from the tapped catalogue card,
              // which has no synonyms/native title. Don't start a canonical
              // source search until full metadata arrives: resolve() shares
              // in-flight work by title id, so an early search would make the
              // later alias-aware lookup reuse the incomplete one.
              // Same late-arrival growth as the meta line above.
              AnimatedSize(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOut,
                alignment: Alignment.topCenter,
                child: sourceMetadataReady && ZmodeIds.isZ(widget.item.url)
                    ? MatchLine(
                        canonical: ZmodeIds.parseShow(widget.item.url)!,
                        title: detail.title,
                        altTitle: detail.englishTitle,
                        malId: detail.malId,
                        metadataAliases: [
                          if (detail.englishTitle != null) detail.englishTitle!,
                          if (detail.nativeTitle != null) detail.nativeTitle!,
                          ...detail.synonyms,
                        ],
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),

        // ── 4. Synopsis (clamped) + "Read more" → Details tab ───────────────
        SliverToBoxAdapter(
          child: AnimatedSize(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: (cleanSynopsis(detail.description) ?? '').isNotEmpty
                ? Padding(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      _windowsDesktopUi ? 8 : 18,
                      16,
                      0,
                    ),
                    child: _Description(
                      text: cleanSynopsis(detail.description) ?? '',
                      // "Read more" reveals the Details tab (full synopsis) rather
                      // than expanding inline; the header stays clamped to 3 lines.
                      onReadMore: () => _revealTab(_detailsTab),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ),

        // ── 5. Starring / Creators / Genres muted lines ─────────────────────
        SliverToBoxAdapter(
          child: AnimatedSize(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: starring != null || creators != null || genresLine != null
                ? Padding(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      _windowsDesktopUi ? 8 : 14,
                      16,
                      0,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (starring != null)
                          _CreditLine(
                            label: context.l10n.starring,
                            value: starring,
                            more: starringMore,
                            // Tapping the line (or its "… more") reveals the Cast tab.
                            // Downloaded mode has no Cast tab to open.
                            onMore: starringMore && !_fromDownloads
                                ? () => _revealTab(1)
                                : null,
                          ),
                        if (genresLine != null)
                          _CreditLine(
                            label: context.l10n.genres,
                            value: genresLine,
                          ),
                        if (creators != null)
                          _CreditLine(
                            label: context.l10n.creators,
                            value: creators,
                          ),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ),

        // ── 6. Icon-over-label action row (My List / Trailer / Share / Web) ─
        // "Trailer" is a CloudStream-style result action (recloudstream's
        // result fragment exposes a Trailer button); it opens the fullscreen
        // TrailerScreen and only appears once a trailer id has resolved.
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              _windowsDesktopUi ? 16 : 8,
              _windowsDesktopUi ? 8 : 20,
              8,
              8,
            ),
            child: _DetailActionRow(
              children: [
                _IconAction(
                  icon: _inMyList ? Icons.check_rounded : Icons.add_rounded,
                  active: _inMyList,
                  // Reading-aware: a manga on your list is "Reading", not
                  // "Watching". Display only — the stored status is still
                  // WatchStatus.watching, so My List and the trackers are
                  // untouched, and reading:false returns the plain label
                  // unchanged for anime.
                  label: _status == null
                      ? context.l10n.myList
                      : shortLabelFor(_status!, reading: isReading),
                  tooltip: _inMyList
                      ? context.l10n.changeStatus
                      : context.l10n.addToMyList,
                  onTap: () => _openListSheet(detail),
                ),
                // Windows shows the bell too (track-1): subscriptions feed the
                // in-app New episodes inbox and Windows notifications.
                // Not in downloaded mode: its list is the saved files, not
                // the source's episodes a subscription has to compare with.
                if ((Platform.isAndroid || _windowsDesktopUi) &&
                    !_fromDownloads &&
                    (_subscribed || (!state.episodesLoading && eps.isNotEmpty)))
                  _IconAction(
                    icon: _subscribed
                        ? Icons.notifications_active_rounded
                        : Icons.notifications_none_rounded,
                    active: _subscribed,
                    label: context.l10n.notify,
                    tooltip: _subscribed
                        ? context.l10n.stopAlerts
                        : (isReading
                              ? context.l10n.notifyOnNewChapters
                              : context.l10n.notifyOnNewEpisodes),
                    onTap: () => _toggleSubscribe(detail),
                  ),
                if (_trackingAvailable(detail))
                  _IconAction(
                    icon: _tracked
                        ? Icons.published_with_changes_rounded
                        : Icons.sync_rounded,
                    active: _tracked,
                    label: context.l10n.tracking,
                    tooltip: _tracked
                        ? context.l10n.trackedEditStatusScoreProgress
                        : context.l10n.syncStatusScoreProgress,
                    onTap: () => _openTrackingSheet(detail),
                  ),
                _IconAction(
                  icon: Icons.ios_share_rounded,
                  label: context.l10n.share,
                  tooltip: context.l10n.share,
                  onTap: () => _share(detail, sourceName),
                ),
                _IconAction(
                  icon: Icons.public_rounded,
                  label: context.l10n.web,
                  tooltip: context.l10n.openSourceSite,
                  onTap: _openSourceSite,
                ),
                // Novel only — a manga chapter is images, not text, and
                // there's nothing to put in an EPUB.
                if (detail.type == ProviderType.novel)
                  _IconAction(
                    icon: Icons.output,
                    label: context.l10n.epub,
                    tooltip: context.l10n.exportAsEpub,
                    onTap: () => showEpubExportSheet(
                      context,
                      sourceId: detail.sourceId.isNotEmpty
                          ? detail.sourceId
                          : item.sourceId,
                      showTitle: detail.title,
                      chapters: eps,
                    ),
                  ),
              ],
            ),
          ),
        ),

        // ── 7. Pinned tab bar ───────────────────────────────────────────────
        SliverPersistentHeader(
          pinned: true,
          delegate: _TabBarDelegate(
            TabBar(
              controller: _tabController,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              // Hug the left edge: the first tab starts flush with the 16px
              // content gutter (title/synopsis), and labelPadding(right: 24)
              // spaces the tabs apart while keeping them left-anchored —
              // never centered/spread (matches Sozo Read).
              padding: const EdgeInsetsDirectional.only(start: 16),
              labelPadding: const EdgeInsetsDirectional.only(end: 24),
              labelColor: AppColors.accent,
              unselectedLabelColor: AppColors.textSecondary,
              indicatorSize: TabBarIndicatorSize.label,
              indicator: UnderlineTabIndicator(
                borderSide: BorderSide(color: AppColors.accent, width: 2.5),
                // Bottom inset lifts the line toward the label. A Tab is 46
                // high for 15px text, so the indicator otherwise draws at the
                // bottom of that box with a visible gap under the word.
                // Raising the line rather than shortening the tab keeps the
                // tap target at its full height.
                insets: EdgeInsetsDirectional.only(start: 2, end: 2, bottom: 8),
              ),
              // Remove the full-width underline divider under the bar.
              dividerColor: Colors.transparent,
              dividerHeight: 0,
              splashFactory: NoSplash.splashFactory,
              overlayColor: WidgetStateProperty.all(Colors.transparent),
              labelStyle: AppText.headline.copyWith(fontSize: 15),
              unselectedLabelStyle: AppText.headline.copyWith(
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
              tabs: [
                Tab(
                  text: isReading
                      ? context.l10n.chapters
                      : (detail.isFilm
                            ? context.l10n.movie
                            : context.l10n.episodes),
                ),
                // Downloaded mode keeps only Episodes + Details.
                if (!_fromDownloads) ...[
                  Tab(
                    text: isReading
                        ? context.l10n.characters
                        : context.l10n.cast,
                  ),
                  Tab(text: context.l10n.relations),
                ],
                Tab(text: context.l10n.details),
              ],
            ),
            tint: ThemeController.adaptiveColour ? _tint : null,
          ),
        ),
    ];
    final contentTabs = TabBarView(
        controller: _tabController,
        children: [
          // ── Episodes ──────────────────────────────────────────────────────
          _EpisodesTab(
            category: category,
            // Windows: an empty list falls back to this show's downloads.
            downloadedFallback: offlineSaved,
            loading: state.episodesLoading,
            eps: eps,
            seasonEps: seasonEps,
            fillerEps: _fillerEps,
            hasMultipleSeasons: hasMultipleSeasons,
            seasonSet: seasonSet,
            currentSeason: currentSeason,
            onSelectSeason: cubit.selectSeason,
            coverUrl: coverUrl,
            coverHeaders: coverHeaders,
            wideCoverUrl: _desktopWideEpisodeArt(item, detail),
            sourceId: item.sourceId,
            // Downloads name the source that has the files; progress above
            // stays on the canonical id.
            downloadSourceId: detail.sourceId.isNotEmpty
                ? detail.sourceId
                : item.sourceId,
            showId: item.id,
            showUrl: item.url,
            resumeIndex: _resumeIndex,
            hasAnyMark: hasAnyMark,
            trackerProgress: _trackerProgress,
            nextAiringEpisode: _nextAiringEpisode,
            nextAiringAt: _nextAiringAt,
            // Downloaded mode: a row plays its saved file directly.
            onOpen: (fullIndex) => _fromDownloads
                ? _playSaved(fullIndex)
                : _openPlayer(eps, fullIndex, detail, category),
            // Reading has no player to pick, but it does have the marking
            // rows — gating the whole menu on the player is what hid them.
            // (Its Windows download rows give Play offline / Show in folder /
            // Delete for a saved episode, which downloaded mode relies on.)
            onEpisodeMenu: (fullIndex) =>
                _pickPlayerFor(eps, fullIndex, detail, category),
            // Downloaded mode has no source list to refresh.
            onRefresh: _fromDownloads ? null : cubit.refresh,
            // Downloaded mode: the selection deletes files instead of
            // downloading them.
            onDeleteMany: _fromDownloads ? _deleteSaved : null,
            onDownload: (ep) => isReading
                ? _downloadChapter(ep, detail)
                : _downloadSingle(ep, detail, category),
            onDownloadMany: isReading
                ? (eps) => _downloadChapters(eps, detail)
                : null,
            resumeChapter: readResume == null || eps.isEmpty
                ? null
                : eps[readResume.index],
            // Only a catalogue title has another source to fall back on.
            onSwitchSource: ZmodeIds.isZ(item.url) && !_fromDownloads
                ? _switchSource
                : null,
            isReading: isReading,
            filmMeta: _filmMeta(detail),
            filmTitle: detail.title,
            // B1: the ticks use the same any-cut lookup (and MAL id) as the
            // right-click menu and Play (_savedInAnyCut), Windows online page
            // only.
            malId: detail.malId ?? item.malId,
            anyCutFallback: _windowsDesktopUi && !_fromDownloads,
          ),
          // Downloaded mode has no Cast / Relations tabs (Details only).
          if (!_fromDownloads) ...[
            // ── Cast ──────────────────────────────────────────────────────────
            _CastTab(
              loading: state.extrasLoading,
              cast: state.cast.isNotEmpty
                  ? state.cast
                  : [for (final n in detail.cast) CastMember(name: n)],
              onOpenPerson: (ref) => Navigator.of(
                context,
              ).push(PersonPage.route(ref, sourceId: widget.item.sourceId)),
            ),
            // ── Relations ───────────────────────────────────────────────────────
            _RelationsTab(
              loading: state.extrasLoading,
              relations: state.relations,
              seasons: state.seasons,
              onOpen: _openRelation,
            ),
          ],
          // ── Details ──────────────────────────────────────────────────────────
          _DetailsTab(
            sourceName: sourceName,
            statusStr: statusStr,
            reading: isReading,
            genres: detail.genres,
            studios: detail.studios,
            // Downloaded mode: the show's total, like the header line.
            episodeCount: shownCount,
            isMovie: detail.isFilm,
            year: detail.year,
            description: cleanSynopsis(detail.description),
            detail: detail,
          ),
        ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (_windowsDesktopUi && constraints.maxWidth >= 980) {
          final infoWidth = (constraints.maxWidth * 0.31).clamp(340.0, 420.0);
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: infoWidth,
                child: CustomScrollView(
                  controller: _scrollController,
                  slivers: headerSlivers
                      .take(headerSlivers.length - 1)
                      .toList(),
                ),
              ),
              VerticalDivider(
                width: 1,
                thickness: 1,
                color: AppColors.hairline,
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                  child: NestedScrollView(
                    headerSliverBuilder: (_, _) => [headerSlivers.last],
                    body: contentTabs,
                  ),
                ),
              ),
            ],
          );
        }
        return NestedScrollView(
          controller: _scrollController,
          headerSliverBuilder: (_, _) => headerSlivers,
          body: contentTabs,
        );
      },
    );
  }
}

/// Windows downloaded show page: "Show online", sitting where Download sits
/// on the normal page and drawn like it (graphite fill, 40px high), opening
/// the normal online page for the same title. Null [onPressed] dims it.
class _ShowOnlineButton extends StatelessWidget {
  const _ShowOnlineButton({required this.onPressed});

  final VoidCallback? onPressed;

  /// Lets tests find the button.
  static const buttonKey = ValueKey('detail-show-online');

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: onPressed != null ? 1.0 : 0.4,
      child: Material(
        key: buttonKey,
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onPressed,
          child: SizedBox(
            height: 40,
            width: double.infinity,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.public_rounded, color: Colors.white, size: 22),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    // Hardcoded like the other Windows-only labels.
                    'Show online',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.button.copyWith(color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What a detail page shows until it has loaded: the page colour and one
/// circular loader in the middle of the whole screen.
class _DetailLoading extends StatelessWidget {
  const _DetailLoading();

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: AppColors.bg,
    child: const Center(child: _AppSpinner()),
  );
}

/// The bar shown when a detail page only half-loaded.
///
/// Named after the service that actually failed, not the app: "couldn't load"
/// on its own reads as Zangetsu being broken, when the usual causes are
/// AniList rate-limiting or a source being down. It sits over the page rather
/// than replacing it — the row you tapped already had a cover and a title, and
/// throwing those away to show an error helps nobody.
///
/// It tells you and gets out of the way. No retry button: the page has two
/// recoveries already — switching source re-runs the fetch, and reopening it
/// starts clean — and a button that mostly cannot help (a rate limit rejects
/// it before it leaves the device) is worse than no button.
///
/// Windows (show-14) differs: a desktop user who looked away missed the
/// 4-second notice, so there it stays until dismissed ([persistent]) and adds
/// Retry ([onRetry]), disabled with a countdown until [retryNotBefore] while
/// rate-limited so it never fires a request that would be refused.
class _LoadFailureBanner extends StatefulWidget {
  const _LoadFailureBanner({
    required this.service,
    required this.isMetadataProvider,
    required this.error,
    this.persistent = false,
    this.onRetry,
    this.retryNotBefore,
  });

  /// Windows: no auto-hide; only the close button removes the banner.
  final bool persistent;

  /// Windows: shows a Retry button that re-runs the fetch.
  final VoidCallback? onRetry;

  /// Rate-limited: Retry stays disabled (counting down) until this time.
  final DateTime? retryNotBefore;

  /// What failed, in the user's terms — "AniList", "Simkl", "AniKoto".
  final String service;

  /// A metadata catalogue rather than an installed source.
  final bool isMetadataProvider;

  final String? error;

  @override
  State<_LoadFailureBanner> createState() => _LoadFailureBannerState();
}

class _LoadFailureBannerState extends State<_LoadFailureBanner> {
  /// It sits over the scroll view, so it hides the last of the page while it
  /// is up. Long enough to read, short enough not to be in the way.
  static const Duration _visibleFor = Duration(seconds: 4);

  bool _dismissed = false;
  Timer? _hide;

  /// Windows: ticks once a second while the Retry countdown runs.
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _armAutoHide();
    _armCountdown();
  }

  @override
  void didUpdateWidget(_LoadFailureBanner old) {
    super.didUpdateWidget(old);
    if (old.error != widget.error) _armAutoHide(); // a new failure, shown again
    if (old.retryNotBefore != widget.retryNotBefore) _armCountdown();
  }

  @override
  void dispose() {
    _hide?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  void _armAutoHide() {
    _hide?.cancel();
    _dismissed = false;
    // Windows keeps it up until the user closes it.
    if (widget.persistent) return;
    _hide = Timer(_visibleFor, () {
      if (mounted) setState(() => _dismissed = true);
    });
  }

  /// Seconds left before Retry is worth pressing (0 = ready).
  int get _retryWait {
    final until = widget.retryNotBefore;
    if (until == null) return 0;
    final left = until.difference(DateTime.now());
    if (left <= Duration.zero) return 0;
    // Round up so it never reads 0 while still disabled.
    return (left.inMilliseconds / 1000).ceil();
  }

  /// Repaints every second until the countdown reaches 0.
  void _armCountdown() {
    _tick?.cancel();
    if (widget.onRetry == null || _retryWait == 0) return;
    _tick = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() {});
      if (_retryWait == 0) t.cancel();
    });
  }

  int? get _limitSeconds {
    final e = widget.error;
    return e != null && e.startsWith('rate_limited:')
        ? int.tryParse(e.substring('rate_limited:'.length))
        : null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final secs = _limitSeconds;
    final offline = widget.error == 'offline';
    // Same words Home uses for the same failure — one voice, so the app does
    // not describe an AniList outage two different ways depending on where you
    // happen to be standing.
    final (icon, title, body) = offline
        ? (Icons.wifi_off_rounded, l10n.offlineTitle, l10n.offlineBody)
        : secs != null
        ? (
            Icons.hourglass_bottom_rounded,
            l10n.providerNeedsBreather(widget.service),
            l10n.providerNeedsBreatherBody(secs),
          )
        : (
            Icons.cloud_off_rounded,
            widget.isMetadataProvider
                ? l10n.providerHavingAMoment(widget.service)
                : l10n.sourceNotAnswering(widget.service),
            l10n.showingWhatWeHave,
          );
    // Windows (src-11): an extension time-out reads "Source timed out"
    // (the Retry button is unchanged). onRetry is only set on Windows.
    final shownTitle = widget.onRetry != null
        ? sourceFailureMessage(widget.error, title)
        : title;
    return IgnorePointer(
      ignoring: _dismissed,
      child: AnimatedOpacity(
        opacity: _dismissed ? 0 : 1,
        duration: const Duration(milliseconds: 220),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AppColors.settingsCard,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: AppColors.hairline),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x66000000),
                    blurRadius: 16,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
                child: Row(
                  // Centred against the whole text block. Top-aligned, the
                  // icon sat level with the title and looked adrift once the
                  // body wrapped to a second line.
                  children: [
                    Icon(icon, size: 20, color: AppColors.accent),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            shownTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.body.copyWith(
                              color: AppColors.textPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(body, style: AppText.caption),
                        ],
                      ),
                    ),
                    // Windows: Retry, counting down while rate-limited.
                    if (widget.onRetry != null) ...[
                      const SizedBox(width: 8),
                      Builder(
                        builder: (context) {
                          final wait = _retryWait;
                          return TextButton(
                            key: const ValueKey('detail-load-retry'),
                            onPressed: wait > 0 ? null : widget.onRetry,
                            style: TextButton.styleFrom(
                              foregroundColor: AppColors.accent,
                              visualDensity: VisualDensity.compact,
                            ),
                            child: Text(
                              wait > 0
                                  ? l10n.retryInSeconds(wait)
                                  : l10n.retry,
                            ),
                          );
                        },
                      ),
                      const SizedBox(width: 2),
                    ],
                    IconButton(
                      tooltip: l10n.dismiss,
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 32,
                        height: 32,
                      ),
                      icon: const Icon(Icons.close_rounded, size: 18),
                      color: AppColors.textTertiary,
                      onPressed: () {
                        _hide?.cancel();
                        setState(() => _dismissed = true);
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
