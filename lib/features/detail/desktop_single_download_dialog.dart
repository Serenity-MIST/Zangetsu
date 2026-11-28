import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/download/download_link_label.dart';
import '../../core/download/download_manager.dart';
import '../../core/download/download_source_search.dart';
import '../../core/models/episode.dart';
import '../../core/models/video_source.dart';
import '../../core/theme/app_colors.dart';
import '../../l10n/l10n.dart';
import '../downloads/download_size_preview.dart';

/// The selected cut owns both its episode identity and its resolved streams.
/// [sourceId]/[sourceName] name the source the links actually came from (a
/// fallback source when the preferred one failed); null on the single-source
/// path, where it is the caller's own source.
typedef DesktopSingleDownloadChoice = ({Episode episode, String category,
  VideoSource chosen, List<VideoSource> all, String? sourceId, String? sourceName});

/// Never use array position to map cuts: missing dubs and specials shift lists.
Episode? matchSingleDownloadEpisode(Episode original, int season,
    Map<int, List<Episode>> candidates) {
  final pool = candidates[season] ?? const <Episode>[];
  final number = original.number;
  final matches = number != null && number.isFinite
      ? pool.where((e) => e.number == number && (e.season == null || e.season == season)).toList()
      : pool.where((e) => e.number == null && (e.season == null || e.season == season)).toList();
  // A single unnumbered movie is safe only when the cut contains one entry.
  if (number == null && pool.length != 1) return null;
  if (number != null && !number.isFinite) return null;
  return matches.length == 1 ? matches.single : null;
}

/// Status text for one source row of a download search.
String downloadSourcePhaseLabel(DownloadSourceStatus s, int links) =>
    switch (s.phase) {
      DownloadSourcePhase.waiting => 'Waiting',
      DownloadSourcePhase.trying => 'Trying ${s.name}...',
      DownloadSourcePhase.found =>
          links == 1 ? '1 link' : '$links links',
      DownloadSourcePhase.empty => 'Not found',
      DownloadSourcePhase.timedOut => 'Timed out',
      DownloadSourcePhase.failed => 'Failed',
      DownloadSourcePhase.skipped => s.detail ?? 'Skipped',
    };

/// Windows cut/server chooser; preserves shared queue/audio verification below.
///
/// With [searchSources] the dialog asks every fallback source at once and
/// lists links as each answers, tagged with the source they came from;
/// without it, [resolveSources] is asked once, bounded by a timeout.
class DesktopSingleDownloadDialog extends StatefulWidget {
  const DesktopSingleDownloadDialog({super.key, required this.episode,
    required this.season, required this.initialCategory, required this.availableCategories,
    required this.resolveEpisodes, required this.resolveSources, this.searchSources,
    this.previewBuilder});
  final Episode episode;
  final int season;
  final String initialCategory;
  final List<String> availableCategories;
  final Future<Map<int, List<Episode>>> Function(String) resolveEpisodes;
  final Future<List<VideoSource>> Function(Episode, String) resolveSources;
  final Stream<List<DownloadSourceStatus>> Function(Episode, String)? searchSources;
  final Widget Function(VideoSource, Episode)? previewBuilder;
  @override State<DesktopSingleDownloadDialog> createState() => _DesktopSingleDownloadDialogState();
}

class _DesktopSingleDownloadDialogState extends State<DesktopSingleDownloadDialog> {
  late String _category;
  Episode? _episode;
  // Latest per-source snapshot, in priority order.
  List<DownloadSourceStatus> _rows = const [];
  VideoSource? _selected;
  String? _selectedSourceId;
  // Once the viewer taps a link, late (higher-priority) answers never move it.
  bool _userPicked = false;
  String? _error;
  bool _loading = true;
  bool _searching = false;
  int _request = 0;
  StreamSubscription<List<DownloadSourceStatus>>? _sub;
  @override void initState() { super.initState(); _category = widget.initialCategory; _load(_category); }
  @override void dispose() { _request++; _sub?.cancel(); _doubleTapTimer?.cancel(); super.dispose(); }

  /// Multi-source mode shows which source each link came from.
  bool get _multi => widget.searchSources != null;

