import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/features/home/desktop_lists_hub_airing_panel.dart';
import 'package:watch_app/features/home/lists_hub_models.dart';

void main() {
  group('hubVisibleAiring', () {
    final day = DateTime(2026, 11, 17);
    final items = [
      for (var h = 1; h <= 8; h++)
        HubAiringItem(
          title: 'Show $h',
          episode: 1,
          airingAt: day.add(Duration(hours: h)),
        ),
    ];
    List<String> titles(DateTime now) =>
        hubVisibleAiring(items, now).map((e) => e.title).toList();

    test('starts at the next to air and shows 4', () {
      expect(titles(day.add(const Duration(hours: 2, minutes: 40))), [
        'Show 3',
        'Show 4',
        'Show 5',
        'Show 6',
      ]);
    });

    test('keeps the one airing now', () {
      expect(
        titles(day.add(const Duration(hours: 3, minutes: 10))).first,
        'Show 3',
      );
    });

    test('late in the day fills from the latest aired', () {
      expect(titles(day.add(const Duration(hours: 23))), [
        'Show 5',
        'Show 6',
        'Show 7',
        'Show 8',
      ]);
    });

    test('short days show everything', () {
      expect(hubVisibleAiring(items.take(3).toList(), day), hasLength(3));
    });
  });

  // A fixed local "now" so countdowns are deterministic.
  final base = DateTime(2026, 11, 17, 18, 0);

  MediaItem show(String id) => MediaItem(
    id: id,
    title: id,
    url: 'fixture://$id',
    sourceId: 'fixture',
    type: ProviderType.anime,
  );

  HubAiringItem row(
    String title,
    Duration fromBase, {
    int ep = 1,
    bool mine = false,
    bool clickable = true,
  }) => HubAiringItem(
    title: title,
    episode: ep,
    airingAt: base.add(fromBase),
    onYourList: mine,
    item: clickable ? show(title) : null,
  );

  Future<void> pump(
    WidgetTester tester, {
    required List<HubAiringItem>? items,
    bool loading = false,
    bool failed = false,
    VoidCallback? onRetry,
    VoidCallback? onOpenSchedule,
    void Function(HubAiringItem)? onOpenItem,
    DateTime Function()? now,
    double width = 420,
  }) async {
    await tester.binding.setSurfaceSize(Size(width, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: DesktopListsHubAiringPanel(
                  items: items,
                  loading: loading,
                  failed: failed,
                  onRetry: onRetry,
                  onOpenSchedule: onOpenSchedule ?? () {},
                  onOpenItem: onOpenItem ?? (_) {},
                  now: now ?? () => base,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  group('countdown label', () {
    test('formats hours and minutes, rounding seconds up', () {
      expect(
        hubFormatCountdown(const Duration(hours: 1, minutes: 12)),
        '1h 12m',
      );
      expect(hubFormatCountdown(const Duration(minutes: 45)), '45m');
      expect(hubFormatCountdown(const Duration(hours: 2)), '2h');
      expect(hubFormatCountdown(const Duration(seconds: 5)), '1m');
    });

    test('next, airing now and all aired states', () {
      final items = [
        row('A', const Duration(hours: -3)),
        row('B', const Duration(hours: 1, minutes: 12)),
      ];
      expect(hubAiringCountdownLabel(items, base), 'Next in 1h 12m');
      expect(
        hubAiringCountdownLabel(
          items,
          base.add(const Duration(hours: 1, minutes: 20)),
        ),
        'Airing now',
      );
      expect(
        hubAiringCountdownLabel(items, base.add(const Duration(hours: 2))),
        'All aired today',
      );
      expect(hubAiringCountdownLabel(const [], base), '');
    });
  });

  testWidgets('shows the countdown and ticks every minute', (tester) async {
    var now = base;
    await pump(
      tester,
      items: [row('Later show', const Duration(hours: 1, minutes: 12))],
      now: () => now,
    );
    expect(find.text('Next in 1h 12m'), findsOneWidget);
    now = base.add(const Duration(minutes: 1));
    await tester.pump(const Duration(minutes: 1));
    expect(find.text('Next in 1h 11m'), findsOneWidget);
    now = base.add(const Duration(hours: 1, minutes: 13));
    await tester.pump(const Duration(minutes: 1));
    expect(find.text('Airing now'), findsOneWidget);
    expect(find.text('Now'), findsOneWidget);
    now = base.add(const Duration(hours: 3));
    await tester.pump(const Duration(minutes: 1));
    expect(find.text('All aired today'), findsOneWidget);
  });

  testWidgets('tags shows on your list and dims aired rows', (tester) async {
    await pump(
      tester,
      items: [
        row('Old show', const Duration(hours: -2), ep: 3),
        row('Mine', const Duration(hours: 1), ep: 7, mine: true),
        row('Other', const Duration(hours: 2)),
      ],
    );
    expect(find.text('On your list'), findsOneWidget);
    expect(find.text('Ep 7'), findsOneWidget);
    expect(find.text('Ep 3'), findsOneWidget);
    final dimmed = tester.widget<Opacity>(
      find
          .ancestor(of: find.text('Old show'), matching: find.byType(Opacity))
          .first,
    );
    expect(dimmed.opacity, lessThan(1));
    final upcoming = tester.widget<Opacity>(
      find
          .ancestor(of: find.text('Other'), matching: find.byType(Opacity))
          .first,
    );
    expect(upcoming.opacity, 1);
  });

  testWidgets('taps open the show and the week schedule', (tester) async {
    final opened = <String>[];
    var schedule = 0;
    await pump(
      tester,
      items: [
        row('Clickable', const Duration(hours: 1)),
        row('No page', const Duration(hours: 2), clickable: false),
      ],
      onOpenItem: (i) => opened.add(i.title),
      onOpenSchedule: () => schedule++,
    );
    await tester.tap(find.text('Clickable'));
    await tester.tap(find.text('No page'));
    await tester.tap(find.text('Full week schedule'));
    await tester.pump();
    // Rows without a show page still open (the page searches the title).
    expect(opened, ['Clickable', 'No page']);
    expect(schedule, 1);
  });

  testWidgets('Enter on a focused row opens it', (tester) async {
    final opened = <String>[];
    await pump(
      tester,
      items: [row('Keyboard', const Duration(hours: 1))],
      onOpenItem: (i) => opened.add(i.title),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(opened, ['Keyboard']);
  });

  testWidgets('empty state keeps the week link', (tester) async {
    var schedule = 0;
    await pump(tester, items: const [], onOpenSchedule: () => schedule++);
    expect(find.text('Nothing airing today'), findsOneWidget);
    await tester.tap(find.text('Full week schedule'));
    expect(schedule, 1);
  });

  testWidgets('skeleton only before the first load', (tester) async {
    await pump(tester, items: null, loading: true);
    expect(find.byKey(const ValueKey('airing-skeleton')), findsOneWidget);
    await pump(
      tester,
      items: [row('Cached', const Duration(hours: 1))],
      loading: true,
    );
    expect(find.byKey(const ValueKey('airing-skeleton')), findsNothing);
    expect(find.text('Cached'), findsOneWidget);
  });

  testWidgets('failed refresh keeps rows and offers a quiet retry', (
    tester,
  ) async {
    var retries = 0;
    await pump(
      tester,
      items: [row('Cached', const Duration(hours: 1))],
      failed: true,
      onRetry: () => retries++,
    );
    expect(find.text('Cached'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(retries, 1);
  });

  for (final width in [300.0, 480.0]) {
    testWidgets('no overflow at ${width.toInt()}px', (tester) async {
      await pump(
        tester,
        width: width,
        failed: true,
        onRetry: () {},
        items: [
          row(
            'An extremely long anime title that keeps going well past the edge',
            const Duration(hours: 1, minutes: 12),
            ep: 1024,
            mine: true,
          ),
          row('Short', const Duration(hours: -1)),
        ],
      );
      expect(tester.takeException(), isNull);
      await pump(tester, width: width, items: null, loading: true);
      expect(tester.takeException(), isNull);
      await pump(tester, width: width, items: const []);
      expect(tester.takeException(), isNull);
    });
  }

  // Windows "Make text bigger" at 150%: the header chip wraps under the
  // title and rows ellipsize instead of overflowing.
  testWidgets('no overflow at text scale 1.5', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    for (final width in [300.0, 360.0]) {
      await pump(
        tester,
        width: width,
        failed: true,
        onRetry: () {},
        items: [
          row(
            'A long anime title that keeps going well past the edge',
            const Duration(hours: 11, minutes: 59),
            ep: 1024,
            mine: true,
          ),
          row('Earlier', const Duration(hours: -2)),
        ],
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Airing today'), findsOneWidget);
      expect(find.text('Next in 11h 59m'), findsOneWidget);
    }
  });

  testWidgets('timer is cancelled on dispose', (tester) async {
    await pump(tester, items: [row('A', const Duration(hours: 1))]);
    await tester.pumpWidget(const SizedBox());
    // A pending periodic tick would fail the test's timer check here.
    await tester.pump(const Duration(minutes: 2));
    expect(tester.takeException(), isNull);
  });
}
