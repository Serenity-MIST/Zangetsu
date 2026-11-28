import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/chapter_download.dart';
import 'package:watch_app/core/download/download_record.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/features/downloads/desktop_download_library.dart';

DownloadRecord _video(String id, String show, String title) => DownloadRecord(
  id: id,
  sourceId: 'src',
  showId: show,
  showTitle: title,
  showUrl: '/s',
  episodeId: id,
  episodeUrl: '/e/$id',
  episodeTitle: 'Episode $id',
  category: 'sub',
  quality: 'best',
  status: DownloadStatus.done,
  bytesTotal: 1000,
  createdAt: 1,
);

ChapterDownload _chapter(String id, String title) => ChapterDownload(
  id: id,
  sourceId: 'src',
  showId: id,
  showTitle: title,
  chapterId: id,
  chapterUrl: '/c',
  chapterTitle: 'Chapter 1',
  mode: ContentMode.manga,
  status: ChapterDownloadStatus.done,
);

void main() {
  late List<DesktopDownloadCollection> shows;
  late List<DesktopDownloadCollection> opened;
  late List<List<DesktopDownloadCollection>> deleted;

  setUp(() {
    shows = desktopDownloadCollections(
      videos: [
        _video('a', 'show-a', 'Alpha'),
        _video('b', 'show-b', 'Bravo'),
        _video('c', 'show-c', 'Charlie'),
      ],
      chapters: [_chapter('m', 'Manga One')],
    );
    opened = [];
    deleted = [];
  });

  Future<void> pump(WidgetTester tester, {bool deletable = true}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopDownloadLibrary(
            collections: shows,
            onOpen: opened.add,
            onDeleteCollections: deletable
                ? (chosen) async => deleted.add(chosen)
                : null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder selectButton() => find.byKey(const ValueKey('downloads-select'));
  Finder countText() => find.byKey(const ValueKey('downloads-selected-count'));
  Finder deleteButton() => find.byKey(const ValueKey('downloads-select-delete'));
  Finder confirmDelete() => find.descendant(
    of: find.byType(Dialog),
    matching: find.text('Delete'),
  );

  testWidgets('has no selection mode when deleting is not offered', (tester) async {
    await pump(tester, deletable: false);
    expect(selectButton(), findsNothing);
  });

  testWidgets('a normal click still opens a show', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Alpha'));
    await tester.pump();
    expect(opened.single.title, 'Alpha');
  });

  testWidgets('Select turns on checkboxes and clicking chooses instead of opening', (
    tester,
  ) async {
    await pump(tester);
    expect(find.byType(Checkbox), findsNothing);
    await tester.tap(selectButton());
    await tester.pumpAndSettle();
    expect(find.byType(Checkbox), findsNWidgets(4));
    expect(find.textContaining('0 '), findsWidgets);

    await tester.tap(find.text('Alpha'));
    await tester.pump();
    await tester.tap(find.text('Bravo'));
    await tester.pump();
    expect(opened, isEmpty); // clicks chose, they did not open
    expect(tester.widget<Text>(countText()).data, startsWith('2 '));
    expect(tester.widget<IconButton>(deleteButton()).onPressed, isNotNull);

    // Clicking a chosen show again un-chooses it.
    await tester.tap(find.text('Bravo'));
    await tester.pump();
    expect(tester.widget<Text>(countText()).data, startsWith('1 '));
  });

  testWidgets('un-choosing the last show leaves selection mode', (tester) async {
    await pump(tester);
    await tester.tap(selectButton());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alpha'));
    await tester.pump();
    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    expect(find.byType(Checkbox), findsNothing);
    expect(selectButton(), findsOneWidget);
  });

  testWidgets('Select all chooses every show on screen', (tester) async {
    await pump(tester);
    await tester.tap(selectButton());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('downloads-select-all')));
    await tester.pump();
    expect(tester.widget<Text>(countText()).data, startsWith('4 '));
  });

  testWidgets('Select all respects the filter', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Manga'));
    await tester.pumpAndSettle();
    await tester.tap(selectButton());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('downloads-select-all')));
    await tester.pump();
    expect(tester.widget<Text>(countText()).data, startsWith('1 '));
  });

  testWidgets('Delete asks first, and Cancel removes nothing', (tester) async {
    await pump(tester);
    await tester.tap(selectButton());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alpha'));
    await tester.pump();
    await tester.tap(find.text('Charlie'));
    await tester.pump();
    await tester.tap(deleteButton());
    await tester.pumpAndSettle();

    expect(find.text('Delete 2 shows'), findsOneWidget);
    expect(find.textContaining('cannot be undone'), findsOneWidget);
    expect(find.textContaining('2 downloads'), findsOneWidget);

    await tester.tap(find.descendant(
      of: find.byType(Dialog),
      matching: find.text('Cancel'),
    ));
    await tester.pumpAndSettle();
    expect(deleted, isEmpty);
    // The choice is kept so the user can adjust it.
    expect(tester.widget<Text>(countText()).data, startsWith('2 '));
  });

  testWidgets('confirming deletes exactly the chosen shows, then clears', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(selectButton());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alpha'));
    await tester.pump();
    await tester.tap(find.text('Manga One'));
    await tester.pump();
    await tester.tap(deleteButton());
    await tester.pumpAndSettle();
    await tester.tap(confirmDelete());
    await tester.pumpAndSettle();

    expect(deleted, hasLength(1));
    expect(deleted.single.map((c) => c.title).toSet(), {'Alpha', 'Manga One'});
    expect(find.byType(Checkbox), findsNothing); // back to normal mode
  });

  testWidgets('Ctrl+click chooses a show without entering Select first', (
    tester,
  ) async {
    await pump(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.text('Bravo'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
    expect(find.byType(Checkbox), findsNWidgets(4));
    expect(tester.widget<Text>(countText()).data, startsWith('1 '));
  });

  testWidgets('Escape leaves selection mode', (tester) async {
    await pump(tester);
    await tester.tap(selectButton());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alpha'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(Checkbox), findsNothing);
  },
      // The shared selection keys (dl-3) are Windows-only.
      variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('Ctrl+A chooses everything and Delete asks to remove it', (
    tester,
  ) async {
    await pump(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(countText()).data, startsWith('4 '));

    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();
    expect(find.text('Delete 4 shows'), findsOneWidget);
    expect(deleted, isEmpty); // asked, but nothing removed yet
  },
      variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('selection mode does not overflow on a small window', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(520, 700);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopDownloadLibrary(
            collections: shows,
            onOpen: (_) {},
            onDeleteCollections: (_) async {},
          ),
        ),
      ),
    );
    await tester.tap(selectButton());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('downloads-select-all')));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
