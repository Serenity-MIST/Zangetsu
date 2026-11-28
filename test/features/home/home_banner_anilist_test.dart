// Windows Home banner: source catalogue slides without a description ask
// AniList once (title search) for the slide on screen only. These tests pin
// the title matching, the per-title cache and its cap, the error / 429 rest,
// and the on-screen wait in HomeBannerMeta.
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/media_detail.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/features/home/home_banner_anilist.dart';
import 'package:watch_app/features/home/home_banner_meta.dart';

/// A source catalogue (Aniyomi extension) title with no description.
MediaItem _src(
  String title, {
  String id = '',
  ProviderType type = ProviderType.anime,
  String sourceId = 'ext.allanime',
}) => MediaItem(
  id: id.isEmpty ? title : id,
  title: title,
  url: 'https://example.invalid/$title',
  sourceId: sourceId,
  type: type,
  genres: const ['Action'],
);

/// An AniList media answer.
Map<String, dynamic> _media(
  String romaji, {
  String? english,
  List<String> synonyms = const [],
  String description = 'An <i>AniList</i> synopsis.<br>Second line.',
}) => {
  'id': 1,
  'title': {'romaji': romaji, 'english': english, 'native': null},
  'synonyms': synonyms,
  'description': description,
};

/// A fake AniList transport that records what it was asked.
class _FakeSearch {
  _FakeSearch(this.answer);
  Map<String, dynamic>? Function(String title, bool manga) answer;
  final calls = <(String, bool)>[];
  Object? error;

  Future<Map<String, dynamic>?> call(
    String title, {
    required bool manga,
  }) async {
    calls.add((title, manga));
    final e = error;
    if (e != null) throw e;
    return answer(title, manga);
  }
}

DioException _limited() {
  final req = RequestOptions(path: 'https://graphql.anilist.co');
  return DioException(
    requestOptions: req,
    response: Response(requestOptions: req, statusCode: 429),
    type: DioExceptionType.badResponse,
  );
}

Future<MediaDetail?> _noDetail(
  String url,
  String sourceId, {
  void Function(MediaDetail partial)? onPartial,
  bool Function()? abandoned,
}) async => fail('the banner must never load a detail on Windows');

