import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../core/ui/app_dialog.dart';
import '../../core/ui/app_toast.dart';
import '../../core/ui/settings_widgets.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/download/chapter_download_store.dart';
import '../../core/download/download_manager.dart';
import '../../core/download/download_prefs.dart';
import '../../core/download/download_record.dart';
import '../../core/mode/content_mode.dart';
import '../../core/models/episode.dart';
import '../../core/models/video_source.dart';
import '../../core/playback/resume_store.dart';
import '../../core/torrent/torrent_download_service.dart';
import '../../core/playback/watch_history.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/states.dart';
import '../../core/ui/poster_card.dart' show posterGridColumns;
import '../../l10n/l10n.dart';
import '../settings/download_location_screen.dart';
import '../player/player_screen.dart';
import '../player/tv_playback_launch.dart';
import 'downloaded_episode_playback.dart';
import 'chapter_downloads_screen.dart';
import 'downloads_screen_tv.dart';
import 'download_library_widgets.dart';

/// Poster library for saved shows, opening the existing episode controls.
class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key, this.showBack = true});

  /// False when shown as a dock tab — see [settingsAppBar].
  final bool showBack;

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  bool _searching = false;
  ContentMode _kind = ContentMode.anime;
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this)..addListener(_onTabChanged);
    WidgetsBinding.instance.addObserver(this);
    _prune();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabs.removeListener(_onTabChanged);
    _tabs.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from a file manager (where a file may have been deleted) →
    // reconcile the list with disk. This is the case initState alone missed.
    if (state == AppLifecycleState.resumed) _prune();
  }

  /// Drop downloads whose file was deleted outside the app. Non-blocking.
  void _prune() => unawaited(sl<DownloadManager>().pruneMissing());

  void _toggleSearch() => setState(() {
    _searching = !_searching;
    if (!_searching) {
      _searchCtrl.clear();
      _query = '';
    }
  });

  Widget _header() {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.surface.withValues(alpha: .72),
          borderRadius: BorderRadius.circular(26),
          border: Border.all(color: AppColors.hairline, width: .5),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
          child: Row(
            children: [
              if (widget.showBack)
                IconButton(
                  style: IconButton.styleFrom(
                    fixedSize: const Size.square(36),
                    minimumSize: const Size.square(36),
                    padding: EdgeInsets.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                  icon: const Icon(Icons.arrow_back_rounded, size: 20),
                  onPressed: _searching
                      ? _toggleSearch
                      : () => Navigator.of(context).maybePop(),
                )
              else
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: Icon(Icons.download_rounded, size: 22),
                ),
              Expanded(
                child: _searching
                    ? _searchField()
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            l10n.downloads,
                            style: AppText.headline.copyWith(fontSize: 15.5),
                          ),
                          Text(
                            l10n.downloadsSubtitleTv,
                            style: AppText.caption.copyWith(fontSize: 11),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
              ),
              _headerButton(
                icon: _searching ? Icons.close_rounded : Icons.search_rounded,
                tooltip: l10n.search,
                onTap: _toggleSearch,
              ),
              const SizedBox(width: 8),
              _headerButton(
                icon: Icons.tune_rounded,
                tooltip: l10n.downloadSettings,
                onTap: _openDownloadSettings,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _headerButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) => IconButton(
    tooltip: tooltip,
    onPressed: onTap,
    icon: Icon(icon, size: 18),
    color: AppColors.accent,
    style: IconButton.styleFrom(
      backgroundColor: AppColors.surface2,
      fixedSize: const Size.square(36),
      minimumSize: const Size.square(36),
      padding: EdgeInsets.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
  );

  /// "Saving to: `folder` · Change" — surfaces the download location right here
  /// (opens the existing picker) instead of only burying it in Settings.
  Widget _locationHeader() {
    final l10n = context.l10n;
    final prefs = sl<DownloadPrefs>();
    final label = downloadDestinationLabel(
      keepPrivate: prefs.keepPrivate,
      locationLabel: prefs.locationLabel,
      publicFallback: l10n.downloadsZangetsu,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 12, 4),
      child: Row(
        children: [
          const Icon(
            Icons.folder_outlined,
            size: 18,
            color: AppColors.textSecondary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: AppText.caption.copyWith(fontSize: 11),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const DownloadLocationScreen(),
                ),
              );
              if (mounted) setState(() {}); // refresh the shown folder
            },
            child: Text(
              l10n.change,
              style: AppText.body.copyWith(
                color: AppColors.accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Bottom sheet with the CloudStream-style download concurrency sliders.
  /// Applies to the NEXT downloads started (running HLS jobs aren't retimed).
  void _openDownloadSettings() {
    final l10n = context.l10n;
    final prefs = sl<DownloadPrefs>();
    // Hold the live drag value in local state so the sliders move smoothly —
    // each tick isn't an async Hive write/read round-trip. Persist + apply on
    // release (onCommit).
    int parallel = prefs.parallelDownloads;
    int connections = prefs.connectionsPerDownload;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          Widget slider({
            required String title,
            required String subtitle,
            required int value,
            required int min,
            required int max,
            required ValueChanged<int> onChanged,
            ValueChanged<int>? onCommit,
          }) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                  child: Row(
                    children: [
                      Expanded(child: Text(title, style: AppText.headline)),
                      Text(
                        '$value',
                        style: AppText.headline.copyWith(
                          color: AppColors.accent,
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
                  child: Text(subtitle, style: AppText.caption),
                ),
                Slider(
                  value: value.toDouble(),
                  min: min.toDouble(),
                  max: max.toDouble(),
                  divisions: max - min,
                  activeColor: AppColors.accent,
                  label: '$value',
                  onChanged: (v) => setSheet(() => onChanged(v.round())),
                  onChangeEnd: onCommit == null
                      ? null
                      : (v) => onCommit(v.round()),
                ),
              ],
            );
          }

          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 12, bottom: 4),
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.textTertiary.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(l10n.downloadSettings, style: AppText.title),
                  ),
                ),
                slider(
                  title: l10n.parallelDownloads,
                  subtitle: l10n.parallelDownloadsSubtitle,
                  value: parallel,
                  min: DownloadPrefs.parallelMin,
                  max: DownloadPrefs.parallelMax,
                  onChanged: (n) => parallel = n,
                  // On release: persist + apply live to both paths (MP4 queue +
                  // HLS service). Raising it starts queued episodes immediately;
                  // lowering it just stops new ones spawning.
                  onCommit: (n) {
                    prefs.setParallelDownloads(n);
                    sl<DownloadManager>().setParallel(n);
                  },
                ),
                const SizedBox(height: 8),
                slider(
                  title: l10n.connectionsPerDownload,
                  subtitle: l10n.connectionsPerDownloadSubtitle,
                  value: connections,
                  min: DownloadPrefs.connectionsMin,
                  max: DownloadPrefs.connectionsMax,
                  onChanged: (n) => connections = n,
                  onCommit: (n) => prefs.setConnectionsPerDownload(n),
                ),
                const SizedBox(height: 12),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (sl<AppMode>().isTv) {
      return DownloadsScreenTv(resume: sl<ResumeStore>());
    }
    final manager = sl<DownloadManager>();
    final store = sl<ChapterDownloadStore>();
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: ListenableBuilder(
        listenable: manager,
        builder: (context, _) {
          final groups = manager.byShow;
          return SafeArea(
            bottom: false,
            child: Column(
              children: [
                _header(),
                _chapterLinks(store),
                _locationHeader(),
                Expanded(
                  child: TabBarView(
                    controller: _tabs,
                    children: [
                      DownloadEntrance(
                        child: groups.isEmpty
                            ? EmptyState(
                                icon: Icons.download_outlined,
                                message:
                                    context.l10n.episodesYouDownloadAppearHere,
                              )
                            : _list(groups, manager),
                      ),
                      for (final mode in const [
                        ContentMode.manga,
                        ContentMode.novel,
                      ])
                        DownloadEntrance(
                          key: ValueKey(mode),
                          child: ChapterDownloadsScreen(
                            key: PageStorageKey(mode),
                            mode: mode,
                            embedded: true,
                            query: _query,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // Chapter counts update independently of the video library.
  Widget _chapterLinks(ChapterDownloadStore store) {
    return ValueListenableBuilder<Box<Map>>(
      valueListenable: store.listenable(),
      builder: (context, box, _) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: TabBar(
          controller: _tabs,
          labelColor: AppColors.accent,
          unselectedLabelColor: AppColors.textSecondary,
          labelStyle: AppText.body.copyWith(
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
          unselectedLabelStyle: AppText.body.copyWith(fontSize: 13),
          labelPadding: const EdgeInsets.symmetric(horizontal: 4),
          indicatorColor: AppColors.accent,
          indicatorWeight: 2,
          indicatorSize: TabBarIndicatorSize.label,
          dividerColor: AppColors.hairline,
          tabs: [
            Tab(height: 34, text: context.l10n.episodes),
            for (final mode in const [ContentMode.manga, ContentMode.novel])
              Tab(
                height: 34,
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: mode == ContentMode.novel
                            ? context.l10n.novels
                            : context.l10n.modeManga,
                      ),
                      if (store.countDone(mode) > 0)
                        TextSpan(
                          text: '  ${store.countDone(mode)}',
                          style: const TextStyle(fontSize: 10),
                        ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _onTabChanged() => _selectKind(ContentMode.values[_tabs.index]);

  void _selectKind(ContentMode mode) {
    if (_kind == mode) return;
    setState(() {
      _kind = mode;
      _query = '';
      _searchCtrl.clear();
    });
  }

  Widget _searchField() => TextField(
    controller: _searchCtrl,
    autofocus: true,
    onChanged: (value) => setState(() => _query = value),
    style: AppText.body.copyWith(fontSize: 13, color: AppColors.textPrimary),
    decoration: InputDecoration(
      isDense: true,
      hintText: context.l10n.searchDownloads,
      hintStyle: AppText.body.copyWith(
        fontSize: 13,
        color: AppColors.textTertiary,
      ),
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
      contentPadding: const EdgeInsets.symmetric(vertical: 8),
    ),
  );

  Widget _list(
    Map<String, List<DownloadRecord>> groups,
    DownloadManager manager,
  ) {
    final q = _query.trim().toLowerCase();
    final done = manager.all.where((r) => r.status == DownloadStatus.done);
    final totalBytes = done.fold<int>(0, (s, r) => s + r.bytesTotal);
    final shown =
        <
          ({
            String id,
            List<DownloadRecord> records,
            List<DownloadRecord> episodes,
          })
        >[];
    for (final entry in groups.entries) {
      if (entry.value.isEmpty) continue;
      final records = [
        ...entry.value,
      ]..sort((a, b) => (a.episodeNumber ?? 0).compareTo(b.episodeNumber ?? 0));
      final showMatch = records.first.showTitle.toLowerCase().contains(q);
      final episodes = q.isEmpty || showMatch
          ? records
          : records.where((r) => _episodeSearchText(r).contains(q)).toList();
      if (episodes.isNotEmpty) {
        shown.add((id: entry.key, records: records, episodes: episodes));
      }
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = posterGridColumns(context);
        final cellWidth =
            (constraints.maxWidth - 32 - 12 * (columns - 1)) / columns;
        final textHeight = MediaQuery.textScalerOf(context).scale(12);
        return CustomScrollView(
          key: const PageStorageKey('downloads-grid'),
          slivers: [
            SliverToBoxAdapter(
              child: _summaryStrip(count: done.length, bytes: totalBytes),
            ),
            if (shown.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyState(
                  icon: Icons.search_off_rounded,
                  message: context.l10n.noDownloadsMatchYourSearch,
                ),
              )
            else ...[
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 16,
                    mainAxisExtent: cellWidth * 1.5 + textHeight * 6.5,
                  ),
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final group = shown[index];
                    return _DownloadPoster(
                      records: group.records,
                      onOpen: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => _DownloadedShowScreen(
                            showId: group.id,
                            query: _query,
                          ),
                        ),
                      ),
                      onDelete: () =>
                          _confirmDeleteShow(context, group.records, manager),
                    );
                  }, childCount: shown.length),
                ),
              ),
            ],
            SliverToBoxAdapter(
              child: SizedBox(
                height: MediaQuery.paddingOf(context).bottom + 16,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _summaryStrip({required int count, required int bytes}) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
    child: Text(
      context.l10n.downloadedSummary(count, fmtDownloadSize(bytes)),
      style: AppText.caption.copyWith(fontSize: 11),
    ),
  );
}

/// Lowercased text a download is matched against when searching.
String _episodeSearchText(DownloadRecord r) {
  final n = r.episodeNumber?.toInt();
  return 'e${n ?? ''} ${r.episodeTitle}'.toLowerCase();
}

class _DownloadPoster extends StatelessWidget {
  const _DownloadPoster({
    required this.records,
    required this.onOpen,
    required this.onDelete,
  });

  final List<DownloadRecord> records;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final head = records.first;
    final done = records.where((r) => r.status == DownloadStatus.done);
    final bytes = done.fold<int>(0, (sum, r) => sum + r.bytesTotal);
    final pending = records.where((r) => r.status != DownloadStatus.done);
    final active = pending.where((r) => r.status == DownloadStatus.downloading);
    final current = active.isNotEmpty
        ? active.first
        : (pending.isEmpty ? null : pending.first);
    final status = switch (current?.status) {
      DownloadStatus.downloading => l10n.downloadProgressPercent(
        (current!.progress * 100).round(),
      ),
      DownloadStatus.paused => l10n.downloadPausedProgress(
        (current!.progress * 100).round(),
      ),
      DownloadStatus.finalizing => l10n.downloadFinalizing,
      DownloadStatus.queued => l10n.downloadQueued,
      DownloadStatus.resolving => l10n.downloadPreparing,
      DownloadStatus.failed => l10n.downloadFailedStatus,
      DownloadStatus.unsupported => l10n.notAvailableOfflineYet,
      DownloadStatus.canceled => l10n.downloadCanceled,
      _ => null,
    };
    return DownloadLibraryPoster(
      title: head.showTitle,
      heroTag: ('download-video', head.showId),
      cover: head.cover,
      coverHeaders: head.coverHeaders,
      countLabel: '${done.length}/${records.length}',
      sizeLabel: fmtDownloadSize(bytes),
      status: status,
      progress:
          current?.status == DownloadStatus.downloading ||
              current?.status == DownloadStatus.paused
          ? current!.progress
          : null,
      isDownloading: active.isNotEmpty,
      onOpen: onOpen,
      onDelete: onDelete,
      deleteTooltip: l10n.deleteAllEpisodesTooltip,
    );
  }
}

Future<void> _confirmDeleteShow(
  BuildContext context,
  List<DownloadRecord> records,
  DownloadManager manager,
) async {
  final l10n = context.l10n;
  final ok = await AppDialog.confirm(
    context,
    title: l10n.deleteAllDownloads,
    message: l10n.removeAllEpisodesOfShow(
      records.length,
      records.first.showTitle,
    ),
    confirmLabel: l10n.deleteAll,
    destructive: true,
  );
  if (ok == true) await manager.deleteAll(records);
}

class _DownloadedShowScreen extends StatelessWidget {
  const _DownloadedShowScreen({required this.showId, required this.query});
  final String showId;
  final String query;

  @override
  Widget build(BuildContext context) {
    final manager = sl<DownloadManager>();
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        surfaceTintColor: Colors.transparent,
        title: Text(l10n.downloads, style: AppText.headline),
        leading: IconButton(
          key: const ValueKey('downloads-back-to-grid'),
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: ListenableBuilder(
        listenable: manager,
        builder: (context, _) {
          final records = [...?manager.byShow[showId]]
            ..sort(
              (a, b) => (a.episodeNumber ?? 0).compareTo(b.episodeNumber ?? 0),
            );
          if (records.isEmpty) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (context.mounted &&
                  ModalRoute.of(context)?.isCurrent == true) {
                Navigator.of(context).pop();
              }
            });
            return const SizedBox.shrink();
          }
          final head = records.first;
          final q = query.trim().toLowerCase();
          final episodes = q.isEmpty || head.showTitle.toLowerCase().contains(q)
              ? records
              : records
                    .where((r) => _episodeSearchText(r).contains(q))
                    .toList();
          final done = records.where((r) => r.status == DownloadStatus.done);
          final bytes = done.fold<int>(0, (sum, r) => sum + r.bytesTotal);
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: DownloadTitleSummary(
                  title: head.showTitle,
                  heroTag: ('download-video', showId),
                  cover: head.cover,
                  coverHeaders: head.coverHeaders,
                  subtitle:
                      '${l10n.ofTotalDownloaded(done.length, records.length)} · ${fmtDownloadSize(bytes)}',
                  deleteTooltip: l10n.deleteAllEpisodesTooltip,
                  onDelete: () => _confirmDeleteShow(context, records, manager),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                sliver: SliverToBoxAdapter(
                  child: Text(
                    l10n.episodes,
                    style: AppText.body.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              SliverList.separated(
                itemCount: episodes.length,
                itemBuilder: (context, index) => DownloadTile(
                  record: episodes[index],
                  manager: manager,
                  resume: sl<ResumeStore>(),
                  compact: true,
                ),
                separatorBuilder: (_, _) => const Divider(
                  height: 12,
                  indent: 56,
                  endIndent: 20,
                  color: AppColors.hairline,
                ),
              ),
              SliverToBoxAdapter(
                child: SizedBox(
                  height: MediaQuery.paddingOf(context).bottom + 24,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Launches playback of a completed [DownloadRecord].
/// Called by both [DownloadTile] (phone touch path) and [DownloadsScreenTv]
/// (TV D-pad OK path) so the play logic lives in one place.
///
/// Phone plays through [PlayerScreen] (media_kit); TV routes to the same two
/// ExoPlayer paths streaming already uses, so nothing on TV touches media_kit.
Future<void> launchDownloadedEpisode(
  BuildContext context,
  DownloadRecord record, {
  List<Episode>? episodes,
  int startIndex = 0,
  Future<List<VideoSource>> Function(String episodeUrl)? fallbackResolveSources,
  Future<({List<VideoSource> sources, bool done})> Function(String episodeUrl)?
  pollSources,
  String? playerOverride,
}) async {
  final path = record.filePath;
  if (path == null) return;
  // A record whose file was removed outside the app must say so — not play.
  // Without this, the player treats the dead file as a dead mirror and
  // hunts online links for a download the viewer asked to play offline.
  final manager = sl<DownloadManager>();
  if (!await manager.filePresent(record)) {
    if (context.mounted) {
      showAppToast(context, context.l10n.downloadFileGone);
    }
    return;
  }
  if (!context.mounted) return;
  final queue = downloadedEpisodePlaybackQueue(
    record: record,
    episodes: episodes,
    startIndex: startIndex,
  );
  final selectedEpisodeUrl = queue.episodes[queue.startIndex].url;

  Future<List<VideoSource>?> resolveDownloadedSources(String episodeUrl) async {
    Episode? episode;
    for (final candidate in queue.episodes) {
      if (candidate.url == episodeUrl) {
        episode = candidate;
        break;
      }
    }
    if (episode == null) return null;

    // Keep the selected saved record authoritative even when today's provider
    // has regenerated its opaque episode id or URL. Other queue entries are
    // matched against their source/show keys and stable episode metadata.
    DownloadRecord? downloaded;
    if (episodeUrl == selectedEpisodeUrl) {
      downloaded = record;
    } else {
      downloaded = await manager.finishedForEpisode(
        sourceId: record.sourceId,
        showId: record.showId,
        episodeId: episode.id,
        episodeUrl: episode.url,
        malId: record.malId,
        episodeNumber: episode.number,
      );
    }
    if (downloaded == null || !await manager.filePresent(downloaded)) {
      return null;
    }
    return [downloadedVideoSource(downloaded)];
  }

  // External players and TV call this resolver directly. The in-app phone
  // player checks the dedicated local callback before any progressive sweep.
  // Downloads itself intentionally has no network fallback.
  Future<List<VideoSource>> resolveSources(String episodeUrl) async {
    final local = await resolveDownloadedSources(episodeUrl);
    if (local != null) return local;
    return await fallbackResolveSources?.call(episodeUrl) ?? const [];
  }

  final scrobbleTitle = record.malId != null ? record.showTitle : null;

  if (sl<AppMode>().isTv) {
    await launchTvPlayback(
      context: context,
      sourceId: record.sourceId,
      episodes: queue.episodes,
      startIndex: queue.startIndex,
      resume: sl<ResumeStore>(),
      resolveSources: resolveSources,
      showUrl: record.showUrl,
      showTitle: record.showTitle,
      cover: record.cover,
      coverHeaders: record.coverHeaders,
      category: record.category,
      malId: record.malId,
      scrobbleTitle: scrobbleTitle,
    );
    return;
  }

  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => PlayerScreen(
        sourceId: record.sourceId,
        episodes: queue.episodes,
        startIndex: queue.startIndex,
        resume: sl<ResumeStore>(),
        resolveSources: resolveSources,
        resolveDownloadedSources: resolveDownloadedSources,
        localOnly: fallbackResolveSources == null,
        pollSources: pollSources,
        history: sl<WatchHistory>(),
        showTitle: record.showTitle,
        cover: record.cover,
        coverHeaders: record.coverHeaders,
        showUrl: record.showUrl,
        category: record.category,
        malId: record.malId,
        scrobbleTitle: scrobbleTitle,
        playerOverride: playerOverride,
      ),
    ),
  );
}

class DownloadTile extends StatelessWidget {
  const DownloadTile({
    super.key,
    required this.record,
    required this.manager,
    this.resume,
    this.compact = false,
  });
  final bool compact;
  final DownloadRecord record;
  final DownloadManager manager;

  /// Per-episode watched position, shown under finished downloads so the user
  /// can tell where they left off. Optional only so widget tests can build the
  /// tile without Hive/GetIt; the real screens always pass it.
  final ResumeStore? resume;

  String _epLabel(AppLocalizations l10n) {
    final n = record.episodeNumber?.toInt();
    final t = record.episodeTitle.trim();
    if (n != null) {
      final short = l10n.episodeNumberShort(n);
      if (t.isEmpty || t == short || t == l10n.episodeLabel(n)) return short;
      return l10n.episodeWithTitleDot(n, t);
    }
    final generic = l10n
        .episodeSemantic(1)
        .replaceFirst(' 1', '')
        .replaceFirst('1', '');
    return (t.isEmpty || t == generic) ? generic : '$generic · $t';
  }

  String _subtitle(AppLocalizations l10n) {
    // A finished torrent is streamed into the user's folder — surface that phase.
    if (record.isTorrent &&
        manager.torrentProgress[record.id]?.status == 'copying') {
      return l10n.savingToYourFolder;
    }
    final pct = (record.progress * 100).round();
    return switch (record.status) {
      DownloadStatus.done =>
        record.bytesTotal > 0
            ? fmtDownloadSize(record.bytesTotal)
            : l10n.downloaded,
      DownloadStatus.downloading =>
        record.bytesTotal > 0
            ? l10n.downloadProgressPercentOfSize(
                    pct,
                    fmtDownloadSize(record.bytesTotal),
                  ) +
                  _torrentSuffix(l10n)
            : l10n.downloadProgressPercent(pct) + _torrentSuffix(l10n),
      DownloadStatus.paused => l10n.downloadPausedProgress(pct),
      DownloadStatus.finalizing => l10n.downloadFinalizing,
      DownloadStatus.queued => l10n.downloadQueued,
      DownloadStatus.resolving => l10n.downloadPreparing,
      DownloadStatus.unsupported => record.error ?? l10n.notAvailableOfflineYet,
      DownloadStatus.failed => record.error ?? l10n.downloadFailedStatus,
      DownloadStatus.canceled => l10n.downloadCanceled,
    };
  }

  /// " · N peers · X MB/s" for an active torrent download (empty otherwise).
  String _torrentSuffix(AppLocalizations l10n) {
    if (!record.isTorrent) return '';
    final TorrentDownloadProgress? p = manager.torrentProgress[record.id];
    if (p == null) return '';
    final parts = <String>[];
    if (p.peers > 0) parts.add(l10n.peerCount(p.peers));
    if (p.downSpeedBps > 0) {
      final mb = p.downSpeedBps / (1024 * 1024);
      parts.add(
        mb >= 1
            ? l10n.downloadSpeedMbps(mb.toStringAsFixed(1))
            : l10n.downloadSpeedKbps((p.downSpeedBps / 1024).round()),
      );
    }
    return parts.isEmpty ? '' : ' · ${parts.join(' · ')}';
  }

  Future<void> _play(BuildContext context) async {
    // The whole downloaded season, not just this row — otherwise Next has
    // nowhere to go and the user is bounced back out to pick manually.
    final queue = await downloadedSiblingQueue(
      showRecords: manager.byShow[record.showId] ?? const [],
      record: record,
      filePresent: manager.filePresent,
    );
    if (!context.mounted) return;
    await launchDownloadedEpisode(
      context,
      record,
      episodes: queue.episodes,
      startIndex: queue.startIndex,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final isDone = record.status == DownloadStatus.done;
    return ListTile(
      dense: compact,
      minLeadingWidth: compact ? 28 : null,
      contentPadding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
      onTap: isDone ? () => _play(context) : null,
      leading: compact
          ? SizedBox(
              width: 28,
              height: 32,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: _StatusGlyph(record: record),
              ),
            )
          : _StatusGlyph(record: record),
      title: Text(
        _epLabel(l10n),
        style: AppText.body.copyWith(
          color: AppColors.textPrimary,
          fontSize: compact ? 13 : null,
          fontWeight: compact ? FontWeight.w600 : null,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_subtitle(l10n), style: AppText.caption),
          if (isDone) ...[
            const SizedBox(height: 3),
            _WatchMeta(record: record, resume: resume),
          ],
          if (record.status == DownloadStatus.downloading ||
              record.status == DownloadStatus.paused) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: record.progress > 0 ? record.progress : null,
                minHeight: 3,
                color: AppColors.accent,
                backgroundColor: AppColors.surface2,
              ),
            ),
          ],
        ],
      ),
      trailing: _TileMenu(record: record, manager: manager),
    );
  }
}

/// "quality · CC langs · watched / total" under a finished download, so the
/// offline list answers "which episode was I on?" without opening one.
///
/// Reads only — no download/playback logic lives here. The box listenable
/// refreshes the line as soon as the player saves a position.
class _WatchMeta extends StatelessWidget {
  const _WatchMeta({required this.record, required this.resume});
  final DownloadRecord record;
  final ResumeStore? resume;

  @override
  Widget build(BuildContext context) {
    final resume = this.resume;
    if (resume == null) return _line(context, null);
    return ValueListenableBuilder<Box<Map>>(
      valueListenable: Hive.box<Map>(ResumeStore.boxName).listenable(),
      builder: (context, _, _) => _line(
        context,
        resume.get(record.sourceId, record.showUrl, record.episodeId),
      ),
    );
  }

  Widget _line(BuildContext context, ResumeMark? mark) {
    final l10n = context.l10n;
    final quality = record.quality.trim();
    final finished = mark?.finished ?? false;
    final hasDuration = (mark?.duration.inMilliseconds ?? 0) > 0;
    String? watched;
    if (mark != null && mark.finished) {
      watched = hasDuration ? '${_clock(mark.duration)} ✓' : '✓';
    } else if (mark != null && hasDuration) {
      watched = '${_clock(mark.position)} / ${_clock(mark.duration)}';
    }
    final parts = <String>[
      if (quality.isNotEmpty)
        quality.toLowerCase() == 'best' ? l10n.best : quality,
      if (record.subtitles.isNotEmpty) _ccLabel(),
      ?watched,
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    final showBar =
        !finished &&
        mark != null &&
        hasDuration &&
        mark.position.inMilliseconds > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          parts.join(' · '),
          style: AppText.caption,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (showBar) ...[
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value:
                  (mark.position.inMilliseconds / mark.duration.inMilliseconds)
                      .clamp(0.0, 1.0),
              minHeight: 2.5,
              color: AppColors.accent,
              backgroundColor: AppColors.surface2,
            ),
          ),
        ],
      ],
    );
  }

  String _ccLabel() {
    final langs = <String>{};
    for (final sub in record.subtitles) {
      final lang = sub.lang.trim();
      if (lang.isEmpty) continue;
      langs.add((lang.length > 3 ? lang.substring(0, 3) : lang).toUpperCase());
    }
    if (langs.isEmpty) return 'CC';
    final shown = langs.take(2).join(' ');
    return 'CC $shown${langs.length > 2 ? ' +${langs.length - 2}' : ''}';
  }
}

/// `m:ss` under an hour, `h:mm:ss` from then on — language-neutral.
String _clock(Duration d) {
  final m = d.inMinutes % 60;
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return d.inHours > 0
      ? '${d.inHours}:${m.toString().padLeft(2, '0')}:$s'
      : '$m:$s';
}

class _StatusGlyph extends StatelessWidget {
  const _StatusGlyph({required this.record});
  final DownloadRecord record;

  @override
  Widget build(BuildContext context) {
    return switch (record.status) {
      DownloadStatus.done => Icon(
        Icons.play_circle_fill_rounded,
        color: AppColors.accent,
        size: 32,
      ),
      DownloadStatus.downloading => SizedBox(
        width: 26,
        height: 26,
        child: CircularProgressIndicator(
          value: record.progress > 0 ? record.progress : null,
          strokeWidth: 2.4,
          color: AppColors.accent,
          backgroundColor: AppColors.surface2,
        ),
      ),
      // Indeterminate on purpose: joining and remuxing report nothing, so a
      // bar frozen at 100% is exactly the lie this state exists to stop.
      DownloadStatus.finalizing => SizedBox(
        width: 26,
        height: 26,
        child: CircularProgressIndicator(
          strokeWidth: 2.4,
          color: AppColors.accent,
        ),
      ),
      DownloadStatus.paused => const Icon(
        Icons.pause_circle_outline_rounded,
        color: AppColors.textSecondary,
        size: 30,
      ),
      DownloadStatus.unsupported => const Icon(
        Icons.cloud_off_outlined,
        color: AppColors.textTertiary,
        size: 26,
      ),
      DownloadStatus.failed => Icon(
        Icons.error_outline_rounded,
        color: AppColors.accent,
        size: 28,
      ),
      DownloadStatus.canceled => const Icon(
        Icons.cancel_outlined,
        color: AppColors.textTertiary,
        size: 26,
      ),
      // queued / resolving — genuinely loading.
      _ => const SizedBox(
        width: 26,
        height: 26,
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.textSecondary,
            ),
          ),
        ),
      ),
    };
  }
}

class _TileMenu extends StatelessWidget {
  const _TileMenu({required this.record, required this.manager});
  final DownloadRecord record;
  final DownloadManager manager;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final r = record;
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert_rounded, color: AppColors.textSecondary),
      color: AppColors.surface2,
      onSelected: (v) {
        switch (v) {
          case 'pause':
            unawaited(manager.pause(r));
          case 'resume':
            unawaited(manager.resume(r));
          case 'retry':
            unawaited(manager.retry(r));
          // Cancel an in-flight download = stop it AND remove it from the list
          // (delete cancels the task, drops the record, and clears fallbacks).
          case 'cancel':
          case 'delete':
            unawaited(manager.delete(r));
        }
      },
      itemBuilder: (context) => [
        if (r.status == DownloadStatus.downloading)
          _item('pause', Icons.pause_rounded, l10n.pause),
        if (r.status == DownloadStatus.paused)
          _item('resume', Icons.play_arrow_rounded, l10n.resume),
        if (r.status == DownloadStatus.failed && !r.isTorrent)
          _item('retry', Icons.refresh_rounded, l10n.retry),
        if (r.isActive) _item('cancel', Icons.close_rounded, l10n.cancel),
        _item('delete', Icons.delete_outline_rounded, l10n.delete),
      ],
    );
  }

  PopupMenuItem<String> _item(String value, IconData icon, String label) =>
      PopupMenuItem<String>(
        value: value,
        child: Row(
          children: [
            Icon(icon, size: 20, color: AppColors.textPrimary),
            const SizedBox(width: 12),
            Text(
              label,
              style: AppText.body.copyWith(color: AppColors.textPrimary),
            ),
          ],
        ),
      );
}
