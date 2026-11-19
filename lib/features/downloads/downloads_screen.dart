import 'package:file_picker/file_picker.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'desktop_download_bulk_delete.dart';
import 'desktop_download_settings_dialog.dart';
import '../../core/download/folder_manifest_scanner.dart';
import 'download_thumbnail.dart';
import 'desktop_download_selection.dart';
import '../../core/download/chapter_downloader.dart';
import 'desktop_download_library.dart';
import '../../core/download/download_failure.dart';
// Rate / time-left text for the live Windows rows (dl-7).
import '../../core/download/download_live_stats.dart'
    show formatTimeLeft, formatTransferRate;
import 'dart:async';
import 'dart:io' show FileSystemEntity;
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
// Windows desktop helpers: right-click menus, Explorer, drag-and-drop,
// shortcuts, free disk space and the queue panel (dl-4, dl-5, dl-9, dl-13,
// dl-14).
import '../../core/desktop/desktop_chrome_colors.dart';
import '../../core/desktop/desktop_context_menu.dart';
import '../../core/desktop/desktop_drop_target.dart';
import '../../core/desktop/desktop_native.dart' show DesktopDropEvent;
import '../../core/desktop/desktop_reveal.dart';
import '../../core/desktop/desktop_shortcuts.dart';
import '../../core/download/windows_download_storage.dart';
import '../../core/models/media_item.dart';
import '../../core/models/provider_info.dart' show ProviderType;
import '../detail/detail_screen.dart' show DetailScreen;
import 'desktop_active_downloads_panel.dart';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../core/cache/app_image_cache.dart';
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

/// One-line, plain-language summary of a folder scan for a toast.
String describeFolderScan(FolderScanResult result) {
  if (result.folders == 0) return 'No Zangetsu download folders found there.';
  final parts = [
    if (result.added > 0)
      '${result.added} added',
    if (result.relinked > 0)
      '${result.relinked} reconnected',
    if (result.skipped > 0)
      '${result.skipped} already in your library',
  ];
  final folders = result.folders == 1 ? '1 folder' : '${result.folders} folders';
  return parts.isEmpty
      ? 'Found $folders, nothing new.'
      : 'Found $folders: ${parts.join(', ')}.';
}

/// Route to one downloaded show's page. Shared by the Downloads library and
/// Home's offline shelf so both open exactly the same screen.
Route<void> desktopDownloadCollectionRoute(
    DesktopDownloadCollection collection) {
  // Windows: a downloaded video show opens the real show page in its
  // downloaded mode (saved episodes, cached details, works offline).
  if (collection.key.kind == 'video' &&
      defaultTargetPlatform == TargetPlatform.windows) {
    return DetailScreen.downloadsRoute(
      downloadedShowItem(collection),
      downloads: liveCollectionRecords(collection.key),
    );
  }
  return MaterialPageRoute<void>(
    builder: (_) => collection.key.kind == 'video'
        ? _DesktopVideoDownloadsPage(collection: collection)
        : ChapterDownloadsScreen(
            mode: collection.key.kind == ContentMode.novel.name
                ? ContentMode.novel
                : ContentMode.manga,
            sourceId: collection.key.sourceId,
            showId: collection.key.showId),
  );
}

/// Reads the current records of the downloaded show [key] from the live
/// download manager, grouped exactly like the library grid (so recovered
/// files attached to the show come along). Regroups only when the library
/// really changed, not on progress ticks.
List<DownloadRecord> Function() liveCollectionRecords(DownloadLibraryKey key) {
  final cache = DesktopDownloadCollectionsCache();
  return () {
    final live = sl<DownloadManager>().all;
    final byId = {for (final r in live) r.id: r};
    final current = cache
        .collections(videos: live, chapters: const [])
        .where((c) => c.key == key)
        .firstOrNull;
    // The cached grouping may hold older copies; hand out the live ones.
    return [
      for (final r in current?.videos ?? const <DownloadRecord>[])
        byId[r.id] ?? r,
    ];
  };
}

