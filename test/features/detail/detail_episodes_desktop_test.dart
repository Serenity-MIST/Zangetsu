// Windows Episodes-tab pieces (show-1, show-2, show-6, show-7, show-10):
// the filter box, selection toolbar, hover checkbox, the finished-download
// menu, the desktop range picker, the remembered list/grid choice and the
// "no episodes/chapters from this source" empty state (R3).
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/desktop_reveal.dart';
import 'package:watch_app/core/download/download_manager.dart';
import 'package:watch_app/core/download/download_record.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/playback/resume_store.dart';
import 'package:watch_app/core/ui/detail_prefs.dart';
import 'package:watch_app/features/detail/chapter_download_range_sheet.dart';
import 'package:watch_app/features/detail/detail_episodes_desktop.dart';
import 'package:watch_app/features/detail/detail_screen.dart'
    show SourceEmptyState, episodeShowsWatched;
import 'package:watch_app/features/downloads/episode_download_icon.dart';
import 'package:watch_app/l10n/app_localizations.dart';

/// Runs [body] with the UI pretending to be Windows, resetting afterwards.
void _windowsTest(String name, WidgetTesterCallback body) {
  testWidgets(name, (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await body(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

/// Minimal app shell with localisations.
Widget _app(Widget child) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

/// Bare download manager: the finished menu only calls delete() on it.
class _FakeManager extends Fake implements DownloadManager {
  final deleted = <DownloadRecord>[];

  @override
  Future<void> delete(DownloadRecord rec) async => deleted.add(rec);
}

void main() {
  group('show-10 remembered view', () {
    test('grid choice is kept in memory even without storage', () async {
      expect(DetailPrefs.episodeGridView, isFalse);
      await DetailPrefs.setEpisodeGridView(true);
      expect(DetailPrefs.episodeGridView, isTrue);
      await DetailPrefs.setEpisodeGridView(false);
      expect(DetailPrefs.episodeGridView, isFalse);
    });

    test('newest-first choice becomes the app-wide default', () async {
      final before = DetailPrefs.reverseEpisodesDefault;
      addTearDown(() => DetailPrefs.reverseEpisodesDefault = before);
      await DetailPrefs.rememberReverseEpisodes(true);
      expect(DetailPrefs.reverseEpisodesDefault, isTrue);
    });
  });

  group('show-7 filter box', () {
    _windowsTest('Esc clears the text first, then closes the box', (
      tester,
    ) async {
      final ctrl = TextEditingController();
      final focus = FocusNode();
      addTearDown(ctrl.dispose);
      addTearDown(focus.dispose);
      final changes = <String>[];
      var closed = 0;
      await tester.pumpWidget(
        _app(
          Center(
            child: EpisodeFilterField(
              controller: ctrl,
              focusNode: focus,
              onChanged: changes.add,
              onClose: () => closed++,
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(EpisodeFilterField.fieldKey));
      await tester.enterText(find.byKey(EpisodeFilterField.fieldKey), '12');
      await tester.pump();
      expect(changes.last, '12');
      // The clear button appears once there is text.
      expect(find.byTooltip('Clear filter'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(ctrl.text, isEmpty);
      expect(closed, 0);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(closed, 1);
    });

    // Users found "Filter episodes" odd: the box now says "Search".
    _windowsTest('placeholder reads Search episodes by default', (
      tester,
    ) async {
      final ctrl = TextEditingController();
      final focus = FocusNode();
      addTearDown(ctrl.dispose);
      addTearDown(focus.dispose);
      await tester.pumpWidget(
        _app(
          Center(
            child: EpisodeFilterField(
              controller: ctrl,
              focusNode: focus,
              onChanged: (_) {},
              onClose: () {},
            ),
          ),
        ),
      );
      expect(find.text('Search episodes'), findsOneWidget);
      expect(find.text('Filter episodes'), findsNothing);
    });
  });

  group('Select button beside the search box', () {
    _windowsTest('starts selecting and names the shortcut', (tester) async {
      var started = 0;
      await tester.pumpWidget(
        _app(Center(child: EpisodeSelectButton(onPressed: () => started++))),
      );
      expect(find.text('Select'), findsOneWidget);
      expect(find.byTooltip('Select episodes (Ctrl+Click)'), findsOneWidget);
      await tester.tap(find.byKey(EpisodeSelectButton.buttonKey));
      expect(started, 1);
    });
  });

  group('show-6 selection', () {
    testWidgets('toolbar shows the count and runs each action', (
      tester,
    ) async {
      // Wide enough that every action is on screen at once.
      tester.view.physicalSize = const Size(1400, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final calls = <String>[];
      await tester.pumpWidget(
        _app(
          EpisodeSelectionBar(
            count: 3,
            onMarkWatched: () => calls.add('watched'),
            onMarkUnwatched: () => calls.add('unwatched'),
            onSelectAll: () => calls.add('all'),
            onClear: () => calls.add('clear'),
            onDownload: () => calls.add('download'),
          ),
        ),
      );
      expect(find.text('3 selected'), findsOneWidget);
      await tester.tap(find.text('Mark watched'));
      await tester.tap(find.text('Mark unwatched'));
      await tester.tap(find.text('Download'));
      await tester.tap(find.text('Select all'));
      await tester.tap(find.byTooltip('Clear selection (Esc)'));
      expect(calls, ['watched', 'unwatched', 'download', 'all', 'clear']);
    });

    testWidgets('reading wording, and no Download without a handler', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          EpisodeSelectionBar(
            count: 1,
            isReading: true,
            onMarkWatched: () {},
            onMarkUnwatched: () {},
            onSelectAll: () {},
            onClear: () {},
          ),
        ),
      );
      expect(find.text('Mark read'), findsOneWidget);
      expect(find.text('Mark unread'), findsOneWidget);
      expect(find.text('Download'), findsNothing);
    });

    // Downloaded show page: the selection deletes files, never downloads.
    testWidgets('Delete replaces Download on the downloaded show page', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1400, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var deleted = 0;
      await tester.pumpWidget(
        _app(
          EpisodeSelectionBar(
            count: 2,
            onMarkWatched: () {},
            onMarkUnwatched: () {},
            onSelectAll: () {},
            onClear: () {},
            onDelete: () => deleted++,
          ),
        ),
      );
      expect(find.text('Download'), findsNothing);
      await tester.tap(find.text('Delete'));
      expect(deleted, 1);
    });

    _windowsTest('hover shows the checkbox and a click toggles', (
      tester,
    ) async {
      final selection = DesktopSelection<String>();
      addTearDown(selection.dispose);
      await tester.pumpWidget(
        _app(
          ListenableBuilder(
            listenable: selection,
            builder: (context, _) => Center(
              child: EpisodeSelectableTile(
                selected: selection.isSelected('e1'),
                selectionActive: selection.isActive,
                onCheckbox: () => selection.toggle('e1'),
                child: const SizedBox(width: 200, height: 80),
              ),
            ),
          ),
        ),
      );
      double opacity() => tester
          .widget<AnimatedOpacity>(
            find.descendant(
              of: find.byType(DesktopSelectionCheckbox),
              matching: find.byType(AnimatedOpacity),
            ),
          )
          .opacity;
      expect(opacity(), 0);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.byType(EpisodeSelectableTile)));
      await tester.pumpAndSettle();
      expect(opacity(), 1);

      await tester.tap(find.byType(DesktopSelectionCheckbox));
      await tester.pumpAndSettle();
      expect(selection.selected, {'e1'});
    });

    test('Shift-click selects the run between two episodes', () {
      final selection = DesktopSelection<String>();
      final ordered = ['e1', 'e2', 'e3', 'e4'];
      expect(selection.handleClick('e1', ordered, ctrl: true), isTrue);
      expect(selection.handleClick('e3', ordered, shift: true), isTrue);
      expect(selection.selected, {'e1', 'e2', 'e3'});
      // While selecting, a plain click toggles instead of opening.
      expect(selection.handleClick('e4', ordered, ctrl: false), isTrue);
      expect(selection.selected, {'e1', 'e2', 'e3', 'e4'});
      selection.dispose();
    });
  });

  group('show-1 finished download menu', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('show1_menu'));
    tearDown(() {
      debugRevealOverride = null;
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    _windowsTest('offers the four file actions; Show in folder reveals', (
      tester,
    ) async {
      final file = File('${dir.path}${Platform.pathSeparator}ep1.mp4')
        ..writeAsStringSync('x');
      final revealed = <String>[];
      debugRevealOverride = (path, {required select}) async =>
          revealed.add(path);
      final rec = DownloadRecord(
        id: 'r1',
        sourceId: 'src',
        showId: 'show',
        showTitle: 'Show',
        showUrl: '/show',
        episodeId: 'e1',
        episodeTitle: 'Episode 1',
        episodeUrl: '/e1',
        category: 'sub',
        quality: 'best',
        status: DownloadStatus.done,
        filePath: file.path,
        createdAt: 0,
      );
      var again = 0;
      await tester.pumpWidget(
        _app(
          Center(
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () => EpisodeDownloadIcon.showFinishedMenu(
                  context,
                  _FakeManager(),
                  rec,
                  onDownloadAgain: () => again++,
                ),
                child: const Text('tick'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('tick'));
      await tester.pumpAndSettle();
      for (final label in [
        'Play offline',
        'Show in folder',
        'Delete download',
        'Download again',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      await tester.tap(find.text('Show in folder'));
      await tester.pumpAndSettle();
      // The reveal checks the real file on disk, which needs real time.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();
      expect(revealed.single, endsWith('ep1.mp4'));

      await tester.tap(find.text('tick'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Download again'));
      await tester.pumpAndSettle();
      expect(again, 1);
    });

    // Reviewer: the follow-up toasts must find an overlay (they used the
    // navigator's own context, which sits above it), and Delete must confirm
    // before it calls the manager.
    _windowsTest('missing file toasts; delete confirms then deletes', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      debugRevealOverride = (path, {required select}) async {};
      final rec = DownloadRecord(
        id: 'r2',
        sourceId: 'src',
        showId: 'show',
        showTitle: 'Show',
        showUrl: '/show',
        episodeId: 'e2',
        episodeTitle: 'Episode 2',
        episodeUrl: '/e2',
        category: 'sub',
        quality: 'best',
        status: DownloadStatus.done,
        // No such file: Show in folder must say so.
        filePath: '${dir.path}${Platform.pathSeparator}gone.mp4',
        createdAt: 0,
      );
      final manager = _FakeManager();
      await tester.pumpWidget(
        _app(
          Center(
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () => EpisodeDownloadIcon.showFinishedMenu(
                  context,
                  manager,
                  rec,
                  onDownloadAgain: () {},
                ),
                child: const Text('tick'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('tick'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show in folder'));
      await tester.pumpAndSettle();
      // The file and folder checks are real disk I/O, one after the other,
      // so give each its own slice of real time.
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
      }
      // The toast fades in over a few frames.
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
      expect(find.text("Couldn't find the downloaded file"), findsOneWidget);
      // Toasts queue one at a time: let this one finish first.
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();

      await tester.tap(find.text('tick'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete download'));
      await tester.pumpAndSettle();
      // Nothing is deleted until the confirm is accepted.
      expect(manager.deleted, isEmpty);
      await tester.tap(find.text('Delete').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
      expect(manager.deleted, [rec]);
      expect(find.text('Download deleted'), findsOneWidget);
      // Let the toasts time out so no timers are left pending.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });
  });

  group('show-2 range picker', () {
    _windowsTest('endpoint picker is the searchable desktop choice dialog', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final chapters = List.generate(
        30,
        (i) => Episode(
          id: 'c${i + 1}',
          title: 'Chapter ${i + 1}',
          number: (i + 1).toDouble(),
          url: '/c${i + 1}',
        ),
      );
      await tester.pumpWidget(
        _app(
          ChapterDownloadRangeSheet(
            chapters: chapters,
            initialFromIndex: 4,
            initialToIndex: 9,
            unavailableUrls: const {},
          ),
        ),
      );
      await tester.tap(find.text('End'));
      await tester.pumpAndSettle();
      // No phone bottom sheet; the graphite dialog has its search box.
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(Dialog), findsOneWidget);
      // Rows before the start (chapter 5) can't end the range.
      expect(find.textContaining('Chapter 4'), findsNothing);
      await tester.enterText(find.byType(TextField).last, '12');
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Chapter 12').last);
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(find.textContaining('Chapter 12'), findsOneWidget);
    });
  });

  // R3: empty source. Reading titles say "chapters"; Windows swaps the red
  // FilledButton for the hero-style graphite chip; phone keeps the button.
  group('R3 empty source state', () {
    _windowsTest('Windows reading title: chapters wording + desktop chip', (
      tester,
    ) async {
      var switched = 0;
      await tester.pumpWidget(
        _app(SourceEmptyState(isReading: true, onSwitchSource: () => switched++)),
      );
      expect(find.text('No chapters available from this source'), findsOneWidget);
      expect(find.text('No episodes available from this source'), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
      final chip = find.byKey(const ValueKey('desktop-empty-switch-source'));
      expect(chip, findsOneWidget);
      expect(find.descendant(of: chip, matching: find.text('Switch source')),
          findsOneWidget);
      await tester.tap(chip);
      await tester.pump();
      expect(switched, 1);
    });

    _windowsTest('Windows anime title keeps episodes wording', (tester) async {
      await tester.pumpWidget(
        _app(SourceEmptyState(isReading: false, onSwitchSource: () {})),
      );
      expect(find.text('No episodes available from this source'), findsOneWidget);
      expect(find.byKey(const ValueKey('desktop-empty-switch-source')),
          findsOneWidget);
    });

    _windowsTest('Windows without another source shows no chip', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(const SourceEmptyState(isReading: true, onSwitchSource: null)),
      );
      expect(find.byKey(const ValueKey('desktop-empty-switch-source')),
          findsNothing);
    });

    testWidgets('phone keeps the shared FilledButton, with chapters wording', (
      tester,
    ) async {
      var switched = 0;
      await tester.pumpWidget(
        _app(SourceEmptyState(isReading: true, onSwitchSource: () => switched++)),
      );
      expect(find.text('No chapters available from this source'), findsOneWidget);
      expect(find.byKey(const ValueKey('desktop-empty-switch-source')),
          findsNothing);
      final button = find.widgetWithText(FilledButton, 'Switch source');
      expect(button, findsOneWidget);
      await tester.tap(button);
      expect(switched, 1);
    });
  });

  // "Mark as unwatched" kept the tick: the row OR'd in tracker progress,
  // which an unmark can't lower. The override must beat the tracker, and the
  // episode menu uses this same rule so its label matches the row.
  group('watched tick vs unwatched override', () {
    ResumeMark override() => ResumeMark(
      position: Duration.zero,
      duration: Duration.zero,
      markedUnwatched: true,
    );

    test('tracker progress alone ticks the episode', () {
      expect(
        episodeShowsWatched(
          mark: null,
          episodeNumber: 2,
          trackerProgress: 4,
          hasMultipleSeasons: false,
        ),
        isTrue,
      );
    });

    test('an unwatched override beats tracker progress', () {
      expect(
        episodeShowsWatched(
          mark: override(),
          episodeNumber: 2,
          trackerProgress: 4,
          hasMultipleSeasons: false,
        ),
        isFalse,
      );
    });

    test('an override with a manual watched flag still reads unwatched', () {
      final mark = ResumeMark(
        position: Duration.zero,
        duration: Duration.zero,
        markedWatched: true,
        markedUnwatched: true,
      );
      expect(mark.finished, isFalse);
      expect(
        episodeShowsWatched(
          mark: mark,
          episodeNumber: 2,
          trackerProgress: null,
          hasMultipleSeasons: false,
        ),
        isFalse,
      );
    });

    test('a local finished mark ticks without a tracker', () {
      expect(
        episodeShowsWatched(
          mark: ResumeMark(
            position: Duration.zero,
            duration: Duration.zero,
            markedWatched: true,
          ),
          episodeNumber: 7,
          trackerProgress: null,
          hasMultipleSeasons: false,
        ),
        isTrue,
      );
    });

    test('multi-season shows ignore the tracker', () {
      expect(
        episodeShowsWatched(
          mark: null,
          episodeNumber: 2,
          trackerProgress: 4,
          hasMultipleSeasons: true,
        ),
        isFalse,
      );
    });
  });
}
