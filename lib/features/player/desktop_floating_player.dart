// Windows only: the in-app floating mini player.
//
// The mini player button in the player's bottom bar (watch page, theatre and
// full screen, plus Ctrl+M and the right-click / More menus) closes the
// player page and keeps the SAME playback going in a small card that floats
// in a corner above the whole app. The card lives above the app's Navigator
// (see main.dart), so it stays on screen through every page change, the
// sidebar pages and dialogs.
//
// Nothing is restarted: the card shows the same PlayerCubit and media_kit
// Player the page was using. The page hands them over instead of closing
// them, and the card either hands them back to a new player page (expand) or
// closes them exactly like leaving the player normally (close).
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/di/injector.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/ui/global_messenger.dart';
import '../../core/zmode/playback_resolver.dart';
import '../../l10n/l10n.dart';
import '../watch_together/watch_together_controller.dart';
import 'episode_player_route.dart';
import 'player_controller.dart';
import 'player_lifecycle.dart';
import 'subtitle_style.dart';

/// One playback handed from the player page to the floating card.
class FloatingPlayback {
  FloatingPlayback({
    required this.cubit,
    required this.reopen,
    this.layout = PlayerPresentation.watchPage,
    this.fullScreen = false,
    PlayerRouteTeardownLease? lease,
    this.roomAttached = false,
    this.title,
  }) : _lease = lease;

  /// The live player session (owns the media_kit Player). Kept running.
  final PlayerCubit cubit;

  /// Builds a player page that takes this playback over (expand).
  final Widget Function(FloatingPlayback playback) reopen;

  /// The page layout the video came from (watch page or theatre).
  final PlayerPresentation layout;

  /// Whether the window was full screen when the video floated.
  final bool fullScreen;

  /// Whether a Watch Together room had this player attached.
  final bool roomAttached;

  /// Show (or episode) name shown on the card.
  final String? title;

  /// The page's "a player is alive" lease (detail trailers wait for it to be
  /// released). It moves with the playback: card, then the reopened page.
  PlayerRouteTeardownLease? _lease;

  /// Set by the player page once it has really taken this playback over
  /// after expand. While false, the playback still has no owner: if the
  /// pushed page goes away before it gets that far, the manager closes it.
  bool adopted = false;

  /// Hands the lease to whoever owns the playback next. Only once.
  PlayerRouteTeardownLease? takeLease() {
    final lease = _lease;
    _lease = null;
    return lease;
  }
}

/// The corner the card sits in.
enum FloatingCorner { topLeft, topRight, bottomLeft, bottomRight }

/// The one floating playback of the app (Windows only).
class DesktopFloatingPlayer extends ChangeNotifier {
  DesktopFloatingPlayer._();

  static final DesktopFloatingPlayer instance = DesktopFloatingPlayer._();

  /// The navigator expand pushes the player page on. Tests can swap it.
  @visibleForTesting
  GlobalKey<NavigatorState> navigatorKey = rootNavigatorKey;

  FloatingPlayback? _current;
  final List<StreamSubscription<dynamic>> _subs = [];
  VoidCallback? _roomListener;

  /// Where the card sits; kept for the next floating video too.
  FloatingCorner corner = FloatingCorner.bottomRight;

  /// The playback floating right now, or null.
  FloatingPlayback? get current => _current;

  /// True while a video floats in the card.
  bool get isActive => _current != null;

  /// True while the floating video is actually playing.
  bool get isPlaying {
    final p = _current;
    if (p == null || p.cubit.isClosed) return false;
    return p.cubit.player.state.playing;
  }

  /// Takes a playback over from the player page. A video already floating is
  /// saved and stopped first, so only one plays at a time.
  Future<void> adopt(FloatingPlayback playback) async {
    if (identical(_current, playback)) return;
    final old = _current;
    if (old != null) _unwatch(old);
    _current = playback;
    _watch(playback);
    _notify();
    if (old != null) await _shutDown(old);
  }

