import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/desktop_window.dart';
import 'package:watch_app/core/desktop/desktop_player_input.dart';
import 'package:watch_app/core/ui/global_messenger.dart';

/// Checks actual desktop shortcut dispatch with a simulated native window.
void main() {
  for (final fullscreen in [false, true]) {
    testWidgets(
      'Escape dismisses sheets only when fullscreen=$fullscreen is false',
      (tester) async {
        const channel = MethodChannel('com.spyou.zangetsu/window');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (_) async => fullscreen,
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: rootNavigatorKey,
            builder: (_, child) => DesktopWindow(child: child!),
            home: const Scaffold(body: Text('Home')),
          ),
        );
        showModalBottomSheet<void>(
          context: rootNavigatorKey.currentContext!,
          builder: (_) => const Text('Open sheet'),
        );
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(
          find.text('Open sheet'),
          fullscreen ? findsOneWidget : findsNothing,
        );
      },
    );
  }
  testWidgets('keyboard seeking honors the chosen duration', (tester) async {
    final seeks = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: DesktopPlayerInput(
          seekSeconds: 25,
          onPlayPause: () {},
          onSeek: seeks.add,
          onVolume: (_) {},
          onMute: () {},
          onBack: () {},
          child: const SizedBox(),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    expect(seeks, [25, -25]);
  });
}
