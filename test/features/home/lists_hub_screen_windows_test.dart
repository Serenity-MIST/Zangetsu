// The Windows "Schedule and lists" page as a whole: cached data on the first
// frame, a background refresh that updates it, the links going to the right
// places, stacking on a narrow window, and a failed refresh that keeps what is
// shown. Phone and TV keep the old list (lists_hub_screen_test.dart).

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/tracker/tracker.dart';
import 'package:watch_app/core/tracker/tracker_hub.dart';
import 'package:watch_app/features/home/lists_hub_models.dart';
import 'package:watch_app/features/home/lists_hub_screen.dart';
import 'package:watch_app/l10n/app_localizations.dart';

/// A tracker whose connection can be flipped, notifying like the real ones.
class _FakeTracker extends ChangeNotifier implements Tracker {
  _FakeTracker(
    this.displayName, {
    required this.supportsReading,
    this.isConnected = true,
  });

  @override
  final String displayName;
  @override
  final bool supportsReading;
  @override
  bool isConnected;

  @override
  String? get viewerName => isConnected ? 'me' : null;

  void setConnected(bool v) {
    isConnected = v;
    notifyListeners();
  }

  /// Whether the page still listens (checks dispose cleanup).
  bool get listening => hasListeners;

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// In-memory [ListsHubData]; refreshes wait on completers the test controls.
class _FakeData extends ChangeNotifier implements ListsHubData {
  final Map<String, List<HubListSummary>> summaries = {};
  List<HubAiringItem>? airing;
  @override
  DateTime? lastUpdated;
  @override
  String? lastError;

  final summaryCalls = <String>[];
  var airingCalls = 0;
  final Map<String, Completer<List<HubListSummary>>> pendingSummaries = {};
  Completer<List<HubAiringItem>>? pendingAiring;

  @override
  List<HubListSummary>? cachedSummaries(Tracker t) => summaries[t.displayName];

  @override
  Future<List<HubListSummary>> refreshSummaries(Tracker t) {
    summaryCalls.add(t.displayName);
    return (pendingSummaries[t.displayName] = Completer()).future;
  }

  @override
  List<HubAiringItem>? cachedAiringToday() => airing;

  @override
  Future<List<HubAiringItem>> refreshAiringToday() {
    airingCalls++;
    return (pendingAiring = Completer()).future;
  }

  /// Finishes every pending refresh, like a successful fetch.
  void completeAll() {
    for (final c in pendingSummaries.values) {
      if (!c.isCompleted) c.complete(const []);
    }
    if (pendingAiring?.isCompleted == false) pendingAiring!.complete(const []);
    notifyListeners();
  }
}

/// Records where the page asked to go.
class _Nav extends ListsHubNavigation {
  final calls = <String>[];

  @override
  void openSchedule(BuildContext context) => calls.add('schedule');
  @override
  void openList(BuildContext context, Tracker t, ContentMode k) =>
      calls.add('list:${t.displayName}:${k.name}');
  @override
  void openShow(BuildContext context, MediaItem item) =>
      calls.add('show:${item.title}');
  @override
  void openSearch(BuildContext context, String title) =>
      calls.add('search:$title');
  @override
  Future<void> openConnect(BuildContext context, Tracker t) async =>
      calls.add('connect:${t.displayName}');
}

final now = DateTime(2026, 11, 17, 12);

HubListSummary sum(String tracker, ContentMode k, int a, int p) =>
    HubListSummary(
      trackerName: tracker,
      kind: k,
      active: a,
      planned: p,
      completed: 0,
    );

HubAiringItem row(String title, int ep, int hour, {bool clickable = true}) =>
    HubAiringItem(
      title: title,
      episode: ep,
      airingAt: DateTime(2026, 11, 17, hour),
      item: clickable
          ? MediaItem(
              id: 'mal:$ep',
              title: title,
              url: 'zm://x',
              type: ProviderType.anime,
              sourceId: 'z',
            )
          : null,
    );

Widget _page(_FakeData data, List<Tracker> trackers, _Nav nav) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: ListsHubWindowsPage(
    data: data,
    trackers: trackers,
    navigation: nav,
    now: () => now,
  ),
);

void setWidth(double w) {
  final v = TestWidgetsFlutterBinding.ensureInitialized()
      .platformDispatcher
      .views
      .first;
  v.physicalSize = Size(w, 1100);
  v.devicePixelRatio = 1;
}

