import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'frosted_sheet.dart';

import '../models/video_source.dart';
import 'copy_playback_link.dart';
import '../desktop/desktop_context_menu.dart';
import 'desktop_docked_panel.dart';
import '../playback/external_player.dart';
import '../playback/source_selection.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../../l10n/l10n.dart';

/// What a long-press on an episode chose: which player to open it in, this
/// once. An empty [package] means the built-in player.
typedef PlayerChoice = ({String package, String label});

/// What the long-press menu was asked to do. The player pick is its own sheet,
/// so this only carries the actions that don't need further input.
enum EpisodeAction {
  /// Open the "play this episode with" sheet.
  pickPlayer,

  /// Drop this episode's cached links and play again. For when a mirror has
  /// expired and every attempt fails on links that looked fine 20 minutes ago.
  reloadLinks,

  /// Flip this episode's watched state by hand, and move any connected
  /// tracker with it.
  toggleWatched,

  /// Mark this episode and everything before it watched — the "came back
  /// mid-season" case, where marking twelve episodes one at a time is the
  /// reason people give up and edit their list on the website instead.
  markAboveWatched,

  /// Resolve the episode's mirrors and pick one before anything plays, rather
  /// than starting on whichever the app chose and switching afterwards.
  playMirror,

  /// Open this chapter's page on the source's own site, in the in-app
  /// browser. Reading only — for when the reader can't render it.
  openInBrowser,

  /// Ask every installed source whether it has THIS episode, and watch them
  /// answer. Different from [playMirror]: that picks between mirrors within
  /// the one source already matched, this is about which SOURCE to use at all.
  whereToWatch,

  /// Windows menu only: play this episode the normal way (same as a click).
  play,

  /// Windows menu only: start downloading this episode.
  download,

  /// Windows menu only: delete this episode's finished download.
  deleteDownload,

  /// Windows menu only: open Explorer with the downloaded file selected.
  showInFolder,
}

/// Where this episode's download stands, for the Windows right-click menu.
/// The caller looks it up so the menu can offer the right download rows.
enum EpisodeDownloadMenuState {
  /// No download rows at all (reading, or downloads not offered here).
  unavailable,

  /// Nothing saved yet: offer Download.
  none,

  /// Queued or downloading: shown as a disabled row, nothing to act on.
  inProgress,

  /// A finished file exists: offer Show in folder and Delete download.
  done,

  /// A saved copy exists but is broken (file gone, or a tiny stub), so it
  /// does not count as downloaded: offer Download again and Delete download,
  /// but nothing that plays or treats it as a real file.
  broken,
}

