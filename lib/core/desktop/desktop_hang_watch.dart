import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../logging/app_logger.dart';
import '../platform/app_paths.dart';

/// Windows-only diagnostic for "the app jammed".
///
/// The normal log cannot explain a jam: it is written by the same thread that
/// got stuck, a little after each line, so the last lines are lost when the
/// app has to be ended. Here a second, separate worker keeps the last lines
/// and the last step in memory. The app sends it a beat every second; when
/// the beats stop for 5 seconds the worker itself writes everything to
/// zangetsu-hang.log. The next start copies that into the normal log, so
/// "export logs" contains it.
///
/// Never started on phone, TV, in debug runs or in tests; [step] and [note]
/// then do nothing.
abstract final class DesktopHangWatch {
  static const _fileName = 'zangetsu-hang.log';
  static const _oldFileName = 'zangetsu-hang.old.log';

  /// How many lines of the last report are copied into the normal log.
  static const _copiedLines = 40;

  static bool _started = false;
  static SendPort? _port;
  static Isolate? _worker;
  static Timer? _timer;
  static bool _frameDrawn = false;
  static FrameStallRules _frames = FrameStallRules();

  /// Starts watching. Never throws: the app must start even if this cannot.
  static Future<void> start() async {
    if (kDebugMode || kIsWeb || !Platform.isWindows || _started) return;
    try {
      await _start(await getWritableAppDirectory());
    } catch (_) {
      // Only a diagnostic.
    }
  }

  static Future<void> _start(Directory dir) async {
    if (_started) return;
    _started = true;
    final path = '${dir.path}/$_fileName';
    await _reportLastSession(File(path), '${dir.path}/$_oldFileName');
    final ready = ReceivePort();
    _worker = await Isolate.spawn(_watch, (
      ready.sendPort,
      path,
    ), debugName: 'hang-watch');
    _port = await ready.first as SendPort;
    AppLogger.onLine = note;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _beat();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _beat());
  }

  /// Remembers what the app is about to do (shown as "last step").
  static void step(String what) => _port?.send((_MessageKind.step, what));

  /// Remembers one log line.
  static void note(String line) => _port?.send((_MessageKind.note, line));

  static void _onTimings(List<FrameTiming> timings) => _frameDrawn = true;

  // Once a second on the UI side: tell the worker we are alive, and check that
  // frames the app asked for really get drawn.
  static void _beat() {
    final scheduler = SchedulerBinding.instance;
    final lifecycle = scheduler.lifecycleState?.name ?? 'unknown';
    _port?.send((_MessageKind.beat, lifecycle));
    final drawn = _frameDrawn;
    _frameDrawn = false;
    final line = _frames.beat(
      drawn: drawn,
      wanted: scheduler.framesEnabled && scheduler.hasScheduledFrame,
      state: () {
        final size = scheduler.platformDispatcher.implicitView?.physicalSize;
        return 'lifecycle=$lifecycle, '
            'visible=${size != null && !size.isEmpty}';
      },
    );
    if (line != null) AppLogger.instance.log(line);
  }

  // Copies what the last session left into the normal log, once.
  static Future<void> _reportLastSession(File file, String oldPath) async {
    try {
      if (!await file.exists()) return;
      final text = utf8.decode(await file.readAsBytes(), allowMalformed: true);
      final lines = [
        for (final line in const LineSplitter().convert(text))
          if (line.trim().isNotEmpty) line,
      ];
      if (lines.isEmpty) return;
      final from = lines.length > _copiedLines
          ? lines.length - _copiedLines
          : 0;
      for (final line in lines.sublist(from)) {
        AppLogger.instance.log('[hang] $line');
      }
      await file.rename(oldPath);
    } catch (_) {
      // Only a diagnostic.
    }
  }

  /// [start] against a folder, without the Windows release check.
  @visibleForTesting
  static Future<void> debugStart(Directory dir) => _start(dir);

  @visibleForTesting
  static void debugStop() {
    if (!_started) return;
    _timer?.cancel();
    _worker?.kill(priority: Isolate.immediate);
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    AppLogger.onLine = null;
    _started = false;
    _port = null;
    _worker = null;
    _timer = null;
    _frameDrawn = false;
    _frames = FrameStallRules();
  }

  // The worker. Runs on its own thread, so it keeps going (and can write to
  // disk) while the app's own thread is stuck.
  static void _watch((SendPort, String) args) {
    final (ready, path) = args;
    final file = File(path);
    final clock = Stopwatch()..start();
    final rules = HangWatchRules();
    void write(List<String> lines) {
      if (lines.isEmpty) return;
      try {
        final now = DateTime.now().toIso8601String();
        final text = lines.map((line) => '$now $line\n').join();
        // Starting over past the limit keeps the newest report, which is the
        // one worth having.
        final full = file.existsSync() && file.lengthSync() > 200 * 1024;
        file.writeAsStringSync(
          text,
          mode: full ? FileMode.write : FileMode.append,
          flush: true,
        );
      } catch (_) {
        // Nowhere to report it to.
      }
    }

    final inbox = ReceivePort();
    inbox.listen((message) {
      final (kind, text) = message as (_MessageKind, String);
      switch (kind) {
        case _MessageKind.beat:
          write(rules.beat(clock.elapsed, text));
        case _MessageKind.step:
          rules.step(clock.elapsed, text);
        case _MessageKind.note:
          rules.note(text);
      }
    });
    Timer.periodic(
      const Duration(seconds: 1),
      (_) => write(rules.tick(clock.elapsed)),
    );
    ready.send(inbox.sendPort);
  }
}

