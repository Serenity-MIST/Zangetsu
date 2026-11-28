import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/desktop/desktop_chrome_colors.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/desktop_media_card.dart';
import 'lists_hub_models.dart';
import '../../l10n/l10n.dart';

/// How long an episode counts as "Airing now" after its start time. The
/// schedule carries no runtime, so this is a typical TV anime slot.
const Duration kHubAiringSlot = Duration(minutes: 30);

/// Headline state of the "Airing today" panel at a given moment.
String hubAiringCountdownLabel(List<HubAiringItem> items, DateTime now) {
  if (items.isEmpty) return '';
  // Something inside its slot wins over the countdown.
  final airing = items.any(
    (e) =>
        !now.isBefore(e.airingAt) &&
        now.isBefore(e.airingAt.add(kHubAiringSlot)),
  );
  if (airing) return 'Airing now';
  DateTime? next;
  for (final e in items) {
    if (e.airingAt.isAfter(now) &&
        (next == null || e.airingAt.isBefore(next))) {
      next = e.airingAt;
    }
  }
  if (next == null) return 'All aired today';
  return 'Next in ${hubFormatCountdown(next.difference(now))}';
}

/// Rows the panel shows at once; the rest are a click away in the Schedule.
const kHubAiringVisibleRows = 4;

/// The 4 most useful of today's rows: starting at the one airing now (or the
/// next to air), filled from the latest already-aired ones when fewer remain.
List<HubAiringItem> hubVisibleAiring(List<HubAiringItem> items, DateTime now) {
  if (items.length <= kHubAiringVisibleRows) return items;
  var start = items.indexWhere(
    (e) => now.isBefore(e.airingAt.add(kHubAiringSlot)),
  );
  if (start < 0) start = items.length;
  start = start.clamp(0, items.length - kHubAiringVisibleRows);
  return items.sublist(start, start + kHubAiringVisibleRows);
}

/// "1h 12m", "45m", "2h". Rounds up so a few seconds left still reads "1m".
String hubFormatCountdown(Duration d) {
  final total = ((d.inSeconds + 59) ~/ 60).clamp(1, 1 << 30);
  final h = total ~/ 60, m = total % 60;
  if (h == 0) return '${m}m';
  return m == 0 ? '${h}h' : '${h}h ${m}m';
}

/// Windows "Schedule and lists" left column: today's airing episodes with a
/// live countdown. Pure widget — the page passes data and callbacks in.
class DesktopListsHubAiringPanel extends StatefulWidget {
  const DesktopListsHubAiringPanel({
    super.key,
    required this.items,
    required this.loading,
    required this.onOpenSchedule,
    required this.onOpenItem,
    this.onRetry,
    this.failed = false,
    this.now,
  });

  /// Today's rows sorted by time; null when nothing is cached yet.
  final List<HubAiringItem>? items;

  /// A refresh is running (skeleton shows only when [items] is null).
  final bool loading;

  /// Opens the full week schedule.
  final VoidCallback onOpenSchedule;

  /// Opens a row's show page; only called for rows with an [HubAiringItem.item].
  final void Function(HubAiringItem) onOpenItem;

  /// Re-runs the refresh after [failed]; hidden when null.
  final VoidCallback? onRetry;

  /// The last refresh failed; cached rows stay and a quiet retry link shows.
  final bool failed;

  /// Clock override for tests; defaults to [DateTime.now].
  final DateTime Function()? now;

  @override
  State<DesktopListsHubAiringPanel> createState() =>
      _DesktopListsHubAiringPanelState();
}

