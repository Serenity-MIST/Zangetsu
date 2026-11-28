// Round 3 (profiles / account dialogs): the account text prompt (reset
// password email, edit name) and the three-button "Back up before logging
// out" dialog are graphite dialogs on Windows with keyboard behaviour.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/auth/auth_screens.dart';
import 'package:watch_app/features/auth/reconnect.dart';

void main() {
  _windowsTest('account prompt: prefilled, Enter returns trimmed text', (
    tester,
  ) async {
    late BuildContext ctx;
    await tester.pumpWidget(_host((c) => ctx = c));
    final result = showAccountTextPrompt(
      ctx,
      title: 'Reset password',
      message: 'Enter your account email.',
      initial: 'old@example.com',
      confirmLabel: 'Send link',
    );
    await tester.pumpAndSettle();
    // Graphite Dialog, not the phone AlertDialog.
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('old@example.com'), findsOneWidget);
    expect(find.text('Enter your account email.'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '  me@example.com ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(await result, 'me@example.com');
  });

  _windowsTest('account prompt: Esc cancels with null', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(_host((c) => ctx = c));
    final result = showAccountTextPrompt(
      ctx,
      title: 'Edit name',
      initial: 'Sam',
      confirmLabel: 'Save',
      maxLength: 40,
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(await result, isNull);
  });

  _windowsTest('account prompt: Save button returns the text', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(_host((c) => ctx = c));
    final result = showAccountTextPrompt(
      ctx,
      title: 'Edit name',
      confirmLabel: 'Save',
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Alex');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(await result, 'Alex');
  });

  _windowsTest('logout backup dialog: three buttons, each returns its id', (
    tester,
  ) async {
    late BuildContext ctx;
    await tester.pumpWidget(_host((c) => ctx = c));
    // One run per button: cancel / log out anyway / reconnect.
    for (final (index, expected) in [
      (0, 'cancel'),
      (1, 'anyway'),
      (2, 'reconnect'),
    ]) {
      final result = showBackupBeforeLogoutDesktop(ctx);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      final buttons = find.descendant(
        of: find.byType(Wrap),
        matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
      );
      expect(buttons, findsNWidgets(3));
      await tester.tap(buttons.at(index));
      await tester.pumpAndSettle();
      expect(await result, expected);
    }
  });

  _windowsTest('logout backup dialog: Enter reconnects, Esc dismisses', (
    tester,
  ) async {
    late BuildContext ctx;
    await tester.pumpWidget(_host((c) => ctx = c));
    // Reconnect (the safe choice) is focused, so Enter picks it.
    var result = showBackupBeforeLogoutDesktop(ctx);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(await result, 'reconnect');
    // Esc closes without a choice, which safeLogout treats as cancel.
    result = showBackupBeforeLogoutDesktop(ctx);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(await result, isNull);
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