  /// Every link of each answering source, SUB and DUB alike (like the
  /// player's Sources sheet), the current cut's kind listed first. Filtering
  /// by the cut hid DUB whenever the title's details had no dub count.
  List<({DownloadSourceStatus row, List<VideoSource> links})> get _options => [
    for (final r in _rows)
      if (r.phase == DownloadSourcePhase.found)
        (row: r, links: orderDownloadLinks(r.streams, _category)),
  ].where((o) => o.links.isNotEmpty).toList();

  /// Download category a link belongs to: its own SUB/DUB kind, else the cut.
  String _categoryOf(VideoSource s) => downloadCategoryForKind(s.kind) ?? _category;

  /// Each cut switch retires both its episode lookup and stream resolution.
  Future<void> _load(String category) async {
    final request = ++_request;
    // Not awaited: cancelling a finished search can settle arbitrarily late.
    unawaited(_sub?.cancel());
    _sub = null;
    if (!mounted || request != _request) return;
    setState(() {
      _category = category; _loading = true; _searching = false; _rows = const [];
      _selected = null; _selectedSourceId = null; _userPicked = false;
      _episode = null; _error = null;
    });
    try {
      final episode = category == widget.initialCategory ? widget.episode
          // Bounded: a hung cut lookup ends in an error with Retry.
          : matchSingleDownloadEpisode(widget.episode, widget.season,
              await widget.resolveEpisodes(category).timeout(const Duration(seconds: 60)));
      if (!mounted || request != _request) return;
      if (episode == null) {
        setState(() { _loading = false; _error = 'No unique matching episode is available in this cut.'; });
        return;
      }
      final stream = widget.searchSources?.call(episode, category) ??
          searchSingleDownloadSource(sourceId: '', name: '',
              resolve: () => widget.resolveSources(episode, category));
      setState(() { _episode = episode; _searching = true; });
      _sub = stream.listen((rows) {
        if (!mounted || request != _request) return;
        setState(() { _rows = rows; _autoSelect(); });
      }, onError: (Object _) {
        // show-13: a source search that throws ends the search here. Links
        // already listed stay pickable; with none, _failed shows Retry.
        if (!mounted || request != _request) return;
        unawaited(_sub?.cancel());
        _sub = null;
        setState(_failed);
      }, onDone: () {
        if (!mounted || request != _request) return;
        setState(() { _searching = false; _loading = false; _finish(); });
      });
    } catch (_) {
      if (!mounted || request != _request) return;
      setState(() { _loading = false; _error = context.l10n.couldntLoadDownloadOptions; });
    }
  }

  /// Highest-priority answering source wins until the viewer picks by hand.
  void _autoSelect() {
    final options = _options;
    if (options.isNotEmpty) _loading = false;
    if (_userPicked && _selected != null) return;
    // First link of the current cut's kind (by source priority), else the
    // first link at all, so the default never jumps to DUB on a SUB page.
    for (final o in options) {
      final match = DownloadManager.sourcesForDownloadCategory(o.links, _category);
      if (match.isNotEmpty) {
        _selected = match.first;
        _selectedSourceId = o.row.sourceId;
        return;
      }
    }
    final first = options.firstOrNull;
    _selected = first?.links.first;
    _selectedSourceId = first?.row.sourceId;
  }

  /// Search over: either links to choose from, or a clear reason plus Retry.
  void _finish() {
    if (_options.isNotEmpty) return;
    final allFailed = _rows.isNotEmpty &&
        _rows.every((r) => r.phase == DownloadSourcePhase.failed);
    _error = allFailed
        ? context.l10n.couldntLoadDownloadOptions
        : _multi ? 'No source had this episode.' : context.l10n.noDownloadSourcesFound;
  }

  /// The search stream errored: stop the spinners and, when nothing usable
  /// arrived, show the load error with Retry (never hang on "Trying...").
  void _failed() {
    _searching = false;
    _loading = false;
    // Sources still marked waiting/trying never answer now: show them failed
    // so their chips stop spinning.
    _rows = [
      for (final r in _rows)
        r.settled ? r : DownloadSourceStatus(sourceId: r.sourceId, name: r.name,
            phase: DownloadSourcePhase.failed, streams: r.streams,
            episodeUrl: r.episodeUrl, showUrl: r.showUrl, detail: r.detail),
    ];
    if (_options.isEmpty) _error = context.l10n.couldntLoadDownloadOptions;
  }

