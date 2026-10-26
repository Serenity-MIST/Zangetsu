import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/ui/featured_carousel.dart';
import 'package:watch_app/core/ui/route_observer.dart';

MediaItem _item(String id) => MediaItem(
  id: id,
  title: 'Show $id',
  url: 'https://example.test/$id',
  type: ProviderType.anime,
  sourceId: 'test',
);

void main() {
  testWidgets('pauses off-tab and resumes when Home is selected', (
    tester,
  ) async {
    final builtHeroIds = <String>{};
    final isHomeActive = ValueNotifier(true);

    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: isHomeActive,
          builder: (context, active, _) => Scaffold(
            body: FeaturedCarousel(
              items: [_item('first'), _item('second')],
              inList: (_) => false,
              onPlay: (_) {},
              onInfo: (_) {},
              onToggleList: (_) {},
              style: HeroTransition.cinematic,
              isActive: active,
              meta: (item) {
                builtHeroIds.add(item.id);
                return Future.value(null);
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    builtHeroIds.clear();

    await tester.pump(const Duration(seconds: 2));
    isHomeActive.value = false;
    await tester.pump();
    builtHeroIds.clear();
    await tester.pump(const Duration(seconds: 5));
    expect(builtHeroIds, isNot(contains('second')));

    isHomeActive.value = true;
    await tester.pump();
    builtHeroIds.clear();
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(builtHeroIds, contains('second'));

    isHomeActive.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('pauses while a detail route covers it and resumes on return', (
    tester,
  ) async {
    final builtHeroIds = <String>{};
    late BuildContext homeContext;

    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [appRouteObserver],
        home: Builder(
          builder: (context) {
            homeContext = context;
            return Scaffold(
              body: FeaturedCarousel(
                items: [_item('first'), _item('second')],
                inList: (_) => false,
                onPlay: (_) {},
                onInfo: (_) {},
                onToggleList: (_) {},
                style: HeroTransition.cinematic,
                meta: (item) {
                  builtHeroIds.add(item.id);
                  return Future.value(null);
                },
              ),
            );
          },
        ),
      ),
    );
    await tester.pump();
    builtHeroIds.clear();

    await tester.pump(const Duration(seconds: 2));
    final detailRoute = Navigator.of(homeContext).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Detail')),
      ),
    );
    await tester.pumpAndSettle();
    builtHeroIds.clear();

    await tester.pump(const Duration(seconds: 5));
    expect(
      builtHeroIds,
      isNot(contains('second')),
      reason: 'the hidden carousel should not advance or build another hero',
    );

    Navigator.of(homeContext).pop();
    await detailRoute;
    await tester.pumpAndSettle();
    builtHeroIds.clear();
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();

    expect(builtHeroIds, contains('second'));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('replaces every banner page when source results change', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FeaturedCarousel(
            items: [_item('same-first'), _item('old-source-second')],
            inList: (_) => false,
            onPlay: (_) {},
            onInfo: (_) {},
            onToggleList: (_) {},
            style: HeroTransition.cinematic,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FeaturedCarousel(
            items: [_item('same-first'), _item('new-source-second')],
            inList: (_) => false,
            onPlay: (_) {},
            onInfo: (_) {},
            onToggleList: (_) {},
            style: HeroTransition.cinematic,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.pump(const Duration(seconds: 5));
    await tester.pump();

    expect(find.text('Show new-source-second'), findsOneWidget);
    expect(find.text('Show old-source-second'), findsNothing);
  });

  for (final style in HeroTransition.values) {
    testWidgets('late colours cannot replace the visible tint (${style.name})', (
      tester,
    ) async {
      final first = Completer<Color?>();
      final second = Completer<Color?>();
      final colors = <Color?>[];
      MediaItem art(String id) => MediaItem(
        id: id,
        title: 'Show $id',
        cover: 'https://example.test/$id.jpg',
        url: 'https://example.test/$id',
        type: ProviderType.anime,
        sourceId: 'test',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FeaturedCarousel(
              items: [art('first'), art('second')],
              inList: (_) => false,
              onPlay: (_) {},
              onInfo: (_) {},
              onToggleList: (_) {},
              style: style,
              onArtColor: colors.add,
              paletteLoader: (url, _) =>
                  url.contains('first') ? first.future : second.future,
            ),
          ),
        ),
      );

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      second.complete(Colors.blue);
      await tester.pump();
      expect(colors.last, Colors.blue);

      first.complete(Colors.red);
      await tester.pump();
      expect(colors.last, Colors.blue);
      await tester.pumpWidget(const SizedBox.shrink());
      // The hero's separate decorative palette lookup has a 15-second timeout.
      await tester.pump(const Duration(seconds: 30));
    });
  }
}