  /// Hands the playback back without closing it (expand). Null when nothing
  /// floats.
  FloatingPlayback? takeForExpand() {
    final p = _current;
    if (p == null) return null;
    _current = null;
    _unwatch(p);
    _notify();
    return p;
  }

  /// Opens the full player page again for the floating playback, in the
  /// layout it came from and at the same position (nothing restarts).
  bool expand() {
    final nav = navigatorKey.currentState;
    if (nav == null || _current == null) return false;
    final p = takeForExpand()!;
    unawaited(
      nav.push(EpisodePlayerRoute(builder: (_) => p.reopen(p))).whenComplete(
        () {
          // The page went away before it took the playback over (popped at
          // once, or replaced): nobody owns the player, so close it here
          // instead of leaving it playing with no screen.
          if (!p.adopted) unawaited(_shutDown(p));
        },
      ),
    );
    return true;
  }

  /// Stops the floating video: saves progress and history, ends the Discord
  /// presence and frees the player, exactly like leaving the player page.
  Future<void> close() async {
    final p = _current;
    if (p == null) return;
    _current = null;
    _unwatch(p);
    _notify();
    await _shutDown(p);
  }

  /// Play / pause from the card or the Space key.
  void togglePlay() {
    final p = _current;
    if (p == null || p.cubit.isClosed) return;
    p.cubit.togglePlay();
  }

  /// Pauses the floating video without closing it, for pages that play
  /// sound of their own (the trailer page). Does nothing when nothing
  /// floats, so it is safe to call on every platform.
  void pause() {
    final p = _current;
    if (p != null && !p.cubit.isClosed) {
      unawaited(p.cubit.player.pause().catchError((Object _) {}));
    }
  }

  /// Moves the card to [next] (after a drag).
  void moveTo(FloatingCorner next) {
    if (corner == next) return;
    corner = next;
    _notify();
  }

  // Tells the card layer about a change. A new player page closes the card
  // from its initState, which runs while the app is building; the layer is
  // not part of that page, so rebuilding it right then is not allowed. In
  // that case the layer is told just after the frame instead. The playback
  // itself still stops at once (close() pauses it straight away).
  void _notify() {
    final binding = SchedulerBinding.instance;
    if (binding.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      binding.addPostFrameCallback((_) => notifyListeners());
    } else {
      notifyListeners();
    }
  }

  /// Space toggles play while a video floats, unless something focused
  /// wants the Space key itself (a text field, a focused button). Only
  /// keys nobody else handled reach this. Esc is left alone on purpose.
  KeyEventResult handleKey(KeyEvent event) {
    if (!isActive || event.logicalKey != LogicalKeyboardKey.space) {
      return KeyEventResult.ignored;
    }
    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed ||
        keys.isAltPressed ||
        keys.isShiftPressed ||
        keys.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    if (_focusWantsSpace()) return KeyEventResult.ignored;
    if (event is KeyDownEvent) togglePlay();
    return KeyEventResult.handled;
  }

