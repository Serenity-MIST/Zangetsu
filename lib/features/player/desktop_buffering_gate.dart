// Windows: keeps the player's "buffering" circle honest. mpv can leave its
// buffering flag set after playback has really resumed (a missed "done"
// event, a stream that stalls and recovers in the same instant), and the
// circle then sat in the play / pause spot over a moving picture. Here the
// circle only shows while the player says it is buffering AND the position
// is not moving forward on its own. A flag that stays set for a while
// although the player says it is playing and a picture is already on screen
// is also treated as stale (mpv sometimes reports 00:00 / 00:00 and never
// moves the position, so the moving check alone cannot clear it). Phone and
// TV never use this file.
import 'dart:async';

import 'package:flutter/widgets.dart';

/// How long after the last normal forward step the picture still counts as
/// moving. Position ticks arrive several times a second while frames play,
/// so this only has to cover the gap between two ticks.
const Duration kDesktopPlaybackMovingWindow = Duration(milliseconds: 1200);

/// How long the buffering flag may stay set while the player says it is
/// playing with a picture up before the circle is treated as stuck. A real
/// stall still shows the circle for this long.
const Duration kDesktopStaleBufferingAfter = Duration(milliseconds: 2500);

/// True when a position change looks like normal playback (a small forward
/// step) rather than a seek (a jump, or going backwards).
@visibleForTesting
bool isPlaybackStep(Duration previous, Duration next) {
  final step = next - previous;
  return step > Duration.zero && step < const Duration(milliseconds: 1500);
}

/// The circle shows only while the player reports buffering, frames are not
/// visibly playing and the flag has not been judged stale.
@visibleForTesting
bool showBufferingCircle({
  required bool buffering,
  required bool moving,
  bool stale = false,
}) => buffering && !moving && !stale;

/// Rebuilds [builder] with whether the buffering circle should show right
/// now (see the file comment). Used by the Windows full player and the
/// Windows watch page.
class DesktopBufferingGate extends StatefulWidget {
  const DesktopBufferingGate({
    super.key,
    required this.bufferingStream,
    required this.initialBuffering,
    required this.positionStream,
    required this.initialPosition,
    required this.builder,
    this.playingStream,
    this.initialPlaying = false,
    this.frameStream,
    this.initialFrameUp = false,
  });

  final Stream<bool>? bufferingStream;
  final bool initialBuffering;
  final Stream<Duration> positionStream;
  final Duration initialPosition;
  final Widget Function(BuildContext context, bool buffering) builder;

  /// Whether the player says it is playing. Together with the picture state
  /// it lets a long-held buffering flag count as stale.
  final Stream<bool>? playingStream;
  final bool initialPlaying;

  /// The video width; any value above 0 means a picture is on screen.
  final Stream<int?>? frameStream;
  final bool initialFrameUp;

  @override
  State<DesktopBufferingGate> createState() => _DesktopBufferingGateState();
}

class _DesktopBufferingGateState extends State<DesktopBufferingGate> {
  late bool _buffering = widget.initialBuffering;
  late Duration _lastPosition = widget.initialPosition;
  late bool _playing = widget.initialPlaying;
  late bool _frameUp = widget.initialFrameUp;

  /// Frames moved forward within [kDesktopPlaybackMovingWindow].
  bool _moving = false;
  Timer? _stillTimer;

  /// The buffering flag stayed set for [kDesktopStaleBufferingAfter] while
  /// playing with a picture up, so the circle is hidden.
  bool _stale = false;
  Timer? _staleTimer;

  StreamSubscription<bool>? _bufferingSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<int?>? _frameSub;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(DesktopBufferingGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The parent may learn about the first picture itself and pass it in.
    if (widget.initialFrameUp && !_frameUp) {
      _frameUp = true;
      _armStale(rebuild: false);
    }
    if (oldWidget.bufferingStream != widget.bufferingStream ||
        oldWidget.positionStream != widget.positionStream ||
        oldWidget.playingStream != widget.playingStream ||
        oldWidget.frameStream != widget.frameStream) {
      _cancelSubs();
      _listen(rebuild: false);
    }
  }

  void _listen({bool rebuild = true}) {
    _bufferingSub = widget.bufferingStream?.listen((b) {
      if (!mounted || b == _buffering) return;
      setState(() => _buffering = b);
      _armStale();
    });
    _positionSub = widget.positionStream.listen(_onPosition);
    _playingSub = widget.playingStream?.listen((p) {
      if (!mounted || p == _playing) return;
      _playing = p;
      _armStale();
    });
    _frameSub = widget.frameStream?.listen((w) {
      if (!mounted || _frameUp || (w ?? 0) <= 0) return;
      _frameUp = true;
      _armStale();
    });
    _armStale(rebuild: rebuild);
  }

  void _cancelSubs() {
    _bufferingSub?.cancel();
    _positionSub?.cancel();
    _playingSub?.cancel();
    _frameSub?.cancel();
  }

  /// Starts the countdown after which a held buffering flag counts as stale.
  /// Any change in buffering, playing or picture state, or a seek, starts it
  /// over and shows the circle again until it runs out.
  void _armStale({bool rebuild = true}) {
    _staleTimer?.cancel();
    _staleTimer = null;
    if (_stale) {
      // didUpdateWidget is followed by a build anyway, so no setState there.
      if (rebuild) {
        setState(() => _stale = false);
      } else {
        _stale = false;
      }
    }
    if (!_buffering || !_playing || !_frameUp) return;
    _staleTimer = Timer(kDesktopStaleBufferingAfter, () {
      if (mounted && _buffering && _playing && _frameUp) {
        setState(() => _stale = true);
      }
    });
  }

  void _onPosition(Duration next) {
    final step = isPlaybackStep(_lastPosition, next);
    final moved = next != _lastPosition;
    _lastPosition = next;
    if (!mounted) return;
    // A seek (a jump) shows the circle again for a moment, so a real stall
    // right after the seek is still visible.
    if (moved && !step) _armStale();
    if (!step) return;
    // Playing: hold "moving" a moment past this tick, then drop it so a
    // real stall brings the circle back.
    _stillTimer?.cancel();
    _stillTimer = Timer(kDesktopPlaybackMovingWindow, () {
      if (mounted && _moving) setState(() => _moving = false);
    });
    if (!_moving) setState(() => _moving = true);
  }

  @override
  void dispose() {
    _stillTimer?.cancel();
    _staleTimer?.cancel();
    _cancelSubs();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(
    context,
    showBufferingCircle(buffering: _buffering, moving: _moving, stale: _stale),
  );
}
