import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zangetsu_source_bridge/stremio.dart';

import '../../core/app_mode.dart';
import '../../core/ui/copy_playback_link.dart';
import '../../core/di/injector.dart';
import '../../core/models/video_source.dart';
import '../../core/stremio/stremio_link_session.dart';
import '../../core/stremio/stremio_manager.dart';
import '../../core/stremio/stremio_addon_icon.dart';
import '../../core/stremio/stremio_ref.dart';
import '../../core/stremio/stremio_stream_mapping.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/app_toast.dart';
import '../../core/ui/desktop_docked_panel.dart';
import '../../core/desktop/desktop_context_menu.dart';
import 'stremio_link_filters.dart';
import '../../l10n/l10n.dart';

/// Stremio-owned titles bypass the normal extension resolver: Play, Resume
/// and episode taps open this grouped links sheet instead.
bool usesStremioLinks(String sourceId, {VideoSource? initialSource}) =>
    sourceId == stremioSourceId && initialSource == null;

/// Links grouped by addon, ordered by installation. Returns the exact chosen
/// source (with its headers) or null when dismissed.
///
/// [onDownloadLink] (Windows only) adds "Download this link" to a link's
/// right-click menu; the panel closes and the chosen source is handed to it.
Future<VideoSource?> showStremioEpisodeLinksSheet(
  BuildContext context, {
  required StremioManager manager,
  required StremioRef ref,
  required String title,
  List<StremioStream> inlineStreams = const [],
  String? bannerUrl,
  Map<String, String>? bannerHeaders,
  ValueChanged<VideoSource>? onDownloadLink,
}) {
  // Windows: the right-docked graphite panel used by the player menus (Esc
  // and click-outside close), not a phone bottom sheet.
  if (desktopPanelsEnabled) {
    return showDesktopDockedPanel<VideoSource>(
      context,
      width: 520,
      dialogKey: const ValueKey('stremio-links-desktop-panel'),
      builder: (_) => _StremioLinksSheet(
        manager: manager,
        ref: ref,
        title: title,
        inlineStreams: inlineStreams,
        bannerUrl: bannerUrl,
        bannerHeaders: bannerHeaders,
        desktop: true,
        onDownloadLink: onDownloadLink,
      ),
    );
  }
  return showModalBottomSheet<VideoSource>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (_) => _StremioLinksSheet(
      manager: manager,
      ref: ref,
      title: title,
      inlineStreams: inlineStreams,
      bannerUrl: bannerUrl,
      bannerHeaders: bannerHeaders,
    ),
  );
}

class _StremioLinksSheet extends StatefulWidget {
  const _StremioLinksSheet({
    required this.manager,
    required this.ref,
    required this.title,
    required this.inlineStreams,
    this.bannerUrl,
    this.bannerHeaders,
    this.desktop = false,
    this.onDownloadLink,
  });

  final StremioManager manager;
  final StremioRef ref;
  final String title;
  final List<StremioStream> inlineStreams;

  /// Windows docked panel: no drag handle, banner melts into the panel fill.
  final bool desktop;

  /// Wide header art. Display-only; null keeps the plain text header.
  final String? bannerUrl;
  final Map<String, String>? bannerHeaders;

  /// Windows: target of the right-click "Download this link" entry.
  final ValueChanged<VideoSource>? onDownloadLink;

  @override
  State<_StremioLinksSheet> createState() => _StremioLinksSheetState();
}

