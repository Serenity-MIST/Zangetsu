// Windows Downloads library additions: shared selection (dl-1, dl-3),
// right-click menus (dl-4), Continue target (dl-8), sorting and the storage
// line (dl-9), readable attempt labels (dl-12) and the grouping cache (dl-7).
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/chapter_download.dart';
import 'package:watch_app/core/download/download_record.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/playback/resume_store.dart';
import 'package:watch_app/features/downloads/desktop_download_library.dart';
import 'package:watch_app/features/downloads/desktop_download_selection.dart';
import 'package:watch_app/features/downloads/downloads_screen.dart'
    show downloadedContinueTarget;

/// A saved (or other status) episode; [created] fixes the "recent" order.
DownloadRecord _video(String id, {String show = 'show', String title = 'Show',
    int created = 1, int bytes = 1000, DownloadStatus status = DownloadStatus.done,
    double? episode, String? path, double progress = 0, String category = 'sub'}) =>
  DownloadRecord(id: id, sourceId: 'src', showId: show, showTitle: title,
    showUrl: '/$show', episodeId: id, episodeUrl: '/e/$id',
    episodeTitle: 'Episode $id', category: category, quality: 'best',
    status: status, bytesTotal: bytes, createdAt: created,
    episodeNumber: episode, filePath: path, progress: progress);

ChapterDownload _chapter(String id, String title) => ChapterDownload(
  id: id, sourceId: 'src', showId: id, showTitle: title, chapterId: id,
  chapterUrl: '/c', chapterTitle: 'Chapter 1', mode: ContentMode.manga,
  status: ChapterDownloadStatus.done);

