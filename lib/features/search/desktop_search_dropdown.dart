import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/di/injector.dart';
import '../../core/models/media_item.dart';
import '../../core/models/provider_info.dart';
import '../../core/models/watch_status.dart';
import '../../core/playback/list_status_store.dart';
import '../../core/playback/my_list.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/desktop_docked_panel.dart';
import '../../core/ui/desktop_media_card.dart';
import '../../l10n/l10n.dart';
import '../detail/detail_screen.dart';
import 'bloc/search_state.dart' show SearchMeta;
import 'desktop_quick_search.dart';

/// How long typing has to pause before the quick lookup runs.
const Duration kDesktopQuickSearchDebounce = Duration(milliseconds: 250);

/// Shorter text than this closes the panel instead of searching.
const int kDesktopQuickSearchMinChars = 2;

/// Windows top-bar search dropdown (mockup q2): while typing in the shell's
/// search box it shows the top few matches under the box, plus a
/// "See all results" row that opens the full results page.
///
/// It wraps the existing TextField ([child]) and never takes focus itself:
/// * Up/Down move a highlight, Enter opens the highlighted title (or, with
///   nothing or "See all" highlighted, calls [onSeeAll]), Esc closes it.
///   Keys are only taken while the panel is open, so Enter with the panel
///   closed still reaches the field's own onSubmitted and Up/Down keep their
///   caret behaviour.
/// * Mouse hover highlights a row, a click opens it. The panel sits in a
///   [TextFieldTapRegion], so clicking it does not count as clicking outside
///   the field (which would unfocus the box and close the panel first).
/// * The panel opens only when the TEXT changes (not when the box merely
///   gains focus with old text), closes when the box loses focus, and closes
///   on Esc, on a pick and on "See all".
///
/// Off Windows, or without a [controller] / [focusNode], [child] is
/// returned untouched, so phone and TV keep their search exactly as before.
class DesktopSearchDropdown extends StatefulWidget {
  const DesktopSearchDropdown({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onSeeAll,
    required this.child,
    this.onOpenItem,
    this.quickSearch,
    this.enabled,
  });

  /// The top-bar box's controller (nullable: the shell's is optional).
  final TextEditingController? controller;

  /// The top-bar box's focus node (nullable: the shell's is optional).
  final FocusNode? focusNode;

  /// Opens the full results page for the given text.
  final ValueChanged<String> onSeeAll;

  /// The search TextField this dropdown hangs under.
  final Widget child;

  /// Opens a picked title. Null pushes [DetailScreen.route] on the nearest
  /// navigator (the app has one root navigator, so this lands on top).
  final ValueChanged<MediaItem>? onOpenItem;

  /// The lookup to use. Null builds the real one ([defaultQuickSearch]).
  final DesktopQuickSearch? quickSearch;

  /// Forces the dropdown on or off; null means "Windows only".
  final bool? enabled;

  @override
  State<DesktopSearchDropdown> createState() => _DesktopSearchDropdownState();
}

class _DesktopSearchDropdownState extends State<DesktopSearchDropdown> {
  /// Ties the floating panel to the box's position.
  final LayerLink _link = LayerLink();

  /// Shows and hides the panel in the nearest Overlay.
  final OverlayPortalController _portal = OverlayPortalController();

  /// Measures the box so the panel can match its width.
  final GlobalKey _fieldKey = GlobalKey();

  /// The lookup in use (owned here unless one was passed in).
  late DesktopQuickSearch _quick = widget.quickSearch ?? DesktopQuickSearch();

  /// Pending debounce for the next lookup.
  Timer? _debounce;

  /// The text the last change was seen for, so caret / selection moves (which
  /// also notify the controller) do not restart a lookup.
  String _lastText = '';

  /// The query the panel is showing (or loading) matches for.
  String _query = '';

  /// Matches for [_query]; empty while the first answer is loading.
  List<MediaItem> _items = const [];