/// The title a downloaded show stands for: its provider page (when it has
/// one), artwork and the ids saved with the files. Used both for the
/// downloaded show page and its "Open show page" / "Show online".
MediaItem downloadedShowItem(DesktopDownloadCollection collection) {
  final type = switch (collection.key.kind) {
    'manga' => ProviderType.manga,
    'novel' => ProviderType.novel,
    _ => ProviderType.anime,
  };
  // First record that carries each id (recovered files may carry none).
  T? firstOf<T>(T? Function(DownloadRecord) pick) {
    for (final r in collection.videos) {
      final v = pick(r);
      if (v != null) return v;
    }
    return null;
  }
  return MediaItem(
    id: collection.key.showId,
    title: collection.title,
    cover: collection.cover,
    coverHeaders: collection.coverHeaders,
    url: collection.showUrl ?? '',
    type: type,
    sourceId: collection.key.sourceId,
    malId: firstOf((r) => r.malId),
    anilistId: firstOf((r) => r.anilistId),
    tmdbId: firstOf((r) => r.tmdbId),
    tmdbIsTv: collection.videos.any((r) => r.tmdbIsTv),
    imdbId: firstOf((r) => r.imdbId),
  );
}

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

  /// Windows: when the disk was last reconciled, so focus changes (Alt-Tab)
  /// rescan at most once a minute (dl-13).
  DateTime? _lastRefresh;

  /// The reconcile that is running, shared by focus, F5 and the button.
  Future<void>? _refreshRun;

  /// Free space on the download drive and its name ("D:") for the library's
  /// storage line (dl-9); null until read or when unreadable.
  int? _freeBytes;
  String? _freeDrive;

  /// Finished downloads when free space was last read; a change (a download
  /// finished or was deleted) reads it again.
  int _freeForDone = -1;

  /// A drag from Explorer is over the library (dl-14).
  bool _dropHover = false;

  /// Grouping of the Windows library, redone only when records really
  /// change, not on every progress tick (dl-7).
  final _collectionsCache = DesktopDownloadCollectionsCache();

  /// Minimum gap between focus-triggered rescans on Windows (dl-13).
  static const _focusRefreshGap = Duration(minutes: 1);

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
    if (state != AppLifecycleState.resumed) return;
    // Windows reports "resumed" on every Alt-Tab back to the window, and each
    // rescan probes every saved file (slow on network drives), so rescan at
    // most once a minute there; F5 / Refresh still work any time (dl-13).
    final last = _lastRefresh;
    if (defaultTargetPlatform == TargetPlatform.windows && last != null &&
        DateTime.now().difference(last) < _focusRefreshGap) {
      return;
    }
    _prune();
  }

  /// Drop downloads whose file was deleted outside the app. Non-blocking.
  void _prune() => unawaited(_refreshLocalFiles());

  /// Updates may retain media while an older download index is absent. Recover
  /// known app-owned local files before reconciling the displayed library.
  /// Calls made while one is running join it instead of scanning twice.
  Future<void> _refreshLocalFiles() {
    final running = _refreshRun;
    if (running != null) return running;
    _lastRefresh = DateTime.now();
    Future<void> run() async {
      try {
        final manager = sl<DownloadManager>();
        await manager.recoverLocalFiles();
        await manager.pruneMissing();
      } finally {
        _refreshRun = null;
        if (mounted) setState(() {});
      }
      // Files may have appeared or gone; the free space follows.
      if (defaultTargetPlatform == TargetPlatform.windows) {
        unawaited(_loadFreeSpace());
      }
    }
    final future = run();
    _refreshRun = future;
    return future;
  }

  /// Refresh button and F5 (dl-13): rescans now, whatever the focus timer
  /// says, with a spinner on the button while it runs.
  Future<void> _manualRefresh() async {
    if (_refreshRun != null) return;
    final future = _refreshLocalFiles();
    setState(() {});
    await future;
  }

  /// F5 / Ctrl+R (the remappable "downloads.refresh" action). Falls back to
  /// F5 when the shortcut catalogue was not registered (tests).
  Map<ShortcutActivator, VoidCallback> _refreshBindings() {
    void refresh() => unawaited(_manualRefresh());
    final bound = DesktopShortcuts.bindings({'downloads.refresh': refresh});
    return bound.isNotEmpty
        ? bound
        : {const SingleActivator(LogicalKeyboardKey.f5): refresh};
  }

  /// Reads the free space of the drive downloads are saved to (dl-9).
  Future<void> _loadFreeSpace() async {
    final location = sl<DownloadPrefs>().locationUri;
    final free = await windowsDownloadFreeBytes(location);
    if (!mounted) return;
    // "D:" for a drive letter, "\\server" for a network share.
    final drive = location == null ? null
        : RegExp(r'^([A-Za-z]:)').firstMatch(location)?.group(1) ??
          RegExp(r'^(\\\\[^\\]+)').firstMatch(location)?.group(1);
    setState(() {
      _freeBytes = free;
      _freeDrive = drive?.toUpperCase();
    });
  }

  /// Reads free space again once the number of finished downloads changed.
  void _maybeReloadFreeSpace(int doneCount) {
    if (doneCount == _freeForDone) return;
    _freeForDone = doneCount;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_loadFreeSpace());
    });
  }

  /// Folders dropped from Explorer (dl-14): each one is scanned for Zangetsu
  /// show folders like "Scan a folder" does, then one summary is shown.
  Future<void> _onDrop(DesktopDropEvent event) async {
    final folders = <String>[];
    for (final path in event.paths) {
      if (await FileSystemEntity.isDirectory(path)) folders.add(path);
    }
    if (!mounted) return;
    if (folders.isEmpty) {
      showAppToast(context, context.l10n.dropFolderToImport);
      return;
    }
    showAppToast(context, folders.length == 1
        ? context.l10n.scanningEllipsis
        : context.l10n.scanningNFolders(folders.length));
    final manager = sl<DownloadManager>();
    var total = const FolderScanResult();
    for (final folder in folders) {
      final r = await manager.scanFolderForDownloads(folder);
      total = FolderScanResult(
        folders: total.folders + r.folders,
        added: total.added + r.added,
        relinked: total.relinked + r.relinked,
        skipped: total.skipped + r.skipped,
      );
    }
    if (!mounted) return;
    showAppToast(context, describeFolderScan(total));
  }

  /// "Show in Explorer" for a whole show (dl-4).
  Future<void> _revealCollection(DesktopDownloadCollection collection) async {
    final folder = collection.folder;
    final shown = folder != null && await revealInExplorer(folder);
    if (!shown && mounted) {
      showAppToast(context, context.l10n.folderNoLongerOnDisk);
    }
  }

  /// Finished episodes of [collection] not yet watched to the end, for the
  /// "Most unwatched" sort (dl-9). One count per episode, not per file.
  int _unwatchedCount(DesktopDownloadCollection collection) {
    if (!sl.isRegistered<ResumeStore>()) return 0;
    final resume = sl<ResumeStore>();
    final unwatched = <String>{};
    for (final r in collection.videos) {
      if (r.status != DownloadStatus.done) continue;
      final mark = resume.get(r.sourceId, r.showUrl, r.episodeId);
      if (!(mark?.finished ?? false)) {
        unwatched.add('${r.season ?? 0}:${r.episodeNumber ?? r.episodeId}');
      }
    }
    return unwatched.length;
  }

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

  /// A Lucide icon from the bundled set, tinted like a secondary icon.
  Widget _lucide(String name, {double size = 20}) => SvgPicture.asset(
    'assets/icons/lucide/$name.svg', width: size, height: size,
    colorFilter: const ColorFilter.mode(AppColors.textSecondary, BlendMode.srcIn));

  /// Windows: the save location as one compact pill (folder icon, shortened
  /// path, Change) that lives in the library toolbar instead of its own row.
  Widget _locationPill() {
    final l10n = context.l10n;
    final prefs = sl<DownloadPrefs>();
    final label = downloadDestinationLabel(
      keepPrivate: prefs.keepPrivate,
      locationLabel: prefs.locationLabel,
      // Windows has no shared "Downloads › Zangetsu" fallback: without a
      // folder the first download asks for one, so say exactly that.
      publicFallback: defaultTargetPlatform == TargetPlatform.windows
          ? 'Choose a folder before your first download'
          : l10n.downloadsZangetsu,
    );
    return Tooltip(
      message: '${l10n.savingTo} $label',
      child: InkWell(
        key: const ValueKey('downloads-location-pill'),
        borderRadius: BorderRadius.circular(24),
        onTap: () async {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const DownloadLocationScreen()),
          );
          if (mounted) setState(() {});
          // A new folder may sit on another drive: re-read its free space.
          if (mounted) unawaited(_loadFreeSpace());
        },
        child: Container(
          constraints: const BoxConstraints(maxWidth: 300),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: AppColors.textSecondary.withValues(alpha: .25)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            _lucide('folder', size: 16),
            const SizedBox(width: 8),
            // Start of the path is the least useful part, so ellipsize the start.
            Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: AppText.caption.copyWith(color: AppColors.textSecondary))),
            const SizedBox(width: 8),
            Text(l10n.change, style: AppText.caption.copyWith(
              color: AppColors.accent, fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
    );
  }

  /// Lets the user pick a folder (a downloads folder, a drive, or one show) and
  /// brings any Zangetsu show folders found inside it into the library. Moved
  /// folders are re-linked; nothing is moved, renamed or deleted.
  Future<void> _scanFolder() async {
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: 'Choose a folder to scan for Zangetsu downloads',
    );
    if (path == null || !mounted) return;
    showAppToast(context, 'Scanning…');
    final result = await sl<DownloadManager>().scanFolderForDownloads(path);
    if (!mounted) return;
    showAppToast(context, describeFolderScan(result));
  }

  /// Bottom sheet with the CloudStream-style download concurrency sliders.
  /// Applies to the NEXT downloads started (running HLS jobs aren't retimed).
  void _openDownloadSettings() {
    if (defaultTargetPlatform == TargetPlatform.windows) {
      unawaited(_openDesktopDownloadSettings());
      return;
    }
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

  /// Windows: the same two download settings as a centered graphite dialog
  /// (no phone bottom sheet or drag handle). Values save when a slider is
  /// released, by mouse or keyboard, and once more when the dialog closes,
  /// so nothing set here is ever lost.
  Future<void> _openDesktopDownloadSettings() async {
    final prefs = sl<DownloadPrefs>();
    var parallel = prefs.parallelDownloads;
    var connections = prefs.connectionsPerDownload;
    // Parallel applies live: the manager raises/lowers its running slots.
    void commitParallel(int n) {
      if (n == prefs.parallelDownloads) return;
      unawaited(prefs.setParallelDownloads(n));
      sl<DownloadManager>().setParallel(n);
    }

    // Connections are read when each download starts.
    void commitConnections(int n) {
      if (n == prefs.connectionsPerDownload) return;
      unawaited(prefs.setConnectionsPerDownload(n));
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, update) => DesktopDownloadSettingsDialog(
          parallel: parallel,
          connections: connections,
          onParallelChanged: (n) => update(() => parallel = n),
          onParallelCommit: commitParallel,
          onConnectionsChanged: (n) => update(() => connections = n),
          onConnectionsCommit: commitConnections,
        ),
      ),
    );
    commitParallel(parallel);
    commitConnections(connections);
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
      // Windows keeps its app bar and desktop library; phones get upstream's
      // in-body header (SafeArea + _header) instead of an app bar.
      appBar: defaultTargetPlatform != TargetPlatform.windows
          ? null
          : settingsAppBar(
            showBack: widget.showBack,
            context.l10n.downloads,
            actions: [
              // Windows only: bring in show folders that carry a Zangetsu manifest,
              // for example ones moved to another drive.
              if (defaultTargetPlatform == TargetPlatform.windows)
                IconButton(
                  key: const ValueKey('downloads-scan-folder'),
                  tooltip: 'Scan a folder for downloads',
                  icon: _lucide('folder-search'),
                  onPressed: _scanFolder,
                ),
              // Windows: rescan the disk now (also F5); focus changes only
              // rescan once a minute (dl-13).
              if (defaultTargetPlatform == TargetPlatform.windows)
                IconButton(
                  key: const ValueKey('downloads-refresh'),
                  tooltip: '${context.l10n.refresh} (F5)',
                  icon: _refreshRun != null
                      ? const SizedBox.square(dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : _lucide('rotate-cw'),
                  onPressed: _refreshRun != null ? null : _manualRefresh,
                ),
              IconButton(
                tooltip: context.l10n.downloadSettings,
                // Lucide sliders on Windows; the Material icon stays on other platforms.
                icon: defaultTargetPlatform == TargetPlatform.windows
                    ? _lucide('sliders-horizontal')
                    : const Icon(Icons.tune_rounded),
                onPressed: _openDownloadSettings,
              ),
            ],
            ),
      body: defaultTargetPlatform == TargetPlatform.windows
          ? CallbackShortcuts(
              // F5 rescans the disk (dl-13); keys reach it from the library,
              // which keeps keyboard focus.
              bindings: _refreshBindings(),
              child: DesktopDropTarget(
              // Folders dragged in from Explorer are imported (dl-14).
              onDrop: (event) => unawaited(_onDrop(event)),
              onHoverChanged: (over) => setState(() => _dropHover = over),
              child: Stack(children: [
              Positioned.fill(child: Column(children: [
              Expanded(child: ListenableBuilder(
                listenable: Listenable.merge([manager, store.listenable(), sl<ChapterDownloader>()]),
                builder: (context, _) {
                  // Live chapter records override persisted interrupted states.
                  final chapters = {for (final c in store.all()) c.id: c,
                    ...sl<ChapterDownloader>().inFlight};
                  final videos = manager.all;
                  _maybeReloadFreeSpace(videos
                      .where((r) => r.status == DownloadStatus.done).length);
                  return DesktopDownloadLibrary(
                    trailing: _locationPill(),
                    // Running / waiting / failed downloads across all shows,
                    // with speed, time left and bulk actions (dl-5).
                    header: DesktopActiveDownloadsPanel(manager: manager),
                    // Regrouped only when records change, not on progress
                    // ticks (dl-7).
                    collections: _collectionsCache.collections(videos: videos,
                      chapters: chapters.values.toList()),
                    freeBytes: _freeBytes,
                    freeDrive: _freeDrive,
                    unwatchedCount: _unwatchedCount,
                    onRevealCollection: (c) => unawaited(_revealCollection(c)),
                    onOpenShowPage: (c) => openDownloadedShowPage(context, c),
                    onOpen: (collection) => Navigator.of(context)
                        .push(desktopDownloadCollectionRoute(collection)),
                    // Select several shows and delete them together. Videos go
                    // through the manager (which cancels active transfers);
                    // chapters are cancelled first when still running.
                    onDeleteCollections: (collections) async {
                      final plan = planBulkDelete(collections);
                      final downloader = sl<ChapterDownloader>();
                      final failed = await executeBulkDelete(plan,
                        deleteVideos: manager.deleteAll,
                        deleteChapter: (c) async {
                          if (downloader.isBusy(c.id)) await downloader.cancel(c.id);
                          await store.remove(c.id);
                        });
                      if (failed > 0 && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text('$failed downloads could not be removed.')));
                      }
                    },
                  );
                },
              )),
            ])),
              // Drop hint while a drag from Explorer hovers the library.
              if (_dropHover) Positioned.fill(child: IgnorePointer(
                child: _DropHint(key: const ValueKey('downloads-drop-hint')))),
            ])))
          : ListenableBuilder(
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

/// Dashed accent frame shown while folders are dragged over the library
/// (dl-14), so the user knows a drop imports them.
class _DropHint extends StatelessWidget {
  const _DropHint({super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(12),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: DesktopChrome.selectedFill(AppColors.accent, strength: .10),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.accent, width: 2),
      ),
      child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.drive_folder_upload_outlined, size: 40,
          color: AppColors.textPrimary),
        const SizedBox(height: 10),
        Text(context.l10n.dropFoldersToImport,
          style: AppText.headline.copyWith(fontSize: 15)),
        const SizedBox(height: 4),
        Text(context.l10n.showFoldersAddedOrReconnected,
          style: AppText.caption),
      ])),
    ),
  );
}

