import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/desktop_background_work.dart';
import 'package:watch_app/core/desktop/desktop_close_guard.dart';
import 'package:watch_app/core/desktop/desktop_native.dart';
import 'package:watch_app/core/desktop/desktop_window.dart';

/// Records which close side effect ran, standing in for the real window.
class _FakeClose {
  final log = <String>[];
  DesktopCloseChoice? answer;

  DesktopCloseActions get actions => DesktopCloseActions(
    quit: () async => log.add('quit'),
    hideToTray: () async => log.add('tray'),
    confirm: (count) async {
      log.add('confirm:$count');
      return answer;
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    DesktopCloseGuard.debugReset();
    DesktopBackgroundWork.debugReset();
  });

  group('decide', () {
    // Every stored behaviour with and without running work.
    final cases = <(String, int, DesktopCloseAction)>[
      ('ask', 0, DesktopCloseAction.quit),
      ('ask', 2, DesktopCloseAction.confirm),
      ('trayWhileDownloading', 0, DesktopCloseAction.quit),
      ('trayWhileDownloading', 1, DesktopCloseAction.hideToTray),
      ('alwaysTray', 0, DesktopCloseAction.hideToTray),
      ('alwaysTray', 3, DesktopCloseAction.hideToTray),
      ('quit', 0, DesktopCloseAction.quit),
      ('quit', 5, DesktopCloseAction.quit),
      ('something-unknown', 1, DesktopCloseAction.confirm),
    ];
    for (final (behaviour, count, expected) in cases) {
      test('$behaviour with $count active -> $expected', () {
        expect(
          DesktopCloseGuard.decide(behaviour: behaviour, activeCount: count),
          expected,
        );
      });
    }
  });

  test('stored behaviour defaults to ask when the prefs box is closed', () {
    expect(DesktopCloseGuard.readCloseBehaviour(), 'ask');
  });