class _StremioLinksSheetState extends State<_StremioLinksSheet> {
  StremioLinkSession? _session;
  StreamSubscription<StremioLinkGroup>? _subscription;
  List<StremioLinkGroup> _groups = const [];
  var _done = false;
  var _picked = false;
  var _dismissed = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    _subscription?.cancel();
    _session?.dispose();
    final session = widget.manager.openLinks(
      widget.ref,
      inlineStreams: widget.inlineStreams,
    );
    _session = session;
    _groups = session.currentGroups;
    _done = false;
    _subscription = session.groups.listen((group) {
      if (!mounted) return;
      setState(() {
        _groups = [
          for (final current in _groups)
            if (current.installation.id == group.installation.id)
              group
            else
              current,
        ];
      });
    });
    session.done.then((_) {
      if (mounted && identical(_session, session)) setState(() => _done = true);
    });
  }

  @override
  void dispose() {
    _dismissed = true;
    _subscription?.cancel();
    _session?.dispose();
    _searchController.dispose();
    super.dispose();
  }

  // Windows panel filters (show-9). Phones never show the controls, so
  // these stay at their "show everything in addon order" defaults there.
  StremioLinkQuality? _quality;
  String _query = '';
  StremioLinkSort _sort = StremioLinkSort.addonOrder;
  final TextEditingController _searchController = TextEditingController();

  /// True while any Windows filter or sort changes what the list shows.
  bool get _filtering =>
      widget.desktop &&
      (_quality != null ||
          _query.trim().isNotEmpty ||
          _sort != StremioLinkSort.addonOrder);

  /// The group's playable links after the Windows quality/search filters.
  List<StremioLinkChoice> _shown(StremioLinkGroup group) {
    final playable = _playable(group);
    if (!widget.desktop) return playable;
    return filterStremioLinks(
      playable,
      quality: _quality,
      query: _query,
      addonName: (_) => group.installation.name,
    );
  }

  /// Resets every Windows filter back to "everything, addon order".
  void _clearFilters() {
    _searchController.clear();
    setState(() {
      _quality = null;
      _query = '';
      _sort = StremioLinkSort.addonOrder;
    });
  }

  /// Builds the playable source for [choice], or null when the session moved
  /// on (it then restarts) or the link can't play here.
  VideoSource? _sourceFor(StremioLinkChoice choice) {
    if (_session?.isCurrent(choice) != true) {
      setState(_start);
      return null;
    }
    return stremioVideoSource(
      choice,
      streamAddonName: widget.manager.byId(choice.installationId)?.name,
      allowTorrent: _allowTorrent,
    );
  }

  /// Windows right-click menu for a link (show-9): Play, Copy link, Copy
  /// title, Open in browser and, when the caller supports it, Download.
  Future<void> _showLinkMenu(StremioLinkChoice choice, Offset position) {
    final url = stremioVideoSource(choice)?.url;
    final webUrl = url != null && url.startsWith(RegExp('https?://'))
        ? url
        : null;
    return showDesktopContextMenu<void>(
      context,
      position: position,
      items: [
        DesktopMenuItem(
          label: context.l10n.play,
          icon: Icons.play_arrow_rounded,
          onTap: () => _choose(choice),
        ),
        if (widget.onDownloadLink != null)
          DesktopMenuItem(
            label: context.l10n.downloadThisLink,
            icon: Icons.file_download_outlined,
            onTap: () => _download(choice),
          ),
        const DesktopMenuItem.divider(),
        DesktopMenuItem(
          label: context.l10n.copyLink,
          icon: Icons.link_rounded,
          enabled: url != null && url.isNotEmpty,
          onTap: () => _copyChoiceLink(context, choice),
        ),
        DesktopMenuItem(
          label: context.l10n.copyTitle,
          icon: Icons.content_copy_rounded,
          onTap: () => _copyTitle(choice),
        ),
        DesktopMenuItem(
          label: context.l10n.openInBrowser,
          icon: Icons.open_in_new_rounded,
          enabled: webUrl != null,
          onTap: () => _openInBrowser(webUrl!),
        ),
      ],
    );
  }

  /// Hands the link to the caller's download path and closes the panel.
  void _download(StremioLinkChoice choice) {
    final onDownload = widget.onDownloadLink;
    if (onDownload == null || _picked || _dismissed) return;
    final source = _sourceFor(choice);
    if (source == null) return;
    _picked = true;
    // Close first (returning no source, so nothing plays), then download.
    Navigator.of(context).pop();
    onDownload(source);
  }

  /// Copies the link's name/description, e.g. to search a release group.
  Future<void> _copyTitle(StremioLinkChoice choice) async {
    try {
      await Clipboard.setData(ClipboardData(text: stremioLinkTitle(choice)));
      if (mounted) showAppToast(context, context.l10n.titleCopied);
    } on PlatformException {
      if (mounted) showAppToast(context, context.l10n.couldNotCopyTitle);
    }
  }

  /// Opens a direct http(s) link in the default browser.
  Future<void> _openInBrowser(String url) async {
    final uri = Uri.tryParse(url);
    var opened = false;
    if (uri != null) {
      try {
        opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {
        opened = false;
      }
    }
    if (!opened && mounted) {
      showAppToast(context, context.l10n.couldNotOpenLink);
    }
  }

  bool get _allowTorrent =>
      Platform.isAndroid && !(sl.isRegistered<AppMode>() && sl<AppMode>().isTv);

  void _choose(StremioLinkChoice choice) {
    if (_picked || _dismissed) return;
    if (_session?.isCurrent(choice) != true) {
      setState(_start);
      return;
    }
    if (stremioVideoSource(choice, allowTorrent: _allowTorrent) == null) {
      return;
    }
    final source = stremioVideoSource(
      choice,
      streamAddonName: widget.manager.byId(choice.installationId)?.name,
      allowTorrent: _allowTorrent,
    );
    if (source == null) {
      return;
    }
    widget.manager.rememberSubtitleStream(
      choice.ref,
      source.url,
      choice.stream,
    );
    _picked = true;
    Navigator.of(context).pop(source);
  }

  int _tab = 0;

  /// Playable choices of one group, in session order (TV hides torrents).
  List<StremioLinkChoice> _playable(StremioLinkGroup group) => [
    for (final choice in group.choices)
      if (choice.stream.kind == StremioStreamKind.direct ||
          (_allowTorrent && choice.stream.kind == StremioStreamKind.torrent))
        choice,
  ];

  /// Windows filter bar: search field + sort dropdown, then resolution chips
  /// with how many links each would leave. Chips with no links are hidden
  /// unless selected, so a short list doesn't sprout empty filters.
  Widget _desktopFilterBar(Map<StremioLinkQuality, int> counts) {
    final sortLabel = stremioLinkSortLabel(_sort);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 34,
                  child: TextField(
                    key: const ValueKey('stremio-links-search'),
                    controller: _searchController,
                    onChanged: (v) => setState(() => _query = v),
                    style: AppText.body,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: context.l10n.searchLinksHint,
                      hintStyle: AppText.caption.copyWith(
                        color: AppColors.textTertiary,
                      ),
                      prefixIcon: const Icon(Icons.search_rounded, size: 18),
                      prefixIconConstraints: const BoxConstraints(
                        minWidth: 34,
                      ),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              tooltip: context.l10n.clearSearch,
                              iconSize: 16,
                              icon: const Icon(Icons.close_rounded),
                              onPressed: () {
                                _searchController.clear();
                                setState(() => _query = '');
                              },
                            ),
                      filled: true,
                      fillColor: AppColors.surface2,
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Sort dropdown: a compact menu anchored below the button.
              Builder(
                builder: (anchor) => Tooltip(
                  message: context.l10n.sortLinks,
                  child: InkWell(
                    key: const ValueKey('stremio-links-sort'),
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => showDesktopContextMenu<StremioLinkSort>(
                      context,
                      anchor: anchor,
                      items: [
                        for (final sort in StremioLinkSort.values)
                          DesktopMenuItem(
                            label: stremioLinkSortLabel(sort),
                            value: sort,
                            checked: sort == _sort,
                            onTap: () {
                              if (mounted) setState(() => _sort = sort);
                            },
                          ),
                      ],
                    ),
                    child: Container(
                      height: 34,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: AppColors.surface2,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.sort_rounded, size: 16),
                          const SizedBox(width: 6),
                          Text(sortLabel, style: AppText.caption),
                          const Icon(Icons.arrow_drop_down_rounded, size: 18),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 32,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _FilterChip(
                  id: 'quality:any',
                  label: context.l10n.anyQuality,
                  selected: _quality == null,
                  onTap: () => setState(() => _quality = null),
                ),
                for (final quality in StremioLinkQuality.values)
                  if ((counts[quality] ?? 0) > 0 || _quality == quality)
                    _FilterChip(
                      id: 'quality:${quality.name}',
                      label:
                          '${stremioLinkQualityLabel(quality)} '
                          '${counts[quality] ?? 0}',
                      selected: _quality == quality,
                      // Clicking the selected chip again clears it.
                      onTap: () => setState(
                        () => _quality = _quality == quality ? null : quality,
                      ),
                    ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Groups only ever resolve in place, so the tab index can't dangle —
    // clamp anyway so a removed addon can't point past the end.
    final tab = _tab.clamp(0, _groups.length);
    final visible = tab == 0 ? _groups : [_groups[tab - 1]];
    // One flat row list for a single virtualized ListView: headers, cards,
    // placeholders and footers are all items, so a 300-link addon still only
    // builds what's on screen.
    final rows = <_SheetRow>[];
    final playable = [
      for (final group in visible)
        for (final choice in _playable(group)) choice,
    ];
    // Windows filters: what survives quality chips + search, for the
    // "nothing matches" row and the chip counts.
    final shownCount = _filtering
        ? visible.fold<int>(0, (n, group) => n + _shown(group).length)
        : playable.length;
    // Search narrows the counts, quality doesn't, so a chip shows how many
    // links it would leave for the current search.
    final qualityCounts = widget.desktop
        ? countStremioLinkQualities([
            for (final group in visible)
              ...filterStremioLinks(
                _playable(group),
                query: _query,
                addonName: (_) => group.installation.name,
              ),
          ])
        : const <StremioLinkQuality, int>{};
    // Best match first (hidden while Windows filters reorder the list, since
    // the addon's first link may not even match them).
    if (playable.isNotEmpty && tab == 0 && !_filtering) {
      final first = playable.first;
      rows.add(
        _BestRow(
          choice: first,
          installationName: _groups
              .firstWhere((g) => g.installation.id == first.installationId)
              .installation
              .name,
        ),
      );
    }
    final sortBySize = widget.desktop && _sort != StremioLinkSort.addonOrder;
    if (sortBySize) {
      // Windows size sort: one flat list across the visible addons, each
      // card still naming its addon. Addons still loading or failed keep
      // their header + placeholder/error rows underneath.
      final groupOf = {for (final g in visible) g.installation.id: g};
      final sorted = sortStremioLinks([
        for (final group in visible) ..._shown(group),
      ], _sort);
      for (final choice in sorted) {
        rows.add(
          _CardRow(
            group: groupOf[choice.installationId]!,
            choice: choice,
            key: ValueKey('link:${choice.installationId}:${choice.label}'),
          ),
        );
      }
      for (final group in visible) {
        if (_playable(group).isNotEmpty) continue;
        final pending = group.state == StremioLinkGroupState.pending;
        final failed =
            group.state == StremioLinkGroupState.error ||
            group.state == StremioLinkGroupState.stale;
        if (!pending && !failed) continue;
        rows.add(_HeaderRow(group: group, count: 0));
        rows.add(pending ? const _PendingRow() : _ErrorRow(group: group));
      }
    } else {
      for (final group in visible) {
        final all = _playable(group);
        // Windows filters may hide some of the group's links.
        final choices = _filtering ? _shown(group) : all;
        rows.add(_HeaderRow(group: group, count: choices.length));
        if (group.state == StremioLinkGroupState.pending && all.isEmpty) {
          rows.add(const _PendingRow());
        }
        if ((group.state == StremioLinkGroupState.error ||
                group.state == StremioLinkGroupState.stale) &&
            all.isEmpty) {
          rows.add(_ErrorRow(group: group));
        }
        for (final choice in choices) {
          rows.add(
            _CardRow(
              group: group,
              choice: choice,
              key: ValueKey('link:${choice.installationId}:${choice.label}'),
            ),
          );
        }
        if (all.isEmpty &&
            group.state != StremioLinkGroupState.pending &&
            group.state != StremioLinkGroupState.error &&
            group.state != StremioLinkGroupState.stale) {
          rows.add(const _EmptyRow());
        }
      }
    }
    // Windows: links exist but the filters hide all of them.
    if (_filtering && playable.isNotEmpty && shownCount == 0) {
      rows.add(const _FilteredEmptyRow());
    }
    if (_done && playable.isEmpty) {
      // An error row already carries its own retry; the footer button is
      // only for the silent-empty case.
      final hasErrorRow = visible.any(
        (group) =>
            (group.state == StremioLinkGroupState.error ||
                group.state == StremioLinkGroupState.stale) &&
            _playable(group).isEmpty,
      );
      rows.add(_DoneEmptyRow(showRetry: !hasErrorRow));
    }
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.8,
        child: Column(
          children: [
            // Drag handle only on phones; the Windows panel has none.
            if (!widget.desktop &&
                (widget.bannerUrl == null || widget.bannerUrl!.isEmpty)) ...[
              const SizedBox(height: 10),
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.textTertiary.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ],
            if (widget.bannerUrl != null && widget.bannerUrl!.isNotEmpty)
              _BannerHeader(
                bannerUrl: widget.bannerUrl!,
                bannerHeaders: widget.bannerHeaders,
                title: widget.title,
                subtitle: _countsLine(playable.length, _groups.length),
                fade: widget.desktop
                    ? DesktopPanelColors.surface
                    : AppColors.surface,
                onClose: () {
                  _dismissed = true;
                  Navigator.of(context).pop();
                },
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 12, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.title,
                            style: AppText.headline,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _countsLine(playable.length, _groups.length),
                            style: AppText.caption.copyWith(
                              color: AppColors.textTertiary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () {
                        _dismissed = true;
                        Navigator.of(context).pop();
                      },
                    ),
                  ],
                ),
              ),
            SizedBox(
              height: 38,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                children: [
                  _FilterChip(
                    label: 'All',
                    selected: tab == 0,
                    onTap: () => setState(() => _tab = 0),
                  ),
                  for (var i = 0; i < _groups.length; i++)
                    _FilterChip(
                      icon: StremioAddonIcon(
                        url: _groups[i].installation.logo,
                        size: 16,
                      ),
                      label: _groups[i].installation.name,
                      selected: tab == i + 1,
                      onTap: () => setState(() => _tab = i + 1),
                    ),
                ],
              ),
            ),
            // Windows: search, sort and resolution chips (show-9).
            if (widget.desktop) _desktopFilterBar(qualityCounts),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                itemCount: rows.length,
                itemBuilder: (context, index) {
                  final row = rows[index];
                  switch (row) {
                    case _BestRow(:final choice, :final installationName):
                      return _Entrance(
                        index: 0,
                        child: _BestCard(
                          choice: choice,
                          installationName: installationName,
                          onTap: () => _choose(choice),
                          onContextMenu: widget.desktop
                              ? (at) => _showLinkMenu(choice, at)
                              : null,
                        ),
                      );
                    case _HeaderRow(:final group, :final count):
                      return _SectionHeader(group: group, count: count);
                    case _PendingRow():
                      return const Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [_SkeletonCard(), _SkeletonCard()],
                      );
                    case _ErrorRow(:final group):
                      return Container(
                        margin: const EdgeInsets.only(top: 8),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: AppColors.textTertiary.withValues(
                              alpha: 0.4,
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                group.error ?? 'Failed',
                                style: AppText.body,
                              ),
                            ),
                            TextButton(
                              onPressed: _start,
                              child: const Text('Retry'),
                            ),
                          ],
                        ),
                      );
                    case _CardRow(:final group, :final choice):
                      return _Entrance(
                        // Identity on the wrapper: rebuilds never replay the
                        // entrance, late answers still fade in once.
                        key: ValueKey(
                          'link:${choice.installationId}:${choice.label}',
                        ),
                        index: index,
                        child: _LinkCard(
                          choice: choice,
                          installationName: group.installation.name,
                          onTap: () => _choose(choice),
                          onContextMenu: widget.desktop
                              ? (at) => _showLinkMenu(choice, at)
                              : null,
                        ),
                      );
                    case _FilteredEmptyRow():
                      // Windows: the filters hide every link; offer a reset.
                      return Column(
                        key: const ValueKey('stremio-links-filtered-empty'),
                        children: [
                          const SizedBox(height: 12),
                          Text(
                            context.l10n.noLinksMatchFilters,
                            style: AppText.caption,
                          ),
                          TextButton(
                            onPressed: _clearFilters,
                            child: Text(context.l10n.clearFilters),
                          ),
                        ],
                      );
                    case _EmptyRow():
                      return Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text('No links', style: AppText.caption),
                      );
                    case _DoneEmptyRow(:final showRetry):
                      return Column(
                        children: [
                          const SizedBox(height: 12),
                          Text(
                            'No playable links found',
                            style: AppText.caption,
                          ),
                          if (showRetry)
                            TextButton(
                              onPressed: _start,
                              child: const Text('Retry'),
                            ),
                        ],
                      );
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One virtualized row of the links list (headers, cards, placeholders,
/// footers) so a 300-link addon only builds what's on screen.
sealed class _SheetRow {
  const _SheetRow({this.key});
  final Key? key;
}

class _BestRow extends _SheetRow {
  const _BestRow({required this.choice, required this.installationName});
  final StremioLinkChoice choice;
  final String installationName;
}

class _HeaderRow extends _SheetRow {
  const _HeaderRow({required this.group, required this.count});
  final StremioLinkGroup group;
  final int count;
}

class _PendingRow extends _SheetRow {
  const _PendingRow();
}

class _ErrorRow extends _SheetRow {
  const _ErrorRow({required this.group});
  final StremioLinkGroup group;
}

class _CardRow extends _SheetRow {
  const _CardRow({super.key, required this.group, required this.choice});
  final StremioLinkGroup group;
  final StremioLinkChoice choice;
}

class _EmptyRow extends _SheetRow {
  const _EmptyRow();
}

class _DoneEmptyRow extends _SheetRow {
  const _DoneEmptyRow({this.showRetry = true});
  final bool showRetry;
}

/// Windows: every link is hidden by the quality/search filters.
class _FilteredEmptyRow extends _SheetRow {
  const _FilteredEmptyRow();
}

/// One-shot entrance: fade + slight rise, staggered by row index.
/// Stable keys keep rebuilds from replaying it; always settles.
class _Entrance extends StatelessWidget {
  const _Entrance({super.key, required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final delay = Duration(milliseconds: (index.clamp(0, 8)) * 30);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 260),
      curve: Interval(
        delay.inMilliseconds / 500,
        1,
        curve: Curves.easeOutCubic,
      ),
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, 10 * (1 - value)),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

/// Human-readable size with GB support, e.g. "8.4 GB" / "512 MB" / "0 B".
/// Local to this sheet: the shared cache formatter caps at MB.
String _formatStreamSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

/// One filter pill: All or a single addon with its live link count.
class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.id,
  });

  final Widget? icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// Stable key part when [label] carries a changing count; defaults to it.
  final String? id;

  @override
  Widget build(BuildContext context) {
    final foreground = selected ? AppColors.accent : AppColors.textPrimary;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        key: ValueKey('filter-chip:${id ?? label}'),
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? AppColors.accentSoft : AppColors.surface2,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected ? AppColors.accent : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (icon != null) ...[icon!, const SizedBox(width: 5)],
              Text(
                label,
                style: AppText.caption.copyWith(
                  fontWeight: FontWeight.w700,
                  color: foreground,
                ),
                softWrap: false,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The first playable choice, one tap to play — same pick path as its card.
class _BestCard extends StatelessWidget {
  const _BestCard({
    required this.choice,
    required this.installationName,
    required this.onTap,
    this.onContextMenu,
  });

  final StremioLinkChoice choice;
  final String installationName;
  final VoidCallback onTap;

  /// Windows: opens the link menu at this global position (right-click).
  final ValueChanged<Offset>? onContextMenu;

  @override
  Widget build(BuildContext context) {
    final menu = onContextMenu;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        onLongPress: () => _copyChoiceLink(context, choice),
        // Windows: right-click opens the link menu (Play, Copy, ...).
        onSecondaryTapUp: menu == null
            ? null
            : (details) => menu(details.globalPosition),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.accent.withValues(alpha: 0.4)),
            color: AppColors.surface2,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'BEST MATCH',
                      style: AppText.caption.copyWith(
                        color: AppColors.accent,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      choice.label,
                      style: AppText.body.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _metaLine(choice, installationName),
                      style: AppText.caption.copyWith(
                        color: AppColors.textTertiary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.accent,
                ),
                child: const Icon(
                  Icons.play_arrow_rounded,
                  color: Colors.black,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Slim addon header; cards are sibling rows so long groups stay virtualized.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.group, required this.count});

  final StremioLinkGroup group;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 2),
      child: Row(
        children: [
          StremioAddonIcon(url: group.installation.logo, size: 18),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              group.installation.name.toUpperCase(),
              style: AppText.caption.copyWith(
                fontWeight: FontWeight.w800,
                color: AppColors.textTertiary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (group.state == StremioLinkGroupState.pending && count == 0)
            const SizedBox.shrink()
          else if (group.state == StremioLinkGroupState.error ||
              group.state == StremioLinkGroupState.stale)
            // With no choices the error row below carries the message;
            // repeating it here would double it.
            if (count > 0)
              Text(
                group.error ?? 'Failed',
                style: AppText.caption.copyWith(color: AppColors.textTertiary),
              )
            else
              const SizedBox.shrink()
          else
            Text(
              '$count',
              style: AppText.caption.copyWith(color: AppColors.textTertiary),
            ),
        ],
      ),
    );
  }
}

/// Card-shaped loading skeleton: headline-width and meta-width bars echoing
/// a real link card's shape, with a shine sweep while it is visible.
class _SkeletonCard extends StatelessWidget {
  const _SkeletonCard();

  @override
  Widget build(BuildContext context) {
    final bar = AppColors.textTertiary.withValues(alpha: 0.22);
    Widget line(double width, double height) => Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        color: bar,
      ),
    );
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: AppColors.surface2,
      ),
      child: _Shine(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            line(150, 14),
            const SizedBox(height: 8),
            line(double.infinity, 11),
            const SizedBox(height: 6),
            line(200, 11),
            const SizedBox(height: 6),
            line(110, 11),
          ],
        ),
      ),
    );
  }
}

