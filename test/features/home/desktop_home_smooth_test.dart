// Windows Home stays smooth: the whole page is built ahead while the user is
// idle and stays built, shelves keep their own sideways position, and the
// next pictures are loaded with exactly the keys the cards use.
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:watch_app/core/desktop/desktop_memory.dart';
import 'package:watch_app/core/desktop/desktop_picture_warmer.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/metadata/title_logo_service.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/ui/desktop_media_card.dart';
import 'package:watch_app/core/ui/featured_hero.dart';
import 'package:watch_app/core/ui/progressive_artwork.dart';
import 'package:watch_app/features/home/desktop_home_page.dart';
import 'package:watch_app/features/player/desktop_floating_player.dart';
import 'package:watch_app/features/player/player_controller.dart';

final _windows = TargetPlatformVariant.only(TargetPlatform.windows);
final _phone = TargetPlatformVariant.only(TargetPlatform.android);

const _shelves = 14;
const _key = ValueKey('home');

MediaItem _item(String id, {bool art = false}) => MediaItem(
  id: id,
  title: 'Title $id',
  url: 'fixture://$id',
  sourceId: 'fixture',
  type: ProviderType.anime,
  cover: art ? 'https://example.test/cover-$id.jpg' : null,
  banner: art ? 'https://example.test/banner-$id.jpg' : null,
);

List<HomeSection> _sections({
  bool art = false,
  int shelves = _shelves,
  int items = 20,
}) => [
  for (var s = 0; s < shelves; s++)
    HomeSection(
      // Two shelves share a name on purpose.
      title: s == 3 ? 'Shelf 2' : 'Shelf $s',
      items: [
        for (var i = 0; i < items; i++) _item('$s-$i', art: art),
      ],
    ),
];

Widget _page({
  List<HomeSection>? sections,
  List<MediaItem>? featured,
  Key? pageKey,
  List<DesktopHomeRow>? rows,
  bool offline = false,
  bool loading = false,
  VoidCallback? onReconnect,
  ValueChanged<MediaItem>? onOpen,
}) => DesktopHomePage(
  rows: rows,
  offline: offline,
  loading: loading,
  onReconnect: onReconnect,
  key: pageKey,
  featured: featured ?? [_item('hero')],
  sections: sections ?? _sections(),
  resume: const [],
  releases: const [],
  reading: false,
  adaptiveColour: false,
  meta: (_) async => const HeroMeta(description: 'Synopsis'),
  onPlay: (_) {},
  onOpen: onOpen ?? (_) {},
  onMenu: (_) {},
  onSection: (_) {},
  onHistory: () {},
  onReleases: () {},
  onRefresh: () async {},
  playLabel: (_) => 'Play',
);

/// A session the mini player can hold; nothing plays.
class _FakePlayer extends Fake implements mk.Player {
  @override
  late final stream = _FakeStream();
}

class _FakeStream extends Fake implements mk.PlayerStream {
  @override
  Stream<bool> get completed => const Stream.empty();
}

class _FakeSession extends Fake implements PlayerCubit {
  @override
  final mk.Player player = _FakePlayer();
  @override
  set onDesktopMediaStop(VoidCallback? value) {}
  @override
  bool get isClosed => false;
}

/// Title logos that never finish being looked up.
class _FakeLogos extends Fake implements TitleLogoService {
  int waiting = 0;
  @override
  int get posterLogosWaiting => waiting;
}

Widget _app(Widget child) => MaterialApp(home: Scaffold(body: child));

Future<void> _size(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1366, 768));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

void _memory(int mb) {
  DesktopMemory.systemMemoryMb = mb;
  addTearDown(() => DesktopMemory.systemMemoryMb = 0);
}

Finder get _cards => find.byType(DesktopMediaSurface, skipOffstage: false);

Set<State> _cardStates(WidgetTester tester) => {
  for (final e in _cards.evaluate()) (e as StatefulElement).state,
};

double? _extent(WidgetTester tester) => tester
    .widget<CustomScrollView>(
      find.byKey(
        const PageStorageKey('desktop-reference-home'),
        skipOffstage: false,
      ),
    )
    // ignore: deprecated_member_use
    .cacheExtent;