  /// Windows: Enter / numpad Enter starts the download of the selected link.
  bool get _desktopKeys => defaultTargetPlatform == TargetPlatform.windows;

  // Windows double-click detection on a link row. Done by hand so a single
  // click still selects instantly (a DoubleTapGestureRecognizer would delay
  // every single click by the double-tap timeout). A Timer (not the wall
  // clock) marks the double-click window, so it also follows test time.
  ({String sourceId, String url})? _lastTapped;
  Timer? _doubleTapTimer;

  /// Selects [source]; a second click on the same row within the double-tap
  /// window downloads it straight away (Windows only).
  void _onLinkTap(DownloadSourceStatus row, VideoSource source) {
    // Same row = same source and URL; a fresh search snapshot may rebuild
    // the VideoSource objects between the two clicks.
    final tapped = (sourceId: row.sourceId, url: source.url);
    final isDouble = _desktopKeys &&
        _lastTapped == tapped &&
        _doubleTapTimer?.isActive == true;
    _doubleTapTimer?.cancel();
    _doubleTapTimer = null;
    _lastTapped = null;
    if (_desktopKeys && !isDouble) {
      // First click: open the double-click window for this row.
      _lastTapped = tapped;
      _doubleTapTimer = Timer(kDoubleTapTimeout, () => _lastTapped = null);
    }
    setState(() {
      _selected = source; _selectedSourceId = row.sourceId; _userPicked = true;
    });
    if (isDouble) _submit();
  }

  String? get _activeLabel {
    final trying = _rows.where((r) => r.phase == DownloadSourcePhase.trying).toList();
    if (trying.isEmpty) return null;
    return trying.length == 1 ? 'Trying ${trying.single.name}...'
        : 'Trying ${trying.first.name} and ${trying.length - 1} more...';
  }