/// Opens the provider page of a downloaded show (dl-4 menu, dl-8 header).
/// Does nothing for files recovered from disk, which have no page.
void openDownloadedShowPage(BuildContext context,
    DesktopDownloadCollection collection) {
  if (collection.showUrl == null) return;
  unawaited(Navigator.of(context).push(
      DetailScreen.route(downloadedShowItem(collection))));
}

/// Where "Continue" should start in a downloaded show (dl-8): the first
/// finished episode, in season/episode order, that is not watched to the
/// end. Null when every saved episode has been watched (or none is saved).
/// [started] tells whether that episode, or any before it, was watched,
/// so the button can say "Continue" instead of "Play".
({DownloadRecord record, bool started})? downloadedContinueTarget(
  List<DownloadRecord> records,
  ResumeMark? Function(DownloadRecord) markOf,
) {
  final done = records.where((r) => r.status == DownloadStatus.done).toList()
    ..sort((a, b) {
      final season = (a.season ?? 0).compareTo(b.season ?? 0);
      return season != 0
          ? season
          : (a.episodeNumber ?? 0).compareTo(b.episodeNumber ?? 0);
    });
  var started = false;
  for (final r in done) {
    final mark = markOf(r);
    if (mark?.finished ?? false) {
      started = true;
      continue;
    }
    return (record: r, started: started || (mark?.position ?? Duration.zero) > Duration.zero);
  }
  return null;
}

