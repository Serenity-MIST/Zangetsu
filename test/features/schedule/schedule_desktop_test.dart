// Windows Schedule (track-3, 4, 5, 7, 8, 11): cubit behaviour behind the
// desktop week view, the offline copy codecs, and the view itself.
import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/desktop_shortcut_catalog.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/playback/my_list.dart';
import 'package:watch_app/core/schedule/airing_service.dart';
import 'package:watch_app/core/schedule/coming_soon_service.dart';
import 'package:watch_app/core/schedule/schedule_models.dart';
import 'package:watch_app/core/tracker/tracker.dart';
import 'package:watch_app/core/tracker/tracker_hub.dart';
import 'package:watch_app/features/schedule/schedule_cubit.dart';
import 'package:watch_app/features/schedule/schedule_offline_cache.dart';
import 'package:watch_app/features/schedule/schedule_screen.dart';
import 'package:watch_app/l10n/app_localizations.dart';

/// Airing service returning [out] and counting calls.
class _Airing implements AiringService {
  _Airing(this.out);
  List<AiringEntry> out;
  int calls = 0;
  @override
  bool lastFailureOffline = false;
  @override
  Future<List<AiringEntry>> weekAiring({DateTime? now}) async {
    calls++;
    return out;
  }

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// Airing service whose first answer waits for [gate] (a load in flight).
class _GatedAiring implements AiringService {
  _GatedAiring(this.gate);
  final Future<void> gate;
  int calls = 0;
  @override
  bool lastFailureOffline = false;
  @override
  Future<List<AiringEntry>> weekAiring({DateTime? now}) async {
    calls++;
    if (calls == 1) await gate;
    return [_airing(1, DateTime.now())];
  }

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// Coming-soon service returning [out].
class _Soon implements ComingSoonService {
  _Soon(this.out);
  List<ComingSoonEntry> out;
  @override
  bool lastFailureOffline = false;
  @override
  Future<List<ComingSoonEntry>> upcoming() async => out;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// Empty My List.
class _MyList implements MyListStore {
  @override
  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  @override
  List<MediaItem> all() => const [];
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// Connected anime tracker that counts list reads.
class _Tracker extends ChangeNotifier implements Tracker {
  int fetchCount = 0;