  static bool _focusWantsSpace() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    if (ctx.findAncestorStateOfType<EditableTextState>() != null) return true;
    final press = Actions.maybeFind<ActivateIntent>(ctx);
    return press != null && press.isEnabled(const ActivateIntent());
  }

  // Jobs the player page did while it was open and the card now does: the
  // media Stop key, next-episode autoplay and the Watch Together role.
  void _watch(FloatingPlayback p) {
    final cubit = p.cubit;
    cubit.onDesktopMediaStop = () => unawaited(close());
    _subs.add(
      cubit.player.stream.completed.listen((done) {
        if (!done || cubit.isClosed || !identical(_current, p)) return;
        final autoplay =
            !sl.isRegistered<PlaybackPrefs>() ||
            sl<PlaybackPrefs>().autoplayNext;
        // No 5 second "Up next" card here: the small card just moves on.
        if (autoplay && cubit.hasPlayableNext) {
          unawaited(cubit.playNext(auto: true));
        }
      }),
    );
    if (p.roomAttached && sl.isRegistered<WatchTogetherController>()) {
      final room = sl<WatchTogetherController>();
      void listener() => cubit.roomRole = room.role;
      _roomListener = listener;
      room.addListener(listener);
    }
  }

  void _unwatch(FloatingPlayback p) {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    final listener = _roomListener;
    _roomListener = null;
    if (listener != null && sl.isRegistered<WatchTogetherController>()) {
      sl<WatchTogetherController>().removeListener(listener);
    }
    if (!p.cubit.isClosed) p.cubit.onDesktopMediaStop = null;
  }

  // The same teardown the player page runs in dispose().
  Future<void> _shutDown(FloatingPlayback p) async {
    if (p.roomAttached && sl.isRegistered<WatchTogetherController>()) {
      sl<WatchTogetherController>().detachPlayer();
    }
    if (sl.isRegistered<PlaybackResolver>()) {
      sl<PlaybackResolver>().abortSweeps();
    }
    final lease = p.takeLease();
    final cubit = p.cubit;
    if (cubit.isClosed) {
      lease?.release();
      return;
    }
    // Sound stops at once; then the resume mark and history are written and
    // waited for, so whoever closed the card (a profile switch) knows the
    // save has landed in the profile that watched the video.
    unawaited(cubit.player.pause().catchError((Object _) {}));
    await cubit.flushProgress();
    if (cubit.isClosed) {
      lease?.release();
      return;
    }
    final closing = cubit.close();
    unawaited(cubit.nativeTeardown.whenComplete(() => lease?.release()));
    await closing;
  }

  /// Clears everything between tests.
  @visibleForTesting
  void debugReset() {
    final p = _current;
    if (p != null) _unwatch(p);
    _current = null;
    corner = FloatingCorner.bottomRight;
    navigatorKey = rootNavigatorKey;
  }
}

/// Stops a video floating in the mini player before the viewer profile (or
/// the account) changes. History is kept per profile: this waits until the
/// last resume mark and history entry are written, so they land in the
/// profile that watched the video, not the next one. Every profile switch
/// and log-out path calls it. It does nothing when nothing floats, which is
/// always the case off Windows.
Future<void> closeFloatingPlayerBeforeProfileSwitch() =>
    DesktopFloatingPlayer.instance.close();

/// Windows only: pauses the floating video when a page opens that plays
/// sound of its own (the trailer page), so two videos never play at once.
/// The card stays, paused, and can be played again from it.
void pauseFloatingPlayerForOwnSound() {
  if (defaultTargetPlatform != TargetPlatform.windows) return;
  DesktopFloatingPlayer.instance.pause();
}

/// Tests draw a plain box instead of the native video texture.
@visibleForTesting
Widget Function(PlayerCubit cubit)? debugFloatingVideoBuilder;

/// Wraps the app so Space reaches the floating card (Windows only). Sits
/// above the Navigator: only key events no page handled bubble up to it.
class DesktopFloatingPlayerKeys extends StatelessWidget {
  const DesktopFloatingPlayerKeys({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.windows) return child;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, event) => DesktopFloatingPlayer.instance.handleKey(event),
      child: child,
    );
  }
}