/// Title-focused Windows workspace; existing row handlers retain offline
/// playback, retry, audio-finalization and cancel/delete ownership semantics.
class _DesktopVideoDownloadsPage extends StatefulWidget {
  const _DesktopVideoDownloadsPage({required this.collection});
  final DesktopDownloadCollection collection;

  @override
  State<_DesktopVideoDownloadsPage> createState() =>
      _DesktopVideoDownloadsPageState();
}

class _DesktopVideoDownloadsPageState extends State<_DesktopVideoDownloadsPage> {
  /// Regroups only when records change, not on progress ticks (dl-7).
  final _cache = DesktopDownloadCollectionsCache();

  /// Set once the page decided to go back after its last episode went.
  bool _leaving = false;

  /// Back to the grid once nothing is left, like the phone page (dl-8).
  void _leaveWhenEmpty() {
    if (_leaving) return;
    _leaving = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        Navigator.of(context).pop();
      }
    });
  }

  /// Cover, "X of Y downloaded - size", delete-all, plus Continue and Open
  /// show page (dl-8).
  Widget _header(BuildContext context, DesktopDownloadCollection current,
      List<DownloadRecord> records, DownloadManager manager) {
    final l10n = context.l10n;
    final resume = sl.isRegistered<ResumeStore>() ? sl<ResumeStore>() : null;
    final target = downloadedContinueTarget(records, (r) =>
        resume?.get(r.sourceId, r.showUrl, r.episodeId));
    final number = target?.record.episodeNumber?.toInt();
    final label = target == null ? null
        : target.started
            ? (number != null ? l10n.continueEpisode(number) : l10n.resume)
            : (number != null ? l10n.playEpisodeShort(number) : l10n.play);
    return DownloadTitleSummary(
      title: current.title,
      heroTag: ('download-video-desktop', current.key),
      cover: current.cover,
      coverHeaders: current.coverHeaders,
      subtitle: '${l10n.ofTotalDownloaded(current.saved, current.total)} · '
          '${fmtDownloadSize(current.bytes)}',
      deleteTooltip: l10n.deleteAllEpisodesTooltip,
      onDelete: () => _confirmDeleteShow(context, records, manager),
      actions: [
        if (target != null && label != null)
          FilledButton.icon(
            key: const ValueKey('downloads-continue'),
            onPressed: () => unawaited(
                playDownloadedRecord(context, target.record, manager)),
            icon: const Icon(Icons.play_arrow_rounded, size: 18),
            label: Text(label),
          ),
        if (current.showUrl != null)
          OutlinedButton.icon(
            key: const ValueKey('downloads-open-show'),
            onPressed: () => openDownloadedShowPage(context, current),
            icon: const Icon(Icons.info_outline_rounded, size: 18),
            label: Text(context.l10n.openShowPage),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final manager = sl<DownloadManager>();
    final collection = widget.collection;
    return Scaffold(backgroundColor: AppColors.bg,
      appBar: settingsAppBar(collection.title),
      body: ListenableBuilder(listenable: manager, builder: (context, _) {
        final live = manager.all;
        final byId = {for (final r in live) r.id: r};
        // Recompute presentation membership so recovered siblings and newly
        // queued episodes stay together without changing their original IDs.
        final current = _cache.collections(videos: live, chapters: const [])
            .where((c) => c.key == collection.key).firstOrNull;
        // The cached grouping may hold older copies; rows show the live ones.
        final records = [for (final r in current?.videos ?? const <DownloadRecord>[])
            byId[r.id] ?? r]..sort((a,b) {
          final season = (a.season ?? 0).compareTo(b.season ?? 0);
          return season != 0 ? season : (a.episodeNumber ?? 0).compareTo(b.episodeNumber ?? 0);
        });
        if (records.isEmpty || current == null) _leaveWhenEmpty();
        return DesktopDownloadSelection(records: records,
          header: current == null || records.isEmpty ? null
              : _header(context, current, records, manager),
          onDelete: (selected) async {
            await manager.deleteAll(selected);
            final remaining = {for (final r in manager.all) r.id: r.storageKey};
            if (selected.any((r) => remaining.containsKey(r.id) &&
                remaining[r.id] == r.storageKey)) {
              throw StateError('Some selected downloads could not be removed');
            }
          },
          rowBuilder: (record) => DownloadTile(record: record,
            manager: manager, resume: sl<ResumeStore>()));
      }));
  }
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

class _DownloadedShowScreen extends StatefulWidget {
  const _DownloadedShowScreen({required this.showId, required this.query});
  final String showId;
  final String query;

  @override
  State<_DownloadedShowScreen> createState() => _DownloadedShowScreenState();
}

class _DownloadedShowScreenState extends State<_DownloadedShowScreen> {
  final Set<String> _selected = {};
  bool _selecting = false;
  bool _busy = false;

  void _clearSelection() {
    if (_busy) return;
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  void _toggleSelection(String id) {
    if (_busy) return;
    setState(() {
      _selecting = true;
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  Future<void> _deleteSelected(List<DownloadRecord> selected, int total) async {
    if (_busy || selected.isEmpty) return;
    final l10n = context.l10n;
    try {
      final confirmed = await AppDialog.confirm(
        context,
        title: l10n.delete,
        message:
            '${l10n.selectedEpisodesOfTotal(selected.length, total)}\n${selected.first.showTitle}',
        confirmLabel: l10n.delete,
        destructive: true,
      );
      if (!confirmed || !mounted || _busy) return;
      setState(() => _busy = true);
      final manager = sl<DownloadManager>();
      final ids = selected.map((r) => r.id).toSet();
      // Refresh records after the dialog: active downloads may have finished.
      await manager.deleteAll(
        manager.all.where((r) => ids.contains(r.id)).toList(),
      );
      if (mounted) {
        setState(() {
          _selected.clear();
          _selecting = false;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final manager = sl<DownloadManager>();
    final l10n = context.l10n;
    return ListenableBuilder(
      listenable: manager,
      builder: (context, _) {
        final records = [...?manager.byShow[widget.showId]]
          ..sort(
            (a, b) => (a.episodeNumber ?? 0).compareTo(b.episodeNumber ?? 0),
          );
        final q = widget.query.trim().toLowerCase();
        final episodes = records.isEmpty
            ? <DownloadRecord>[]
            : q.isEmpty || records.first.showTitle.toLowerCase().contains(q)
            ? records
            : records.where((r) => _episodeSearchText(r).contains(q)).toList();
        if (episodes.isEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted && ModalRoute.of(context)?.isCurrent == true) {
              Navigator.of(context).pop();
            }
          });
          return const SizedBox.shrink();
        }
        final head = records.first;
        final chosen = episodes.where((r) => _selected.contains(r.id)).toList();
        final allSelected = chosen.length == episodes.length;
        final done = records.where((r) => r.status == DownloadStatus.done);
        final bytes = done.fold<int>(0, (sum, r) => sum + r.bytesTotal);
        return PopScope<Object?>(
          canPop: !_selecting && !_busy,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _clearSelection();
          },
          child: Scaffold(
            backgroundColor: AppColors.bg,
            appBar: AppBar(
              backgroundColor: AppColors.bg,
              surfaceTintColor: Colors.transparent,
              title: Text(
                _selecting
                    ? l10n.selectedEpisodesOfTotal(
                        chosen.length,
                        episodes.length,
                      )
                    : l10n.downloads,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.headline,
              ),
              leading: IconButton(
                key: const ValueKey('downloads-back-to-grid'),
                tooltip: _selecting
                    ? l10n.cancel
                    : MaterialLocalizations.of(context).backButtonTooltip,
                icon: Icon(
                  _selecting ? Icons.close_rounded : Icons.arrow_back_rounded,
                ),
                onPressed: _busy
                    ? null
                    : _selecting
                    ? _clearSelection
                    : () => Navigator.of(context).pop(),
              ),
              actions: [
                if (_selecting) ...[
                  IconButton(
                    tooltip: allSelected ? l10n.clear : l10n.selectAll,
                    icon: Icon(
                      allSelected
                          ? Icons.deselect_rounded
                          : Icons.select_all_rounded,
                    ),
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            if (allSelected) {
                              _selected.clear();
                            } else {
                              _selected.addAll(episodes.map((r) => r.id));
                            }
                          }),
                  ),
                  IconButton(
                    tooltip: l10n.delete,
                    icon: _busy
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.delete_outline_rounded),
                    onPressed: _busy || chosen.isEmpty
                        ? null
                        : () => _deleteSelected(chosen, episodes.length),
                  ),
                ] else
                  IconButton(
                    tooltip: l10n.selectEpisodes,
                    icon: const Icon(Icons.checklist_rounded),
                    onPressed: () => setState(() => _selecting = true),
                  ),
              ],
            ),
            body: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: DownloadTitleSummary(
                    title: head.showTitle,
                    heroTag: ('download-video', widget.showId),
                    cover: head.cover,
                    coverHeaders: head.coverHeaders,
                    subtitle:
                        '${l10n.ofTotalDownloaded(done.length, records.length)} · ${fmtDownloadSize(bytes)}',
                    deleteTooltip: l10n.deleteAllEpisodesTooltip,
                    onDelete: _selecting || _busy
                        ? null
                        : () => _confirmDeleteShow(context, records, manager),
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
                SliverList.builder(
                  itemCount: episodes.length,
                  itemBuilder: (context, index) {
                    final record = episodes[index];
                    return DownloadTile(
                      record: record,
                      manager: manager,
                      resume: sl<ResumeStore>(),
                      compact: true,
                      selected: _selected.contains(record.id),
                      onSelect: _selecting
                          ? () => _toggleSelection(record.id)
                          : null,
                      onLongPress: () => _toggleSelection(record.id),
                    );
                  },
                ),
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: MediaQuery.paddingOf(context).bottom + 24,
                  ),
                ),
              ],
            ),
          ),
        );
      },
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
  // Continue watching passes its saved spot as a fallback resume position.
  Duration resumePosition = Duration.zero,
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
        category: record.category,
        season: episode.season,
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
        downloadShowId: record.showId,
        category: record.category,
        malId: record.malId,
        // The ids saved with the download let subtitle search find this exact
        // show instead of guessing from the title.
        tmdbId: record.tmdbId,
        tmdbIsTv: record.tmdbIsTv,
        imdbId: record.imdbId,
        scrobbleTitle: scrobbleTitle,
        playerOverride: playerOverride,
        resumePosition: resumePosition,
      ),
    ),
  );
}