void main() {
  late _FakeData data;
  late _FakeTracker anilist;
  late _FakeTracker simkl;
  late _Nav nav;

  setUp(() {
    setWidth(1400);
    data = _FakeData()
      ..lastUpdated = now.subtract(const Duration(minutes: 5))
      ..summaries['AniList'] = [
        sum('AniList', ContentMode.anime, 12, 40),
        sum('AniList', ContentMode.manga, 3, 8),
        sum('AniList', ContentMode.novel, 0, 0),
      ]
      ..airing = [row('Frieren', 7, 18), row('Untracked', 2, 20, clickable: false)];
    anilist = _FakeTracker('AniList', supportsReading: true);
    simkl = _FakeTracker('Simkl', supportsReading: false, isConnected: false);
    nav = _Nav();
  });

  tearDown(() async {
    TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .views
        .first
        .resetPhysicalSize();
    await sl.reset();
  });

  test('updated label wording', () {
    expect(hubUpdatedLabel(null, now), '');
    expect(hubUpdatedLabel(now, now), 'Updated just now');
    expect(
      hubUpdatedLabel(now.subtract(const Duration(minutes: 5)), now),
      'Updated 5 min ago',
    );
    expect(
      hubUpdatedLabel(now.subtract(const Duration(hours: 3)), now),
      'Updated 3 h ago',
    );
  });

  testWidgets('Windows gets the dashboard, other platforms the list', (
    t,
  ) async {
    sl.registerSingleton<ListsHubData>(data);
    sl.registerSingleton<TrackerHub>(TrackerHub([anilist, simkl]));
    const app = MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ListsHubScreen(),
    );

    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await t.pumpWidget(app);
    await t.pump();
    expect(find.byType(ListsHubWindowsPage), findsOneWidget);
    expect(find.text('12 watching · 40 planned'), findsOneWidget);
    // Refreshes started from the registered data on open.
    expect(data.summaryCalls, ['AniList']);
    expect(data.airingCalls, 1);

    await t.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await t.pumpWidget(app);
    await t.pump();
    expect(find.byType(ListsHubWindowsPage), findsNothing);
    expect(find.text('BROWSE'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('cached data on the first frame, refresh updates it', (t) async {
    await t.pumpWidget(_page(data, [anilist, simkl], nav));

    // First frame: cache, header and a background refresh in flight.
    // Localised title, the same wording as the sidebar item.
    expect(find.text('Schedule & lists'), findsOneWidget);
    expect(find.text('Updated 5 min ago'), findsOneWidget);
    expect(find.text('12 watching · 40 planned'), findsOneWidget);
    expect(find.textContaining('Frieren'), findsOneWidget);
    expect(find.byKey(const ValueKey('lists-hub-refreshing')), findsOneWidget);
    expect(find.byKey(const ValueKey('airing-skeleton')), findsNothing);
    expect(find.byKey(const ValueKey('hub-skeleton-anime')), findsNothing);
    // Not-connected trackers are not fetched.
    expect(data.summaryCalls, ['AniList']);

    // The refresh lands with new numbers.
    data
      ..summaries['AniList'] = [sum('AniList', ContentMode.anime, 13, 40)]
      ..lastUpdated = now;
    data.completeAll();
    await t.pump();
    await t.pump();
    expect(find.text('13 watching · 40 planned'), findsOneWidget);
    expect(find.text('Updated just now'), findsOneWidget);
    expect(find.byKey(const ValueKey('lists-hub-refreshing')), findsNothing);
  });

  testWidgets('skeletons only when nothing is cached', (t) async {
    data
      ..summaries.clear()
      ..airing = null
      ..lastUpdated = null;
    await t.pumpWidget(_page(data, [anilist], nav));
    expect(find.byKey(const ValueKey('airing-skeleton')), findsOneWidget);
    expect(find.byKey(const ValueKey('hub-skeleton-anime')), findsOneWidget);

    data
      ..summaries['AniList'] = [sum('AniList', ContentMode.anime, 1, 2)]
      ..airing = const [];
    data.completeAll();
    await t.pump();
    await t.pump();
    expect(find.byKey(const ValueKey('airing-skeleton')), findsNothing);
    expect(find.text('Nothing airing today'), findsOneWidget);
    expect(find.text('1 watching · 2 planned'), findsOneWidget);
  });

  testWidgets('tile, row, week link and connect go to the right places', (
    t,
  ) async {
    await t.pumpWidget(_page(data, [anilist, simkl], nav));
    data.completeAll();
    await t.pump();

    await t.tap(find.byKey(const ValueKey('hub-tile-AniList-manga')));
    await t.tap(find.textContaining('Frieren'));
    // A row without a show page searches its title instead.
    await t.tap(find.textContaining('Untracked'));
    await t.tap(find.textContaining('Full week schedule'));
    await t.tap(find.byKey(const ValueKey('hub-tab-Simkl')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('hub-connect-button-Simkl')));
    await t.pump();

    expect(nav.calls, [
      'list:AniList:manga',
      'show:Frieren',
      'search:Untracked',
      'schedule',
      'connect:Simkl',
    ]);
  });

  testWidgets('nothing connected: connect row and the airing panel', (
    t,
  ) async {
    anilist.isConnected = false;
    data.summaries.clear();
    await t.pumpWidget(_page(data, [anilist, simkl], nav));
    expect(find.byKey(const ValueKey('hub-connect-AniList')), findsOneWidget);
    expect(find.textContaining('Frieren'), findsOneWidget);
    expect(data.summaryCalls, isEmpty);
    data.completeAll();
    await t.pump();
  });

  testWidgets('connecting a tracker refreshes it and the airing tags', (
    t,
  ) async {
    await t.pumpWidget(_page(data, [anilist, simkl], nav));
    data.completeAll();
    await t.pump();
    expect(data.summaryCalls, ['AniList']);
    expect(data.airingCalls, 1);

    simkl.setConnected(true);
    await t.pump();
    expect(data.summaryCalls, ['AniList', 'Simkl']);
    expect(data.airingCalls, 2);
    // Connected trackers move to the front of the tabs.
    final aniX = t.getTopLeft(find.byKey(const ValueKey('hub-tab-AniList'))).dx;
    final simX = t.getTopLeft(find.byKey(const ValueKey('hub-tab-Simkl'))).dx;
    expect(aniX < simX, isTrue);
    data.completeAll();
    await t.pump();
  });

  testWidgets('a failed refresh keeps the cache and offers a quiet retry', (
    t,
  ) async {
    await t.pumpWidget(_page(data, [anilist], nav));
    data.lastError = 'offline';
    data.completeAll();
    await t.pump();
    await t.pump();

    expect(find.text('12 watching · 40 planned'), findsOneWidget);
    expect(find.textContaining('Frieren'), findsOneWidget);
    expect(find.text("Couldn't refresh"), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('lists-hub-retry')));
    await t.pump();
    expect(data.summaryCalls, ['AniList', 'AniList']);
    expect(data.airingCalls, 2);
    data.completeAll();
    await t.pump();
  });

  testWidgets('leaving the page stops listening to trackers and data', (
    t,
  ) async {
    await t.pumpWidget(_page(data, [anilist, simkl], nav));
    expect(anilist.listening, isTrue);
    data.completeAll();
    await t.pump();
    await t.pumpWidget(const SizedBox());
    expect(anilist.listening, isFalse);
    expect(simkl.listening, isFalse);
    // A connect after the page is gone fetches nothing.
    simkl.setConnected(true);
    expect(data.summaryCalls, ['AniList']);
  });

  testWidgets('shown again after a while, or after midnight, it refetches', (
    t,
  ) async {
    var clock = now;
    Widget host(bool visible) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: TickerMode(
        enabled: visible,
        child: ListsHubWindowsPage(
          data: data,
          trackers: [anilist],
          navigation: nav,
          now: () => clock,
        ),
      ),
    );
    await t.pumpWidget(host(true));
    data.completeAll();
    await t.pump();
    expect(data.airingCalls, 1);

    // Hidden then shown within two minutes: no refetch.
    await t.pumpWidget(host(false));
    await t.pumpWidget(host(true));
    expect(data.airingCalls, 1);

    // Hidden, three minutes pass, shown again: refetch everything.
    await t.pumpWidget(host(false));
    clock = clock.add(const Duration(minutes: 3));
    await t.pumpWidget(host(true));
    expect(data.airingCalls, 2);
    expect(data.summaryCalls, ['AniList', 'AniList']);
    data.completeAll();
    await t.pump();

    // Left open past local midnight: the minute tick refetches airing.
    clock = DateTime(2026, 11, 18, 0, 1);
    await t.pump(const Duration(minutes: 1));
    expect(data.airingCalls, 3);
    data.completeAll();
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('two columns when wide, stacked when narrow', (t) async {
    final airing = find.byKey(const ValueKey('lists-hub-airing'));
    final library = find.byKey(const ValueKey('lists-hub-library'));

    await t.pumpWidget(_page(data, [anilist, simkl], nav));
    data.completeAll();
    await t.pump();
    expect(t.getTopLeft(airing).dx < t.getTopLeft(library).dx, isTrue);
    expect(t.getTopLeft(airing).dy, t.getTopLeft(library).dy);
    // Content is capped and centred on a very wide window.
    final width = t.getSize(airing).width + 32 + t.getSize(library).width;
    expect(width, lessThanOrEqualTo(1180.5));

    setWidth(820);
    await t.pump();
    expect(t.getTopLeft(airing).dy < t.getTopLeft(library).dy, isTrue);
    expect(t.getTopLeft(airing).dx, t.getTopLeft(library).dx);
    expect(t.takeException(), isNull);

    setWidth(480);
    await t.pump();
    expect(t.takeException(), isNull);
  });
}
