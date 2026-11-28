// Detail page "Read more" / "… more" links: Windows hover + keyboard
// feedback, and the old plain tap area everywhere else.
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/detail/desktop_hover_link.dart';

void main() {
  // Pumps one link that shows "Read more" underlined while highlighted.
  Future<List<int>> pumpLink(WidgetTester tester) async {
    final taps = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: DesktopHoverLink(
              key: const ValueKey('link'),
              onTap: () => taps.add(1),
              builder: (context, highlighted) => Text(
                'Read more',
                style: TextStyle(
                  decoration: highlighted ? TextDecoration.underline : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return taps;
  }

  bool underlined(WidgetTester tester) =>
      tester.widget<Text>(find.text('Read more')).style?.decoration ==
      TextDecoration.underline;

  testWidgets('Windows: hand cursor and underline on hover, Enter activates', (
    tester,
  ) async {
    final taps = await pumpLink(tester);
    expect(underlined(tester), isFalse);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('Read more')));
    await tester.pumpAndSettle();
    expect(underlined(tester), isTrue);
    expect(
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.click,
    );

    // Leaving clears the highlight.
    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(underlined(tester), isFalse);

    // Click still works.
    await tester.tap(find.text('Read more'));
    expect(taps, hasLength(1));

    // Keyboard: Tab focuses it (highlighted), Enter activates it.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(underlined(tester), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(taps, hasLength(2));
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('Android: plain tap area, never highlighted or focusable', (
    tester,
  ) async {
    final taps = await pumpLink(tester);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('link')),
        matching: find.byType(FocusableActionDetector),
      ),
      findsNothing,
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('Read more')));
    await tester.pumpAndSettle();
    expect(underlined(tester), isFalse);
    await tester.tap(find.text('Read more'));
    expect(taps, hasLength(1));
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
