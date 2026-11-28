// The controls laid over the video: top bar, centre transport, bottom block.
part of 'player_screen.dart';

class _ControlsOverlay extends StatelessWidget {
  const _ControlsOverlay({
    required this.controller,
    required this.state,
    required this.showTitle,
    required this.duration,
    required this.onDurationChanged,
    required this.onInteract,
    required this.onBack,
    required this.onSpeed,
    required this.onAudioSubs,
    required this.onQuality,
    required this.onSources,
    required this.onLock,
    required this.onRotate,
    required this.portraitMode,
    required this.onSettings,
    required this.barConfig,
    required this.onZoom,
    required this.zoomLabel,
    required this.onPrev,
    required this.onSleep,
    required this.sleepActive,
    required this.decoderLabel,
    required this.onDecoder,
    required this.onEpisodes,
    required this.megaSkipEnabled,
    required this.megaSkipSeconds,
    required this.onMegaSkip,
    this.onPip,
    this.onMinimize,
    this.onSwitchPlayer,
    required this.ambientActive,
    required this.onAmbientToggle,
    this.onChat,
    this.onInfo,
    this.infoOpen = false,
    this.showQuality = false,
    required this.onScreenshot,
    required this.onEnhance,
    required this.enhanceActive,
    required this.onColorProfile,
    this.visible = true,
    this.onShowPage,
    this.onSeekStep,
    this.seekStepSeconds = 10,
    this.onTheatre,
    this.onMiniPlayer,
    this.fullScreen = false,
    this.isMovie = false,
  });

  /// Windows only: a film (one item, movie kind). Its top bar shows just the
  /// title, with no "E1" line. Phone always passes false.
  final bool isMovie;

  /// Windows only: leaves theatre mode for the watch page (from full screen
  /// it drops to theatre mode first). Non-null adds the theatre button to
  /// the bottom bar; null (phone) leaves the bar as it was.
  final VoidCallback? onTheatre;

  /// Windows only: pops the video into the small floating mini player.
  /// Non-null adds the mini player button to the bottom bar.
  final VoidCallback? onMiniPlayer;

  /// Windows only: the window is in full screen (changes the theatre
  /// button's tooltip).
  final bool fullScreen;

  /// Windows only: one click to the show's detail page. Null hides it.
  final VoidCallback? onShowPage;

  /// Windows only: seeks by the given seconds (negative = back), the same
  /// path the arrow keys use. Non-null adds the back / forward buttons
  /// either side of play / pause. Null (phone) leaves the centre row as is.
  final ValueChanged<int>? onSeekStep;

  /// How far one press of those buttons jumps, in seconds (the arrow-key
  /// step).
  final int seekStepSeconds;

  final PlayerCubit controller;
  final PlayerState state;
  final String? showTitle;
  final Duration duration;
  final ValueChanged<Duration> onDurationChanged;
  final VoidCallback onInteract;
  final VoidCallback onBack;
  final VoidCallback onSpeed;
  final VoidCallback onAudioSubs;
  final VoidCallback onQuality;
  final VoidCallback onSources;
  final VoidCallback onLock;
  final VoidCallback
  onRotate; // flip between locked landscape and locked portrait
  final bool portraitMode; // true while watching upright
  final VoidCallback onSettings;

  /// The user's control arrangement — which bar each control sits on, in what
  /// order. Drives both bars; anything not placed is reachable via ⋮ More.
  final PlayerControlsConfig barConfig;

  final VoidCallback onZoom;
  final String zoomLabel;
  final VoidCallback? onPrev; // null = no previous episode
  final VoidCallback onSleep;
  final bool sleepActive;
  final String decoderLabel; // current decoder short label (HW/HW+/SW/AUTO)
  final VoidCallback onDecoder; // opens the in-player decoder picker
  final VoidCallback? onEpisodes; // null = single episode (no picker)
  final bool megaSkipEnabled; // MegaSkip pill above the seek bar
  final int megaSkipSeconds;
  final VoidCallback onMegaSkip;
  final VoidCallback? onMinimize;
  final VoidCallback? onPip; // null = PiP unsupported (hide the button)
  final VoidCallback? onSwitchPlayer; // null = no other engine to switch to
  final bool
  ambientActive; // current state of the "Ambient player screen" setting
  final VoidCallback onAmbientToggle;
  final VoidCallback? onChat; // in-room chat toggle (null = no active room)
  final VoidCallback? onInfo; // toggle the info panel (null = no fields picked)
  final bool infoOpen; // whether the info panel is currently shown
  final bool
  showQuality; // plain quality text on the top-bar right (with controls)
  final VoidCallback onScreenshot; // grab the current frame → gallery
  final VoidCallback onEnhance; // opens the video-enhancement (upscaler) picker
  final bool enhanceActive; // an upscaling preset is currently on
  final VoidCallback onColorProfile; // opens the colour-profile picker
  final bool visible; // drives the bars' slide-in (top drops, bottom rises)

  /// Overflow sheet that slides up from the bottom (like the Android player's) —
  /// holds the occasional actions so the control bars stay clean.
  void _showMore(BuildContext context) {
    showPlayerMorePanel(
      context: context,
      onInteract: onInteract,
      decoderLabel: decoderLabel,
      enhanceActive: enhanceActive,
      onDecoder: onDecoder,
      onEnhance: onEnhance,
      onColorProfile: onColorProfile,
      onScreenshot: onScreenshot,
      sleepActive: sleepActive,
      onSleep: onSleep,
      onPip: onPip,
      onMinimize: onMinimize,
      onSwitchPlayer: onSwitchPlayer,
      ambientActive: ambientActive,
      onAmbientToggle: onAmbientToggle,
      // Windows: enables Copy stream link / Open in external player.
      controller: controller,
    );
  }

