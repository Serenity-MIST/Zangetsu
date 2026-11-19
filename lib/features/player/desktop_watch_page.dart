// Windows theater layout for the watch page: the video large on the left,
// a tabbed side panel (episodes / comments) on the right. Phone and TV never
// reach this file: [PlayerWatchPage.createState] picks it on Windows only.
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart' show GestureBinding, PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/desktop/desktop_context_menu.dart';
import '../../core/desktop/desktop_text_prompt.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../l10n/l10n.dart';
import '../detail/episode_filter.dart';
import 'desktop_player_hud.dart';
import 'desktop_video_click.dart';
import 'player_watch_page.dart';
import 'watch_page_info.dart';

/// A Lucide glyph tinted for the dark desktop surfaces.
Widget _lucide(
  String name, {
  double size = 18,
  Color color = AppColors.textPrimary,
}) => SvgPicture.asset(
  'assets/icons/lucide/$name.svg',
  width: size,
  height: size,
  colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
);

/// Side panel tabs. Comments is a placeholder until the feature ships.
enum _PanelTab { episodes, comments }

/// Per-row context menu (right click or the row's ⋯ button).
enum _RowAction { watched, mirror }

/// Episode list options (same two the phone page keeps in its ⋮ menu).
enum _ListAction { reverse, autoplay }

/// Desktop state for [PlayerWatchPage]. Owns no playback decisions: like the
/// phone page it only lays out the parent's video surface and forwards every
/// action through the same callbacks.
class DesktopWatchPageState extends State<PlayerWatchPage> {
  /// Fixed row height so the list can jump to the playing episode without
  /// building every row first (long shows have 1000+ entries).
  static const double rowExtent = 92;

  late bool _playing = widget.initialPlaying;
  late bool _frameUp =
      widget.firstFrameStream == null || widget.initialFirstFrame > 0;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<int?>? _frameSub;
  StreamSubscription<Uint8List?>? _ambientSub;

  /// Soft glow behind the video, sampled from live frames (theater ambience).
  Color? _glow;

  /// Mouse moved over the video recently: show the transport bar.
  bool _pointerActive = false;
  Timer? _idleTimer;

  /// Seek slider position while the user drags it; null when not dragging.
  double? _dragMs;

  /// A mouse button is held on the transport (dragging the seek bar or the
  /// volume slider): keep the bar up even if the mouse stops moving.
  bool _transportHeld = false;

  bool _descExpanded = false;
  _PanelTab _tab = _PanelTab.episodes;

  /// Display-only list state; tapped rows always carry the real index.
  int _range = 0;
  bool _reversed = false;
  final ScrollController _list = ScrollController();

  /// Episode index last scrolled into view, so rebuilds don't fight the user.
  int? _revealed;

