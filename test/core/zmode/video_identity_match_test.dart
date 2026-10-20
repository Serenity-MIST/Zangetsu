import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/zmode/match_store.dart';
import 'package:watch_app/core/zmode/source_matcher.dart';
import 'package:watch_app/core/zmode/video_identity.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/core/zmode/zmode_source_prefs.dart';

/// Provides the same-name movie and TV hits returned by CineStream.
class _Sources implements SourceRepository {
  List<MediaItem> results = [];
  int searches = 0;
  @override
  bool hasSource(String id) => true;
  @override
  Future<bool> ensureSourceLoaded(String id) async => true;
  @override
  Future<List<MediaItem>> search(
    String query, {
    String category = 'sub',
    String? sourceId,
  }) async {
    searches++;
    return results;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Builds an opaque provider hit without relying on CloudStream's coarse type.
MediaItem _hit(String url) => MediaItem(
  id: url,
  title: 'The Mentalist',
  url: url,
  type: ProviderType.movie,
  sourceId: 'cs:test',
);

/// Exercises automatic repair against isolated persistent match storage.
void main() {
  const movie = '{"id":"tt2111458","type":"movie"}';
  const series = '{"id":"tt1196946","type":"series"}';
  const tv = ZCanonical(ZKind.tv, 'tmdb:5920');
  late Directory dir;
  late MatchStore store;
  late SourceMatcher matcher;
  late _Sources sources;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('video-match-');
    Hive.init(dir.path);
    store = await MatchStore.open();
    sources = _Sources()..results = [_hit(movie), _hit(series)];
    matcher = SourceMatcher(
      sources: sources,
      store: store,
      prefs: await ZSourcePrefs.open(),
      candidates: (_) => [(id: 'cs:test', name: 'CineStream')],
    );
  });
  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });
  test('TV matching excludes same-name movies', () async {
    expect(
      (await matcher.matchOn(tv, 'cs:test', title: 'The Mentalist'))?.showUrl,
      series,
    );
  });
  test('movie matching excludes same-name series', () async {
    expect(
      (await matcher.matchOn(
        const ZCanonical(ZKind.movie, 'tmdb:1'),
        'cs:test',
        title: 'The Mentalist',
      ))?.showUrl,
      movie,
    );
  });
  test(
    'old automatic movie guess repairs and invalidates cached playback',
    () async {
      await store.save(
        tv,
        const SourceMatch(
          sourceId: 'cs:test',
          showUrl: movie,
          showId: 'old',
          showTitle: 'The Mentalist',
          pinned: false,
        ),
      );
      var changes = 0;
      matcher.bindSourceChanged((_) {
        changes++;
      });
      expect(
        (await matcher.matchOn(tv, 'cs:test', title: 'The Mentalist'))?.showUrl,
        series,
      );
      expect(store.get(tv, 'cs:test')?.showUrl, series);
      expect(changes, 1);
      await matcher.matchOn(tv, 'cs:test', title: 'The Mentalist');
      expect(sources.searches, 1);
    },
  );
  test('explicit pins remain untouched', () async {
    await store.pin(
      tv,
      const SourceMatch(
        sourceId: 'cs:test',
        showUrl: movie,
        showId: 'manual',
        showTitle: 'The Mentalist',
        pinned: true,
      ),
    );
    expect(
      (await matcher.matchOn(tv, 'cs:test', title: 'The Mentalist'))?.showUrl,
      movie,
    );
    expect(sources.searches, 0);
  });
  test(
    'an incompatible cached guess is not reused when series is absent',
    () async {
      await store.save(
        tv,
        const SourceMatch(
          sourceId: 'cs:test',
          showUrl: movie,
          showId: 'old',
          showTitle: 'The Mentalist',
          pinned: false,
        ),
      );
      sources.results = [_hit(movie)];
      expect(
        await matcher.matchOn(tv, 'cs:test', title: 'The Mentalist'),
        isNull,
      );
    },
  );
  test('unknown provider URLs remain candidates', () {
    expect(sourceVideoKind('https://example.com/show'), isNull);
    expect(sourceVideoKind('{broken'), isNull);
    expect(
      videoCandidatesFor(ZKind.tv, [_hit('https://example.com/show')]),
      hasLength(1),
    );
  });
}
