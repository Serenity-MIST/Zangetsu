import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/download/download_link_label.dart';
import '../../core/download/download_manager.dart';
import '../../core/download/download_size_estimate.dart';
import '../../core/download/download_source_search.dart';
import '../../core/download/windows_download_storage.dart';
import '../../core/models/episode.dart';
import '../../core/models/video_source.dart';
import '../../core/playback/source_selection.dart'
    show resolutionPx, sortByQuality;
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/desktop_settings_surface.dart'
    show GraphiteSettingsColors;
import '../../l10n/l10n.dart';
import 'episode_filter.dart';

/// Same shape the phone batch sheet pops, so the caller's enqueue path is shared.
typedef DesktopBatchDownloadChoice = ({
  String quality,
  String category,
  List<Episode> episodes,
  VideoSource? server,
  // Real source the probe's links came from (fallback-aware); null = caller's.
  String? sourceId,
});

/// Graphite tones shared with the desktop settings and download surfaces.
// Getters (set-9) so they follow Pure black and custom backgrounds.
Color get _graphiteLine => GraphiteSettingsColors.panelEdge;
Color get _graphiteHover => GraphiteSettingsColors.rowHover;

/// Lucide glyph tinted like the rest of the Windows chrome.
Widget _lucide(String name, {double size = 18, Color? color}) =>
    SvgPicture.asset(
      'assets/icons/lucide/$name.svg',
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(
        color ?? AppColors.textSecondary,
        BlendMode.srcIn,
      ),
    );

/// Server identity used by batch preference matching: SUB/DUB kind + server
/// name + host + audio language. The kind and the server name (which some
/// providers keep in `quality`) used to be missing, so every Anikoto server
/// on one CDN host collapsed into a single "server" and DUB was unreachable.
String _serverKey(VideoSource s) =>
    '${downloadServerKey(s)}|${s.audioLang ?? ''}';

/// Resolution option ("1080p") for a link, or null when its quality names
/// no resolution (a bare server name).
String? _resolutionOption(VideoSource s) {
  final px = resolutionPx(s.quality);
  return px == null ? null : '${px}p';
}

/// Windows batch download chooser: season, sub/dub, episode grid, quality,
/// server and size estimate in one centered dialog. Phone and TV keep the
/// bottom sheet; this returns the identical record so enqueueing is shared.
class DesktopBatchDownloadDialog extends StatefulWidget {
  const DesktopBatchDownloadDialog({
    super.key,
    required this.title,
    required this.episodesBySeason,
    required this.initialSeason,
    required this.initialCategory,
    required this.availableCategories,
    required this.resolve,
    required this.resolveEpisodes,
    this.coverUrl = '',
    this.coverHeaders,
    this.downloadedIds,
    this.estimateSize,
    this.readFreeBytes,
    this.searchSources,
  });

  final String title;
  final Map<int, List<Episode>> episodesBySeason;
  final int initialSeason;
  final String initialCategory;
  final List<String> availableCategories;

  /// Resolves one episode's streams (used on the season's first episode).
  final Future<List<VideoSource>> Function(Episode) resolve;

  /// Re-resolves the whole episode list for another sub/dub category.
  final Future<Map<int, List<Episode>>> Function(String category)
  resolveEpisodes;
  final String coverUrl;
  final Map<String, String>? coverHeaders;

  /// Ids of [episodes] already saved locally for [category]; null skips marks.
  final Future<Set<String>> Function(String category, List<Episode> episodes)?
  downloadedIds;

  /// Per-episode size probe for the picked stream; null hides the estimate.
  final Future<DownloadSizeEstimate?> Function(
    VideoSource source,
    Episode episode,
    String quality,
  )?
  estimateSize;

  /// Free bytes at the download location; null (or a null result) = unknown.
  final Future<int?> Function()? readFreeBytes;

  /// Bounded per-source search for the first-episode probe (fallback chain,
  /// progress per source). When null, [resolve] is asked once, bounded.
  final Stream<List<DownloadSourceStatus>> Function(Episode, String category)?
  searchSources;

  @override
  State<DesktopBatchDownloadDialog> createState() =>
      _DesktopBatchDownloadDialogState();
}