void main() {
  group('title matching', () {
    test('ignores case, punctuation, accents and bracketed notes', () {
      expect(
        bannerTitleMatches('Frieren: Beyond Journey’s End (Dub)', {
          'title': {'english': "Frieren: Beyond Journey's End"},
        }),
        isTrue,
      );
      expect(
        bannerTitleMatches('[Uncensored] Pokémon', {
          'title': {'romaji': 'Pokemon'},
        }),
        isTrue,
      );
    });

    test('drops season words on both sides', () {
      expect(
        bannerTitleMatches('Spy x Family Season 2', {
          'title': {'romaji': 'SPY×FAMILY'},
          'synonyms': ['Spy x Family'],
        }),
        isTrue,
      );
      expect(
        bannerTitleMatches('Mushoku Tensei 2nd Season', {
          'title': {'romaji': 'Mushoku Tensei'},
        }),
        isTrue,
      );
      expect(
        bannerTitleMatches('Attack on Titan The Final Season', {
          'title': {'english': 'Attack on Titan'},
        }),
        isTrue,
      );
    });

    test('matches the native title and synonyms too', () {
      expect(
        bannerTitleMatches('Shingeki no Kyojin', {
          'title': {'romaji': 'x', 'english': 'y', 'native': '進撃の巨人'},
          'synonyms': ['Shingeki no Kyojin'],
        }),
        isTrue,
      );
      expect(
        bannerTitleMatches('進撃の巨人', {
          'title': {'native': '進撃の巨人'},
        }),
        isTrue,
      );
    });

    test('rejects a different show and an empty title', () {
      expect(
        bannerTitleMatches('Naruto Shippuden', {
          'title': {'romaji': 'Naruto'},
        }),
        isFalse,
      );
      expect(
        bannerTitleMatches('One Piece Film Red', {
          'title': {'romaji': 'One Piece'},
        }),
        isFalse,
      );
      expect(
        bannerTitleMatches('(Dub)', {
          'title': {'romaji': ''},
        }),
        isFalse,
      );
    });

    test('search title keeps season words but drops notes', () {
      expect(
        bannerSearchTitle('Oshi no Ko Season 2 (Dub)'),
        'Oshi no Ko Season 2',
      );
      expect(bannerSearchTitle('Bleach Sub'), 'Bleach');
    });

    test('description HTML is stripped', () {
      expect(
        cleanBannerDescription('A <i>story</i>.<br><br>More &amp; more.'),
        'A story. More & more.',
      );
      expect(cleanBannerDescription('<br>'), isNull);
      expect(cleanBannerDescription(null), isNull);
    });

    // AniList's own markup and the wider entity set go through the shared
    // cleaner, so no `~!`, `!~`, `__` or raw entity reaches the banner.
    test('AniList spoiler/bold markup and entities are cleaned', () {
      expect(
        cleanBannerDescription(
          'He wins ~!the war!~ and __the girl__ &mdash; then waits&hellip;',
        ),
        'He wins the war and the girl — then waits…',
      );
    });

    // The trailing credit note is not part of the story.
    test('trailing "(Source: ...)" note is removed', () {
      expect(
        cleanBannerDescription('A boy finds a sword.<br><br>(Source: Crunchyroll)'),
        'A boy finds a sword.',
      );
      expect(cleanBannerDescription('(Source: MAL)'), isNull);
    });
  });

  group('look-up cache', () {
    test('asks once per title, including "no match"', () async {
      final search = _FakeSearch((t, _) => _media(t));
      final lookup = HomeBannerAniList(search.call);
      final a = _src('Bleach');
      expect(await lookup.description(a), 'An AniList synopsis. Second line.');
      expect(await lookup.description(a), 'An AniList synopsis. Second line.');
      // Same title from another source item: still the one answer.
      expect(await lookup.description(_src('Bleach', id: 'other')), isNotNull);
      expect(search.calls, [('Bleach', false)]);

      // A wrong hit is a kept "no match", never shown, never asked again.
      search.answer = (_, _) => _media('Something Else');
      final b = _src('Dandadan');
      expect(await lookup.description(b), isNull);
      expect(await lookup.description(b), isNull);
      expect(search.calls, hasLength(2));
    });

    test('manga and novels search MANGA, apart from the anime', () async {
      final search = _FakeSearch((t, _) => _media(t));
      final lookup = HomeBannerAniList(search.call);
      await lookup.description(_src('Berserk'));
      await lookup.description(_src('Berserk', type: ProviderType.manga));
      await lookup.description(_src('Berserk', type: ProviderType.novel));
      expect(search.calls, [('Berserk', false), ('Berserk', true)]);
    });

    test('skips metadata catalogue titles and films', () async {
      final search = _FakeSearch((t, _) => _media(t));
      final lookup = HomeBannerAniList(search.call);
      expect(await lookup.description(_src('Bleach', sourceId: 'zm')), isNull);
      expect(
        await lookup.description(_src('Dune', type: ProviderType.movie)),
        isNull,
      );
      expect(search.calls, isEmpty);
    });

    test('keeps at most [capacity] titles, oldest dropped first', () async {
      final search = _FakeSearch((t, _) => _media(t));
      final lookup = HomeBannerAniList(search.call, capacity: 3);
      for (final t in ['A1', 'B1', 'C1']) {
        await lookup.description(_src(t));
      }
      // Using A1 again makes B1 the oldest.
      await lookup.description(_src('A1'));
      await lookup.description(_src('D1'));
      expect(lookup.cachedCount, 3);
      expect(lookup.holds(_src('A1')), isTrue);
      expect(lookup.holds(_src('B1')), isFalse);
      await lookup.description(_src('B1'));
      expect(search.calls.where((c) => c.$1 == 'B1'), hasLength(2));
    });

    test(
      'errors and 429 answer null, are not kept, and rest a while',
      () async {
        var now = DateTime(2026);
        final search = _FakeSearch((t, _) => _media(t))..error = _limited();
        final lookup = HomeBannerAniList(search.call, now: () => now);
        expect(await lookup.description(_src('Bleach')), isNull);
        expect(lookup.holds(_src('Bleach')), isFalse);
        // Resting: nothing is sent.
        search.error = null;
        now = now.add(const Duration(minutes: 1));
        expect(await lookup.description(_src('Bleach')), isNull);
        expect(search.calls, hasLength(1));
        // Rest over: asked again and answered.
        now = now.add(const Duration(minutes: 2));
        expect(await lookup.description(_src('Bleach')), isNotNull);
        expect(search.calls, hasLength(2));
      },
    );
  });

  group('HomeBannerMeta on Windows', () {
    // A short real delay stands in for the 1 s on-screen wait.
    const delay = Duration(milliseconds: 80);
    Future<void> wait(int ms) =>
        Future<void>.delayed(Duration(milliseconds: ms));

    test('asks only after the slide stayed on screen, never twice', () async {
      final search = _FakeSearch((t, _) => _media(t));
      final meta = HomeBannerMeta(
        loadDetail: _noDetail,
        windows: true,
        aniList: HomeBannerAniList(search.call),
        lookupDelay: delay,
      );
      final a = _src('Bleach');
      final b = _src('Naruto');

      final first = meta(a);
      // Rebuilds of the same slide share the one waiting future.
      expect(identical(first, meta(a)), isTrue);
      await wait(20);
      expect(search.calls, isEmpty);
      expect((await first)?.description, 'An AniList synopsis. Second line.');
      expect(search.calls, [('Bleach', false)]);

      // Skipped past within the delay: Naruto asks nothing.
      final skipped = meta(b);
      await wait(20);
      meta(a);
      expect(await skipped, isNull);
      await wait(150);
      expect(search.calls, hasLength(1));

      // Back on Bleach: answered from the kept result, no new request.
      expect((await meta(a))?.description, isNotNull);
      expect(search.calls, hasLength(1));
    });

    test('a "no match" slide is not asked again', () async {
      final search = _FakeSearch((_, _) => _media('Another Show'));
      final meta = HomeBannerMeta(
        loadDetail: _noDetail,
        windows: true,
        aniList: HomeBannerAniList(search.call),
        lookupDelay: delay,
      );
      expect(await meta(_src('Bleach')), isNull);
      expect(await meta(_src('Bleach')), isNull);
      expect(search.calls, hasLength(1));
    });

    test('a metadata catalogue slide never asks AniList', () async {
      final search = _FakeSearch((t, _) => _media(t));
      final meta = HomeBannerMeta(
        loadDetail: _noDetail,
        windows: true,
        aniList: HomeBannerAniList(search.call),
        lookupDelay: delay,
      );
      expect(await meta(_src('Bleach', sourceId: 'zm')), isNull);
      await wait(150);
      expect(search.calls, isEmpty);
    });
  });
}
