import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/ui/featured_hero.dart';
import 'package:watch_app/core/ui/content_row.dart';
import 'package:watch_app/core/ui/poster_card.dart';
import 'package:watch_app/features/home/desktop_home_page.dart';

void main() {
  final title = MediaItem(
    id: 'fixture',
    title: 'A beautifully long story title',
    url: 'fixture://title',
    sourceId: 'fixture',
    score: 86,
    type: ProviderType.anime,
  );
  for (final size in [(420.0, 1.0), (1366.0, 1.0), (420.0, 2.0)]) {
    testWidgets(
      'new Home layout and real callback dispatch ${size.$1}/${size.$2}',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(size.$1, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        var played = 0, details = 0, resumed = 0, released = 0;
        var reconnected = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                size: Size(size.$1, 900),
                textScaler: TextScaler.linear(size.$2),
              ),
              child: Scaffold(
                body: DesktopHomePage(
                  featured: [title],
                  onReconnect: () => reconnected++,
                  sections: [
                    HomeSection(title: 'Trending this week', items: [title]),
                  ],
                  reading: false,
                  resume: [
                    DesktopHomeResume(
                      title: 'Resume fixture',
                      subtitle: 'Episode 7',
                      progress: .77,
                      remaining: '23m left',
                      open: () => resumed++,
                    ),
                  ],
                  releases: [
                    DesktopHomeRelease(
                      title: 'Release fixture',
                      subtitle: 'Episode 8 available',
                      open: () => released++,
                    ),
                  ],
                  meta: (_) async => const HeroMeta(
                    description:
                        'A real synopsis supplied by the data adapter.',
                  ),
                  onPlay: (_) => played++,
                  onOpen: (_) => details++,
                  onMenu: (_) {},
                  onSection: (_) {},
                  onHistory: () {},
                  onReleases: () {},
                  onRefresh: () async {},
                  playLabel: (_) => 'Continue E7',
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Reconnect to sync'));
        expect(reconnected, 1);
        if (size.$1 == 1366 && size.$2 == 1) {
          final hero = tester.getSize(
            find.byKey(const ValueKey('desktop-home-feature')),
          );
          expect(hero.height / hero.width, closeTo(.226, .002));
          final card = tester.getSize(
            find.byKey(const ValueKey('desktop-home-resume-0')),
          );
          expect(card.height, lessThan(card.width * .6));
          await tester.ensureVisible(find.text('Trending this week'));
          await tester.pumpAndSettle();
          final poster = tester.getSize(
            find.byKey(
              const ValueKey('desktop-home-poster-Trending this week-0'),
            ),
          );
          expect(poster.width, closeTo((1334 - 72) / 7, 1));
          expect(poster.height / poster.width, inInclusiveRange(.9, 1.15));
          await tester.ensureVisible(find.text('Continue E7'));
          await tester.pumpAndSettle();
        }
        expect(find.byType(ContentRow), findsNothing);
        expect(find.byType(PosterCard), findsNothing);
        expect(find.text('Catalogue'), findsNothing);
        expect(find.text('Schedule & lists'), findsNothing);
        await tester.tap(find.text('Continue E7'));
        expect(played, 1);
        await tester.tap(find.text('Details'));
        expect(details, 1);
        await tester.ensureVisible(find.text('Resume fixture'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Resume fixture'));
        expect(resumed, 1);
        await tester.ensureVisible(find.text('Release fixture'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Release fixture'));
        expect(released, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets('new Home empty state refreshes without a fake hero', (
    tester,
  ) async {
    var refreshed = 0, catalogueOpened = 0, verified = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopHomePage(
            featured: const [],
            sections: const [],
            resume: const [],
            releases: const [],
            reading: false,
            error: 'Source unavailable',
            onCatalogue: () => catalogueOpened++,
            onVerify: () => verified++,
            onPlay: (_) {},
            onOpen: (_) {},
            onMenu: (_) {},
            onSection: (_) {},
            onHistory: () {},
            onReleases: () {},
            onRefresh: () async {
              refreshed++;
            },
            meta: (_) async => null,
            playLabel: (_) => 'Play',
          ),
        ),
      ),
    );
    expect(find.text('Source unavailable'), findsOneWidget);
    expect(find.text('Reconnect to sync'), findsNothing);
    expect(find.text('ZANGETSU PRESENTS'), findsNothing);
    await tester.tap(find.text('Refresh catalogue'));
    expect(refreshed, 1);
    await tester.tap(find.text('Choose catalogue'));
    expect(catalogueOpened, 1);
    await tester.tap(find.text('Verify website'));
    expect(verified, 1);
  });
  testWidgets('Home recovery controls remain reachable with enlarged text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var actions = 0;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(3)),
          child: child!,
        ),
        home: Scaffold(
          body: DesktopHomePage(
            featured: const [],
            sections: const [],
            resume: const [],
            releases: const [],
            reading: false,
            error:
                'This source needs website verification before its catalogue can load.',
            onCatalogue: () => actions++,
            onVerify: () => actions++,
            onRefresh: () async {
              actions++;
            },
            onPlay: (_) {},
            onOpen: (_) {},
            onMenu: (_) {},
            onSection: (_) {},
            onHistory: () {},
            onReleases: () {},
            meta: (_) async => null,
            playLabel: (_) => 'Play',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    for (final label in [
      'Verify website',
      'Choose catalogue',
      'Refresh catalogue',
    ]) {
      await tester.ensureVisible(find.text(label));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
    }
    expect(actions, 3);
    expect(tester.takeException(), isNull);
  });
  testWidgets('new Home utility routes dispatch without legacy cards', (
    tester,
  ) async {
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopHomeUtilities(
            actions: [
              (
                label: 'Streaming services',
                icon: 'circle-play',
                run: () => opened++,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('Streaming services'));
    expect(opened, 1);
    expect(find.byType(PosterCard), findsNothing);
  });
  testWidgets('new desktop context menu invokes once and dismisses', (
    tester,
  ) async {
    var invoked = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDesktopHomeMenu(
              context,
              title: 'Fixture',
              actions: [
                (label: 'Play now', icon: 'play', run: () => invoked++),
              ],
            ),
            child: const Text('Open menu'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play now'));
    await tester.pumpAndSettle();
    expect(invoked, 1);
    expect(find.byType(Dialog), findsNothing);
  });
}