enum _MessageKind { beat, step, note }

/// Decides when the app counts as not responding and what to write. Fed with
/// times only, so it can be tested without a second thread.
class HangWatchRules {
  /// A report at 5 s with everything known, then one more line at 15 and 60 s.
  static const _limits = [
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 60),
  ];

  /// The worker's own 1 s timer being this late means the whole PC was asleep
  /// or overloaded, which says nothing about the app.
  static const _ownDelay = Duration(seconds: 4);

  static const _keptLines = 30;

  final List<String> _lines = [];
  Duration? _lastBeat;
  Duration? _lastTick;
  String _step = 'none';
  Duration _stepAt = Duration.zero;
  String _lifecycle = 'unknown';
  int _reported = 0;

  void note(String line) {
    _lines.add(line);
    if (_lines.length > _keptLines) _lines.removeAt(0);
  }

  void step(Duration now, String what) {
    _step = what;
    _stepAt = now;
  }

  /// The app is alive. Returns a line when it had been reported as stuck.
  List<String> beat(Duration now, String lifecycle) {
    final last = _lastBeat;
    final wasReported = _reported > 0;
    _lastBeat = now;
    _lifecycle = lifecycle;
    _reported = 0;
    if (!wasReported || last == null) return const [];
    return ['responding again after ${(now - last).inSeconds} s'];
  }

  /// Called every second; returns what to write, usually nothing.
  List<String> tick(Duration now) {
    final lastTick = _lastTick;
    _lastTick = now;
    final beat = _lastBeat;
    if (beat == null) return const [];
    if (lastTick != null && now - lastTick > _ownDelay) {
      _lastBeat = now;
      _reported = 0;
      return const [];
    }
    if (_reported >= _limits.length) return const [];
    final quiet = now - beat;
    if (quiet < _limits[_reported]) return const [];
    _reported++;
    final head =
        'UI not responding for ${quiet.inSeconds} s, last step $_step '
        '(${(now - _stepAt).inSeconds} s ago), lifecycle $_lifecycle';
    if (_reported > 1) return [head];
    return [head, for (final line in _lines) '  $line'];
  }
}

/// Notices frames the app asked for that never get drawn: the app itself runs,
/// but the picture is frozen.
class FrameStallRules {
  static const _beats = 4;

  int _waiting = 0;

  /// Beats since the last drawn frame once reported, 0 when not reported.
  int _stuck = 0;

  /// One call per second. [drawn]: a frame was drawn since the last call.
  /// [wanted]: the window is shown and a frame is waiting to be drawn.
  String? beat({
    required bool drawn,
    required bool wanted,
    required String Function() state,
  }) {
    if (drawn) {
      final stuck = _stuck;
      _waiting = 0;
      _stuck = 0;
      return stuck > 0 ? '[ui] picture back after $stuck s' : null;
    }
    if (_stuck > 0) {
      _stuck++;
      return null;
    }
    // Hidden, minimised or nothing to draw: no frame is expected.
    _waiting = wanted ? _waiting + 1 : 0;
    if (_waiting < _beats) return null;
    _stuck = _waiting;
    return '[ui] no picture for $_beats s, ${state()}';
  }
}
