import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/desktop_hang_watch.dart';
import 'package:watch_app/core/logging/app_logger.dart';

Duration _s(int seconds) => Duration(seconds: seconds);

/// Ticks once a second from [from] to [to] and collects what gets written.
List<String> _run(HangWatchRules rules, int from, int to) => [
  for (var i = from; i <= to; i++) ...rules.tick(_s(i)),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HangWatchRules', () {
    test('silent while beats arrive, and before the first beat', () {
      final rules = HangWatchRules();
      expect(_run(rules, 1, 30), isEmpty);
      for (var i = 31; i < 60; i++) {
        expect(rules.beat(_s(i), 'resumed'), isEmpty);
        expect(rules.tick(_s(i)), isEmpty);
      }
    });

    test('nothing before 5 s, then the last step and the last lines', () {
      final rules = HangWatchRules()
        ..beat(_s(0), 'resumed')
        ..step(_s(2), 'player open');
      for (var i = 0; i < 40; i++) {
        rules.note('line $i');
      }
      expect(_run(rules, 1, 4), isEmpty);
      final report = rules.tick(_s(5));
      expect(
        report.first,
        'UI not responding for 5 s, last step player open (3 s ago), '
        'lifecycle resumed',
      );
      expect(report.length, 31);
      expect(report[1], '  line 10');
      expect(report.last, '  line 39');
    });

    test('one more line at 15 s and 60 s, then quiet', () {
      final rules = HangWatchRules()
        ..beat(_s(0), 'resumed')
        ..note('a');
      _run(rules, 1, 5);
      expect(_run(rules, 6, 14), isEmpty);
      expect(_run(rules, 15, 15), hasLength(1));
      expect(_run(rules, 16, 59), isEmpty);
      expect(_run(rules, 60, 60), hasLength(1));
      expect(_run(rules, 61, 300), isEmpty);
    });

    test('says when the app answers again, and can report once more', () {
      final rules = HangWatchRules()..beat(_s(0), 'resumed');
      _run(rules, 1, 7);
      expect(rules.beat(_s(8), 'resumed'), ['responding again after 8 s']);
      expect(rules.beat(_s(9), 'resumed'), isEmpty);
      expect(_run(rules, 8, 13), isEmpty);
      expect(_run(rules, 14, 14), hasLength(1));
    });

    test('a sleeping PC is not a stuck app', () {
      final rules = HangWatchRules()..beat(_s(0), 'resumed');
      _run(rules, 1, 2);
      expect(rules.tick(_s(4000)), isEmpty);
      expect(_run(rules, 4001, 4004), isEmpty);
      expect(rules.beat(_s(4004), 'resumed'), isEmpty);
    });
  });

  group('FrameStallRules', () {
    String state() => 'lifecycle=resumed, visible=true';
    List<String?> beats(
      FrameStallRules rules,
      int count, {
      bool drawn = false,
      bool wanted = true,
    }) => [
      for (var i = 0; i < count; i++)
        rules.beat(drawn: drawn, wanted: wanted, state: state),
    ];

    test('silent when hidden, idle or drawing', () {
      final rules = FrameStallRules();
      expect(beats(rules, 20, wanted: false), everyElement(isNull));
      expect(beats(rules, 20, drawn: true), everyElement(isNull));
      // Never 4 in a row.
      expect(beats(rules, 3), everyElement(isNull));
      expect(beats(rules, 1, wanted: false), [isNull]);
      expect(beats(rules, 3), everyElement(isNull));
    });

    test('reports once after 4 beats and once when the picture is back', () {
      final rules = FrameStallRules();
      expect(beats(rules, 3), everyElement(isNull));
      expect(beats(rules, 1), [
        '[ui] no picture for 4 s, lifecycle=resumed, visible=true',
      ]);
      expect(beats(rules, 5), everyElement(isNull));
      expect(beats(rules, 1, drawn: true), ['[ui] picture back after 9 s']);
      expect(beats(rules, 1, drawn: true), [isNull]);
    });
  });

  test('step and note do nothing when not started', () async {
    await DesktopHangWatch.start(); // A test run is a debug run.
    expect(AppLogger.onLine, isNull);
    DesktopHangWatch.step('x');
    DesktopHangWatch.note('y');
  });

  test(
    'a real stall is written while the app is stuck, and shown next start',
    () async {
      final dir = await Directory.systemTemp.createTemp('hang-watch');
      final file = File('${dir.path}/zangetsu-hang.log');
      try {
        AppLogger.instance.clearForTest();
        await DesktopHangWatch.debugStart(dir);
        expect(file.existsSync(), isFalse);
        AppLogger.instance.log('logged just before the stall');
        DesktopHangWatch.step('test stall');
        // Blocks this thread for real, so nothing here can send a beat.
        sleep(const Duration(seconds: 8));
        // Already on disk although this thread has not run anything since.
        final stuck = file.readAsStringSync();
        expect(stuck, contains('UI not responding for'));
        expect(stuck, contains('last step test stall'));
        expect(stuck, contains('logged just before the stall'));
        DesktopHangWatch.debugStop();

        await DesktopHangWatch.debugStart(dir);
        expect(
          AppLogger.instance.contents,
          contains(RegExp(r'\[hang\] .*last step test stall')),
        );
        expect(file.existsSync(), isFalse);
        expect(File('${dir.path}/zangetsu-hang.old.log').existsSync(), isTrue);
      } finally {
        DesktopHangWatch.debugStop();
        AppLogger.instance.clearForTest();
        await dir.delete(recursive: true);
      }
    },
  );
}
