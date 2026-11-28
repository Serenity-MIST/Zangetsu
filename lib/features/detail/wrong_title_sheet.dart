import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/desktop/desktop_focus_repair.dart';
import '../../core/app_mode.dart';
import '../../core/desktop/desktop_sheet.dart';
import '../../core/desktop/desktop_undo_toast.dart';
import '../../core/di/injector.dart';
import '../../core/playback/source_health_store.dart';
import '../../core/ui/desktop_docked_panel.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/ui/app_toast.dart';
import '../../core/models/media_item.dart';
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/ui/poster_card.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/ui/reveal_item.dart';
import '../../core/ui/states.dart';
import '../../core/ui/source_switcher.dart';
import '../../core/theme/app_text.dart';
import '../../core/zmode/match_store.dart';
import '../../core/zmode/source_matcher.dart';
import '../../core/zmode/zmode_ids.dart';
import '../../core/zmode/zmode_module.dart';
import '../../l10n/l10n.dart';
import '../sources/zangetsu_sources_screen.dart';
import '../sources/source_picker_row_actions.dart';
import 'cubit/detail_cubit.dart';
import 'cubit/source_select_cubit.dart';
import 'cubit/wrong_title_cubit.dart';

/// "Source: AllAnime ▾  Wrong title?" under a metadata title. Tapping the
/// source name opens a picker of installed sources for this title's kind
/// (each keeping its own remembered match); "Wrong title?" corrects the
/// match for whichever source is currently selected.
class MatchLine extends StatefulWidget {
  const MatchLine({
    super.key,
    required this.canonical,
    required this.title,
    this.altTitle,
    this.malId,
    this.compact = false,
    this.metadataAliases = const [],
  });

  final ZCanonical canonical;
  final String title;
  final String? altTitle;
  final int? malId;
  final bool compact;
  final List<String> metadataAliases;

  @override
  State<MatchLine> createState() => _MatchLineState();
}

class _MatchLineState extends State<MatchLine> {
  late final SourceSelectCubit _cubit = SourceSelectCubit(
    store: sl<MatchStore>(),
    matcher: sl<SourceMatcher>(),
    canonical: widget.canonical,
    sources: candidatesForKind(sl<SourceRepository>(), widget.canonical.kind),
    title: widget.title,
    altTitle: widget.altTitle,
    malId: widget.malId,
    metadataAliases: widget.metadataAliases,
  )..load();

  @override
  void dispose() {
    _cubit.close();
    super.dispose();
  }

  /// Every kind's episode/chapter list is substituted from the matched source
  /// (see `MetadataRepository.detail`) — anime and movie/TV now take their
  /// titles and count from the source too, not just manga/novel. So any
  /// change of selection or correction must re-fetch the Detail screen,
  /// regardless of kind.
  void _refreshAfterMatchChange() =>
      // dropCache: false — the source just switched TO was never in that
      // cache, and clearing it would slow this switch down and every other
      // source with it. Only a deliberate pull-to-refresh wants that.
      context.read<DetailCubit>().refresh(dropCache: false);

