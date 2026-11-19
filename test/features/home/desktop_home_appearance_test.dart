import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/desktop/desktop_chrome_colors.dart';
import 'package:watch_app/core/desktop/desktop_title_bar.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/theme/app_colors.dart';
import 'package:watch_app/core/theme/theme_controller.dart';
import 'package:watch_app/core/ui/desktop_media_card.dart';
import 'package:watch_app/core/ui/featured_hero.dart';
import 'package:watch_app/core/ui/poster_card.dart';
import 'package:watch_app/core/ui/poster_palette.dart';
import 'package:watch_app/features/home/desktop_home_page.dart';

/// Desktop Home must follow Theme & colour, Font, Poster cards and Home rows
/// on Windows. Each test drives one setting and checks the rendered result.
void main() {
  MediaItem item(String id, {String? banner, int? score = 86}) => MediaItem(
    id: id,
    title: 'Title $id',
    url: 'fixture://$id',
    sourceId: 'fixture',
    score: score,
    banner: banner,
    type: ProviderType.anime,
  );

  final trending = HomeSection(
    title: 'Trending this week',
    items: [item('t1'), item('t2')],
  );
  final popular = HomeSection(title: 'Popular', items: [item('p1')]);

  Widget home({
    List<MediaItem>? featured,
    List<HomeSection>? sections,
    List<DesktopHomeRow>? rows,
    bool adaptive = false,
    Future<Color?> Function(MediaItem)? heroColour,
    List<DesktopHomeRelease> releases = const [],
    String? font,
  }) => MaterialApp(
    theme: ThemeData(fontFamily: font),
    home: Scaffold(
      body: PosterCardScope(
        child: DesktopHomePage(
          featured: featured ?? [item('hero')],
          sections: sections ?? [trending, popular],
          rows: rows,
          adaptiveColour: adaptive,
          heroColour: heroColour,
          reading: false,
          resume: [
            DesktopHomeResume(
              title: 'Resume fixture',
              subtitle: 'Episode 7',
              progress: .5,
              open: () {},
            ),
          ],
          releases: releases,
          meta: (_) async => const HeroMeta(description: 'Synopsis.'),
          onPlay: (_) {},
          onOpen: (_) {},
          onMenu: (_) {},
          onSection: (_) {},
          onHistory: () {},
          onReleases: () {},
          onRefresh: () async {},
          playLabel: (_) => 'Watch now',
        ),
      ),
    ),
  );

  List<Color> canvasColours(WidgetTester tester) {
    final box = tester.widget<AnimatedContainer>(
      find.byKey(const ValueKey('desktop-home-canvas')),
    );
    final gradient = (box.decoration! as BoxDecoration).gradient!;
    return (gradient as LinearGradient).colors;
  }

  Color primaryFill(WidgetTester tester) => tester
      .widget<Material>(
        find.byKey(const ValueKey('desktop-home-primary-action')),
      )
      .color!;

  setUp(() {
    AppColors.accent = AppColors.defaultAccent;
    AppColors.bg = AppColors.defaultBg;
  });
  tearDown(() {
    AppColors.accent = AppColors.defaultAccent;
    AppColors.bg = AppColors.defaultBg;
  });

  group('Theme & colour', () {
    testWidgets('accent recolours Play, progress and hover ring live', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1366, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final blue = ThemeController.accentPresets[1].$2;
      final amber = ThemeController.accentPresets[4].$2;
      AppColors.accent = blue;
      await tester.pumpWidget(home());
      await tester.pumpAndSettle();
      expect(primaryFill(tester), blue);
      // Dark accent: white label.
      expect(
        tester.widget<Text>(find.text('Watch now')).style!.color,
        Colors.white,
      );
      final progress = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator).first,
      );
      expect(progress.color, blue);

      // A new accent applies on the theme revision, without a restart.
      AppColors.accent = amber;
      ThemeController.revision.value++;
      await tester.pump();
      expect(primaryFill(tester), amber);
      // Light accent: dark label so it stays readable.
      expect(
        tester.widget<Text>(find.text('Watch now')).style!.color,
        const Color(0xFF0B0B0F),
      );

      // Hovering a poster lights the ring in the accent.
      final surface = find.byKey(
        const ValueKey('desktop-home-poster-Trending this week-0'),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(surface));
      await tester.pumpAndSettle();
      final ring = tester.widget<AnimatedContainer>(
        find.descendant(of: surface, matching: find.byType(AnimatedContainer)),
      );
      expect(
        ((ring.decoration! as BoxDecoration).border! as Border).top.color,
        amber,
      );
    });

    testWidgets('app font reaches the feature title and rank numerals', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1366, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(home(font: 'Inter'));
      await tester.pumpAndSettle();
      String? family(Finder of) => tester
          .widget<RichText>(
            find.descendant(of: of, matching: find.byType(RichText)).first,
          )
          .text
          .style!
          .fontFamily;
      expect(
        family(find.byKey(const ValueKey('desktop-home-feature-title'))),
        'Inter',
      );
      expect(
        family(find.byKey(const ValueKey('desktop-media-rank-1'))),
        'Inter',
      );
    });

    testWidgets('Pure black and Background colour recolour the canvas live', (
      tester,
    ) async {
      await tester.pumpWidget(home());
      await tester.pumpAndSettle();
      // Stock background keeps the original Home grey.
      expect(canvasColours(tester), [
        DesktopChrome.stockCanvas,
        DesktopChrome.stockCanvas,
      ]);
      AppColors.bg = ThemeController.amoledBg;
      ThemeController.revision.value++;
      await tester.pumpAndSettle();
      expect(canvasColours(tester), [Colors.black, Colors.black]);
      const custom = Color(0xFF14233A);
      AppColors.bg = custom;
      ThemeController.revision.value++;
      await tester.pumpAndSettle();
      expect(canvasColours(tester), [custom, custom]);
    });

    test('desktop chrome colours derive from the background', () {
      expect(DesktopChrome.frame, DesktopChrome.stockFrame);
      expect(DesktopChrome.canvas, DesktopChrome.stockCanvas);
      AppColors.bg = Colors.black;
      expect(DesktopChrome.frame, Colors.black);
      expect(DesktopChrome.canvas, Colors.black);
      AppColors.bg = const Color(0xFF14233A);
      expect(DesktopChrome.canvas, const Color(0xFF14233A));
      expect(DesktopChrome.frame, isNot(DesktopChrome.stockFrame));
    });

    testWidgets('title bar follows Pure black live', (tester) async {
      const channel = MethodChannel('com.spyou.zangetsu/window');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => false,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: DesktopTitleBar())),
      );
      Color bar() => tester
          .widget<Material>(
            find.byKey(const ValueKey('desktop-title-bar-surface')),
          )
          .color!;
      expect(bar(), DesktopChrome.stockFrame);
      AppColors.bg = Colors.black;
      ThemeController.revision.value++;
      await tester.pump();
      expect(bar(), Colors.black);
    });

    testWidgets('Adaptive colour washes Home from the featured art', (
      tester,
    ) async {
      var reads = 0;
      const art = Color(0xFF2050C0);
      await tester.pumpWidget(
        home(
          adaptive: true,
          heroColour: (_) async {
            reads++;
            return art;
          },
        ),
      );
      await tester.pumpAndSettle();
      // The fixture has no art URL, so nothing is sampled.
      expect(reads, 0);

      await tester.pumpWidget(
        home(
          featured: [item('a', banner: 'fixture-a.png')],
          adaptive: true,
          heroColour: (_) async {
            reads++;
            return art;
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(reads, 1);
      expect(canvasColours(tester), [
        tintFromDominant(art, blend: adaptiveColourBlend),
        DesktopChrome.stockCanvas,
      ]);

      // Pure black while the wash is on re-blends against black without
      // sampling the art again.
      AppColors.bg = Colors.black;
      ThemeController.revision.value++;
      await tester.pumpAndSettle();
      expect(reads, 1);
      expect(canvasColours(tester), [
        tintFromDominant(art, blend: adaptiveColourBlend),
        Colors.black,
      ]);
      AppColors.bg = AppColors.defaultBg;

      // Off: the plain canvas, and no sampling.
      await tester.pumpWidget(
        home(
          featured: [item('b', banner: 'fixture-b.png')],
          heroColour: (_) async {
            reads++;
            return art;
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(reads, 1);
      expect(canvasColours(tester), [
        DesktopChrome.stockCanvas,
        DesktopChrome.stockCanvas,
      ]);
    });
  });

  group('Home rows', () {
    testWidgets('saved order and visibility drive the desktop shelves', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1366, 3000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        home(
          rows: [
            DesktopHomeRow.shelf(popular),
            DesktopHomeRow.resume(),
            DesktopHomeRow.shelf(trending),
          ],
        ),
      );
      await tester.pumpAndSettle();
      final popularY = tester.getTopLeft(find.text('Popular')).dy;
      final continueY = tester.getTopLeft(find.text('Continue watching')).dy;
      final trendingY = tester.getTopLeft(find.text('Trending this week')).dy;
      expect(popularY, lessThan(continueY));
      expect(continueY, lessThan(trendingY));
      // Trending is not leading any more, so it is not ranked.
      expect(find.byKey(const ValueKey('desktop-media-rank-1')), findsNothing);

      // Hidden rows are gone; hiding Continue keeps library releases.
      await tester.pumpWidget(
        home(
          rows: [DesktopHomeRow.shelf(trending)],
          releases: [
            DesktopHomeRelease(
              title: 'Release fixture',
              subtitle: 'Episode 8 available',
              open: () {},
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Popular'), findsNothing);
      expect(find.text('Continue watching'), findsNothing);
      expect(
        find.byKey(const ValueKey('desktop-home-releases-only')),
        findsOneWidget,
      );
      expect(find.text('Release fixture'), findsOneWidget);
      // Leading Trending keeps its ranks.
      expect(
        find.byKey(const ValueKey('desktop-media-rank-1')),
        findsOneWidget,
      );
    });

    testWidgets('tracker shelves use their own open, see-all and tags', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1366, 3000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var opened = 0, all = 0;
      await tester.pumpWidget(
        home(
          rows: [
            DesktopHomeRow.shelf(
              HomeSection(title: 'New episodes', items: [item('n1')]),
              onOpen: (_) => opened++,
              onAll: () => all++,
              tagsFor: (_) => ['+2'],
            ),
            DesktopHomeRow.custom((_) => const Text('Services fixture')),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('+2'), findsOneWidget);
      expect(find.text('Services fixture'), findsOneWidget);
      await tester.tap(find.text('Title n1'));
      expect(opened, 1);
      await tester.tap(find.byTooltip('See all New episodes'));
      expect(all, 1);
    });
  });

  group('Poster cards', () {
    late Directory temp;
    setUp(() async {
      temp = await Directory.systemTemp.createTemp('desktop_home_posters');
      Hive.init(temp.path);
      await PlaybackPrefs.init();
      GetIt.I.registerSingleton<PlaybackPrefs>(PlaybackPrefs());
    });
    tearDown(() async {
      await GetIt.I.reset();
      await Hive.close();
      await temp.delete(recursive: true);
    });

    final poster = find.byKey(
      const ValueKey('desktop-home-poster-Trending this week-0'),
    );

    // Runs [body] as the Windows target, restoring the override before the
    // test framework's end-of-test invariant check.
    Future<void> onWindows(Future<void> Function() body) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await body();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

    Future<void> set(
      WidgetTester tester,
      Future<void> Function(PlaybackPrefs p) change,
    ) async {
      await tester.runAsync(() => change(GetIt.I<PlaybackPrefs>()));
      await tester.pumpAndSettle();
    }

    testWidgets(
      'shape, size, placement and badges apply to Home live',
      (tester) => onWindows(() async {
        await tester.binding.setSurfaceSize(const Size(1366, 3000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(home());
        await tester.pumpAndSettle();
        // Shelf content width at 1366: 1366 - 32 padding.
        const shelf = 1334.0;
        double cardWidth(int count) => (shelf - (count - 1) * 12) / count;
        expect(tester.getSize(poster).width, closeTo(cardWidth(7), .5));

        await set(tester, (p) => p.setPosterPortraitSize(PosterCardSize.large));
        expect(tester.getSize(poster).width, closeTo(cardWidth(6), .5));
        await set(tester, (p) => p.setPosterPortraitSize(PosterCardSize.small));
        expect(tester.getSize(poster).width, closeTo(cardWidth(8), .5));

        // Landscape: four-up with 16:9 art.
        await set(tester, (p) => p.setPosterCardLayout(PosterCardLayout.wide));
        final wide = tester.getSize(poster);
        expect(wide.width, closeTo(cardWidth(4), .5));
        expect(wide.height, closeTo(wide.width * 9 / 16, 1));
        await set(
          tester,
          (p) => p.setPosterLandscapeSize(PosterCardSize.large),
        );
        expect(tester.getSize(poster).width, closeTo(cardWidth(3), .5));
        await set(
          tester,
          (p) => p.setPosterCardLayout(PosterCardLayout.portrait),
        );
        await set(
          tester,
          (p) => p.setPosterPortraitSize(PosterCardSize.standard),
        );

        // Score badge on by default, off on demand.
        expect(find.text('8.6'), findsWidgets);
        await set(tester, (p) => p.setPosterScoreBadge(false));
        expect(find.text('8.6'), findsNothing);
        await set(tester, (p) => p.setPosterScoreBadge(true));

        // Title inside: the title moves onto the artwork, score joins badges.
        expect(
          find.descendant(of: poster, matching: find.text('Title t1')),
          findsNothing,
        );
        await set(
          tester,
          (p) => p.setPosterTitlePlacement(PosterTitlePlacement.inside),
        );
        expect(
          find.descendant(of: poster, matching: find.text('Title t1')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: poster, matching: find.text('★ 8.6')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('desktop-media-rank-1')),
          findsOneWidget,
        );
        await set(
          tester,
          (p) => p.setPosterTitlePlacement(PosterTitlePlacement.below),
        );

        // Title artwork swaps the caption for the logo-capable title.
        expect(find.byType(PosterCardTitle), findsNothing);
        await set(
          tester,
          (p) => p.setPosterTitleStyle(PosterTitleStyle.artwork),
        );
        expect(find.byType(PosterCardTitle), findsWidgets);
        expect(find.byType(DesktopMediaCard), findsWidgets);
        expect(tester.takeException(), isNull);
      }),
    );

    testWidgets(
      'watch progress badge follows its switch',
      (tester) => onWindows(() async {
        await tester.binding.setSurfaceSize(const Size(1366, 3000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          home(
            rows: [
              DesktopHomeRow.shelf(
                HomeSection(title: 'Watching', items: [item('w1')]),
                progressFor: (_) => 'EP 3/12',
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();
        await set(tester, (p) => p.setPosterProgressBadge(false));
        expect(find.text('EP 3/12'), findsNothing);
        await set(tester, (p) => p.setPosterProgressBadge(true));
        expect(find.text('EP 3/12'), findsOneWidget);
      }),
    );

    // A loaded title logo has a fixed height; with the score row below it the
    // caption must shrink the logo rather than overflow. Real Windows fonts
    // give the score row more line height than the test font, so the fixture
    // logo is taller than the 34px default to reproduce that squeeze.
    testWidgets('title logo plus score fits the caption', (tester) async {
      const width = 157.0;
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: width,
              height: DesktopMediaCard.height(width, 1),
              child: const DesktopMediaCard(
                title: 'Logo fixture',
                score: 86,
                rank: 1,
                titleWidget: SizedBox(height: 46, width: width),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('8.6'), findsOneWidget);
    });
  });
}
