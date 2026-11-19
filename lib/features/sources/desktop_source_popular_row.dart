// 'Popular on <source>' poster row in the Windows Sources manager's details
// pane. Loads the selected source's home lazily through the same
// BrowseSourceCubit the source's own catalogue page uses, so it shows the
// same titles and fails the same way.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/di/injector.dart';
import '../../core/error/exceptions.dart';
import '../../core/models/home_section.dart';
import '../../core/models/media_item.dart';
import '../../core/provider/cf_solve_needed.dart';
import '../../core/repository/source_actions.dart' as source_actions;
import '../../core/repository/source_inventory_events.dart';
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/poster_card.dart';
import '../../l10n/l10n.dart';
import '../detail/detail_screen.dart';
import '../search/browse_source_screen.dart' show canonicalTargetFor;
import '../search/cubit/browse_source_cubit.dart';

/// Picks the row to show from a source's home sections: the first non-empty
/// section titled like 'Popular', else the first non-empty section, else
/// null. Pure so it can be tested.
HomeSection? pickPopularSection(List<HomeSection> sections) {
  final nonEmpty = sections.where((s) => s.items.isNotEmpty).toList();
  if (nonEmpty.isEmpty) return null;
  return nonEmpty
          .where((s) => s.title.toLowerCase().contains('popular'))
          .firstOrNull ??
      nonEmpty.first;
}

/// The poster row for one source. Create it with `key: ValueKey(sourceId)`
/// so switching the selection disposes the old cubit (and its request).
class DesktopSourcePopularRow extends StatefulWidget {
  const DesktopSourcePopularRow({
    super.key,
    required this.sourceId,
    required this.sourceName,
  });

  final String sourceId;
  final String sourceName;

  @override
  State<DesktopSourcePopularRow> createState() =>
      _DesktopSourcePopularRowState();
}

class _DesktopSourcePopularRowState extends State<DesktopSourcePopularRow> {
  /// Latches true the first time the page is on screen. The manager lives
  /// in the shell's IndexedStack (TickerMode off while hidden), and a
  /// hidden page must not start loading a source's catalogue.
  bool _visibleOnce = false;

  // Row titles below read the translated "Popular on <source>" text.
  @override
  Widget build(BuildContext context) {
    final sourceId = widget.sourceId;
    final sourceName = widget.sourceName;
    _visibleOnce = _visibleOnce || TickerMode.valuesOf(context).enabled;
    // Unit tests and minimal hosts have no SourceRepository: say so calmly
    // instead of throwing.
    if (!sl.isRegistered<SourceRepository>()) {
      return _RowFrame(
        title: context.l10n.desktopPopularOn(sourceName),
        child: const _RowMessage(text: 'Titles are not available here.'),
      );
    }
    if (!_visibleOnce) {
      return _RowFrame(
        title: context.l10n.desktopPopularOn(sourceName),
        child: SizedBox(
          height: posterRowHeight(context),
          child: _Skeletons(
            width: posterRowWidth(context),
            height: posterRowHeight(context),
          ),
        ),
      );
    }
    return BlocProvider(
      // Same construction as BrowseSourceScreen.
      create: (_) => BrowseSourceCubit(
        repo: sl<SourceRepository>(),
        sourceId: sourceId,
        sourceAvailable: () => sl<SourceRepository>().hasSource(sourceId),
        inventoryChanges: sourceInventoryEvents(sourceId),
        timeout: desktopCatalogueTimeout,
      )..load(),
      child: DesktopPopularBody(sourceId: sourceId, sourceName: sourceName),
    );
  }
}

/// How long a Windows catalogue load may take before it fails. A Cloudflare
/// source's first load after verification can need the engine's request plus
/// a browser replay for both of its home lists; the shared 40s default cut
/// that off and showed a time-out right after a successful verification.
const Duration desktopCatalogueTimeout = Duration(seconds: 90);

/// Opens the verification for [sourceId] at [url] and reports whether it
/// passed. Defaults to [source_actions.verifySourceChallengeWithFeedback];
/// tests replace it to drive the Solve Cloudflare button without WebView2.
typedef DesktopChallengeVerifier =
    Future<bool> Function(BuildContext context, String sourceId, String url);

