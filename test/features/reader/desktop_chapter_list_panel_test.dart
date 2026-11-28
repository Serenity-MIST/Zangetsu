import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/features/reader/desktop_chapter_list_panel.dart';

/// Bounded pumping: the focused filter box blinks its caret forever, so
/// pumpAndSettle would never return.
Future<void> settleUi(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

/// The Windows chapter panel of the manga reader (reader-10).
void main() {
  /// Ten chapters numbered 1..10, titled 'Title n'.
  final chapters = [
    for (var i = 1; i <= 10; i++)
      Episode(id: 'c$i', title: 'Title $i', url: 'u$i', number: i.toDouble()),
  ];

  /// Opens the panel in a route so it can pop itself, with fakes for every
  /// callback. [opened] collects the opened chapter indices.
  Future<void> open(
    WidgetTester tester, {
    required List<int> opened,
    Set<int> read = const {},
    Set<int> downloaded = const {},
    List<int>? markedUpTo,
    List<int>? downloads,
    int current = 4,
  }) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => Center(
                    child: SizedBox(
                      width: 460,
                      child: Material(
                        type: MaterialType.transparency,
                        child: DesktopChapterListPanel(
                          title: 'Chapters',
                          chapters: chapters,
                          currentIndex: current,
                          isRead: read.contains,
                          isDownloaded: downloaded.contains,
                          onOpen: opened.add,
                          onMarkReadUpTo: markedUpTo == null
                              ? null
                              : (i) async => markedUpTo.add(i),
                          onDownload: downloads == null
                              ? null
                              : (i) async => downloads.add(i),
                        ),
                      ),
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await settleUi(tester);
  }

  testWidgets('starts on the current chapter; arrows move and Enter opens', (
    tester,
  ) async {
    final opened = <int>[];
    await open(tester, opened: opened, current: 4);

    // Focus is in the filter box from the start.
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('reader-chapter-search')),
    );
    expect(field.focusNode!.hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settleUi(tester);

    // From index 4: down, down, up -> 5.
    expect(opened, [5]);
    expect(find.byType(DesktopChapterListPanel), findsNothing);
  });

  testWidgets('filters by chapter number or title', (tester) async {
    final opened = <int>[];
    await open(tester, opened: opened);

    await tester.enterText(
      find.byKey(const ValueKey('reader-chapter-search')),
      '10',
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('reader-chapter-row-9')), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-chapter-row-0')), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('reader-chapter-search')),
      'title 3',
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('reader-chapter-row-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-chapter-row-3')), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('reader-chapter-search')),
      'nothing like this',
    );
    await tester.pump();
    expect(find.text('No chapters match'), findsOneWidget);
  });

  testWidgets('marks read and downloaded chapters', (tester) async {
    await open(tester, opened: [], read: {0, 1}, downloaded: {2}, current: 4);
    expect(find.byKey(const ValueKey('reader-chapter-read-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-chapter-read-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-chapter-read-2')), findsNothing);
    expect(
      find.byKey(const ValueKey('reader-chapter-downloaded-2')),
      findsOneWidget,
    );
  });

  testWidgets('right-click offers Mark read up to here and Download', (
    tester,
  ) async {
    final marked = <int>[];
    final downloads = <int>[];
    await open(
      tester,
      opened: [],
      markedUpTo: marked,
      downloads: downloads,
      downloaded: {6},
    );

    Future<void> rightClick(int row) async {
      await tester.tapAt(
        tester.getCenter(find.byKey(ValueKey('reader-chapter-row-$row'))),
        buttons: kSecondaryMouseButton,
        kind: PointerDeviceKind.mouse,
      );
      await settleUi(tester);
    }

    await rightClick(3);
    await tester.tap(find.text('Mark read up to here'));
    await settleUi(tester);
    expect(marked, [3]);

    await rightClick(5);
    await tester.tap(find.text('Download'));
    await settleUi(tester);
    expect(downloads, [5]);

    // An already downloaded chapter shows a disabled 'Downloaded' row.
    await rightClick(6);
    expect(find.text('Downloaded'), findsWidgets);
    expect(find.text('Download'), findsNothing);
  });
}
