// Skip pills, round buttons, the bar capsule and the centre transport discs.
part of 'player_screen.dart';

class PlayerSegmentSkipButton extends StatefulWidget {
  const PlayerSegmentSkipButton({
    super.key,
    required this.label,
    required this.controlsVisible,
    required this.onTap,
  });

  final String label;
  final bool controlsVisible;
  final VoidCallback onTap;

  @override
  State<PlayerSegmentSkipButton> createState() =>
      _PlayerSegmentSkipButtonState();
}

class _PlayerSegmentSkipButtonState extends State<PlayerSegmentSkipButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _timer = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 10),
    animationBehavior: AnimationBehavior.preserve,
  );

  @override
  void initState() {
    super.initState();
    _timer.forward();
  }

  /// Windows: the skip runs on the mouse press itself (see [build]).
  bool get _windows => defaultTargetPlatform == TargetPlatform.windows;

  @override
  void dispose() {
    _timer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final labelStyle = AppText.body.copyWith(
      fontSize: 13,
      fontWeight: FontWeight.w600,
    );
    return AnimatedBuilder(
      animation: _timer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Text(widget.label, style: labelStyle.copyWith(color: Colors.white)),
      ),
      builder: (context, label) {
        if (_timer.isCompleted && !widget.controlsVisible) {
          return const SizedBox.shrink();
        }
        return Material(
          color: Colors.black.withValues(alpha: 0.76),
          borderRadius: BorderRadius.circular(22),
          clipBehavior: Clip.antiAlias,
          // Windows: skip on the primary-button press, not on release.
          // The player rebuilds often while it plays (position ticks,
          // controls showing or hiding); a rebuild or a moved pill
          // between press and release used to drop the tap, so a click
          // sometimes did nothing. The InkWell stays for the hover and
          // press look only.
          child: Listener(
            onPointerDown: _windows
                ? (e) {
                    if (e.buttons & kPrimaryMouseButton == 0) return;
                    AppLogger.instance.log('[skip] pressed: ${widget.label}');
                    widget.onTap();
                  }
                : null,
            child: InkWell(
              onTap: _windows ? () {} : widget.onTap,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    height: 44,
                    child: Center(widthFactor: 1, child: label),
                  ),
                  if (_timer.value > 0)
                    Positioned.fill(
                      child: ExcludeSemantics(
                        child: ClipRect(
                          clipper: _SkipFillClipper(_timer.value),
                          child: ColoredBox(
                            color: Colors.white,
                            child: Center(
                              child: RichText(
                                text: TextSpan(
                                  text: widget.label,
                                  style: labelStyle.copyWith(
                                    color: Colors.black,
                                  ),
                                ),
                                textScaler: MediaQuery.textScalerOf(context),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SkipFillClipper extends CustomClipper<Rect> {
  const _SkipFillClipper(this.progress);

  final double progress;

  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, size.width * progress, size.height);

  @override
  bool shouldReclip(_SkipFillClipper oldClipper) => progress != oldClipper.progress;
}

// MegaSkip — Aniyomi-style manual "jump forward N seconds" pill. A compact,
// accent-outlined stadium that sits right-aligned just above the seek bar (so
// it never overlaps the bar or the controls), distinct from the AniSkip pill.
class _MegaSkipPill extends StatelessWidget {
  const _MegaSkipPill({required this.seconds, required this.onTap});
  final int seconds;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Deliberately the twin of the timestamp chip it now sits beside — same
    // fill, radius and type. The accent-outlined stadium it used to be was
    // louder than anything else on the bar and read as a stray element.
    return Material(
      color: Colors.black.withValues(alpha: 0.3),
      borderRadius: BorderRadius.circular(13),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 12, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.keyboard_double_arrow_right_rounded,
                color: Colors.white,
                size: 18,
              ),
              const SizedBox(width: 5),
              Text(
                '+${seconds}s',
                style: AppText.caption.copyWith(
                  color: Colors.white,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  height: 1.1,
                  letterSpacing: 0.3,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Small circular icon button (used for the unlock control while locked).
class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    required this.icon,
    required this.onTap,
    this.semanticLabel,
  });
  final IconData icon;
  final VoidCallback onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return _withTooltip(
      semanticLabel,
      Semantics(
        button: true,
        label: semanticLabel,
        child: Material(
          color: Colors.black.withValues(alpha: 0.5),
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Icon(icon, color: Colors.white, size: 24),
            ),
          ),
        ),
      ),
    );
  }
}

/// Long-press tooltip for the player's icon-only controls. Most of them lost
/// their text labels to keep the bars compact, so the tooltip is the only way
/// to find out what one does without pressing it.
///
/// Semantics are excluded by default because these buttons already declare
/// their own — letting the tooltip add a second label makes a screen reader
/// announce everything twice. Pass false for a control that has none.
Widget _withTooltip(
  String? message,
  Widget child, {
  bool excludeSemantics = true,
}) {
  if (message == null || message.isEmpty) return child;
  return Tooltip(
    message: message,
    excludeFromSemantics: excludeSemantics,
    child: child,
  );
}

/// Aspect-mode icon. The fit button dropped its text label to keep every
/// button the same width, so the icon has to carry which mode you're on.
IconData _fitIcon(String label) => switch (label) {
  'Fill' => Icons.crop_free_rounded,
  'Stretch' => Icons.open_in_full_rounded,
  _ => Icons.fit_screen_rounded,
};

/// One translucent capsule holding a set of [_BarButton]s. Grouping them means
/// a single soft backdrop behind the row instead of a chip per icon, which is
/// quieter over video — plain alpha, no BackdropFilter, so it costs nothing to
/// composite. It's also the Material the buttons' ripples paint onto; without
/// it they'd splash on the Scaffold underneath and be hidden by this backdrop.
class _BarGroup extends StatelessWidget {
  const _BarGroup({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.3),
      borderRadius: BorderRadius.circular(26),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

/// A single icon button inside a [_BarGroup] — uniform square footprint so the
/// row never reflows, transparent itself since the group carries the backdrop.
class _BarButton extends StatelessWidget {
  const _BarButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return _withTooltip(
      tooltip,
      Semantics(
        button: true,
        label: tooltip,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Icon(icon, color: Colors.white, size: 24),
          ),
        ),
      ),
    );
  }
}

/// A single leading-icon row in the ⋮ More overflow sheet.
class _MoreRow extends StatelessWidget {
  const _MoreRow({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.subtitle,
    this.hint,
    this.trailing,
    this.chevron = false,
    this.enabled = true,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// Optional second line (e.g. a warning about an external player).
  final String? subtitle;

  /// Optional shortcut hint shown on the right (e.g. 'Ctrl+M').
  final String? hint;

  /// Optional widget on the right (e.g. a switch).
  final Widget? trailing;

  /// Windows More panel: a chevron for rows that open a sub-page in place.
  final bool chevron;

  /// Greyed out and not clickable when false.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final color = enabled ? AppColors.textPrimary : AppColors.textTertiary;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: Padding(
            // Tighter than the old 14 — the panel is narrower now, and these
            // rows were spaced like a settings screen rather than a menu.
            padding: EdgeInsets.symmetric(
              horizontal: 13,
              vertical: trailing != null ? 4 : 11,
            ),
            child: Row(
              children: [
                Icon(icon, color: color, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        style: AppText.body.copyWith(
                          color: color,
                          fontSize: 14,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (subtitle != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            subtitle!,
                            style: AppText.caption.copyWith(
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (hint != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(
                      hint!,
                      style: AppText.caption.copyWith(
                        color: AppColors.textTertiary,
                      ),
                    ),
                  ),
                ?trailing,
                if (chevron)
                  const Padding(
                    padding: EdgeInsets.only(left: 6),
                    child: Icon(
                      Icons.chevron_right_rounded,
                      color: AppColors.textTertiary,
                      size: 20,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Strips a leading episode marker from [title] when it just repeats [n].
///
/// Plenty of sources hand back "Episode 2: I Suppose You Aren't Aware", which
/// sits next to the "E2" the panel already draws and eats the whole line for
/// something you can see a centimetre to the left.
///
/// Two shapes, deliberately narrow:
///  * a word form — "Episode 2 …", "Ep.2 - …", "E2: …" — separator optional;
///  * a bare number — "2. …", "02 - …" — where the separator is REQUIRED,
///    otherwise a title like "12 Monkeys" on episode 12 would lose its name.
class _AnimatedPlayPause extends StatelessWidget {
  const _AnimatedPlayPause({required this.playing, required this.onTap});
  final bool playing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // No tooltip — play/pause needs no explaining, and a bubble over the
    // middle of the picture is just in the way.
    return Semantics(
      button: true,
      label: playing ? 'Pause' : 'Play',
      // Larger disc than the episode arrows so the row keeps its hierarchy —
      // the icon inside is bigger too, so matching discs would have crowded
      // this one while leaving the arrows swimming in theirs.
      child: _TransportDisc(
        size: 58,
        onTap: onTap,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          transitionBuilder: (child, anim) => FadeTransition(
            opacity: anim,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.72, end: 1).animate(anim),
              child: child,
            ),
          ),
          child: Icon(
            playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            key: ValueKey<bool>(playing),
            color: Colors.white,
            size: 34,
          ),
        ),
      ),
    );
  }
}

/// Backdrop for the three centre transport buttons. They sit over the middle
/// of the picture where barely any scrim reaches, so they carry more alpha
/// than the bottom capsules' 0.3 — at that level they wash out on a bright
/// frame. [dimmed] fades the disc along with its icon, otherwise a dead arrow
/// ends up inside a solid circle and reads as broken rather than unavailable.
class _TransportDisc extends StatelessWidget {
  const _TransportDisc({
    required this.size,
    required this.child,
    required this.onTap,
    this.dimmed = false,
  });

  final double size;
  final Widget child;
  final VoidCallback? onTap;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    // The disc is itself the Material the ripple paints onto. A plain
    // DecoratedBox wouldn't do: ink splashes render on the nearest Material
    // ancestor, which would be the Scaffold underneath — so the ripple would
    // spread behind this circle and never be seen. Clipping to the same
    // CircleBorder keeps the splash inside the disc instead of squaring off.
    return Material(
      color: Colors.black.withValues(alpha: dimmed ? 0.18 : 0.45),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        // Explicit, because the theme's default splash is tuned for opaque
        // surfaces and barely shows on a translucent black disc over video.
        splashColor: Colors.white.withValues(alpha: 0.22),
        highlightColor: Colors.white.withValues(alpha: 0.10),
        child: SizedBox(
          width: size,
          height: size,
          child: Center(child: child),
        ),
      ),
    );
  }
}

/// Episode step either side of play/pause. A null [onTap] means there's
/// nowhere to step (first or last episode): the button dims and stops taking
/// touches, so the tap falls through and toggles the controls like any other
/// empty patch of screen rather than dying on a dead button. It stays mounted
/// either way, which is what keeps play/pause centred instead of sliding as
/// the row shrinks.
///
/// No tooltip: the three transport controls are the most self-evident thing on
/// the screen, so a bubble over them is noise. The bottom bar keeps its
/// tooltips — those buttons lost their text labels and need the help.
class _TransportButton extends StatelessWidget {
  const _TransportButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: IgnorePointer(
        ignoring: !enabled,
        child: _TransportDisc(
          size: 46,
          dimmed: !enabled,
          onTap: onTap,
          child: Icon(
            icon,
            color: Colors.white.withValues(alpha: enabled ? 1 : 0.28),
            size: 26,
          ),
        ),
      ),
    );
  }
}

/// Windows: the "back N seconds" / "forward N seconds" disc either side of
/// play / pause. Same size and look as the episode arrows. Unlike those it
/// carries a tooltip, because a mouse user cannot tell how far it jumps
/// otherwise. The InkWell inside the disc can take keyboard focus (Tab) and
/// is pressed with Enter, like any other button.
class _SeekStepButton extends StatelessWidget {
  const _SeekStepButton({
    super.key,
    required this.seconds,
    required this.onTap,
  });

  /// Signed jump: negative seeks back, positive seeks forward.
  final int seconds;
  final VoidCallback onTap;

  /// Material has numbered arrows for 5, 10 and 30 seconds; any other step
  /// shows the plain arrow with the number written under it.
  IconData? get _numberedIcon {
    final back = seconds < 0;
    return switch (seconds.abs()) {
      5 => back ? Icons.replay_5_rounded : Icons.forward_5_rounded,
      10 => back ? Icons.replay_10_rounded : Icons.forward_10_rounded,
      30 => back ? Icons.replay_30_rounded : Icons.forward_30_rounded,
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final back = seconds < 0;
    // "Seek back 10s" / "Seek forward 10s", from the existing shortcut names.
    final label =
        '${back ? l10n.shortcutPlayerSeekBack : l10n.shortcutPlayerSeekForward}'
        ' ${l10n.secondsShort(seconds.abs())}';
    final numbered = _numberedIcon;
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        child: _TransportDisc(
          size: 46,
          onTap: onTap,
          child: numbered != null
              ? Icon(numbered, color: Colors.white, size: 26)
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      back ? Icons.replay_rounded : Icons.forward_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                    Text(
                      '${seconds.abs()}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        height: 1,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// The player's bottom-sheet surface: a SOLID, detached card that floats above
/// the screen edges (margins + full-radius + soft shadow), centred in landscape
/// — instead of an edge-to-edge frosted panel. Drop-in for the old
/// `FrostedSurface(...)` sheet wrappers: it accepts (and ignores) blur/opacity/
/// borderRadius so those call sites only needed a rename.

/// Height of the bottom controls block (timestamp, seek bar, button groups)
/// while it is laid out, so overlays that must stay clickable above it — the
/// Skip Intro/Outro pill — can sit exactly over it instead of guessing a
/// screen fraction. One player is on screen at a time, so one value suffices.
final ValueNotifier<double> _controlsBottomBlockHeight = ValueNotifier(0);

/// Reports its child's laid-out height into [_controlsBottomBlockHeight].
class _ReportBottomBlockHeight extends SingleChildRenderObjectWidget {
  const _ReportBottomBlockHeight({required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderReportHeight();
}

/// Render box behind [_ReportBottomBlockHeight]: publishes its height after
/// each layout.
class _RenderReportHeight extends RenderProxyBox {
  @override
  void performLayout() {
    super.performLayout();
    final h = size.height;
    if ((h - _controlsBottomBlockHeight.value).abs() > 0.5) {
      // Notify after layout; listeners rebuild on the next frame.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _controlsBottomBlockHeight.value = h,
      );
    }
  }
}
