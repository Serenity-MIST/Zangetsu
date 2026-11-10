import 'dart:ui' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/settings/desktop_source_priority_row.dart';

/// Desktop ordering controls must remain reachable with pointer or keyboard.
void main() {
  Finder button(String tooltip) => find.byWidgetPredicate(
    (widget) => widget is IconButton && widget.tooltip == tooltip,
  );

  testWidgets(
    'boundary buttons disable correctly and keyboard activates once',
    (tester) async {
      var moves = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DesktopSourcePriorityRow(
              index: 0,
              count: 2,
              name: 'Source',
              tried: true,
              onMoveUp: () => moves -= 100,
              onMoveDown: () => moves++,
            ),
          ),
        ),
      );
      expect(
        tester.widget<IconButton>(button('Move Source up')).onPressed,
        isNull,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(moves, 1);
      await tester.tap(button('Move Source down'));
      await tester.pumpAndSettle();
      expect(moves, 2);
    },
  );

  testWidgets('long source metadata wraps in a narrow window at large text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var moves = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: SingleChildScrollView(
              child: DesktopSourcePriorityRow(
                index: 1,
                count: 2,
                name: 'A long provider name from another ecosystem',
                repo:
                    'A long repository name so the exact provider can be identified',
                reason: 'This source has not worked recently',
                tried: false,
                health: (
                  label: 'An extended health explanation',
                  color: Colors.red,
                ),
                onMoveUp: () => moves++,
                onMoveDown: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final up = button('Move A long provider name from another ecosystem up');
    await tester.ensureVisible(up);
    await tester.tap(up);
    expect(moves, 1);
    expect(
      tester
          .widget<IconButton>(
            button('Move A long provider name from another ecosystem down'),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('drag handle begins reordering without holding the mouse', (
    tester,
  ) async {
    final moves = <(int, int)>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReorderableListView(
            buildDefaultDragHandles: false,
            onReorderItem: (oldIndex, newIndex) =>
                moves.add((oldIndex, newIndex)),
            children: [
              for (var i = 0; i < 3; i++)
                DesktopSourcePriorityRow(
                  key: ValueKey(i),
                  index: i,
                  count: 3,
                  name: 'Source $i',
                  tried: true,
                  onMoveUp: () {},
                  onMoveDown: () {},
                ),
            ],
          ),
        ),
      ),
    );
    final handle = find.byType(ReorderableDragStartListener).first;
    final gesture = await tester.startGesture(
      tester.getCenter(handle),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, 170));
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(moves, isNotEmpty);
    expect(moves.single.$1, 0);
    expect(moves.single.$2, greaterThan(0));
  });
}
