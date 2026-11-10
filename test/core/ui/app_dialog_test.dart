import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/ui/app_dialog.dart';
import 'package:watch_app/core/ui/desktop_settings_surface.dart';

void main() {
  setUp(() {
    sl.registerSingleton<AppMode>(const AppMode(isTv: false));
  });

  tearDown(sl.reset);

  for (final confirm in [false, true]) {
    testWidgets('desktop confirm returns $confirm through nested navigator', (
      tester,
    ) async {
      bool? result;
      await tester.pumpWidget(
        MaterialApp(
          home: DesktopSettingsScope(
            child: Navigator(
              onGenerateRoute: (_) => MaterialPageRoute<void>(
                builder: (context) => Scaffold(
                  body: TextButton(
                    child: const Text('open'),
                    onPressed: () async {
                      result = await AppDialog.confirm(
                        context,
                        title: 'Remove fixture',
                        message: 'Only a test fixture.',
                        confirmLabel: 'Remove',
                        destructive: true,
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(TvAlertDialog), findsNothing);
      expect(find.byType(AlertDialog), findsOneWidget);
      if (confirm) {
        await tester.tap(find.text('Remove'));
      } else {
        // The safe action must receive keyboard focus for destructive prompts.
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      }
      await tester.pumpAndSettle();
      expect(result, confirm);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('open'), findsOneWidget); // nested page was not popped
    });
  }

  testWidgets(
    'desktop alert scrolls long copy at large text in narrow windows',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: DesktopSettingsScope(
              child: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    child: const Text('open'),
                    onPressed: () => AppDialog.alert(
                      context,
                      title: 'A longer desktop notice',
                      message: List.filled(30, 'Long explanation.').join(' '),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  testWidgets('AppDialog.confirm returns true on the confirm action', (
    tester,
  ) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await AppDialog.confirm(
                  context,
                  title: 'Delete all',
                  message: 'This cannot be undone.',
                  confirmLabel: 'Delete',
                  destructive: true,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(TvAlertDialog), findsOneWidget);

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
    expect(find.byType(TvAlertDialog), findsNothing);
  });

  testWidgets('AppDialog.alert dismisses on OK', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => AppDialog.alert(
                context,
                title: 'Restore complete',
                message: 'Library restored',
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Restore complete'), findsOneWidget);

    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('Restore complete'), findsNothing);
  });
}
