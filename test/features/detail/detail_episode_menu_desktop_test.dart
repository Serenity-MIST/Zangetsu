// Windows episode right-click menu (show-5): which rows each download state
// produces, and that the menu opens as a compact context menu on Windows
// while phones keep their bottom sheet.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/desktop_context_menu.dart';
import 'package:watch_app/core/ui/episode_player_sheet.dart';

/// The enabled, non-divider labels of a menu, in order.
List<String> _labels(List<DesktopMenuItem<EpisodeAction>> items) => [
  for (final i in items)
    if (!i.isDivider) i.label,
];

void main() {
  group('episodeDesktopMenuItems', () {
    test('nothing saved offers Download', () {
      final items = episodeDesktopMenuItems(
        isWatched: false,
        canSurveySources: true,
        downloadState: EpisodeDownloadMenuState.none,
      );
      expect(_labels(items), [
        'Play',
        'Play mirror',
        'Where to watch',
        'Reload links',
        'Download',
        'Mark as watched',
        'Mark all above as watched',
      ]);
      expect(
        items.firstWhere((i) => i.label == 'Download').value,
        EpisodeAction.download,
      );
    });

    test('a finished file offers Show in folder and Delete download', () {
      final items = episodeDesktopMenuItems(
        isWatched: true,
        downloadState: EpisodeDownloadMenuState.done,
      );
      final labels = _labels(items);
      expect(labels, contains('Show in folder'));
      expect(labels, contains('Delete download'));
      expect(labels, isNot(contains('Download')));
      expect(labels, contains('Mark as unwatched'));
      expect(
        items.firstWhere((i) => i.label == 'Delete download').destructive,
        isTrue,
      );
    });

    test('a broken saved copy offers Download again and Delete download', () {
      final items = episodeDesktopMenuItems(
        isWatched: false,
        downloadState: EpisodeDownloadMenuState.broken,
      );
      final labels = _labels(items);
      expect(labels, contains('Download'));
      expect(labels, contains('Show in folder'));
      expect(labels, contains('Delete download'));
      // Never offered as a playable saved file.
      expect(labels, isNot(contains('Play offline')));
      final delete = items.firstWhere((i) => i.label == 'Delete download');
      expect(delete.value, EpisodeAction.deleteDownload);
      expect(delete.destructive, isTrue);
    });

    test('an active download is a disabled row', () {
      final items = episodeDesktopMenuItems(
        isWatched: false,
        downloadState: EpisodeDownloadMenuState.inProgress,
      );
      final row = items.firstWhere((i) => i.label == 'Downloading…');
      expect(row.enabled, isFalse);
      expect(_labels(items), isNot(contains('Download')));
    });

    test('reading keeps only the marking rows and Open in browser', () {
      final items = episodeDesktopMenuItems(
        isWatched: false,
        reading: true,
        canOpenInBrowser: true,
        downloadState: EpisodeDownloadMenuState.none,
      );
      expect(_labels(items), [
        'Mark as read',
        'Mark this and all above as read',
        'Open in browser',
      ]);
    });
  });

  testWidgets('Windows opens a context menu and returns the picked action', (
    tester,
  ) async {
    EpisodeAction? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () async {
                picked = await showEpisodeActionSheet(
                  context,
                  episodeLabel: 'Episode 7',
                  currentPlayerLabel: 'Built-in',
                  isWatched: false,
                  tracksToServices: false,
                  downloadState: EpisodeDownloadMenuState.done,
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
    // Context menu rows, no bottom sheet.
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('Show in folder'), findsOneWidget);
    expect(find.text('Delete download'), findsOneWidget);
    await tester.tap(find.text('Show in folder'));
    await tester.pumpAndSettle();
    expect(picked, EpisodeAction.showInFolder);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('phones keep the bottom sheet without download rows', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showEpisodeActionSheet(
                context,
                episodeLabel: 'Episode 7',
                currentPlayerLabel: 'Built-in',
                isWatched: false,
                tracksToServices: false,
                downloadState: EpisodeDownloadMenuState.done,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('Show in folder'), findsNothing);
    expect(find.text('Play with…'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
