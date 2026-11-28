import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:watch_app/features/home/cubit/home_cubit.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/zmode/zmode_prefs.dart';
// The Genres card on Home is only offered when the catalogue can actually
// narrow itself, so what is worth pinning here is the OTHER half of that
// promise: the screen behind the card lists the genres for the mode you are
// in, and it refuses to open Search when the provider cannot filter — because
// MAL and Simkl answer a genre parameter with the same unfiltered list, and a
// tap that looked like it worked would be worse than no card at all.

import 'package:bloc/bloc.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/mode/content_mode_cubit.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/zmode/metadata_filters.dart';
import 'package:watch_app/core/zmode/metadata_repository.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/features/home/genres_screen.dart';
import 'package:watch_app/l10n/app_localizations.dart';

class _FakeContentModeCubit extends Cubit<ContentMode>
    implements ContentModeCubit {
  _FakeContentModeCubit(super.initial);
  void change(ContentMode mode) => emit(mode);
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// Emits catalogue rows without fetching a real provider or altering user data.
class _ArtworkHomeCubit extends Cubit<HomeState> implements HomeCubit {
  _ArtworkHomeCubit() : super(const HomeState());
  void rows(List<HomeSection> sections) => emit(HomeState(sections: sections));
  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Only [supportsFilters] is reached by this screen; everything else on the
/// repository would be a lie to stub.
class _FakeMetaRepo implements MetadataRepository {
  _FakeMetaRepo(this._supports);
  final bool _supports;
  @override
  bool get supportsFilters => _supports;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// Counts pushes so navigation can be asserted WITHOUT pumping, which matters:
/// letting the route build would drag in the whole SearchScreen dependency
/// graph (AppMode, SearchPrefs, …) and the test would be about GetIt setup
/// rather than about the guard.
class _Pushes extends NavigatorObserver {
  int count = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previous) {
    if (previous != null) count++; // ignore the initial home route
  }
}

Widget harness(NavigatorObserver observer) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      navigatorObservers: [observer],
      home: const GenresScreen(),
    );

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('genres-kind-');
    Hive.init(directory.path);
    await ZModePrefs.init();
    // The grid runs well past a default 800x600 surface, and a tile that was
    // never laid out cannot be found or tapped.
    final v = TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher
        .views
        .first;
    v.physicalSize = const Size(420 * 3, 1800 * 3);
    v.devicePixelRatio = 3;
  });

  tearDown(() async {
    TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher.views.first
        .resetPhysicalSize();
    await sl.reset();
    await Hive.close();
    await directory.delete(recursive:true);
  });

  test('genre artwork isolates canonical and provider media kinds', () {
    MediaItem media(String id, ProviderType type, String url) => MediaItem(
      id:id, title:id, url:url, sourceId:'fixture', type:type,
      cover:'https://example.invalid/$id.jpg', genres:const ['Action'],
      coverHeaders:const {'Referer':'fixture'},
    );
    final rows=[HomeSection(title:'mixed',items:[
      media('old-anime',ProviderType.anime,'/anime'),
      media('movie',ProviderType.anime,'zm://tv/123'),
      media('manga',ProviderType.manga,'/manga'),
      media('novel',ProviderType.novel,'/novel'),
    ])];
    for(final kind in ZKind.values) {
      final expected=switch(kind) {
        ZKind.anime=>'old-anime', ZKind.movie || ZKind.tv=>'movie',
        ZKind.manga=>'manga', ZKind.novel=>'novel',
      };
      final art=genreArtFrom(rows,kind:kind);
      expect(art['Action']?.url,'https://example.invalid/$expected.jpg');
      expect(art['Action']?.headers,{'Referer':'fixture'});
    }
    expect(genreArtFrom(const [],kind:ZKind.manga),isEmpty);
  });

  testWidgets('retained Genres refreshes late Home artwork and disposes listener', (t) async {
    final mode = _FakeContentModeCubit(ContentMode.anime);
    final home = _ArtworkHomeCubit();
    sl.registerSingleton<ContentModeCubit>(mode);
    sl.registerSingleton<HomeCubit>(home);
    sl.registerSingleton<MetadataRepository>(_FakeMetaRepo(true));
    await t.pumpWidget(harness(_Pushes()));
    await t.pumpAndSettle();
    final state = t.state(find.byType(GenresScreen));
    expect(find.byType(CachedNetworkImage), findsNothing);
    List<HomeSection> rows(String id, ProviderType type) => [
      HomeSection(title:'loaded', items:[MediaItem(
        id:id, title:id, url:'/$id', sourceId:'fixture', type:type,
        cover:'https://example.invalid/$id.jpg', genres:const ['Action'],
      )]),
    ];
    home.rows(rows('late-anime',ProviderType.anime));
    await t.pump(); await t.pump();
    expect(t.widget<CachedNetworkImage>(find.byType(CachedNetworkImage)).imageUrl,
      'https://example.invalid/late-anime.jpg');
    mode.change(ContentMode.manga);
    await t.pump(); await t.pump();
    expect(find.byType(CachedNetworkImage), findsNothing);
    home.rows(rows('late-manga',ProviderType.manga));
    await t.pump(); await t.pump();
    expect(t.widget<CachedNetworkImage>(find.byType(CachedNetworkImage)).imageUrl,
      'https://example.invalid/late-manga.jpg');
    expect(t.state(find.byType(GenresScreen)),same(state));
    await t.pumpWidget(const SizedBox());
    home.rows(rows('after-dispose',ProviderType.manga));
    await t.pump();
    expect(t.takeException(),isNull);
    await mode.close(); await home.close();
  });

  testWidgets('retained Genres follows media mode and streaming kind', (t) async {
    final mode=_FakeContentModeCubit(ContentMode.anime);
    sl.registerSingleton<ContentModeCubit>(mode);
    sl.registerSingleton<MetadataRepository>(_FakeMetaRepo(true));
    await t.pumpWidget(harness(_Pushes())); await t.pumpAndSettle();
    final state=t.state(find.byType(GenresScreen));
    expect(find.byKey(const ValueKey('genre_Documentary')),findsNothing);
    await t.runAsync(()=>ZModePrefs.setStreamKind(StreamKind.movie)); await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('genre_Documentary')),findsOneWidget);
    mode.change(ContentMode.manga); await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('genre_Documentary')),findsNothing);
    mode.change(ContentMode.anime); await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('genre_Documentary')),findsOneWidget);
    expect(t.state(find.byType(GenresScreen)),same(state));
    await t.pumpWidget(const SizedBox());
    mode.change(ContentMode.novel); await t.pump();
    expect(t.takeException(),isNull);
    await mode.close();
  });

  testWidgets('lists the genres for the current mode', (t) async {
    sl.registerSingleton<ContentModeCubit>(
      _FakeContentModeCubit(ContentMode.anime),
    );
    sl.registerSingleton<MetadataRepository>(_FakeMetaRepo(true));

    await t.pumpWidget(harness(_Pushes()));
    await t.pumpAndSettle();

    // Not an arbitrary sample: these come from metaGenresFor(anime), so if
    // that list is ever swapped for a provider-specific one this fails.
    for (final g in metaGenresFor(ZKind.anime)) {
      expect(find.text(g), findsOneWidget, reason: 'missing genre $g');
    }
  });

  testWidgets('a genre opens Search when the catalogue can filter', (t) async {
    sl.registerSingleton<ContentModeCubit>(
      _FakeContentModeCubit(ContentMode.anime),
    );
    sl.registerSingleton<MetadataRepository>(_FakeMetaRepo(true));

    final pushes = _Pushes();
    await t.pumpWidget(harness(pushes));
    await t.pumpAndSettle();
    // Deliberately no pump after the tap — see [_Pushes].
    await t.tap(find.byKey(const ValueKey('genre_Action')));

    expect(pushes.count, 1);
  });

  testWidgets('a genre does NOT open Search when the provider cannot filter',
      (t) async {
    sl.registerSingleton<ContentModeCubit>(
      _FakeContentModeCubit(ContentMode.anime),
    );
    // MAL/Simkl: takes the parameter, returns everything.
    sl.registerSingleton<MetadataRepository>(_FakeMetaRepo(false));

    final pushes = _Pushes();
    await t.pumpWidget(harness(pushes));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('genre_Action')));
    // The refusal shows a toast, which holds a 2s timer the binding checks
    // for at teardown — run past it rather than leaving it pending.
    await t.pump(const Duration(seconds: 3));

    // Refused, not silently wrong: still here, and nothing was pushed.
    expect(find.byType(GenresScreen), findsOneWidget);
    expect(pushes.count, 0);
  });
  group('genreArtFrom', () {
    MediaItem item(String id, String? cover, List<String> genres) => MediaItem(
          id: id,
          title: id,
          url: '/$id',
          sourceId: 'zm',
          type: ProviderType.anime,
          cover: cover,
          genres: genres,
        );

    HomeSection row(List<MediaItem> items) =>
        HomeSection(title: 'row', items: items);

    test('first match wins, so the grid is stable between visits', () {
      final art = genreArtFrom([
        row([item('a', 'A.jpg', ['Action']), item('b', 'B.jpg', ['Action'])]),
      ]);
      expect(art['Action']?.url, 'A.jpg');
    });

    test('one title backs one genre, not all of its genres', () {
      // The inner break, not the dedupe: a title carrying three genres must
      // not paper three tiles with itself.
      final art = genreArtFrom([
        row([item('a', 'A.jpg', ['Action', 'Comedy', 'Drama'])]),
      ]);
      expect(art.length, 1);
      expect(art['Action']?.url, 'A.jpg');
      expect(art['Comedy'], isNull);
    });

    test('the same cover on two titles is not used twice', () {
      // The dedupe proper. A show that appears in two rows arrives as two
      // MediaItems with one artwork, and without `used` it would sit under
      // both Action and Comedy.
      final art = genreArtFrom([
        row([item('a', 'A.jpg', ['Action'])]),
        row([item('b', 'A.jpg', ['Comedy'])]),
      ]);
      expect(art['Action']?.url, 'A.jpg');
      expect(art['Comedy'], isNull, reason: 'A.jpg was already spoken for');
    });

    test('a second title fills the next genre', () {
      final art = genreArtFrom([
        row([
          item('a', 'A.jpg', ['Action', 'Comedy']),
          item('b', 'B.jpg', ['Comedy']),
        ]),
      ]);
      expect(art['Action']?.url, 'A.jpg');
      expect(art['Comedy']?.url, 'B.jpg');
    });

    test('skips items with no cover or no genres', () {
      final art = genreArtFrom([
        row([
          item('a', null, ['Action']),
          item('b', '', ['Action']),
          item('c', 'C.jpg', const []),
        ]),
      ]);
      expect(art, isEmpty);
    });
  });
  group('the adult genre', () {
    test('is absent unless asked for', () {
      expect(metaGenresFor(ZKind.anime), isNot(contains(kAdultGenre)));
      expect(metaGenresFor(ZKind.manga), isNot(contains(kAdultGenre)));
    });

    test('is offered for anime/manga/novel when the switch is on', () {
      for (final k in [ZKind.anime, ZKind.manga, ZKind.novel]) {
        expect(metaGenresFor(k, adult: true), contains(kAdultGenre),
            reason: '$k should offer it');
      }
    });

    test('is never offered for movie/TV — TMDB has no such genre', () {
      for (final k in [ZKind.movie, ZKind.tv]) {
        expect(metaGenresFor(k, adult: true), isNot(contains(kAdultGenre)),
            reason: '$k has no adult genre to filter on');
      }
    });

    test('does not disturb the ordinary list', () {
      final plain = metaGenresFor(ZKind.anime);
      final withAdult = metaGenresFor(ZKind.anime, adult: true);
      expect(withAdult.where((g) => g != kAdultGenre).toList(), plain);
      expect(withAdult.length, plain.length + 1);
    });

    test('sorts into place rather than landing at the bottom', () {
      final g = metaGenresFor(ZKind.anime, adult: true);
      // Alphabetical: you go looking under H, so it must not be last.
      expect(g.last, isNot(kAdultGenre));
      final i = g.indexOf(kAdultGenre);
      expect(g[i - 1].compareTo(kAdultGenre), lessThan(0));
      expect(g[i + 1].compareTo(kAdultGenre), greaterThan(0));
    });

    test('the whole list stays alphabetical with it in', () {
      final g = metaGenresFor(ZKind.anime, adult: true);
      expect(g, orderedEquals([...g]..sort()));
    });
  });
  group('genreFilters', () {
    test('an ordinary genre does not switch 18+ on', () {
      final f = genreFilters('Action');
      expect(f.genres, ['Action']);
      expect(f.adult, isFalse);
    });

    test('the adult genre switches it on, or the grid is always empty', () {
      final f = genreFilters(kAdultGenre);
      expect(f.genres, [kAdultGenre]);
      expect(f.adult, isTrue);
    });
  });
  group('the adult tile colour', () {
    // Pinned rather than hashed: 'Hentai' hashes to hue 323, a hot pink that
    // shouted across the grid. This is the regression guard for that.
    test('is blue, not the hashed pink', () {
      final hsl = HSLColor.fromColor(genreTint(kAdultGenre));
      expect(hsl.hue, closeTo(212, 1), reason: 'should be blue');
      // The hash would have put it here; make sure we are not back on it.
      expect(hsl.hue, isNot(closeTo(323, 1)));
    });

    test('every other genre still uses its own hashed colour', () {
      expect(genreTint('Action'), isNot(genreTint('Comedy')));
      expect(genreTint('Action'), genreTint('Action')); // stable
    });
  });
}
