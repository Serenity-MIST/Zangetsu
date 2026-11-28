import 'package:flutter/material.dart';

import '../../core/desktop/desktop_chrome_colors.dart';
import '../../core/desktop/desktop_context_menu.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/zmode/metadata_filters.dart';
import '../../core/zmode/zmode_ids.dart' show ZKind;
import '../../l10n/l10n.dart';
import 'bloc/search_event.dart';
import 'bloc/search_state.dart';

/// One chip in the Windows results header's filter row.
///
/// A chip either opens a compact menu ([items], built when it opens so the
/// ticks reflect the current state) or runs [onPressed] (for "More filters").
class DesktopFilterChipSpec {
  const DesktopFilterChipSpec({
    required this.id,
    required this.label,
    this.active = false,
    this.items,
    this.onPressed,
    this.tooltip,
  });

  /// Stable id; the chip's key is `desktop-results-chip-<id>`.
  final String id;

  /// What the chip reads, e.g. "Type" or "Type: Movie".
  final String label;

  /// Highlighted (accent) when the chip narrows or reorders the results.
  final bool active;

  /// Menu rows, built on open. Null for a plain button chip.
  final List<DesktopMenuItem<Object?>> Function()? items;

  /// Action for a plain button chip (no menu).
  final VoidCallback? onPressed;

  /// Hover hint; defaults to the label.
  final String? tooltip;
}

/// Windows results-page header (mockup q1): "Results for “q”" with the title
/// count, then one row of filter chips and "Clear filters".
///
/// The page's own search box is gone on Windows; the shell's top-bar box is
/// the only one, and this header echoes the query it ran. Everything is
/// passed in (values and callbacks), so the widget is testable on its own;
/// see [desktopLibraryFilterChips] and [desktopSourcesFilterChips] for the
/// chip sets the Search page builds.
class DesktopResultsHeader extends StatelessWidget {
  const DesktopResultsHeader({
    super.key,
    required this.query,
    this.count,
    this.chips = const [],
    this.leading = const [],
    this.trailing = const [],
    this.onClearFilters,
    this.searchingSources = false,
  });

  /// The query the results are for.
  final String query;

  /// Number of titles; null hides the count (still loading, or failed).
  /// On a search that also asks the installed sources it includes their
  /// titles, so it never reads "0 titles" above source results.
  final int? count;

  /// True while installed sources are still answering: the count line then
  /// reads "Searching your sources…" (nothing counted yet) or
  /// "N titles · searching sources…".
  final bool searchingSources;

  /// Filter chips, in order.
  final List<DesktopFilterChipSpec> chips;

  /// Widgets before the chips (the NSFW toggle).
  final List<Widget> leading;

  /// Widgets after "Clear filters" (the per-source filter icon).
  final List<Widget> trailing;

  /// Shown as "Clear filters" only when non-null (something is active).
  final VoidCallback? onClearFilters;

