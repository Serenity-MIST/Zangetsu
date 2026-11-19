// home-10: with continueListenable + resumeItems, a history change rebuilds
// only the Continue block and shows the new items without a Home rebuild.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/ui/featured_hero.dart';
import 'package:watch_app/features/home/desktop_home_page.dart';

void main() {
  final title = MediaItem(
    id: 'fixture',
    title: 'Fixture title',
    url: 'fixture://title',
    sourceId: 'fixture',
    type: ProviderType.anime,
  );

  DesktopHomeResume resume(String name) => DesktopHomeResume(
    title: name,
    subtitle: 'Episode 1',
    progress: .5,
    remaining: '10m left',
    open: () {},
  );

  testWidgets('Continue block follows the listenable', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1366, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final changes = ValueNotifier(0);
    addTearDown(changes.dispose);
    var items = <DesktopHomeResume>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopHomePage(
            featured: [title],
            sections: [
              HomeSection(title: 'Trending this week', items: [title]),
            ],
            reading: false,
            // The constructor list is stale on purpose: the getter wins.
            resume: const [],
            resumeItems: () => items,
            continueListenable: changes,
            releases: const [],
            meta: (_) async => const HeroMeta(description: 'Synopsis'),
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
      ),
    );
    await tester.pumpAndSettle();
    // Empty history: no Continue block yet.
    expect(find.byKey(const ValueKey('desktop-home-continue')), findsNothing);

    items = [resume('Resume fixture')];
    changes.value++; // history changed
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('desktop-home-continue')), findsOneWidget);
    expect(find.text('Resume fixture'), findsOneWidget);
  });

  // The hero's play label reads history too, so it follows the listenable
  // even though Home itself no longer rebuilds on history changes.
  testWidgets('hero play label follows the listenable', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1366, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final changes = ValueNotifier(0);
    addTearDown(changes.dispose);
    var label = 'Watch now';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopHomePage(
            featured: [title],
            sections: const [],
            reading: false,
            resume: const [],
            resumeItems: () => const [],
            continueListenable: changes,
            releases: const [],
            meta: (_) async => const HeroMeta(description: 'Synopsis'),
            onPlay: (_) {},
            onOpen: (_) {},
            onMenu: (_) {},
            onSection: (_) {},
            onHistory: () {},
            onReleases: () {},
            onRefresh: () async {},
            playLabel: (_) => label,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Watch now'), findsOneWidget);

    label = 'Continue E2';
    changes.value++; // a new episode started
    await tester.pumpAndSettle();
    expect(find.text('Continue E2'), findsOneWidget);
  });
}