  /// For an installed-sources lookup: which source found each of [_items].
  List<String> _sourceNames = const [];

  /// The lookup in flight; cancelled when a newer one starts or the panel
  /// closes (which also stops an installed-sources fan-out).
  StreamSubscription<QuickSearchResult>? _watch;

  /// True while a lookup for [_query] is in flight (including while more
  /// installed sources may still add titles under the ones shown).
  bool _loading = false;

  /// Installed sources still answering (0 for a catalogue lookup).
  int _pendingSources = 0;

  /// True when the last lookup failed.
  bool _failed = false;

  /// True when no installed source of the mode is on for search.
  bool _noSources = false;

  /// Keyboard / hover highlight: 0..n-1 are titles, n is "See all", -1 none.
  int _highlight = -1;

  /// Whether the dropdown is active at all on this platform.
  bool get _active =>
      (widget.enabled ?? defaultTargetPlatform == TargetPlatform.windows) &&
      widget.controller != null &&
      widget.focusNode != null;

  /// Whether the panel is currently shown.
  bool get _open => _portal.isShowing;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  @override
  void didUpdateWidget(DesktopSearchDropdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.focusNode != widget.focusNode) {
      _detach(oldWidget);
      _attach();
    }
    if (oldWidget.quickSearch != widget.quickSearch) {
      _quick = widget.quickSearch ?? DesktopQuickSearch();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _watch?.cancel();
    _quick.cancel();
    _detach(widget);
    super.dispose();
  }

  /// Starts listening to the box's text and focus.
  void _attach() {
    if (!_active) return;
    _lastText = widget.controller!.text;
    widget.controller!.addListener(_onText);
    widget.focusNode!.addListener(_onFocus);
  }

  /// Stops listening to [w]'s box.
  void _detach(DesktopSearchDropdown w) {
    w.controller?.removeListener(_onText);
    w.focusNode?.removeListener(_onFocus);
  }

  /// Text changed: debounce a lookup, or close for too-short text.
  void _onText() {
    final text = widget.controller!.text;
    if (text == _lastText) return; // Caret or selection move only.
    _lastText = text;
    // Programmatic changes while the box is not focused (the shell filling
    // it in) must not pop a panel over the page.
    if (!widget.focusNode!.hasFocus) return;
    _debounce?.cancel();
    if (text.trim().length < kDesktopQuickSearchMinChars) {
      _close();
      return;
    }
    _debounce = Timer(kDesktopQuickSearchDebounce, () => _lookup(text.trim()));
  }

  /// Leaving the box (click elsewhere, Tab, a route on top) closes the panel.
  void _onFocus() {
    if (!widget.focusNode!.hasFocus) _close();
  }

  /// Runs the lookup for [query] and shows the panel (skeleton rows first).
  ///
  /// The lookup streams: a catalogue answers once, while an installed-sources
  /// fan-out (novel "Browse", a source catalogue) shows its first titles as
  /// sources answer, with a "Searching N sources…" row until it is done.
  void _lookup(String query) {
    if (!mounted || !widget.focusNode!.hasFocus) return;
    // A newer lookup replaces the old one (and stops its source fan-out).
    _watch?.cancel();
    setState(() {
      // Keep the previous rows while the next answer loads, unless they were
      // for a query this one does not extend (they would just be wrong).
      if (!_open || !query.toLowerCase().startsWith(_query.toLowerCase())) {
        _items = const [];
        _sourceNames = const [];
      }
      _query = query;
      _loading = true;
      _pendingSources = 0;
      _failed = false;
      _noSources = false;
      _highlight = -1;
    });
    if (!_open) _portal.show();
    late final StreamSubscription<QuickSearchResult> sub;
    sub = _quick
        .watch(query)
        .listen(
          (result) {
            // Stale (a newer lookup took over) or the panel closed meanwhile.
            if (!identical(_watch, sub) || !mounted || !_open) return;
            setState(() {
              final oldTitles = _rowCount - 1;
              // A sources run's first answers are often still empty: keep the
              // rows kept over from the shorter query until this run has its
              // own titles (or is done), so typing does not flash skeletons.
              final keepPrevious = result.searching && result.items.isEmpty;
              if (!keepPrevious) {
                _items = result.items;
                _sourceNames = result.sourceNames;
              }
              _failed = result.failed;
              _noSources = result.noSources;
              _pendingSources = result.pendingSources;
              _loading = result.searching;
              // Titles only ever append, so a highlighted title stays put; a
              // highlight on "See all" follows it down as titles arrive.
              if (_highlight >= oldTitles) _highlight = _rowCount - 1;
            });
          },
          onDone: () {
            // The stream ended without a final answer: stop showing loading.
            if (!identical(_watch, sub) || !mounted) return;
            if (_loading) setState(() => _loading = false);
          },
        );
    _watch = sub;
  }