/// Plays a finished download with its downloaded siblings queued after it.
/// Shared by the row, its right-click menu and the show page's Continue
/// button (dl-8).
Future<void> playDownloadedRecord(
  BuildContext context,
  DownloadRecord record,
  DownloadManager manager,
) async {
  // The whole downloaded season, not just this row — otherwise Next has
  // nowhere to go and the user is bounced back out to pick manually.
  final queue = await downloadedSiblingQueue(
    showRecords: manager.byShow[record.showId] ?? const [],
    record: record,
    filePresent: manager.filePresent,
    // Windows keeps Next inside the tapped season (desktop behaviour).
    sameSeason: defaultTargetPlatform == TargetPlatform.windows,
  );
  if (!context.mounted) return;
  await launchDownloadedEpisode(
    context,
    record,
    episodes: queue.episodes,
    startIndex: queue.startIndex,
  );
}

class DownloadTile extends StatelessWidget {
  const DownloadTile({
    super.key,
    required this.record,
    required this.manager,
    this.resume,
    this.compact = false,
    this.selected = false,
    this.onSelect,
    this.onLongPress,
  });
  final bool compact;
  final bool selected;
  final VoidCallback? onSelect;
  final VoidCallback? onLongPress;
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

  /// [progress] overrides the record's saved value with the live one the
  /// Windows row listens to (dl-7).
  String _subtitle(AppLocalizations l10n, [double? progress]) {
    // A finished torrent is streamed into the user's folder — surface that phase.
    if (record.isTorrent &&
        manager.torrentProgress[record.id]?.status == 'copying') {
      return l10n.savingToYourFolder;
    }
    if (defaultTargetPlatform == TargetPlatform.windows &&
        record.status == DownloadStatus.queued && record.retryAt != null) {
      return record.error ?? 'Waiting for source cooldown; retrying automatically.';
    }
    final pct = ((progress ?? record.progress) * 100).round();
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
      DownloadStatus.failed => downloadFailureMessage(
        record.error, fallback: l10n.downloadFailedStatus),
      DownloadStatus.canceled => l10n.downloadCanceled,
    };
  }

  /// " · 2.1 MB/s · 3 min left" for a downloading Windows row (dl-7). Empty
  /// for torrents (their suffix already has the rate) or when unknown.
  String _liveStatsSuffix() {
    if (record.isTorrent || record.status != DownloadStatus.downloading) {
      return '';
    }
    final speed = manager.speedOf(record.id);
    final left = manager.timeLeftOf(record.id);
    return [
      if (speed != null && speed > 0) ' · ${formatTransferRate(speed)}',
      if (left != null) ' · ${formatTimeLeft(left)}',
    ].join();
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

  Future<void> _play(BuildContext context) =>
      playDownloadedRecord(context, record, manager);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final isDone = record.status == DownloadStatus.done;
    // Windows keeps its compact desktop row (artwork + status glyph) inside
    // DesktopDownloadSelection; phone uses upstream's card tile below.
    if (defaultTargetPlatform == TargetPlatform.windows) {
      return _desktopRow(context, l10n, isDone);
    }
    final active =
        record.status == DownloadStatus.downloading ||
        record.status == DownloadStatus.paused;
    final selecting = onSelect != null;
    final thumb = (record.episodeThumbnail?.trim().isNotEmpty ?? false)
        ? record.episodeThumbnail!
        : record.cover;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onSelect ?? (isDone ? () => _play(context) : null),
        onLongPress: onLongPress,
        splashColor: AppColors.accentSoft,
        highlightColor: AppColors.surface,
        child: Container(
          decoration: BoxDecoration(
            color: selected && selecting
                ? AppColors.accentSoft
                : AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected && selecting
                  ? AppColors.accent
                  : AppColors.hairline,
            ),
          ),
          padding: const EdgeInsets.fromLTRB(10, 10, 6, 10),
          child: Row(
            children: [
              _TileThumb(
                url: thumb,
                headers: record.coverHeaders,
                record: record,
                resume: resume,
                width: compact ? 64 : 68,
                selecting: selecting,
                selected: selected,
                onSelect: onSelect,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      _epLabel(l10n),
                      style: AppText.body.copyWith(
                        color: AppColors.textPrimary,
                        fontSize: compact ? 13 : 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _subtitle(l10n),
                      style: AppText.caption.copyWith(
                        color: isDone
                            ? AppColors.textSecondary
                            : AppColors.accent,
                        fontWeight: isDone ? null : FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (isDone) ...[
                      const SizedBox(height: 4),
                      _WatchMeta(record: record, resume: resume),
                    ],
                    if (active) ...[
                      const SizedBox(height: 8),
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
              ),
              if (selecting)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Icon(
                    selected
                        ? Icons.check_circle_rounded
                        : Icons.circle_outlined,
                    color: selected ? AppColors.accent : AppColors.textTertiary,
                    size: 22,
                  ),
                )
              else
                _TileMenu(record: record, manager: manager),
            ],
          ),
        ),
      ),
    );
  }

  /// Right-click / Menu key rows for one episode (dl-4): Play, Show in
  /// Explorer, the same transfer actions as the three-dot menu, Delete.
  List<DesktopMenuItem<Object?>> _rowMenu(BuildContext context,
      AppLocalizations l10n, bool isDone) {
    final path = record.filePath;
    final onDisk = path != null && path.isNotEmpty && !isUriPath(path);
    final actions = _tileActions(record, l10n, manager);
    final transfer = actions.where((a) => a.value != 'delete' && a.value != 'cancel');
    return [
      if (isDone)
        DesktopMenuItem(label: l10n.play, icon: Icons.play_arrow_rounded,
          shortcut: 'Enter', onTap: () => unawaited(_play(context))),
      DesktopMenuItem(label: l10n.showInExplorer,
        icon: Icons.folder_open_rounded, enabled: onDisk,
        onTap: () async {
          if (!await revealInExplorer(path!) && context.mounted) {
            showAppToast(context, l10n.downloadFileGone);
          }
        }),
      if (transfer.isNotEmpty) const DesktopMenuItem.divider(),
      for (final a in transfer)
        DesktopMenuItem(label: a.label, icon: a.icon,
          onTap: () => _runTileAction(a.value, record, manager)),
      const DesktopMenuItem.divider(),
      DesktopMenuItem(label: l10n.delete, icon: Icons.delete_outline_rounded,
        destructive: true,
        onTap: () => _runTileAction('delete', record, manager)),
    ];
  }

  /// Live progress for a moving row (dl-7): only this row repaints on each
  /// tick, the page itself rebuilds about once a second at most.
  Widget _liveProgress({required Widget Function(double progress) builder}) {
    final moving = record.status == DownloadStatus.downloading ||
        record.status == DownloadStatus.paused;
    if (!moving) return builder(record.progress);
    return ValueListenableBuilder<double>(
      valueListenable: manager.progressListenable(record.id),
      builder: (context, progress, _) => builder(progress),
    );
  }

  /// Windows row: the desktop ListTile, now selection-aware (dl-1, dl-3)
  /// with a right-click menu (dl-4) and live progress (dl-7).
  Widget _desktopRow(BuildContext context, AppLocalizations l10n, bool isDone) {
    final scope = DesktopDownloadRowScope.maybeOf(context);
    final selected = scope?.selected ?? false;
    return DesktopContextMenuRegion(
      // While selecting, the right-click menu would compete with ticking.
      enabled: !(scope?.selecting ?? false),
      items: () => _rowMenu(context, l10n, isDone),
      child: ListTile(
      contentPadding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
      tileColor: selected ? DesktopChrome.selectedFill(AppColors.accent) : null,
      // Inside a selectable list the click goes through the selection first:
      // while selecting (or with Ctrl/Shift) it ticks the row instead of
      // starting playback (dl-1). Elsewhere only finished rows react.
      onTap: scope != null
          ? () {
              if (scope.onClick()) return;
              if (isDone) unawaited(_play(context));
            }
          : isDone ? () => _play(context) : null,
      leading: SizedBox(width: 80, height: 48, child: Stack(fit: StackFit.expand, children: [
        DownloadThumbnail(thumbnail: record.episodeThumbnail, cover: record.cover,
          headers: record.coverHeaders, fallback: ColoredBox(color: AppColors.surface2)),
        Positioned(right: 2, bottom: 2, child: _StatusGlyph(record: record)),
      ])),
      title: Text(
        _epLabel(l10n),
        style: AppText.body.copyWith(color: AppColors.textPrimary),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (record.recoveredFromDisk)
            Text('Recovered from disk', style: AppText.caption),
          _liveProgress(builder: (progress) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Speed and time left ride along with the live progress, so
              // they refresh on the same per-row tick (dl-7).
              Text(_subtitle(l10n, progress) + _liveStatsSuffix(),
                  style: AppText.caption),
              if (record.status == DownloadStatus.downloading ||
                  record.status == DownloadStatus.paused) ...[
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: progress > 0 ? progress : null,
                    minHeight: 3,
                    color: AppColors.accent,
                    backgroundColor: AppColors.surface2,
                  ),
                ),
              ],
            ],
          )),
          if (isDone) ...[
            const SizedBox(height: 3),
            _WatchMeta(record: record, resume: resume),
          ],
        ],
      ),
      trailing: _TileMenu(record: record, manager: manager),
    ));
  }
}

