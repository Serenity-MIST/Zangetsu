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

    test('a second request while the dialog is open is ignored', () async {
      final fake = _FakeClose();
      final first = DesktopCloseGuard.handleCloseRequest(
        actions: DesktopCloseActions(
          quit: fake.actions.quit,
          hideToTray: fake.actions.hideToTray,
          // Never answers during the second request.
          confirm: (count) async {
            fake.log.add('confirm');
            await Future<void>.delayed(const Duration(milliseconds: 10));
            return DesktopCloseChoice.cancel;
          },
        ),
        behaviour: 'ask',
        activeCount: 1,
      );
      await DesktopCloseGuard.handleCloseRequest(
        actions: fake.actions,
        behaviour: 'quit',
      );
      await first;
      expect(fake.log, ['confirm']);
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
