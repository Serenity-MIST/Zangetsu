// The tracker half of the Windows "Schedule and lists" page: tabs per
// tracker, a tile per list kind with counts, a connect row for trackers that
// are not connected, and skeletons only before the first load.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/tracker/tracker.dart';
import 'package:watch_app/features/home/desktop_lists_hub_library.dart';
import 'package:watch_app/features/home/lists_hub_models.dart';
import 'package:watch_app/l10n/app_localizations.dart';

class _FakeTracker implements Tracker {
  _FakeTracker(this.displayName, {required this.supportsReading});

  @override
  final String displayName;
  @override
  final bool supportsReading;

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

final anilist = _FakeTracker('AniList', supportsReading: true);
final simkl = _FakeTracker('Simkl', supportsReading: false);
final mal = _FakeTracker('MyAnimeList', supportsReading: true);

HubListSummary sum(ContentMode k, int a, int p, {int c = 0}) => HubListSummary(
  trackerName: 'AniList',
  kind: k,
  active: a,
  planned: p,
  completed: c,
);

/// Records what the library asked its owner to do.
class Calls {
  final opened = <(String, ContentMode)>[];
  final connected = <String>[];
}

Widget harness(
  Calls calls, {
  List<({Tracker tracker, bool connected})>? trackers,
  Map<String, List<HubListSummary>?> data = const {},
  Set<String> loading = const {},
  double width = 900,
}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: SingleChildScrollView(
      child: Center(
        child: SizedBox(
          width: width,
          child: DesktopListsHubLibrary(
            trackers:
                trackers ??
                [
                  (tracker: anilist, connected: true),
                  (tracker: simkl, connected: true),
                  (tracker: mal, connected: false),
                ],
            summariesFor: (t) => data[t.displayName],
            loadingFor: (t) => loading.contains(t.displayName),
            onOpenList: (t, k) => calls.opened.add((t.displayName, k)),
            onConnect: (t) => calls.connected.add(t.displayName),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  setUp(() {
    final v = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .views
        .first;
    v.physicalSize = const Size(1200, 1600);
    v.devicePixelRatio = 1;
  });

  tearDown(() {
    TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher.views.first
        .resetPhysicalSize();
  });

  final aniData = {
    'AniList': [
      sum(ContentMode.anime, 12, 40, c: 7),
      sum(ContentMode.manga, 3, 8),
      sum(ContentMode.novel, 1, 2),
    ],
  };

  testWidgets('starts on the first connected tracker with counts', (t) async {
    await t.pumpWidget(harness(Calls(), data: aniData));
    await t.pumpAndSettle();

    expect(find.text('Anime'), findsOneWidget);
    expect(find.text('Manga'), findsOneWidget);
    expect(find.text('Novel'), findsOneWidget);
    expect(find.text('12 watching · 40 planned'), findsOneWidget);
    expect(find.text('3 reading · 8 planned'), findsOneWidget);
    expect(find.text('1 reading · 2 planned'), findsOneWidget);
    expect(find.text('7 completed'), findsOneWidget);
    // The not-connected tracker still has a tab, marked as such.
    expect(find.text('MyAnimeList'), findsOneWidget);
    expect(find.text('not connected'), findsOneWidget);
  });

  testWidgets('tabs switch trackers and kinds follow the tracker', (t) async {
    await t.pumpWidget(harness(Calls(), data: aniData));
    await t.pumpAndSettle();

    await t.tap(find.byKey(const ValueKey('hub-tab-Simkl')));
    await t.pumpAndSettle();

    // Simkl has no reading side: one video tile with its own title.
    expect(find.text('Movies and series'), findsOneWidget);
    expect(find.text('Manga'), findsNothing);
    expect(find.byKey(const ValueKey('hub-tile-Simkl-anime')), findsOneWidget);
  });

  testWidgets('tile taps open the right tracker and kind', (t) async {
    final calls = Calls();
    await t.pumpWidget(harness(calls, data: aniData));
    await t.pumpAndSettle();

    await t.tap(find.byKey(const ValueKey('hub-tile-AniList-manga')));
    await t.tap(find.byKey(const ValueKey('hub-tile-AniList-novel')));
    await t.tap(find.byKey(const ValueKey('hub-tile-AniList-anime')));
    expect(calls.opened, [
      ('AniList', ContentMode.manga),
      ('AniList', ContentMode.novel),
      ('AniList', ContentMode.anime),
    ]);
  });

  testWidgets('Enter on a focused tile opens it', (t) async {
    final calls = Calls();
    await t.pumpWidget(harness(calls, data: aniData));
    await t.pumpAndSettle();

    // Focus the anime tile's InkWell, then press Enter.
    final ink = find.descendant(
      of: find.byKey(const ValueKey('hub-tile-AniList-anime')),
      matching: find.byType(InkWell),
    );
    // Any widget inside the InkWell's own Focus reaches its node.
    final inside = find.descendant(
      of: ink.first,
      matching: find.byType(Padding),
    );
    Focus.of(t.element(inside.first)).requestFocus();
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pump();
    expect(calls.opened, [('AniList', ContentMode.anime)]);
  });

  testWidgets('not-connected tab shows the connect row', (t) async {
    final calls = Calls();
    await t.pumpWidget(harness(calls, data: aniData));
    await t.pumpAndSettle();

    await t.tap(find.byKey(const ValueKey('hub-tab-MyAnimeList')));
    await t.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('hub-connect-MyAnimeList')),
      findsOneWidget,
    );
    expect(
      find.text('Connect MyAnimeList to see its lists here'),
      findsOneWidget,
    );
    expect(find.text('Anime'), findsNothing);
    await t.tap(find.byKey(const ValueKey('hub-connect-button-MyAnimeList')));
    expect(calls.connected, ['MyAnimeList']);
  });

  testWidgets('nothing connected lands on the connect row', (t) async {
    await t.pumpWidget(
      harness(
        Calls(),
        trackers: [
          (tracker: anilist, connected: false),
          (tracker: simkl, connected: false),
        ],
      ),
    );
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('hub-connect-AniList')), findsOneWidget);
  });

  testWidgets('skeletons only while loading with no cache', (t) async {
    await t.pumpWidget(harness(Calls(), loading: {'AniList'}));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('hub-skeleton-anime')), findsOneWidget);
    expect(find.byKey(const ValueKey('hub-skeleton-novel')), findsOneWidget);
    expect(find.text('Anime'), findsNothing);

    // Cached data stays on screen during a refresh: no skeletons.
    await t.pumpWidget(harness(Calls(), data: aniData, loading: {'AniList'}));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('hub-skeleton-anime')), findsNothing);
    expect(find.text('12 watching · 40 planned'), findsOneWidget);
  });

  for (final width in [360.0, 700.0, 900.0]) {
    testWidgets('no overflow at ${width.toInt()}px', (t) async {
      await t.pumpWidget(harness(Calls(), data: aniData, width: width));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.tap(find.byKey(const ValueKey('hub-tab-MyAnimeList')));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.pumpWidget(harness(Calls(), loading: {'AniList'}, width: width));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('tile grid goes 3 / 2 / 1 across', (t) async {
    double tileWidth() =>
        t.getSize(find.byKey(const ValueKey('hub-tile-AniList-anime'))).width;

    await t.pumpWidget(harness(Calls(), data: aniData, width: 900));
    await t.pumpAndSettle();
    expect(tileWidth(), lessThan(300));

    await t.pumpWidget(harness(Calls(), data: aniData, width: 500));
    await t.pumpAndSettle();
    expect(tileWidth(), closeTo(243, 1));

    await t.pumpWidget(harness(Calls(), data: aniData, width: 360));
    await t.pumpAndSettle();
    expect(tileWidth(), 360);
  });

  // Windows "Make text bigger" at 150% on tiles, tabs and the connect row.
  testWidgets('no overflow at text scale 1.5', (t) async {
    t.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    for (final width in [360.0, 580.0, 712.0]) {
      await t.pumpWidget(harness(Calls(), data: aniData, width: width));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.tap(find.byKey(const ValueKey('hub-tab-MyAnimeList')));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    }
  });

  testWidgets('keyboard focus ring stays after the mouse leaves', (t) async {
    await t.pumpWidget(harness(Calls(), data: aniData));
    await t.pumpAndSettle();
    final tile = find.byKey(const ValueKey('hub-tile-AniList-anime'));
    List<BoxShadow> shadows() =>
        (t
                    .widget<AnimatedContainer>(
                      find
                          .descendant(
                            of: tile,
                            matching: find.byType(AnimatedContainer),
                          )
                          .first,
                    )
                    .decoration!
                as BoxDecoration)
            .boxShadow ??
        const [];
    // Tab past the three tracker tabs onto the first tile.
    for (var i = 0; i < 4; i++) {
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
    }
    await t.pumpAndSettle();
    final focused = shadows().length;
    expect(focused, 2, reason: 'focus halo plus lift shadow');
    // Hover in and out with the mouse: the focus halo must remain.
    final g = await t.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(g.removePointer);
    await g.addPointer(location: t.getCenter(tile));
    await t.pumpAndSettle();
    await g.moveTo(Offset.zero);
    await t.pumpAndSettle();
    expect(shadows().length, focused);
  });
}