  /// Picking a row selects it directly (rather than popping an id for the
  /// caller to act on afterward) so the real store write is a direct
  /// continuation of the tap that triggers it, not of the sheet closing.
  /// Opens the app's own source picker — the same tabbed, searchable sheet the
  /// Home switcher uses, so CloudStream and Aniyomi rows appear here with their
  /// ecosystem labels and repo tags. `onPick` keeps the choice local to this
  /// title: the app's ACTIVE source is deliberately not changed.
  void _pickSource(SourceSelectState state) {
    SourceSwitcher(
      currentId: state.selectedId ?? '',
      onChanged: (_) {},
      onInstallSources: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const ZangetsuSourcesScreen(openToRepos: true),
        ),
      ),
    ).showPicker(
      context,
      trailingBuilder: (id) => SourcePickerRowActions(
        sourceId: id,
        onCloudflareSolved: (_) async {
          if (!mounted) return;
          await _cubit.load();
          if (mounted) _refreshAfterMatchChange();
        },
      ),
      // Auto Resolve sits above the sources rather than among them, because
      // it is not one: it is the absence of a pinned choice, which lets the
      // resolver sweep every source at play time. Picking a source here pins
      // that title to it; this is how you undo that.
      autoSelected: state.auto,
      onAutoResolve: () async {
        await _cubit.selectAuto();
        if (mounted) _refreshAfterMatchChange();
      },
      onPick: (id) async {
        if (!state.auto && id == state.selectedId) return;
        await _cubit.selectSource(id);
        if (mounted) _refreshAfterMatchChange();
      },
    );
  }

  Widget _rowActions(BuildContext _, String id) => SourcePickerRowActions(
    sourceId: id,
    onCloudflareSolved: (_) async {
      if (!mounted) return;
      await _cubit.load();
      if (mounted) _refreshAfterMatchChange();
    },
  );

  Future<void> _fix(String sourceId) async {
    final before = sl<SourceMatcher>().sourceForTitle(widget.canonical);
    // Windows: the title's match entries as they are now, so the "Match
    // saved" toast can Undo a misclick exactly (ar-7). Taken before the
    // sheet opens because picking a result pins (and demotes the old pin)
    // before the sheet even closes.
    final store = sl<MatchStore>();
    final snapshot = desktopPanelsEnabled
        ? store.snapshot(widget.canonical)
        : null;
    final picked = await showWrongTitleSheet(
      context,
      canonical: widget.canonical,
      title: widget.title,
      sourceId: sourceId,
      metadataAliases: widget.metadataAliases,
      malId: widget.malId,
    );
    if (!mounted) return;
    if (picked == null) {
      // Closed without pinning — but the sheet can change the SOURCE on its
      // own, so a stale row here would name the source the user just left.
      if (sl<SourceMatcher>().sourceForTitle(widget.canonical) != before) {
        await _cubit.load();
        if (mounted) _refreshAfterMatchChange();
      }
      return;
    }
    _cubit.applyPinned(picked);
    _refreshAfterMatchChange();
    final message = context.l10n.matchSaved(
      sl<SourceRepository>().displayName(picked.sourceId),
    );
    if (snapshot == null) {
      // Phone / TV: the plain notice, as before.
      showAppToast(context, message);
      return;
    }
    // Windows: remember the title's own name for the Manual matches page,
    // then offer Undo, which puts every entry of this title back as it was
    // (the previous pin included) and refreshes the row and the page.
    // Not awaited: the name is written to memory at once, and the toast
    // should not wait on the disk flush.
    unawaited(store.rememberTitle(widget.canonical, widget.title));
    showUndoToast(
      context,
      message: message,
      onUndo: () async {
        await store.restore(widget.canonical, snapshot);
        if (!mounted) return;
        await _cubit.load();
        if (mounted) _refreshAfterMatchChange();
      },
    );
  }

  bool get _isTv => sl.isRegistered<AppMode>() && sl<AppMode>().isTv;

  /// Source dropdown and "Wrong title?" are separate D-pad targets on TV.
  /// Phone keeps InkWell.
  Widget _tappable({
    required VoidCallback onTap,
    required Widget child,
    required String semanticLabel,
    Key? key,
    double borderRadius = 8,
  }) {
    if (_isTv) {
      return TvFocusable(
        key: key,
        onTap: onTap,
        // Both actions open a sheet that autofocuses a TvFocusable. KeyDown
        // open + KeyUp on that first item would pick/dismiss instantly —
        // same race waitForKeyUp documents on TvFocusable.
        waitForKeyUp: true,
        variant: TvFocusVariant.float,
        scale: 1.02,
        borderRadius: borderRadius,
        semanticLabel: semanticLabel,
        child: ExcludeSemantics(child: child),
      );
    }
    return InkWell(key: key, onTap: onTap, child: child);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return BlocProvider.value(
      value: _cubit,
      child: BlocBuilder<SourceSelectCubit, SourceSelectState>(
        builder: (context, state) {
          if (state.sources.isEmpty) {
            return Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Icon(
                    Icons.hub_outlined,
                    size: 15,
                    color: AppColors.textTertiary,
                  ),
                  const SizedBox(width: 6),
                  // Nothing is INSTALLED — which is not the same as nothing
                  // having the title, and saying the latter blames the show
                  // for the app being empty.
                  Text(l10n.noSourcesInstalled, style: AppText.caption),
                ],
              ),
            );
          }
          if (state.loading && state.selectedId == null) {
            // Hold the row's place. The Detail screen now paints before the
            // source is resolved, so an empty box here left a hole between
            // Download and the synopsis for the whole sweep — which read as
            // "this title has no source selector" rather than "still looking".
            final canStop =
                state.auto &&
                widget.canonical.kind != ZKind.manga &&
                widget.canonical.kind != ZKind.novel;
            final progress = state.progress;
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: Container(
                height: 52,
                padding: const EdgeInsetsDirectional.only(start: 14, end: 4),
                decoration: BoxDecoration(
                  color: AppColors.surface2,
                  borderRadius: BorderRadius.circular(26),
                ),
                child: canStop
                    ? Row(
                        children: [
                          SizedBox(
                            width: 17,
                            height: 17,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.accent,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              progress == null
                                  ? 'Auto Resolve'
                                  : 'Auto Resolve · ${progress.sourceName} · '
                                        '${progress.current}/${progress.total}',
                              style: AppText.button.copyWith(
                                color: AppColors.textPrimary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Tooltip(
                            message: l10n.cancel,
                            child: _tappable(
                              key: const ValueKey('stop-auto-resolve'),
                              onTap: _cubit.stopAutoResolve,
                              semanticLabel: l10n.cancel,
                              borderRadius: 24,
                              child: SizedBox(
                                width: 44,
                                height: 44,
                                child: Icon(
                                  Icons.close_rounded,
                                  size: 20,
                                  color: AppColors.textSecondary,
                                  semanticLabel: l10n.cancel,
                                ),
                              ),
                            ),
                          ),
                        ],
                      )
                    : Container(
                        alignment: AlignmentDirectional.centerStart,
                        child: Container(
                          width: 120,
                          height: 14,
                          decoration: BoxDecoration(
                            color: AppColors.surface,
                            borderRadius: BorderRadius.circular(7),
                          ),
                        ),
                      ),
              ),
            );
          }
          // Candidates exist and the resolve finished, but nothing genuinely
          // matched anywhere and nothing has been picked by hand yet — the
          // row still opens the picker (there IS something to choose from),
          // it just has no source to name yet and nothing for "Wrong title?"
          // to correct until one is picked.
          final selectedId = state.selectedId;
          // Just the name inside the pill — the shape already reads as a
          // control, so a "Source:" prefix only crowds it.
          //
          // Auto Resolve is the primary answer until the user pins a source.
          // A settled candidate (from a prior sweep) may still be known —
          // show it dimmer in parentheses so the pill doesn't read like a
          // manual pick. Hardcoded like the picker's own row
          // (source_switcher.dart) rather than an l10n key, so the two
          // always read the same.
          final autoHint = state.auto && selectedId != null
              ? sl<SourceRepository>().taggedName(selectedId)
              : null;
          final semanticLabel = state.auto
              ? (autoHint == null ? 'Auto Resolve' : 'Auto Resolve ($autoHint)')
              : selectedId == null
              ? l10n.checkedTopSources
              : sl<SourceRepository>().taggedName(selectedId);
          // Sized and filled like _DownloadButton directly above, so Play,
          // Download and Source read as one stack. The row body opens the
          // picker; the trailing icons act on the SELECTED source and are
          // outside that tap target so they never double as a row tap.
          // On TV the full gray dropdown pill is one TvFocusable; "Wrong
          // title?" is a second — D-pad can land on each independently.
          final labelRow = Row(
            children: [
              // Glyph so the pill reads as "this picks your source" on
              // sight — sparkle for Auto Resolve, dns for a pinned pick.
              Icon(
                state.auto ? Icons.auto_awesome_rounded : Icons.dns_rounded,
                size: 16,
                color: AppColors.textSecondary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  state.auto
                      ? 'Auto Resolve'
                      : selectedId == null
                      ? l10n.checkedTopSources
                      : sl<SourceRepository>().taggedName(selectedId),
                  style: AppText.button.copyWith(
                    // Dimmed only when there is no source to name at all; a
                    // source the user picked reads normally even when it
                    // came up empty — the line below the pill says so
                    // outright.
                    color: !state.auto && selectedId == null
                        ? AppColors.textTertiary
                        : AppColors.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // Dimmed candidate + chevron hug the trailing edge so the
              // primary label stays left and the hint/arrow stay right.
              if (autoHint != null) ...[
                const SizedBox(width: 8),
                Flexible(
                  // Fill the allotted space so short names cannot leave an
                  // unused gap after the chevron inside the source button.
                  fit: FlexFit.tight,
                  child: Text(
                    '($autoHint)',
                    textAlign: TextAlign.end,
                    style: AppText.button.copyWith(
                      fontSize: (AppText.button.fontSize ?? 14) - 2,
                      color: AppColors.textTertiary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              const SizedBox(width: 4),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 20,
                color: AppColors.textSecondary,
              ),
            ],
          );
          // Its own side padding, because detail_screen.dart pads each button
          // individually rather than wrapping the Column — this line sits as a
          // plain last child and has to bring its own, or it runs to the edge
          // while Play and Download above it stay inset. TV lays the row out
          // itself and wants the full width.
          return Padding(
            padding: _isTv || widget.compact
                ? EdgeInsets.zero
                : const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (_isTv)
                  Row(
                    children: [
                      Expanded(
                        child: _tappable(
                          key: const ValueKey('tv-match-source'),
                          onTap: () => _pickSource(state),
                          semanticLabel: semanticLabel,
                          child: Material(
                            color: AppColors.surface2,
                            borderRadius: BorderRadius.circular(8),
                            child: SizedBox(
                              height: 52,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                ),
                                child: labelRow,
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (selectedId != null) _rowActions(context, selectedId),
                    ],
                  )
                else
                  Material(
                    color: AppColors.surface2,
                    borderRadius: BorderRadius.circular(26),
                    clipBehavior: Clip.antiAlias,
                    child: SizedBox(
                      height: widget.compact ? 40 : 52,
                      child: Row(
                        children: [
                          Expanded(
                            // The 52 belongs INSIDE the InkWell, exactly as
                            // _DownloadButton has it. A Row hands its children
                            // a loose height, so an InkWell out here shrank to
                            // the text's own ~20px and left a 52px-tall row
                            // with a 20px-tall tap strip — miss the text line
                            // and the tap did nothing.
                            child: InkWell(
                              onTap: () => _pickSource(state),
                              child: SizedBox(
                                height: 52,
                                child: Padding(
                                  padding: const EdgeInsetsDirectional.only(
                                    start: 18,
                                  ),
                                  child: labelRow,
                                ),
                              ),
                            ),
                          ),
                          if (selectedId != null)
                            _rowActions(context, selectedId),
                          const SizedBox(width: 10),
                        ],
                      ),
                    ),
                  ),
                if (selectedId != null)
                  Padding(
                    // Lined up with the pill's text, clear of its rounded ends.
                    padding: _isTv
                        ? EdgeInsets.zero
                        : const EdgeInsetsDirectional.only(
                            start: 18,
                            end: 8,
                            top: 4,
                          ),
                    child: Row(
                      children: [
                        // What the source actually matched, beside the button
                        // that corrects it. Naming only the SOURCE hid the case
                        // this whole control exists for: a confident match on
                        // the wrong show looks identical to a right one — same
                        // source name, a full episode list — until you play it
                        // and get someone else's episodes. Showing the title
                        // makes a bad match visible without opening anything.
                        //
                        // Silent while still resolving: the screen paints before
                        // the match lands, and an unguarded line would claim
                        // "nothing here" for every title during that window.
                        Expanded(
                          child: state.loading
                              ? const SizedBox.shrink()
                              : Text(
                                  state.match?.showTitle.isNotEmpty == true
                                      ? state.match!.showTitle
                                      : l10n.noEpisodesAvailableFromThisSource,
                                  style: AppText.caption.copyWith(
                                    color: AppColors.textSecondary,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                        ),
                        _tappable(
                          key: const ValueKey('tv-match-wrong-title'),
                          onTap: () => _fix(selectedId),
                          semanticLabel: l10n.wrongTitle,
                          borderRadius: 14,
                          child: Padding(
                            // Windows: a bigger target for the mouse.
                            padding: desktopPanelsEnabled
                                ? const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  )
                                : const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 8,
                                  ),
                            child: Text(
                              l10n.wrongTitle,
                              style: AppText.caption.copyWith(
                                color: AppColors.accent,
                              ),
                            ),
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
}

/// Pick a result, correcting the match for exactly [sourceId]. Returns the
/// pinned match.
Future<SourceMatch?> showWrongTitleSheet(
  BuildContext context, {
  required ZCanonical canonical,
  required String title,
  required String sourceId,
  List<String> metadataAliases = const [],
  int? malId,
}) {
  if (desktopPanelsEnabled) {
    // Windows (ar-4): a panel docked to the right of the detail page, so
    // the show's own cover, year and episode count stay visible to compare
    // against while picking. The body brings its own header and close.
    return showAdaptiveSheet<SourceMatch>(
      context,
      desktopStyle: DesktopSheetStyle.sidePanel,
      desktopWidth: _desktopPanelWidth,
      builder: (_) => _WrongTitleBody(
        canonical: canonical,
        initialQuery: title,
        sourceId: sourceId,
        metadataAliases: metadataAliases,
        malId: malId,
      ),
    );
  }
  return showModalBottomSheet<SourceMatch>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _WrongTitleBody(
      canonical: canonical,
      initialQuery: title,
      sourceId: sourceId,
      metadataAliases: metadataAliases,
      malId: malId,
    ),
  );
}

class _WrongTitleBody extends StatelessWidget {
  const _WrongTitleBody({
    required this.canonical,
    required this.initialQuery,
    required this.sourceId,
    required this.metadataAliases,
    required this.malId,
  });
  final ZCanonical canonical;
  final String initialQuery;
  final String sourceId;
  final List<String> metadataAliases;
  final int? malId;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) =>
          WrongTitleCubit(
            sources: sl<SourceRepository>(),
            matcher: sl<SourceMatcher>(),
            canonical: canonical,
            sourceId: sourceId,
            // Status-aware, paged search only where the Windows panel shows
            // its failure messages and "Load more" (not TV, even on Windows).
            statusAware: desktopPanelsEnabled,
          )..search(
            initialQuery,
            retryWithMetadataAliases: true,
            metadataAliases: metadataAliases,
            malId: malId,
          ),
      child: _WrongTitleView(initialQuery: initialQuery),
    );
  }
}

class _WrongTitleView extends StatefulWidget {
  const _WrongTitleView({required this.initialQuery});
  final String initialQuery;
  @override
  State<_WrongTitleView> createState() => _WrongTitleViewState();
}

class _WrongTitleViewState extends State<_WrongTitleView> {
  late final _ctrl = TextEditingController(text: widget.initialQuery);

  /// Focus of the search field, so the Windows panel can start there.
  final FocusNode _field = FocusNode(debugLabel: 'wrong-title-field');

  @override
  void initState() {
    super.initState();
    // Windows panel: put the caret in the search field once the panel is
    // built. A plain `autofocus` loses to the docked panel's Esc handler,
    // which autofocuses its own Focus higher up the tree.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && DesktopSheetScope.of(context)) _field.requestFocus();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _field.dispose();
    _firstResult.dispose();
    for (final n in _cellNodes.values) {
      n.dispose();
    }
    super.dispose();
  }

  /// The result this title is pinned to on the source being searched, so the
  /// poster the user already chose is marked instead of offered again as if
  /// it were new. Read per build rather than held: picking a result rebuilds
  /// this sheet, and the store is the only thing that knows.
  String? _currentUrl(String sourceId) => sl<MatchStore>()
      .get(context.read<WrongTitleCubit>().canonical, sourceId)
      ?.showUrl;

  void _openSourcePicker(WrongTitleCubit cubit) => SourceSwitcher(
    currentId: cubit.sourceId,
    onChanged: (_) {},
    onInstallSources: () => Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const ZangetsuSourcesScreen(openToRepos: true),
      ),
    ),
  ).showPicker(context, onPick: (id) => cubit.setSource(id));

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<WrongTitleCubit>();
    // Matches the Search screen's grid exactly: 3 up, 12 across, 16 down, and
    // the same aspect helper — so a result here is the same object a search
    // result is, at the same size, with the same press animation.
    final cellWidth = posterGridCellWidth(context);
    // Windows side panel (ar-4): fills the docked panel's height instead of
    // 75% of the window, and lays the grid out for the panel's own width.
    final desktop = DesktopSheetScope.of(context);
    if (desktop) {
      return LayoutBuilder(
        builder: (context, box) => SizedBox(
          height: box.maxHeight.isFinite
              ? box.maxHeight
              : MediaQuery.sizeOf(context).height * 0.85,
          child: _content(context, cubit, cellWidth, desktop: true),
        ),
      );
    }
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.75,
          child: _content(context, cubit, cellWidth, desktop: false),
        ),
      ),
    );
  }

  /// Focus of the first result, so Down in the search box can jump into the
  /// grid on Windows (the rest is reached with the arrow keys).
  final FocusNode _firstResult = FocusNode(debugLabel: 'wrong-title-first');

  /// Focus nodes of the other result cells (Windows), by index, kept here so
  /// arrow-key moves can reach a cell and they survive grid rebuilds.
  final Map<int, FocusNode> _cellNodes = {};

  FocusNode _cellNode(int i) => i == 0
      ? _firstResult
      : _cellNodes.putIfAbsent(
          i,
          () => FocusNode(debugLabel: 'wrong-title-result-$i'),
        );

  /// Moves keyboard focus from the search field into the results (Windows).
  KeyEventResult _fieldKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent || e.logicalKey != LogicalKeyboardKey.arrowDown) {
      return KeyEventResult.ignored;
    }
    if (_firstResult.context == null) return KeyEventResult.ignored;
    _firstResult.requestFocus();
    return KeyEventResult.handled;
  }

  /// Header, search field, status line and results; shared by the phone
  /// sheet and the Windows panel ([desktop] adds a close button, keyboard
  /// focus handling, failure messages and "Load more").
  Widget _content(
    BuildContext context,
    WrongTitleCubit cubit,
    double cellWidth, {
    required bool desktop,
  }) {
    final l10n = context.l10n;
    return BlocBuilder<WrongTitleCubit, WrongTitleState>(
      builder: (context, state) {
        final currentUrl = _currentUrl(cubit.sourceId);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 12),
            // Title left, source right, one line. The source used to sit
            // centred underneath as grey text with a caret, which read as
            // a label rather than the button it is.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.whichOneIsIt,
                      style: AppText.headline,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 10),
                  _SourcePill(
                    sourceId: cubit.sourceId,
                    onTap: () => _openSourcePicker(cubit),
                  ),
                  // Windows panel: no drag-to-dismiss, so a close
                  // button like the other desktop panels (Esc works
                  // too).
                  if (desktop)
                    IconButton(
                      key: const ValueKey('wrong-title-close'),
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).closeButtonTooltip,
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.close_rounded),
                      color: AppColors.textSecondary,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              // The metadata Search bar, same shape: a fully rounded
              // surface2 pill with the icon INSIDE it, not an
              // InputDecoration prefix on a boxed field. This sheet is
              // reached from a catalogue title, so it should look like
              // catalogue search rather than like a settings input.
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: AppColors.surface2,
                  borderRadius: BorderRadius.circular(26),
                ),
                child: Row(
                  children: [
                    const SizedBox(width: 14),
                    // A tap target, like the Search screen's: it runs the
                    // query the same as Enter does.
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        DesktopFocusRepair.dropFocus(context);
                        cubit.search(_ctrl.text);
                      },
                      child: const Icon(
                        Icons.search_rounded,
                        size: 20,
                        color: AppColors.textTertiary,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      // Windows: Down moves from the field into the
                      // results (this Focus sees the key before the
                      // app's text-editing shortcuts do).
                      child: Focus(
                        canRequestFocus: false,
                        skipTraversal: true,
                        onKeyEvent: desktop ? _fieldKey : null,
                        child: TextField(
                          controller: _ctrl,
                          // Windows: typing a different name is the
                          // usual next step, so the field starts
                          // focused there (requested after the first
                          // frame in initState: the panel's own Esc
                          // Focus autofocuses first and would win).
                          focusNode: _field,
                          onSubmitted: cubit.search,
                          textInputAction: TextInputAction.search,
                          style: AppText.body.copyWith(
                            color: AppColors.textPrimary,
                          ),
                          cursorColor: AppColors.accent,
                          decoration: InputDecoration(
                            hintText: l10n.searchThisSource,
                            hintStyle: AppText.body,
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 11,
                            ),
                          ),
                        ),
                      ),
                    ),
                    // The field opens pre-filled with the title, so
                    // searching for something else means clearing it
                    // first. Keeps the pill's right inset when hidden.
                    ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _ctrl,
                      builder: (context, value, _) => value.text.isEmpty
                          ? const SizedBox(width: 14)
                          : IconButton(
                              icon: const Icon(
                                Icons.close_rounded,
                                size: 18,
                                color: AppColors.textTertiary,
                              ),
                              tooltip: context.l10n.clear,
                              onPressed: () => _ctrl.clear(),
                            ),
                    ),
                  ],
                ),
              ),
            ),
            // Says which query is running, not merely that one is: a
            // source can take seconds, and after switching source this is
            // the only thing naming what is being re-searched.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
              child: Text(
                state.loading
                    ? '${l10n.searching}: ${state.query}'
                    : l10n.matchResultCount(state.results.length),
                style: AppText.caption.copyWith(color: AppColors.textTertiary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Expanded(
              child: desktop
                  // Windows: focusable cells, failure messages with
                  // Retry and "Load more" (ar-4 / ar-5 / ar-6).
                  ? _DesktopResults(
                      state: state,
                      currentUrl: currentUrl,
                      firstFocus: _firstResult,
                      nodeFor: _cellNode,
                      sourceName: sl<SourceRepository>().displayName(
                        cubit.sourceId,
                      ),
                      onPick: (r) async {
                        final m = await cubit.choose(r);
                        if (context.mounted) {
                          Navigator.of(context).pop(m);
                        }
                      },
                      onChangeSource: () => _openSourcePicker(cubit),
                      onRetry: cubit.retry,
                      onLoadMore: cubit.loadMore,
                      // Up from the top row goes back to the search box.
                      onExitTop: _field.requestFocus,
                    )
                  : _Results(
                      state: state,
                      cellWidth: cellWidth,
                      currentUrl: currentUrl,
                      onPick: (r) async {
                        final m = await cubit.choose(r);
                        if (context.mounted) {
                          Navigator.of(context).pop(m);
                        }
                      },
                      onChangeSource: () => _openSourcePicker(cubit),
                    ),
            ),
          ],
        );
      },
    );
  }
}

