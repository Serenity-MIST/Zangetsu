import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/tracker/tracker.dart';
import 'package:watch_app/core/tracker/tracker_hub.dart';
import 'package:watch_app/core/ui/tracker_list_sheet.dart';
import 'package:watch_app/core/ui/tracker_sync_sheet.dart';

/// Connected tracker with a canned entry and one canned search hit — no
/// network, just enough for the tracking pop-ups to render.
class _FakeTracker extends ChangeNotifier implements Tracker {
  _FakeTracker({this.entry});

  final TrackerEntry? entry;

  @override
  String get displayName => 'AniList';
  @override
  bool get supportsReading => true;
  @override
  bool get isConnected => true;
  @override
  String? get viewerName => 'someone';
  @override
  String? get viewerAvatar => null;
  @override
  bool get autoSync => true;
  @override
  set autoSync(bool value) {}

  @override
  Future<bool> connect() async => true;
  @override
  Future<void> disconnect() async {}

  @override
  Future<void> markWatching({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    MediaKind kind = MediaKind.anime,
  }) async {}

  @override
  Future<void> scrobble({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    required int episode,
    int? season,
    int? seasonEpisode,
    MediaKind kind = MediaKind.anime,
    bool novel = false,
  }) async {}

  @override
  Future<void> setStatus({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    required WatchStatus status,
    MediaKind kind = MediaKind.anime,
  }) async {}

  @override
  Future<void> removeFromList({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    String? pinnedId,
    MediaKind kind = MediaKind.anime,
  }) async {}

  @override
  Future<List<TrackerListItem>> fetchList() async => const [];

  @override
  Future<TrackerEntry?> fetchEntry({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    String? pinnedId,
    MediaKind kind = MediaKind.anime,
    bool novel = false,
  }) async => entry;

  @override
  Future<void> updateEntry({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    String? pinnedId,
    WatchStatus? status,
    double? score,
    int? progress,
    bool? isPrivate,
    MediaKind kind = MediaKind.anime,
  }) async {}

  @override
  Future<List<TrackerSearchResult>> searchEntries(
    String query, {
    MediaKind kind = MediaKind.anime,
  }) async => const [];

  @override
  Map<String, dynamic>? exportSession() => null;
  @override
  Future<void> importSession(Map<String, dynamic> session) async {}
}

/// Key the Windows adaptive sheet puts on its graphite Dialog.
const _desktopSheet = ValueKey('desktop-adaptive-sheet');

void main() {
  setUp(() {
    sl.registerSingleton<AppMode>(const AppMode(isTv: false));
    sl.registerSingleton<TrackerHub>(
      TrackerHub([
        _FakeTracker(
          entry: const TrackerEntry(
            trackerName: 'AniList',
            onList: true,
            title: 'Solo Leveling',
            url: 'https://anilist.co/anime/1',
          ),
        ),
      ]),
    );
  });

  tearDown(() => sl.reset());

  /// A page with one button that opens [open]; returns after it is tapped.
  Future<void> openFrom(
    WidgetTester tester,
    Future<void> Function(BuildContext) open,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (c) =>
                TextButton(onPressed: () => open(c), child: const Text('open')),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Windows: list -> tracker -> change match all open as graphite dialogs',
    (tester) async {
      await openFrom(
        tester,
        (c) => showTrackerListSheet(c, title: 'Solo Leveling', isAnime: true),
      );
      // The list itself is a desktop dialog, not a phone sheet.
      expect(find.byKey(_desktopSheet), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);

      // Opening one tracker stacks a second (nested) dialog — no bottom sheet.
      await tester.tap(find.text('Solo Leveling').last);
      await tester.pumpAndSettle();
      expect(find.byKey(_desktopSheet), findsNWidgets(2));
      expect(find.byType(BottomSheet), findsNothing);
      // The heading lives in the title bar, not in the body a second time.
      expect(find.text('Apply'), findsOneWidget);

      // "Change match" opens the search picker as a third dialog.
      final change = find.textContaining('Change match');
      await tester.ensureVisible(change);
      await tester.tap(change);
      await tester.pumpAndSettle();
      expect(find.byKey(_desktopSheet), findsNWidgets(3));
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('No matches found'), findsOneWidget);

      // Esc closes only the top picker, leaving the sync dialog open.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(_desktopSheet), findsNWidgets(2));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'Windows: the row options button opens the desktop menu, not a popup',
    (tester) async {
      await openFrom(
        tester,
        (c) => showTrackerListSheet(c, title: 'Solo Leveling', isAnime: true),
      );
      await tester.tap(find.byIcon(Icons.more_vert_rounded));
      await tester.pumpAndSettle();
      expect(find.text('Open in browser'), findsOneWidget);
      expect(find.text('Remove tracking'), findsOneWidget);
      expect(find.byType(PopupMenuItem<String>), findsNothing);

      // Close it, then right-click the row: the same desktop menu opens.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Open in browser'), findsNothing);
      await tester.tap(
        find.text('Solo Leveling').last,
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      expect(find.text('Open in browser'), findsOneWidget);
      expect(find.text('Remove tracking'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('Phone: the sync editor is still a bottom sheet', (tester) async {
    await openFrom(
      tester,
      (c) => showTrackerSyncSheet(c, title: 'Solo Leveling', isAnime: true),
    );
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byKey(_desktopSheet), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