  Widget _statusChip(DownloadSourceStatus r) {
    // Every link counts (SUB and DUB), matching the rows listed below.
    final links = r.streams.length;
    final busy = r.phase == DownloadSourcePhase.trying;
    final ok = r.phase == DownloadSourcePhase.found && links > 0;
    return Container(
      key: ValueKey('download-source-${r.sourceId}'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: AppColors.surface2,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ok ? AppColors.accent : AppColors.hairline)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (busy) const Padding(padding: EdgeInsets.only(right: 6),
          child: SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5))),
        Text(busy ? r.name : '${r.name} · ${r.phase == DownloadSourcePhase.found && links == 0
            ? 'No ${_category.toUpperCase()} links' : downloadSourcePhaseLabel(r, links)}',
          style: TextStyle(fontSize: 12,
            color: ok ? AppColors.textPrimary : AppColors.textSecondary)),
      ]));
  }

  @override Widget build(BuildContext context) {
    final l10n = context.l10n;
    final selected = _selected;
    final episode = _episode;
    final categories = {widget.initialCategory, ...widget.availableCategories};
    final options = _options;
    final active = _activeLabel;
    final dialog = Dialog(backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(constraints: BoxConstraints(maxWidth: 640,
          maxHeight: MediaQuery.sizeOf(context).height * .85),
        child: Padding(padding: const EdgeInsets.all(24), child: Column(
          mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(l10n.downloadChooseServer, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(widget.episode.title, maxLines: 2, overflow: TextOverflow.ellipsis),
            if (categories.length > 1) Padding(padding: const EdgeInsets.symmetric(vertical: 14),
              child: Wrap(spacing: 8, runSpacing: 8, children: [for (final cat in categories)
                ChoiceChip(label: Text(cat.toUpperCase()), selected: cat == _category,
                  onSelected: (_) { if (cat != _category) _load(cat); })])),
            // Per-source progress: which source is being asked and what each said.
            if (_multi && _rows.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6, bottom: 4),
              child: Wrap(spacing: 6, runSpacing: 6, children: [for (final r in _rows) _statusChip(r)])),
            if (_searching || _loading) Padding(padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const LinearProgressIndicator(),
                if (_multi && active != null) Padding(padding: const EdgeInsets.only(top: 8),
                  child: Text(active, key: const ValueKey('download-search-active'),
                    style: TextStyle(fontSize: 12, color: AppColors.textSecondary))),
              ])),
            if (_error != null) Padding(padding: const EdgeInsets.symmetric(vertical: 16),
              child: Row(children: [
                Expanded(child: Text(_error!, key: const ValueKey('download-search-error'))),
                // A finished search with nothing to offer can be asked again.
                if (!_searching && !_loading) TextButton(
                  key: const ValueKey('download-search-retry'),
                  onPressed: () => _load(_category), child: Text(l10n.retry)),
              ])),
            if (options.isNotEmpty) Flexible(child: ListView(shrinkWrap: true, children: [
              for (final o in options) ...[
                if (_multi) Padding(padding: const EdgeInsets.only(top: 8, bottom: 6),
                  child: Text(o.row.name, style: const TextStyle(fontWeight: FontWeight.w600))),
                for (var i = 0; i < o.links.length; i++) Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _linkTile(o.row, o.links[i], i, selected)),
              ],
            ])),
            if (selected != null && episode != null)
              widget.previewBuilder?.call(selected, episode) ?? DownloadSizePreview(
                source: selected, runtimeMinutes: episode.runtimeMinutes),
            const SizedBox(height: 14),
            Wrap(alignment: WrapAlignment.end, spacing: 12, runSpacing: 8, children: [
              TextButton(onPressed: () => Navigator.pop(context), child: Text(l10n.cancel)),
              FilledButton(onPressed: selected == null || episode == null ? null : _submit,
                child: Text(l10n.download)),
            ]),
          ]))));
    if (!_desktopKeys) return dialog;
    // Windows (show-13): Enter downloads the selected link, like the batch
    // dialog. The autofocus Focus makes the keys reach the shortcuts.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter): _onEnter,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): _onEnter,
      },
      child: Focus(autofocus: true, child: dialog),
    );
  }

  Widget _linkTile(DownloadSourceStatus row, VideoSource source, int i, VideoSource? selected) {
    // Same name the player's Sources sheet shows: "SUB • HD - 1 - 1080p".
    final label = downloadLinkLabel(source);
    final chosen = identical(source, selected);
    return Material(color: chosen ? AppColors.surface2 : AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: chosen ? AppColors.accent : AppColors.hairline)),
      child: ListTile(title: Text(label),
        // Quality is already in the title; the subtitle adds what is not.
        subtitle: Text([if (source.audioLang != null) source.audioLang!,
          source.container.name, if (_multi) row.name].join(' - ')),
        trailing: Icon(chosen ? Icons.radio_button_checked : Icons.radio_button_unchecked,
          color: chosen ? AppColors.accent : AppColors.textSecondary),
        onTap: () => _onLinkTap(row, source)));
  }

  /// Windows Enter: download the selected link once it can be downloaded.
  void _onEnter() {
    if (_selected == null || _episode == null) return;
    _submit();
  }

  /// Pops the pick. Its category is the picked link's own SUB/DUB kind, and
  /// the only fallbacks are links of that same kind and server, so a failed
  /// link can never quietly turn into another server or the other audio.
  void _submit() {
    final selected = _selected, episode = _episode;
    if (selected == null || episode == null) return;
    final option = _options.where((o) => o.row.sourceId == _selectedSourceId).firstOrNull;
    final key = downloadServerKey(selected);
    final sameServer = [
      selected,
      for (final s in option?.links ?? const <VideoSource>[])
        if (s.url != selected.url && downloadServerKey(s) == key) s,
    ];
    // The search may still be running; stop waiting on the other sources.
    _sub?.cancel();
    Navigator.pop(context, (episode: episode, category: _categoryOf(selected), chosen: selected,
      all: sameServer,
      sourceId: _multi ? option?.row.sourceId : null,
      sourceName: _multi ? option?.row.name : null));
  }
}
