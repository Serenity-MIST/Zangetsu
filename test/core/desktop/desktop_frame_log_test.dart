import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/desktop_frame_log.dart';

/// A frame that took [buildMs] to build and [rasterMs] to draw.
FrameTiming _frame(double buildMs, double rasterMs) {
  final build = (buildMs * 1000).round(), raster = (rasterMs * 1000).round();
  return FrameTiming(
    vsyncStart: 0,
    buildStart: 0,
    buildFinish: build,
    rasterStart: build,
    rasterFinish: build + raster,
    rasterFinishWallTime: build + raster,
  );
}

/// Hands [timings] to the app the way the engine reports them.
void _report(List<FrameTiming> timings) =>
    SchedulerBinding.instance.platformDispatcher.onReportTimings!(timings);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(DesktopFrameLog.stop);

  test('off by default: no variable means nothing is registered', () {
    final lines = <String>[];
    expect(
      DesktopFrameLog.startIfAsked(
        environment: const {},
        windows: true,
        write: lines.add,
      ),
      isFalse,
    );
    expect(DesktopFrameLog.running, isNull);
    expect(lines, isEmpty);
  });

  test('any value other than 1 keeps it off', () {
    for (final value in ['0', '', 'true', 'yes']) {
      expect(
        DesktopFrameLog.startIfAsked(
          environment: {desktopFrameLogVariable: value},
          windows: true,
        ),
        isFalse,
      );
    }
    expect(DesktopFrameLog.running, isNull);
  });

  test('never turns on off Windows, even with the variable set', () {
    expect(
      DesktopFrameLog.startIfAsked(
        environment: const {desktopFrameLogVariable: '1'},
        windows: false,
      ),
      isFalse,
    );
    expect(DesktopFrameLog.running, isNull);
  });

  test('on Windows with the variable it writes one summary line', () {
    final lines = <String>[];
    expect(
      DesktopFrameLog.startIfAsked(
        environment: const {desktopFrameLogVariable: '1'},
        windows: true,
        write: lines.add,
      ),
      isTrue,
    );
    // One line saying it is on.
    expect(lines, hasLength(1));
    _report([_frame(2, 5), _frame(4, 20), _frame(3, 40)]);
    DesktopFrameLog.running!.flushNow();
    expect(lines, hasLength(2));
    expect(
      lines.last,
      '[frames] n=3 build avg/p90/max 3.0/4.0/4.0ms '
      'raster avg/p90/max 21.7/40.0/40.0ms over16ms=2 over33ms=1',
    );
    // Nothing drawn since: no further line.
    DesktopFrameLog.running!.flushNow();
    expect(lines, hasLength(2));
  });

  test('summary line counts a frame as slow when either part is slow', () {
    final line = desktopFrameSummary([
      for (var i = 0; i < 9; i++) (1000, 2000),
      (20000, 1000),
    ]);
    expect(
      line,
      '[frames] n=10 build avg/p90/max 2.9/1.0/20.0ms '
      'raster avg/p90/max 1.9/2.0/2.0ms over16ms=1 over33ms=0',
    );
  });
}
