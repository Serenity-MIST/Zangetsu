// R1: the player's keys ignore a focused text field (Watch Together chat)
// and come back on a click on the video, plus the focus repair after the
// focused chat field is removed.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/desktop_focus_repair.dart';
import 'package:watch_app/core/desktop/desktop_player_input.dart';

void main() {
  setUp(DesktopFocusRepair.debugReset);
  tearDown(() {
    DesktopFocusRepair.debugReset();
  });

  // Player with a chat-like text field on the right (shown while [chat]).
  Widget player({
    required VoidCallback onPlay,
    required FocusNode field,
    bool chat = true,
  }) => MaterialApp(
    home: DesktopPlayerInput(
      onPlayPause: onPlay,
      onBack: () {},
      onMute: () {},
      onSeek: (_) {},
      onVolume: (_) {},
      child: Scaffold(
        body: Row(
          children: [
            const Expanded(child: SizedBox.expand(key: Key('video'))),
            if (chat)
              SizedBox(
                width: 200,
                child: TextField(key: const Key('chat'), focusNode: field),
              ),
          ],
        ),
      ),
    ),
  );

  testWidgets('keys go to the text field while typing, not the player', (
    tester,
  ) async {
    var play = 0;
    final field = FocusNode();
    addTearDown(field.dispose);
    await tester.pumpWidget(player(onPlay: () => play++, field: field));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(play, 1);

    await tester.tap(find.byKey(const Key('chat')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    // Space typed into the field, the player did not toggle.
    expect(play, 1);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('a click on the video takes the keys back', (tester) async {
    var play = 0;
    final field = FocusNode();
    addTearDown(field.dispose);
    await tester.pumpWidget(player(onPlay: () => play++, field: field));
    await tester.pump();
    final node = DesktopFocusRepair.registered.single;

    // Focus parked on a bare scope (what scope-unfocus used to leave).
    field.requestFocus();
    await tester.pump();
    field.unfocus();
    await tester.pump();
    expect(node.hasFocus, isFalse);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.down(tester.getCenter(find.byKey(const Key('video'))));
    await mouse.up();
    await tester.pump();
    expect(node.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(play, 1);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('closing chat with its field focused hands keys back', (
    tester,
  ) async {
    var play = 0;
    final field = FocusNode();
    addTearDown(field.dispose);
    await tester.pumpWidget(player(onPlay: () => play++, field: field));
    await tester.pump();
    final node = DesktopFocusRepair.registered.single;
    await tester.tap(find.byKey(const Key('chat')));
    await tester.pump();
    // Chat closes: the focused field is removed from the tree.
    await tester.pumpWidget(
      player(onPlay: () => play++, field: field, chat: false),
    );
    DesktopFocusRepair.schedule();
    await tester.pump();
    await tester.pump();
    expect(node.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(play, 1);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