/// A shine band sweeping left to right across [child]. Runs a few sweeps
/// then parks: a looping ticker would never settle and would hang widget
/// tests on pumpAndSettle. Disposal (rows resolving) stops it sooner.
class _Shine extends StatefulWidget {
  const _Shine({required this.child});

  final Widget child;

  @override
  State<_Shine> createState() => _ShineState();
}

class _ShineState extends State<_Shine> with SingleTickerProviderStateMixin {
  static const _maxSweeps = 4;
  late final AnimationController _controller = AnimationController(
    duration: const Duration(milliseconds: 1000),
    vsync: this,
  );
  var _sweeps = 0;

  @override
  void initState() {
    super.initState();
    _controller.addStatusListener(_onStatus);
    _controller.forward();
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    if (++_sweeps >= _maxSweeps) {
      _controller.stop();
      return;
    }
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => ShaderMask(
        blendMode: BlendMode.srcATop,
        shaderCallback: (rect) {
          // A soft white band sliding across a window wider than the card
          // so it enters and exits cleanly.
          final slide = -rect.width + _controller.value * rect.width * 3;
          return LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [
              Colors.white.withValues(alpha: 0),
              Colors.white.withValues(alpha: 0.35),
              Colors.white.withValues(alpha: 0),
            ],
            stops: const [0.0, 0.5, 1.0],
          ).createShader(Rect.fromLTWH(slide, 0, rect.width, rect.height));
        },
        child: child,
      ),
      child: widget.child,
    );
  }
}