/// The source being searched, as a button. Named "Searching X" rather than
/// "Source: X" because that is what it is doing — the results below came from
/// it, and changing it re-runs the query.
class _SourcePill extends StatelessWidget {
  const _SourcePill({required this.sourceId, required this.onTap});
  final String sourceId;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 170),
        padding: const EdgeInsets.fromLTRB(10, 5, 6, 5),
        decoration: BoxDecoration(
          color: AppColors.surface2,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: AppColors.hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The source NAME carries the meaning here — "Searching" is the
            // same on every source — so it gets the readable colour and the
            // verb stays quiet.
            Flexible(
              child: Builder(
                builder: (context) {
                  final name = sl<SourceRepository>().displayName(sourceId);
                  final full = context.l10n.searchingSourceShort(name);
                  final at = full.lastIndexOf(name);
                  // Fall back to one flat span if a translation drops or
                  // reorders the placeholder rather than guessing at a split.
                  if (at < 0) {
                    return Text(
                      full,
                      style: AppText.caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    );
                  }
                  return Text.rich(
                    TextSpan(
                      style: AppText.caption.copyWith(
                        color: AppColors.textTertiary,
                      ),
                      children: [
                        TextSpan(text: full.substring(0, at)),
                        TextSpan(
                          text: name,
                          style: AppText.caption.copyWith(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        TextSpan(text: full.substring(at + name.length)),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  );
                },
              ),
            ),
            Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 16,
              color: AppColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}

/// Results, loading and empty — one widget so the three states can never be
/// shown at once, which is how "no results" used to look identical to "still
/// searching": both drew an empty list.
class _Results extends StatelessWidget {
  const _Results({
    required this.state,
    required this.cellWidth,
    required this.currentUrl,
    required this.onPick,
    required this.onChangeSource,
  });

  final WrongTitleState state;
  final double cellWidth;
  final String? currentUrl;
  final ValueChanged<MediaItem> onPick;
  final VoidCallback onChangeSource;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final aspect = posterCellAspect(
      cellWidth,
      textScaler: MediaQuery.textScalerOf(context),
      wide: posterLayout(context) == PosterCardLayout.wide,
      titleInside: posterTitleInside(
        context,
        wide: posterLayout(context) == PosterCardLayout.wide,
      ),
    );
    final isTv = sl<AppMode>().isTv;
    if (state.results.isEmpty) {
      if (state.loading) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: SkeletonGrid(
            crossAxisCount: posterGridColumns(context),
            childAspectRatio: aspect,
          ),
        );
      }
      return EmptyState(
        icon: Icons.search_off_rounded,
        message: l10n.sourceMayNotCarryIt,
        actionLabel: l10n.chooseSource,
        onAction: onChangeSource,
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      // Both copied from the metadata results grid, and both are why scrolling
      // felt different here: without the cache extent a row is built as it
      // enters the viewport and its cover pops in mid-scroll, and without the
      // dismiss behaviour the keyboard stays up over the results you are
      // scrolling to — this sheet always opens with a focusable field.
      scrollCacheExtent: const ScrollCacheExtent.pixels(800),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: posterGridColumns(context),
        childAspectRatio: aspect,
        crossAxisSpacing: 12,
        mainAxisSpacing: 16,
      ),
      itemCount: state.results.length,
      itemBuilder: (_, i) {
        final r = state.results[i];
        // A source can answer with five results all titled the same — the
        // cover is the only thing that separates them, so it is the whole
        // cell. Marking the one already pinned stops it being re-picked as
        // though it were a different show.
        final isCurrent = currentUrl != null && r.url == currentUrl;
        Widget cell = PosterCard(
          title: r.title,
          logoItem: r,
          imageUrl: r.cover,
          wideImageUrl: r.banner,
          genres: r.genres,
          isAdult: r.isAdult,
          headers: r.coverHeaders,
          cellWidth: cellWidth,
          qualityBadge: r.quality,
          dubBadge: r.dubBadge,
          tags: isCurrent ? [l10n.currentMatchBadge] : const [],
          // On TV the TvFocusable below owns OK, so the card must not also
          // claim the tap — see the TV rails for the same pairing.
          onTap: isTv ? null : () => onPick(r),
        );
        if (isTv) {
          // PosterCard is a bare GestureDetector, which the D-pad cannot
          // reach. The ListTile this replaced was focusable for free, so
          // without this the sheet is unusable on TV — and TV's Detail
          // screen does show "Wrong title?".
          cell = TvFocusable(
            autofocus: i == 0,
            variant: TvFocusVariant.float,
            scale: 1.06,
            onTap: () => onPick(r),
            semanticLabel: r.title,
            child: cell,
          );
        }
        // The same staggered entrance My List uses, so a sheetful of posters
        // cascades in instead of appearing as one block. Self-gating: returns
        // the child untouched on TV or with list animations off.
        return RevealItem(index: i, child: cell);
      },
    );
  }
}

/// Width of the Windows "Wrong title?" side panel: three poster columns,
/// leaving the detail page's own cover and facts visible on the left.
const double _desktopPanelWidth = 600;

/// The Windows results area of "Wrong title?" (ar-4 / ar-5 / ar-6).
///
/// Separate from [_Results] so the phone sheet stays exactly as it was.
/// Adds: a grid laid out for the panel's width with keyboard-focusable cells
/// (visible focus ring, arrows move, Enter picks); its own message and
/// Retry for a timeout, a Cloudflare block and an error, instead of the
/// "this source may not carry it" of a real empty result; and paging
/// ("Load more" at the end, also fetched when scrolled near the end).
class _DesktopResults extends StatelessWidget {
  const _DesktopResults({
    required this.state,
    required this.currentUrl,
    required this.firstFocus,
    required this.sourceName,
    required this.onPick,
    required this.onChangeSource,
    required this.onRetry,
    required this.onLoadMore,
    required this.nodeFor,
    required this.onExitTop,
  });

  final WrongTitleState state;
  final String? currentUrl;

  /// Focus node of the first cell, so Down in the search field lands there.
  final FocusNode firstFocus;

  /// The focus node of the cell at an index (owned by the view's State so
  /// it survives rebuilds); used to move focus with the arrow keys.
  final FocusNode Function(int index) nodeFor;

  /// Called when Up is pressed on the top row.
  final VoidCallback onExitTop;
  final String sourceName;
  final ValueChanged<MediaItem> onPick;
  final VoidCallback onChangeSource;
  final VoidCallback onRetry;
  final VoidCallback onLoadMore;

  /// The failure message for a source that did not really answer.
  String _failureMessage(SourceOutcome failure) => switch (failure) {
    // No context in this helper; appL10n follows the app language.
    SourceOutcome.timeout =>
      appL10n.sourceTookTooLongNamed(sourceName),
    SourceOutcome.blocked =>
      appL10n.sourceBlockedByCloudflare(sourceName),
    _ =>
      appL10n.couldntReachSource(sourceName),
  };

  /// Arrow-key movement inside the grid. Done by index rather than by
  /// Flutter's geometric directional focus, which would jump out of the
  /// grid to the docked panel's own (focusable) Esc handler.
  void _move(int from, TraversalDirection d, int columns) {
    final to = switch (d) {
      TraversalDirection.left => from - 1,
      TraversalDirection.right => from + 1,
      TraversalDirection.up => from - columns,
      TraversalDirection.down => from + columns,
    };
    if (to < 0) {
      if (d == TraversalDirection.up) onExitTop();
      return;
    }
    if (to >= state.results.length) return;
    final node = nodeFor(to);
    // Only cells the lazy grid has built have a context; the cache extent
    // keeps the next rows built, so this is the normal case.
    final ctx = node.context;
    if (ctx == null) return;
    node.requestFocus();
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.5,
      duration: const Duration(milliseconds: 120),
    );
  }

  /// A glyph per failure, so the three cases also look different.
  IconData _failureIcon(SourceOutcome failure) => switch (failure) {
    SourceOutcome.timeout => Icons.hourglass_empty_rounded,
    SourceOutcome.blocked => Icons.shield_outlined,
    _ => Icons.cloud_off_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return LayoutBuilder(
      builder: (context, box) {
        // Columns from the panel's width (the phone helpers read the whole
        // window, which would cram a dozen tiny posters into the panel).
        final width = box.maxWidth.isFinite ? box.maxWidth : _desktopPanelWidth;
        final columns = ((width - 32 + 12) / (150 + 12)).floor().clamp(2, 6);
        final cellWidth = (width - 32 - 12 * (columns - 1)) / columns;
        final aspect = posterCellAspect(
          cellWidth,
          textScaler: MediaQuery.textScalerOf(context),
        );
        if (state.results.isEmpty) {
          if (state.loading) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: SkeletonGrid(
                crossAxisCount: columns,
                childAspectRatio: aspect,
              ),
            );
          }
          final failure = state.failure;
          if (failure != null) {
            // The source failed: say how, and offer the same search again
            // rather than implying the show is not there.
            return _DesktopFailure(
              key: ValueKey('wrong-title-failure-${failure.name}'),
              icon: _failureIcon(failure),
              message: _failureMessage(failure),
              retryLabel: l10n.retry,
              onRetry: onRetry,
              changeLabel: l10n.chooseSource,
              onChangeSource: onChangeSource,
            );
          }
          return EmptyState(
            icon: Icons.search_off_rounded,
            message: l10n.sourceMayNotCarryIt,
            actionLabel: l10n.chooseSource,
            onAction: onChangeSource,
          );
        }
        return NotificationListener<ScrollUpdateNotification>(
          // Near the end of the grid: fetch the next page without waiting
          // for a click (the button below covers short lists).
          onNotification: (n) {
            if (n.metrics.extentAfter < 400 &&
                state.hasMore &&
                !state.loadingMore &&
                !state.loadMoreFailed) {
              onLoadMore();
            }
            return false;
          },
          child: FocusTraversalGroup(
            child: CustomScrollView(
              scrollCacheExtent: const ScrollCacheExtent.pixels(800),
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  sliver: SliverGrid.builder(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      childAspectRatio: aspect,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 16,
                    ),
                    itemCount: state.results.length,
                    itemBuilder: (_, i) {
                      final r = state.results[i];
                      // Same "current match" tag as the phone grid.
                      final isCurrent =
                          currentUrl != null && r.url == currentUrl;
                      return _DesktopResultCell(
                        key: ValueKey('wrong-title-result-$i'),
                        focusNode: i == 0 ? firstFocus : nodeFor(i),
                        semanticLabel: r.title,
                        onActivate: () => onPick(r),
                        onMove: (d) => _move(i, d, columns),
                        child: PosterCard(
                          title: r.title,
                          logoItem: r,
                          imageUrl: r.cover,
                          wideImageUrl: r.banner,
                          genres: r.genres,
                          isAdult: r.isAdult,
                          headers: r.coverHeaders,
                          cellWidth: cellWidth,
                          qualityBadge: r.quality,
                          dubBadge: r.dubBadge,
                          tags: isCurrent ? [l10n.currentMatchBadge] : const [],
                          onTap: () => onPick(r),
                        ),
                      );
                    },
                  ),
                ),
                SliverToBoxAdapter(child: _footer(context)),
              ],
            ),
          ),
        );
      },
    );
  }

  /// End of the grid: a spinner while the next page loads, Retry when it
  /// failed, "Load more" while the source may have more.
  Widget _footer(BuildContext context) {
    Widget? child;
    if (state.loadingMore) {
      child = SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: AppColors.accent,
        ),
      );
    } else if (state.loadMoreFailed) {
      child = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            context.l10n.couldntLoadMoreResults,
            style: AppText.caption.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 6),
          OutlinedButton(
            key: const ValueKey('wrong-title-load-more-retry'),
            onPressed: onLoadMore,
            child: Text(context.l10n.retry),
          ),
        ],
      );
    } else if (state.hasMore) {
      child = OutlinedButton.icon(
        key: const ValueKey('wrong-title-load-more'),
        onPressed: onLoadMore,
        icon: const Icon(Icons.expand_more_rounded, size: 18),
        label: Text(context.l10n.loadMore),
      );
    }
    if (child == null) return const SizedBox(height: 16);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      child: Center(child: child),
    );
  }
}

