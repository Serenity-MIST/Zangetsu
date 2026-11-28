// Live bugs D, E and F on the Windows Home:
//  D: the banner shows a short description again, taken from the catalogue
//     list answer (or the same show's row already in memory), never from a
//     per-slide detail load.
//  E: the banner draws the widest picture there is (its own banner, else the
//     same show's from held catalogue rows) at the panel width; a title with
//     only a portrait cover shows it whole instead of stretched and zoomed.
//  F: a Continue card uses the show's stored wide picture when the episode
//     has no still, and the history keeps that picture across saves.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/desktop/desktop_shortcut_catalog.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_detail.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/playback/watch_history.dart';
import 'package:watch_app/core/supabase/supabase_service.dart';
import 'package:watch_app/core/ui/desktop_media_card.dart';
import 'package:watch_app/core/ui/featured_hero.dart' show HeroMeta;
import 'package:watch_app/core/zmode/anilist_catalogue.dart';
import 'package:watch_app/core/zmode/tmdb_catalogue.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/features/home/desktop_home_page.dart';
import 'package:watch_app/features/home/home_banner_meta.dart';
import 'package:watch_app/features/home/home_known_artwork.dart';

final _windows = TargetPlatformVariant.only(TargetPlatform.windows);
final _android = TargetPlatformVariant.only(TargetPlatform.android);

MediaItem _item({
  String id = 'a',
  String title = 'Sakamoto Days',
  String sourceId = 'zm',
  String? url,
  String? cover = 'https://img/cover.jpg',
  String? banner,
  String? description,
  int? malId,
  ProviderType type = ProviderType.anime,
}) => MediaItem(
  id: id,
  title: title,
  url: url ?? 'zm://anime/mal:$id',
  sourceId: sourceId,
  type: type,
  cover: cover,
  banner: banner,
  description: description,
  malId: malId,
  genres: const ['Action', 'Comedy'],
);

/// Counts detail loads; the Windows banner must never make one.
class _Loader {
  int calls = 0;
  Future<MediaDetail?> call(
    String url,
    String sourceId, {
    void Function(MediaDetail partial)? onPartial,
    bool Function()? abandoned,
  }) async {
    calls++;
    return null;
  }
}

