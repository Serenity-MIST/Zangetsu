import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/media_detail.dart';
import 'package:watch_app/core/ui/media_info_sheet.dart';

/// Pumps a button that opens the info card and records which action fired.
Future<List<String>> _open(WidgetTester tester, {bool removable = true}) async {
  final calls = <String>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showMediaInfoSheet(
              context,
              title: 'Frieren',
              detail: Future<MediaDetail?>.value(null),
              inMyList: false,
              onPlay: () => calls.add('play'),
              onOpenDetail: () => calls.add('detail'),
              onToggleMyList: () async {
                calls.add('list');
                return true;
              },
              onRemoveFromContinue: removable
                  ? () => calls.add('remove')
                  : null,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return calls;
}

void main() {
  group('Windows', () {
    windowsWidgets('opens as a centred dialog, not a bottom sheet', (
      tester,
    ) async {
      await _open(tester);

      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byKey(const ValueKey('media-info-close')), findsOneWidget);
      // Bounded and centred on the wide window.
      final rect = tester.getRect(
        find
            .descendant(
              of: find.byType(Dialog),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(rect.width, lessThanOrEqualTo(580));
      expect(rect.center.dx, closeTo(800, 1));
      // Same content and actions as the phone sheet.
      expect(find.text('Frieren'), findsOneWidget);
      expect(find.text('No description available.'), findsOneWidget);
      for (final label in ['Play', 'My List', 'Details', 'Remove']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
    });

    windowsWidgets('Esc closes it without firing an action', (tester) async {
      final calls = await _open(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(calls, isEmpty);
    });

    windowsWidgets('close button closes it', (tester) async {
      await _open(tester);
      await tester.tap(find.byKey(const ValueKey('media-info-close')));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
    });

    windowsWidgets('Play is focused, so Enter plays and closes', (
      tester,
    ) async {
      final calls = await _open(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(calls, ['play']);
      expect(find.byType(Dialog), findsNothing);
    });

    windowsWidgets('My List toggles in place; Details and Remove close', (
      tester,
    ) async {
      final calls = await _open(tester);
      await tester.tap(find.byKey(const ValueKey('media-info-my-list')));
      await tester.pumpAndSettle();
      expect(calls, ['list']);
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('media-info-details')));
      await tester.pumpAndSettle();
      expect(calls, ['list', 'detail']);
      expect(find.byType(Dialog), findsNothing);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('media-info-remove')));
      await tester.pumpAndSettle();
      expect(calls, ['list', 'detail', 'remove']);
    });

    windowsWidgets('a narrow window stacks Play above the other actions', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(480, 800);
      await _open(tester);
      expect(tester.takeException(), isNull);
      final play = tester.getRect(
        find.byKey(const ValueKey('media-info-play')),
      );
      final list = tester.getRect(
        find.byKey(const ValueKey('media-info-my-list')),
      );
      expect(play.bottom, lessThanOrEqualTo(list.top));
    });

    windowsWidgets('Remove is absent outside Continue Watching', (
      tester,
    ) async {
      await _open(tester, removable: false);
      expect(find.byKey(const ValueKey('media-info-remove')), findsNothing);
    });
  });

  testWidgets('phones keep the bottom sheet with its grab handle', (
    tester,
  ) async {
    await _open(tester);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    expect(find.byKey(const ValueKey('media-info-close')), findsNothing);
  });
}

/// Runs [body] as the Windows target, restoring the platform inside the body
/// (Flutter checks foundation debug variables before tearDown runs).
void windowsWidgets(String description, WidgetTesterCallback body) {
  testWidgets(description, (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    // A typical desktop window.
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    try {
      await body(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
