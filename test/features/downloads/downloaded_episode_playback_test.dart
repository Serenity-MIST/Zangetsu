import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/download_record.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/features/downloads/downloaded_episode_playback.dart';

void main() {
  const record = DownloadRecord(
    id: 'show-e2',
    sourceId: 'source',
    showId: 'show',
    showTitle: 'Show',
    showUrl: '/show',
    episodeId: 'e2',
    episodeUrl: '/e2',
    episodeTitle: 'Episode 2',
    category: 'sub',
    quality: '1080p',
    status: DownloadStatus.done,
    filePath: '/downloads/e2.mp4',
    createdAt: 0,
  );

  test('downloaded detail playback preserves the full episode queue', () {
    const episodes = [
      Episode(id: 'e1', title: 'Episode 1', url: '/e1', number: 1),
      Episode(id: 'e2', title: 'Episode 2', url: '/e2', number: 2),
      Episode(id: 'e3', title: 'Episode 3', url: '/e3', number: 3),
    ];

    final queue = downloadedEpisodePlaybackQueue(
      record: record,
      episodes: episodes,
      startIndex: 1,
    );

    expect(queue.episodes, episodes);
    expect(queue.startIndex, 1);
  });

  test('Downloads playback defaults to the selected episode only', () {
    final queue = downloadedEpisodePlaybackQueue(record: record);

    expect(queue.episodes, hasLength(1));
    expect(queue.episodes.single.id, 'e2');
    expect(queue.startIndex, 0);
  });

  test('a downloaded source points directly at the saved file', () {
    final source = downloadedVideoSource(record);

    expect(source.url, '/downloads/e2.mp4');
    expect(source.container, SourceContainer.mp4);
  });

  group('downloaded sibling queue', () {
    DownloadRecord rec(String id, double number, {bool done = true}) =>
        DownloadRecord(
          id: 'show-$id',
          sourceId: 'source',
          showId: 'show',
          showTitle: 'Show',
          showUrl: '/show',
          episodeId: id,
          episodeUrl: '/$id',
          episodeTitle: 'Episode $id',
          episodeNumber: number,
          category: 'sub',
          quality: '1080p',
          status: done ? DownloadStatus.done : DownloadStatus.queued,
          filePath: '/downloads/$id.mp4',
          createdAt: 0,
        );

    test(
      'lists the whole downloaded season starting at the tapped one',
      () async {
        final tapped = rec('e2', 2);
        final queue = await downloadedSiblingQueue(
          showRecords: [rec('e3', 3), rec('e1', 1), tapped],
          record: tapped,
          filePresent: (_) async => true,
        );

        expect(queue.episodes.map((e) => e.id), ['e1', 'e2', 'e3']);
        expect(queue.startIndex, 1);
      },
    );

    test('skips unfinished and missing files so Next never stalls', () async {
      final tapped = rec('e1', 1);
      final queue = await downloadedSiblingQueue(
        showRecords: [tapped, rec('e2', 2, done: false), rec('e3', 3)],
        record: tapped,
        // e3's file was deleted outside the app.
        filePresent: (r) async => r.episodeId != 'e3',
      );

      expect(queue.episodes.map((e) => e.id), ['e1']);
      expect(queue.startIndex, 0);
    });

    for (final mismatch in ['source', 'category', 'season']) {
      test('offline season queue excludes a different $mismatch', () async {
        final tapped = DownloadRecord.fromMap({...record.toMap(), 'season': 1});
        final unrelated = DownloadRecord.fromMap({
          ...tapped.toMap(),
          'id': 'other-record',
          'episodeId': 'other-episode',
          'episodeNumber': 1,
          if (mismatch == 'source') 'sourceId': 'another-source',
          if (mismatch == 'category') 'category': 'dub',
          if (mismatch == 'season') 'season': 2,
        });
        final queue = await downloadedSiblingQueue(
          showRecords: [unrelated, tapped],
          record: tapped,
          filePresent: (_) async => true,
        );
        expect(queue.episodes.map((episode) => episode.id), [tapped.episodeId]);
        expect(queue.startIndex, 0);
        expect(queue.episodes.single.season, 1);
      });
    }

    DownloadRecord legacy(String id, double? number, {String title = '', int? season}) =>
        DownloadRecord.fromMap({...record.toMap(), 'id': id, 'episodeId': id,
          'episodeTitle': title, 'episodeNumber': number, 'season': season});

    test('legacy structured seasons join explicit season without crossing cuts', () async {
      final tapped = legacy('S2E2', 2);
      final queue = await downloadedSiblingQueue(
        showRecords: [legacy('plain', 1, title: 'S2 \u00b7 E1'), tapped,
          legacy('S1E3', 3), legacy('S0E4', 4),
          legacy('explicit', 3, season: 2)],
        record: tapped, filePresent: (_) async => true);
      expect(queue.episodes.map((e) => e.id), ['plain', 'S2E2', 'explicit']);
      expect(queue.episodes.every((e) => e.season == 2), isTrue);
      expect(queue.startIndex, 1);
    });

    test('explicit season wins and S0 IDs may use a structured title', () {
      expect(downloadedEpisodePlaybackQueue(record: legacy('S2E1', 1, season: 0))
          .episodes.single.season, 0);
      expect(downloadedEpisodePlaybackQueue(record: legacy('S0E1', 1, title: 's3. E1'))
          .episodes.single.season, 3);
      expect(downloadedEpisodePlaybackQueue(record: legacy('S0E1', 1, title: 'Show 2026'))
          .episodes.single.season, isNull);
      expect(downloadedEpisodePlaybackQueue(record: legacy('S20omething', 1))
          .episodes.single.season, isNull);
    });

    test('fractional episodes retain numeric order', () async {
      final tapped = legacy('e2', 2);
      final queue = await downloadedSiblingQueue(showRecords: [tapped,
        legacy('special', 1.5), legacy('e1', 1)], record: tapped,
        filePresent: (_) async => true);
      expect(queue.episodes.map((e) => e.number), [1, 1.5, 2]);
      expect(queue.startIndex, 2);
    });

    for (final number in <double?>[null, double.nan, double.infinity, 2]) {
      test('ambiguous position $number retains only tapped episode', () async {
        final tapped = legacy('e2', 2);
        final queue = await downloadedSiblingQueue(showRecords: [tapped,
          legacy('other', number)], record: tapped, filePresent: (_) async => true);
        expect(queue.episodes.map((e) => e.id), ['e2']);
        expect(queue.startIndex, 0);
      });
    }

    test('missing tapped file never starts an available sibling instead', () async {
      final tapped = legacy('e2', 2);
      final queue = await downloadedSiblingQueue(showRecords: [legacy('e1', 1), tapped],
        record: tapped, filePresent: (r) async => r.id != tapped.id);
      expect(queue.episodes.map((e) => e.id), ['e2']);
      expect(queue.startIndex, 0);
    });

    test('falls back to the single entry when nothing is on disk', () async {
      final queue = await downloadedSiblingQueue(
        showRecords: [record],
        record: record,
        filePresent: (_) async => false,
      );

      expect(queue.episodes, hasLength(1));
      expect(queue.episodes.single.id, 'e2');
      expect(queue.startIndex, 0);
    });
  });
}