/// Title + content of the row, driven by the [BrowseSourceCubit] above it.
/// Public (and [verifier] injectable) only so the Solve Cloudflare button
/// can be tested with a fake cubit.
class DesktopPopularBody extends StatefulWidget {
  const DesktopPopularBody({
    super.key,
    required this.sourceId,
    required this.sourceName,
    this.verifier,
    this.solveTarget,
  });

  final String sourceId;
  final String sourceName;

  /// Test seam for the verification step (see [DesktopChallengeVerifier]).
  final DesktopChallengeVerifier? verifier;

  /// Test seam for the fresh solve target lookup
  /// ([SourceRepository.cfSolveTargetFor] in the app).
  final Future<String?> Function(String sourceId)? solveTarget;

  @override
  State<DesktopPopularBody> createState() => _PopularBodyState();
}

class _PopularBodyState extends State<DesktopPopularBody> {
  /// A tapped poster is being matched to the catalogue (one at a time).
  bool _opening = false;

  /// A Cloudflare verification started from this row is open.
  bool _solving = false;

  /// True when the failure is a Cloudflare challenge the user can solve:
  /// the engine's typed error, or the source flagged by an earlier request.
  bool _blockedByCloudflare(BrowseSourceState state) =>
      state.loadError is CloudflareRequiredException ||
      CfSolveNeeded.sourceFlagged(widget.sourceId);

  /// Solve Cloudflare: opens the verification for this source's challenged
  /// page and, once it passes, reloads the row so the titles appear without
  /// a second click on Retry. A closed window or a failure (shown as a snack
  /// bar by the verifier) leaves the error in place.
  Future<void> _solveThenRetry(BrowseSourceState state) async {
    if (_solving) return;
    final cubit = context.read<BrowseSourceCubit>();
    setState(() => _solving = true);
    try {
      // Fresh target first (a plugin may have moved domains), else the URL
      // the engine reported in the challenge.
      String? target;
      try {
        final lookup =
            widget.solveTarget ??
            (id) => sl<SourceRepository>().cfSolveTargetFor(id);
        target = await lookup(widget.sourceId);
      } catch (_) {
        target = null;
      }
      final error = state.loadError;
      if ((target == null || target.isEmpty) &&
          error is CloudflareRequiredException) {
        target = error.url;
      }
      if (target == null || target.isEmpty || !mounted) return;
      final verify =
          widget.verifier ?? source_actions.verifySourceChallengeWithFeedback;
      final verified = await verify(context, widget.sourceId, target);
      // Retry the failed load right away (the engine now has the session).
      if (verified && !cubit.isClosed) await cubit.load();
    } finally {
      if (mounted) setState(() => _solving = false);
    }
  }