  group('handleCloseRequest', () {
    test('ask without downloads quits at once', () async {
      final fake = _FakeClose();
      await DesktopCloseGuard.handleCloseRequest(
        actions: fake.actions,
        behaviour: 'ask',
        activeCount: 0,
      );
      expect(fake.log, ['quit']);
    });

    test('ask with downloads follows the dialog answer', () async {
      for (final (answer, expected) in [
        (DesktopCloseChoice.quit, ['confirm:2', 'quit']),
        (DesktopCloseChoice.tray, ['confirm:2', 'tray']),
        (DesktopCloseChoice.cancel, ['confirm:2']),
        (null, ['confirm:2']),
      ]) {
        final fake = _FakeClose()..answer = answer;
        await DesktopCloseGuard.handleCloseRequest(
          actions: fake.actions,
          behaviour: 'ask',
          activeCount: 2,
        );
        expect(fake.log, expected, reason: 'answer $answer');
      }
    });

    test('reads the active count from DesktopBackgroundWork', () async {
      DesktopBackgroundWork.register(
        'downloads',
        label: 'Downloads',
        activeCount: () => 3,
      );
      final fake = _FakeClose();
      await DesktopCloseGuard.handleCloseRequest(
        actions: fake.actions,
        behaviour: 'trayWhileDownloading',
      );
      expect(fake.log, ['tray']);
    });

    group('a second request while the question is open', () {
      late DateTime now;
      late _FakeClose fake;
      late Completer<DesktopCloseChoice?> answer;

      // Starts a first close that asks and waits for [answer].
      Future<void> askFirst({Future<void> Function()? quit}) {
        return DesktopCloseGuard.handleCloseRequest(
          actions: DesktopCloseActions(
            quit: quit ?? fake.actions.quit,
            hideToTray: fake.actions.hideToTray,
            confirm: (count) {
              fake.log.add('confirm');
              return answer.future;
            },
            // The real dialog closes itself without an answer.
            dismiss: () {
              fake.log.add('dismiss');
              if (!answer.isCompleted) answer.complete(null);
            },
          ),
          behaviour: 'ask',
          activeCount: 1,
        );
      }

      // A repeated close; its own actions must never run.
      Future<void> closeAgain() => DesktopCloseGuard.handleCloseRequest(
        actions: DesktopCloseActions(
          quit: () async => fake.log.add('wrong-quit'),
          hideToTray: () async => fake.log.add('wrong-tray'),
          confirm: (_) async => null,
        ),
        behaviour: 'ask',
        activeCount: 1,
      );

      setUp(() {
        now = DateTime(2026, 1, 1, 12);
        DesktopCloseGuard.debugNow = () => now;
        fake = _FakeClose();
        answer = Completer<DesktopCloseChoice?>();
      });

      test('quits when it comes a moment after the first', () async {
        final first = askFirst();
        now = now.add(const Duration(milliseconds: 1500));
        await closeAgain();
        expect(fake.log, ['confirm', 'dismiss', 'quit']);
        // A third click while quitting does nothing more.
        now = now.add(const Duration(seconds: 2));
        await closeAgain();
        await first;
        expect(fake.log, ['confirm', 'dismiss', 'quit']);
      });

      test('is ignored as a double-click when it comes too soon', () async {
        final first = askFirst();
        now = now.add(const Duration(milliseconds: 200));
        await closeAgain();
        expect(fake.log, ['confirm']);
        // A later, deliberate click still quits.
        now = now.add(DesktopCloseGuard.secondRequestGap);
        await closeAgain();
        expect(fake.log, ['confirm', 'dismiss', 'quit']);
        await first;
      });

      // Reported: a quick second click on the app's X was ignored as a
      // double-click and the app looked stuck.
      test('a click on the X quits at once, however soon', () async {
        final first = askFirst();
        now = now.add(const Duration(milliseconds: 150));
        await DesktopCloseGuard.closeButtonPressed(
          requestClose: () async => fake.log.add('wrong-request'),
        );
        expect(fake.log, ['confirm', 'dismiss', 'quit']);
        await first;
      });

      test('the X asks normally when no question is open', () async {
        await DesktopCloseGuard.closeButtonPressed(
          requestClose: () async => fake.log.add('request'),
        );
        expect(fake.log, ['request']);
      });

      test('Cancel still cancels and a new close asks again', () async {
        final first = askFirst();
        answer.complete(DesktopCloseChoice.cancel);
        await first;
        expect(fake.log, ['confirm']);
        answer = Completer<DesktopCloseChoice?>();
        final second = askFirst();
        answer.complete(DesktopCloseChoice.tray);
        await second;
        expect(fake.log, ['confirm', 'confirm', 'tray']);
      });

      test('a fresh close after a forced quit is handled normally', () async {
        final first = askFirst();
        now = now.add(const Duration(seconds: 2));
        await closeAgain();
        await first;
        answer = Completer<DesktopCloseChoice?>();
        final next = askFirst();
        answer.complete(DesktopCloseChoice.tray);
        await next;
        expect(fake.log, ['confirm', 'dismiss', 'quit', 'confirm', 'tray']);
      });

      test('holding Alt+F4 down does not quit', () async {
        final first = askFirst();
        // Key repeat: a first repeat after the longest delay (1 s), then a
        // stream at the slowest repeat rate (400 ms) for five seconds.
        now = now.add(const Duration(milliseconds: 1000));
        await closeAgain();
        for (var i = 0; i < 12; i++) {
          now = now.add(const Duration(milliseconds: 400));
          await closeAgain();
        }
        // ... and at the fast rate too.
        for (var i = 0; i < 30; i++) {
          now = now.add(const Duration(milliseconds: 33));
          await closeAgain();
        }
        expect(fake.log, ['confirm']);
        // After letting go, a deliberate new click quits.
        now = now.add(const Duration(milliseconds: 800));
        await closeAgain();
        expect(fake.log, ['confirm', 'dismiss', 'quit']);
        await first;
      });

      test('the question stays busy until the forced quit is done', () async {
        final quitting = Completer<void>();
        var finished = false;
        final first = askFirst(
          quit: () {
            fake.log.add('quit');
            return quitting.future;
          },
        ).then((_) => finished = true);
        now = now.add(const Duration(seconds: 2));
        final forced = closeAgain();
        await Future<void>.delayed(Duration.zero);
        expect(fake.log, ['confirm', 'dismiss', 'quit']);
        // The dialog is gone, but a new close while quitting asks nothing.
        now = now.add(const Duration(seconds: 2));
        await closeAgain();
        expect(fake.log, ['confirm', 'dismiss', 'quit']);
        expect(finished, isFalse);
        quitting.complete();
        await forced;
        await first;
        expect(finished, isTrue);
      });
    });

    test('a repeated request while quitting is ignored', () async {
      final quitting = Completer<void>();
      final log = <String>[];
      final first = DesktopCloseGuard.handleCloseRequest(
        actions: DesktopCloseActions(
          quit: () {
            log.add('quit');
            return quitting.future;
          },
          hideToTray: () async => log.add('tray'),
          confirm: (_) async => null,
        ),
        behaviour: 'quit',
      );
      await DesktopCloseGuard.handleCloseRequest(
        actions: DesktopCloseActions(
          quit: () async => log.add('second-quit'),
          hideToTray: () async => log.add('second-tray'),
          confirm: (_) async => null,
        ),
        behaviour: 'quit',
      );
      quitting.complete();
      await first;
      expect(log, ['quit']);
    });
  });