  @override
  void initState() {
    super.initState();
    _playingSub = widget.playingStream.listen((p) {
      if (mounted && p != _playing) setState(() => _playing = p);
    });
    _frameSub = widget.firstFrameStream?.listen((w) {
      if (!mounted || _frameUp || (w ?? 0) <= 0) return;
      setState(() => _frameUp = true);
    });
    _ambientSub = widget.ambientFrameStream?.listen((bytes) {
      if (!mounted || bytes == null || bytes.isEmpty) return;
      unawaited(_applyAmbient(bytes));
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealCurrent());
  }

  @override
  void didUpdateWidget(PlayerWatchPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new episode or season list: bring the playing row back into view.
    if (_currentIndex(oldWidget.episodes) != _currentIndex(widget.episodes) ||
        oldWidget.episodes.length != widget.episodes.length) {
      _revealed = null;
      // Another season picked: start its list at the top on page one; the
      // reveal below still jumps to the playing row when it is in there.
      if (oldWidget.selectedSeason != widget.selectedSeason) {
        _range = 0;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _list.hasClients) _list.jumpTo(0);
        });
      }
      WidgetsBinding.instance.addPostFrameCallback((_) => _revealCurrent());
    }
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    _playingSub?.cancel();
    _frameSub?.cancel();
    _ambientSub?.cancel();
    _list.dispose();
    super.dispose();
  }

  static int? _currentIndex(List<WatchPageEpisode> eps) {
    for (final e in eps) {
      if (e.current) return e.index;
    }
    return null;
  }

  /// Decodes a grab tiny and keeps its deep tone for the glow. A near-black
  /// frame never wipes an existing glow (paused on a black scene).
  Future<void> _applyAmbient(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 32);
      final frame = await codec.getNextFrame();
      final img = frame.image;
      final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      final w = img.width, h = img.height;
      img.dispose();
      if (data == null || !mounted) return;
      final c = ambientGlowColor(data, w, h).top;
      final lum =
          ((c.r * 255).round() + (c.g * 255).round() + (c.b * 255).round()) ~/
          3;
      if (lum < 28 && _glow != null) return;
      setState(() => _glow = c);
    } catch (_) {
      // Undecodable grab: keep the previous glow.
    }
  }

  // ── Episode list helpers (same paging rules as the phone page) ───────────

  List<WatchPageEpisode> get _ordered =>
      _reversed ? widget.episodes.reversed.toList() : widget.episodes;

  int get _rangeCount => episodeRangeCount(_ordered.length);

  int get _pageStart {
    final d = _ordered;
    if (d.length <= kEpisodeRangeChunk) return 0;
    return episodeRangeSlice(_range.clamp(0, _rangeCount - 1), d.length).start;
  }

  List<WatchPageEpisode> get _paged {
    final d = _ordered;
    if (d.length <= kEpisodeRangeChunk) return d;
    final s = episodeRangeSlice(_range.clamp(0, _rangeCount - 1), d.length);
    return d.sublist(s.start, s.end);
  }

  String _rangeLabel(int i) {
    final s = episodeRangeSlice(i, _ordered.length);
    return '${s.start + 1}–${s.end}';
  }

  /// Scrolls the playing episode into view (switching range page if needed).
  void _revealCurrent({bool force = false}) {
    if (!mounted) return;
    final at = _ordered.indexWhere((e) => e.current);
    if (at < 0) return;
    final idx = _ordered[at].index;
    if (!force && _revealed == idx) return;
    _revealed = idx;
    _revealAt(at);
  }

  /// Shows display position [at]: picks its range page, then scrolls so the
  /// row sits about a third down the panel.
  void _revealAt(int at) {
    if (_ordered.length > kEpisodeRangeChunk) {
      final want = at ~/ kEpisodeRangeChunk;
      if (want != _range) setState(() => _range = want);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_list.hasClients) return;
      final pos = _list.position;
      final target =
          ((at - _pageStart) * rowExtent - pos.viewportDimension * 0.3).clamp(
            0.0,
            pos.maxScrollExtent,
          );
      unawaited(
        _list.animateTo(
          target,
          duration: MediaQuery.disableAnimationsOf(context)
              ? const Duration(milliseconds: 1)
              : const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
        ),
      );
    });
  }

  // ── Video chrome ─────────────────────────────────────────────────────────

  /// Any mouse movement over the video shows the bar; it fades after 2.5s
  /// of stillness while playing (paused keeps it up).
  void _onVideoHover(PointerEvent _) {
    _idleTimer?.cancel();
    _idleTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted) setState(() => _pointerActive = false);
    });
    if (!_pointerActive) setState(() => _pointerActive = true);
  }

  void _onVideoExit(PointerEvent _) {
    _idleTimer?.cancel();
    if (_pointerActive) setState(() => _pointerActive = false);
  }

  @override
  Widget build(BuildContext context) {
    final page = Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            _header(context),
            const Divider(height: 1, color: AppColors.hairline),
            Expanded(
              child: LayoutBuilder(
                builder: (context, c) {
                  // Narrow windows stack the panel under the video instead
                  // of squeezing both columns.
                  if (c.maxWidth < 900) {
                    return Column(
                      children: [
                        SizedBox(height: c.maxHeight * 0.58, child: _main()),
                        const Divider(height: 1, color: AppColors.hairline),
                        Expanded(child: _panel(context)),
                      ],
                    );
                  }
                  final panelW = (c.maxWidth * 0.27).clamp(360.0, 420.0);
                  return Center(
                    child: ConstrainedBox(
                      // Keeps a 4K / ultrawide window from stretching rows.
                      constraints: const BoxConstraints(maxWidth: 1800),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: _main()),
                          SizedBox(width: panelW, child: _panel(context)),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    if (widget.onWheelVolume == null) return page;
    // Wheel-to-volume belongs to the video only. Claiming leftover wheel
    // events here (header, title, empty panel space) keeps the player's
    // page-wide wheel handler from changing the volume there; the video
    // and the scrolling lists claim theirs first, being deeper.
    return Listener(
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) {
          GestureBinding.instance.pointerSignalResolver.register(event, (_) {});
        }
      },
      child: page,
    );
  }

  /// Top bar: Back (leaves the player), the one-click show page button and
  /// the switch back to the full player.
  Widget _header(BuildContext context) {
    final l10n = context.l10n;
    final show = (widget.showTitle ?? '').trim();
    return SizedBox(
      height: 56,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            _IconBtn(
              key: const ValueKey('watch-back'),
              icon: 'arrow-left',
              tooltip: '${l10n.back} · Esc',
              onTap: widget.onBack,
            ),
            const SizedBox(width: 6),
            if (widget.onShowPage != null)
              Flexible(
                child: Tooltip(
                  message: context.l10n.openTheShowPage,
                  child: TextButton.icon(
                    key: const ValueKey('watch-show-page'),
                    onPressed: widget.onShowPage,
                    icon: _lucide('clapperboard', size: 17),
                    label: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: Text(
                        show.isEmpty ? 'Show page' : show,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.textPrimary,
                      textStyle: AppText.body.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
              )
            else
              const Spacer(),
            if (widget.onShowPage != null) const Spacer(),
            _IconBtn(
              key: const ValueKey('watch-full-player'),
              icon: 'maximize',
              tooltip: context.l10n.fullPlayer,
              onTap: widget.onFullscreen,
            ),
          ],
        ),
      ),
    );
  }

  /// Left column: the video, then title, actions and description.
  Widget _main() {
    return LayoutBuilder(
      builder: (context, c) {
        const pad = 24.0;
        final maxW = (c.maxWidth - pad * 2).clamp(200.0, double.infinity);
        // Leave room for the title row under the video on short windows.
        final maxH = (c.maxHeight - 150).clamp(180.0, double.infinity);
        var videoW = maxW;
        var videoH = videoW * 9 / 16;
        if (videoH > maxH) {
          videoH = maxH;
          videoW = videoH * 16 / 9;
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(pad, 20, pad, 32),
          children: [
            Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 900),
                width: videoW,
                height: videoH,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    if (_glow != null)
                      BoxShadow(
                        color: _glow!.withValues(alpha: 0.28),
                        blurRadius: 80,
                        spreadRadius: 4,
                      ),
                  ],
                ),
                child: _video(),
              ),
            ),
            const SizedBox(height: 18),
            Center(
              child: SizedBox(width: videoW, child: _info(context)),
            ),
          ],
        );
      },
    );
  }

  Widget _video() {
    final l10n = context.l10n;
    final video = ClipRRect(
      key: const ValueKey('watch-video'),
      borderRadius: BorderRadius.circular(14),
      child: ColoredBox(
        color: Colors.black,
        child: StreamBuilder<bool>(
          stream: widget.bufferingStream,
          initialData: widget.initialBuffering,
          builder: (context, snap) {
            // Controls are locked only while a source is found or the first
            // frame loads. A later mid-episode stall keeps the spinner but
            // still lets the viewer pause or seek past the stuck part.
            final blocked = widget.loading || !_frameUp;
            final busy = blocked || snap.data == true;
            final chrome =
                busy || !_playing || _pointerActive || _transportHeld;
            return MouseRegion(
              onHover: _onVideoHover,
              onExit: _onVideoExit,
              cursor: chrome ? MouseCursor.defer : SystemMouseCursors.none,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  widget.video,
                  // Click toggles play at once; a quick second click undoes
                  // it and opens the full player (no 300ms double-click
                  // wait). Right-click opens the player menu at the pointer.
                  Positioned.fill(
                    child: DesktopVideoPointer(
                      key: const ValueKey('watch-video-click'),
                      onToggle: widget.onTogglePlay,
                      onDoubleClick: widget.onFullscreen,
                      canToggle: () => !blocked,
                      onContextMenu: widget.onContextMenu,
                    ),
                  ),
                  // Volume / seek feedback for keyboard and wheel input.
                  if (widget.hud != null)
                    Positioned.fill(
                      child: DesktopPlayerHud(
                        controller: widget.hud!,
                        volumeStream: widget.volumeStream,
                        initialVolume: widget.initialVolume,
                      ),
                    ),
                  if (busy)
                    IgnorePointer(
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Semantics(
                              label: l10n.loading,
                              child: const SizedBox.square(
                                dimension: 34,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2.5,
                                ),
                              ),
                            ),
                            if (widget.loadingStatus != null) ...[
                              const SizedBox(height: 12),
                              Text(
                                widget.loadingStatus!,
                                style: AppText.caption.copyWith(
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  // Skip intro/recap/ending, as in the full player. Always
                  // visible inside an interval; sits above the transport.
                  if (widget.skipButtonFor != null)
                    Positioned(
                      right: 16,
                      bottom: 72,
                      child: StreamBuilder<Duration>(
                        stream: widget.positionStream,
                        initialData: widget.initialPosition,
                        builder: (context, pos) =>
                            widget.skipButtonFor!(
                              pos.data ?? Duration.zero,
                            ) ??
                            const SizedBox.shrink(),
                      ),
                    ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: AnimatedOpacity(
                      opacity: chrome ? 1 : 0,
                      duration: const Duration(milliseconds: 180),
                      child: IgnorePointer(
                        ignoring: !chrome,
                        // A held button (seek or volume drag) keeps the bar
                        // up; releasing restarts the idle fade.
                        child: Listener(
                          onPointerDown: (_) {
                            _idleTimer?.cancel();
                            setState(() => _transportHeld = true);
                          },
                          onPointerUp: (e) {
                            setState(() => _transportHeld = false);
                            _onVideoHover(e);
                          },
                          onPointerCancel: (_) =>
                              setState(() => _transportHeld = false),
                          child: _transport(blocked),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
    // Wheel over the video (and only the video) changes the volume; over
    // the rest of the page it keeps scrolling.
    return DesktopVideoWheel(
      enabled: widget.onWheelVolume != null,
      onStep: (step) => widget.onWheelVolume?.call(step),
      child: video,
    );
  }

  /// Bottom bar over the video: seek line, then transport and time.
  /// [busy] is true only while the first frame is still loading (see
  /// [_video]); buffering later leaves every control live.
  Widget _transport(bool busy) {
    final l10n = context.l10n;
    final nextTip = widget.nextTitle == null
        ? l10n.nextEpisode
        : '${l10n.nextEpisode}: ${widget.nextLabel ?? ''} ${widget.nextTitle}'
              .trim();
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xB3000000), Color(0x00000000)],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 28, 10, 6),
        child: StreamBuilder<Duration?>(
          stream: widget.durationStream,
          initialData: widget.initialDuration,
          builder: (context, durSnap) {
            final total = durSnap.data ?? Duration.zero;
            return StreamBuilder<Duration>(
              stream: widget.positionStream,
              initialData: widget.initialPosition,
              builder: (context, posSnap) {
                final pos = posSnap.data ?? Duration.zero;
                final maxMs = total.inMilliseconds > 0
                    ? total.inMilliseconds.toDouble()
                    : 1.0;
                // While dragging, the thumb follows the mouse and the seek
                // is sent once on release (no seek storm into the player).
                final value = (_dragMs ?? pos.inMilliseconds.toDouble()).clamp(
                  0.0,
                  maxMs,
                );
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // The full player's bar (buffered range, skip marks,
                    // hover time) when the player provides it; it stays
                    // usable during buffering and is only held off while
                    // the first frame loads.
                    if (widget.seekBar != null)
                      IgnorePointer(
                        ignoring: busy,
                        child: Opacity(
                          opacity: busy ? 0.5 : 1,
                          child: widget.seekBar!,
                        ),
                      )
                    else
                      SizedBox(
                        height: 18,
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            activeTrackColor: AppColors.accent,
                            inactiveTrackColor: Colors.white.withValues(
                              alpha: 0.3,
                            ),
                            thumbColor: AppColors.accent,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 6,
                            ),
                            overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 12,
                            ),
                            trackHeight: 3,
                            trackShape: const RectangularSliderTrackShape(),
                          ),
                          child: Slider(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            value: value,
                            max: maxMs,
                            onChanged: busy
                                ? null
                                : (v) => setState(() => _dragMs = v),
                            onChangeEnd: busy
                                ? null
                                : (v) {
                                    setState(() => _dragMs = null);
                                    widget.onSeek(
                                      Duration(milliseconds: v.round()),
                                    );
                                  },
                          ),
                        ),
                      ),
                    Row(
                      children: [
                        _IconBtn(
                          icon: 'skip-back',
                          tooltip: l10n.previousEpisode,
                          color: Colors.white,
                          onTap: widget.hasPrevious ? widget.onPrevious : null,
                        ),
                        _IconBtn(
                          key: const ValueKey('watch-play'),
                          icon: _playing ? 'pause' : 'play',
                          tooltip: busy
                              ? l10n.loading
                              : '${_playing ? l10n.pause : l10n.play} · Space',
                          color: Colors.white,
                          onTap: busy ? null : widget.onTogglePlay,
                        ),
                        _IconBtn(
                          icon: 'skip-forward',
                          tooltip: nextTip,
                          color: Colors.white,
                          onTap: widget.nextTitle != null
                              ? widget.onNext
                              : null,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${formatWatchTime(pos)} / ${formatWatchTime(total)}',
                          style: AppText.caption.copyWith(
                            color: Colors.white,
                            fontFeatures: const [
                              ui.FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                        const Spacer(),
                        // Compact volume (click mutes, hover opens a slider)
                        // and the speed picker, as in the full player.
                        if (widget.onVolumeChanged != null)
                          _VolumeButton(
                            volumeStream: widget.volumeStream,
                            initialVolume: widget.initialVolume,
                            onChanged: widget.onVolumeChanged!,
                            onToggleMute: widget.onToggleMute,
                          ),
                        if (widget.onSpeed != null)
                          StreamBuilder<double>(
                            stream: widget.rateStream,
                            initialData: widget.initialRate,
                            builder: (context, rate) => _SpeedBtn(
                              rate: rate.data ?? 1,
                              tooltip: l10n.playbackSpeed,
                              onTap: widget.onSpeed!,
                            ),
                          ),
                        _IconBtn(
                          icon: 'captions',
                          tooltip: l10n.subtitles,
                          color: Colors.white,
                          onTap: widget.onSubtitles,
                        ),
                        _IconBtn(
                          icon: 'maximize',
                          tooltip: context.l10n.fullPlayerDoubleClick,
                          color: Colors.white,
                          onTap: widget.onFullscreen,
                        ),
                      ],
                    ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }

  /// Title, the playback actions and the expandable synopsis.
  Widget _info(BuildContext context) {
    final l10n = context.l10n;
    final server = widget.serverName?.trim() ?? '';
    final serverLabel = server.isNotEmpty
        ? 'Server · ${server.split(RegExp(r"[\r\n]")).first}'
        : l10n.watchServer;
    final description = widget.header.description;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.header.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: AppText.headline.copyWith(color: Colors.white, fontSize: 22),
        ),
        if (widget.header.subtitle.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            widget.header.subtitle,
            style: AppText.body.copyWith(color: AppColors.textSecondary),
          ),
        ],
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _ActionBtn(
              icon: 'server',
              label: serverLabel,
              onTap: widget.onServer,
            ),
            _ActionBtn(
              icon: 'headphones',
              label: l10n.audio,
              onTap: widget.onAudio,
            ),
            _ActionBtn(
              icon: 'captions',
              label: l10n.subtitles,
              onTap: widget.onSubtitles,
            ),
            _ActionBtn(
              icon: 'ellipsis',
              label: l10n.more,
              onTap: widget.onMore,
            ),
          ],
        ),
        if (description != null) ...[
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.hairline),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  description,
                  maxLines: _descExpanded ? null : 3,
                  overflow: _descExpanded ? null : TextOverflow.ellipsis,
                  style: AppText.body.copyWith(
                    color: AppColors.textSecondary,
                    height: 1.45,
                  ),
                ),
                TextButton(
                  onPressed: () =>
                      setState(() => _descExpanded = !_descExpanded),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.accent,
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 32),
                  ),
                  child: Text(
                    _descExpanded ? l10n.watchSeeLess : l10n.watchSeeMore,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  // ── Side panel ───────────────────────────────────────────────────────────

  Widget _panel(BuildContext context) {
    final l10n = context.l10n;
    final episodesLabel = widget.isMovie
        ? l10n.movie
        : '${l10n.watchEpisodes} (${widget.episodes.length})';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Color.lerp(AppColors.bg, AppColors.surface, 0.55),
        border: const Border(left: BorderSide(color: AppColors.hairline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
            child: Row(
              children: [
                _TabBtn(
                  key: const ValueKey('watch-tab-episodes'),
                  icon: 'list-video',
                  label: episodesLabel,
                  selected: _tab == _PanelTab.episodes,
                  onTap: () {
                    if (_tab == _PanelTab.episodes) return;
                    setState(() => _tab = _PanelTab.episodes);
                    // The list is rebuilt: land on the playing row again.
                    _revealed = null;
                    WidgetsBinding.instance.addPostFrameCallback(
                      (_) => _revealCurrent(),
                    );
                  },
                ),
                const SizedBox(width: 6),
                _TabBtn(
                  key: const ValueKey('watch-tab-comments'),
                  icon: 'message-square',
                  label: l10n.watchComments,
                  selected: _tab == _PanelTab.comments,
                  onTap: () => setState(() => _tab = _PanelTab.comments),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.hairline),
          Expanded(
            child: _tab == _PanelTab.episodes
                ? _episodesTab(l10n)
                : _commentsTab(l10n),
          ),
        ],
      ),
    );
  }

  Widget _commentsTab(AppLocalizations l10n) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _lucide('message-square', size: 28, color: AppColors.textSecondary),
            const SizedBox(height: 12),
            Text(l10n.watchComments, style: AppText.title),
            const SizedBox(height: 4),
            Text(
              l10n.watchComingSoon,
              textAlign: TextAlign.center,
              style: AppText.body.copyWith(color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _episodesTab(AppLocalizations l10n) {
    final seasons = widget.seasons;
    final multiSeason = seasons != null && seasons.length > 1;
    final showRanges = _ordered.length > kEpisodeRangeChunk;
    final paged = _paged;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 6, 6),
          child: Row(
            children: [
              if (multiSeason) ...[
                _seasonMenu(l10n, seasons),
                const SizedBox(width: 6),
              ],
              if (showRanges) _rangeMenu(),
              const Spacer(),
              if (!widget.isMovie)
                _IconBtn(
                  icon: 'search',
                  tooltip: l10n.findEpisode,
                  onTap: () => _openJumpDialog(l10n),
                ),
              _listMenu(l10n),
            ],
          ),
        ),
        Expanded(
          child: paged.isEmpty
              // Season with nothing in it (or a source that returned none).
              ? Center(
                  child: Text(
                    l10n.noEpisodes,
                    style: AppText.body.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                )
              : Scrollbar(
                  controller: _list,
                  child: ListView.builder(
                    key: const ValueKey('watch-episode-list'),
                    controller: _list,
                    itemExtent: rowExtent,
                    padding: const EdgeInsets.only(bottom: 16),
                    itemCount: paged.length,
                    itemBuilder: (context, i) => _row(paged[i]),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _seasonMenu(AppLocalizations l10n, List<int> seasons) {
    final selected = widget.selectedSeason ?? seasons.first;
    // Graphite dropdown under the pill (was a Material PopupMenuButton).
    return _MenuPill(
      key: const ValueKey('watch-season-menu'),
      label: '${l10n.season} $selected',
      tooltip: l10n.season,
      onOpen: (anchor) => showDesktopContextMenu<int>(
        context,
        anchor: anchor,
        items: [
          for (final s in seasons)
            DesktopMenuItem(
              label: '${l10n.season} $s',
              value: s,
              // Tick marks the season on screen.
              checked: s == selected,
              onTap: () {
                if (s != widget.selectedSeason) widget.onSelectSeason?.call(s);
              },
            ),
        ],
      ),
    );
  }

  Widget _rangeMenu() {
    final current = _range.clamp(0, _rangeCount - 1);
    // Graphite dropdown of episode ranges, ticked on the shown range.
    return _MenuPill(
      key: const ValueKey('watch-range-menu'),
      label: _rangeLabel(current),
      tooltip: context.l10n.episodeRangeText,
      onOpen: (anchor) => showDesktopContextMenu<int>(
        context,
        anchor: anchor,
        items: [
          for (var i = 0; i < _rangeCount; i++)
            DesktopMenuItem(
              label: _rangeLabel(i),
              value: i,
              checked: i == current,
              onTap: () {
                if (!mounted) return;
                setState(() => _range = i);
                if (_list.hasClients) _list.jumpTo(0);
              },
            ),
        ],
      ),
    );
  }

  Widget _listMenu(AppLocalizations l10n) {
    // Icon button that drops the graphite list-options menu below itself;
    // the Builder hands the menu the button's own box as its anchor.
    return Builder(
      builder: (buttonContext) => _IconBtn(
        key: const ValueKey('watch-list-menu'),
        icon: 'arrow-up-down',
        tooltip: l10n.more,
        color: AppColors.textSecondary,
        onTap: () => showDesktopContextMenu<_ListAction>(
          context,
          anchor: buttonContext,
          items: [
            DesktopMenuItem(
              label: l10n.watchReverseOrder,
              value: _ListAction.reverse,
              checked: _reversed,
              onTap: _toggleReverse,
            ),
            DesktopMenuItem(
              label: l10n.watchAutoplay,
              value: _ListAction.autoplay,
              checked: widget.autoplay,
              onTap: () => widget.onAutoplayChanged(!widget.autoplay),
            ),
          ],
        ),
      ),
    );
  }

  /// Flips the list order, goes back to the first range, and re-centres on
  /// the playing episode once the new order has laid out.
  void _toggleReverse() {
    if (!mounted) return;
    setState(() {
      _reversed = !_reversed;
      _range = 0;
    });
    _revealed = null;
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealCurrent());
  }

  /// Jump to an episode number; unknown numbers dismiss quietly.
  Future<void> _openJumpDialog(AppLocalizations l10n) async {
    // Graphite one-field prompt (was a Material AlertDialog). Digits only,
    // so any answer parses; Enter jumps, Esc cancels.
    final typed = await showDesktopTextPrompt(
      context,
      title: l10n.jumpToEpisode,
      hint: l10n.episodeNumber,
      confirmLabel: l10n.go,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
    );
    final go = int.tryParse(typed ?? '');
    if (go == null || !mounted) return;
    var at = _ordered.indexWhere((e) => e.number?.toInt() == go);
    if (at < 0) {
      // No numbered match: treat the number as a position, like the phone.
      if (go - 1 < 0 || go - 1 >= widget.episodes.length) return;
      final real = widget.episodes[go - 1].index;
      at = _ordered.indexWhere((e) => e.index == real);
    }
    if (at >= 0) _revealAt(at);
  }

  /// Menu entries for one row; empty when nothing applies. Each entry acts
  /// through its onTap (run after the menu closes), so one list serves the
  /// right-click menu, the Menu key / Shift+F10 and the row's ⋯ button.
  List<DesktopMenuItem<Object?>> _rowMenuItems(
    WatchPageEpisode ep,
    bool watched,
    bool dead,
  ) => [
    if (widget.onSetWatched != null)
      DesktopMenuItem(
        label: watched ? 'Mark as unwatched' : 'Mark as watched',
        icon: watched
            ? Icons.remove_done_rounded
            : Icons.check_circle_outline_rounded,
        value: _RowAction.watched,
        onTap: () => _runRowAction(_RowAction.watched, ep, watched),
      ),
    if (widget.onPlayMirror != null && !dead)
      DesktopMenuItem(
        label: context.l10n.playMirror,
        icon: Icons.swap_horiz_rounded,
        value: _RowAction.mirror,
        onTap: () => _runRowAction(_RowAction.mirror, ep, watched),
      ),
  ];

  void _runRowAction(_RowAction action, WatchPageEpisode ep, bool watched) {
    if (!mounted) return;
    if (action == _RowAction.watched) {
      widget.onSetWatched?.call(ep.index, !watched);
    } else {
      widget.onPlayMirror?.call(ep.index);
    }
  }

  /// One desktop episode row: 16:9 thumb with progress, number, title, meta.
  Widget _row(WatchPageEpisode ep) {
    final dead = (ep.unavailableReason ?? '').trim().isNotEmpty;
    final watched = widget.isEpisodeWatched?.call(ep.index) ?? ep.watched;
    final saved = widget.episodeProgress?.call(ep.index);
    final progress = watched && !ep.current ? 1.0 : saved;
    final hasMenu =
        widget.onSetWatched != null || (widget.onPlayMirror != null && !dead);
    final numberLine = [
      if (ep.number != null) 'E${ep.number!.toInt()}',
      if (ep.current) 'Now playing' else if (watched) 'Watched',
    ].join(' · ');
    final titleColor = dead
        ? AppColors.textTertiary
        : ep.current
        ? AppColors.accent
        : watched
        ? AppColors.textSecondary
        : AppColors.textPrimary;

    final thumb = Container(
      width: 128,
      height: 72,
      foregroundDecoration: ep.current
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.accent, width: 2),
            )
          : null,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ep.thumb.isEmpty
                ? ColoredBox(color: AppColors.surface2)
                : CachedNetworkImage(
                    imageUrl: ep.thumb,
                    httpHeaders: widget.coverHeaders,
                    fit: BoxFit.cover,
                    memCacheWidth: 320,
                    errorWidget: (_, _, _) =>
                        ColoredBox(color: AppColors.surface2),
                  ),
            if (ep.current)
              ColoredBox(
                color: Colors.black.withValues(alpha: 0.35),
                child: Center(
                  child: _lucide('play', size: 22, color: Colors.white),
                ),
              ),
            if (progress != null && progress > 0)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: LinearProgressIndicator(
                  value: progress.clamp(0.0, 1.0),
                  minHeight: 3,
                  color: AppColors.accent,
                  backgroundColor: Colors.white24,
                ),
              ),
          ],
        ),
      ),
    );

    final content = Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
      child: Row(
        children: [
          thumb,
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (numberLine.isNotEmpty)
                  Text(
                    numberLine,
                    maxLines: 1,
                    style: AppText.caption.copyWith(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: ep.current
                          ? AppColors.accent
                          : AppColors.textTertiary,
                    ),
                  ),
                Flexible(
                  child: Text(
                    ep.label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.body.copyWith(
                      fontSize: 13.5,
                      height: 1.25,
                      fontWeight: FontWeight.w600,
                      color: titleColor,
                    ),
                  ),
                ),
                if (ep.meta.isNotEmpty)
                  Text(
                    ep.meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption.copyWith(
                      fontSize: 11.5,
                      color: AppColors.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
          if (!dead && widget.downloadButton != null)
            widget.downloadButton!(ep),
          if (hasMenu)
            // ⋯ drops the same graphite menu below the button.
            Builder(
              builder: (buttonContext) => _IconBtn(
                key: ValueKey('watch-row-more-${ep.index}'),
                icon: 'ellipsis',
                tooltip: context.l10n.more,
                color: AppColors.textSecondary,
                onTap: () => showDesktopContextMenu<Object?>(
                  context,
                  anchor: buttonContext,
                  items: _rowMenuItems(ep, watched, dead),
                ),
              ),
            ),
        ],
      ),
    );

    // Right-click opens the graphite row menu at the pointer; the Menu key
    // or Shift+F10 opens it while the row has keyboard focus.
    final row = DesktopContextMenuRegion(
      key: ValueKey('watch-row-menu-${ep.index}'),
      enabled: hasMenu,
      items: () => _rowMenuItems(ep, watched, dead),
      child: Material(
        color: ep.current ? AppColors.accentSoft : Colors.transparent,
        child: InkWell(
          key: ValueKey('watch-row-${ep.index}'),
          onTap: dead || ep.current
              ? null
              : () => widget.onOpenEpisode(ep.index),
          hoverColor: AppColors.surface2.withValues(alpha: 0.75),
          splashColor: AppColors.accentSoft,
          child: Stack(
            children: [
              content,
              // Accent edge marks the playing row even at a glance.
              if (ep.current)
                Positioned(
                  left: 0,
                  top: 12,
                  bottom: 12,
                  child: Container(
                    width: 3,
                    decoration: BoxDecoration(
                      color: AppColors.accent,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    return dead
        ? Tooltip(
            message: ep.unavailableReason!.trim(),
            child: Opacity(opacity: .55, child: row),
          )
        : row;
  }
}

/// Compact icon button with tooltip and hover, sized for a mouse.
class _IconBtn extends StatelessWidget {
  const _IconBtn({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.color = AppColors.textPrimary,
  });

  final String icon;
  final String tooltip;
  final VoidCallback? onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      iconSize: 18,
      constraints: const BoxConstraints.tightFor(width: 38, height: 38),
      padding: EdgeInsets.zero,
      style: IconButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      icon: _lucide(
        icon,
        color: onTap == null ? color.withValues(alpha: 0.35) : color,
      ),
    );
  }
}

/// Compact volume control for the theater transport: the speaker icon mutes
/// on click, and hovering it slides out a short level slider (YouTube-style),
/// so the bar stays narrow until the viewer reaches for it.
class _VolumeButton extends StatefulWidget {
  const _VolumeButton({
    required this.volumeStream,
    required this.initialVolume,
    required this.onChanged,
    required this.onToggleMute,
  });

  final Stream<double>? volumeStream;
  final double initialVolume;
  final ValueChanged<double> onChanged;
  final VoidCallback? onToggleMute;

  @override
  State<_VolumeButton> createState() => _VolumeButtonState();
}

class _VolumeButtonState extends State<_VolumeButton> {
  /// Mouse is over the button or its slider.
  bool _open = false;

  /// Level held locally while dragging so stream echoes don't fight the thumb.
  double? _drag;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _open = true),
      onExit: (_) => setState(() => _open = false),
      child: StreamBuilder<double>(
        stream: widget.volumeStream,
        initialData: widget.initialVolume,
        builder: (context, snap) {
          final v = (_drag ?? snap.data ?? widget.initialVolume).clamp(
            0.0,
            100.0,
          );
          final icon = v <= 0.5
              ? Icons.volume_off_rounded
              : v < 50
              ? Icons.volume_down_rounded
              : Icons.volume_up_rounded;
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                key: const ValueKey('watch-volume'),
                // "Mute · M" / "Unmute · M": same shortcut as the full player.
                tooltip: v <= 0.5
                    ? context.l10n.unmuteWithKey('M')
                    : context.l10n.muteWithKey('M'),
                onPressed: widget.onToggleMute,
                iconSize: 20,
                constraints: const BoxConstraints.tightFor(
                  width: 38,
                  height: 38,
                ),
                padding: EdgeInsets.zero,
                style: IconButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                icon: Icon(icon, color: Colors.white),
              ),
              // The slider slides open on hover and folds away after.
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOutCubic,
                width: _open || _drag != null ? 88 : 0,
                height: 28,
                child: ClipRect(
                  child: OverflowBox(
                    alignment: Alignment.centerLeft,
                    minWidth: 88,
                    maxWidth: 88,
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: Colors.white,
                        inactiveTrackColor: Colors.white.withValues(alpha: 0.3),
                        thumbColor: Colors.white,
                        trackHeight: 3,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 6,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 10,
                        ),
                      ),
                      child: Slider(
                        key: const ValueKey('watch-volume-slider'),
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        value: v,
                        max: 100,
                        onChanged: (x) {
                          setState(() => _drag = x);
                          widget.onChanged(x);
                        },
                        onChangeEnd: (x) => setState(() => _drag = null),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Speed button showing the live rate ("1x", "1.5x"); opens the picker.
class _SpeedBtn extends StatelessWidget {
  const _SpeedBtn({
    required this.rate,
    required this.tooltip,
    required this.onTap,
  });

  final double rate;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Trim "1.0" to "1" but keep "1.25".
    final text = rate == rate.roundToDouble()
        ? '${rate.toInt()}x'
        : '${double.parse(rate.toStringAsFixed(2))}x';
    return Tooltip(
      message: tooltip,
      child: TextButton(
        key: const ValueKey('watch-speed'),
        onPressed: onTap,
        style: TextButton.styleFrom(
          foregroundColor: Colors.white,
          minimumSize: const Size(44, 38),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          textStyle: AppText.caption.copyWith(
            fontWeight: FontWeight.w700,
            fontSize: 13,
            fontFeatures: const [ui.FontFeature.tabularFigures()],
          ),
        ),
        child: Text(text),
      ),
    );
  }
}

/// Outlined pill action under the video (Server / Audio / Subtitles / More).
class _ActionBtn extends StatelessWidget {
  const _ActionBtn({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final String icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: OutlinedButton.icon(
        onPressed: onTap,
        icon: _lucide(icon, size: 16),
        label: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 260),
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.textPrimary,
          backgroundColor: AppColors.surface,
          side: const BorderSide(color: AppColors.hairline),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          textStyle: AppText.body.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

/// One side-panel tab; selected tabs get a filled background.
class _TabBtn extends StatelessWidget {
  const _TabBtn({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? AppColors.textPrimary : AppColors.textSecondary;
    return Flexible(
      child: Material(
        color: selected ? AppColors.surface2 : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          hoverColor: AppColors.surface2.withValues(alpha: 0.6),
          child: Semantics(
            selected: selected,
            button: true,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _lucide(icon, size: 16, color: fg),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.body.copyWith(
                        color: fg,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Clickable dropdown pill: the [_MenuLabel] look plus hover/focus ink.
/// [onOpen] gets the pill's own context so the menu can drop below it;
/// Enter/Space open it from the keyboard like any button.
class _MenuPill extends StatelessWidget {
  const _MenuPill({
    super.key,
    required this.label,
    required this.tooltip,
    required this.onOpen,
  });

  final String label;
  final String tooltip;
  final void Function(BuildContext anchor) onOpen;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(9),
          hoverColor: Colors.white10,
          onTap: () => onOpen(context),
          child: _MenuLabel(label),
        ),
      ),
    );
  }
}

/// Dropdown-looking label for the season and range menus.
class _MenuLabel extends StatelessWidget {
  const _MenuLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 7, 8, 7),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            style: AppText.body.copyWith(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 4),
          _lucide('chevron-down', size: 16, color: AppColors.textSecondary),
        ],
      ),
    );
  }
}