  /// Opens a poster the way the source's own page does: ask the catalogue
  /// which title it is, falling back to the source's own item.
  Future<void> _open(MediaItem item) async {
    if (_opening) return;
    final cubit = context.read<BrowseSourceCubit>();
    if (!cubit.checkSourceAvailability()) return;
    _opening = true;
    final nav = Navigator.of(context);
    final accepts = cubit.retainSourceIntent();
    try {
      final target = await canonicalTargetFor(
        item,
        abandoned: () => !mounted || !accepts(),
      );
      if (!mounted || !accepts()) return;
      unawaited(nav.push(DetailScreen.route(target ?? item)));
    } finally {
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = posterRowWidth(context);
    final height = posterRowHeight(context);
    return BlocBuilder<BrowseSourceCubit, BrowseSourceState>(
      builder: (context, state) {
        final section = pickPopularSection(state.sections);
        final title = section == null || section.title.trim().isEmpty
            ? context.l10n.desktopPopularOn(widget.sourceName)
            : '${section.title} on ${widget.sourceName}';
        if (state.loading) {
          return _RowFrame(
            title: context.l10n.desktopPopularOn(widget.sourceName),
            child: SizedBox(
              height: height,
              child: _Skeletons(width: width, height: height),
            ),
          );
        }
        if (state.failed) {
          final blocked = _blockedByCloudflare(state);
          final error = state.loadError;
          return _RowFrame(
            title: context.l10n.desktopPopularOn(widget.sourceName),
            child: _RowMessage(
              key: const ValueKey('desktop-popular-error'),
              // A Cloudflare block gets plain words and the site, not the
              // raw exception text.
              text: blocked
                  ? 'This site needs a Cloudflare check before its titles load.'
                  : "Couldn't load this source's titles.",
              detail: blocked
                  ? (error is CloudflareRequiredException
                        ? Uri.tryParse(error.url)?.host
                        : null)
                  : (error == null ? null : '$error'),
              actionLabel: context.l10n.retry,
              onAction: _solving
                  ? null
                  : () => context.read<BrowseSourceCubit>().load(),
              // Solve Cloudflare sits before Retry when the site is blocked.
              solveLabel: blocked ? context.l10n.solveCloudflare : null,
              solving: _solving,
              onSolve: blocked ? () => _solveThenRetry(state) : null,
            ),
          );
        }
        if (section == null) {
          return _RowFrame(
            title: context.l10n.desktopPopularOn(widget.sourceName),
            child: const _RowMessage(
              text: 'This source has no front page to show.',
            ),
          );
        }
        final items = section.items;
        return _RowFrame(
          title: title,
          child: SizedBox(
            height: height,
            child: ListView.separated(
              key: const ValueKey('desktop-popular-list'),
              scrollDirection: Axis.horizontal,
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(width: 14),
              itemBuilder: (c, i) {
                final item = items[i];
                return SizedBox(
                  width: width,
                  child: PosterCard(
                    title: item.title,
                    logoItem: item,
                    imageUrl: item.cover,
                    headers: item.coverHeaders,
                    cellWidth: width,
                    wideImageUrl: item.banner,
                    genres: item.genres,
                    isAdult: item.isAdult,
                    qualityBadge: item.quality,
                    scoreBadge: item.score,
                    dubBadge: item.dubBadge,
                    onTap: () => unawaited(_open(item)),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

/// Label above the row plus the row itself.
class _RowFrame extends StatelessWidget {
  const _RowFrame({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppText.body.copyWith(color: AppColors.textSecondary),
      ),
      const SizedBox(height: 12),
      child,
    ],
  );
}

/// Placeholder cards while the row loads. Exactly the card size, so the
/// pane does not jump when the posters arrive.
class _Skeletons extends StatelessWidget {
  const _Skeletons({required this.width, required this.height});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) => ListView.separated(
    key: const ValueKey('desktop-popular-skeletons'),
    scrollDirection: Axis.horizontal,
    physics: const NeverScrollableScrollPhysics(),
    itemCount: 8,
    separatorBuilder: (_, _) => const SizedBox(width: 14),
    itemBuilder: (_, _) => Container(
      key: const ValueKey('desktop-popular-skeleton'),
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(12),
      ),
    ),
  );
}

/// One calm line (with optional detail and action) in place of the posters.
class _RowMessage extends StatelessWidget {
  const _RowMessage({
    super.key,
    required this.text,
    this.detail,
    this.actionLabel,
    this.onAction,
    this.solveLabel,
    this.onSolve,
    this.solving = false,
  });

  final String text;
  final String? detail;
  final String? actionLabel;

  /// Retry; null while a verification runs (the button shows disabled).
  final VoidCallback? onAction;

  /// "Solve Cloudflare" label and action, shown before Retry when set.
  final String? solveLabel;
  final VoidCallback? onSolve;

  /// A verification is open: the solve button shows a spinner, disabled.
  final bool solving;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: AppColors.surface2,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(text, style: AppText.body),
              if (detail != null && detail!.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  detail!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption,
                ),
              ],
            ],
          ),
        ),
        if (solveLabel != null && onSolve != null) ...[
          const SizedBox(width: 12),
          FilledButton.icon(
            key: const ValueKey('desktop-popular-solve-cloudflare'),
            onPressed: solving ? null : onSolve,
            icon: solving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.shield_outlined, size: 18),
            label: Text(solveLabel!),
          ),
        ],
        if (actionLabel != null) ...[
          const SizedBox(width: 12),
          OutlinedButton.icon(
            key: const ValueKey('desktop-popular-retry'),
            onPressed: onAction,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: Text(actionLabel!),
          ),
        ],
      ],
    ),
  );
}
