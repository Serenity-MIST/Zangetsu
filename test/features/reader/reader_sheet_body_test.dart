import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/reader/desktop_page_scroller.dart';
import 'package:watch_app/features/reader/reader_auto_scroll_ui.dart';
import 'package:watch_app/features/reader/reader_chrome.dart';

/// Opens [body] the way the readers do (showReaderPanel) from a button.
Future<void> _open(WidgetTester tester, WidgetBuilder body) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                showReaderPanel<void>(context: context, builder: body),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Widget _textSize(BuildContext context) => readerSheetBody(
  context: context,
  title: 'Text size',
  subtitle: 'Applies straight away',
  children: const [SizedBox(height: 40)],
);

/// The phone grabber: a 36x4 pill with no other content.
final Finder _grabber = find.byWidgetPredicate(
  (w) =>
      w is Container &&
      w.constraints?.maxWidth == 36 &&
      w.constraints?.maxHeight == 4,
);

void main() {
  testWidgets('Windows side panel: no drag handle, close button closes it', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await _open(tester, _textSize);
      expect(find.byKey(const ValueKey('reader-desktop-panel')), findsOne);
      expect(_grabber, findsNothing);
      expect(find.byKey(const ValueKey('reader-sheet-close')), findsOne);
      await tester.tap(find.byKey(const ValueKey('reader-sheet-close')));
      await tester.pumpAndSettle();
      expect(find.text('Text size'), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Windows auto-scroll panel also gets the close button', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await _open(
        tester,
        (_) => ReaderAutoScrollSheet(
          desktop: true,
          running: false,
          speed: 3,
          showButton: true,
          onToggle: (_) {},
          onSpeed: (_) {},
          onShowButton: (_) {},
        ),
      );
      expect(_grabber, findsNothing);
      await tester.tap(find.byKey(const ValueKey('reader-sheet-close')));
      await tester.pumpAndSettle();
      expect(find.byType(ReaderAutoScrollSheet), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('phone bottom sheet keeps the grabber and no close button', (
    tester,
  ) async {
    await _open(tester, _textSize);
    expect(find.byType(BottomSheet), findsOne);
    expect(_grabber, findsOne);
    expect(find.byKey(const ValueKey('reader-sheet-close')), findsNothing);
  });
}