class _DesktopListsHubAiringPanelState
    extends State<DesktopListsHubAiringPanel> {
  Timer? _tick;

  DateTime _now() => (widget.now ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  /// Re-renders on each minute boundary so the countdown and dimming advance.
  void _schedule() {
    _tick?.cancel();
    final now = _now();
    final toNextMinute = Duration(
      seconds: 60 - now.second,
      milliseconds: -now.millisecond,
    );
    _tick = Timer(
      toNextMinute <= Duration.zero ? const Duration(minutes: 1) : toNextMinute,
      () {
        if (!mounted) return;
        setState(() {});
        _schedule();
      },
    );
  }

  @override
  void didUpdateWidget(DesktopListsHubAiringPanel old) {
    super.didUpdateWidget(old);
    // A new clock means the next minute boundary moved; re-arm against it.
    if (old.now != widget.now) _schedule();
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    final now = _now();
    final skeleton = items == null && widget.loading;
    final label = items == null ? '' : hubAiringCountdownLabel(items, now);

    final Widget body;
    if (skeleton) {
      body = const _AiringSkeleton();
    } else if (items == null || items.isEmpty) {
      body = _EmptyState(
        message: items == null && widget.failed
            ? "Couldn't load today's schedule"
            : 'Nothing airing today',
      );
    } else {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final item in hubVisibleAiring(items, now))
            _AiringRow(
              item: item,
              now: now,
              // Every row opens: the show page, or a title search when
              // AniList gave no id (the page decides which).
              onTap: () => widget.onOpenItem(item),
            ),
        ],
      );
    }

    // Same graphite fill, outline and radius as the list tiles beside it.
    return Container(
      decoration: BoxDecoration(
        color: Color.lerp(DesktopChrome.frame, Colors.white, .035),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Color.lerp(DesktopChrome.frame, Colors.white, .12)!,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(6, 12, 6, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(label: label),
          const SizedBox(height: 6),
          body,
          if (widget.failed && widget.onRetry != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      "Couldn't refresh",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption,
                    ),
                  ),
                  const SizedBox(width: 8),
                  _LinkButton(
                    label: context.l10n.retry,
                    icon: 'rotate-cw',
                    leadingIcon: true,
                    onTap: widget.onRetry!,
                  ),
                ],
              ),
            ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: _LinkButton(
              // Names how many of today's rows are hidden by the 4-row cap.
              label: items != null && items.length > kHubAiringVisibleRows
                  ? '${items.length - kHubAiringVisibleRows} more today · Full week schedule'
                  : 'Full week schedule',
              icon: 'arrow-right',
              onTap: widget.onOpenSchedule,
            ),
          ),
        ],
      ),
    );
  }
}