  /// Shared overflow panel (decoder / enhance / colour / snapshot / sleep /
  /// PiP). The fullscreen overlay and the portrait watch page open the same
  /// panel so the occasional actions live in exactly one place.
  static void showPlayerMorePanel({
    required BuildContext context,
    required VoidCallback onInteract,
    required String decoderLabel,
    required bool enhanceActive,
    required VoidCallback onDecoder,
    required VoidCallback onEnhance,
    required VoidCallback onColorProfile,
    required VoidCallback onScreenshot,
    required bool sleepActive,
    required VoidCallback onSleep,
    required VoidCallback? onPip,
    VoidCallback? onMinimize,
    required VoidCallback? onSwitchPlayer,
    required bool ambientActive,
    required VoidCallback onAmbientToggle,
    bool animatePortraitEntrance = false,
    // Windows: the stream link / headers for the copy and external rows.
    PlayerCubit? controller,
  }) {
    // Windows: the standard docked panel, with sub-options opening inside
    // it. Phone keeps the bottom sheet below unchanged.
    if (playerMenusDocked) {
      onInteract();
      showDesktopPlayerMorePanel(
        context: context,
        decoderLabel: decoderLabel,
        enhanceActive: enhanceActive,
        onDecoder: onDecoder,
        onEnhance: onEnhance,
        onColorProfile: onColorProfile,
        onScreenshot: onScreenshot,
        sleepActive: sleepActive,
        onSleep: onSleep,
        onPip: onPip,
        controller: controller,
      );
      return;
    }
    final reduced = MediaQuery.disableAnimationsOf(context);
    onInteract();
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'More',
      barrierColor: Colors.black54,
      transitionDuration: reduced
          ? Duration.zero
          : const Duration(milliseconds: 240),
      pageBuilder: (ctx, _, _) {
        // A bottom sheet, like the Android player's More menu. Capped in width so
        // it doesn't stretch across a landscape screen.
        final size = MediaQuery.of(ctx).size;
        final w = size.width < 520 ? size.width : 520.0;
        return Align(
          alignment: Alignment.bottomCenter,
          child: Material(
            color: Colors.transparent,
            child: FrostedSurface(
              blur: true,
              opacity: 0.88,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(20),
              ),
              child: SafeArea(
                top: false,
                child: SizedBox(
                  width: w,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: size.height * 0.9),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 13, 8, 9),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  ctx.l10n.more,
                                  style: AppText.title,
                                ),
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.close_rounded,
                                  color: AppColors.textSecondary,
                                ),
                                tooltip: ctx.l10n.close,
                                onPressed: () => Navigator.of(ctx).pop(),
                              ),
                            ],
                          ),
                        ),
                        const Divider(color: AppColors.hairline, height: 1),
                        const SizedBox(height: 4),
                        Flexible(
                          child: SingleChildScrollView(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _MoreRow(
                                  icon: Icons.memory_rounded,
                                  label: ctx.l10n.decoderColon(decoderLabel),
                                  onTap: () {
                                    Navigator.pop(ctx);
                                    onDecoder();
                                  },
                                ),
                                _MoreRow(
                                  icon: enhanceActive
                                      ? Icons.auto_awesome_rounded
                                      : Icons.auto_awesome_outlined,
                                  label: ctx.l10n.anime4kEnhancement,
                                  onTap: () {
                                    Navigator.pop(ctx);
                                    onEnhance();
                                  },
                                ),
                                _MoreRow(
                                  icon: Icons.palette_outlined,
                                  label: ctx.l10n.colour,
                                  onTap: () {
                                    Navigator.pop(ctx);
                                    onColorProfile();
                                  },
                                ),
                                _MoreRow(
                                  icon: Icons.photo_camera_rounded,
                                  label: ctx.l10n.snapshot,
                                  onTap: () {
                                    Navigator.pop(ctx);
                                    onScreenshot();
                                  },
                                ),
                                _MoreRow(
                                  icon: sleepActive
                                      ? Icons.bedtime_rounded
                                      : Icons.bedtime_outlined,
                                  label: ctx.l10n.sleepTimer,
                                  onTap: () {
                                    Navigator.pop(ctx);
                                    onSleep();
                                  },
                                ),
                                if (onMinimize != null)
                                  _MoreRow(
                                    icon: Icons.close_fullscreen_rounded,
                                    label: 'Minimize player',
                                    onTap: () {
                                      Navigator.pop(ctx);
                                      onMinimize();
                                    },
                                  ),
                                if (onPip != null)
                                  _MoreRow(
                                    icon: Icons.picture_in_picture_alt_rounded,
                                    label: ctx.l10n.pictureInPicture,
                                    onTap: () {
                                      Navigator.pop(ctx);
                                      onPip();
                                    },
                                  ),
                                if (onSwitchPlayer != null)
                                  _MoreRow(
                                    icon: Icons.swap_horiz_rounded,
                                    label: ctx.l10n.switchPlayer,
                                    onTap: () {
                                      Navigator.pop(ctx);
                                      onSwitchPlayer();
                                    },
                                  ),
                                _MoreRow(
                                  icon: ambientActive
                                      ? Icons.gradient_rounded
                                      : Icons.gradient_outlined,
                                  label: ambientActive
                                      ? ctx.l10n.ambientPlayer
                                      : '${ctx.l10n.ambientPlayer} · ${ctx.l10n.off}',
                                  onTap: () {
                                    Navigator.pop(ctx);
                                    onAmbientToggle();
                                  },
                                ),
                              ],
                            ),
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
      },
      transitionBuilder: (ctx, anim, _, child) => reduced
          ? child
          : SlideTransition(
              position: Tween(begin: const Offset(0, 1), end: Offset.zero)
                  .animate(
                    CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
                  ),
              child: child,
            ),
    );
  }

  /// Whether [id] sits on any bar. Used so a control that's already placed
  /// doesn't also get drawn by one of the player's own conditional buttons.
  bool _placedAnywhere(String id) => barConfig.slotOf(id) != ControlSlot.hidden;

  /// Top-bar versions of the arrangeable controls. Plain [IconButton]s rather
  /// than the bottom bar's chips, so anything moved up here matches the row
  /// it lands in instead of importing the bottom bar's look.
  List<Widget> _topButtons(BuildContext context, List<String> ids) {
    final out = <Widget>[];
    for (final id in ids) {
      switch (id) {
        case 'cast':
          // Android only, and only where the Cast framework is actually
          // supported — the setting decides placement, not availability.
          if (Platform.isAndroid) {
            out.add(
              AnimatedBuilder(
                animation: sl<CastController>(),
                builder: (context, _) {
                  final castCtrl = sl<CastController>();
                  if (!castCtrl.castSupported) return const SizedBox.shrink();
                  return IconButton(
                    icon: Icon(
                      castCtrl.state == CastState.connected
                          ? Icons.cast_connected
                          : Icons.cast,
                      color: Colors.white,
                    ),
                    tooltip: context.l10n.cast,
                    onPressed: () => castCtrl.pickDevice(),
                  );
                },
              ),
            );
          }
        case 'info':
          if (onInfo != null) {
            out.add(
              IconButton(
                icon: Icon(
                  Icons.info_outline_rounded,
                  color: infoOpen ? AppColors.accent : Colors.white,
                ),
                tooltip: context.l10n.playbackStats,
                onPressed: onInfo,
              ),
            );
          }
        default:
          final spec = _specFor(context, id);
          if (spec != null) {
            out.add(
              IconButton(
                icon: Icon(spec.$1, color: Colors.white),
                tooltip: spec.$2,
                onPressed: spec.$3,
              ),
            );
          }
      }
    }
    return out;
  }

  /// Icon, tooltip and action for the controls that render the same wherever
  /// they're placed. Returns null when the control isn't available right now
  /// (no second quality to pick, a single-episode item, no PiP support).
  (IconData, String, VoidCallback)? _specFor(BuildContext context, String id) {
    final c = controller;
    switch (id) {
      case 'speed':
        return (Icons.speed_rounded, 'Playback speed', onSpeed);
      case 'tracks':
        return (Icons.subtitles_rounded, 'Audio & subtitles', onAudioSubs);
      case 'quality':
        // Nothing to switch inside the stream that's playing -> no button,
        // rather than a menu of other servers pretending to be qualities.
        if (state.qualities.isEmpty && c.mediaVideoTracks.length <= 1) {
          return null;
        }
        return (Icons.high_quality_rounded, 'Quality', onQuality);
      case 'sources':
        return (Icons.layers_rounded, 'Sources', onSources);
      case 'more':
        return (Icons.more_vert_rounded, 'More', () => _showMore(context));
      case 'episodes':
        if (onEpisodes == null) return null;
        return (Icons.video_library_outlined, 'Episodes', onEpisodes!);
      case 'fit':
        return (_fitIcon(zoomLabel), 'Aspect ratio · $zoomLabel', onZoom);
      case 'rotate':
        if (Platform.isWindows) {
          return (
            Icons.fullscreen_rounded,
            'Fullscreen · F / F11',
            DesktopWindow.toggleFullscreen,
          );
        }
        return (
          Icons.screen_rotation_rounded,
          portraitMode ? 'Landscape' : 'Portrait',
          onRotate,
        );
      case 'decoder':
        return (Icons.memory_rounded, 'Decoder · $decoderLabel', onDecoder);
      case 'enhance':
        return (
          enhanceActive
              ? Icons.auto_awesome_rounded
              : Icons.auto_awesome_outlined,
          'Anime4K enhancement',
          onEnhance,
        );
      case 'colour':
        return (Icons.palette_outlined, 'Colour', onColorProfile);
      case 'snapshot':
        return (Icons.photo_camera_rounded, 'Snapshot', onScreenshot);
      case 'sleep':
        return (
          sleepActive ? Icons.bedtime_rounded : Icons.bedtime_outlined,
          'Sleep timer',
          onSleep,
        );
      case 'pip':
        if (onPip == null) return null;
        return (
          Icons.picture_in_picture_alt_rounded,
          'Picture-in-picture',
          onPip!,
        );
    }
    return null; // unknown id — a layout from a newer build
  }

  /// Whether the centre spinner replaces play / pause. Phone: mpv's buffering
  /// flag as before. Windows: the flag only counts while the picture is not
  /// moving, so the spinner can never sit stuck over a playing video.
  Widget _centreBufferingGate(
    PlayerCubit c, {
    required Widget Function(BuildContext context, bool buffering) builder,
  }) {
    if (defaultTargetPlatform == TargetPlatform.windows) {
      return DesktopBufferingGate(
        bufferingStream: c.player.stream.buffering,
        initialBuffering: c.player.state.buffering,
        positionStream: c.player.stream.position,
        initialPosition: c.player.state.position,
        playingStream: c.player.stream.playing,
        initialPlaying: c.player.state.playing,
        frameStream: c.player.stream.width,
        initialFrameUp: (c.player.state.width ?? 0) > 0,
        builder: builder,
      );
    }
    return StreamBuilder<bool>(
      stream: c.player.stream.buffering,
      builder: (context, bSnap) =>
          builder(context, bSnap.data ?? c.player.state.buffering),
    );
  }

  /// Turns saved control ids into real buttons.
  ///
  /// The availability rules that were baked into the old fixed row still
  /// apply on top of the user's arrangement — Quality with nothing to pick
  /// between, Episodes on a single-episode item and PiP where the device
  /// doesn't support it drop out even if they've been placed on the bar.
  /// Anything unrecognised is skipped rather than crashing, which is what
  /// makes a layout saved by a newer build safe to load.
  List<Widget> _barButtons(BuildContext context, List<String> ids) {
    return [
      for (final id in ids)
        if (_specFor(context, id) case (final icon, final tip, final tap))
          _BarButton(icon: icon, tooltip: tip, onTap: tap),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final ep = c.currentEpisode;
    final epNum = ep.number?.toInt() ?? state.currentIndex + 1;
    // The episode's own name, but only when it's more than a generic
    // "Episode N" / bare number (many sources just echo the number there).
    // Windows: the same name the watch page and episode list show, so a name
    // looked up from AniZip / TMDB (Episode.metaTitle) is used when the source
    // only says "Episode 1". Phone keeps the source title as before.
    final epName = playerHeaderEpisodeName(
      ep,
      epNum,
      windows: defaultTargetPlatform == TargetPlatform.windows,
    );
    final hasEpName = epName != null;
    // Line 1 = show name (falls back to "Episode N" when no show title).
    final primaryTitle = showTitle ?? 'Episode $epNum';
    // Line 2 = "E5 · Episode Name" — only when there's a show name above it to
    // pair with (otherwise line 1 already carries the episode number).
    // Windows: a film gets no E-line at all (see [playerHeaderSecondLine]).
    final secondaryTitle = playerHeaderSecondLine(
      showTitle: showTitle,
      epNum: epNum,
      epName: hasEpName ? epName : null,
      isMovie: isMovie,
    );
    // Quality appended to the E-line when enabled — prefers
    // the source's quality label, else the live video height (e.g. "1080p").
    String? qualityLabel;
    if (showQuality) {
      final q = state.active?.quality?.trim();
      if (q != null && q.isNotEmpty && q.toLowerCase() != 'auto') {
        qualityLabel = q;
      } else {
        final h = c.player.state.height ?? 0;
        if (h > 0) qualityLabel = '${h}p';
      }
    }
    final secondaryLine = qualityLabel == null
        ? secondaryTitle
        : (secondaryTitle == null
              ? qualityLabel
              : '$secondaryTitle · $qualityLabel');
    // Not just "is there another entry" — an episode nothing has yet is not a
    // next episode. Shared with the outro pill, the Up-next card and autoplay
    // so every Next affordance agrees.
    final hasNext = c.hasPlayableNext;
    // Movies and one-off items have nowhere to step, so they get a lone play
    // button rather than two arrows that can never do anything.
    final multiEpisode = c.episodes.length > 1;

    return Stack(
      fit: StackFit.expand,
      children: [
        // Top scrim.
        const Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: 110,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x59000000), Color(0x00000000)],
                ),
              ),
            ),
          ),
        ),
        // Bottom scrim. There were two of these stacked at each end — 0xCC over
        // 0x99 up top, 0xE6 over 0xB3 down here — which is why showing the
        // controls dropped a heavy curtain over the video. One gentle pass each
        // way is plenty to keep white text legible on a bright frame.
        const Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          height: 170,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Color(0x8C000000), Color(0x00000000)],
                ),
              ),
            ),
          ),
        ),

        // Top bar.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            bottom: false,
            // Vertical insets only. Now that the window draws into the display
            // cutout, the horizontal safe inset is the camera's — and it exists
            // on one edge only, so honouring it shunts the whole bar sideways
            // and the margins stop matching. The cutout sits mid-edge; this bar
            // is pinned to the top, so they never meet.
            left: false,
            right: false,
            child: Padding(
              // 32, not the bottom block's 44, and the difference is on
              // purpose: these are IconButtons, which reserve 12px around the
              // glyph before it draws (8 default padding, plus 4 stretching the
              // 40px button out to the 48px minimum touch target). 32 + 12 puts
              // the back arrow on 44 — the exact line the bottom capsules start
              // at. Writing 44 here would land it at 56 and overshoot inward.
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 4),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(
                      Icons.arrow_back_rounded,
                      color: Colors.white,
                    ),
                    tooltip: context.l10n.back,
                    onPressed: onBack,
                  ),
                  // Text hit-tests as opaque (RenderParagraph.hitTestSelf is
                  // true), so the title used to eat taps aimed at the video —
                  // a wide dead strip across the top where tapping did nothing.
                  // Nothing here is interactive, so let taps fall through to the
                  // zones below and toggle the controls like anywhere else.
                  // On Windows (onShowPage set) the title lines double as the
                  // link to the show page.
                  Expanded(
                    child: onShowPage != null
                        ? _ShowAfterFirstFrame(
                            controller: c,
                            child: _TopBarTitle(
                              title: primaryTitle,
                              secondaryLine: secondaryLine,
                              onShowPage: onShowPage,
                              badge: ValueListenableBuilder<Set<int>>(
                                valueListenable: c.fillerEpisodes,
                                builder: (context, _, _) =>
                                    c.isFillerAt(state.currentIndex)
                                    ? const Padding(
                                        padding: EdgeInsetsDirectional.only(
                                          start: 8,
                                        ),
                                        child: TagBadge(text: 'FILLER'),
                                      )
                                    : const SizedBox.shrink(),
                              ),
                            ),
                          )
                        : IgnorePointer(
                      child: _ShowAfterFirstFrame(
                        // Show / episode names stay hidden behind the startup
                        // loader, then fade in.
                        controller: c,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    primaryTitle,
                                    style: AppText.headline.copyWith(
                                      color: Colors.white,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                // Refresh when Tenrai metadata arrives.
                                ValueListenableBuilder<Set<int>>(
                                  valueListenable: c.fillerEpisodes,
                                  builder: (context, _, _) =>
                                      c.isFillerAt(state.currentIndex)
                                      ? const Padding(
                                          padding: EdgeInsetsDirectional.only(
                                            start: 8,
                                          ),
                                          // No colour passed: TagBadge falls back
                                          // to the app accent, so the badge
                                          // follows the user's theme colour.
                                          child: TagBadge(text: 'FILLER'),
                                        )
                                      : const SizedBox.shrink(),
                                ),
                              ],
                            ),
                            if (secondaryLine != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 1),
                                child: Text(
                                  secondaryLine,
                                  style: AppText.caption.copyWith(
                                    color: Colors.white70,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // Whatever the user put up here, in their order. Cast and
                  // the ⓘ stats toggle live here by default; anything else in
                  // the registry can be moved up in Settings.
                  ..._topButtons(context, barConfig.top),
                  // Sleep timer armed — a visible accent moon; tap to adjust or
                  // cancel. Only shown while a timer / end-of-episode is set,
                  // and only when Sleep isn't already placed somewhere, or an
                  // armed timer would show two of the same button.
                  if (sleepActive && !_placedAnywhere('sleep'))
                    IconButton(
                      icon: Icon(
                        Icons.bedtime_rounded,
                        color: AppColors.accent,
                      ),
                      tooltip: context.l10n.sleepTimerOn,
                      onPressed: onSleep,
                    ),
                  // Episodes and ⋮ More live in the bottom bar now — a second
                  // copy up here just split the same action across two places.
                  // Lock stays: it's the one control you want reachable without
                  // looking down at the bar you're about to hide.
                  if (!Platform.isWindows)
                    IconButton(
                      icon: const Icon(
                        Icons.lock_open_rounded,
                        color: Colors.white,
                      ),
                      tooltip: context.l10n.lockControls,
                      onPressed: onLock,
                    ),
                  IconButton(
                    icon: const Icon(
                      Icons.settings_rounded,
                      color: Colors.white,
                    ),
                    tooltip: context.l10n.settingsTooltip,
                    onPressed: onSettings,
                  ),
                  if (onChat != null)
                    IconButton(
                      icon: const Icon(
                        Icons.chat_bubble_outline_rounded,
                        color: Colors.white,
                      ),
                      tooltip: context.l10n.chat,
                      onPressed: onChat,
                    ),
                ],
              ),
            ),
          ),
        ),

        // Centre transport — episode step either side of play/pause. The ±10s
        // buttons used to live here, but they jumped a hardcoded 10s while
        // double-tap honoured the user's Double-tap skip setting, so the two
        // disagreed; seeking is covered by double-tap, drag-to-seek and the
        // MegaSkip pill, all of which read the same preference. Windows has no
        // double-tap (double-click is fullscreen), so it gets them back there,
        // jumping by the same step as the arrow keys.
        Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (multiEpisode) ...[
                _TransportButton(
                  icon: Icons.skip_previous_rounded,
                  label: context.l10n.previousEpisode,
                  onTap: onPrev,
                ),
                const SizedBox(width: 24),
              ],
              // Windows: seek back by the arrow-key step, just left of
              // play / pause. Phone never passes onSeekStep, so its row
              // is unchanged.
              if (onSeekStep != null) ...[
                _SeekStepButton(
                  key: const ValueKey('player-seek-back'),
                  seconds: -seekStepSeconds,
                  onTap: () {
                    onSeekStep!(-seekStepSeconds);
                    onInteract();
                  },
                ),
                const SizedBox(width: 24),
              ],
              StreamBuilder<int?>(
                stream: c.player.stream.width,
                initialData: c.player.state.width,
                builder: (context, frame) {
                  return _centreBufferingGate(
                    c,
                    builder: (context, buffering) {
                      // While buffering, show the spinner IN PLACE OF the play/pause
                      // button — no more spinner-over-button overlap. 58px matches
                      // _AnimatedPlayPause's disc exactly, so the episode arrows
                      // don't twitch every time playback stalls.
                      if (buffering) {
                        if ((frame.data ?? 0) <= 0) {
                          return const SizedBox(width: 58, height: 58);
                        }
                        return const SizedBox(
                          width: 58,
                          height: 58,
                          child: Center(
                            child: SizedBox(
                              width: 32,
                              height: 32,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 3,
                              ),
                            ),
                          ),
                        );
                      }
                      return StreamBuilder<bool>(
                        stream: c.player.stream.playing,
                        builder: (context, snap) {
                          final playing = snap.data ?? c.player.state.playing;
                          return _AnimatedPlayPause(
                            playing: playing,
                            onTap: () {
                              c.togglePlay();
                              onInteract();
                            },
                          );
                        },
                      );
                    },
                  );
                },
              ),
              // Windows: seek forward by the same step, right of play / pause.
              if (onSeekStep != null) ...[
                const SizedBox(width: 24),
                _SeekStepButton(
                  key: const ValueKey('player-seek-forward'),
                  seconds: seekStepSeconds,
                  onTap: () {
                    onSeekStep!(seekStepSeconds);
                    onInteract();
                  },
                ),
              ],
              if (multiEpisode) ...[
                const SizedBox(width: 24),
                _TransportButton(
                  icon: Icons.skip_next_rounded,
                  label: context.l10n.nextEpisode2,
                  onTap: hasNext
                      ? () {
                          c.playNext();
                          onInteract();
                        }
                      : null,
                ),
              ],
            ],
          ),
        ),

        // Bottom: seek row + buttons. Rises into place as it fades in — the
        // motion reads as instant even when the tap resolves a beat later.
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: AnimatedSlide(
            offset: visible ? Offset.zero : const Offset(0, 0.14),
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            child: SafeArea(
              top: false,
              // Vertical inset only — the bottom one keeps the bar clear of the
              // gesture nav. See the top bar for why the horizontal cutout inset
              // is skipped: it lands on one edge only and pushed this whole block
              // sideways, leaving a fat gap on the camera side and a thin one
              // opposite. The camera sits mid-edge, well clear of this bar.
              left: false,
              right: false,
              child: Padding(
                // One margin for the whole block — timestamp, progress bar and
                // both button groups share it, so every edge lines up. Kept wide
                // so the controls sit clear of the screen edges.
                padding: const EdgeInsets.fromLTRB(44, 0, 44, 14),
                // Measured so the Skip pill can sit just above this block.
                child: _ReportBottomBlockHeight(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Duration tracker (off-screen listener via StreamBuilder).
                      StreamBuilder<Duration>(
                        stream: c.player.stream.duration,
                        initialData: c.player.state.duration,
                        builder: (context, snap) {
                          final d = snap.data ?? duration;
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (d > Duration.zero) onDurationChanged(d);
                          });
                          return PlayerSeekBar(
                            controller: c,
                            duration: d > Duration.zero ? d : duration,
                            onInteract: onInteract,
                            // MegaSkip — manual jump-forward, riding the timestamp's
                            // line rather than a row of its own above it.
                            trailing: megaSkipEnabled
                                ? _MegaSkipPill(
                                    seconds: megaSkipSeconds,
                                    onTap: onMegaSkip,
                                  )
                                : null,
                          );
                        },
                      ),
                      const SizedBox(height: 2),
                      // Control bar under the progress bar: the pickers ride in one
                      // translucent group on the left, episode list + fit mode in
                      // another on the right. Two groups rather than seven floating
                      // chips — the split reads at a glance, and every button is the
                      // same width so nothing shifts as the video changes.
                      LayoutBuilder(
                        builder: (context, constraints) {
                          // Rendered from the user's saved arrangement rather than
                          // a fixed row. Untouched prefs give the defaults, which
                          // are the exact layout that shipped before the Settings
                          // screen existed — so nobody's bar moves unless they
                          // move it.
                          final left = _barButtons(context, barConfig.left);
                          final right = _barButtons(context, barConfig.right);
                          if (Platform.isWindows) {
                            left.insert(
                              0,
                              SizedBox(
                                width: 148,
                                child: StreamBuilder<double>(
                                  stream: c.player.stream.volume,
                                  initialData: c.player.state.volume,
                                  builder: (context, snapshot) {
                                    // player-6: the slider is the 0-100
                                    // user level; the saved volume boost is
                                    // applied on top by the controller, so
                                    // dragging never resets it.
                                    final level = c.userVolumeFromMpv(
                                      snapshot.data ?? 100,
                                    );
                                    return Row(
                                      children: [
                                        Tooltip(
                                          message: context.l10n.volumeTooltipKeys,
                                          // Click toggles mute and comes
                                          // back to the previous level.
                                          child: InkWell(
                                            key: const ValueKey(
                                              'player-volume-mute',
                                            ),
                                            customBorder: const CircleBorder(),
                                            onTap: () {
                                              c.toggleUserMute();
                                              onInteract();
                                            },
                                            child: Icon(
                                              level <= 0
                                                  ? Icons.volume_off_rounded
                                                  : Icons.volume_up_rounded,
                                              color: Colors.white,
                                              size: 20,
                                            ),
                                          ),
                                        ),
                                        Expanded(
                                          child: Slider(
                                            value: level,
                                            max: 100,
                                            onChanged: (value) {
                                              c.setUserVolume(value);
                                              onInteract();
                                            },
                                          ),
                                        ),
                                      ],
                                    );
                                  },
                                ),
                              ),
                            );
                            // Windows: mini player and theatre buttons, in
                            // theatre mode and in full screen alike. The
                            // theatre button goes back towards the watch
                            // page (full screen drops to theatre first).
                            if (onMiniPlayer != null) {
                              right.add(
                                _BarButton(
                                  key: const ValueKey('player-mini-player'),
                                  icon: Icons.picture_in_picture_alt_rounded,
                                  tooltip: desktopPlayerTip(
                                    context.l10n.shortcutPlayerMiniPlayer,
                                    'player.miniPlayer',
                                  ),
                                  onTap: onMiniPlayer!,
                                ),
                              );
                            }
                            if (onTheatre != null) {
                              right.add(
                                _BarButton(
                                  key: const ValueKey('player-theatre'),
                                  icon: Icons.crop_7_5_rounded,
                                  tooltip: desktopPlayerTip(
                                    fullScreen
                                        ? context.l10n.theatreMode
                                        : context.l10n.exitTheatreMode,
                                    'player.theatre',
                                  ),
                                  onTap: () {
                                    onInteract();
                                    onTheatre!();
                                  },
                                ),
                              );
                            }
                            // player-5: opens the '?' shortcut overlay
                            // (player keys first, remaps included) instead
                            // of a hover-only tooltip.
                            right.add(
                              IconButton(
                                key: const ValueKey('player-shortcuts-help'),
                                tooltip: context.l10n.keyboardShortcutsWithKey,
                                icon: const Icon(
                                  Icons.keyboard_rounded,
                                  color: Colors.white,
                                ),
                                onPressed: () {
                                  onInteract();
                                  showPlayerShortcutsHelp(context);
                                },
                              ),
                            );
                          }
                          // Buttons are a uniform 48 (12 padding + 24 icon + 12)
                          // and each group adds 8 of its own, so the width the bar
                          // wants is arithmetic rather than something to measure.
                          const buttonWidth = 48.0;
                          const groupPadding = 8.0;
                          double groupWidth(int n) =>
                              n == 0 ? 0 : n * buttonWidth + groupPadding;
                          final wanted =
                              groupWidth(left.length) +
                              groupWidth(right.length) +
                              (Platform.isWindows ? 100 : 0);

                          if (wanted <= constraints.maxWidth) {
                            return Row(
                              children: [
                                if (left.isNotEmpty) _BarGroup(children: left),
                                const Spacer(),
                                if (right.isNotEmpty)
                                  _BarGroup(children: right),
                              ],
                            );
                          }
                          // Narrower than the bar wants — portrait, or a bar the
                          // user has loaded up in Settings. The Spacer pins the
                          // groups to opposite edges and can't give any width back,
                          // so the right-hand group would run off-screen and take
                          // its buttons out of reach. Scroll the pair instead:
                          // everything stays tappable, and nothing about the
                          // landscape layout above changes.
                          return SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                if (left.isNotEmpty) _BarGroup(children: left),
                                if (left.isNotEmpty && right.isNotEmpty)
                                  const SizedBox(width: 8),
                                if (right.isNotEmpty)
                                  _BarGroup(children: right),
                              ],
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The player top bar's title block: show title (plus [badge]) and the
/// episode line under it.
///
/// With [onShowPage] (Windows only) both lines act as one link to the show
/// page: hand cursor, an underline on hover, an "Open show page" tooltip and
/// a click that runs [onShowPage]. The hit area hugs the text, so clicks on
/// the empty bar beside it still reach the video and toggle the controls.
///
/// Without it (phone, local files) the block is wrapped in [IgnorePointer]:
/// Text hit-tests as opaque (RenderParagraph.hitTestSelf is true), so the
/// title would otherwise eat taps aimed at the video — a wide dead strip
/// across the top where tapping did nothing.
class _TopBarTitle extends StatefulWidget {
  const _TopBarTitle({
    required this.title,
    required this.secondaryLine,
    required this.badge,
    this.onShowPage,
  });

  final String title;

  /// Episode line ("E1", "S1 · E3 · Name"); null hides it.
  final String? secondaryLine;

  /// Trailing decoration on the title row (the FILLER tag). Never clickable.
  final Widget badge;

  /// Opens the show page; null keeps the title inert.
  final VoidCallback? onShowPage;

  @override
  State<_TopBarTitle> createState() => _TopBarTitleState();
}

/// State of [_TopBarTitle]: whether the pointer is over the link.
class _TopBarTitleState extends State<_TopBarTitle> {
  /// The pointer is over either line. Shared, so both lines underline
  /// together and read as a single link.
  bool _hover = false;

  /// Updates [_hover], rebuilding only when it changes.
  void _setHover(bool value) {
    if (_hover != value) setState(() => _hover = value);
  }

  /// Wraps one line of text in the show-page link (cursor, hover, tooltip,
  /// click). The wrappers are all proxies, so the hit area stays the text's
  /// own size.
  Widget _link(Key key, Widget text) {
    final onShowPage = widget.onShowPage;
    if (onShowPage == null) return text;
    return Tooltip(
      message: 'Open show page',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => _setHover(true),
        onExit: (_) => _setHover(false),
        child: GestureDetector(
          key: key,
          // Opaque: a click on a gap between glyphs still counts.
          behavior: HitTestBehavior.opaque,
          onTap: onShowPage,
          child: text,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Underline only while hovered, and only when there is a link at all.
    final underline = widget.onShowPage != null && _hover
        ? TextDecoration.underline
        : TextDecoration.none;
    final secondary = widget.secondaryLine;
    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Flexible(
              child: _link(
                const ValueKey('player-title-link'),
                Text(
                  widget.title,
                  style: AppText.headline.copyWith(
                    color: Colors.white,
                    decoration: underline,
                    decorationColor: Colors.white,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            // The badge is not part of the link; let taps on it fall through.
            IgnorePointer(child: widget.badge),
          ],
        ),
        if (secondary != null)
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: _link(
              const ValueKey('player-episode-link'),
              Text(
                secondary,
                style: AppText.caption.copyWith(
                  color: Colors.white70,
                  decoration: underline,
                  decorationColor: Colors.white70,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
      ],
    );
    // Phone / no show: nothing here is interactive, so let taps through.
    return widget.onShowPage == null ? IgnorePointer(child: column) : column;
  }
}

/// Line 2 of the player top bar: "E5 · Episode Name" (or just "E5"). Null
/// when there is no show name above it (line 1 then already carries the
/// number) and, on Windows, for a film ([isMovie]): a movie is one item, so
/// "E1 · The Odyssey" only repeated its title. Phone never passes isMovie.
@visibleForTesting
String? playerHeaderSecondLine({
  required String? showTitle,
  required int epNum,
  required String? epName,
  bool isMovie = false,
}) {
  if (showTitle == null || isMovie) return null;
  return 'E$epNum${epName != null ? ' · $epName' : ''}';
}

/// The episode name shown after "E5 ·" in the player top bar, or null when
/// there is no real name (the source only echoes "Episode 5" or "5").
///
/// Windows reads the same name the watch page and episode list show, so a
/// name looked up from AniZip / TMDB ([Episode.metaTitle]) is used when the
/// source has none. Phone keeps the source title exactly as before.
@visibleForTesting
String? playerHeaderEpisodeName(
  Episode ep,
  int epNum, {
  required bool windows,
}) {
  // Windows: the line already starts with "E5 ·", so a name that repeats
  // the number ("E5 — Name", "Episode 5: Name", "#5 Name") loses it.
  final name = windows
      ? stripRepeatedEpisodeNumber(
          episodeDisplayTitle(ep, number: epNum) ?? '',
          epNum,
        )
      : ep.title.trim();
  final real =
      name.isNotEmpty &&
      name.toLowerCase() != 'episode $epNum' &&
      name != '$epNum';
  return real ? name : null;
}

/// Windows: [name] without a leading copy of episode number [n], so the
/// header shows "E1166 · Encountering Loki" and not "E1166 · E1166 —
/// Encountering Loki". Handles "E1166", "Ep. 1166", "Episode 1166", "#1166",
/// "S1E1166" / "S01 E1166" and a bare "1166." / "1166 -" in front, followed by
/// any of : - – — . · | ) ]. Repeats so "E5 · Episode 5: Name" is cleaned too.
/// A different number ("E1167 …") or a number that is part of the name
/// ("100 Ways…") is left alone. Empty when the name was only the number.
@visibleForTesting
String stripRepeatedEpisodeNumber(String name, int n) {
  // A marker word / symbol in front of the number: the separator after it
  // is optional ("E1166 Encountering").
  final marked = RegExp(
    '^(?:s\\d+\\s*)?(?:episode|ep\\.?|e|#)\\s*0*$n(?![0-9])'
    '\\s*[:\\-–—.·|)\\]]*\\s*',
    caseSensitive: false,
  );
  // A bare number needs a separator after it, so "100 Ways" stays a name.
  final bare = RegExp('^0*$n(?![0-9])\\s*[:\\-–—.·|)\\]]+\\s*');
  // Separators left at the front once a number is gone.
  final leftover = RegExp('^[\\s:\\-–—.·|]+');
  // The name may already arrive with a separator in front ("· E5 — Name"
  // once an earlier step dropped the first "E5"), so clear that first.
  var out = name.trim().replaceFirst(leftover, '').trim();
  for (var i = 0; i < 4; i++) {
    final m = marked.firstMatch(out) ?? bare.firstMatch(out);
    if (m == null) break;
    out = out.substring(m.end).replaceFirst(leftover, '').trim();
  }
  return out;
}

/// Test hook: the Windows seek back / forward disc, which is private.
@visibleForTesting
Widget debugPlayerSeekStepButton({
  required int seconds,
  required VoidCallback onTap,
}) => _SeekStepButton(seconds: seconds, onTap: onTap);

/// Test hook: the player top bar's title block, which is private.
@visibleForTesting
Widget debugPlayerTopBarTitle({
  required String title,
  String? secondaryLine,
  VoidCallback? onShowPage,
}) => _TopBarTitle(
  title: title,
  secondaryLine: secondaryLine,
  badge: const SizedBox.shrink(),
  onShowPage: onShowPage,
);

/// Test hook: opens the shared "More" panel, which lives on a private class.
@visibleForTesting
void debugShowPlayerMorePanel(
  BuildContext context, {
  VoidCallback? onSleep,
  VoidCallback? onDecoder,
  VoidCallback? onPip,
}) => _ControlsOverlay.showPlayerMorePanel(
      context: context,
      onInteract: () {},
      decoderLabel: 'HW',
      enhanceActive: false,
      onDecoder: onDecoder ?? () {},
      onEnhance: () {},
      onColorProfile: () {},
      onScreenshot: () {},
      sleepActive: false,
      onSleep: onSleep ?? () {},
      onPip: onPip,
      onSwitchPlayer: null,
      ambientActive: false,
      onAmbientToggle: () {},
    );

// ─────────────────────────────────────────────────────────────────────────────
// Seek row — current time + slider (stream-bound) + total time.
// ─────────────────────────────────────────────────────────────────────────────

/// Fades its child in once the first video frame is up — or playback has
/// started, so audio-only media (no frame, ever) isn't left without a title.
/// Latches: a later source switch resetting the width doesn't hide it again.
class _ShowAfterFirstFrame extends StatefulWidget {
  const _ShowAfterFirstFrame({required this.controller, required this.child});

  final PlayerCubit controller;
  final Widget child;

  @override
  State<_ShowAfterFirstFrame> createState() => _ShowAfterFirstFrameState();
}

class _ShowAfterFirstFrameState extends State<_ShowAfterFirstFrame> {
  late bool _shown = _ready();
  final _subs = <StreamSubscription<Object?>>[];

  bool _ready() {
    final p = widget.controller.player.state;
    return (p.width ?? 0) > 0 || p.playing;
  }

  void _check() {
    if (!_shown && mounted && _ready()) setState(() => _shown = true);
  }

  @override
  void initState() {
    super.initState();
    final s = widget.controller.player.stream;
    _subs
      ..add(s.width.listen((_) => _check()))
      ..add(s.playing.listen((_) => _check()));
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      sub.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
    opacity: _shown ? 1 : 0,
    duration: const Duration(milliseconds: 250),
    child: widget.child,
  );
}
