// Windows-only Home behaviour from the home-page group: cursor menus
// (home-1), shelf arrows (home-2), banner controls and auto-rotate (home-5),
// "New from your list" rows (home-7 contract), keyboard shortcuts (home-9),
// downloads "See all" (home-12) and full-title tooltips (home-13).
import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/desktop_row_scroller.dart';
import 'package:watch_app/core/desktop/desktop_shortcut_catalog.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/ui/desktop_media_card.dart';
import 'package:watch_app/core/ui/featured_hero.dart';
import 'package:watch_app/features/home/desktop_home_page.dart';

/// Runs a test body with the target platform pretending to be Windows.
final _windows = TargetPlatformVariant.only(TargetPlatform.windows);

MediaItem _item(int i) => MediaItem(
  id: 'item-$i',
  title: 'Featured title number $i with a long name',
  url: 'fixture://$i',
  sourceId: 'fixture',
  type: ProviderType.anime,
);

/// Builds the desktop Home with fixture data; counters go through callbacks.
Widget _home({
  List<MediaItem>? featured,
  List<DesktopHomeRelease> releases = const [],
  List<DesktopHomeResume> resume = const [],
  List<DesktopHomeDownload> downloads = const [],
  bool offline = false,
  Future<void> Function()? onRefresh,
  int sectionItems = 3,
}) => MaterialApp(
  home: MediaQuery(
    data: const MediaQueryData(size: Size(1366, 900)),
    child: Scaffold(
      body: DesktopHomePage(
        featured: featured ?? [_item(0), _item(1), _item(2)],
        sections: [
          HomeSection(
            title: 'Trending this week',
            items: [for (var i = 0; i < sectionItems; i++) _item(10 + i)],
          ),
        ],
        resume: resume,
        releases: releases,
        downloads: downloads,
        offline: offline,
        reading: false,
        meta: (_) async => const HeroMeta(description: 'Synopsis'),
        onPlay: (_) {},
        onOpen: (_) {},
        onMenu: (_) {},
        onSection: (_) {},
        onHistory: () {},
        onReleases: () {},
        onRefresh: onRefresh ?? () async {},
        playLabel: (_) => 'Play',
      ),
    ),
  ),
);

String _featureTitle(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey('desktop-home-feature-title')))
    .data!;