/// A selectable stream with addon formatting and an optional size badge.
class _LinkCard extends StatelessWidget {
  const _LinkCard({
    required this.choice,
    required this.installationName,
    required this.onTap,
    this.onContextMenu,
  });

  final StremioLinkChoice choice;
  final String installationName;
  final VoidCallback onTap;

  /// Windows: opens the link menu at this global position (right-click).
  final ValueChanged<Offset>? onContextMenu;

  @override
  Widget build(BuildContext context) {
    final menu = onContextMenu;
    final stream = choice.stream;
    final headline = stream.name?.trim().isNotEmpty == true
        ? stream.name!
        : installationName;
    final description = stream.description;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        onLongPress: () => _copyChoiceLink(context, choice),
        // Windows: right-click opens the link menu (Play, Copy, ...).
        onSecondaryTapUp: menu == null
            ? null
            : (details) => menu(details.globalPosition),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: AppColors.surface2,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                headline,
                style: AppText.body.copyWith(fontWeight: FontWeight.w700),
              ),
              if (description != null && description.trim().isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  description,
                  style: AppText.body.copyWith(color: AppColors.textSecondary),
                ),
              ],
              if (stream.videoSize != null && stream.videoSize! > 0) ...[
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(7),
                      color: AppColors.surface,
                    ),
                    child: Text(
                      'SIZE ${_formatStreamSize(stream.videoSize!)}',
                      style: AppText.caption.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Copies a link row's playback URL (long-press, or the Windows link menu).
void _copyChoiceLink(BuildContext context, StremioLinkChoice choice) {
  final source = stremioVideoSource(choice);
  if (source != null) copyPlaybackLink(context, source.url);
}

String _countsLine(int links, int addons) =>
    '$links link${links == 1 ? '' : 's'} · '
    '$addons addon${addons == 1 ? '' : 's'}';

/// Full-bleed header art melting into the background; title sits over
/// the fade, close floats top-right.
class _BannerHeader extends StatelessWidget {
  const _BannerHeader({
    required this.bannerUrl,
    required this.title,
    required this.subtitle,
    required this.onClose,
    required this.fade,
    this.bannerHeaders,
  });

  final String bannerUrl;
  final Map<String, String>? bannerHeaders;
  final String title;
  final String subtitle;
  final VoidCallback onClose;

  /// Fill the art melts into: the sheet or the Windows panel surface.
  final Color fade;

  @override
  Widget build(BuildContext context) {
    final surface = fade;
    // Explicit top rounding: the banner bleeds to the sheet's top edge, so
    // it must carry the sheet's own corner radius itself.
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
      child: SizedBox(
        height: 142,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.network(
              bannerUrl,
              headers: bannerHeaders,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => ColoredBox(color: AppColors.surface2),
            ),
            // Legibility scrim up top, then a melt into the sheet background
            // along the bottom edge — no line where the image ends.
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.25),
                    Colors.black.withValues(alpha: 0.45),
                    surface.withValues(alpha: 0.85),
                    surface,
                  ],
                  stops: const [0.0, 0.55, 0.85, 1.0],
                ),
              ),
            ),
            Positioned(
              top: 10,
              right: 10,
              child: Tooltip(
                message: 'Close',
                child: InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: onClose,
                  child: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.black.withValues(alpha: 0.45),
                    ),
                    child: const Icon(
                      Icons.close_rounded,
                      color: Colors.white,
                      size: 16,
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: AppText.headline.copyWith(color: Colors.white),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    subtitle,
                    style: AppText.caption.copyWith(
                      color: Colors.white.withValues(alpha: 0.75),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _metaLine(StremioLinkChoice choice, String installationName) {
  final size = choice.stream.videoSize;
  final subCount = choice.stream.subtitles.length;
  return [
    installationName,
    if (size != null) _formatStreamSize(size),
    if (subCount > 0) '$subCount subs',
  ].join(' · ');
}