/// "Airing today" title with the countdown chip on the right.
class _Header extends StatelessWidget {
  const _Header({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final live = label == 'Airing now';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      // Wrap, not Row: at narrow widths or large text the chip drops below
      // the title instead of squeezing it to an ellipsis.
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 6,
        children: [
          Text(context.l10n.airingToday, style: AppText.headline),
          if (label.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: live ? AppColors.accentSoft : AppColors.surface2,
                borderRadius: BorderRadius.circular(99),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _Svg(
                    'clock',
                    size: 13,
                    color: live ? AppColors.accent : AppColors.textSecondary,
                  ),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption.copyWith(
                        color: live
                            ? AppColors.accent
                            : AppColors.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// One episode: cover, title, "Ep N", optional "On your list" tag, time.
class _AiringRow extends StatefulWidget {
  const _AiringRow({required this.item, required this.now, this.onTap});
  final HubAiringItem item;
  final DateTime now;
  final VoidCallback? onTap;

  @override
  State<_AiringRow> createState() => _AiringRowState();
}

class _AiringRowState extends State<_AiringRow> {
  bool _hover = false, _focus = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final start = item.airingAt;
    final live =
        !widget.now.isBefore(start) &&
        widget.now.isBefore(start.add(kHubAiringSlot));
    final aired = !live && !widget.now.isBefore(start);
    final mine = item.onYourList;
    final active = (_hover || _focus) && widget.onTap != null;
    final time = MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(start),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );

    Color fill = Colors.transparent;
    if (mine) fill = AppColors.accent.withValues(alpha: .07);
    if (active) {
      fill = Color.alphaBlend(Colors.white.withValues(alpha: .05), fill);
    }

    // One announcement per row (title, episode, tag, time) with its tap.
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            onHover: (v) => setState(() => _hover = v),
            onFocusChange: (v) => setState(() => _focus = v),
            borderRadius: BorderRadius.circular(9),
            hoverColor: Colors.transparent,
            focusColor: Colors.transparent,
            child: AnimatedContainer(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 140),
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(
                  color: _focus && widget.onTap != null
                      ? AppColors.accent
                      : Colors.transparent,
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              // Aired episodes fade back so what's still to come stands out.
              child: Opacity(
                opacity: aired ? .55 : 1,
                child: Row(
                  children: [
                    if (mine)
                      Container(
                        width: 3,
                        height: 36,
                        margin: const EdgeInsets.only(right: 7),
                        decoration: BoxDecoration(
                          color: AppColors.accent,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(5),
                      child: SizedBox(
                        width: 32,
                        height: 48,
                        child: DesktopMediaArtwork(
                          url: item.cover,
                          width: 32,
                          headers: item.item?.coverHeaders,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.body.copyWith(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 3),
                          // Wrap so the tag drops under "Ep N" in a narrow
                          // column or at large text instead of overflowing.
                          Wrap(
                            spacing: 6,
                            runSpacing: 3,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                'Ep ${item.episode}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppText.caption,
                              ),
                              if (mine) const _OnYourListTag(),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      live ? 'Now' : time,
                      style: AppText.caption.copyWith(
                        color: live
                            ? AppColors.accent
                            : AppColors.textSecondary,
                        fontWeight: FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Small accent pill marking a show on one of the user's lists.
class _OnYourListTag extends StatelessWidget {
  const _OnYourListTag();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      color: AppColors.accentSoft,
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      'On your list',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: AppText.caption.copyWith(
        fontSize: 11,
        color: AppColors.accent,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

/// Quiet "Nothing airing today" (or load failure) message.
class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 22),
    child: Row(
      children: [
        _Svg('calendar-days', size: 18, color: AppColors.textTertiary),
        const SizedBox(width: 10),
        Expanded(
          child: Text(message, style: AppText.body.copyWith(fontSize: 14)),
        ),
      ],
    ),
  );
}

/// Grey placeholder rows shown before the first load finishes.
class _AiringSkeleton extends StatelessWidget {
  const _AiringSkeleton();

  @override
  Widget build(BuildContext context) {
    final block = AppColors.surface2;
    Widget bar(double w, double h) => Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        color: block,
        borderRadius: BorderRadius.circular(4),
      ),
    );
    return Column(
      key: const ValueKey('airing-skeleton'),
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 4; i++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            child: Row(
              children: [
                bar(34, 48),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      FractionallySizedBox(
                        widthFactor: .75,
                        child: bar(double.infinity, 12),
                      ),
                      const SizedBox(height: 7),
                      bar(44, 10),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                bar(38, 10),
              ],
            ),
          ),
      ],
    );
  }
}

/// Small accent text link with a Lucide icon, hover underline and focus ring.
class _LinkButton extends StatefulWidget {
  const _LinkButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.leadingIcon = false,
  });
  final String label;
  final String icon;
  final VoidCallback onTap;
  final bool leadingIcon;

  @override
  State<_LinkButton> createState() => _LinkButtonState();
}

class _LinkButtonState extends State<_LinkButton> {
  bool _hover = false, _focus = false;

  @override
  Widget build(BuildContext context) {
    final color = AppColors.accent;
    final icon = _Svg(widget.icon, size: 14, color: color);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: widget.onTap,
        onHover: (v) => setState(() => _hover = v),
        onFocusChange: (v) => setState(() => _focus = v),
        borderRadius: BorderRadius.circular(6),
        hoverColor: Colors.transparent,
        focusColor: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: _focus ? color : Colors.transparent),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.leadingIcon) ...[icon, const SizedBox(width: 5)],
              Flexible(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption.copyWith(
                    color: color,
                    fontWeight: FontWeight.w600,
                    decoration: _hover ? TextDecoration.underline : null,
                    decorationColor: color,
                  ),
                ),
              ),
              if (!widget.leadingIcon) ...[const SizedBox(width: 5), icon],
            ],
          ),
        ),
      ),
    );
  }
}

/// Decorative bundled Lucide icon tinted to [color].
class _Svg extends StatelessWidget {
  const _Svg(this.name, {required this.size, required this.color});
  final String name;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SvgPicture.asset(
      'assets/icons/lucide/$name.svg',
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    ),
  );
}
