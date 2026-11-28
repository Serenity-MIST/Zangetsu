// Item 12: the Windows Home banner must not load a show's details (catalogue
// fetch + source matching) while it rotates. Details load only when the user
// opens a show. Phone keeps loading the banner text once per slide.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/desktop_shortcut_catalog.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_detail.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/features/home/desktop_home_page.dart';
import 'package:watch_app/features/home/home_banner_meta.dart';

final _windows = TargetPlatformVariant.only(TargetPlatform.windows);

MediaItem _item(int i) => MediaItem(
  id: 'item-$i',
  title: 'Featured title $i',
  url: 'zm://anime/mal:$i',
  sourceId: 'zm',
  type: ProviderType.anime,
  genres: const ['Action', 'Drama'],
);

/// A detail loader that only counts the calls it gets.
class _CountingLoader {
  final calls = <String>[];

  Future<MediaDetail?> call(
    String url,
    String sourceId, {
    void Function(MediaDetail partial)? onPartial,
    bool Function()? abandoned,
  }) async {
    calls.add(url);
    return MediaDetail(
      id: url,
      title: url,
      url: url,
      sourceId: sourceId,
      type: ProviderType.anime,
      description: 'Loaded synopsis',
      genres: const ['Loaded'],
    );
  }
}

Widget _home(HomeBannerMeta meta, List<MediaItem> featured) => MaterialApp(
  home: MediaQuery(
    data: const MediaQueryData(size: Size(1366, 900)),
    child: Scaffold(
      body: DesktopHomePage(
        featured: featured,
        sections: [HomeSection(title: 'Trending', items: featured)],
        resume: const [],
        releases: const [],
        downloads: const [],
        offline: false,
        reading: false,
        meta: meta.call,
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

String _featureTitle(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey('desktop-home-feature-title')))
    .data!;

void main() {
  setUpAll(registerDefaultDesktopShortcuts);

  testWidgets('Windows: rotating banner slides never loads a detail', (
    tester,
  ) async {
    final loader = _CountingLoader();
    final meta = HomeBannerMeta(loadDetail: loader.call);
    final featured = [for (var i = 0; i < 4; i++) _item(i)];
    await tester.pumpWidget(_home(meta, featured));
    await tester.pump();
    expect(_featureTitle(tester), featured[0].title);

    // Go round every slide and back to the first one.
    for (var i = 1; i <= featured.length; i++) {
      await tester.pump(desktopHomeBannerInterval);
      await tester.pump();
      expect(_featureTitle(tester), featured[i % featured.length].title);
    }

    expect(loader.calls, isEmpty);
    // The banner still shows what the Home row has: its genres.
    expect(find.text('Action · Drama'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  }, variant: _windows);

  test(
    'Windows: asking for banner text answers null and loads nothing',
    () async {
      final loader = _CountingLoader();
      final meta = HomeBannerMeta(loadDetail: loader.call, windows: true);
      for (var i = 0; i < 6; i++) {
        expect(await meta(_item(i)), isNull);
      }
      expect(loader.calls, isEmpty);
    },
  );

  test('Android unchanged: one detail load per slide, reused after', () async {
    final loader = _CountingLoader();
    final meta = HomeBannerMeta(loadDetail: loader.call, windows: false);
    final first = await meta(_item(0));
    expect(first?.description, 'Loaded synopsis');
    expect(first?.genres, ['Loaded']);
    await meta(_item(0));
    await meta(_item(1));
    expect(loader.calls, ['zm://anime/mal:0', 'zm://anime/mal:1']);
    // Clearing (active source changed) loads again.
    meta.clear();
    await meta(_item(0));
    expect(loader.calls, hasLength(3));
  });

  testWidgets('Android: platform default still loads the banner text', (
    tester,
  ) async {
    final loader = _CountingLoader();
    final meta = HomeBannerMeta(loadDetail: loader.call);
    await tester.runAsync(() => meta(_item(0)));
    expect(loader.calls, ['zm://anime/mal:0']);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
