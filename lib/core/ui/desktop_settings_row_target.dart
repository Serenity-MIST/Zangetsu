import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme/app_colors.dart';

/// set-2: a Windows settings search result names one row on a page. Before
/// the page opens, the result records that row here; the row then scrolls
/// itself into view, flashes in the accent colour and takes keyboard focus.
///
/// Rows opt in by sitting inside a [DesktopSettingsRowTarget]. Every
/// `GraphiteSettingsControl` (and so every desktop `SettingsTile`) does this
/// on its own, keyed by its title, so most pages need no change at all. A row
/// whose label differs from its search leaf can pass an explicit [id].
abstract final class DesktopSettingsRowTargets {
  static _PendingTarget? _pending;

  /// How long a request waits for its row. Long enough for the page route
  /// transition and a few scroll steps; short enough that a later, unrelated
  /// visit to the same page never flashes a stale row.
  static const Duration _ttl = Duration(seconds: 5);

  /// Records the row the next opened settings page should reveal. [title] is
  /// the row's visible label (matched case-insensitively); [id] matches rows
  /// that registered the same explicit id.
  static void request({String? id, required String title}) {
    _pending = _PendingTarget(id, _normalise(title), DateTime.now());
  }

  /// True while a request is waiting for its row.
  static bool get hasPending {
    final pending = _pending;
    if (pending == null) return false;
    if (DateTime.now().difference(pending.at) > _ttl) {
      _pending = null;
      return false;
    }
    return true;
  }

  /// Drops any waiting request (the page had no such row).
  static void clear() => _pending = null;

  /// Claims the waiting request when it names this row. Returns true once:
  /// the first matching row wins and the request is cleared.
  static bool claim({String? id, String? title}) {
    if (!hasPending) return false;
    final pending = _pending!;
    final byId = id != null && pending.id != null && id == pending.id;
    final byTitle = title != null && _normalise(title) == pending.title;
    if (!byId && !byTitle) return false;
    _pending = null;
    return true;
  }

  /// Titles compare without case or surrounding/doubled spaces, so a label
  /// that wraps or ends in an ellipsis still matches its search leaf.
  static String _normalise(String s) =>
      s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  @visibleForTesting
  static void debugReset() => _pending = null;
}

/// One waiting request: explicit id (optional), normalised title, timestamp.
class _PendingTarget {
  const _PendingTarget(this.id, this.title, this.at);
  final String? id;
  final String title;
  final DateTime at;
}

/// Wraps one settings row so a search result can reveal it (see
/// [DesktopSettingsRowTargets]). Costs nothing when no request is waiting:
/// the wrapper only checks once when it is first built.
class DesktopSettingsRowTarget extends StatefulWidget {
  const DesktopSettingsRowTarget({
    super.key,
    this.id,
    this.title,
    this.borderRadius = const BorderRadius.all(Radius.circular(14)),
    required this.child,
  });

  /// Explicit leaf id, for rows whose label is not the leaf title.
  final String? id;

  /// The row's visible label.
  final String? title;

  /// Shape of the accent flash, matching the row's own hover shape.
  final BorderRadius borderRadius;

  final Widget child;

  @override
  State<DesktopSettingsRowTarget> createState() =>
      _DesktopSettingsRowTargetState();
}

