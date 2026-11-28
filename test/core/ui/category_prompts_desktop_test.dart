// Round 3 (library categories): the text prompt used for new/rename
// category and new AniList list is a graphite dialog on Windows and the old
// AlertDialog on phone; a picker inside a desktop sheet drops its grabber.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/desktop_dialogs.dart';
import 'package:watch_app/core/desktop/desktop_sheet.dart';

void main() {
  _windowsTest('Windows prompt is graphite: Enter submits typed text', (
    tester,
  ) async {
    late BuildContext ctx;
    await tester.pumpWidget(_host((c) => ctx = c));
    final result = showAdaptiveTextPrompt(
      ctx,
      title: 'New category',
      hint: 'Persona, Gym, …',
      confirmLabel: 'Create',
    );
    await tester.pumpAndSettle();
    // Graphite field, not the phone AlertDialog.
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byKey(const ValueKey('desktop-text-prompt-field')), findsOne);
    await tester.enterText(find.byType(TextField), 'Gym');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(await result, 'Gym');
  });

  _windowsTest('Windows prompt: Esc cancels, rename is prefilled', (
    tester,
  ) async {
    late BuildContext ctx;
    await tester.pumpWidget(_host((c) => ctx = c));
    final result = showAdaptiveTextPrompt(
      ctx,
      title: 'Rename category',
      initialValue: 'Persona',
      confirmLabel: 'Rename',
    );
    await tester.pumpAndSettle();
    expect(find.text('Persona'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(await result, isNull);
  });

  _windowsTest('Windows prompt: Create button returns the text', (
    tester,
  ) async {
    late BuildContext ctx;
    await tester.pumpWidget(_host((c) => ctx = c));
    final result = showAdaptiveTextPrompt(
      ctx,
      title: 'New AniList list',
      confirmLabel: 'Create',
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Rewatching');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(await result, 'Rewatching');
  });

  testWidgets('phone keeps the AlertDialog prompt', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(_host((c) => ctx = c));
    final result = showAdaptiveTextPrompt(
      ctx,
      title: 'New category',
      confirmLabel: 'Create',
      cancelLabel: 'Cancel',
    );
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await result, isNull);
  });

  _windowsTest('Windows adaptive sheet hides the phone heading', (
    tester,
  ) async {
    late BuildContext ctx;
    await tester.pumpWidget(_host((c) => ctx = c));
    // Same pattern as the category / AniList list pickers.
    showAdaptiveSheet<void>(
      ctx,
      title: 'Categories',
      builder: (c) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!DesktopSheetScope.of(c)) const Text('phone heading'),
          const Text('row'),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('desktop-adaptive-sheet')), findsOne);
    expect(find.text('phone heading'), findsNothing);
    expect(find.text('Categories'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('row'), findsNothing);
  });
}

/// Minimal app that hands the test a context under a Navigator.
Widget _host(void Function(BuildContext) onContext) => MaterialApp(
  home: Scaffold(
    body: Builder(
      builder: (c) {
        onContext(c);
        return const SizedBox.expand();
      },
    ),
  ),
);

/// testWidgets with the platform set to Windows; reset inside the body
/// because the framework checks debug variables before tearDown.
void _windowsTest(String description, WidgetTesterCallback body) =>
    testWidgets(description, (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await body(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
