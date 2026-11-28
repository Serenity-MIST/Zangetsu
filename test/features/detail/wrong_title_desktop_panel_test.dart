// Windows "Wrong title?" panel (ar-4 / ar-5), its Undo toast (ar-7 A) and
// the Manual matches page (ar-7 B).
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/media_detail.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/playback/source_health_store.dart';
import 'package:watch_app/core/playback/title_prefs.dart';
import 'package:watch_app/core/repository/catalogue_repository.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/zmode/match_store.dart';
import 'package:watch_app/core/zmode/source_matcher.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/core/zmode/zmode_source_prefs.dart';
import 'package:watch_app/features/detail/cubit/detail_cubit.dart';
import 'package:watch_app/features/detail/wrong_title_sheet.dart';
import 'package:watch_app/features/settings/manual_matches_screen.dart';

import '../../support/picker_deps.dart';

/// Source fake answering both the plain search (used by the matcher) and
/// the status-aware search (used by the Windows panel).
class _Src implements SourceRepository {
  _Src(this.bySource, {this.outcomes = const {}, this.page2 = const {}});
  final Map<String, List<MediaItem>> bySource;

  /// Second page of results per source ("Load more").
  final Map<String, List<MediaItem>> page2;

  /// Forced status-aware outcome per source (e.g. blocked).
  final Map<String, SourceOutcome> outcomes;

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  Future<bool> ensureSourceLoaded(String sourceId) async => true;
  @override
  List<({String id, String name})> get pickableSources => loadedSources;
  @override
  String baseUrlFor(String id) => 'https://example.test';
  @override
  List<({String id, String name})> get loadedSources => [
    for (final id in bySource.keys) (id: id, name: displayName(id)),
  ];
  @override
  bool hasSource(String sourceId) => bySource.containsKey(sourceId);
  @override
  String displayName(String id) =>
      (id == 'ani:1' || id == 'mihon:1') ? 'AllAnime' : 'HiAnime';
  @override
  Future<List<MediaItem>> search(
    String q, {
    String category = 'sub',
    String? sourceId,
  }) async => bySource[sourceId] ?? const [];
  @override
  Future<({List<MediaItem> items, SourceOutcome outcome})> searchStatus(
    String query, {
    String category = 'sub',
    String? sourceId,
    String? filtersJson,
    bool cache = false,
    int page = 1,
  }) async {
    final forced = outcomes[sourceId];
    if (forced != null) return (items: const <MediaItem>[], outcome: forced);
    final items = page == 1
        ? bySource[sourceId] ?? const <MediaItem>[]
        : page == 2
        ? page2[sourceId] ?? const <MediaItem>[]
        : const <MediaItem>[];
    return (
      items: items,
      outcome: items.isEmpty ? SourceOutcome.empty : SourceOutcome.ok,
    );
  }
}

/// Minimal catalogue so MatchLine's refresh has a DetailCubit to call.
class _Repo implements CatalogueRepository {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  Future<bool> ensureSourceLoaded(String sourceId) async => true;
  @override
  Future<void> clearHttpCache() async {}
  @override
  Future<MediaDetail> detail(
    String url, {
    String category = 'sub',
    String? sourceId,
    void Function(MediaDetail partial)? onPartial,
    bool Function()? abandoned,
  }) async => const MediaDetail(
    id: 'x',
    title: 'x',
    url: 'zm://anime/mal:5114',
    type: ProviderType.anime,
    sourceId: 'zm',
  );
}

class _FakeTitlePrefs extends TitlePrefsStore {
  @override
  String? category(String s, String u) => null;
  @override
  Future<void> setCategory(String s, String u, String c) async {}
}

MediaItem _item(String id, String title, String src) => MediaItem(
  id: id,
  title: title,
  url: 'https://$src/$id',
  type: ProviderType.anime,
  sourceId: src,
);