void main() {
  group('sorting and storage (dl-9)', () {
    final shows = desktopDownloadCollections(videos: [
      _video('a', show: 'a', title: 'Bravo', created: 3, bytes: 100),
      _video('b', show: 'b', title: 'alpha', created: 2, bytes: 900),
      _video('c', show: 'c', title: 'Charlie', created: 1, bytes: 500),
    ], chapters: const []);

    List<String> titles(List<DesktopDownloadCollection> list) =>
        [for (final c in list) c.title];

    test('recent, title (case-insensitive) and size orders', () {
      expect(titles(sortDesktopDownloadCollections(shows, DesktopDownloadSort.recent)),
        ['Bravo', 'alpha', 'Charlie']);
      expect(titles(sortDesktopDownloadCollections(shows, DesktopDownloadSort.title)),
        ['alpha', 'Bravo', 'Charlie']);
      expect(titles(sortDesktopDownloadCollections(shows, DesktopDownloadSort.size)),
        ['alpha', 'Charlie', 'Bravo']);
    });

    test('most unwatched first, ties fall back to recent', () {
      final counts = {'Bravo': 0, 'alpha': 2, 'Charlie': 2};
      expect(titles(sortDesktopDownloadCollections(shows,
          DesktopDownloadSort.unwatched, unwatched: (c) => counts[c.title]!)),
        ['alpha', 'Charlie', 'Bravo']);
    });

    test('storage line names used, free and the drive', () {
      expect(describeDownloadStorage(usedBytes: 84 * 1024 * 1024 * 1024,
          freeBytes: 120 * 1024 * 1024 * 1024, drive: 'D:'),
        '84.0 GB used - 120.0 GB free on D:');
      expect(describeDownloadStorage(usedBytes: 2 * 1024 * 1024), '2 MB used');
    });

    test('collection size counts finished videos and chapters only', () {
      final c = desktopDownloadCollections(videos: [
        _video('x', bytes: 300),
        _video('y', bytes: 700, status: DownloadStatus.downloading),
      ], chapters: const []).single;
      expect(c.bytes, 300);
    });
  });

  group('folders and labels (dl-4, dl-12)', () {
    test('show folder is the deepest folder shared by its files', () {
      expect(desktopDownloadFolder([r'D:\Videos\Show\Season 1\e1.mp4',
          r'D:\Videos\Show\Season 1\e2.mp4']), r'D:\Videos\Show\Season 1');
      expect(desktopDownloadFolder([r'D:\Videos\Show\Season 1\e1.mp4',
          r'd:\videos\show\Season 2\e1.mp4']), r'D:\Videos\Show');
      expect(desktopDownloadFolder(['content://media/1']), isNull);
      expect(desktopDownloadFolder(const []), isNull);
    });

    test('audio category reads Subbed / Dubbed', () {
      expect(downloadCategoryLabel('sub'), 'Subbed');
      expect(downloadCategoryLabel('DUB'), 'Dubbed');
      expect(downloadCategoryLabel('raw'), 'raw');
    });

    test('recovered files have no show page', () {
      final recovered = DownloadRecord.fromMap(
          {..._video('r').toMap(), 'recoveredFromDisk': true});
      final c = desktopDownloadCollections(videos: [recovered], chapters: const []).single;
      expect(c.showUrl, isNull);
      final real = desktopDownloadCollections(videos: [_video('s')], chapters: const []).single;
      expect(real.showUrl, '/show');
    });
  });

  group('grouping cache (dl-7)', () {
    test('progress ticks reuse the grouping, a status change regroups', () {
      final cache = DesktopDownloadCollectionsCache();
      final first = cache.collections(videos: [
        _video('a', status: DownloadStatus.downloading, progress: .1),
      ], chapters: [_chapter('m', 'Manga')]);
      final tick = cache.collections(videos: [
        _video('a', status: DownloadStatus.downloading, progress: .6),
      ], chapters: [_chapter('m', 'Manga')]);
      expect(identical(first, tick), isTrue);
      final finished = cache.collections(videos: [
        _video('a', status: DownloadStatus.done, progress: 1),
      ], chapters: [_chapter('m', 'Manga')]);
      expect(identical(first, finished), isFalse);
    });
  });

  group('Continue target (dl-8)', () {
    ResumeMark mark({bool finished = false, int seconds = 0}) => ResumeMark(
      position: Duration(seconds: seconds),
      duration: const Duration(minutes: 24),
      markedWatched: finished,
    );

    test('first unfinished episode after watched ones, marked as started', () {
      final records = [_video('2', episode: 2), _video('1', episode: 1),
        _video('3', episode: 3)];
      final marks = {'1': mark(finished: true)};
      final target = downloadedContinueTarget(records, (r) => marks[r.id]);
      expect(target?.record.id, '2');
      expect(target?.started, isTrue);
    });

    test('nothing watched yet starts at the first episode, not started', () {
      final target = downloadedContinueTarget(
          [_video('2', episode: 2), _video('1', episode: 1)], (_) => null);
      expect(target?.record.id, '1');
      expect(target?.started, isFalse);
    });

    test('everything watched or nothing saved gives no target', () {
      expect(downloadedContinueTarget([_video('1', episode: 1)],
          (_) => mark(finished: true)), isNull);
      expect(downloadedContinueTarget(
          [_video('1', episode: 1, status: DownloadStatus.failed)], (_) => null),
        isNull);
    });
  });

  group('library grid on Windows', () {
    late List<DesktopDownloadCollection> shows;
    late List<String> opened;
    late List<String> revealed;
    late List<String> showPages;

    setUp(() {
      shows = desktopDownloadCollections(videos: [
        _video('a', show: 'a', title: 'Alpha', created: 4,
          path: r'D:\Videos\Alpha\e1.mp4'),
        _video('b', show: 'b', title: 'Bravo', created: 3),
        _video('c', show: 'c', title: 'Charlie', created: 2),
        _video('d', show: 'd', title: 'Delta', created: 1),
      ], chapters: const []);
      opened = [];
      revealed = [];
      showPages = [];
    });

    Future<void> pump(WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1400, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(home: Scaffold(
        body: DesktopDownloadLibrary(
          collections: shows,
          onOpen: (c) => opened.add(c.title),
          onDeleteCollections: (_) async {},
          onRevealCollection: (c) => revealed.add(c.folder ?? ''),
          onOpenShowPage: (c) => showPages.add(c.title),
          unwatchedCount: (_) => 0,
          freeBytes: 5 * 1024 * 1024 * 1024,
          freeDrive: 'D:',
        ))));
      await tester.pumpAndSettle();
    }

    String count(WidgetTester tester) => tester.widget<Text>(
        find.byKey(const ValueKey('downloads-selected-count'))).data!;

    testWidgets('Shift-click selects the range from the Ctrl-clicked show', (tester) async {
      await pump(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(find.text('Alpha'));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tap(find.text('Charlie'));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(count(tester), startsWith('3 '));
      expect(opened, isEmpty);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('storage line and sort dropdown', (tester) async {
      await pump(tester);
      expect(find.text('4 KB used - 5.0 GB free on D:'), findsOneWidget);
      expect(find.text('Sort by: Recent'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('downloads-sort')));
      await tester.pumpAndSettle();
      expect(find.text('Most unwatched'), findsOneWidget);
      await tester.tap(find.text('Title'));
      await tester.pumpAndSettle();
      expect(find.text('Sort by: Title'), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('right-click menu: Show in Explorer and Open show page', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Alpha'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('Open'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
      await tester.tap(find.text('Show in Explorer'));
      await tester.pumpAndSettle();
      expect(revealed, [r'D:\Videos\Alpha']);

      await tester.tap(find.text('Bravo'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open show page'));
      await tester.pumpAndSettle();
      expect(showPages, ['Bravo']);
      expect(opened, isEmpty);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('right-click Delete asks first', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Delta'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Delete download?'), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  });

  group('episode list selection (dl-1, dl-3)', () {
    late List<String> played;

    Future<void> pump(WidgetTester tester, List<DownloadRecord> records) async {
      played = [];
      await tester.pumpWidget(MaterialApp(home: Scaffold(
        body: DesktopDownloadSelection(
          records: records,
          onDelete: (_) async {},
          // Same contract as DownloadTile: ask the scope first, then play.
          rowBuilder: (r) => Builder(builder: (context) {
            final scope = DesktopDownloadRowScope.maybeOf(context)!;
            return ListTile(
              selected: scope.selected,
              title: Text('row ${r.id}'),
              onTap: () {
                if (scope.onClick()) return;
                played.add(r.id);
              },
            );
          }),
        ))));
      await tester.pumpAndSettle();
    }

    final records = [_video('1', episode: 1), _video('2', episode: 2),
      _video('3', episode: 3), _video('4', episode: 4)];

    testWidgets('a row click plays normally but ticks while selecting', (tester) async {
      await pump(tester, records);
      await tester.tap(find.text('row 1'));
      expect(played, ['1']);
      await tester.tap(find.text('Select episodes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('row 2'));
      await tester.pumpAndSettle();
      expect(played, ['1']);
      expect(find.text('1 selected'), findsOneWidget);
    });

    testWidgets('Shift-click range, Ctrl+A and Esc', (tester) async {
      await pump(tester, records);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(find.text('row 1'));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tap(find.text('row 3'));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(find.text('3 selected'), findsOneWidget);
      expect(played, isEmpty);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.text('4 selected'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(Checkbox), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('Delete key asks to remove the selection', (tester) async {
      await pump(tester, records);
      await tester.tap(find.text('Select episodes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('row 4'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  });
}
