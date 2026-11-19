// Windows: short on-screen feedback for keyboard and mouse-wheel input on the
// theater watch page (volume level / mute, and how far a seek jumped). The
// full player reuses its own swipe HUD and seek indicator for the same input;
// this is the matching indicator for the watch page, which is a separate
// library and cannot reach those private widgets.
import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../l10n/l10n.dart';

/// What the indicator is currently showing.
enum DesktopHudKind { volume, seek }

/// One indicator state. [serial] changes on every input so the widget can
/// replay its fade even when the value itself did not change.
@immutable
class DesktopHudEvent {
  const DesktopHudEvent.volume({required this.serial, this.volume})
    : kind = DesktopHudKind.volume,
      seekSeconds = 0;

  const DesktopHudEvent.seek(this.seekSeconds, {required this.serial})
    : kind = DesktopHudKind.seek,
      volume = null;

  final DesktopHudKind kind;

  /// Signed running total of a burst of seeks (−20 = two 10s rewinds).
  final int seekSeconds;

  /// The level the input just set (0..100). The player applies volume
  /// asynchronously, so the live stream can lag a frame behind; this lets
  /// the pill show the new level at once. Null = read the stream.
  final double? volume;
  final int serial;
}

/// Drives [DesktopPlayerHud]: shows an event, then clears it after [hold].
class DesktopHudController extends ValueNotifier<DesktopHudEvent?> {
  DesktopHudController({this.hold = const Duration(milliseconds: 900)})
    : super(null);

  /// How long the indicator stays after the last input.
  final Duration hold;
  Timer? _timer;
  int _serial = 0;

  /// Volume changed or mute toggled: show [volume] (0..100) when known,
  /// else the live level.
  void showVolume([double? volume]) =>
      _show(DesktopHudEvent.volume(serial: ++_serial, volume: volume));

  /// A seek of [seconds] (negative = back). Seeks in the same direction while
  /// the indicator is up add up (+10s, +20s, …), like the double-tap seek.
  void showSeek(int seconds) {
    final cur = value;
    var total = seconds;
    if (cur != null &&
        cur.kind == DesktopHudKind.seek &&
        cur.seekSeconds.sign == seconds.sign) {
      total += cur.seekSeconds;
    }
    _show(DesktopHudEvent.seek(total, serial: ++_serial));
  }

  void _show(DesktopHudEvent e) {
    value = e;
    _timer?.cancel();
    _timer = Timer(hold, () => value = null);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// Centred pill over the video: volume (icon, percent and a level bar) or
/// a seek (arrow and "+10s"). Same translucent black capsule as the player's
/// swipe HUD so both layouts read alike.
class DesktopPlayerHud extends StatelessWidget {
  const DesktopPlayerHud({
    super.key,
    required this.controller,
    required this.volumeStream,
    required this.initialVolume,
  });

  final ValueListenable<DesktopHudEvent?> controller;

  /// Live player volume (0..100); read when a volume event shows so a mute
  /// toggle shows the level the player really ended up at.
  final Stream<double>? volumeStream;
  final double initialVolume;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ValueListenableBuilder<DesktopHudEvent?>(
        valueListenable: controller,
        builder: (context, event, _) {
          return AnimatedOpacity(
            opacity: event == null ? 0 : 1,
            duration: Duration(milliseconds: event == null ? 260 : 120),
            child: event == null
                ? const SizedBox.shrink()
                : Center(
                    child: event.kind == DesktopHudKind.seek
                        ? _pill(
                            icon: event.seekSeconds < 0
                                ? Icons.fast_rewind_rounded
                                : Icons.fast_forward_rounded,
                            text:
                                '${event.seekSeconds < 0 ? '−' : '+'}${event.seekSeconds.abs()}s',
                          )
                        : event.volume != null
                        // The level the input just set: no stream lag.
                        ? _volumePill(event.volume!)
                        : StreamBuilder<double>(
                            stream: volumeStream,
                            initialData: initialVolume,
                            builder: (context, snap) =>
                                _volumePill(snap.data ?? initialVolume),
                          ),
                  ),
          );
        },
      ),
    );
  }

  Widget _volumePill(double volume) {
    final v = volume.clamp(0.0, 100.0);
    final muted = v <= 0.5;
    return _pill(
      key: const ValueKey('watch-hud-volume'),
      icon: muted
          ? Icons.volume_off_rounded
          : v < 50
          ? Icons.volume_down_rounded
          : Icons.volume_up_rounded,
      // "Muted" reads clearer than "0%" after pressing M.
      text: muted ? appL10n.muted : '${v.round()}%',
      level: v / 100,
    );
  }

  Widget _pill({
    Key? key,
    required IconData icon,
    required String text,
    double? level,
  }) {
    return DecoratedBox(
      key: key,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 22),
            const SizedBox(width: 10),
            Text(
              text,
              style: AppText.caption.copyWith(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            if (level != null) ...[
              const SizedBox(width: 12),
              // Thin level bar in the accent, like the swipe HUD's fill.
              SizedBox(
                width: 90,
                height: 4,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: level.clamp(0.0, 1.0),
                    color: AppColors.accent,
                    backgroundColor: Colors.white24,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