void main() {
  late Directory dir;
  const fma = ZCanonical(ZKind.anime, 'mal:5114');

  Widget harness(Widget child) => MaterialApp(
    home: Scaffold(
      body: BlocProvider(
        create: (_) => DetailCubit(
          repo: _Repo(),
          url: 'zm://anime/mal:5114',
          prefs: _FakeTitlePrefs(),
        ),
        child: child,
      ),
    ),
  );

  Future<void> register(_Src src) async {
    await registerPickerDeps(
      aniyomi: [
        aniSource(id: 1, name: 'AllAnime'),
        aniSource(id: 2, name: 'HiAnime'),
      ],
    );
    for (final ch in const ['zangetsu/aniyomi', 'zangetsu/mihon']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            MethodChannel(ch),
            (call) async => call.method == 'hasSourceSettings' ? false : null,
          );
    }
    final store = await MatchStore.open();
    final prefs = await ZSourcePrefs.open();
    sl.registerSingleton<SourceRepository>(src);
    sl.registerSingleton<MatchStore>(store);
    sl.registerSingleton<ZSourcePrefs>(prefs);
    sl.registerSingleton<SourceMatcher>(
      SourceMatcher(
        sources: src,
        store: store,
        prefs: prefs,
        candidates: (_) => src.loadedSources,
      ),
    );
  }

  // Hive's file I/O never completes inside the fake-async test zone, so the
  // stores are opened under runAsync.
  Future<void> registerAsync(WidgetTester t, _Src src) async {
    await t.runAsync(() => register(src));
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('wrongtitle_panel');
    Hive.init(dir.path);
  });
  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await disposePickerDeps();
    await sl.reset();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  testWidgets(
    'Windows: side panel, keyboard pick, then Undo restores the old match',
    (t) async {
      await registerAsync(
        t,
        _Src({
          'ani:1': [
            _item('fma03', 'Fullmetal Alchemist (2003)', 'ani:1'),
            _item('fmab', 'Fullmetal Alchemist: Brotherhood', 'ani:1'),
          ],
        }),
      );
      await t.runAsync(
        () => sl<SourceMatcher>().resolve(
          fma,
          title: 'Fullmetal Alchemist (2003)',
        ),
      );
      final before = sl<MatchStore>().get(fma, 'ani:1');
      expect(before?.showId, 'fma03');
      expect(before?.pinned, isFalse);

      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await t.pumpWidget(
        harness(
          const MatchLine(canonical: fma, title: 'Fullmetal Alchemist (2003)'),
        ),
      );
      await t.pumpAndSettle();

      await t.tap(find.text('Wrong title?'));
      await t.pumpAndSettle();
      // Docked beside the page rather than a phone bottom sheet.
      expect(
        find.byKey(const ValueKey('desktop-docked-panel')),
        findsOneWidget,
      );
      expect(find.byType(BottomSheet), findsNothing);
      expect(
        find.byKey(const ValueKey('wrong-title-result-1')),
        findsOneWidget,
      );

      // Down from the (autofocused) search field lands on the first
      // result, Right moves to the second and Enter picks it.
      String? focused() => FocusManager.instance.primaryFocus?.debugLabel;
      expect(focused(), 'wrong-title-field');
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.pump();
      expect(focused(), 'wrong-title-first');
      // Up on the top row goes back to the search box, Down returns.
      await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await t.pump();
      expect(focused(), 'wrong-title-field');
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.pump();
      expect(focused(), 'wrong-title-result-1');
      await t.runAsync(() async {
        await t.sendKeyEvent(LogicalKeyboardKey.enter);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await t.pumpAndSettle();
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await t.pump();

      final pinned = sl<MatchStore>().get(fma, 'ani:1');
      expect(pinned?.showId, 'fmab');
      expect(pinned?.pinned, isTrue);
      expect(sl<MatchStore>().titleFor(fma), 'Fullmetal Alchemist (2003)');
      expect(find.text('Undo'), findsOneWidget);

      await t.runAsync(() async {
        await t.tap(find.text('Undo'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await t.pumpAndSettle();
      final restored = sl<MatchStore>().get(fma, 'ani:1');
      expect(restored?.showId, 'fma03');
      expect(restored?.pinned, isFalse);

      // Let any remaining toast timer run out.
      await t.pump(const Duration(seconds: 7));
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('Windows: a blocked source says so and offers Retry', (t) async {
    await registerAsync(
      t,
      _Src(
        {
          'ani:1': [_item('fma03', 'Fullmetal Alchemist (2003)', 'ani:1')],
        },
        outcomes: {'ani:1': SourceOutcome.blocked},
      ),
    );
    await t.runAsync(
      () =>
          sl<SourceMatcher>().resolve(fma, title: 'Fullmetal Alchemist (2003)'),
    );
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await t.pumpWidget(
      harness(
        const MatchLine(canonical: fma, title: 'Fullmetal Alchemist (2003)'),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('Wrong title?'));
    await t.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('wrong-title-failure-blocked')),
      findsOneWidget,
    );
    expect(find.textContaining('Cloudflare'), findsOneWidget);
    expect(find.byKey(const ValueKey('wrong-title-retry')), findsOneWidget);
    // Not the "this source may not carry it" of a real empty answer.
    expect(find.text('Choose a source'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  // ar-6: the panel offers "Load more" after a full first page and appends
  // the next page to the grid; once a page adds nothing, the button goes.
  testWidgets('Windows: Load more appends the next page', (t) async {
    await registerAsync(
      t,
      _Src(
        {
          'ani:1': [_item('fma03', 'Fullmetal Alchemist (2003)', 'ani:1')],
        },
        page2: {
          'ani:1': [_item('fmab', 'Fullmetal Alchemist: Brotherhood', 'ani:1')],
        },
      ),
    );
    await t.runAsync(
      () =>
          sl<SourceMatcher>().resolve(fma, title: 'Fullmetal Alchemist (2003)'),
    );
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await t.pumpWidget(
      harness(
        const MatchLine(canonical: fma, title: 'Fullmetal Alchemist (2003)'),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('Wrong title?'));
    await t.pumpAndSettle();

    expect(find.byKey(const ValueKey('wrong-title-result-1')), findsNothing);
    final more = find.byKey(const ValueKey('wrong-title-load-more'));
    expect(more, findsOneWidget);
    await t.tap(more);
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('wrong-title-result-1')), findsOneWidget);
    // Page 2 added a result, so one more page is offered; page 3 is empty
    // and ends paging.
    await t.tap(find.byKey(const ValueKey('wrong-title-load-more')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('wrong-title-load-more')), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Manual matches lists pins and resets them to Auto', (t) async {
    await registerAsync(t, _Src({'ani:1': const [], 'ani:2': const []}));
    const other = ZCanonical(ZKind.anime, 'mal:1');
    await t.runAsync(() async {
      final store = sl<MatchStore>();
      await store.pin(
        fma,
        const SourceMatch(
          sourceId: 'ani:1',
          showUrl: '/fma',
          showId: 'fma',
          showTitle: 'FMA on AllAnime',
          pinned: true,
        ),
      );
      await store.rememberTitle(fma, 'Fullmetal Alchemist');
      await store.pin(
        other,
        const SourceMatch(
          sourceId: 'ani:2',
          showUrl: '/bleach',
          showId: 'bleach',
          showTitle: 'Bleach',
          pinned: true,
        ),
      );
    });
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await t.pumpWidget(const MaterialApp(home: ManualMatchesScreen()));
    await t.pumpAndSettle();

    expect(find.text('Fullmetal Alchemist'), findsOneWidget);
    expect(find.text('AllAnime · FMA on AllAnime'), findsOneWidget);
    expect(find.text('Bleach'), findsOneWidget);

    // Search narrows the list.
    await t.enterText(
      find.byKey(const ValueKey('manual-matches-search')),
      'bleach',
    );
    await t.pumpAndSettle();
    expect(find.text('Fullmetal Alchemist'), findsNothing);
    await t.enterText(find.byKey(const ValueKey('manual-matches-search')), '');
    await t.pumpAndSettle();

    // Select the FMA row and reset it.
    await t.tap(find.text('Fullmetal Alchemist'));
    await t.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    await t.runAsync(() async {
      await t.tap(find.byKey(const ValueKey('manual-matches-reset')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await t.pumpAndSettle();
    expect(sl<MatchStore>().pinnedFor(fma), isNull);
    expect(sl<MatchStore>().pinnedFor(other)?.showId, 'bleach');
    expect(find.text('Fullmetal Alchemist'), findsNothing);
    await t.pump(const Duration(seconds: 7));
    debugDefaultTargetPlatformOverride = null;
  });
}