/// Square episode still with quality and progress pills plus a status veil.
/// Falls back to the show cover for records saved before stills were
/// captured; dims when selected.
class _TileThumb extends StatelessWidget {
  const _TileThumb({
    required this.url,
    required this.headers,
    required this.record,
    required this.resume,
    required this.width,
    required this.selecting,
    required this.selected,
    required this.onSelect,
  });

  final String? url;
  final Map<String, String>? headers;
  final DownloadRecord record;
  final ResumeStore? resume;
  final double width;
  final bool selecting;
  final bool selected;
  final VoidCallback? onSelect;

  @override
  Widget build(BuildContext context) {
    final done = record.status == DownloadStatus.done;
    final active =
        record.status == DownloadStatus.downloading ||
        record.status == DownloadStatus.paused;
    final pct = (record.progress * 100).round();
    return SizedBox(
      width: width,
      height: width,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: ColoredBox(
          color: AppColors.surface2,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (url != null && url!.isNotEmpty)
                CachedNetworkImage(
                  imageUrl: url!,
                  cacheManager: AppImageCache.cacheManagerOrDefault,
                  httpHeaders: headers,
                  fit: BoxFit.cover,
                  memCacheWidth: 260,
                  placeholder: (c, u) => ColoredBox(color: AppColors.surface2),
                  errorWidget: (c, u, e) =>
                      ColoredBox(color: AppColors.surface2),
                ),
              if (selected)
                const DecoratedBox(
                  decoration: BoxDecoration(color: Color(0x8C000000)),
                ),
              if (!done && !selecting) Center(child: _veil(active, pct)),
              if (done && !selecting)
                _ThumbWatchBadge(record: record, resume: resume),
              if (done && !selecting)
                _ThumbDuration(record: record, resume: resume),
              if (active && pct > 0 && !selecting)
                Align(
                  alignment: Alignment.bottomRight,
                  child: Padding(
                    padding: const EdgeInsets.all(5),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0xD2000000),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 2,
                        ),
                        child: Text(
                          '$pct%',
                          style: const TextStyle(
                            fontSize: 9.5,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (selecting)
                Center(
                  child: Checkbox(
                    value: selected,
                    activeColor: AppColors.accent,
                    checkColor: Colors.white,
                    side: const BorderSide(color: Colors.white, width: 2),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onChanged: (_) => onSelect?.call(),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Center badge while the row still carries state: % ring for active
  /// downloads, the status glyph for everything else. Finished episodes show
  /// nothing here — the watch badge owns that corner.
  Widget _veil(bool active, int pct) {
    if (active && pct > 0) {
      return DecoratedBox(
        decoration: const BoxDecoration(
          color: Color(0x99000000),
          shape: BoxShape.circle,
        ),
        child: Padding(
          padding: const EdgeInsets.all(7),
          child: Text(
            '$pct%',
            style: const TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
        ),
      );
    }
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Color(0x99000000),
        shape: BoxShape.circle,
      ),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: SizedBox(
          width: 14,
          height: 14,
          child: FittedBox(
            fit: BoxFit.contain,
            child: _StatusGlyph(record: record),
          ),
        ),
      ),
    );
  }
}

/// Watch state on a finished thumbnail: red check when done, white play ring
/// when resumed mid-episode. Reads the same resume box [_WatchMeta] does.
class _ThumbWatchBadge extends StatelessWidget {
  const _ThumbWatchBadge({required this.record, required this.resume});

  final DownloadRecord record;
  final ResumeStore? resume;

  @override
  Widget build(BuildContext context) {
    final resume = this.resume;
    if (resume == null) return const SizedBox.shrink();
    return ValueListenableBuilder<Box<Map>>(
      valueListenable: Hive.box<Map>(ResumeStore.boxName).listenable(),
      builder: (context, _, __) {
        final mark = resume.get(
          record.sourceId,
          record.showUrl,
          record.episodeId,
        );
        if (mark?.finished ?? false) {
          return Align(
            alignment: Alignment.topRight,
            child: Padding(
              padding: const EdgeInsets.all(5),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: AppColors.accent,
                  shape: BoxShape.circle,
                ),
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(
                    Icons.check_rounded,
                    color: Colors.white,
                    size: 10,
                  ),
                ),
              ),
            ),
          );
        }
        final hasPos = (mark?.duration.inMilliseconds ?? 0) > 0;
        if (!hasPos) return const SizedBox.shrink();
        return const Center(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Color(0x99000000),
              shape: BoxShape.circle,
            ),
            child: Padding(
              padding: EdgeInsets.all(9),
              child: Icon(
                Icons.play_arrow_rounded,
                color: Colors.white,
                size: 12,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Total runtime chip on a finished thumbnail, bottom-right. Only there when
/// the resume box actually knows the duration — never guessed.
class _ThumbDuration extends StatelessWidget {
  const _ThumbDuration({required this.record, required this.resume});

  final DownloadRecord record;
  final ResumeStore? resume;

  @override
  Widget build(BuildContext context) {
    final resume = this.resume;
    if (resume == null) return const SizedBox.shrink();
    return ValueListenableBuilder<Box<Map>>(
      valueListenable: Hive.box<Map>(ResumeStore.boxName).listenable(),
      builder: (context, _, __) {
        final total = resume
            .get(record.sourceId, record.showUrl, record.episodeId)
            ?.duration;
        if (total == null || total.inMilliseconds <= 0) {
          return const SizedBox.shrink();
        }
        return Align(
          alignment: Alignment.bottomRight,
          child: Padding(
            padding: const EdgeInsets.all(5),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xD2000000),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 5,
                  vertical: 2,
                ),
                child: Text(
                  _clock(total),
                  style: const TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
        );
      },
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
    if (defaultTargetPlatform == TargetPlatform.windows &&
        record.status == DownloadStatus.queued && record.retryAt != null) {
      return const Icon(Icons.schedule_rounded, size: 26,
          color: AppColors.textSecondary);
    }
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

/// The actions offered for one download, shared by the three-dot menu and
/// the Windows right-click menu (dl-4) so they never drift apart.
List<({String value, IconData icon, String label})> _tileActions(
    DownloadRecord r, AppLocalizations l10n, DownloadManager manager) {
  final windows = defaultTargetPlatform == TargetPlatform.windows;
  // Local media workers are Windows-only; phone and TV retain their menus.
  final localAudio = windows && r.pendingAudioFinalization;
  final waitingRetry = windows &&
      r.autoResumePending && r.retryAt != null && r.status == DownloadStatus.queued;
  // Windows: an item still waiting for a slot (or resolving its source) can
  // be held back with Pause instead of only removed (dl-6).
  final waiting = windows && !r.isTorrent &&
      const {DownloadStatus.queued, DownloadStatus.resolving}.contains(r.status);
  // Windows: "Download next" moves an item to the front of the queue (dl-6).
  // Only items that wait (queued / resolving / paused) can jump; failed ones
  // keep Retry as their way back. The manager then decides (hidden when the
  // item is already first in line).
  final canJump = windows && !r.isTorrent &&
      const {
        DownloadStatus.queued,
        DownloadStatus.resolving,
        DownloadStatus.paused,
      }.contains(r.status) &&
      manager.canMoveToFront(r);
  return [
    if (r.status == DownloadStatus.downloading || waitingRetry || waiting ||
        (localAudio &&
            const {
              DownloadStatus.queued,
              DownloadStatus.finalizing,
            }.contains(r.status)))
      (value: 'pause', icon: Icons.pause_rounded, label: l10n.pause),
    if (r.status == DownloadStatus.paused ||
        (localAudio && r.status == DownloadStatus.failed))
      (value: 'resume', icon: Icons.play_arrow_rounded, label: l10n.resume),
    if (r.status == DownloadStatus.failed && !r.isTorrent)
      (value: 'retry', icon: Icons.refresh_rounded, label: l10n.retry),
    if (canJump)
      (value: 'next', icon: Icons.vertical_align_top_rounded,
        label: l10n.downloadNext),
    if (r.isActive) (value: 'cancel', icon: Icons.close_rounded, label: l10n.cancel),
    (value: 'delete', icon: Icons.delete_outline_rounded, label: l10n.delete),
  ];
}

/// Runs one of [_tileActions] on [r].
void _runTileAction(String action, DownloadRecord r, DownloadManager manager) {
  switch (action) {
    case 'pause':
      unawaited(manager.pause(r));
    case 'resume':
      unawaited(manager.resume(r));
    case 'retry':
      unawaited(manager.retry(r));
    case 'next':
      unawaited(manager.moveToFront(r));
    // Cancel an in-flight download = stop it AND remove it from the list
    // (delete cancels the task, drops the record, and clears fallbacks).
    case 'cancel':
    case 'delete':
      unawaited(manager.delete(r));
  }
}

class _TileMenu extends StatelessWidget {
  const _TileMenu({required this.record, required this.manager});
  final DownloadRecord record;
  final DownloadManager manager;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert_rounded, color: AppColors.textSecondary),
      color: AppColors.surface2,
      onSelected: (v) => _runTileAction(v, record, manager),
      itemBuilder: (context) => [
        for (final a in _tileActions(record, l10n, manager)) _item(a.value, a.icon, a.label),
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