void main() {
  // The page reads its keys from the shared shortcut catalogue.
  setUpAll(registerDefaultDesktopShortcuts);

  testWidgets('home-1: Home menu opens at the cursor, not as a dialog', (
    tester,
  ) async {
    var ran = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDesktopHomeMenu(
                context,
                title: 'Fixture',
                actions: [
                  (label: 'Details', icon: 'info', run: () => ran++),
                  (label: 'Add to list', icon: 'bookmark', run: () {}),
                ],
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(find.text('Add to list'), findsOneWidget);
    // The context menu has no title row.
    expect(find.text('Fixture'), findsNothing);
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    expect(ran, 1);
    expect(find.text('Add to list'), findsNothing);
  }, variant: _windows);

  testWidgets('home-1: other platforms keep the centred dialog', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDesktopHomeMenu(
                context,
                title: 'Fixture',
                actions: [(label: 'Details', icon: 'info', run: () {})],
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('Fixture'), findsOneWidget);
  });

  testWidgets('home-2: shelves get hover arrows on Windows only', (
    tester,
  ) async {
    await tester.pumpWidget(_home(sectionItems: 12));
    await tester.pumpAndSettle();
    expect(find.byType(DesktopRowScroller), findsWidgets);
    final shelf = find
        .ancestor(
          of: find.byKey(
            const ValueKey('desktop-home-poster-Trending this week-0'),
          ),
          matching: find.byType(DesktopRowScroller),
        )
        .first;
    await tester.ensureVisible(shelf);
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(shelf));
    await tester.pumpAndSettle();
    // At the start of a long row only the forward arrow is offered.
    final arrows = find.descendant(
      of: shelf,
      matching: find.byType(AnimatedOpacity),
    );
    final opacities = [
      for (final e in arrows.evaluate()) (e.widget as AnimatedOpacity).opacity,
    ];
    expect(opacities, [0, 1]);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox());
  }, variant: _windows);

  testWidgets('home-2: phone shelves have no arrows', (tester) async {
    await tester.pumpWidget(_home());
    await tester.pumpAndSettle();
    expect(find.byType(DesktopRowScroller), findsNothing);
  });

  testWidgets('home-5: Previous, Next and dots step through features', (
    tester,
  ) async {
    await tester.pumpWidget(_home());
    await tester.pump();
    final first = _featureTitle(tester);
    expect(first, _item(0).title);
    await tester.tap(find.byKey(const ValueKey('desktop-home-feature-next')));
    await tester.pump();
    expect(_featureTitle(tester), _item(1).title);
    await tester.tap(
      find.byKey(const ValueKey('desktop-home-feature-previous')),
    );
    await tester.pump();
    expect(_featureTitle(tester), _item(0).title);
    // Previous wraps around to the last title.
    await tester.tap(
      find.byKey(const ValueKey('desktop-home-feature-previous')),
    );
    await tester.pump();
    expect(_featureTitle(tester), _item(2).title);
    await tester.tap(find.byKey(const ValueKey('desktop-home-feature-dot-1')));
    await tester.pump();
    expect(_featureTitle(tester), _item(1).title);
    await tester.pumpWidget(const SizedBox());
  }, variant: _windows);

  testWidgets('home-5: banner auto-rotates and pauses on hover', (
    tester,
  ) async {
    await tester.pumpWidget(_home());
    await tester.pump();
    expect(_featureTitle(tester), _item(0).title);
    await tester.pump(desktopHomeBannerInterval);
    await tester.pump();
    expect(_featureTitle(tester), _item(1).title);
    // Hovering the banner holds it on the current title.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(
      location: tester.getCenter(
        find.byKey(const ValueKey('desktop-home-feature')),
      ),
    );
    await tester.pump();
    await tester.pump(desktopHomeBannerInterval * 2);
    await tester.pump();
    expect(_featureTitle(tester), _item(1).title);
    // Leaving restarts a full interval, then it moves on again.
    await mouse.moveTo(const Offset(5, 895));
    await tester.pump();
    await tester.pump(desktopHomeBannerInterval);
    await tester.pump();
    expect(_featureTitle(tester), _item(2).title);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox());
  }, variant: _windows);

  testWidgets('home-5: no banner controls or rotation off Windows', (
    tester,
  ) async {
    await tester.pumpWidget(_home());
    await tester.pump();
    expect(
      find.byKey(const ValueKey('desktop-home-feature-previous')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('desktop-home-feature-dots')),
      findsNothing,
    );
    await tester.pump(desktopHomeBannerInterval * 2);
    expect(_featureTitle(tester), _item(0).title);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('home-7: three release rows, "+N more" and row menus', (
    tester,
  ) async {
    var menus = 0;
    await tester.pumpWidget(
      _home(
        featured: const [],
        releases: [
          for (var i = 0; i < 7; i++)
            DesktopHomeRelease(
              title: 'Release $i',
              subtitle: 'Chapter $i available',
              open: () {},
              menu: () => menus++,
            ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    // Three rows keep the column level with the Continue cards.
    expect(find.text('Release 2'), findsOneWidget);
    expect(find.text('Release 3'), findsNothing);
    expect(find.text('+4 more'), findsOneWidget);
    await tester.ensureVisible(find.text('Release 0'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Release 0'), buttons: kSecondaryButton);
    await tester.pump();
    expect(menus, 1);
    await tester.pumpWidget(const SizedBox());
  }, variant: _windows);

  testWidgets('home-9: F5 refreshes and Home/End jump the page', (
    tester,
  ) async {
    var refreshed = 0;
    await tester.pumpWidget(
      _home(
        sectionItems: 3,
        onRefresh: () async => refreshed++,
        releases: [
          for (var i = 0; i < 3; i++)
            DesktopHomeRelease(title: 'R$i', subtitle: 's', open: () {}),
        ],
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    await tester.pump();
    expect(refreshed, 1);
    // The banner no longer draws a Refresh button; F5 / Ctrl+R are the way.
    expect(find.byKey(const ValueKey('desktop-home-refresh')), findsNothing);
    final scroll = tester.state<ScrollableState>(
      find
          .byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          )
          .first,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pumpAndSettle();
    expect(scroll.position.pixels, scroll.position.maxScrollExtent);
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pumpAndSettle();
    expect(scroll.position.pixels, 0);
    await tester.pumpWidget(const SizedBox());
  }, variant: _windows);

  // No Refresh button on the banner: only a spinner while a refresh runs,
  // and F5 / Ctrl+R keep working before, during and after (regression guard).
  testWidgets('home-9: banner shows only a spinner while refreshing', (
    tester,
  ) async {
    var refreshed = 0;
    // Each refresh waits on this completer so the spinner state is visible.
    var pending = Completer<void>();
    await tester.pumpWidget(
      _home(
        onRefresh: () {
          refreshed++;
          return pending.future;
        },
      ),
    );
    await tester.pump();
    const button = ValueKey('desktop-home-refresh');
    const spinner = ValueKey('desktop-home-refreshing');
    // Idle: neither the old button nor the spinner is drawn.
    expect(find.byKey(button), findsNothing);
    expect(find.byKey(spinner), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    await tester.pump();
    expect(refreshed, 1);
    // Running: the small spinner shows, still no button.
    expect(find.byKey(spinner), findsOneWidget);
    expect(find.byKey(button), findsNothing);
    // A second press while running is ignored (no double refresh).
    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    await tester.pump();
    expect(refreshed, 1);
    pending.complete();
    await tester.pump();
    await tester.pump();
    // Done: the spinner goes away and Ctrl+R refreshes again.
    expect(find.byKey(spinner), findsNothing);
    pending = Completer<void>()..complete();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(refreshed, 2);
    await tester.pumpWidget(const SizedBox());
  }, variant: _windows);

  testWidgets('home-9: Enter opens and Menu key opens the focused card menu', (
    tester,
  ) async {
    var opened = 0;
    Offset? menuAt;
    await tester.pumpWidget(
      _home(
        resume: [
          DesktopHomeResume(
            title: 'Resume fixture',
            subtitle: 'Episode 2',
            progress: .5,
            open: () => opened++,
            // Menu helpers read the keyboard origin synchronously.
            menu: () => menuAt = DesktopMediaMenuOrigin.pending,
          ),
        ],
      ),
    );
    await tester.pump();
    final card = find.byKey(const ValueKey('desktop-home-resume-0'));
    await tester.ensureVisible(card);
    await tester.pump();
    final inner = find
        .descendant(of: card, matching: find.byType(Column))
        .first;
    Focus.of(tester.element(inner)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(opened, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pump();
    expect(menuAt, isNotNull);
    expect((menuAt! - tester.getCenter(card)).distance, lessThan(1));
    // Shift+F10 is the other menu key.
    menuAt = null;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f10);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(menuAt, isNotNull);
    await tester.pumpWidget(const SizedBox());
  }, variant: _windows);

  testWidgets('home-12: downloads shelf always offers See all on Windows', (
    tester,
  ) async {
    await tester.pumpWidget(
      _home(
        offline: true,
        downloads: [
          DesktopHomeDownload(
            title: 'Saved show',
            subtitle: '3 episodes saved',
            open: () {},
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    // No onDownloads handler, yet the arrow is live (it opens Downloads).
    final seeAll = find.byTooltip('See all Available offline');
    expect(seeAll, findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.ancestor(of: seeAll, matching: find.byType(IconButton)),
          )
          .onPressed,
      isNotNull,
    );
    await tester.pumpWidget(const SizedBox());
  }, variant: _windows);

  testWidgets('home-13: full-title tooltips and accessible names', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              SizedBox(
                width: 160,
                height: 260,
                child: DesktopMediaCard(
                  title: 'A very long poster title that will be cut',
                  onTap: () {},
                ),
              ),
              SizedBox(
                width: 160,
                height: 260,
                child: DesktopMediaCard(
                  title: 'Logo only title',
                  titleWidget: const SizedBox(height: 20),
                  badges: const ['+2'],
                  onTap: () {},
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final tips = tester.widgetList<Tooltip>(find.byType(Tooltip)).toList();
    expect(
      tips.map((t) => t.message),
      containsAll([
        'A very long poster title that will be cut',
        'Logo only title',
      ]),
    );
    expect(tips.every((t) => t.waitDuration == desktopCardTooltipWait), isTrue);
    // A title-artwork card is announced by its title, not only its badges.
    expect(find.bySemanticsLabel(RegExp('Logo only title')), findsWidgets);
    handle.dispose();
  }, variant: _windows);

  testWidgets('home-13: phone cards have no tooltip', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 160,
            height: 260,
            child: DesktopMediaCard(title: 'Phone card', onTap: () {}),
          ),
        ),
      ),
    );
    expect(find.byType(Tooltip), findsNothing);
  });
}
