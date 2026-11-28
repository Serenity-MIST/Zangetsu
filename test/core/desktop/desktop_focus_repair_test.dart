// R1: lost keyboard focus (a bare scope, nothing focused) is handed back to
// the newest registered page node, and only on the Windows UI.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/desktop_focus_repair.dart';

void main() {
  setUp(DesktopFocusRepair.debugReset);
  tearDown(() {
    DesktopFocusRepair.debugReset();
  });

  // A page with a registered key node that counts K presses, plus a text
  // field to type in.
  Widget page({required ValueSetter<int> onK, required FocusNode field}) {
    var presses = 0;
    return MaterialApp(
      home: Scaffold(
        body: DesktopRepairFocus(
          autofocus: true,
          debugLabel: 'page',
          onKeyEvent: (_, event) {
            if (event is KeyDownEvent &&
                event.logicalKey == LogicalKeyboardKey.keyK) {
              onK(++presses);
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Column(
            children: [
              TextField(key: const Key('field'), focusNode: field),
              const Expanded(child: SizedBox.expand()),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('scope unfocus from a text field is repaired on Windows', (
    tester,
  ) async {
    var k = 0;
    final field = FocusNode();
    addTearDown(field.dispose);
    await tester.pumpWidget(page(onK: (n) => k = n, field: field));
    await tester.pump();
    expect(DesktopFocusRepair.registered, hasLength(1));
    final pageNode = DesktopFocusRepair.registered.single;
    expect(pageNode.hasPrimaryFocus, isTrue);

    // Type in the field, then leave it the way the SDK default does
    // (disposition: scope), which parks focus on the bare route scope.
    await tester.tap(find.byKey(const Key('field')));
    await tester.pump();
    expect(field.hasPrimaryFocus, isTrue);
    field.unfocus();
    await tester.pump();
    // The listener-free path: run() alone puts focus back on the page.
    expect(DesktopFocusRepair.focusIsLost(), isTrue);
    expect(DesktopFocusRepair.run(), same(pageNode));
    await tester.pump();
    expect(pageNode.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    expect(k, 1);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('schedule() repairs after the next frame', (tester) async {
    final field = FocusNode();
    addTearDown(field.dispose);
    await tester.pumpWidget(page(onK: (_) {}, field: field));
    await tester.pump();
    final pageNode = DesktopFocusRepair.registered.single;
    field.requestFocus();
    await tester.pump();
    field.unfocus();
    DesktopFocusRepair.schedule();
    await tester.pump();
    await tester.pump();
    expect(pageNode.hasPrimaryFocus, isTrue);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('dropFocus leaves a text field back to the page on Windows', (
    tester,
  ) async {
    final field = FocusNode();
    addTearDown(field.dispose);
    await tester.pumpWidget(page(onK: (_) {}, field: field));
    await tester.pump();
    final pageNode = DesktopFocusRepair.registered.single;
    await tester.tap(find.byKey(const Key('field')));
    await tester.pump();
    DesktopFocusRepair.dropFocus(tester.element(find.byType(TextField)));
    await tester.pump();
    await tester.pump();
    expect(pageNode.hasPrimaryFocus, isTrue);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  // Review fix: previouslyFocusedChild alone would move the caret into an
  // older text field (A) after leaving B; the page node must get it instead.
  testWidgets('leaving a field never jumps into an older field', (
    tester,
  ) async {
    final a = FocusNode(debugLabel: 'a');
    final b = FocusNode(debugLabel: 'b');
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopRepairFocus(
            autofocus: true,
            debugLabel: 'page',
            child: Column(
              children: [
                TextField(focusNode: a),
                TextField(focusNode: b),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final pageNode = DesktopFocusRepair.registered.single;
    a.requestFocus();
    await tester.pump();
    b.requestFocus();
    await tester.pump();
    DesktopFocusRepair.leaveTextField(b);
    await tester.pump();
    await tester.pump();
    expect(a.hasFocus, isFalse);
    expect(pageNode.hasPrimaryFocus, isTrue);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('never steals focus from a real widget or a covering route', (
    tester,
  ) async {
    final field = FocusNode();
    addTearDown(field.dispose);
    await tester.pumpWidget(page(onK: (_) {}, field: field));
    await tester.pump();
    final pageNode = DesktopFocusRepair.registered.single;

    // A focused text field is not "lost".
    field.requestFocus();
    await tester.pump();
    expect(DesktopFocusRepair.run(), isNull);
    expect(field.hasPrimaryFocus, isTrue);

    // A dialog route covers the page: its bare scope stays focused.
    final context = tester.element(find.byType(TextField));
    showDialog<void>(context: context, builder: (_) => const Text('dialog'));
    await tester.pumpAndSettle();
    expect(DesktopFocusRepair.run(), isNull);
    expect(pageNode.hasFocus, isFalse);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('hidden IndexedStack tab is skipped', (tester) async {
    final a = FocusNode(debugLabel: 'a');
    final b = FocusNode(debugLabel: 'b');
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    Widget stack(int index) => MaterialApp(
      home: IndexedStack(
        index: index,
        children: [
          DesktopRepairFocus(focusNode: a, child: const SizedBox()),
          DesktopRepairFocus(focusNode: b, child: const SizedBox()),
        ],
      ),
    );
    await tester.pumpWidget(stack(0));
    // b is newest but hidden, so a (shown) gets the keys.
    expect(DesktopFocusRepair.run(), same(a));
    await tester.pump();
    expect(a.hasPrimaryFocus, isTrue);
    // Switch tabs: a's focus is dropped by ExcludeFocus; repair picks b.
    await tester.pumpWidget(stack(1));
    await tester.pump();
    expect(DesktopFocusRepair.run(), same(b));
    await tester.pump();
    expect(b.hasPrimaryFocus, isTrue);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('does nothing off Windows', (tester) async {
    final field = FocusNode();
    addTearDown(field.dispose);
    await tester.pumpWidget(page(onK: (_) {}, field: field));
    await tester.pump();
    field.requestFocus();
    await tester.pump();
    field.unfocus();
    await tester.pump();
    expect(DesktopFocusRepair.run(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