class _DesktopSettingsRowTargetState extends State<DesktopSettingsRowTarget>
    with SingleTickerProviderStateMixin {
  // Holds the row's own focusable descendants (its InkWell, switch...). The
  // node itself never takes focus; it only lets us find the first child that
  // can, so focusing does not change how the row reacts to Enter or Space.
  final FocusNode _scope = FocusNode(
    debugLabel: 'settings-row-target',
    canRequestFocus: false,
    skipTraversal: true,
  );

  AnimationController? _flash;

  @override
  void initState() {
    super.initState();
    // Cheap fast path: nothing waits, nothing to do.
    if (DesktopSettingsRowTargets.hasPending) {
      SchedulerBinding.instance.addPostFrameCallback((_) => _maybeReveal());
    }
  }

  @override
  void dispose() {
    _flash?.dispose();
    _scope.dispose();
    super.dispose();
  }

  /// Claims a matching request, then scrolls, flashes and focuses this row.
  void _maybeReveal() {
    if (!mounted) return;
    if (!DesktopSettingsRowTargets.claim(id: widget.id, title: widget.title)) {
      return;
    }
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    // Centre-ish placement reads better than flush with the page header.
    Scrollable.ensureVisible(
      context,
      alignment: .3,
      duration: reduced ? Duration.zero : const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
    // Focus the row's first focusable control, so Enter / Space act on it.
    for (final node in _scope.traversalDescendants) {
      if (node.canRequestFocus) {
        node.requestFocus();
        break;
      }
    }
    // A short accent flash: held briefly, then fades. Reduced motion keeps
    // the hold but drops the fade (the curve is a step).
    final flash = _flash ??= AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    setState(() {});
    flash.forward(from: 0).whenCompleteOrCancel(() {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final child = Focus(
      focusNode: _scope,
      canRequestFocus: false,
      skipTraversal: true,
      includeSemantics: false,
      child: widget.child,
    );
    final flash = _flash;
    final flashing = flash != null && flash.isAnimating;
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    // Always the same Stack shape: switching between a bare child and a
    // Stack would rebuild the row and drop the focus just given to it.
    return Stack(
      children: [
        child,
        // Painted over the row without catching clicks.
        if (flashing)
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: flash,
                builder: (context, _) {
                  // Hold full strength for the first 40%, then fade out.
                  final t = flash.value;
                  final strength = reduced
                      ? 1.0
                      : t < .4
                      ? 1.0
                      : 1 - Curves.easeOut.transform((t - .4) / .6);
                  return DecoratedBox(
                    decoration: BoxDecoration(
                      color: AppColors.accent.withValues(alpha: .14 * strength),
                      borderRadius: widget.borderRadius,
                      border: Border.all(
                        color: AppColors.accent.withValues(alpha: strength),
                        width: 1.5,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
      ],
    );
  }
}

/// Wraps a settings page that was opened from a search result. Rows far down
/// a long page (Playback) are not built until scrolled near, so they cannot
/// reveal themselves; this steps the page's scroll view down until the
/// requested row is built and claims the request, or the end is reached.
class DesktopSettingsRowSeeker extends StatefulWidget {
  const DesktopSettingsRowSeeker({super.key, required this.child});

  final Widget child;

  @override
  State<DesktopSettingsRowSeeker> createState() =>
      _DesktopSettingsRowSeekerState();
}

class _DesktopSettingsRowSeekerState extends State<DesktopSettingsRowSeeker> {
  @override
  void initState() {
    super.initState();
    if (DesktopSettingsRowTargets.hasPending) _seek();
  }

  /// Uses frame callbacks only (no timers), so a widget test that stops
  /// pumping never trips over a pending timer.
  Future<void> _seek() async {
    // Let the route lay out and visible rows claim the request first.
    await SchedulerBinding.instance.endOfFrame;
    await SchedulerBinding.instance.endOfFrame;
    for (var step = 0; step < 80; step++) {
      if (!mounted || !DesktopSettingsRowTargets.hasPending) return;
      final position = _findVerticalScrollable()?.position;
      if (position == null || !position.hasContentDimensions) {
        // The page may still be building (async data); try a few frames.
        if (step > 10) break;
      } else if (position.pixels >= position.maxScrollExtent) {
        break;
      } else {
        position.jumpTo(
          (position.pixels + position.viewportDimension * .8).clamp(
            position.minScrollExtent,
            position.maxScrollExtent,
          ),
        );
      }
      await SchedulerBinding.instance.endOfFrame;
    }
    // Not on this page (renamed or platform-hidden row): open at the top as
    // before, and drop the request so it cannot fire somewhere else later.
    if (!mounted || !DesktopSettingsRowTargets.hasPending) return;
    DesktopSettingsRowTargets.clear();
    final position = _findVerticalScrollable()?.position;
    if (position != null && position.hasContentDimensions) {
      position.jumpTo(position.minScrollExtent);
    }
  }

  /// The page's outermost vertical scroll view (its body list).
  ScrollableState? _findVerticalScrollable() {
    ScrollableState? found;
    void visit(Element element) {
      if (found != null) return;
      if (element is StatefulElement &&
          element.state is ScrollableState &&
          axisDirectionToAxis(
                (element.state as ScrollableState).axisDirection,
              ) ==
              Axis.vertical) {
        found = element.state as ScrollableState;
        return;
      }
      element.visitChildElements(visit);
    }

    (context as Element).visitChildElements(visit);
    return found;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