ScrollPosition _position(WidgetTester tester) => tester
    .stateList<ScrollableState>(
      find.byType(Scrollable, skipOffstage: false),
    )
    .firstWhere((s) => s.axisDirection == AxisDirection.down)
    .position;

/// Every sideways list on the page, top to bottom.
List<ScrollPosition> _rows(WidgetTester tester) => [
  for (final s in tester.stateList<ScrollableState>(
    find.byType(Scrollable, skipOffstage: false),
  ))
    if (s.axisDirection == AxisDirection.right) s.position,
];

/// Lets the idle warm-up run for [time] in small steps.
Future<void> _idle(WidgetTester tester, Duration time) async {
  for (var t = Duration.zero; t < time; t += const Duration(milliseconds: 50)) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// One scroll to [target] in frames of 60 pixels.
Future<Set<State>> _scrollTo(WidgetTester tester, double target) async {
  final p = _position(tester);
  final seen = <State>{};
  while ((p.pixels - target).abs() > .5) {
    final left = target - p.pixels;
    p.jumpTo(p.pixels + left.clamp(-60.0, 60.0));
    await tester.pump(const Duration(milliseconds: 16));
    seen.addAll(_cardStates(tester));
  }
  return seen;
}

void main() {
  testWidgets('every shelf is built while idle and stays built', (
    tester,
  ) async {
    await _size(tester);
    _memory(24000);
    await tester.pumpWidget(_app(_page()));
    await tester.pump();
    // Not at once: opening the app must not get slower.
    expect(_extent(tester), desktopHomeCacheExtent);
    final early = _cardStates(tester).length;
    await _idle(tester, const Duration(seconds: 1));
    expect(_extent(tester), desktopHomeCacheExtent);

    await _idle(tester, const Duration(seconds: 8));
    expect(_rows(tester), hasLength(_shelves));
    final built = _cardStates(tester);
    expect(built.length, greaterThan(early));
    // A full scroll down and up again makes and loses no card at all.
    final max = _position(tester).maxScrollExtent;
    final seen = await _scrollTo(tester, max)
      ..addAll(await _scrollTo(tester, 0));
    expect(seen.difference(built), isEmpty);
    expect(_cardStates(tester), built);
    await tester.pumpWidget(const SizedBox());
  }, variant: _windows);

  testWidgets('a warm-up step rebuilds no shelf that is already there', (
    tester,
  ) async {
    await _size(tester);
    _memory(24000);
    await tester.pumpWidget(_app(_page()));
    await tester.pump();
    final cards = _cards.evaluate().first.widget;
    await _idle(tester, const Duration(seconds: 8));
    expect(_rows(tester), hasLength(_shelves));
    // The very same widget object: its shelf was never rebuilt.
    expect(identical(_cards.evaluate().first.widget, cards), isTrue);
    await tester.pumpWidget(const SizedBox());
  }, variant: _windows);

  testWidgets('no step runs while the page is being scrolled', (tester) async {
    await _size(tester);
    _memory(24000);
    await tester.pumpWidget(_app(_page()));
    await tester.pump();
    final p = _position(tester);
    // Keep scrolling past the start delay.
    for (var i = 0; i < 200; i++) {
      p.jumpTo(i.isEven ? 10 : 0);
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(_extent(tester), desktopHomeCacheExtent);
    await _idle(tester, const Duration(seconds: 2));
    expect(_extent(tester), greaterThan(desktopHomeCacheExtent));
    await tester.pumpWidget(const SizedBox());
  }, variant: _windows);

  testWidgets('no step runs on a hidden tab, and it resumes when shown', (
    tester,
  ) async {
    await _size(tester);
    _memory(24000);
    final page = _page();
    Widget tab(bool on) => _app(TickerMode(enabled: on, child: page));
    await tester.pumpWidget(tab(false));
    await _idle(tester, const Duration(seconds: 5));
    expect(_extent(tester), desktopHomeCacheExtent);
    await tester.pumpWidget(tab(true));
    await _idle(tester, const Duration(seconds: 3));
    expect(_extent(tester), greaterThan(desktopHomeCacheExtent));
    await tester.pumpWidget(const SizedBox());
  }, variant: _windows);

  testWidgets('no step runs under another page or dialog, and opening one '
      'rebuilds no shelf', (tester) async {
    await _size(tester);
    _memory(24000);
    await tester.pumpWidget(_app(_page()));
    await tester.pump();
    final card = _cards.evaluate().first.widget;
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(
      showDialog<void>(
        context: nav.context,
        builder: (_) => const Dialog(child: Text('covering')),
      ),
    );
    await _idle(tester, const Duration(seconds: 5));
    expect(_extent(tester), desktopHomeCacheExtent);
    nav.pop();
    await _idle(tester, const Duration(seconds: 4));
    expect(_extent(tester), greaterThan(desktopHomeCacheExtent));
    expect(identical(_cards.evaluate().first.widget, card), isTrue);
    await tester.pumpWidget(const SizedBox());
  }, variant: _windows);

  testWidgets('no step runs while minimised; it resumes afterwards', (
    tester,
  ) async {
    await _size(tester);
    _memory(24000);
    await tester.pumpWidget(_app(_page()));
    await tester.pump();
    for (final s in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
    await tester.pump(const Duration(seconds: 5));
    expect(_extent(tester), desktopHomeCacheExtent);
    for (final s in [
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
    await _idle(tester, const Duration(seconds: 2));
    expect(_extent(tester), greaterThan(desktopHomeCacheExtent));
    await tester.pumpWidget(const SizedBox());
  }, variant: _windows);

  testWidgets('8 GB and unknown PCs build at most two screens ahead', (
    tester,
  ) async {
    await _size(tester);
    for (final mb in [0, 8192]) {
      _memory(mb);
      await tester.pumpWidget(_app(_page(pageKey: ValueKey(mb))));
      await _idle(tester, const Duration(seconds: 8));
      expect(_extent(tester), 768 * 2, reason: '$mb MB');
      expect(_rows(tester).length, lessThan(_shelves), reason: '$mb MB');
    }
    await tester.pumpWidget(const SizedBox());
  }, variant: _windows);

  testWidgets('rows that arrive later are built ahead too', (tester) async {
    await _size(tester);
    _memory(24000);
    await tester.pumpWidget(_app(_page(sections: _sections(shelves: 4))));
    await _idle(tester, const Duration(seconds: 5));
    await tester.pumpWidget(_app(_page()));
    await _idle(tester, const Duration(seconds: 6));
    expect(_rows(tester), hasLength(_shelves));
    await tester.pumpWidget(const SizedBox());
  }, variant: _windows);

  testWidgets('phone keeps the default build-ahead and no keys', (
    tester,
  ) async {
    await _size(tester);
    _memory(24000);
    await tester.pumpWidget(_app(_page()));
    await _idle(tester, const Duration(seconds: 5));
    expect(_extent(tester), isNull);
    for (final list in tester.widgetList<ListView>(find.byType(ListView))) {
      expect(list.key, isNull);
    }
    await tester.pumpWidget(const SizedBox());
  }, variant: _phone);

  testWidgets('a shelf built while scrolling starts at its own place', (
    tester,
  ) async {
    await _size(tester);
    await tester.pumpWidget(_app(_page()));
    await tester.pump();
    await _scrollTo(tester, _position(tester).maxScrollExtent);
    await _scrollTo(tester, 0);
    for (final row in _rows(tester)) {
      expect(row.pixels, 0);
    }
    // Move the second "Shelf 2": it keeps its place, the first one its own.
    await _scrollTo(tester, 900);
    ScrollPosition rowOf(String id) => Scrollable.of(
      tester.element(find.text('Title $id', skipOffstage: false)),
    ).position;
    rowOf('3-0').jumpTo(300);
    await tester.pump();
    await _scrollTo(tester, _position(tester).maxScrollExtent);
    expect(find.text('Title 3-0', skipOffstage: false), findsNothing);
    await _scrollTo(tester, 900);
    expect(rowOf('3-3').pixels, 300);
    expect(rowOf('2-0').pixels, 0);
    await tester.pumpWidget(const SizedBox());
  }, variant: _windows);

  group('once everything is built', () {
    /// Home with every shelf built ahead.
    Future<void> warm(
      WidgetTester tester, {
      List<HomeSection>? sections,
      List<DesktopHomeRow>? rows,
    }) async {
      await _size(tester);
      _memory(24000);
      await tester.pumpWidget(
        _app(_page(pageKey: _key, sections: sections, rows: rows)),
      );
      await _idle(tester, const Duration(seconds: 8));
      expect(_rows(tester).length, greaterThanOrEqualTo(_shelves));
    }

    /// How many cards [change] builds again.
    Future<int> rebuilt(
      WidgetTester tester,
      Future<void> Function() change,
    ) async {
      final before = {for (final e in _cards.evaluate()) e.widget};
      await change();
      return _cards
          .evaluate()
          .where((e) => !before.contains(e.widget))
          .length;
    }

    testWidgets('a row arriving on top keeps every card', (tester) async {
      await warm(tester);
      final before = _cardStates(tester);
      final added = HomeSection(
        title: 'Continue on tracker',
        items: [for (var i = 0; i < 20; i++) _item('new-$i')],
      );
      await tester.pumpWidget(
        _app(_page(pageKey: _key, sections: [added, ..._sections()])),
      );
      expect(_cardStates(tester).containsAll(before), isTrue);
      expect(find.text('Title new-0'), findsOneWidget);
      // And it leaving again.
      await tester.pumpWidget(_app(_page(pageKey: _key)));
      expect(_cardStates(tester), before);
      await tester.pumpWidget(const SizedBox());
    }, variant: _windows);

    testWidgets('the reconnect notice and another row order keep every card', (
      tester,
    ) async {
      await warm(tester);
      final before = _cardStates(tester);
      expect(
        await rebuilt(
          tester,
          () => tester.pumpWidget(
            _app(_page(pageKey: _key, onReconnect: () {})),
          ),
        ),
        0,
      );
      expect(_cardStates(tester), before);
      await tester.pumpWidget(_app(_page(pageKey: _key)));
      final turned = _sections().reversed.toList();
      await tester.pumpWidget(_app(_page(pageKey: _key, sections: turned)));
      // Every shelf is the same one, at another place. (The two that share a
      // name count as each other, so only those get other titles.)
      expect(_cardStates(tester).containsAll(before), isTrue);
      await tester.pumpWidget(const SizedBox());
    }, variant: _windows);

    testWidgets('a refresh with the same titles rebuilds no card', (
      tester,
    ) async {
      await warm(tester);
      for (final loading in [true, false]) {
        expect(
          await rebuilt(
            tester,
            () => tester.pumpWidget(
              _app(_page(pageKey: _key, loading: loading)),
            ),
          ),
          0,
        );
      }
      await tester.pumpWidget(const SizedBox());
    }, variant: _windows);

    testWidgets('one changed shelf rebuilds only that shelf, and clicks use '
        'the newest data', (tester) async {
      final old = <MediaItem>[], fresh = <MediaItem>[];
      var sections = _sections();
      List<DesktopHomeRow> rows(List<MediaItem> opened, {String tag = '+1'}) =>
          [
            for (final s in sections)
              DesktopHomeRow.shelf(
                s,
                onOpen: opened.add,
                tagsFor: s.title == 'Shelf 1' ? (_) => [tag] : null,
              ),
          ];
      await warm(tester, rows: rows(old));
      final drawn = sections.first.items.first;
      sections = _sections();
      Future<void> pump(List<DesktopHomeRow> r) =>
          tester.pumpWidget(_app(_page(pageKey: _key, rows: r)));
      expect(await rebuilt(tester, () => pump(rows(fresh))), 0);
      await tester.tap(find.byType(DesktopMediaSurface).first);
      expect(old, isEmpty);
      expect(identical(fresh.single, sections.first.items.first), isTrue);
      expect(identical(fresh.single, drawn), isFalse);
      // New badges on one shelf (about nine cards are built per shelf).
      expect(
        await rebuilt(tester, () => pump(rows(fresh, tag: '+2'))),
        inInclusiveRange(7, 10),
      );
      expect(find.text('+2', skipOffstage: false), findsWidgets);
      expect(find.text('+1', skipOffstage: false), findsNothing);
      await tester.pumpWidget(const SizedBox());
    }, variant: _windows);

    testWidgets('going offline and back builds only what is near', (
      tester,
    ) async {
      await warm(tester);
      await tester.pumpWidget(_app(_page(pageKey: _key, offline: true)));
      expect(_cards, findsNothing);
      await tester.pumpWidget(_app(_page(pageKey: _key)));
      expect(_extent(tester), desktopHomeCacheExtent);
      expect(_cards.evaluate().length, lessThan(50));
      await _idle(tester, const Duration(seconds: 8));
      expect(_rows(tester), hasLength(_shelves));
      await tester.pumpWidget(const SizedBox());
    }, variant: _windows);

    testWidgets('rows that empty and come back build only what is near', (
      tester,
    ) async {
      await warm(tester);
      await tester.pumpWidget(
        _app(_page(pageKey: _key, sections: const [], featured: const [])),
      );
      await tester.pumpWidget(_app(_page(pageKey: _key)));
      expect(_cards.evaluate().length, lessThan(50));
      await tester.pumpWidget(const SizedBox());
    }, variant: _windows);

    testWidgets('a whole new catalogue builds only what is near', (
      tester,
    ) async {
      await warm(tester);
      final other = [
        for (var s = 0; s < _shelves; s++)
          HomeSection(
            title: 'Shelf $s',
            items: [for (var i = 0; i < 20; i++) _item('other-$s-$i')],
          ),
      ];
      await tester.pumpWidget(_app(_page(pageKey: _key, sections: other)));
      expect(_extent(tester), desktopHomeCacheExtent);
      expect(_cards.evaluate().length, lessThan(50));
      await _idle(tester, const Duration(seconds: 8));
      expect(_rows(tester), hasLength(_shelves));
      await tester.pumpWidget(const SizedBox());
    }, variant: _windows);

    testWidgets('resizing the window lays out only what is near, then builds '
        'the rest again', (tester) async {
      await warm(tester);
      for (var width = 1366.0; width > 1300; width -= 10) {
        await tester.binding.setSurfaceSize(Size(width - 10, 768));
        await tester.pump();
        expect(_extent(tester), desktopHomeCacheExtent);
        expect(_cards.evaluate().length, lessThan(50));
      }
      await _idle(tester, const Duration(seconds: 8));
      expect(_rows(tester), hasLength(_shelves));
      await tester.pumpWidget(const SizedBox());
    }, variant: _windows);
  });

  testWidgets('nothing is built ahead until Home has loaded', (tester) async {
    await _size(tester);
    _memory(24000);
    await tester.pumpWidget(_app(_page(pageKey: _key, loading: true)));
    await _idle(tester, const Duration(seconds: 5));
    expect(_extent(tester), desktopHomeCacheExtent);
    await tester.pumpWidget(_app(_page(pageKey: _key)));
    await _idle(tester, const Duration(seconds: 2));
    expect(_extent(tester), greaterThan(desktopHomeCacheExtent));
    await tester.pumpWidget(const SizedBox());
  }, variant: _windows);

  testWidgets('nothing is built ahead while the mini player floats', (
    tester,
  ) async {
    await _size(tester);
    _memory(24000);
    final host = DesktopFloatingPlayer.instance;
    addTearDown(host.debugReset);
    await host.adopt(
      FloatingPlayback(
        cubit: _FakeSession(),
        reopen: (_) => const SizedBox(),
      ),
    );
    await tester.pumpWidget(_app(_page()));
    await _idle(tester, const Duration(seconds: 5));
    expect(_extent(tester), desktopHomeCacheExtent);
    host.takeForExpand();
    await _idle(tester, const Duration(seconds: 2));
    expect(_extent(tester), greaterThan(desktopHomeCacheExtent));
    await tester.pumpWidget(const SizedBox());
  }, variant: _windows);

  testWidgets('title logos being looked up hold the next step back', (
    tester,
  ) async {
    await _size(tester);
    _memory(24000);
    await sl.reset();
    final logos = _FakeLogos()..waiting = 40;
    sl.registerSingleton<TitleLogoService>(logos);
    addTearDown(sl.reset);
    await tester.pumpWidget(_app(_page()));
    await _idle(tester, const Duration(seconds: 6));
    expect(_extent(tester), desktopHomeCacheExtent);
    logos.waiting = 0;
    await _idle(tester, const Duration(seconds: 2));
    expect(_extent(tester), greaterThan(desktopHomeCacheExtent));
    await tester.pumpWidget(const SizedBox());
  }, variant: _windows);

  group('pictures', () {
    late ui.Image image;

    setUp(() async {
      image = await createTestImage(width: 20, height: 30, cache: false);
    });

    /// Puts a ready picture in the image cache for [provider].
    void fill(ImageProvider provider) {
      Object? key;
      provider.obtainKey(ImageConfiguration.empty).then((k) => key = k);
      PaintingBinding.instance.imageCache.putIfAbsent(
        key!,
        () => OneFrameImageStreamCompleter(
          SynchronousFuture(ImageInfo(image: image.clone())),
        ),
      );
    }

    bool live(ImageProvider provider) {
      Object? key;
      provider.obtainKey(ImageConfiguration.empty).then((k) => key = k);
      return PaintingBinding.instance.imageCache.statusForKey(key!).live;
    }

    List<ImageProvider> shown(WidgetTester tester) => [
      for (final a in tester.widgetList<ProgressiveArtwork>(
        find.byType(ProgressiveArtwork, skipOffstage: false),
      ))
        a.full ?? a.preview,
    ];

    testWidgets('a shelf scrolled away keeps its pictures decoded', (
      tester,
    ) async {
      await _size(tester);
      _memory(24000);
      addTearDown(PaintingBinding.instance.imageCache.clear);
      // Learn every picture the page asks for, then run it with them ready.
      final sections = _sections(art: true, items: 9);
      for (final section in sections) {
        for (final item in section.items) {
          fill(_posterOf(item, _cellWidth));
        }
      }
      await tester.pumpWidget(
        _app(_page(sections: sections, featured: const [])),
      );
      await _idle(tester, const Duration(seconds: 9));
      expect(_rows(tester), hasLength(_shelves));
      final first = shown(tester).first;
      expect(live(first), isTrue);
      await _scrollTo(tester, _position(tester).maxScrollExtent);
      // Even if the cache drops what it may, the far shelf still holds its
      // pictures, so coming back decodes nothing again.
      PaintingBinding.instance.imageCache.clear();
      expect(live(first), isTrue);
      await tester.pumpWidget(const SizedBox());
    }, variant: _windows);

    testWidgets('the next banner and second screen load ahead with the very '
        'pictures the page then draws', (tester) async {
      await _size(tester);
      _memory(24000);
      final loaded = <ImageProvider>[];
      DesktopPictureWarmer.debugOnLoad = loaded.add;
      addTearDown(() => DesktopPictureWarmer.debugOnLoad = null);
      addTearDown(PaintingBinding.instance.imageCache.clear);
      final sections = _sections(art: true, shelves: 3);
      // The first cards of each shelf are already there.
      for (final section in sections) {
        for (final item in section.items.take(10)) {
          fill(_posterOf(item, _cellWidth));
        }
      }
      await tester.pumpWidget(
        _app(
          _page(
            sections: sections,
            featured: [_item('a', art: true), _item('b', art: true)],
          ),
        ),
      );
      final p = _position(tester);
      await _idle(tester, const Duration(seconds: 6));
      expect(loaded, isNotEmpty);
      final firstLoaded = loaded.first;
      // Scrolling pauses it.
      final before = loaded.length;
      for (var i = 0; i < 100; i++) {
        p.jumpTo(i.isEven ? 10 : 0);
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(loaded.length, lessThanOrEqualTo(before + 1));
      // No picture ever arrives in a test, so each one takes its full wait.
      for (var i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      // Second screen of each shelf, seven cards, minus the ones held.
      final wanted = [
        for (final section in sections)
          for (final item in section.items.skip(10).take(4))
            _posterOf(item, _cellWidth),
      ];
      expect(loaded, containsAll(wanted));
      expect(
        loaded,
        isNot(contains(_posterOf(sections.first.items[14], _cellWidth))),
      );
      // The banner really asks for that picture when it comes round.
      await tester.tap(
        find.byKey(const ValueKey('desktop-home-feature-dot-1')),
      );
      await tester.pump();
      final hero = tester.widget<ProgressiveArtwork>(
        find.descendant(
          of: find.byKey(const ValueKey('desktop-home-feature-art')),
          matching: find.byType(ProgressiveArtwork),
        ),
      );
      expect(firstLoaded, hero.full ?? hero.preview);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    }, variant: _windows);

    testWidgets('a new window size loads the pictures in the new size, and a '
        'minimise asks again for what was dropped', (tester) async {
      await _size(tester);
      _memory(24000);
      final loaded = <ImageProvider>[];
      DesktopPictureWarmer.debugOnLoad = loaded.add;
      addTearDown(() => DesktopPictureWarmer.debugOnLoad = null);
      addTearDown(PaintingBinding.instance.imageCache.clear);
      final sections = _sections(art: true, shelves: 2);
      Future<void> settle() async {
        for (var i = 0; i < 400; i++) {
          await tester.pump(const Duration(milliseconds: 500));
        }
      }

      await tester.pumpWidget(
        _app(_page(sections: sections, featured: const [])),
      );
      // Nothing ever arrives in a test: warm only a first few of them.
      await _idle(tester, const Duration(seconds: 12));
      expect(loaded, isNotEmpty);
      await tester.binding.setSurfaceSize(const Size(1200, 768));
      await tester.pump();
      loaded.clear();
      await settle();
      const cell = (1200 - 32 - 6 * 12) / 7;
      expect(loaded, contains(_posterOf(sections[1].items[13], cell)));
      expect(
        loaded,
        isNot(contains(_posterOf(sections[1].items[13], _cellWidth))),
      );
      // Dropped while minimised: asked for again afterwards.
      loaded.clear();
      await settle();
      expect(loaded, isEmpty);
      for (final s in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      for (final s in [
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await settle();
      expect(loaded, contains(_posterOf(sections[1].items[13], cell)));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    }, variant: _windows);

    testWidgets('8 GB PCs load no pictures ahead', (tester) async {
      await _size(tester);
      _memory(8192);
      final loaded = <ImageProvider>[];
      DesktopPictureWarmer.debugOnLoad = loaded.add;
      addTearDown(() => DesktopPictureWarmer.debugOnLoad = null);
      await tester.pumpWidget(_app(_page(sections: _sections(shelves: 2))));
      await _idle(tester, const Duration(seconds: 6));
      expect(loaded, isEmpty);
      await tester.pumpWidget(const SizedBox());
    }, variant: _windows);

    testWidgets('the preload uses exactly the keys the cards and the banner '
        'ask for', (tester) async {
      await _size(tester);
      await tester.pumpWidget(
        _app(
          _page(
            sections: _sections(art: true, shelves: 1, items: 2),
            featured: [_item('a', art: true), _item('b', art: true)],
          ),
        ),
      );
      await tester.pump();
      final arts = tester
          .widgetList<DesktopMediaArtwork>(find.byType(DesktopMediaArtwork))
          .toList();
      final hero = arts.firstWhere(
        (a) => a.key == const ValueKey('desktop-home-feature-art'),
      );
      // 1366 wide: 16 px page padding each side and the 1 px panel outline.
      final expected = desktopHeroArtwork(
        _item('a', art: true),
        wideArt: 'https://example.test/banner-a.jpg',
        panelWidth: 1366 - 32 - 2,
      );
      expect(hero.width, expected.width);
      expect(hero.url, expected.url);
      expect(hero.headers, expected.headers);
      expect(hero.backdrop, expected.backdrop);
      expect(hero.maxDecodeWidth, expected.maxDecodeWidth);
      expect(hero.fitWhole, expected.fitWhole);
      final card = arts.firstWhere((a) => a.url!.contains('cover-0-0'));
      expect(card.width, closeTo(_cellWidth, 1e-9));
      final drawn = tester
          .widget<ProgressiveArtwork>(
            find.descendant(
              of: find.byWidget(card),
              matching: find.byType(ProgressiveArtwork),
            ),
          );
      expect(
        drawn.full ?? drawn.preview,
        _posterOf(_item('0-0', art: true), _cellWidth),
      );
      await tester.pumpWidget(const SizedBox());
    }, variant: _windows);
  });
}

/// Width of a shelf card on a 1366 px wide page (seven per screen).
const _cellWidth = (1366 - 32 - 6 * 12) / 7;

ImageProvider _posterOf(MediaItem item, double width) {
  final art = desktopArtworkFor(
    url: item.cover!,
    headers: item.coverHeaders,
    width: width,
    devicePixelRatio: 3,
  );
  return art.full ?? art.preview;
}