class _DesktopBatchDownloadDialogState
    extends State<DesktopBatchDownloadDialog> {
  late String _category;
  late int _season;
  late Map<int, List<Episode>> _episodesBySeason;
  late Map<String, Episode> _byId;
  final Set<String> _selectedIds = {};
  final Set<String> _downloaded = {};
  String? _anchorId;
  bool _episodesLoading = false;
  bool _episodesFailed = false;

  // Sources resolved from the current season's first episode.
  List<VideoSource>? _sources;
  bool _sourcesFailed = false;
  String? _serverKeyPick;
  String _quality = 'best';

  // Per-source probe progress and which answering source the links are from.
  List<DownloadSourceStatus> _searchRows = const [];
  StreamSubscription<List<DownloadSourceStatus>>? _searchSub;
  bool _searching = false;
  String? _sourcePick;
  bool _sourcePickedByUser = false;

  // Size estimate for one episode of the picked stream; totals scale by count.
  int? _perEpisode;
  bool _solid = false;
  bool _estimating = false;
  int? _freeBytes;
  bool _submitting = false;

  // Request counters retire stale async results after a newer pick.
  int _categoryRequest = 0;
  int _sourceRequest = 0;
  int _estimateRequest = 0;
  int _downloadedRequest = 0;

  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'batch-search');
  final _fromCtrl = TextEditingController();
  final _toCtrl = TextEditingController();
  final _fromFocus = FocusNode(debugLabel: 'batch-range-from');
  final _toFocus = FocusNode(debugLabel: 'batch-range-to');
  final _gridScroll = ScrollController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _category = widget.initialCategory;
    _season = widget.initialSeason;
    _applyEpisodes(widget.episodesBySeason);
    // Whole current season preselected, like the phone sheet's default.
    _selectedIds.addAll(_seasonEps.map((e) => e.id));
    _resetRangeFields();
    _resolveSources();
    _loadDownloaded();
    _loadFreeBytes();
  }

  @override
  void dispose() {
    _categoryRequest++;
    _sourceRequest++;
    _estimateRequest++;
    _downloadedRequest++;
    _searchSub?.cancel();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _fromCtrl.dispose();
    _toCtrl.dispose();
    _fromFocus.dispose();
    _toFocus.dispose();
    _gridScroll.dispose();
    super.dispose();
  }

  // ── Derived state ───────────────────────────────────────────────────────

  List<int> get _seasons => _episodesBySeason.keys.toList()..sort();
  List<Episode> get _seasonEps => _episodesBySeason[_season] ?? const [];
  List<Episode> get _filtered => filterEpisodes(_seasonEps, _query);
  int get _totalEpisodes =>
      _episodesBySeason.values.fold(0, (a, b) => a + b.length);

  /// Downloaded episodes are skipped by the enqueue path, so they never count.
  List<Episode> get _selectedEpisodes =>
      _selectedIds
          .where((id) => !_downloaded.contains(id))
          .map((id) => _byId[id])
          .whereType<Episode>()
          .toList()
        ..sort((a, b) => (a.number ?? 0).compareTo(b.number ?? 0));

  int _epNum(Episode e) {
    final n = e.number;
    return n != null ? n.toInt() : _seasonEps.indexOf(e) + 1;
  }

  /// One representative source per distinct server, best quality first.
  List<VideoSource> get _servers {
    final seen = <String>{};
    return [
      for (final s in _sources ?? const <VideoSource>[])
        if (seen.add(_serverKey(s))) s,
    ];
  }

  VideoSource? get _server {
    final key = _serverKeyPick;
    if (key == null) return null;
    for (final s in _servers) {
      if (_serverKey(s) == key) return s;
    }
    return null;
  }

  /// Sources the quality menu draws from: the picked server's, or all.
  List<VideoSource> get _scopedSources {
    final all = _sources ?? const <VideoSource>[];
    final key = _serverKeyPick;
    return key == null ? all : all.where((s) => _serverKey(s) == key).toList();
  }

  /// Resolutions of the scoped server(s), best first. Only real resolutions:
  /// a server name kept in `quality` ("HD - 1 - 1080p") belongs to the
  /// Server menu, not here.
  List<String> get _qualities {
    final seen = <String>{};
    return [
      'best',
      for (final s in sortByQuality(_scopedSources))
        if (_resolutionOption(s) case final q? when seen.add(q)) q,
    ];
  }

  /// SUB/DUB category the batch downloads: the picked server's own kind,
  /// else the dialog's cut. Picking a DUB server is how dub gets chosen when
  /// the title's details do not offer a Dub toggle.
  String get _effectiveCategory {
    final server = _server;
    return server == null
        ? _category
        : downloadCategoryForKind(server.kind) ?? _category;
  }

  /// The stream the size estimate samples: matching quality within the scope.
  VideoSource? get _sampleSource {
    final scoped = _scopedSources;
    if (scoped.isEmpty) return null;
    if (_quality != 'best') {
      for (final s in scoped) {
        if (_resolutionOption(s) == _quality) return s;
      }
    }
    return scoped.first;
  }

  // ── Loading ─────────────────────────────────────────────────────────────

  void _applyEpisodes(Map<int, List<Episode>> bySeason) {
    _episodesBySeason = bySeason;
    _byId = {
      for (final eps in bySeason.values)
        for (final e in eps) e.id: e,
    };
  }

  /// Range fields start at the season's first and last episode numbers.
  void _resetRangeFields() {
    final eps = _seasonEps;
    _fromCtrl.text = eps.isEmpty ? '' : '${_epNum(eps.first)}';
    _toCtrl.text = eps.isEmpty ? '' : '${_epNum(eps.last)}';
  }

  /// Resolves the season's first episode for real server/quality options.
  ///
  /// Runs as a bounded per-source search: links appear as soon as any source
  /// answers, the footer says which source is being asked, and the search
  /// always ends (links, or "No source had this episode" with Retry).
  Future<void> _resolveSources() async {
    final request = ++_sourceRequest;
    final eps = _seasonEps;
    unawaited(_searchSub?.cancel());
    _searchSub = null;
    setState(() {
      _sources = eps.isEmpty ? const [] : null;
      _sourcesFailed = false;
      _perEpisode = null;
      _searchRows = const [];
      _searching = eps.isNotEmpty;
      _sourcePick = null;
      _sourcePickedByUser = false;
    });
    if (eps.isEmpty) return;
    final first = eps.first;
    final category = _category;
    final stream =
        widget.searchSources?.call(first, category) ??
        searchSingleDownloadSource(
          sourceId: '',
          name: '',
          resolve: () => widget.resolve(first),
        );
    _searchSub = stream.listen(
      (rows) {
        if (!mounted || request != _sourceRequest) return;
        setState(() {
          _searchRows = rows;
          final found = _foundSources;
          if (!_sourcePickedByUser &&
              found.isNotEmpty &&
              _sourcePick != found.first.row.sourceId) {
            _applySource(found.first.row.sourceId);
          }
        });
      },
      onDone: () {
        if (!mounted || request != _sourceRequest) return;
        setState(() {
          _searching = false;
          if (_sources == null) {
            // Nothing usable from any source: Retry stays available.
            _sources = const [];
            _sourcesFailed = true;
          }
        });
      },
    );
  }

  /// Sources that answered with links, in priority order. Every link is kept,
  /// SUB and DUB alike (grouped like the player, this cut's kind first, best
  /// quality first): filtering by the cut hid DUB servers whenever the
  /// title's details had no dub count.
  List<({DownloadSourceStatus row, List<VideoSource> links})>
  get _foundSources => [
    for (final r in _searchRows)
      if (r.phase == DownloadSourcePhase.found)
        (row: r, links: orderDownloadLinks(r.streams, _category)),
  ].where((o) => o.links.isNotEmpty).toList();

  /// Shows [sourceId]'s links and preselects its first server of this cut.
  void _applySource(String sourceId) {
    final match = _foundSources.where((o) => o.row.sourceId == sourceId);
    if (match.isEmpty) return;
    final ranked = match.first.links;
    _sourcePick = sourceId;
    _sources = ranked;
    _sourcesFailed = false;
    // Phone parity: the first ranked server is preselected, taken from this
    // cut's kind so the default never silently switches SUB to DUB.
    final ofCut = DownloadManager.sourcesForDownloadCategory(ranked, _category);
    final previousCategory = _effectiveCategory;
    final first = ofCut.isNotEmpty ? ofCut.first : ranked.first;
    _serverKeyPick = _serverKey(first);
    // Its resolution is preselected too (Best when it names none).
    _quality = _resolutionOption(first) ?? 'best';
    _onCategoryMaybeChanged(previousCategory);
    // After this frame: the estimate reads the state just set.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refreshEstimate();
    });
  }

  /// Footer status line for the probe: who is being asked, or why it ended.
  String? get _searchStatus {
    final trying = _searchRows
        .where((r) => r.phase == DownloadSourcePhase.trying)
        .toList();
    if (_searching && trying.isNotEmpty) {
      final name = trying.first.name;
      if (name.isEmpty) return null;
      return trying.length == 1
          ? 'Trying $name...'
          : 'Trying $name and ${trying.length - 1} more...';
    }
    if (!_searching && _sourcesFailed && _searchRows.length > 1) {
      return 'No source had this episode';
    }
    return null;
  }

  /// Marks already-saved episodes of the visible season for this category.
  Future<void> _loadDownloaded() async {
    final lookup = widget.downloadedIds;
    if (lookup == null) return;
    final request = ++_downloadedRequest;
    // Marks follow the cut that will actually be downloaded (a DUB server
    // pick downloads the dub cut).
    final category = _effectiveCategory;
    try {
      final ids = await lookup(category, _seasonEps);
      if (!mounted ||
          request != _downloadedRequest ||
          category != _effectiveCategory) {
        return;
      }
      setState(() => _downloaded.addAll(ids));
    } catch (_) {
      /* Unknown state stays selectable; the enqueue path re-checks. */
    }
  }

  Future<int?> _readFree() async {
    try {
      return await widget.readFreeBytes?.call();
    } catch (_) {
      return null; // Unreadable drives never fabricate a low-space warning.
    }
  }

  Future<void> _loadFreeBytes() async {
    final free = await _readFree();
    if (mounted) setState(() => _freeBytes = free);
  }

  /// Samples one episode's size for the picked server + quality.
  Future<void> _refreshEstimate() async {
    final request = ++_estimateRequest;
    final source = _sampleSource;
    final episode = _seasonEps.firstOrNull;
    final estimate = widget.estimateSize;
    setState(() {
      _perEpisode = null;
      _solid = false;
      _estimating = source != null && episode != null && estimate != null;
    });
    if (source == null || episode == null || estimate == null) return;
    DownloadSizeEstimate? est;
    try {
      est = await estimate(source, episode, _quality);
    } catch (_) {
      est = null;
    }
    if (!mounted || request != _estimateRequest) return;
    setState(() {
      _perEpisode = est?.bytes;
      _solid = est?.solid ?? false;
      _estimating = false;
    });
  }

  // ── Actions ─────────────────────────────────────────────────────────────

  /// Sub/dub switch re-resolves episodes, keeps the season when it exists.
  /// [force] re-runs the current category (Retry after a failed switch).
  Future<void> _setCategory(String category, {bool force = false}) async {
    if ((category == _category && !force) || _submitting) return;
    final request = ++_categoryRequest;
    _sourceRequest++;
    _estimateRequest++;
    // The old cut's probe must not keep its "Trying X..." line alive.
    unawaited(_searchSub?.cancel());
    _searchSub = null;
    setState(() {
      _category = category;
      _episodesLoading = true;
      _episodesFailed = false;
      _searching = false;
      _searchRows = const [];
      _sourcePick = null;
      _sources = null;
      _perEpisode = null;
      _downloaded.clear();
      _anchorId = null;
    });
    try {
      // Bounded: a hung episode list ends in the failed state with Retry.
      final bySeason = await widget
          .resolveEpisodes(category)
          .timeout(const Duration(seconds: 60));
      if (!mounted || request != _categoryRequest) return;
      final seasons = bySeason.keys.toList()..sort();
      setState(() {
        _applyEpisodes(bySeason);
        if (!bySeason.containsKey(_season) && seasons.isNotEmpty) {
          _season = seasons.first;
        }
        _selectedIds
          ..clear()
          ..addAll(_seasonEps.map((e) => e.id));
        _episodesLoading = false;
        _clearQuery();
        _resetRangeFields();
      });
      _resolveSources();
      _loadDownloaded();
    } catch (_) {
      if (!mounted || request != _categoryRequest) return;
      setState(() {
        _applyEpisodes(const {});
        _selectedIds.clear();
        _sources = const [];
        _episodesLoading = false;
        _episodesFailed = true;
      });
    }
  }

  /// Season switch keeps other seasons' picks (phone parity).
  void _setSeason(int season) {
    if (season == _season) return;
    setState(() {
      _season = season;
      _anchorId = null;
      _clearQuery();
      _resetRangeFields();
    });
    if (_gridScroll.hasClients) _gridScroll.jumpTo(0);
    _resolveSources();
    _loadDownloaded();
  }

  void _clearQuery() {
    _query = '';
    _searchCtrl.clear();
  }

  void _setServer(String? key) {
    final previousCategory = _effectiveCategory;
    setState(() {
      _serverKeyPick = key;
      // A resolution the new server lacks moves to that server's best one.
      if (!_qualities.contains(_quality)) {
        final top = sortByQuality(_scopedSources).firstOrNull;
        _quality = top == null ? 'best' : _resolutionOption(top) ?? 'best';
      }
    });
    _onCategoryMaybeChanged(previousCategory);
    _refreshEstimate();
  }

  /// A server pick of the other kind (SUB <-> DUB) changes which saved
  /// episodes are "already downloaded": redo the marks for the new cut.
  void _onCategoryMaybeChanged(String previousCategory) {
    if (_effectiveCategory == previousCategory) return;
    _downloaded.clear();
    // After this frame: _loadDownloaded reads the state just set.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadDownloaded();
    });
  }

  void _setQuality(String quality) {
    setState(() => _quality = quality);
    _refreshEstimate();
  }

  /// Plain click toggles; shift-click applies the anchor's state to the range.
  void _onEpisodeTap(Episode ep) {
    if (_downloaded.contains(ep.id) || _submitting) return;
    final visible = _filtered;
    final anchor = _anchorId;
    final anchorIdx = anchor == null
        ? -1
        : visible.indexWhere((e) => e.id == anchor);
    setState(() {
      if (HardwareKeyboard.instance.isShiftPressed && anchorIdx >= 0) {
        final idx = visible.indexOf(ep);
        final select = _selectedIds.contains(anchor);
        final lo = idx < anchorIdx ? idx : anchorIdx;
        final hi = idx < anchorIdx ? anchorIdx : idx;
        for (final e in visible.sublist(lo, hi + 1)) {
          if (_downloaded.contains(e.id)) continue;
          select ? _selectedIds.add(e.id) : _selectedIds.remove(e.id);
        }
      } else {
        _selectedIds.contains(ep.id)
            ? _selectedIds.remove(ep.id)
            : _selectedIds.add(ep.id);
        _anchorId = ep.id;
      }
    });
  }

  /// Select-all and none act on the filtered view, like the phone sheet.
  void _selectAll() => setState(
    () => _selectedIds.addAll(
      _filtered.where((e) => !_downloaded.contains(e.id)).map((e) => e.id),
    ),
  );

  void _selectNone() =>
      setState(() => _selectedIds.removeAll(_filtered.map((e) => e.id)));

  /// Replaces this season's picks with episodes numbered within From..To.
  void _applyRange() {
    final a = int.tryParse(_fromCtrl.text.trim());
    final b = int.tryParse(_toCtrl.text.trim());
    if (a == null || b == null) return;
    final lo = a < b ? a : b;
    final hi = a < b ? b : a;
    setState(() {
      _selectedIds.removeAll(_seasonEps.map((e) => e.id));
      _selectedIds.addAll(
        _seasonEps
            .where(
              (e) =>
                  !_downloaded.contains(e.id) &&
                  _epNum(e) >= lo &&
                  _epNum(e) <= hi,
            )
            .map((e) => e.id),
      );
      _anchorId = null;
    });
  }

  /// Pops the choice, confirming first when a solid estimate exceeds free space.
  Future<void> _submit() async {
    final episodes = _selectedEpisodes;
    if (_submitting || episodes.isEmpty || _episodesLoading) return;
    final choice = (
      quality: _quality,
      // The picked server's SUB/DUB kind decides the cut for every episode.
      category: _effectiveCategory,
      episodes: List<Episode>.of(episodes),
      server: _server,
      sourceId: (_sourcePick?.isEmpty ?? true) ? null : _sourcePick,
    );
    final perEpisode = _perEpisode;
    setState(() => _submitting = true);
    try {
      if (perEpisode != null && _solid) {
        final free = await _readFree();
        if (!mounted) return;
        final total = perEpisode * episodes.length;
        if (downloadEstimateExceedsSpace(
          freeBytes: free,
          estimatedBytes: total,
          solid: true,
        )) {
          final l10n = context.l10n;
          final go = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: AppColors.surface,
              title: Text(l10n.storageLowTitle),
              content: Text(
                l10n.storageLowBody(
                  formatApproxBytes(total),
                  formatApproxBytes(free!),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(l10n.cancel),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(l10n.downloadAnyway),
                ),
              ],
            ),
          );
          if (go != true || !mounted) return;
        }
      }
      if (mounted) Navigator.pop(context, choice);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// Enter applies the range while a range field is focused, does nothing in
  /// the search box (typing a query should never start downloads), else
  /// confirms.
  void _onEnter() {
    if (_fromFocus.hasFocus || _toFocus.hasFocus) {
      _applyRange();
    } else if (_searchFocus.hasFocus) {
      return;
    } else {
      _submit();
    }
  }

  /// Ctrl+A selects visible episodes unless a text field owns the shortcut.
  void _onSelectAllShortcut() {
    if (_searchFocus.hasFocus || _fromFocus.hasFocus || _toFocus.hasFocus) {
      return;
    }
    _selectAll();
  }

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 28),
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.enter): _onEnter,
          const SingleActivator(LogicalKeyboardKey.numpadEnter): _onEnter,
          const SingleActivator(LogicalKeyboardKey.keyA, control: true):
              _onSelectAllShortcut,
        },
        child: Focus(
          autofocus: true,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 940,
              maxHeight: (size.height * 0.9).clamp(360, 800).toDouble(),
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                // set-9: themed panel gradient (stock greys by default).
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: GraphiteSettingsColors.panelGradient,
                ),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _graphiteLine),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x80000000),
                    blurRadius: 40,
                    offset: Offset(0, 16),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Material(
                  type: MaterialType.transparency,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _header(),
                      Divider(height: 1, color: _graphiteLine),
                      _toolbar(),
                      Flexible(child: _episodeArea()),
                      Divider(height: 1, color: _graphiteLine),
                      _footer(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Poster, title, season menu, sub/dub control and close button.
  Widget _header() {
    final l10n = context.l10n;
    final seasons = _seasons;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 16, 18),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 44,
              height: 64,
              child: _image(widget.coverUrl, 120),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  l10n.downloadEpisodes,
                  style: AppText.headline.copyWith(fontSize: 18),
                ),
                const SizedBox(height: 4),
                Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (seasons.length > 1) ...[
            const SizedBox(width: 12),
            _MenuPill<int>(
              key: const ValueKey('batch-season'),
              caption: l10n.season,
              tooltip: l10n.season,
              valueLabel: l10n.seasonNumber(_season),
              selected: _season,
              options: [for (final s in seasons) (s, l10n.seasonNumber(s))],
              onSelected: _episodesLoading || _submitting ? null : _setSeason,
            ),
          ],
          if (widget.availableCategories.length > 1) ...[
            const SizedBox(width: 12),
            _Segmented(
              tooltip: l10n.audio,
              options: [
                for (final c in widget.availableCategories)
                  (c, c == 'dub' ? l10n.dub : l10n.sub),
              ],
              selected: _category,
              onSelected: _submitting ? null : _setCategory,
            ),
          ],
          const SizedBox(width: 8),
          IconButton(
            tooltip: l10n.cancel,
            onPressed: () => Navigator.pop(context),
            icon: _lucide('x', size: 18),
          ),
        ],
      ),
    );
  }

  /// Search, custom range input and select all / none for the visible season.
  Widget _toolbar() {
    final l10n = context.l10n;
    final enabled = !_episodesLoading && _seasonEps.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 14, 24, 10),
      child: Row(
        children: [
          // Search shrinks first when the window is narrow.
          Expanded(
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 260),
                child: SizedBox(
                  height: 36,
                  child: TextField(
                    controller: _searchCtrl,
                    focusNode: _searchFocus,
                    enabled: enabled,
                    onChanged: (v) => setState(() => _query = v),
                    style: AppText.body.copyWith(
                      color: AppColors.textPrimary,
                      fontSize: 13.5,
                    ),
                    cursorColor: AppColors.accent,
                    decoration: _fieldDecoration(l10n.searchEpisodes).copyWith(
                      prefixIcon: Padding(
                        padding: const EdgeInsets.all(9),
                        child: _lucide('search', size: 16),
                      ),
                      prefixIconConstraints: const BoxConstraints(
                        minWidth: 34,
                        minHeight: 34,
                      ),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              tooltip: l10n.clear,
                              iconSize: 14,
                              onPressed: () => setState(_clearQuery),
                              icon: _lucide('x', size: 14),
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          // The caption drops on narrow windows; the apply button's tooltip
          // still names the control.
          if (MediaQuery.sizeOf(context).width >= 940) ...[
            Text(
              l10n.customRange,
              style: AppText.caption.copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(width: 10),
          ],
          _rangeField(
            _fromCtrl,
            _fromFocus,
            const ValueKey('batch-range-from'),
            enabled,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              '-',
              style: AppText.caption.copyWith(color: AppColors.textSecondary),
            ),
          ),
          _rangeField(
            _toCtrl,
            _toFocus,
            const ValueKey('batch-range-to'),
            enabled,
          ),
          const SizedBox(width: 6),
          Tooltip(
            message: l10n.customRange,
            child: IconButton.outlined(
              key: const ValueKey('batch-range-apply'),
              onPressed: enabled ? _applyRange : null,
              style: IconButton.styleFrom(
                side: BorderSide(color: _graphiteLine),
                minimumSize: const Size(36, 36),
                fixedSize: const Size(36, 36),
              ),
              icon: _lucide('check', size: 16),
            ),
          ),
          const SizedBox(width: 14),
          Container(width: 1, height: 22, color: _graphiteLine),
          const SizedBox(width: 8),
          TextButton(
            onPressed: enabled ? _selectAll : null,
            child: Text(l10n.selectAll),
          ),
          TextButton(
            onPressed: enabled ? _selectNone : null,
            child: Text(l10n.none),
          ),
        ],
      ),
    );
  }

  Widget _rangeField(
    TextEditingController ctrl,
    FocusNode focus,
    Key key,
    bool enabled,
  ) => SizedBox(
    width: 64,
    height: 36,
    child: TextField(
      key: key,
      controller: ctrl,
      focusNode: focus,
      enabled: enabled,
      textAlign: TextAlign.center,
      keyboardType: TextInputType.number,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(5),
      ],
      style: AppText.body.copyWith(
        color: AppColors.textPrimary,
        fontSize: 13.5,
      ),
      cursorColor: AppColors.accent,
      decoration: _fieldDecoration('E'),
    ),
  );

  InputDecoration _fieldDecoration(String hint) => InputDecoration(
    isDense: true,
    hintText: hint,
    hintStyle: AppText.caption.copyWith(color: AppColors.textTertiary),
    filled: true,
    fillColor: AppColors.surface,
    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: _graphiteLine),
    ),
    disabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: _graphiteLine),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: AppColors.accent),
    ),
  );

  /// Scrollable episode grid, or the loading / empty / no-match states.
  Widget _episodeArea() {
    final l10n = context.l10n;
    Widget message(String text) => SizedBox(
      height: 220,
      child: Center(
        child: Text(
          text,
          style: AppText.body.copyWith(color: AppColors.textTertiary),
        ),
      ),
    );
    if (_episodesLoading) {
      return const SizedBox(
        height: 220,
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
        ),
      );
    }
    // A failed sub/dub re-resolve (offline, source error) offers a retry.
    if (_episodesFailed) {
      return SizedBox(
        height: 220,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l10n.couldntLoadDownloadOptions,
                style: AppText.body.copyWith(color: AppColors.textTertiary),
              ),
              const SizedBox(height: 10),
              OutlinedButton(
                key: const ValueKey('batch-episodes-retry'),
                onPressed: () => _setCategory(_category, force: true),
                child: Text(l10n.retry),
              ),
            ],
          ),
        ),
      );
    }
    if (_seasonEps.isEmpty) return message(l10n.noEpisodesToDownload);
    final visible = _filtered;
    if (visible.isEmpty) return message(l10n.noEpisodesMatch);
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 12.0;
        const padding = 24.0;
        final width = constraints.maxWidth - padding * 2;
        final columns = ((width + gap) / (196 + gap)).floor().clamp(2, 8);
        final tileWidth = (width - gap * (columns - 1)) / columns;
        return Scrollbar(
          controller: _gridScroll,
          thumbVisibility: true,
          child: GridView.builder(
            controller: _gridScroll,
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(padding, 6, padding, 18),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: gap,
              mainAxisSpacing: gap,
              // 16:9 thumbnail plus tile padding and a two-line caption.
              mainAxisExtent: (tileWidth - 12) * 9 / 16 + 56,
            ),
            itemCount: visible.length,
            itemBuilder: (context, i) {
              final ep = visible[i];
              final thumb = (ep.thumbnail?.isNotEmpty ?? false)
                  ? ep.thumbnail!
                  : widget.coverUrl;
              return _EpisodeTile(
                key: ValueKey('batch-ep-${ep.id}'),
                number: _epNum(ep),
                title: ep.title.trim(),
                image: _image(thumb, 360),
                selected:
                    _selectedIds.contains(ep.id) &&
                    !_downloaded.contains(ep.id),
                downloaded: _downloaded.contains(ep.id),
                onTap: () => _onEpisodeTap(ep),
              );
            },
          ),
        );
      },
    );
  }

  /// Network art with a quiet placeholder; empty urls never hit the network.
  Widget _image(String url, int cacheWidth) {
    final placeholder = ColoredBox(
      color: AppColors.surface2,
      child: Center(
        child: _lucide('clapperboard', size: 18, color: AppColors.textTertiary),
      ),
    );
    if (url.isEmpty) return placeholder;
    return CachedNetworkImage(
      imageUrl: url,
      httpHeaders: widget.coverHeaders,
      fit: BoxFit.cover,
      memCacheWidth: cacheWidth,
      placeholder: (_, _) => placeholder,
      errorWidget: (_, _, _) => placeholder,
    );
  }

  /// Selection summary, size estimate, quality + server menus and actions.
  Widget _footer() {
    final l10n = context.l10n;
    final count = _selectedEpisodes.length;
    final sources = _sources;
    final perEpisode = _perEpisode;
    final total = perEpisode == null ? null : perEpisode * count;
    final low = downloadEstimateExceedsSpace(
      freeBytes: _freeBytes,
      estimatedBytes: total,
      solid: _solid,
    );
    final sizeText = count == 0
        ? null
        : _estimating
        ? 'Estimating download size...'
        : perEpisode == null
        ? null
        : l10n.downloadSizeEstimate(
                formatApproxBytes(perEpisode),
                formatApproxBytes(total!),
              ) +
              (_solid ? '' : ' (assumed bitrate)');
    final servers = _servers;
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          l10n.selectedEpisodesOfTotal(count, _totalEpisodes),
          key: const ValueKey('batch-count'),
          // R2: bounded lines so a squeezed bar can't grow the footer tall.
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: AppText.body.copyWith(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (sizeText != null) ...[
          const SizedBox(height: 3),
          Text(
            sizeText,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppText.caption.copyWith(color: AppColors.textSecondary),
          ),
        ],
        if (_freeBytes != null)
          Text(
            '${formatDownloadEstimate(_freeBytes!).replaceFirst('~', '')} available in download location',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppText.caption.copyWith(
              color: AppColors.textTertiary,
              fontSize: 12,
            ),
          ),
        if (low)
          Text(
            'Low storage: this estimate exceeds the available space.',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppText.caption.copyWith(
              color: AppColors.accent,
              fontSize: 12,
            ),
          ),
        // Probe progress per source, or why it ended with nothing.
        if (_searchStatus != null)
          Text(
            _searchStatus!,
            key: const ValueKey('batch-source-status'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.caption.copyWith(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
      ],
    );
    final found = _foundSources;
    List<Widget> controls(bool narrow) => [
      // Which source the links come from, when more than one answered.
      if (found.length > 1) ...[
        Flexible(
          flex: narrow ? 1 : 0,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 200),
            child: _MenuPill<String>(
              key: const ValueKey('batch-source'),
              caption: context.l10n.playerInfoSource,
              tooltip: context.l10n.playerInfoSource,
              valueLabel:
                  found
                      .where((o) => o.row.sourceId == _sourcePick)
                      .firstOrNull
                      ?.row
                      .name ??
                  found.first.row.name,
              selected: _sourcePick ?? '',
              options: [
                for (final o in found)
                  (o.row.sourceId, '${o.row.name} (${o.links.length})'),
              ],
              onSelected: _submitting
                  ? null
                  : (id) => setState(() {
                      _sourcePickedByUser = true;
                      _applySource(id);
                    }),
            ),
          ),
        ),
        const SizedBox(width: 8),
      ],
      if (sources == null)
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        )
      else if (sources.isEmpty) ...[
        Tooltip(
          message: _sourcesFailed
              ? l10n.couldntLoadDownloadOptions
              : l10n.noDownloadSourcesFound,
          child: Text(
            l10n.autoBestAvailable,
            style: AppText.caption.copyWith(color: AppColors.textSecondary),
          ),
        ),
        // Source lookup failed (offline/timeout): retry without reopening.
        if (_sourcesFailed && !_episodesFailed)
          IconButton(
            key: const ValueKey('batch-sources-retry'),
            tooltip: l10n.retry,
            onPressed: _submitting ? null : _resolveSources,
            icon: _lucide('rotate-cw', size: 16),
          ),
      ] else ...[
        // R2: quality may shrink too (capped) so a long label can never
        // push Cancel/Download off the stacked controls row.
        Flexible(
          flex: narrow ? 1 : 0,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: _MenuPill<String>(
              key: const ValueKey('batch-quality'),
              caption: l10n.quality,
              tooltip: l10n.quality,
              valueLabel: _quality == 'best' ? l10n.best : _quality,
              selected: _quality,
              options: [
                for (final q in _qualities) (q, q == 'best' ? l10n.best : q),
              ],
              onSelected: _submitting ? null : _setQuality,
            ),
          ),
        ),
        const SizedBox(width: 8),
        // Server names can be long; on the stacked (narrow) bar the pill
        // shrinks first. (Pills now always use the stacked bar, see R2.)
        Flexible(
          flex: narrow ? 1 : 0,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: _MenuPill<String>(
              key: const ValueKey('batch-server'),
              caption: l10n.watchServer,
              tooltip: l10n.watchServer,
              valueLabel: _server == null
                  ? l10n.auto
                  : _serverLabel(_server!, servers.indexOf(_server!)),
              selected: _serverKeyPick ?? '',
              options: [
                ('', l10n.autoBestAvailable),
                for (var i = 0; i < servers.length; i++)
                  (_serverKey(servers[i]), _serverLabel(servers[i], i)),
              ],
              onSelected: _submitting
                  ? null
                  : (k) => _setServer(k.isEmpty ? null : k),
            ),
          ),
        ),
      ],
      const SizedBox(width: 16),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(l10n.cancel),
      ),
      const SizedBox(width: 8),
      FilledButton.icon(
        key: const ValueKey('batch-download'),
        onPressed: count == 0 || _submitting || _episodesLoading
            ? null
            : _submit,
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.accent,
          foregroundColor: Colors.white,
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.symmetric(horizontal: 18),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        icon: _lucide(
          'download',
          size: 16,
          color: count == 0 ? AppColors.textTertiary : Colors.white,
        ),
        label: Text(
          count == 0 ? l10n.selectEpisodes : l10n.downloadCountEpisodes(count),
        ),
      ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 14, 20, 16),
      child: LayoutBuilder(
        // R2: the one-bar layout is only safe while the controls are small
        // (spinner / "Auto" text + Cancel + Download). Once the quality,
        // server or source pills show, their natural widths could eat the
        // whole 896px bar and starve the summary to 0px wide (text wrapping
        // one glyph per line, footer so tall the episode list vanished), so
        // those cases always stack the summary above the controls.
        builder: (context, constraints) =>
            constraints.maxWidth >= 860 &&
                (sources == null || sources.isEmpty) &&
                found.length <= 1
            // Wide: summary left, controls right on one bar.
            ? Row(
                children: [
                  Expanded(child: info),
                  const SizedBox(width: 12),
                  ...controls(false),
                ],
              )
            // Narrow windows stack the summary above the controls.
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  info,
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: controls(true),
                  ),
                ],
              ),
      ),
    );
  }

  /// Readable server name like the player's ("SUB • HD - 1"): server name,
  /// else host, with its SUB/DUB kind; a numbered server as last resort.
  String _serverLabel(VideoSource s, int index) {
    final label = downloadServerLabel(s);
    final bare = label.replaceFirst(RegExp(r'^[A-Z]+ • '), '');
    return bare.isNotEmpty ? label : context.l10n.serverNumber(index + 1);
  }
}