  /// What the next list read answers (real trackers answer [] on errors).
  List<TrackerListItem> list = const [];
  @override
  String get displayName => 'AniList';
  @override
  bool get supportsReading => true;
  @override
  bool get isConnected => true;
  @override
  Future<List<TrackerListItem>> fetchList() async {
    fetchCount++;
    return list;
  }

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

AiringEntry _airing(int mal, DateTime at) => AiringEntry(
  malId: mal,
  title: 'Show $mal',
  coverUrl: null,
  episode: 3,
  airsAtLocal: at,
  format: 'TV',
  synopsis: 'About show $mal',
);

/// Cubit seeded with a fixed state that records refreshes instead of
/// fetching, so the view can be driven without services.
class _StubCubit extends ScheduleCubit {
  _StubCubit(ScheduleState seed)
    : super(_Airing(const []), _Soon(const []), _MyList()) {
    emit(seed);
  }
  int refreshes = 0;
  @override
  Future<void> load() async {}
  @override
  Future<void> refresh() async => refreshes++;
}

void main() {
  group('ScheduleCubit (Windows extras)', () {
    test(
      'rollOverDay moves a "today" selection to the new day and reloads',
      () async {
        final airing = _Airing([_airing(1, DateTime(2026, 7, 10, 12))]);
        final cubit = ScheduleCubit(
          airing,
          _Soon(const []),
          _MyList(),
          retryDelays: const [],
        );
        await cubit.load();
        cubit.selectDay(DateTime(2026, 7, 10));
        final before = airing.calls;
        final rolled = cubit.rollOverDay(
          DateTime(2026, 7, 10),
          now: DateTime(2026, 7, 11, 0, 1),
        );
        await Future<void>.delayed(Duration.zero);
        expect(rolled, isTrue);
        expect(cubit.state.selectedDay, DateTime(2026, 7, 11));
        expect(airing.calls, greaterThan(before));
        await cubit.close();
      },
    );

    test('rollOverDay keeps a selection the user moved off today', () async {
      final cubit = ScheduleCubit(
        _Airing(const []),
        _Soon(const []),
        _MyList(),
        retryDelays: const [],
      );
      cubit.selectDay(DateTime(2026, 7, 13));
      cubit.rollOverDay(
        DateTime(2026, 7, 10),
        now: DateTime(2026, 7, 11, 0, 1),
      );
      expect(cubit.state.selectedDay, DateTime(2026, 7, 13));
      // Same day: nothing happens.
      expect(
        cubit.rollOverDay(DateTime(2026, 7, 11), now: DateTime(2026, 7, 11, 9)),
        isFalse,
      );
      await Future<void>.delayed(Duration.zero);
      await cubit.close();
    });

    test('a good load is saved; a failed one shows the saved copy', () async {
      final cache = MemoryScheduleOfflineCache();
      final airing = _Airing([_airing(1, DateTime(2026, 7, 10, 12))]);
      final soon = _Soon(const [
        ComingSoonEntry(
          tmdbId: 5,
          isTv: false,
          title: 'Film',
          posterUrl: null,
          releaseDate: null,
        ),
      ]);
      final first = ScheduleCubit(
        airing,
        soon,
        _MyList(),
        retryDelays: const [],
        offlineCache: cache,
      );
      await first.load();
      expect(cache.airing!.entries.single.malId, 1);
      expect(cache.soon!.entries.single.tmdbId, 5);
      expect(first.state.airingSavedAt, isNull);
      expect(first.state.lastUpdated, isNotNull);
      await first.close();

      // Next session: both services fail (empty) and one is offline.
      airing
        ..out = const []
        ..lastFailureOffline = true;
      soon.out = const [];
      final second = ScheduleCubit(
        airing,
        soon,
        _MyList(),
        retryDelays: const [],
        offlineCache: cache,
      );
      await second.load();
      expect(second.state.airingAll.single.malId, 1);
      expect(second.state.comingSoon.single.tmdbId, 5);
      expect(second.state.airingSavedAt, cache.airing!.savedAt);
      expect(second.state.soonSavedAt, cache.soon!.savedAt);
      expect(second.state.errorAiring, isTrue);
      await second.close();
    });

    test('without a cache (phone) a failed load stays empty', () async {
      final cubit = ScheduleCubit(
        _Airing(const []),
        _Soon(const []),
        _MyList(),
        retryDelays: const [],
      );
      await cubit.load();
      expect(cubit.state.airingAll, isEmpty);
      expect(cubit.state.errorAiring, isTrue);
      expect(cubit.state.airingSavedAt, isNull);
      await cubit.close();
    });

    test(
      'refresh re-reads the active tracker list only when asked to',
      () async {
        for (final reload in [false, true]) {
          final tracker = _Tracker();
          final cubit = ScheduleCubit(
            _Airing(const []),
            _Soon(const []),
            _MyList(),
            retryDelays: const [],
            trackerHub: TrackerHub([tracker]),
            reloadTrackersOnRefresh: reload,
          );
          await cubit.selectTrackerFilter('AniList');
          expect(tracker.fetchCount, 1);
          await cubit.refresh();
          await Future<void>.delayed(Duration.zero);
          expect(tracker.fetchCount, reload ? 2 : 1);
          // The filter never flashes empty / loading while re-reading.
          expect(
            cubit.state.trackerFollowedByName.containsKey('AniList'),
            isTrue,
          );
          await cubit.close();
        }
      },
    );

    // Reviewer: fetchList() answers [] on network errors, so an offline
    // refresh must not wipe the tracker filter that was already loaded.
    test('a refresh re-read that comes back empty keeps the old list', () async {
      final tracker = _Tracker()
        ..list = const [
          TrackerListItem(
            item: MediaItem(
              id: 'a',
              title: 'Show 1',
              url: 'a',
              type: ProviderType.anime,
              sourceId: 's',
              malId: 1,
            ),
            status: WatchStatus.watching,
          ),
        ];
      final cubit = ScheduleCubit(
        _Airing(const []),
        _Soon(const []),
        _MyList(),
        retryDelays: const [],
        trackerHub: TrackerHub([tracker]),
        reloadTrackersOnRefresh: true,
      );
      await cubit.selectTrackerFilter('AniList');
      expect(cubit.state.trackerFollowedByName['AniList']!.malIds, {1});
      tracker.list = const []; // offline: the read "fails" quietly
      await cubit.refresh();
      await Future<void>.delayed(Duration.zero);
      expect(tracker.fetchCount, 2);
      expect(cubit.state.trackerFollowedByName['AniList']!.malIds, {1});
      await cubit.close();
    });

    // Reviewer: a day change during a running load must still reload.
    test('rollOverDay during a running load queues one more load', () async {
      final gate = Completer<void>();
      final airing = _GatedAiring(gate.future);
      final cubit = ScheduleCubit(
        airing,
        _Soon(const []),
        _MyList(),
        retryDelays: const [],
      );
      final first = cubit.load();
      await Future<void>.delayed(Duration.zero);
      expect(airing.calls, 1);
      cubit.rollOverDay(
        DateTime.now().subtract(const Duration(days: 1)),
      );
      gate.complete();
      await first;
      expect(airing.calls, 2);
      await cubit.close();
    });

    test('an in-app status edit invalidates cached tracker lists', () async {
      final tracker = _Tracker();
      final edits = ValueNotifier<int>(0);
      final cubit = ScheduleCubit(
        _Airing(const []),
        _Soon(const []),
        _MyList(),
        retryDelays: const [],
        trackerHub: TrackerHub([tracker]),
        trackerListChanges: edits,
        trackerInvalidateDelay: Duration.zero,
      );
      await cubit.selectTrackerFilter('AniList');
      expect(tracker.fetchCount, 1);
      edits.value++;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(tracker.fetchCount, 2);
      await cubit.close();
      // Closed: further edits do nothing.
      edits.value++;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(tracker.fetchCount, 2);
    });
  });

  group('offline cache codecs', () {
    test('airing and release rows survive a round trip', () {
      final a = _airing(7, DateTime(2026, 7, 10, 18, 30));
      expect(airingEntryFromMap(airingEntryToMap(a)), a);
      final s = ComingSoonEntry(
        tmdbId: 9,
        isTv: true,
        title: 'Series',
        posterUrl: 'p',
        releaseDate: DateTime(2026, 7, 12),
        episodeLabel: 'S1E2',
        rank: 4,
      );
      expect(comingSoonEntryFromMap(comingSoonEntryToMap(s)), s);
      // Broken rows are skipped, not thrown.
      expect(airingEntryFromMap({'title': 1}), isNull);
      expect(comingSoonEntryFromMap(const {}), isNull);
    });
  });

  group('ScheduleDesktopView', () {
    final today = DateTime(2026, 7, 10);
    DateTime clock() => DateTime(2026, 7, 10, 9);

    // The lists.* day keys come from the shared shortcut catalogue.
    setUp(registerDefaultDesktopShortcuts);

    /// A widget test run as the Windows build (the variant restores the
    /// platform override itself).
    void winTest(String name, WidgetTesterCallback body) => testWidgets(
      name,
      body,
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    Future<_StubCubit> pump(
      WidgetTester tester,
      ScheduleState seed, {
      Size size = const Size(1400, 900),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final cubit = _StubCubit(seed);
      addTearDown(cubit.close);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: BlocProvider<ScheduleCubit>.value(
            value: cubit,
            child: ScheduleDesktopView(now: clock),
          ),
        ),
      );
      await tester.pump();
      return cubit;
    }

    ScheduleState loaded({DateTime? savedAt}) {
      final entries = [_airing(1, DateTime(2026, 7, 10, 12))];
      return ScheduleState(
        loadingAiring: false,
        loadingSoon: false,
        airingAll: entries,
        airingByDay: groupByLocalDay(entries),
        selectedDay: today,
        airingSavedAt: savedAt,
        errorAiring: savedAt != null,
      );
    }

    winTest('a failed load shows an error with Retry, not "Nothing airing"', (
      tester,
    ) async {
      final cubit = await pump(
        tester,
        const ScheduleState(
          loadingAiring: false,
          loadingSoon: false,
          errorAiring: true,
        ),
      );
      expect(find.byKey(const ValueKey('schedule-desktop-error')), findsOne);
      expect(find.text('Nothing airing on this day'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('schedule-desktop-retry')));
      expect(cubit.refreshes, 1);
    });

    winTest('wide window: seven columns, day keys and F5', (tester) async {
      final cubit = await pump(tester, loaded());
      expect(find.byKey(const ValueKey('schedule-desktop-week')), findsOne);
      for (var i = 0; i < 7; i++) {
        expect(find.byKey(ValueKey('schedule-desktop-day-$i')), findsOne);
      }
      expect(find.text('Show 1'), findsOne);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(cubit.state.selectedDay, DateTime(2026, 7, 11));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft); // clamped
      expect(cubit.state.selectedDay, today);
      cubit.selectDay(DateTime(2026, 7, 14));
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      expect(cubit.state.selectedDay, today);
      await tester.sendKeyEvent(LogicalKeyboardKey.f5);
      expect(cubit.refreshes, 1);
      await tester.tap(find.byKey(const ValueKey('schedule-desktop-refresh')));
      expect(cubit.refreshes, 2);
    });

    winTest('narrow window: day list beside the chosen day', (tester) async {
      await pump(tester, loaded(), size: const Size(900, 800));
      expect(find.byKey(const ValueKey('schedule-desktop-split')), findsOne);
      expect(find.byKey(const ValueKey('schedule-desktop-week')), findsNothing);
      // The one-line title carries a full-title tooltip.
      expect(
        find.ancestor(of: find.text('Show 1'), matching: find.byType(Tooltip)),
        findsOne,
      );
    });

    winTest('saved copy shows the offline banner', (tester) async {
      await pump(tester, loaded(savedAt: DateTime(2026, 7, 9, 20)));
      expect(
        find.byKey(const ValueKey('schedule-desktop-saved-copy')),
        findsOne,
      );
      expect(find.text('Show 1'), findsOne);
    });

    // Reviewer: the saved copy shows at once on open, while the live load
    // still runs; the banner must not say the refresh failed yet.
    winTest('saved copy during a running load does not claim a failure', (
      tester,
    ) async {
      await pump(
        tester,
        loaded(savedAt: DateTime(2026, 7, 9, 20)).copyWith(
          loadingAiring: true,
          errorAiring: false,
        ),
      );
      expect(find.textContaining('updating'), findsOne);
      expect(find.textContaining("Couldn't refresh"), findsNothing);
    });

    winTest('right-click on a row opens the desktop row menu', (tester) async {
      await pump(tester, loaded());
      await tester.tap(
        find.text('Show 1'),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(find.text('Copy title'), findsOne);
      expect(find.text('Search sources'), findsOne);
      expect(find.text('Add to My List…'), findsOne);
    });
  });
}
