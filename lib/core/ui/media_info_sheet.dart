import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_mode.dart';
import '../di/injector.dart';
import '../models/media_detail.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../tv/tv_focusable.dart';
import 'desktop_settings_surface.dart' show GraphiteSettingsColors;

/// Netflix-style "more info" card shown on long-press of any row item.
///
/// A cinematic sheet: the cover art is blurred into a hero band that melts into
/// the surface, with the sharp poster floating on it, a refined meta line, genre
/// pills and a lazy-loaded synopsis, then a bold Play action over a segmented
/// icon strip. Decoupled from feature screens — the caller supplies data and the
/// action callbacks.
Future<void> showMediaInfoSheet(
  BuildContext context, {
  required String title,
  String? englishTitle,
  String? cover,
  Map<String, String>? headers,
  String? typeLabel,
  int? subCount,
  int? dubCount,
  required Future<MediaDetail?> detail,
  required bool inMyList,
  required VoidCallback onPlay,
  required VoidCallback onOpenDetail,
  required Future<bool> Function() onToggleMyList,
  String? playLabel,
  String? progressLabel,
  double? progress,
  VoidCallback? onRemoveFromContinue,
}) {
  // Windows: a centred graphite dialog (Esc / click outside closes it) instead
  // of a phone bottom sheet. Same content and actions.
  if (defaultTargetPlatform == TargetPlatform.windows) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.6),
      builder: (_) => _MediaInfoSheet(
        desktop: true,
        title: title,
        englishTitle: englishTitle,
        cover: cover,
        headers: headers,
        typeLabel: typeLabel,
        subCount: subCount,
        dubCount: dubCount,
        detail: detail,
        inMyList: inMyList,
        onPlay: onPlay,
        onOpenDetail: onOpenDetail,
        onToggleMyList: onToggleMyList,
        playLabel: playLabel,
        progressLabel: progressLabel,
        progress: progress,
        onRemoveFromContinue: onRemoveFromContinue,
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    barrierColor: Colors.black.withValues(alpha: 0.65),
    builder: (_) => _MediaInfoSheet(
      title: title,
      englishTitle: englishTitle,
      cover: cover,
      headers: headers,
      typeLabel: typeLabel,
      subCount: subCount,
      dubCount: dubCount,
      detail: detail,
      inMyList: inMyList,
      onPlay: onPlay,
      onOpenDetail: onOpenDetail,
      onToggleMyList: onToggleMyList,
      playLabel: playLabel,
      progressLabel: progressLabel,
      progress: progress,
      onRemoveFromContinue: onRemoveFromContinue,
    ),
  );
}

/// Graphite dialog surface on Windows (matches the desktop settings dialogs).
// A getter (set-9) so it follows Pure black and custom backgrounds.
Color get _kDesktopSurface => GraphiteSettingsColors.dialog;

class _MediaInfoSheet extends StatefulWidget {
  const _MediaInfoSheet({
    required this.title,
    this.englishTitle,
    this.cover,
    this.headers,
    this.typeLabel,
    this.subCount,
    this.dubCount,
    required this.detail,
    required this.inMyList,
    required this.onPlay,
    required this.onOpenDetail,
    required this.onToggleMyList,
    this.playLabel,
    this.progressLabel,
    this.progress,
    this.onRemoveFromContinue,
    this.desktop = false,
  });

  /// Windows dialog presentation (no grab handle, close button, button row).
  final bool desktop;
  final String title;
  final String? englishTitle;
  final String? cover;
  final Map<String, String>? headers;
  final String? typeLabel;
  final int? subCount;
  final int? dubCount;
  final Future<MediaDetail?> detail;
  final bool inMyList;
  final VoidCallback onPlay;
  final VoidCallback onOpenDetail;
  final Future<bool> Function() onToggleMyList;
  final String? playLabel;
  final String? progressLabel;
  final double? progress;
  final VoidCallback? onRemoveFromContinue;

  @override
  State<_MediaInfoSheet> createState() => _MediaInfoSheetState();
}

class _MediaInfoSheetState extends State<_MediaInfoSheet> {
  late bool _inList = widget.inMyList;
  bool _togglingList = false;

  String? _statusLabel(MediaStatus s) => switch (s) {
    MediaStatus.ongoing => 'Ongoing',
    MediaStatus.completed => 'Completed',
    MediaStatus.hiatus => 'Hiatus',
    MediaStatus.cancelled => 'Cancelled',
    MediaStatus.unknown => null,
  };