/// Compact desktop dropdown: caption + value with a chevron, opens a menu.
class _MenuPill<T> extends StatelessWidget {
  const _MenuPill({
    super.key,
    required this.caption,
    required this.tooltip,
    required this.valueLabel,
    required this.selected,
    required this.options,
    required this.onSelected,
  });
  final String caption;
  final String tooltip;
  final String valueLabel;
  final T selected;
  final List<(T, String)> options;
  final ValueChanged<T>? onSelected;

  @override
  Widget build(BuildContext context) {
    final enabled = onSelected != null;
    return PopupMenuButton<T>(
      tooltip: tooltip,
      enabled: enabled,
      initialValue: selected,
      position: PopupMenuPosition.under,
      color: AppColors.surface2,
      constraints: const BoxConstraints(
        minWidth: 160,
        maxWidth: 320,
        maxHeight: 420,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: _graphiteLine),
      ),
      onSelected: onSelected,
      itemBuilder: (_) => [
        for (final (value, label) in options)
          PopupMenuItem<T>(
            value: value,
            height: 38,
            child: Row(
              children: [
                SizedBox(
                  width: 22,
                  child: value == selected
                      ? _lucide('check', size: 15, color: AppColors.accent)
                      : null,
                ),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.body.copyWith(
                      color: AppColors.textPrimary,
                      fontSize: 13.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
      child: Container(
        height: 40,
        padding: const EdgeInsets.only(left: 12, right: 8),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _graphiteLine),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Caption yields space to the value when the pill is squeezed.
            Flexible(
              child: Text(
                caption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.caption.copyWith(
                  color: AppColors.textTertiary,
                  fontSize: 12,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              flex: 2,
              child: Text(
                valueLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.body.copyWith(
                  color: enabled
                      ? AppColors.textPrimary
                      : AppColors.textTertiary,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 4),
            _lucide('chevron-down', size: 16),
          ],
        ),
      ),
    );
  }
}

/// Two-or-more option segmented control (Sub / Dub) with hover feedback.
class _Segmented extends StatelessWidget {
  const _Segmented({
    required this.tooltip,
    required this.options,
    required this.selected,
    required this.onSelected,
  });
  final String tooltip;
  final List<(String, String)> options;
  final String selected;
  final ValueChanged<String>? onSelected;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Container(
      height: 40,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _graphiteLine),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (value, label) in options)
            Material(
              color: value == selected ? AppColors.accent : Colors.transparent,
              borderRadius: BorderRadius.circular(7),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                key: ValueKey('batch-category-$value'),
                hoverColor: _graphiteHover,
                onTap: onSelected == null ? null : () => onSelected!(value),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Center(
                    child: Text(
                      label,
                      style: AppText.body.copyWith(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: value == selected
                            ? Colors.white
                            : AppColors.textSecondary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

/// One selectable episode: 16:9 art, checkbox badge, number and title.
/// Hover lifts the tile; downloaded episodes are marked and not selectable.
class _EpisodeTile extends StatefulWidget {
  const _EpisodeTile({
    super.key,
    required this.number,
    required this.title,
    required this.image,
    required this.selected,
    required this.downloaded,
    required this.onTap,
  });
  final int number;
  final String title;
  final Widget image;
  final bool selected;
  final bool downloaded;
  final VoidCallback onTap;

  @override
  State<_EpisodeTile> createState() => _EpisodeTileState();
}

class _EpisodeTileState extends State<_EpisodeTile> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final sel = widget.selected;
    final active = (_hover || _focus) && !widget.downloaded;
    final reduced = MediaQuery.disableAnimationsOf(context);
    final hasTitle =
        widget.title.isNotEmpty &&
        widget.title != l10n.episodeLabel(widget.number);
    final tile = AnimatedContainer(
      duration: reduced ? Duration.zero : const Duration(milliseconds: 140),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: sel
            ? AppColors.accentSoft
            : active
            ? _graphiteHover
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: sel || _focus
              ? AppColors.accent
              : active
              ? const Color(0xFF3A3B42)
              : Colors.transparent,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Opacity(
                    opacity: widget.downloaded ? 0.45 : 1,
                    child: widget.image,
                  ),
                  if (!widget.downloaded)
                    Positioned(top: 6, left: 6, child: _checkbox(sel))
                  else
                    Positioned(
                      left: 6,
                      bottom: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xCC000000),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _lucide(
                              'circle-check',
                              size: 12,
                              color: Colors.white,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              l10n.downloaded,
                              style: AppText.caption.copyWith(
                                color: Colors.white,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            l10n.episodeNumberShort(widget.number),
            maxLines: 1,
            style: AppText.caption.copyWith(
              color: sel ? AppColors.accent : AppColors.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(
            hasTitle ? widget.title : '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.caption.copyWith(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
    final tip = widget.downloaded
        ? l10n.downloaded
        : (hasTitle ? widget.title : null);
    final body = Semantics(
      button: true,
      selected: sel,
      enabled: !widget.downloaded,
      label: hasTitle
          ? l10n.episodeSemanticWithTitle(widget.number, widget.title)
          : l10n.episodeSemantic(widget.number),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        mouseCursor: widget.downloaded
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        hoverColor: Colors.transparent,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        focusColor: Colors.transparent,
        onHover: (v) => setState(() => _hover = v),
        onFocusChange: (v) => setState(() => _focus = v),
        onTap: widget.onTap,
        child: ExcludeSemantics(child: tile),
      ),
    );
    // Tooltip only when there is something to say (full title or state).
    return tip == null
        ? body
        : Tooltip(
            message: tip,
            waitDuration: const Duration(milliseconds: 600),
            child: body,
          );
  }

  /// Square checkbox badge readable on any thumbnail.
  Widget _checkbox(bool checked) => Container(
    width: 20,
    height: 20,
    decoration: BoxDecoration(
      color: checked ? AppColors.accent : const Color(0x99000000),
      borderRadius: BorderRadius.circular(5),
      border: Border.all(
        color: checked ? AppColors.accent : const Color(0xB3FFFFFF),
        width: 1.4,
      ),
    ),
    child: checked
        ? Center(child: _lucide('check', size: 14, color: Colors.white))
        : null,
  );
}