  /// Hides the panel and drops anything pending.
  void _close() {
    _debounce?.cancel();
    _watch?.cancel();
    _watch = null;
    _quick.cancel();
    if (!mounted) return;
    if (_open) _portal.hide();
    if (_highlight != -1 || _loading) {
      setState(() {
        _highlight = -1;
        _loading = false;
      });
    }
  }

  /// Opens [item]'s page after closing the panel.
  void _openItem(MediaItem item) {
    _close();
    final open = widget.onOpenItem;
    if (open != null) {
      open(item);
    } else {
      Navigator.of(context).push(DetailScreen.route(item));
    }
  }

  /// "See all results": the full page for the current text.
  void _seeAll() {
    final text = widget.controller!.text;
    _close();
    widget.onSeeAll(text);
  }

  /// Number of rows the keyboard can land on: the titles plus "See all".
  int get _rowCount => (_loading && _items.isEmpty ? 0 : _items.length) + 1;

  /// Keys bubbling up from the focused box. Only taken while the panel is
  /// open; with it closed everything is ignored so the field and the shell
  /// keep their own behaviour.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final enter =
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter;
    if (!_open) {
      // Enter submits through the field; a lookup still waiting on the
      // debounce must not pop the panel over the results page afterwards.
      if (enter) {
        _debounce?.cancel();
        _watch?.cancel();
        _watch = null;
        _quick.cancel();
      }
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (event is KeyDownEvent) _close();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() => _highlight = (_highlight + 1) % _rowCount);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      // Up from the first row (or from nothing) wraps to "See all".
      setState(
        () => _highlight = _highlight <= 0 ? _rowCount - 1 : _highlight - 1,
      );
      return KeyEventResult.handled;
    }
    if (enter) {
      // A held Enter must not open several pages.
      if (event is KeyRepeatEvent) return KeyEventResult.handled;
      final titles = _rowCount - 1;
      if (_highlight >= 0 && _highlight < titles) {
        _openItem(_items[_highlight]);
      } else {
        _seeAll();
      }
      // Handled, so the field's onSubmitted does not run the search again.
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    if (!_active) return widget.child;
    return Focus(
      // Only listens: the TextField below keeps its own focus node, and keys
      // from it bubble here before the app-wide text editing shortcuts.
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: CompositedTransformTarget(
        link: _link,
        child: OverlayPortal(
          controller: _portal,
          overlayChildBuilder: _panelLayer,
          child: KeyedSubtree(key: _fieldKey, child: widget.child),
        ),
      ),
    );
  }

  /// The floating panel, positioned under the box's right edge so a narrow
  /// box near the window's right side never pushes the panel off screen.
  Widget _panelLayer(BuildContext context) {
    final box = _fieldKey.currentContext?.findRenderObject();
    final fieldWidth = box is RenderBox && box.hasSize ? box.size.width : 340.0;
    final width = math.max(fieldWidth, 320.0);
    return Positioned(
      left: 0,
      top: 0,
      width: width,
      child: CompositedTransformFollower(
        link: _link,
        showWhenUnlinked: false,
        targetAnchor: Alignment.bottomRight,
        followerAnchor: Alignment.topRight,
        offset: const Offset(0, 6),
        // Clicks on the panel count as clicks "inside" the field, so the
        // field keeps focus and the click lands on the row.
        child: TextFieldTapRegion(child: _panel(context)),
      ),
    );
  }

  /// The panel itself: rows, then a divider and "See all results".
  Widget _panel(BuildContext context) {
    final titles = _rowCount - 1;
    final List<Widget> rows;
    // Installed sources still answering: one slim "Searching N sources…"
    // row (above the placeholders, or under the titles already in).
    final searchingRow = _loading && _pendingSources > 0
        ? _QuickSearchingRow(
            key: const ValueKey('desktop-search-dropdown-searching'),
            pending: _pendingSources,
          )
        : null;
    if (_loading && _items.isEmpty) {
      rows = [
        ?searchingRow,
        for (var i = 0; i < 3; i++)
          _QuickSkeletonRow(key: ValueKey('desktop-search-dropdown-skel-$i')),
      ];
    } else if (_items.isEmpty) {
      rows = [
        _QuickCaptionRow(
          key: const ValueKey('desktop-search-dropdown-caption'),
          text: _failed
              ? 'Quick results did not load. See all results to try again.'
              : _noSources
              ? 'No installed sources to search. See all results.'
              : 'No quick matches for “$_query”.',
        ),
      ];
    } else {
      rows = [
        for (var i = 0; i < titles; i++)
          _QuickResultRow(
            key: ValueKey('desktop-search-dropdown-row-$i'),
            item: _items[i],
            sourceName: i < _sourceNames.length ? _sourceNames[i] : null,
            highlighted: _highlight == i,
            onHover: () => setState(() => _highlight = i),
            onTap: () => _openItem(_items[i]),
          ),
        ?searchingRow,
      ];
    }
    return Material(
      key: const ValueKey('desktop-search-dropdown'),
      type: MaterialType.card,
      color: DesktopPanelColors.surface,
      elevation: 12,
      shadowColor: Colors.black,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: DesktopPanelColors.edge),
      ),
      clipBehavior: Clip.antiAlias,
      child: Semantics(
        container: true,
        // Screen-reader name for the panel, from the translations.
        label: context.l10n.desktopQuickSearchResults,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ...rows,
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Divider(
                  height: 1,
                  thickness: 1,
                  color: DesktopPanelColors.edge,
                ),
              ),
              _SeeAllRow(
                highlighted: _highlight == titles,
                onHover: () => setState(() => _highlight = titles),
                onTap: _seeAll,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Fill for a highlighted (hovered or keyboard-selected) row: a soft accent
/// tint like the selected row in mockup q2.
Color _rowHighlight() => AppColors.accent.withValues(alpha: 0.14);

/// One title row: poster thumb, title, and "Type · Year" (or its My List
/// status). Hover and click only; it never takes focus.
class _QuickResultRow extends StatelessWidget {
  const _QuickResultRow({
    super.key,
    required this.item,
    required this.highlighted,
    required this.onHover,
    required this.onTap,
    this.sourceName,
  });

  final MediaItem item;

  /// The installed source that found [item] (sources lookups only).
  final String? sourceName;

  final bool highlighted;
  final VoidCallback onHover;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => onHover(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          height: 62,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: highlighted ? _rowHighlight() : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: 40,
                  height: 56,
                  child: DesktopMediaArtwork(
                    url: item.cover,
                    headers: item.coverHeaders,
                    width: 40,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Tooltip(
                      // Full title after a hover pause; the row cuts it off.
                      message: item.title,
                      waitDuration: const Duration(milliseconds: 700),
                      excludeFromSemantics: true,
                      child: Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.body.copyWith(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      quickSearchRowSubtitle(item, sourceName: sourceName),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption.copyWith(
                        fontSize: 12,
                        color: AppColors.textSecondary,
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
}

/// Second line of a row: [quickSearchSubtitle], led by the installed
/// source's name when a source found the title ("Novel Ping · Novel").
String quickSearchRowSubtitle(MediaItem item, {String? sourceName}) {
  final sub = quickSearchSubtitle(item);
  if (sourceName == null || sourceName.isEmpty) return sub;
  return '$sourceName · $sub';
}

/// Second line of a quick-search row: "In your My List · (status)" when the
/// title is saved, otherwise "Type · Year" (year only when one is known).
String quickSearchSubtitle(MediaItem item) {
  final reading =
      item.type == ProviderType.manga || item.type == ProviderType.novel;
  if (sl.isRegistered<MyListStore>() && sl<MyListStore>().contains(item)) {
    final status = sl.isRegistered<ListStatusStore>()
        ? sl<ListStatusStore>().statusOf(item)
        : null;
    return status == null
        ? 'In your My List'
        : 'In your My List · ${labelFor(status, reading: reading)}';
  }
  final year = SearchMeta.year(item);
  final type = quickSearchTypeLabel(item);
  return year == null ? type : '$type · $year';
}

/// Short type label for a quick-search row.
String quickSearchTypeLabel(MediaItem item) => switch (item.type) {
  ProviderType.anime => 'Anime',
  // TMDB titles know whether they are a film or a series; others do not.
  ProviderType.movie =>
    item.tmdbId == null ? 'Movie/TV' : (item.tmdbIsTv ? 'TV' : 'Movie'),
  ProviderType.manga => 'Manga',
  ProviderType.novel => 'Novel',
};

/// The last row: "See all results ⏎" in the accent colour.
class _SeeAllRow extends StatelessWidget {
  const _SeeAllRow({
    required this.highlighted,
    required this.onHover,
    required this.onTap,
  });

  final bool highlighted;
  final VoidCallback onHover;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => onHover(),
      child: GestureDetector(
        key: const ValueKey('desktop-search-dropdown-see-all'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Semantics(
          button: true,
          child: Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            alignment: AlignmentDirectional.centerStart,
            decoration: BoxDecoration(
              color: highlighted ? _rowHighlight() : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              'See all results ⏎',
              style: AppText.body.copyWith(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.accent,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Placeholder row while the first answer loads; same height as a real row
/// so the panel does not jump when results arrive.
class _QuickSkeletonRow extends StatelessWidget {
  const _QuickSkeletonRow({super.key});

  @override
  Widget build(BuildContext context) {
    final fill = AppColors.surface2.withValues(alpha: 0.7);
    return SizedBox(
      height: 62,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 56,
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FractionallySizedBox(
                    widthFactor: 0.6,
                    child: Container(
                      height: 11,
                      decoration: BoxDecoration(
                        color: fill,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                  const SizedBox(height: 7),
                  FractionallySizedBox(
                    widthFactor: 0.35,
                    child: Container(
                      height: 9,
                      decoration: BoxDecoration(
                        color: fill,
                        borderRadius: BorderRadius.circular(4),
                      ),
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

/// Small spinner + "Searching N sources…" while installed sources are still
/// answering. Not selectable (keyboard and hover skip it).
class _QuickSearchingRow extends StatelessWidget {
  const _QuickSearchingRow({super.key, required this.pending});

  /// Sources still answering.
  final int pending;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
    child: Row(
      children: [
        const SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(strokeWidth: 1.6),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Searching $pending ${pending == 1 ? 'source' : 'sources'}…',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.caption.copyWith(
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
          ),
        ),
      ],
    ),
  );
}

/// One quiet line for "no matches" and "did not load".
class _QuickCaptionRow extends StatelessWidget {
  const _QuickCaptionRow({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
    child: Text(
      text,
      style: AppText.caption.copyWith(
        fontSize: 12.5,
        color: AppColors.textSecondary,
      ),
    ),
  );
}