  bool get _hasCover => widget.cover != null && widget.cover!.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height;
    if (widget.desktop) {
      // Windows: bounded centred card in the graphite settings-dialog style.
      return Dialog(
        backgroundColor: _kDesktopSurface,
        insetPadding: const EdgeInsets.all(32),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: GraphiteSettingsColors.dialogEdge),
        ),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 580, maxHeight: h * 0.86),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _hero(),
              Flexible(child: _body()),
              _desktopActions(),
            ],
          ),
        ),
      );
    }
    return Padding(
      // Tiny side inset so the rounded corners read as a floating card.
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: SafeArea(
        top: false,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: ColoredBox(
            color: AppColors.surface,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: h * 0.86),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _hero(),
                  Flexible(child: _body()),
                  _actions(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── JioHotstar-style cinematic hero: full-bleed cover + gradient + title ───
  Widget _hero() {
    // The gradient melts into whichever surface hosts the card.
    final fade = widget.desktop ? _kDesktopSurface : const Color(0xFF16161C);
    return SizedBox(
      height: widget.desktop ? 260 : 220,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_hasCover)
            CachedNetworkImage(
              imageUrl: widget.cover!,
              httpHeaders: widget.headers,
              fit: BoxFit.cover,
              alignment: const Alignment(0, -0.25),
              placeholder: (_, _) => ColoredBox(color: AppColors.surface2),
              errorWidget: (_, _, _) => ColoredBox(color: AppColors.surface2),
            )
          else
            ColoredBox(color: AppColors.surface2),

          // Cinematic gradient — clear at top, melts to the sheet surface so the
          // image flows seamlessly into the content.
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  const Color(0x33000000),
                  const Color(0x00000000),
                  fade.withValues(alpha: 0.8),
                  fade,
                ],
                stops: const [0.0, 0.4, 0.82, 1.0],
              ),
            ),
          ),

          // Windows: a close button over the art instead of a grab handle.
          if (widget.desktop)
            Align(
              alignment: AlignmentDirectional.topEnd,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: IconButton(
                  key: const ValueKey('media-info-close'),
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded, size: 20),
                  color: Colors.white,
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black.withValues(alpha: 0.45),
                  ),
                ),
              ),
            )
          else
          // Grab handle over the art.
          Align(
            alignment: Alignment.topCenter,
            child: Container(
              margin: const EdgeInsets.only(top: 10),
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          // Title + meta overlaid at the bottom.
          Align(
            alignment: AlignmentDirectional.bottomStart,
            child: Padding(padding: const EdgeInsets.fromLTRB(18, 0, 18, 16), child: _heroTitle()),
          ),
        ],
      ),
    );
  }

  Widget _heroTitle() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.title,
          style: AppText.largeTitle.copyWith(fontSize: 23, height: 1.08, color: Colors.white),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        if (widget.englishTitle != null && widget.englishTitle!.isNotEmpty && widget.englishTitle != widget.title) ...[
          const SizedBox(height: 4),
          Text(
            widget.englishTitle!,
            style: AppText.caption.copyWith(color: Colors.white70),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        const SizedBox(height: 12),
        FutureBuilder<MediaDetail?>(
          future: widget.detail,
          builder: (context, snap) {
            final d = snap.data;
            final parts = <String>[
              if (d?.year != null && d!.year!.isNotEmpty) d.year!,
              if (widget.typeLabel != null) widget.typeLabel!,
              if (d != null && _statusLabel(d.status) != null) _statusLabel(d.status)!,
            ];
            if (parts.isEmpty && (widget.subCount ?? 0) == 0 && (widget.dubCount ?? 0) == 0) {
              return const SizedBox.shrink();
            }
            return Row(
              children: [
                if (parts.isNotEmpty)
                  Flexible(
                    child: Text(
                      parts.join('  •  '),
                      style: AppText.overline.copyWith(color: Colors.white),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                if ((widget.subCount ?? 0) > 0) ...[const SizedBox(width: 8), _miniBadge('SUB')],
                if ((widget.dubCount ?? 0) > 0) ...[const SizedBox(width: 6), _miniBadge('DUB')],
              ],
            );
          },
        ),
      ],
    );
  }

  // ── Body: progress, genres, synopsis ──────────────────────────────────────
  Widget _body() {
    final p = widget.progress;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (p != null) ...[
            if (widget.progressLabel != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 7),
                child: Text(widget.progressLabel!, style: AppText.caption.copyWith(color: AppColors.textSecondary)),
              ),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: p.clamp(0.0, 1.0),
                minHeight: 5,
                backgroundColor: AppColors.hairline,
                valueColor: AlwaysStoppedAnimation(AppColors.accent),
              ),
            ),
            const SizedBox(height: 16),
          ],
          FutureBuilder<MediaDetail?>(
            future: widget.detail,
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const _SynopsisSkeleton();
              }
              final d = snap.data;
              final desc = d?.description?.trim();
              // Dedupe + trim (some providers repeat the same value or stuff
              // non-genre noise in); preserve order, cap the count.
              // Dedupe, trim, and drop URL-like / over-long noise some
              // providers stuff into the genres field (e.g. "4KHDHub.com").
              bool looksLikeGenre(String g) => g.isNotEmpty && g.length <= 20 && !g.contains('.') && !g.contains('/');
              final genres = d == null
                  ? const <String>[]
                  : (<String>{
                      for (final g in d.genres.map((x) => x.trim()))
                        if (looksLikeGenre(g)) g,
                    }.take(5).toList());
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (genres.isNotEmpty) ...[
                    Wrap(spacing: 7, runSpacing: 7, children: genres.map((g) => _genrePill(g)).toList()),
                    const SizedBox(height: 14),
                  ],
                  Text(
                    (desc != null && desc.isNotEmpty) ? desc : 'No description available.',
                    style: AppText.body.copyWith(height: 1.4),
                    // The wider desktop card has room for more synopsis.
                    maxLines: widget.desktop ? 6 : 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (d != null && d.studios.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    _metaLine('Studio', d.studios.take(3).join(', ')),
                  ],
                  if (d != null && d.cast.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    _metaLine('Cast', d.cast.take(4).join(', ')),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  bool get _isTv => sl.isRegistered<AppMode>() && sl<AppMode>().isTv;

  /// D-pad focusable on TV; InkWell on phone.
  Widget _focusable({
    required Widget child,
    required VoidCallback onTap,
    String? semantic,
    bool autofocus = false,
    TvFocusVariant variant = TvFocusVariant.float,
    double scale = 1.04,
    double borderRadius = 12,
  }) {
    if (_isTv) {
      return TvFocusable(
        onTap: onTap,
        autofocus: autofocus,
        variant: variant,
        scale: scale,
        borderRadius: borderRadius,
        semanticLabel: semantic,
        child: child,
      );
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(borderRadius: BorderRadius.circular(borderRadius), onTap: onTap, child: child),
    );
  }

  // ── Actions: glowing Play + circular icon chips ───────────────────────────
  Widget _actions() {
    void play() {
      Navigator.pop(context);
      widget.onPlay();
    }

    final playChild = Container(
      height: 46,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 12, offset: const Offset(0, 4))],
      ),
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.play_arrow_rounded, color: AppColors.bg, size: 24),
            const SizedBox(width: 6),
            Text(widget.playLabel ?? 'Play', style: AppText.button.copyWith(color: AppColors.bg)),
          ],
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
      child: FocusTraversalGroup(
        child: Column(
          children: [
            // Play / Resume — white button (JioHotstar-style) with dark content.
            _focusable(
              onTap: play,
              autofocus: true,
              semantic: widget.playLabel ?? 'Play',
              borderRadius: 12,
              child: playChild,
            ),
            const SizedBox(height: 14),
            // Secondary actions — circular icon chips, evenly spread.
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _IconAction(
                  icon: _inList ? Icons.check_rounded : Icons.add_rounded,
                  label: 'My List',
                  active: _inList,
                  busy: _togglingList,
                  onTap: _toggleList,
                ),
                _IconAction(
                  icon: Icons.info_outline_rounded,
                  label: 'Details',
                  onTap: () {
                    Navigator.pop(context);
                    widget.onOpenDetail();
                  },
                ),
                if (widget.onRemoveFromContinue != null)
                  _IconAction(
                    icon: Icons.delete_outline_rounded,
                    label: 'Remove',
                    destructive: true,
                    onTap: () {
                      Navigator.pop(context);
                      widget.onRemoveFromContinue!();
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Windows action row: Play (default focus, so Enter plays) beside labelled
  /// My List / Details / Remove buttons — the same actions as the phone chips.
  Widget _desktopActions() {
    void closeThen(VoidCallback action) {
      Navigator.pop(context);
      action();
    }

    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
    );
    Widget secondary({
      required Key key,
      required Widget icon,
      required String label,
      required VoidCallback? onPressed,
      bool highlighted = false,
    }) {
      final color = highlighted ? AppColors.accent : AppColors.textPrimary;
      return OutlinedButton.icon(
        key: key,
        onPressed: onPressed,
        icon: icon,
        label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          foregroundColor: color,
          backgroundColor: highlighted
              ? AppColors.accentSoft
              : const Color(0xFF232429),
          side: BorderSide(
            color: highlighted
                ? AppColors.accent.withValues(alpha: 0.5)
                : const Color(0xFF36373E),
          ),
          shape: shape,
          textStyle: AppText.button.copyWith(fontSize: 14),
        ),
      );
    }

    final play = FilledButton.icon(
      key: const ValueKey('media-info-play'),
      autofocus: true,
      onPressed: () => closeThen(widget.onPlay),
      icon: const Icon(Icons.play_arrow_rounded, size: 22),
      label: Text(
        widget.playLabel ?? 'Play',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 44),
        backgroundColor: Colors.white,
        foregroundColor: AppColors.bg,
        shape: shape,
        textStyle: AppText.button.copyWith(fontSize: 15),
      ),
    );
    final secondaries = <Widget>[
      secondary(
        key: const ValueKey('media-info-my-list'),
        icon: _togglingList
            ? SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.accent,
                ),
              )
            : Icon(_inList ? Icons.check_rounded : Icons.add_rounded, size: 18),
        label: 'My List',
        highlighted: _inList,
        onPressed: _toggleList,
      ),
      secondary(
        key: const ValueKey('media-info-details'),
        icon: const Icon(Icons.info_outline_rounded, size: 18),
        label: 'Details',
        onPressed: () => closeThen(widget.onOpenDetail),
      ),
      if (widget.onRemoveFromContinue != null)
        secondary(
          key: const ValueKey('media-info-remove'),
          icon: const Icon(Icons.delete_outline_rounded, size: 18),
          label: 'Remove',
          highlighted: true,
          onPressed: () => closeThen(widget.onRemoveFromContinue!),
        ),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
      child: FocusTraversalGroup(
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Normal window: one row, Play takes the spare width.
            if (constraints.maxWidth >= 500) {
              return Row(
                children: [
                  Expanded(child: play),
                  for (final s in secondaries) ...[const SizedBox(width: 8), s],
                ],
              );
            }
            // Very narrow window: Play on its own line, the rest share a row.
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                play,
                const SizedBox(height: 8),
                Row(
                  children: [
                    for (var i = 0; i < secondaries.length; i++) ...[
                      if (i > 0) const SizedBox(width: 8),
                      Expanded(child: secondaries[i]),
                    ],
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _toggleList() async {
    if (_togglingList) return;
    setState(() => _togglingList = true);
    final now = await widget.onToggleMyList();
    if (mounted) {
      setState(() {
        _inList = now;
        _togglingList = false;
      });
    }
  }

  Widget _miniBadge(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: AppColors.accentSoft,
      borderRadius: BorderRadius.circular(4),
      border: Border.all(color: AppColors.accent.withValues(alpha: 0.5)),
    ),
    child: Text(text, style: AppText.overline.copyWith(color: AppColors.accent, fontSize: 10, letterSpacing: 0.6)),
  );

  Widget _genrePill(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: AppColors.hairline),
    ),
    child: Text(text, style: AppText.caption.copyWith(color: AppColors.textSecondary)),
  );

  Widget _metaLine(String label, String value) => RichText(
    text: TextSpan(
      children: [
        TextSpan(
          text: '$label  ',
          style: AppText.caption.copyWith(color: AppColors.textTertiary),
        ),
        TextSpan(
          text: value,
          style: AppText.caption.copyWith(color: AppColors.textSecondary),
        ),
      ],
    ),
  );
}

/// A circular icon chip + label, Netflix-style. No surrounding box — the chip
/// itself is the tactile surface.
class _IconAction extends StatelessWidget {
  const _IconAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.busy = false,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;
  final bool busy;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final accentish = active || destructive;
    final iconColor = accentish ? AppColors.accent : AppColors.textPrimary;
    final chipColor = active ? AppColors.accentSoft : AppColors.surface2;
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: chipColor,
              shape: BoxShape.circle,
              border: active ? Border.all(color: AppColors.accent.withValues(alpha: 0.5)) : null,
            ),
            child: busy
                ? Padding(
                    padding: EdgeInsets.all(11),
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent),
                  )
                : Icon(icon, color: iconColor, size: 20),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: AppText.caption.copyWith(
              fontSize: 12,
              color: accentish ? AppColors.accent : AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
    if (sl.isRegistered<AppMode>() && sl<AppMode>().isTv) {
      return TvFocusable(
        onTap: onTap,
        variant: TvFocusVariant.float,
        scale: 1.08,
        borderRadius: 10,
        semanticLabel: label,
        child: content,
      );
    }
    return InkWell(borderRadius: BorderRadius.circular(40), onTap: onTap, child: content);
  }
}

/// Shimmer-free, lightweight loading placeholder for the synopsis area.
class _SynopsisSkeleton extends StatelessWidget {
  const _SynopsisSkeleton();

  @override
  Widget build(BuildContext context) {
    Widget bar(double w) => Container(
      width: w,
      height: 12,
      margin: const EdgeInsets.only(bottom: 9),
      decoration: BoxDecoration(color: AppColors.surface2, borderRadius: BorderRadius.circular(6)),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [bar(70), const SizedBox(width: 7), bar(54)]),
        bar(double.infinity),
        bar(double.infinity),
        bar(220),
      ],
    );
  }
}