/// The long-press menu itself. Kept separate from the player sheet so the
/// player list doesn't push the actions off-screen once several players are
/// installed.
Future<EpisodeAction?> showEpisodeActionSheet(
  BuildContext context, {
  required String episodeLabel,
  required String currentPlayerLabel,

  /// Offers the "Where to watch" row. Only true for metadata titles: a
  /// source-backed one already IS a single source, so there is nothing to
  /// survey.
  bool canSurveySources = false,

  /// Drives the watched row's wording — the same row unmarks when the episode
  /// is already watched, so a mis-tap isn't a one-way door.
  required bool isWatched,

  /// Whether any tracker is linked. Only used for the subtitle, so nobody is
  /// surprised that marking an episode moved their AniList progress.
  required bool tracksToServices,

  /// Whether this chapter has a page that can be opened on the source's own
  /// site. Reading only; hidden rather than greyed, because a source that keys
  /// chapters by an internal id has nothing to open.
  bool canOpenInBrowser = false,

  /// Manga/novel. Leaves ONLY the two marking rows, reworded as read rather
  /// than watched. Everything above them is about playback — a chapter
  /// resolves to the reader, so there is no player to pick, no mirror to
  /// choose, no stream to reload, and no point surveying sources for one.
  bool reading = false,

  /// Windows menu only: which download rows to show. The phone sheet ignores
  /// it, so phones keep exactly the rows they had.
  EpisodeDownloadMenuState downloadState = EpisodeDownloadMenuState.unavailable,
}) {
  // Windows (right-click / long-press an episode): a compact context menu at
  // the mouse pointer (position null -> DesktopPointer's last click), like
  // every other right-click menu on Windows. It also carries the download
  // rows the phone sheet never had.
  if (desktopPanelsEnabled) {
    return showDesktopContextMenu<EpisodeAction>(
      context,
      items: episodeDesktopMenuItems(
        isWatched: isWatched,
        reading: reading,
        canSurveySources: canSurveySources,
        canOpenInBrowser: canOpenInBrowser,
        downloadState: downloadState,
      ),
    );
  }
  // Without isScrollControlled a sheet is capped at 9/16 of the screen
  // (_kDefaultScrollControlDisabledMaxHeightRatio) and anything past that is
  // simply clipped — no scrolling, no warning. These rows come to ~493dp once
  // the tracker subtitle is on, which needs an ~876dp-tall screen to clear the
  // cap. Most phones are shorter, so "Mark this and all above as watched" was
  // cut off the bottom edge. Same treatment showEpisodePlayerSheet below
  // already gets, for the same reason.
  return showModalBottomSheet<EpisodeAction>(
    context: context,
    backgroundColor: _frostedSheets ? Colors.transparent : AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    isScrollControlled: true,
    builder: (sheetContext) => _sheetSurface(
      SafeArea(
        child: ConstrainedBox(
          // Not full height: the list is short, and keeping the episode list
          // visible behind it is what makes this read as a menu.
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.7,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 10),
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.hairline,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      episodeLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.headline,
                    ),
                  ),
                ),
                if (!reading) ...[
                  _PlayerRow(
                    icon: Icons.play_circle_outline_rounded,
                    label: 'Play with…',
                    trailingText: currentPlayerLabel,
                    onTap: () =>
                        Navigator.pop(sheetContext, EpisodeAction.pickPlayer),
                  ),
                  _PlayerRow(
                    icon: Icons.swap_horiz_rounded,
                    label: 'Play mirror',
                    subtitle: 'Choose the source before it starts',
                    onTap: () =>
                        Navigator.pop(sheetContext, EpisodeAction.playMirror),
                  ),
                ],
                // Streaming only, like the two rows above it: reading gets the
                // marking rows and nothing else.
                if (canSurveySources && !reading)
                  _PlayerRow(
                    icon: Icons.travel_explore_rounded,
                    label: 'Where to watch',
                    subtitle: 'See which of your sources has this episode',
                    onTap: () =>
                        Navigator.pop(sheetContext, EpisodeAction.whereToWatch),
                  ),
                if (!reading)
                  _PlayerRow(
                    icon: Icons.refresh_rounded,
                    label: 'Reload links',
                    subtitle: 'Fetch fresh streams if playback keeps failing',
                    onTap: () =>
                        Navigator.pop(sheetContext, EpisodeAction.reloadLinks),
                  ),
                Divider(height: 1, color: AppColors.hairline),
                _PlayerRow(
                  icon: isWatched
                      ? Icons.remove_done_rounded
                      : Icons.check_circle_outline_rounded,
                  label: reading
                      ? (isWatched ? 'Mark as unread' : 'Mark as read')
                      : (isWatched ? 'Mark as unwatched' : 'Mark as watched'),
                  subtitle: tracksToServices
                      ? 'Also updates your connected trackers'
                      : null,
                  onTap: () =>
                      Navigator.pop(sheetContext, EpisodeAction.toggleWatched),
                ),
                _PlayerRow(
                  icon: Icons.done_all_rounded,
                  label: reading
                      ? 'Mark this and all above as read'
                      : 'Mark this and all above as watched',
                  onTap: () => Navigator.pop(
                    sheetContext,
                    EpisodeAction.markAboveWatched,
                  ),
                ),
                if (reading && canOpenInBrowser)
                  _PlayerRow(
                    icon: Icons.public_rounded,
                    label: 'Open in browser',
                    subtitle: "Read it on the source's own site",
                    onTap: () => Navigator.pop(
                      sheetContext,
                      EpisodeAction.openInBrowser,
                    ),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// The rows of the Windows episode right-click menu. Public so tests can
/// check which rows a given download state produces without opening a menu.
///
/// Order: playback first (Play is what a click does, so it leads), then the
/// download rows for the episode's current download state, then the marking
/// rows. Reading keeps only the marking rows plus Open in browser, like the
/// phone sheet.
@visibleForTesting
List<DesktopMenuItem<EpisodeAction>> episodeDesktopMenuItems({
  required bool isWatched,
  bool reading = false,
  bool canSurveySources = false,
  bool canOpenInBrowser = false,
  EpisodeDownloadMenuState downloadState = EpisodeDownloadMenuState.unavailable,
}) => [
  // Labels use appL10n (no context here); it follows the app language.
  if (!reading) ...[
    DesktopMenuItem(
      label: appL10n.play,
      icon: Icons.play_arrow_rounded,
      value: EpisodeAction.play,
    ),
    DesktopMenuItem(
      label: appL10n.playMirror,
      icon: Icons.swap_horiz_rounded,
      value: EpisodeAction.playMirror,
    ),
    // Metadata titles only, same rule as the phone sheet.
    if (canSurveySources)
      DesktopMenuItem(
        label: appL10n.whereToWatch,
        icon: Icons.travel_explore_rounded,
        value: EpisodeAction.whereToWatch,
      ),
    DesktopMenuItem(
      label: appL10n.reloadLinks,
      icon: Icons.refresh_rounded,
      value: EpisodeAction.reloadLinks,
    ),
    // Download rows follow what is actually saved for this episode.
    if (downloadState != EpisodeDownloadMenuState.unavailable) ...[
      const DesktopMenuItem<EpisodeAction>.divider(),
      ...switch (downloadState) {
        EpisodeDownloadMenuState.none => [
          DesktopMenuItem(
            label: appL10n.download,
            icon: Icons.download_rounded,
            value: EpisodeAction.download,
          ),
        ],
        // Already queued: say so instead of offering a second download.
        EpisodeDownloadMenuState.inProgress => [
          DesktopMenuItem<EpisodeAction>(
            label: appL10n.downloading,
            icon: Icons.downloading_rounded,
            enabled: false,
          ),
        ],
        EpisodeDownloadMenuState.done => [
          DesktopMenuItem(
            label: appL10n.showInFolder,
            icon: Icons.folder_open_rounded,
            value: EpisodeAction.showInFolder,
          ),
          DesktopMenuItem(
            label: appL10n.deleteDownload,
            icon: Icons.delete_outline_rounded,
            value: EpisodeAction.deleteDownload,
            destructive: true,
          ),
        ],
        // A broken saved copy: fetch it again, look at it, or remove it
        // (same delete and confirm as a finished file). Never Play offline.
        EpisodeDownloadMenuState.broken => [
          DesktopMenuItem(
            label: appL10n.download,
            icon: Icons.download_rounded,
            value: EpisodeAction.download,
          ),
          DesktopMenuItem(
            label: appL10n.showInFolder,
            icon: Icons.folder_open_rounded,
            value: EpisodeAction.showInFolder,
          ),
          DesktopMenuItem(
            label: appL10n.deleteDownload,
            icon: Icons.delete_outline_rounded,
            value: EpisodeAction.deleteDownload,
            destructive: true,
          ),
        ],
        EpisodeDownloadMenuState.unavailable =>
          const <DesktopMenuItem<EpisodeAction>>[],
      },
    ],
    const DesktopMenuItem<EpisodeAction>.divider(),
  ],
  DesktopMenuItem(
    label: reading
        ? (isWatched ? appL10n.markAsUnread : appL10n.markAsRead)
        : (isWatched ? appL10n.markAsUnwatched : appL10n.markAsWatched),
    icon: isWatched
        ? Icons.remove_done_rounded
        : Icons.check_circle_outline_rounded,
    value: EpisodeAction.toggleWatched,
  ),
  DesktopMenuItem(
    label: reading ? appL10n.markThisAndAboveRead : appL10n.markAllAboveWatched,
    icon: Icons.done_all_rounded,
    value: EpisodeAction.markAboveWatched,
  ),
  if (reading && canOpenInBrowser) ...[
    const DesktopMenuItem<EpisodeAction>.divider(),
    DesktopMenuItem(
      label: appL10n.openInBrowser,
      icon: Icons.public_rounded,
      value: EpisodeAction.openInBrowser,
    ),
  ],
];

/// Long-press an episode → pick where it plays, for this episode only.
///
/// Deliberately doesn't touch [PlaybackPrefs.externalPlayerPackage]: Settings
/// stays the place that says "always use X", and trying VLC once shouldn't
/// quietly rewire every future tap.
///
/// Returns null when dismissed — a long-press that starts playback on its own
/// would be a trap.
Future<PlayerChoice?> showEpisodePlayerSheet(
  BuildContext context, {
  required String episodeLabel,
  required String defaultPackage,
}) async {
  final installed = await ExternalPlayer().installed();
  if (!context.mounted) return null;

  return showModalBottomSheet<PlayerChoice>(
    context: context,
    backgroundColor: _frostedSheets ? Colors.transparent : AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    // The list is short, but a device with several players installed plus a
    // long episode title shouldn't push the last row off-screen.
    isScrollControlled: true,
    builder: (sheetContext) => _sheetSurface(
      SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.7,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 10),
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.hairline,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 2),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      'Play this episode with',
                      style: AppText.headline,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      episodeLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                ),
                _PlayerRow(
                  icon: Icons.play_circle_outline_rounded,
                  label: 'Built-in player',
                  isDefault: defaultPackage.isEmpty,
                  onTap: () => Navigator.pop(sheetContext, (
                    package: '',
                    label: 'Built-in player',
                  )),
                ),
                for (final p in installed.where((p) => p.known))
                  _PlayerRow(
                    icon: Icons.open_in_new_rounded,
                    label: p.label,
                    isDefault: defaultPackage == p.package,
                    onTap: () => Navigator.pop(sheetContext, (
                      package: p.package,
                      label: p.label,
                    )),
                  ),
                // Everything else on the device that answers a video intent. They
                // play — header-gated streams too, via the local proxy — but we
                // don't know which intent extras they read, so external subtitles
                // and the resume position may be ignored. Under their own heading
                // because some are galleries or browsers rather than players at
                // all, hence "apps", not "players".
                if (installed.any((p) => !p.known)) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(
                        'Other apps',
                        style: AppText.caption.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                  ),
                  for (final p in installed.where((p) => !p.known))
                    _PlayerRow(
                      icon: Icons.open_in_new_rounded,
                      label: p.label,
                      isDefault: defaultPackage == p.package,
                      onTap: () => Navigator.pop(sheetContext, (
                        package: p.package,
                        label: p.label,
                      )),
                    ),
                ],
                // Opening an empty sheet on long-press reads as a broken gesture,
                // so say why there's only one row rather than showing nothing.
                if (installed.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                    child: Text(
                      'No other video apps installed. VLC, MX Player and '
                      'Just Player all show up here once installed.',
                      style: AppText.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// Pick one of an episode's resolved mirrors.
///
/// Opens with whatever is resolved already. [live] (optional) is a list that
/// keeps growing while the sheet is open; rows are lazy and fixed-height so a
/// long list and frequent additions stay cheap, and the scroll position
/// survives each addition. [loadingMore] drives the thin progress line.
Future<VideoSource?> showMirrorSheet(
  BuildContext context, {
  required String episodeLabel,
  required List<VideoSource> sources,
  ValueListenable<List<VideoSource>>? live,
  ValueListenable<bool>? loadingMore,
}) {
  // Windows: the right-docked graphite panel (title row + close, Esc and
  // click-outside close) instead of a phone drag-handle sheet. It follows
  // [live] the same way, so late mirrors still fill in.
  if (desktopPanelsEnabled) {
    final listenables = <Listenable>[?live, ?loadingMore];
    return _showEpisodeDesktopPanel<VideoSource>(
      context,
      dialogKey: const ValueKey('mirror-desktop-panel'),
      title: 'Play mirror',
      subtitle: episodeLabel,
      refresh: listenables.isEmpty ? null : Listenable.merge(listenables),
      rows: (panelContext) => [
        if (loadingMore?.value == true)
          LinearProgressIndicator(
            minHeight: 2,
            color: AppColors.accent,
            backgroundColor: DesktopPanelColors.edge,
          ),
        ..._desktopMirrorRows(panelContext, live?.value ?? sources),
      ],
    );
  }
  return showModalBottomSheet<VideoSource>(
    context: context,
    backgroundColor: _frostedSheets ? Colors.transparent : AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    isScrollControlled: true,
    builder: (sheetContext) => _sheetSurface(
      _MirrorSheet(
        episodeLabel: episodeLabel,
        initial: sources,
        live: live,
        loadingMore: loadingMore,
      ),
    ),
  );
}

/// Windows mirror panel rows: one per mirror, grouped by audio kind and
/// sorted by quality, labelled like the phone sheet. Long-press or
/// right-click copies the playback link.
List<Widget> _desktopMirrorRows(
  BuildContext panelContext,
  List<VideoSource> sources,
) => [
  for (final k in availableKinds(sources))
    for (final s in sortByQuality(sourcesForKind(sources, k)))
      _PlayerRow(
        icon: Icons.play_arrow_rounded,
        // Same shape the player's own Sources sheet uses: the provider's
        // mirror name when it has one, otherwise the audio kind — and never
        // a stray "UNKNOWN •" for sources that don't declare sub/dub.
        label: s.label?.trim().isNotEmpty == true
            ? s.label!.trim()
            : '${k != AudioKind.unknown ? '${k.name.toUpperCase()} • ' : ''}'
                  '${s.quality ?? s.container.name.toUpperCase()}',
        subtitle: s.label?.trim().isNotEmpty == true ? s.quality : null,
        onTap: () => Navigator.pop(panelContext, s),
        onLongPress: () => copyPlaybackLink(panelContext, s.url),
        onSecondaryTap: () => copyPlaybackLink(panelContext, s.url),
      ),
];

class _MirrorSheet extends StatefulWidget {
  const _MirrorSheet({
    required this.episodeLabel,
    required this.initial,
    this.live,
    this.loadingMore,
  });

  final String episodeLabel;
  final List<VideoSource> initial;
  final ValueListenable<List<VideoSource>>? live;
  final ValueListenable<bool>? loadingMore;

  @override
  State<_MirrorSheet> createState() => _MirrorSheetState();
}

class _MirrorSheetState extends State<_MirrorSheet> {
  // Sorted rows are rebuilt only when the list changes, not on every repaint.
  List<VideoSource>? _forList;
  List<({AudioKind kind, VideoSource source})> _rows = const [];

  List<({AudioKind kind, VideoSource source})> _rowsFor(
    List<VideoSource> list,
  ) {
    if (!identical(list, _forList)) {
      _forList = list;
      _rows = [
        for (final k in availableKinds(list))
          for (final s in sortByQuality(sourcesForKind(list, k)))
            (kind: k, source: s),
      ];
    }
    return _rows;
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.75,
        ),
        child: ValueListenableBuilder<List<VideoSource>>(
          valueListenable:
              widget.live ?? ValueNotifier<List<VideoSource>>(widget.initial),
          builder: (context, list, _) {
            final rows = _rowsFor(list);
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 10),
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.hairline,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 2),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text('Play mirror', style: AppText.headline),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      widget.episodeLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                ),
                // Fixed 2px slot: the line comes and goes without moving the
                // list below it.
                SizedBox(
                  height: 2,
                  child: widget.loadingMore == null
                      ? null
                      : ValueListenableBuilder<bool>(
                          valueListenable: widget.loadingMore!,
                          builder: (_, on, _) => on
                              ? LinearProgressIndicator(
                                  minHeight: 2,
                                  color: AppColors.accent,
                                  backgroundColor: AppColors.hairline,
                                )
                              : const SizedBox.shrink(),
                        ),
                ),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(bottom: 8),
                    itemCount: rows.length,
                    itemBuilder: (context, i) {
                      final k = rows[i].kind;
                      final s = rows[i].source;
                      final hasLabel = s.label?.trim().isNotEmpty == true;
                      return _PlayerRow(
                        icon: Icons.play_arrow_rounded,
                        // Same shape the player's own Sources sheet uses: the
                        // provider's mirror name when it has one, otherwise
                        // the audio kind — never a stray "UNKNOWN •".
                        label: hasLabel
                            ? s.label!.trim()
                            : '${k != AudioKind.unknown ? '${k.name.toUpperCase()} • ' : ''}'
                                  '${s.quality ?? s.container.name.toUpperCase()}',
                        subtitle: hasLabel ? s.quality : null,
                        onTap: () => Navigator.pop(context, s),
                        onLongPress: () => copyPlaybackLink(context, s.url),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _PlayerRow extends StatelessWidget {
  const _PlayerRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.onLongPress,
    this.onSecondaryTap,
    this.isDefault = false,
    this.subtitle,
    this.trailingText,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// Right-click action (Windows panels only; null leaves the tile as is).
  final VoidCallback? onSecondaryTap;

  /// Marks the row a plain tap would have used. Marked rather than sorted to
  /// the top, so the list doesn't reshuffle when the Settings default changes.
  final bool isDefault;
  final String? subtitle;
  final String? trailingText;

  @override
  Widget build(BuildContext context) {
    final trailing = trailingText ?? (isDefault ? 'Default' : null);
    final tile = ListTile(
      leading: Icon(icon, color: AppColors.textSecondary),
      title: Text(label, style: AppText.body),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              style: AppText.caption.copyWith(color: AppColors.textSecondary),
            ),
      trailing: trailing == null
          ? null
          : Text(
              trailing,
              style: AppText.caption.copyWith(color: AppColors.textSecondary),
            ),
      onTap: onTap,
      onLongPress: onLongPress,
    );
    if (onSecondaryTap == null) return tile;
    return GestureDetector(onSecondaryTap: onSecondaryTap, child: tile);
  }
}

/// Windows target. Uses the target platform, not the host OS, so phone tests
/// on a Windows host keep the plain phone sheet. (Windows itself takes the
/// docked panels and context menu; only TV mode would still reach a sheet.)
bool get _frostedSheets => defaultTargetPlatform == TargetPlatform.windows;

/// Applies the desktop translucent sheet surface without altering mobile sheets.
Widget _sheetSurface(Widget child) =>
    _frostedSheets ? FrostedSheet(child: child) : child;

/// Windows: an episode menu opens as the right-docked graphite panel (title
/// row + close button, Esc and click-outside close) instead of a phone
/// drag-handle sheet. [rows] receives the panel's context for popping. When
/// [refresh] is given, the rows are rebuilt each time it notifies (a mirror
/// list that keeps filling in while the panel is open).
Future<T?> _showEpisodeDesktopPanel<T>(
  BuildContext context, {
  required Key dialogKey,
  required String title,
  String? subtitle,
  required List<Widget> Function(BuildContext panelContext) rows,
  Listenable? refresh,
}) => showDesktopDockedPanel<T>(
  context,
  dialogKey: dialogKey,
  builder: (panelContext) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      DesktopPanelTitleBar(title: title, subtitle: subtitle),
      Divider(height: 1, color: DesktopPanelColors.edge),
      Flexible(
        child: refresh == null
            ? ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 6),
                children: rows(panelContext),
              )
            : ListenableBuilder(
                listenable: refresh,
                builder: (_, _) => ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  children: rows(panelContext),
                ),
              ),
      ),
    ],
  ),
);
