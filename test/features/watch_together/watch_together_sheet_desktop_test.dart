// Windows look of the Watch Together sheet: graphite dialog + graphite
// room-code prompt instead of the phone bottom sheet and AlertDialog.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/desktop_sheet.dart';
import 'package:watch_app/features/watch_together/ui/watch_together_sheet.dart';
import 'package:watch_app/features/watch_together/watch_room_service.dart';
import 'package:watch_app/features/watch_together/watch_together_controller.dart';
import 'package:watch_app/l10n/app_localizations.dart';

/// The sheet never talks to the room service in these tests, so any call
/// would be a bug; noSuchMethod makes it fail loudly.
class _NoService implements WatchRoomService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// Pumps a button that opens the sheet, so the sheet gets a real navigator.
Future<void> _pumpOpener(WidgetTester tester) async {
  final controller = WatchTogetherController(_NoService());
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showWatchTogetherSheet(
              context,
              buildInitialRoom: () => throw StateError('not used'),
              controller: controller,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Windows: sheet is a desktop dialog and the code prompt is '
      'graphite', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await _pumpOpener(tester);
      // Opened through showAdaptiveSheet's desktop branch.
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(DesktopSheetScope), findsWidgets);

      await tester.tap(find.byIcon(Icons.login));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        find.byKey(const ValueKey('desktop-text-prompt-field')),
        findsOneWidget,
      );
      // Esc cancels the prompt and leaves the sheet open.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('desktop-text-prompt-field')),
        findsNothing,
      );
      expect(find.byIcon(Icons.login), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('phone: bottom sheet and Material code dialog stay', (
    tester,
  ) async {
    await _pumpOpener(tester);
    expect(find.byType(BottomSheet), findsOneWidget);
    await tester.tap(find.byIcon(Icons.login));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
  });
}