/// The layer that shows the floating card above the whole app. Empty (and
/// click-through) while nothing floats. Draws nothing off Windows.
class DesktopFloatingPlayerLayer extends StatelessWidget {
  const DesktopFloatingPlayerLayer({super.key});

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.windows) {
      return const SizedBox.shrink();
    }
    final host = DesktopFloatingPlayer.instance;
    return ListenableBuilder(
      listenable: host,
      builder: (context, _) {
        final p = host.current;
        if (p == null) return const SizedBox.shrink();
        return LayoutBuilder(
          builder: (context, box) => Stack(
            children: [
              _FloatingCard(
                key: ObjectKey(p),
                playback: p,
                area: box.biggest,
                corner: host.corner,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Space between the card and the window edge.
const double _kFloatingMargin = 16;

/// Card size for an [area]: about 400x225 (16:9), smaller in a small window.
@visibleForTesting
Size floatingCardSize(Size area) {
  final room = (area.width - 2 * _kFloatingMargin).clamp(160.0, 400.0);
  final byHeight = ((area.height - 2 * _kFloatingMargin) * 16 / 9).clamp(
    160.0,
    400.0,
  );
  final w = room < byHeight ? room : byHeight;
  return Size(w, w * 9 / 16);
}

/// Top-left of the card in [corner].
@visibleForTesting
Offset floatingCardOrigin(FloatingCorner corner, Size area, Size card) {
  final left =
      corner == FloatingCorner.topLeft || corner == FloatingCorner.bottomLeft;
  final top =
      corner == FloatingCorner.topLeft || corner == FloatingCorner.topRight;
  return Offset(
    left ? _kFloatingMargin : area.width - card.width - _kFloatingMargin,
    top ? _kFloatingMargin : area.height - card.height - _kFloatingMargin,
  );
}

/// The corner nearest to a card whose top-left is at [origin].
@visibleForTesting
FloatingCorner nearestFloatingCorner(Offset origin, Size area, Size card) {
  final center = origin + Offset(card.width / 2, card.height / 2);
  final left = center.dx < area.width / 2;
  final top = center.dy < area.height / 2;
  if (top) return left ? FloatingCorner.topLeft : FloatingCorner.topRight;
  return left ? FloatingCorner.bottomLeft : FloatingCorner.bottomRight;
}

class _FloatingCard extends StatefulWidget {
  const _FloatingCard({
    super.key,
    required this.playback,
    required this.area,
    required this.corner,
  });

  final FloatingPlayback playback;
  final Size area;
  final FloatingCorner corner;

  @override
  State<_FloatingCard> createState() => _FloatingCardState();
}

/// How long the card's controls stay up after the mouse stops moving over
/// it, the same idle time the main player uses.
@visibleForTesting
const Duration floatingControlsHideDelay = Duration(seconds: 2);

class _FloatingCardState extends State<_FloatingCard> {
  /// True while the controls (title, expand, close, play/pause) are shown
  /// because the mouse is moving over the card or the card was clicked.
  bool _hover = false;

  /// Hides the controls once the mouse has been still for
  /// [floatingControlsHideDelay].
  Timer? _hideTimer;

  /// Shows the controls and restarts the hide countdown. Called on every
  /// mouse move over the card, on enter and on any click, so the controls
  /// stay up while the mouse moves and go away about 2 s after it stops.
  void _showControls() {
    _hideTimer?.cancel();
    _hideTimer = Timer(floatingControlsHideDelay, _onHideTimer);
    if (!_hover && mounted) setState(() => _hover = true);
  }

  // The mouse sat still long enough: hide the controls, unless the card is
  // being dragged right now (then wait another round).
  void _onHideTimer() {
    if (!mounted) return;
    if (_drag != null) {
      _hideTimer = Timer(floatingControlsHideDelay, _onHideTimer);
      return;
    }
    setState(() => _hover = false);
  }

  /// The mouse left the card: hide the controls straight away. A drag that
  /// runs past the card edge keeps them up until the drag is over.
  void _hideControls() {
    _hideTimer?.cancel();
    _hideTimer = null;
    if (_drag != null) {
      _hideTimer = Timer(floatingControlsHideDelay, _onHideTimer);
      return;
    }
    if (_hover && mounted) setState(() => _hover = false);
  }

  @override
  void dispose() {
    // No timer may fire into a card that is gone.
    _hideTimer?.cancel();
    super.dispose();
  }

  /// Top-left while the card is being dragged; null otherwise.
  Offset? _drag;

  PlayerCubit get _cubit => widget.playback.cubit;

  // Whole seconds only: the progress line does not need a rebuild per frame.
  late final Stream<Duration> _seconds = _cubit.player.stream.position
      .map((p) => Duration(seconds: p.inSeconds))
      .distinct();

  void _onPanEnd(Size card) {
    final at = _drag;
    if (at == null) return;
    setState(() => _drag = null);
    // Drag over: the controls go away 2 s from now unless the mouse moves.
    if (_hover) _showControls();
    DesktopFloatingPlayer.instance.moveTo(
      nearestFloatingCorner(at, widget.area, card),
    );
  }

  @override
  Widget build(BuildContext context) {
    final area = widget.area;
    final card = floatingCardSize(area);
    final origin = _drag ?? floatingCardOrigin(widget.corner, area, card);
    return AnimatedPositioned(
      key: const ValueKey('floating-player-card'),
      duration: _drag == null
          ? const Duration(milliseconds: 220)
          : Duration.zero,
      curve: Curves.easeOutCubic,
      left: origin.dx,
      top: origin.dy,
      width: card.width,
      height: card.height,
      // The MouseRegion wraps the WHOLE card and is opaque, so it is hit
      // itself even where the native video texture underneath is not
      // hit-testable. onHover restarts the 2 s hide timer on every move;
      // onExit hides the controls at once.
      child: MouseRegion(
        key: const ValueKey('floating-player-hover'),
        opaque: true,
        hitTestBehavior: HitTestBehavior.opaque,
        cursor: SystemMouseCursors.grab,
        onEnter: (_) => _showControls(),
        onHover: (_) => _showControls(),
        onExit: (_) => _hideControls(),
        // A click anywhere on the card (also a touch or pen press, which
        // sends no hover) shows the controls too. A Listener takes no part
        // in the gesture arena, so the drag and the buttons work as before.
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (_) => _showControls(),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // No double-click to expand: a double-tap handler would hold
            // every button click on the card back by 300 ms.
            onPanStart: (_) => setState(
              () => _drag = floatingCardOrigin(widget.corner, area, card),
            ),
            onPanUpdate: (d) {
              final at = (_drag ?? origin) + d.delta;
              setState(
                () => _drag = Offset(
                  at.dx.clamp(0.0, (area.width - card.width).clamp(0.0, 1e9)),
                  at.dy.clamp(0.0, (area.height - card.height).clamp(0.0, 1e9)),
                ),
              );
            },
            onPanEnd: (_) => _onPanEnd(card),
            onPanCancel: () => _onPanEnd(card),
            child: _cardBody(context),
          ),
        ),
      ),
    );
  }

  Widget _cardBody(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [
          BoxShadow(
            color: Color(0x99000000),
            blurRadius: 24,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        // No Overlay sits above this layer, so plain buttons without
        // tooltips; Material is needed for their ink.
        child: Material(
          type: MaterialType.transparency,
          child: StreamBuilder<bool>(
            stream: _cubit.player.stream.playing,
            initialData: _cubit.player.state.playing,
            builder: (context, snap) {
              final playing = snap.data ?? false;
              return Stack(
                fit: StackFit.expand,
                children: [
                  _video(),
                  _status(),
                  // Controls on hover, and always while paused so the
                  // play button is there to press.
                  AnimatedOpacity(
                    opacity: _hover || !playing ? 1 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: IgnorePointer(
                      ignoring: !(_hover || !playing),
                      child: _controls(context, playing),
                    ),
                  ),
                  Positioned(left: 0, right: 0, bottom: 0, child: _progress()),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _video() {
    final test = debugFloatingVideoBuilder;
    if (test != null) return test(_cubit);
    return Stack(
      fit: StackFit.expand,
      children: [
        // Rebuilt when the video size arrives: a video above 1440p (4K) uses
        // the cheap bilinear filter, as the watch page does, because bicubic
        // on its big texture costs a weak iGPU too much every frame.
        StreamBuilder<int?>(
          stream: _cubit.player.stream.height,
          initialData: _cubit.player.state.height,
          builder: (context, _) => Video(
            controller: _cubit.videoController,
            controls: NoVideoControls,
            filterQuality:
                isAbove1440p(
                  _cubit.player.state.width ?? 0,
                  _cubit.player.state.height ?? 0,
                )
                ? FilterQuality.low
                : FilterQuality.high,
            subtitleViewConfiguration: const SubtitleViewConfiguration(
              visible: false,
            ),
          ),
        ),
        // Same plain-text subtitles the player page draws when styled
        // (libass) subtitles are off; they scale down with the card.
        if (!_cubit.styledSubtitlesOn)
          StreamBuilder<List<String>>(
            stream: _cubit.player.stream.subtitle,
            initialData: _cubit.player.state.subtitle,
            builder: (context, snapshot) {
              final prefs = sl<PlaybackPrefs>();
              return PositionedSubtitle(
                text: (snapshot.data ?? const <String>[])
                    .where((line) => line.trim().isNotEmpty)
                    .join('\n'),
                position: prefs.subtitlePosition,
                style: buildSubtitleTextStyle(
                  prefs,
                  fontSize: 32 * prefs.subtitleScale,
                ),
              );
            },
          ),
      ],
    );
  }

  /// Spinner while a source is still being found, a short error line when
  /// playback failed (expand shows the full error page).
  Widget _status() {
    return BlocBuilder<PlayerCubit, PlayerState>(
      bloc: _cubit,
      buildWhen: (a, b) =>
          a.loadingSources != b.loadingSources || a.error != b.error,
      builder: (context, state) {
        if (state.error != null) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                state.error!.split('\n').first,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
          );
        }
        if (state.loadingSources) {
          return const Center(
            child: SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
          );
        }
        return const SizedBox.shrink();
      },
    );
  }

  Widget _controls(BuildContext context, bool playing) {
    final l10n = context.l10n;
    final title = widget.playback.title;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xAA000000), Color(0x22000000), Color(0xAA000000)],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            left: 12,
            top: 6,
            right: 88,
            child: title == null
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
          ),
          Positioned(
            top: 2,
            right: 2,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _button(
                  key: const ValueKey('floating-player-expand'),
                  icon: Icons.open_in_full_rounded,
                  label: l10n.floatingPlayerExpand,
                  onTap: DesktopFloatingPlayer.instance.expand,
                ),
                _button(
                  key: const ValueKey('floating-player-close'),
                  icon: Icons.close_rounded,
                  label: l10n.floatingPlayerClose,
                  onTap: () =>
                      unawaited(DesktopFloatingPlayer.instance.close()),
                ),
              ],
            ),
          ),
          Center(
            child: _button(
              key: const ValueKey('floating-player-play'),
              icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              label: playing ? l10n.pause : l10n.play,
              size: 40,
              onTap: DesktopFloatingPlayer.instance.togglePlay,
            ),
          ),
        ],
      ),
    );
  }

  Widget _button({
    required Key key,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    double size = 22,
  }) {
    return Semantics(
      button: true,
      label: label,
      child: IconButton(
        key: key,
        onPressed: onTap,
        icon: Icon(icon, size: size, color: Colors.white),
        mouseCursor: SystemMouseCursors.click,
      ),
    );
  }

  /// A thin line along the bottom: how far into the episode playback is.
  Widget _progress() {
    return StreamBuilder<Duration>(
      stream: _seconds,
      initialData: _cubit.player.state.position,
      builder: (context, snap) {
        final total = _cubit.player.state.duration.inMilliseconds;
        final done = (snap.data ?? Duration.zero).inMilliseconds;
        final value = total <= 0 ? 0.0 : (done / total).clamp(0.0, 1.0);
        return LinearProgressIndicator(
          key: const ValueKey('floating-player-progress'),
          value: value,
          minHeight: 3,
          backgroundColor: Colors.white24,
          color: Theme.of(context).colorScheme.primary,
        );
      },
    );
  }
}