/// A result poster that the keyboard can reach (Windows): Tab / arrows move
/// focus between cells, Enter or Space picks, and the focused cell shows an
/// accent ring. The mouse still clicks the poster itself.
class _DesktopResultCell extends StatefulWidget {
  const _DesktopResultCell({
    super.key,
    required this.child,
    required this.onActivate,
    required this.semanticLabel,
    required this.onMove,
    this.focusNode,
  });

  final Widget child;
  final VoidCallback onActivate;
  final String semanticLabel;
  final FocusNode? focusNode;

  /// An arrow key was pressed on this cell (the grid moves focus).
  final ValueChanged<TraversalDirection> onMove;

  @override
  State<_DesktopResultCell> createState() => _DesktopResultCellState();
}

// Keyboard focus ring state for a Windows search result cell.
class _DesktopResultCellState extends State<_DesktopResultCell> {
  /// True while focus came from the keyboard (no ring for mouse clicks).
  bool _highlight = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: widget.semanticLabel,
      child: FocusableActionDetector(
        focusNode: widget.focusNode,
        // Enter / Space map to ActivateIntent through the app's default
        // shortcuts; picking a result is the cell's only action.
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onActivate();
              return null;
            },
          ),
          // Arrows arrive as DirectionalFocusIntent from the app's default
          // shortcuts; the grid moves by index instead (see _move).
          DirectionalFocusIntent: CallbackAction<DirectionalFocusIntent>(
            onInvoke: (intent) {
              widget.onMove(intent.direction);
              return null;
            },
          ),
        },
        onShowFocusHighlight: (v) => setState(() => _highlight = v),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          foregroundDecoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: _highlight ? AppColors.accent : Colors.transparent,
              width: 2.5,
            ),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// "The source failed" message of the Windows panel: icon, what went wrong,
/// Retry and a way to pick another source.
class _DesktopFailure extends StatelessWidget {
  const _DesktopFailure({
    super.key,
    required this.icon,
    required this.message,
    required this.retryLabel,
    required this.onRetry,
    required this.changeLabel,
    required this.onChangeSource,
  });

  final IconData icon;
  final String message;
  final String retryLabel;
  final VoidCallback onRetry;
  final String changeLabel;
  final VoidCallback onChangeSource;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: AppColors.textTertiary),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center, style: AppText.body),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                FilledButton.icon(
                  key: const ValueKey('wrong-title-retry'),
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: Text(retryLabel),
                ),
                TextButton(onPressed: onChangeSource, child: Text(changeLabel)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
