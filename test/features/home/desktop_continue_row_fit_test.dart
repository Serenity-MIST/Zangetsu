// Windows Home: the Continue row never leaves a half card at its right end
// running up to the "New from your list" panel, after scrolling and after the
// window changes size.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/desktop_shortcut_catalog.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/ui/featured_hero.dart';
import 'package:watch_app/features/home/desktop_home_page.dart';

MediaItem _item(int i) => MediaItem(
  id: 'item-$i',
  title: 'Title $i',
  url: 'fixture://$i',
  sourceId: 'fixture',
  type: ProviderType.anime,
);

Widget _home() => MaterialApp(
  home: Scaffold(
    body: DesktopHomePage(
      featured: const [],
      sections: [
        HomeSection(title: 'Trending', items: [_item(1), _item(2)]),
      ],
      resume: [
        for (var i = 0; i < 7; i++)
          DesktopHomeResume(
            title: 'Show $i',
            subtitle: 'Episode 1',
            progress: .3,
            open: () {},
          ),
      ],
      releases: [
        DesktopHomeRelease(title: 'Release', subtitle: 'New', open: () {}),
      ],
      reading: false,
      meta: (_) async => const HeroMeta(description: ''),
      onPlay: (_) {},
      onOpen: (_) {},
      onMenu: (_) {},
      onSection: (_) {},
      onHistory: () {},
      onReleases: () {},
      onRefresh: () async {},
      playLabel: (_) => 'Play',
    ),
  ),
);

/// Fails when a Continue card is cut by the row's right end (the edge 20 px
/// before the release panel), or sits under the panel.
void _expectNoCutCard(WidgetTester tester, String when) {
  final panel = tester.getRect(
    find.byKey(const ValueKey('desktop-home-release-panel')),
  );
  final edge = panel.left - 20;
  var seen = 0;
  for (var i = 0; i < 7; i++) {
    final card = find.byKey(
      ValueKey('desktop-home-resume-$i'),
      skipOffstage: false,
    );
    if (card.evaluate().isEmpty) continue;
    final r = tester.getRect(card);
    // Cards that start past the row's end are off screen (laid out ahead).
    if (r.left >= edge - .5) continue;
    seen++;
    expect(
      r.right,
      lessThanOrEqualTo(edge + .5),
      reason: '$when: card $i ends at ${r.right}, row ends at $edge',
    );
  }
  expect(seen, greaterThan(0), reason: '$when: no card on screen');
}

void main() {
  setUpAll(registerDefaultDesktopShortcuts);

  testWidgets(
    'Continue row ends on a whole card after scrolling and resizing',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_home());
      await tester.pumpAndSettle();
      _expectNoCutCard(tester, 'at rest');

      // Drag most of a card: the row settles on the next card edge.
      await tester.drag(
        find.byKey(const ValueKey('desktop-home-resume-1')),
        const Offset(-300, 0),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      _expectNoCutCard(tester, 'after a drag');
      // The row really moved on by a card, so the resize below starts from
      // a scrolled row.
      expect(
        tester
            .getRect(
              find.byKey(
                const ValueKey('desktop-home-resume-1'),
                skipOffstage: false,
              ),
            )
            .left,
        lessThan(30),
      );

      // The window gets narrower: the cards get narrower too, and the old
      // offset must not leave a half card at the right end.
      tester.view.physicalSize = const Size(1300, 900);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      _expectNoCutCard(tester, 'after a resize');

      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