  @override
  Widget build(BuildContext context) {
    final n = count;
    // The count line: a plain count, a count still growing while sources
    // answer, or only "searching" while nothing is counted yet (never a
    // "0 titles" that is about to be wrong).
    final String? countText;
    if (searchingSources && (n == null || n == 0)) {
      countText = 'Searching your sources…';
    } else if (n == null) {
      countText = null;
    } else {
      final titles = n == 1 ? '1 title' : '$n titles';
      countText = searchingSources ? '$titles · searching sources…' : titles;
    }
    return Padding(
      key: const ValueKey('desktop-results-header'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(
                  'Results for “$query”',
                  key: const ValueKey('desktop-results-title'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.headline.copyWith(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (countText != null) ...[
                const SizedBox(width: 12),
                Text(
                  countText,
                  key: const ValueKey('desktop-results-count'),
                  style: AppText.caption.copyWith(
                    fontSize: 13,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ],
          ),
          if (chips.isNotEmpty ||
              leading.isNotEmpty ||
              trailing.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ...leading,
                for (final chip in chips) DesktopFilterChip(spec: chip),
                if (onClearFilters != null)
                  _ClearFiltersButton(onPressed: onClearFilters!),
                ...trailing,
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// A rounded pill chip with a ▾, opening its menu below itself. Hover lifts
/// the edge, keyboard focus draws an accent ring, Enter/Space open it.
class DesktopFilterChip extends StatefulWidget {
  const DesktopFilterChip({super.key, required this.spec});

  final DesktopFilterChipSpec spec;

  @override
  State<DesktopFilterChip> createState() => _DesktopFilterChipState();
}

class _DesktopFilterChipState extends State<DesktopFilterChip> {
  bool _hover = false;
  bool _focused = false;

  /// Opens the chip's menu under it, or runs its plain action.
  void _activate(BuildContext anchor) {
    final spec = widget.spec;
    final items = spec.items;
    if (items == null) {
      spec.onPressed?.call();
      return;
    }
    showDesktopContextMenu<Object?>(context, anchor: anchor, items: items());
  }

  @override
  Widget build(BuildContext context) {
    final spec = widget.spec;
    final active = spec.active;
    final hasMenu = spec.items != null;
    final Color border = _focused
        ? AppColors.accent
        : active
        ? AppColors.accent.withValues(alpha: 0.7)
        : _hover
        ? const Color(0xFF4A4C55)
        : DesktopChrome.hairline;
    final Color fill = active
        ? DesktopChrome.selectedFill(AppColors.accent, strength: .22)
        : _hover
        ? AppColors.surface2
        : AppColors.surface;
    final Color fg = active ? AppColors.textPrimary : AppColors.textSecondary;
    return Tooltip(
      message: spec.tooltip ?? spec.label,
      waitDuration: const Duration(milliseconds: 600),
      excludeFromSemantics: true,
      child: Builder(
        // This builder's context is the anchor the menu opens under.
        builder: (anchor) => Material(
          key: ValueKey('desktop-results-chip-${spec.id}'),
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: () => _activate(anchor),
            onHover: (v) => setState(() => _hover = v),
            onFocusChange: (v) => setState(() => _focused = v),
            focusColor: Colors.transparent,
            hoverColor: Colors.transparent,
            child: AnimatedContainer(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 120),
              height: 32,
              padding: EdgeInsets.fromLTRB(14, 0, hasMenu ? 10 : 14, 0),
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: border, width: _focused ? 1.6 : 1),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    spec.label,
                    style: AppText.body.copyWith(
                      fontSize: 12.5,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                      color: fg,
                    ),
                  ),
                  if (hasMenu) ...[
                    const SizedBox(width: 4),
                    Icon(Icons.arrow_drop_down_rounded, size: 18, color: fg),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The quiet "Clear filters" text button after the chips.
class _ClearFiltersButton extends StatelessWidget {
  const _ClearFiltersButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => TextButton(
    key: const ValueKey('desktop-results-clear'),
    onPressed: onPressed,
    style: TextButton.styleFrom(
      foregroundColor: AppColors.textSecondary,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      minimumSize: const Size(0, 32),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
    ),
    child: Text(
      context.l10n.clearFilters,
      style: AppText.caption.copyWith(fontSize: 12.5),
    ),
  );
}

// ── Library (metadata catalogue) chips ─────────────────────────────────────

/// Sort names. A public copy of the metadata filter sheet's private label
/// helper (meta_filter_sheet.dart), kept here so that file stays untouched.
String desktopMetaSortLabel(BuildContext context, MetaSort s) => switch (s) {
  MetaSort.popularity => context.l10n.sortPopularity,
  MetaSort.score => context.l10n.sortScore,
  MetaSort.trending => context.l10n.sortTrending,
  MetaSort.newest => context.l10n.sortNewest,
  MetaSort.title => context.l10n.sortTitle,
};

/// Format names (copy of the sheet's private helper, see above).
String desktopMetaFormatLabel(MetaFormat f) => switch (f) {
  MetaFormat.tv => 'TV',
  MetaFormat.movie => 'Movie',
  MetaFormat.ova => 'OVA',
  MetaFormat.special => 'Special',
  MetaFormat.manga => 'Manga',
  MetaFormat.novel => 'Novel',
  MetaFormat.oneShot => 'One shot',
};

/// Status names (copy of the sheet's private helper, see above).
String desktopMetaStatusLabel(MetaStatus s) => switch (s) {
  MetaStatus.releasing => 'Airing',
  MetaStatus.finished => 'Finished',
  MetaStatus.notYetReleased => 'Upcoming',
  MetaStatus.cancelled => 'Cancelled',
};

/// Formats worth offering for [kind], mirroring the filter sheet: manga and
/// novel pin their format by kind, so they get no Type chip at all.
List<MetaFormat> desktopMetaFormatsFor(ZKind kind) => switch (kind) {
  ZKind.movie || ZKind.tv => const [MetaFormat.tv, MetaFormat.movie],
  ZKind.anime => const [
    MetaFormat.tv,
    MetaFormat.movie,
    MetaFormat.ova,
    MetaFormat.special,
  ],
  ZKind.manga || ZKind.novel => const [],
};

/// The library-scope filters with everything cleared except the NSFW switch
/// (a visibility choice, not a filter).
MetaFilters desktopClearedMetaFilters(MetaFilters f) =>
    MetaFilters(adult: f.adult);

/// The chip row for a metadata-catalogue (library) search.
///
/// [onChanged] gets the new filters for every pick; the page stores them and
/// re-runs. [onMoreFilters] opens the full sheet (season, min score, tags).
/// When the provider cannot filter ([supportsFilters] false) only More
/// filters remains; it explains why (like the old tune icon did), because
/// picks the provider cannot honour would be silently dropped.
List<DesktopFilterChipSpec> desktopLibraryFilterChips(
  BuildContext context, {
  required MetaFilters filters,
  required ZKind kind,
  required bool supportsFilters,
  required ValueChanged<MetaFilters> onChanged,
  required VoidCallback onMoreFilters,
}) {
  final l10n = context.l10n;
  final f = filters;
  final formats = desktopMetaFormatsFor(kind);
  final genres = metaGenresFor(kind, adult: f.adult);
  final thisYear = DateTime.now().year;
  final years = [for (var y = thisYear; y > thisYear - 25; y--) y];
  final extraCount =
      (f.season != null ? 1 : 0) +
      (f.minScore != null ? 1 : 0) +
      (f.tags.isNotEmpty ? 1 : 0);
  return [
    if (supportsFilters && formats.isNotEmpty)
      DesktopFilterChipSpec(
        id: 'type',
        // Reads "Type" like the sources chip and mockup q1 (it edits the
        // catalogue's format filter).
        label: f.format == null
            ? 'Type'
            : 'Type: ${desktopMetaFormatLabel(f.format!)}',
        tooltip: l10n.format,
        active: f.format != null,
        items: () => [
          DesktopMenuItem(
            label: l10n.any,
            checked: f.format == null,
            onTap: () => onChanged(f.copyWith(clearFormat: true)),
          ),
          for (final format in formats)
            DesktopMenuItem(
              label: desktopMetaFormatLabel(format),
              checked: f.format == format,
              onTap: () => onChanged(f.copyWith(format: format)),
            ),
        ],
      ),
    if (supportsFilters && genres.isNotEmpty)
      DesktopFilterChipSpec(
        id: 'genre',
        // "Genre" (singular) as in mockup q1; a count once several are on.
        label: switch (f.genres.length) {
          0 => 'Genre',
          1 => 'Genre: ${f.genres.first}',
          final n => 'Genres: $n',
        },
        active: f.genres.isNotEmpty,
        tooltip: f.genres.isEmpty ? l10n.genres : f.genres.join(', '),
        items: () => [
          DesktopMenuItem(
            label: l10n.any,
            checked: f.genres.isEmpty,
            onTap: () => onChanged(f.copyWith(genres: const [])),
          ),
          const DesktopMenuItem.divider(),
          // Multi-select: each pick toggles that genre in or out.
          for (final g in genres)
            DesktopMenuItem(
              label: g,
              checked: f.genres.contains(g),
              onTap: () => onChanged(
                f.copyWith(
                  genres: f.genres.contains(g)
                      ? ([...f.genres]..remove(g))
                      : [...f.genres, g],
                ),
              ),
            ),
        ],
      ),
    if (supportsFilters)
      DesktopFilterChipSpec(
        id: 'year',
        label: f.year == null ? l10n.year : '${l10n.year}: ${f.year}',
        active: f.year != null,
        items: () => [
          DesktopMenuItem(
            label: l10n.any,
            checked: f.year == null,
            onTap: () => onChanged(f.copyWith(clearYear: true)),
          ),
          for (final y in years)
            DesktopMenuItem(
              label: '$y',
              checked: f.year == y,
              onTap: () => onChanged(f.copyWith(year: y)),
            ),
        ],
      ),
    if (supportsFilters)
      DesktopFilterChipSpec(
        id: 'status',
        label: f.status == null
            ? l10n.status
            : '${l10n.status}: ${desktopMetaStatusLabel(f.status!)}',
        active: f.status != null,
        items: () => [
          DesktopMenuItem(
            label: l10n.any,
            checked: f.status == null,
            onTap: () => onChanged(f.copyWith(clearStatus: true)),
          ),
          for (final s in MetaStatus.values)
            DesktopMenuItem(
              label: desktopMetaStatusLabel(s),
              checked: f.status == s,
              onTap: () => onChanged(f.copyWith(status: s)),
            ),
        ],
      ),
    // Sort rides the same provider filter path, so it hides with the rest.
    if (supportsFilters)
      DesktopFilterChipSpec(
        id: 'sort',
        // Translated "Sort: <order>" label.
        label: l10n.desktopSortChip(desktopMetaSortLabel(context, f.sort)),
        active: f.sort != MetaSort.popularity,
        tooltip: l10n.sortBy,
        items: () => [
          for (final s in MetaSort.values)
            DesktopMenuItem(
              label: desktopMetaSortLabel(context, s),
              checked: f.sort == s,
              onTap: () => onChanged(f.copyWith(sort: s)),
            ),
        ],
      ),
    DesktopFilterChipSpec(
      id: 'more',
      // Translated chip text; the count shows how many sheet filters are on.
      label: extraCount == 0
          ? l10n.desktopMoreFilters
          : l10n.desktopMoreFiltersCount(extraCount),
      active: extraCount > 0,
      tooltip: l10n.desktopLibraryFiltersTooltip,
      onPressed: onMoreFilters,
    ),
  ];
}

// ── Sources chips ──────────────────────────────────────────────────────────

/// The chip row for a sources search. Picks dispatch the same events the
/// filter sheet uses; [onMoreFilters] opens that sheet (audio, which sources
/// to search, current source only). There is no Year chip: sources carry no
/// year filter.
List<DesktopFilterChipSpec> desktopSourcesFilterChips(
  BuildContext context, {
  required SearchState state,
  required void Function(SearchEvent event) dispatch,
  required VoidCallback onMoreFilters,
}) {
  final l10n = context.l10n;
  final genres = state.availableGenres;
  final genre = state.genreFilter;
  return [
    DesktopFilterChipSpec(
      id: 'type',
      label: state.contentFilter == SearchContentFilter.all
          ? 'Type'
          : 'Type: ${state.contentFilter.label}',
      active: state.contentFilter != SearchContentFilter.all,
      items: () => [
        for (final c in SearchContentFilter.values)
          DesktopMenuItem(
            label: c.label,
            checked: state.contentFilter == c,
            onTap: () => dispatch(SearchContentFilterChanged(c)),
          ),
      ],
    ),
    // Genres come from the results themselves; none known = no chip, unless
    // one is still selected (it must stay removable).
    if (genres.isNotEmpty || genre != null)
      DesktopFilterChipSpec(
        id: 'genre',
        // "Genre" (singular) as in mockup q1.
        label: genre == null ? 'Genre' : 'Genre: $genre',
        active: genre != null,
        items: () => [
          DesktopMenuItem(
            label: l10n.any,
            checked: genre == null,
            onTap: () => dispatch(const SearchGenreFilterChanged(null)),
          ),
          for (final g in {...genres, ?genre})
            DesktopMenuItem(
              label: g,
              checked: genre == g,
              onTap: () => dispatch(SearchGenreFilterChanged(g)),
            ),
        ],
      ),
    DesktopFilterChipSpec(
      id: 'status',
      label: state.statusFilter == SearchStatusFilter.any
          ? l10n.status
          : '${l10n.status}: ${state.statusFilter.label}',
      active: state.statusFilter != SearchStatusFilter.any,
      items: () => [
        for (final s in SearchStatusFilter.values)
          DesktopMenuItem(
            label: s.label,
            checked: state.statusFilter == s,
            onTap: () => dispatch(SearchStatusFilterChanged(s)),
          ),
      ],
    ),
    DesktopFilterChipSpec(
      id: 'sort',
      // Translated "Sort: <order>" label.
      label: l10n.desktopSortChip(state.sort.label),
      active: state.sort != SearchSort.bestMatch,
      tooltip: l10n.sortBy,
      items: () => [
        for (final s in SearchSort.values)
          DesktopMenuItem(
            label: s.label,
            checked: state.sort == s,
            onTap: () => dispatch(SearchSortChanged(s)),
          ),
      ],
    ),
    DesktopFilterChipSpec(
      id: 'more',
      label: state.audioFilter == SearchAudioFilter.any
          ? l10n.desktopMoreFilters
          // Audio is the only sheet filter counted here, so at most one.
          : l10n.desktopMoreFiltersCount(1),
      active: state.audioFilter != SearchAudioFilter.any,
      tooltip: l10n.desktopSourceFiltersTooltip,
      onPressed: onMoreFilters,
    ),
  ];
}

/// The events that reset every sources-search filter and the sort.
List<SearchEvent> desktopClearSourcesFilterEvents() => const [
  SearchContentFilterChanged(SearchContentFilter.all),
  SearchAudioFilterChanged(SearchAudioFilter.any),
  SearchGenreFilterChanged(null),
  SearchStatusFilterChanged(SearchStatusFilter.any),
  SearchSortChanged(SearchSort.bestMatch),
];