Widget _home(
  List<MediaItem> featured, {
  Future<HeroMeta?> Function(MediaItem)? meta,
  String? Function(MediaItem)? wideArt,
}) => MaterialApp(
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
        meta: meta ?? (_) async => null,
        wideArt: wideArt,
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

DesktopMediaArtwork _art(WidgetTester tester, String key) =>
    tester.widget<DesktopMediaArtwork>(find.byKey(ValueKey(key)));

void main() {
  setUpAll(registerDefaultDesktopShortcuts);

  group('D: banner description', () {
    test('Windows: the row\'s own description, with no detail load', () async {
      final loader = _Loader();
      final meta = HomeBannerMeta(loadDetail: loader.call, windows: true);
      final answer = await meta(_item(description: 'An ex-hitman.'));
      expect(answer?.description, 'An ex-hitman.');
      expect(answer?.genres, ['Action', 'Comedy']);
      expect(loader.calls, 0);
    });

    test(
      'Windows: a source title borrows the same show\'s description',
      () async {
        final loader = _Loader();
        final known = HomeKnownTitles([
          _item(id: '1', title: 'SAKAMOTO DAYS', description: 'Retired.'),
          // The manga of the same name is never used for a show to watch.
          _item(
            id: '2',
            title: 'Sakamoto Days',
            description: 'Manga text.',
            type: ProviderType.manga,
          ),
        ]);
        final meta = HomeBannerMeta(
          loadDetail: loader.call,
          known: () => known,
          windows: true,
        );
        final source = _item(
          id: 'src',
          sourceId: 'ani:1',
          url: 'https://source/sakamoto',
        );
        expect((await meta(source))?.description, 'Retired.');
        // Nothing known: no answer, still no load.
        expect(await meta(_item(id: 'x', title: 'Unknown show')), isNull);
        expect(loader.calls, 0);
      },
    );

    testWidgets('Windows: the banner shows the description text', (
      tester,
    ) async {
      final meta = HomeBannerMeta(loadDetail: _Loader().call);
      await tester.pumpWidget(
        _home([
          _item(banner: 'https://img/banner.jpg', description: 'An ex-hitman.'),
        ], meta: meta.call),
      );
      await tester.pump();
      expect(find.text('An ex-hitman.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    }, variant: _windows);

    test('AniList asks for the synopsis on the banner row only', () async {
      final saved = AniListCatalogue.homeBannerDescriptions;
      addTearDown(() => AniListCatalogue.homeBannerDescriptions = saved);
      for (final on in [true, false]) {
        AniListCatalogue.homeBannerDescriptions = on;
        late String query;
        final cat = AniListCatalogue((q, v) async {
          query = q;
          final aliases = RegExp(
            r'(r\d+):',
          ).allMatches(q).map((m) => m.group(1)!);
          return {
            for (final a in aliases)
              a: {
                'media': [
                  {
                    'id': 1,
                    'idMal': 7,
                    'title': {'romaji': 'X'},
                    'coverImage': {'large': 'https://img/c.jpg'},
                    'bannerImage': 'https://img/b.jpg',
                    if (q.contains('description')) 'description': 'Synopsis',
                  },
                ],
              },
          };
        });
        final rows = await cat.home(ZKind.anime);
        final parts = query.split(RegExp(r'r\d+: '));
        final withSynopsis = parts.where((p) => p.contains('description'));
        expect(withSynopsis, hasLength(on ? 1 : 0));
        if (on) {
          expect(withSynopsis.single, contains('TRENDING_DESC'));
          expect(
            rows
                .firstWhere((r) => r.title == 'Trending')
                .items
                .single
                .description,
            'Synopsis',
          );
        }
      }
    });

    Future<String?> tmdbDescription(TargetPlatform platform) async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final cat = TmdbCatalogue(
        (p, q) async => {
          'results': [
            {
              'id': 5,
              'title': 'The Odyssey',
              'poster_path': '/p.jpg',
              'backdrop_path': '/b.jpg',
              'overview': 'Homer.',
              'media_type': 'movie',
            },
          ],
        },
      );
      final rows = await cat.home();
      return rows.first.items.first.description;
    }

    test('Windows: TMDB list items carry the overview they include', () async {
      expect(await tmdbDescription(TargetPlatform.windows), 'Homer.');
    });

    test('Android unchanged: TMDB list items carry no description', () async {
      expect(await tmdbDescription(TargetPlatform.android), isNull);
    });
  });

  group('E: banner picture', () {
    testWidgets('Windows: the own banner fills the panel as a backdrop', (
      tester,
    ) async {
      await tester.pumpWidget(_home([_item(banner: 'https://img/b.jpg')]));
      await tester.pump();
      final art = _art(tester, 'desktop-home-feature-art');
      expect(art.url, 'https://img/b.jpg');
      expect(art.backdrop, isTrue);
      expect(art.fitWhole, isFalse);
      // Decoded for the whole panel width, not a small card size.
      expect(
        art.width,
        closeTo(
          tester
              .getSize(find.byKey(const ValueKey('desktop-home-feature')))
              .width,
          2,
        ),
      );
      await tester.pumpWidget(const SizedBox());
    }, variant: _windows);

    testWidgets('Windows: a borrowed wide picture beats the portrait cover', (
      tester,
    ) async {
      await tester.pumpWidget(
        _home([_item()], wideArt: (_) => 'https://img/borrowed.jpg'),
      );
      await tester.pump();
      final art = _art(tester, 'desktop-home-feature-art');
      expect(art.url, 'https://img/borrowed.jpg');
      expect(art.backdrop, isTrue);
      expect(art.headers, isNull);
      await tester.pumpWidget(const SizedBox());
    }, variant: _windows);

    testWidgets(
      'Windows: only a portrait cover is shown whole, not stretched',
      (tester) async {
        await tester.pumpWidget(_home([_item()]));
        await tester.pump();
        expect(
          find.byKey(const ValueKey('desktop-home-feature-art')),
          findsNothing,
        );
        final poster = _art(tester, 'desktop-home-feature-poster');
        expect(poster.url, 'https://img/cover.jpg');
        expect(poster.fitWhole, isTrue);
        await tester.pumpWidget(const SizedBox());
      },
      variant: _windows,
    );

    testWidgets('Android unchanged: banner field or cover, no poster layout', (
      tester,
    ) async {
      await tester.pumpWidget(
        _home([_item()], wideArt: (_) => 'https://img/borrowed.jpg'),
      );
      await tester.pump();
      expect(
        _art(tester, 'desktop-home-feature-art').url,
        'https://img/cover.jpg',
      );
      expect(
        find.byKey(const ValueKey('desktop-home-feature-poster')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
    }, variant: _android);

    test('known titles: own art first, then url, ids, then title', () {
      final known = HomeKnownTitles([
        _item(id: 'u', title: 'Other', url: 'x://same', banner: 'by-url'),
        _item(id: 'm', title: 'Else', malId: 9, banner: 'by-mal'),
        _item(id: 't', title: 'Solo Leveling', banner: 'by-title'),
        _item(id: 'n', title: 'No art'),
      ]);
      expect(known.wideArtFor(_item(banner: 'own')), 'own');
      expect(known.wideArtFor(_item(url: 'x://same')), 'by-url');
      expect(known.wideArtFor(_item(title: 'Q', malId: 9)), 'by-mal');
      expect(known.wideArtFor(_item(title: 'solo leveling!')), 'by-title');
      expect(known.wideArtFor(_item(title: 'No art')), isNull);
    });

    test('a title match never lends art across a film and a series', () {
      final known = HomeKnownTitles([
        _item(
          id: 'f',
          title: 'Dune',
          url: 'zm://movie/tmdb:1',
          banner: 'film-art',
          type: ProviderType.movie,
        ),
      ]);
      // A series of the same name stays without the film's picture.
      expect(
        known.wideArtFor(
          _item(title: 'Dune', url: 'zm://tv/tmdb:2', type: ProviderType.movie),
        ),
        isNull,
      );
      // The same kind still matches on title.
      expect(
        known.wideArtFor(
          _item(
            title: 'Dune',
            url: 'zm://movie/tmdb:3',
            type: ProviderType.movie,
          ),
        ),
        'film-art',
      );
    });

    test('a title match never lends art between remakes with other ids', () {
      final known = HomeKnownTitles([
        _item(
          id: '1999',
          title: 'Hunter x Hunter',
          malId: 136,
          banner: 'old-art',
          description: 'The 1999 one.',
        ),
      ]);
      final remake = _item(id: '2011', title: 'Hunter x Hunter', malId: 11061);
      expect(known.wideArtFor(remake), isNull);
      expect(known.descriptionFor(remake), isNull);
      // No id on the asking side: the title alone is still trusted.
      expect(
        known.wideArtFor(
          _item(title: 'Hunter x Hunter', url: 'https://source/hxh'),
        ),
        'old-art',
      );
    });

    test('Continue cards need the same known kind for a title match', () {
      final known = HomeKnownTitles([
        _item(
          title: 'The Odyssey',
          url: 'zm://movie/tmdb:9',
          banner: 'odyssey-art',
        ),
      ]);
      MediaItem? continueTwin(String url) => known.twin(
        title: 'The Odyssey',
        url: url,
        reading: false,
        wanted: (i) => homeWideArtOf(i) != null,
        titleNeedsKind: true,
      );
      expect(continueTwin('zm://movie/tmdb:1')?.banner, 'odyssey-art');
      // A source history entry: its kind is unknown, so no borrowed picture.
      expect(continueTwin('https://source/odyssey'), isNull);
      expect(continueTwin('zm://tv/tmdb:1'), isNull);
    });
  });

  group('F: Continue backdrop', () {
    DesktopHomeResume resume({String? still, String? backdrop}) =>
        DesktopHomeResume(
          title: 'The Odyssey',
          subtitle: 'Episode 1',
          progress: .3,
          open: () {},
          image: 'https://img/poster.jpg',
          headers: const {'Referer': 'x'},
          still: still,
          backdrop: backdrop,
          sourceId: 'zm',
          showId: 'zm://movie/tmdb:1',
        );

    test('still, then stored backdrop, then known titles, then poster', () {
      final known = [
        _item(
          title: 'The Odyssey',
          url: 'zm://movie/tmdb:1',
          banner: 'https://img/known.jpg',
        ),
      ];
      expect(
        desktopResumeArtwork(resume(still: 's', backdrop: 'b'), known).url,
        's',
      );
      final stored = desktopResumeArtwork(resume(backdrop: 'b'), known);
      expect(stored.url, 'b');
      expect(stored.headers, isNull);
      expect(
        desktopResumeArtwork(resume(), known).url,
        'https://img/known.jpg',
      );
      expect(
        desktopResumeArtwork(resume(), const []).url,
        'https://img/poster.jpg',
      );
    });

    group('history keeps the backdrop', () {
      late Directory dir;
      setUp(() async {
        dir = Directory.systemTemp.createTempSync('wh_backdrop');
        Hive.init(dir.path);
        await Hive.deleteBoxFromDisk(WatchHistory.boxName);
        await WatchHistory.init();
        ShowBackdrops.reset();
      });
      tearDown(() async {
        ShowBackdrops.resetEnabled();
        ShowBackdrops.reset();
        await Hive.box<Map>(WatchHistory.boxName).clear();
        await Hive.close();
        dir.deleteSync(recursive: true);
      });

      HistoryEntry entry({String? backdrop, int pos = 60000}) => HistoryEntry(
        sourceId: ZmodeIds.sourceId,
        showId: 'zm://movie/tmdb:1',
        showTitle: 'The Odyssey',
        showUrl: 'zm://movie/tmdb:1',
        category: 'sub',
        episodeId: '1',
        episodeNumber: 1,
        episodeUrl: 'zm://movie/tmdb:1/1',
        position: Duration(milliseconds: pos),
        duration: const Duration(minutes: 170),
        updatedAt: pos,
        backdrop: backdrop,
      );

      test(
        'Windows: picked up from the show\'s details, kept on saves',
        () async {
          ShowBackdrops.enabled = true;
          final history = WatchHistory(SupabaseService(), () => null);
          // An entry saved before this change has no picture.
          await history.save(entry());
          expect(history.recent().single.backdrop, isNull);
          // The show's details load (detail page or playback start)...
          ShowBackdrops.remember('zm://movie/tmdb:1', 'https://img/bd.jpg');
          // ...and the player's next plain save stores it.
          await history.save(entry(pos: 70000));
          expect(history.recent().single.backdrop, 'https://img/bd.jpg');
          // Later saves without a picture keep the stored one.
          ShowBackdrops.reset();
          await history.save(entry(pos: 80000));
          expect(history.recent().single.backdrop, 'https://img/bd.jpg');
        },
      );

      test('the switch follows the target platform, not the host', () {
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        expect(ShowBackdrops.enabled, isFalse);
        ShowBackdrops.remember('zm://movie/tmdb:1', 'https://img/bd.jpg');
        expect(ShowBackdrops.of('zm://movie/tmdb:1'), isNull);
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        expect(ShowBackdrops.enabled, isTrue);
      });

      test('Android unchanged: no backdrop is recorded or stored', () async {
        // No hand-set switch: the Android target alone turns it off.
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final history = WatchHistory(SupabaseService(), () => null);
        ShowBackdrops.remember('zm://movie/tmdb:1', 'https://img/bd.jpg');
        await history.save(entry(backdrop: 'https://img/given.jpg'));
        expect(history.recent().single.backdrop, isNull);
        expect(
          Hive.box<Map>(
            WatchHistory.boxName,
          ).values.single.containsKey('backdrop'),
          isFalse,
        );
      });
    });
  });
}