  group('DesktopBackgroundWork', () {
    test('sums sources, ignores failing ones and pauses all', () async {
      var paused = 0;
      DesktopBackgroundWork.register(
        'a',
        label: 'Downloads',
        activeCount: () => 2,
        pauseAll: () async => paused++,
      );
      DesktopBackgroundWork.register(
        'b',
        label: 'Broken',
        activeCount: () => throw StateError('boom'),
        pauseAll: () async => throw StateError('boom'),
      );
      DesktopBackgroundWork.register(
        'c',
        label: 'Sync',
        activeCount: () => 1,
        pauseAll: () async => paused++,
      );
      expect(DesktopBackgroundWork.activeCount, 3);
      expect(DesktopBackgroundWork.activeLabels, ['Downloads', 'Sync']);
      await DesktopBackgroundWork.pauseAll();
      expect(paused, 2);
      DesktopBackgroundWork.unregister('a');
      expect(DesktopBackgroundWork.activeCount, 1);
    });

    test('notifies listeners on changes', () {
      var changes = 0;
      void listener() => changes++;
      DesktopBackgroundWork.changes.addListener(listener);
      addTearDown(() => DesktopBackgroundWork.changes.removeListener(listener));
      DesktopBackgroundWork.register('x', label: 'X', activeCount: () => 0);
      DesktopBackgroundWork.notifyChanged();
      DesktopBackgroundWork.unregister('x');
      DesktopBackgroundWork.unregister('missing');
      expect(changes, 3);
    });
  });

  testWidgets('close dialog returns the picked choice', (tester) async {
    DesktopCloseChoice? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              picked = await showDialog<DesktopCloseChoice>(
                context: context,
                builder: (_) => const DesktopCloseDialog(activeCount: 2),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('2 downloads in progress'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('close-guard-tray')));
    await tester.pumpAndSettle();
    expect(picked, DesktopCloseChoice.tray);
  });

  testWidgets('close dialog text for one download', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: DesktopCloseDialog(activeCount: 1)),
    );
    expect(find.text('1 download in progress'), findsOneWidget);
    expect(find.textContaining('Quitting stops them.'), findsOneWidget);
  });

  test('running work of one source alone', () {
    DesktopBackgroundWork.register('other', label: 'S', activeCount: () => 1);
    DesktopBackgroundWork.register(
      'downloads',
      label: 'D',
      activeCount: () => 2,
    );
    addTearDown(() {
      DesktopBackgroundWork.unregister('other');
      DesktopBackgroundWork.unregister('downloads');
    });
    expect(DesktopBackgroundWork.activeCountOf('other'), 1);
    expect(DesktopBackgroundWork.activeCountOf('missing'), 0);
    expect(DesktopBackgroundWork.activeCount, 3);
  });

  group('native events', () {
    tearDown(() {
      DesktopWindow.fullscreen.value = false;
      DesktopWindow.maximized.value = false;
      DesktopWindow.miniPlayer.value = false;
    });

    test('window state notifiers follow the runner', () async {
      await DesktopNative.debugHandleNativeCall(
        const MethodCall('fullscreenChanged', true),
      );
      await DesktopNative.debugHandleNativeCall(
        const MethodCall('maximizedChanged', true),
      );
      await DesktopNative.debugHandleNativeCall(
        const MethodCall('miniPlayerChanged', true),
      );
      expect(DesktopWindow.fullscreen.value, isTrue);
      expect(DesktopWindow.maximized.value, isTrue);
      expect(DesktopWindow.miniPlayer.value, isTrue);
      await DesktopNative.debugHandleNativeCall(
        const MethodCall('fullscreenChanged', false),
      );
      expect(DesktopWindow.fullscreen.value, isFalse);
    });

    test('media commands are parsed', () async {
      final next = DesktopNative.mediaCommands.first;
      await DesktopNative.debugHandleNativeCall(
        const MethodCall('mediaCommand', {'kind': 'seek', 'positionMs': 1500}),
      );
      final command = await next;
      expect(command.kind, DesktopMediaCommandKind.seek);
      expect(command.position, const Duration(milliseconds: 1500));
    });
  });

  testWidgets('Esc in a text field only unfocuses, it does not pop', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    final field = FocusNode();
    addTearDown(field.dispose);
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigator, home: const Text('home')),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(body: TextField(focusNode: field)),
      ),
    );
    await tester.pumpAndSettle();
    field.requestFocus();
    await tester.pump();
    expect(field.hasFocus, isTrue);
    await DesktopWindow.handleEscape();
    await tester.pump();
    expect(field.hasFocus, isFalse);
    expect(find.byType(TextField), findsOneWidget);
  });
}
