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
    DownloadRecord rec(
      String id,
      double number, {
      bool done = true,
      String source = 'source',
      String category = 'sub',
      int createdAt = 0,
      String? title,
    }) => DownloadRecord(
      id: 'show-$id',
      sourceId: source,
      showId: 'show',
      showTitle: 'Show',
      showUrl: '/show',
      episodeId: id,
      episodeUrl: '/$id',
      episodeTitle: title ?? 'Episode $id',
      episodeNumber: number,
      category: category,
      quality: '1080p',
      status: done ? DownloadStatus.done : DownloadStatus.queued,
      filePath: '/downloads/$id.mp4',
      createdAt: createdAt,
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

    test(
      'sub and dub runs never mix, even with matching episode ids',
      () async {
        final tapped = rec('e1', 1, category: 'dub');
        final queue = await downloadedSiblingQueue(
          showRecords: [
            rec('e1', 1, category: 'sub'),
            tapped,
            rec('e2', 2, category: 'sub'),
            rec('e2', 2, category: 'dub'),
          ],
          record: tapped,
          filePresent: (_) async => true,
        );

        expect(queue.episodes.map((e) => e.id), ['e1', 'e2']);
        expect(queue.startIndex, 0);
      },
    );

    test(
      'a same-id re-download from another source is a different run',
      () async {
        final tapped = rec('e1', 1, source: 'b');
        final queue = await downloadedSiblingQueue(
          showRecords: [
            rec('e1', 1, source: 'a'),
            tapped,
          ],
          record: tapped,
          filePresent: (_) async => true,
        );

        expect(queue.episodes, hasLength(1));
        expect(queue.startIndex, 0);
      },
    );

    test(
      'seasons stay in order when a whole batch shares a timestamp',
      () async {
        final tapped = rec('S1E1', 1, createdAt: 100);
        final queue = await downloadedSiblingQueue(
          showRecords: [
            rec('S2E2', 2, createdAt: 100),
            rec('S2E1', 1, createdAt: 100),
            rec('S1E2', 2, createdAt: 100),
            tapped,
          ],
          record: tapped,
          filePresent: (_) async => true,
        );

        expect(queue.episodes.map((e) => e.id), [
          'S1E1',
          'S1E2',
          'S2E1',
          'S2E2',
        ]);
        expect(queue.startIndex, 0);
        expect(queue.episodes.map((e) => e.season), [1, 1, 2, 2]);
      },
    );

    test('download time never decides season order', () async {
      final tapped = rec('S1E1', 1, createdAt: 1);
      final queue = await downloadedSiblingQueue(
        showRecords: [
          rec('S1E2', 2, createdAt: 4),
          rec('S2E2', 2, createdAt: 3),
          rec('S2E1', 1, createdAt: 2),
          tapped,
        ],
        record: tapped,
        filePresent: (_) async => true,
      );

      expect(queue.episodes.map((e) => e.id), ['S1E1', 'S1E2', 'S2E1', 'S2E2']);
    });

    test('older downloads can recover seasons from title prefixes', () async {
      final tapped = rec('a', 1, title: 'S1 E1 - First');
      final queue = await downloadedSiblingQueue(
        showRecords: [
          rec('d', 2, title: 'S2 · E2'),
          rec('c', 1, title: 'S2 · E1'),
          rec('b', 2, title: 'S1 E2 - Second'),
          tapped,
        ],
        record: tapped,
        filePresent: (_) async => true,
      );

      expect(queue.episodes.map((e) => e.id), ['a', 'b', 'c', 'd']);
    });

    test('saved source seasons survive storage and record updates', () async {
      DownloadRecord saved(String id, double number, int season) =>
          DownloadRecord.fromMap({
            ...rec(id, number).toMap(),
            'episodeSeason': season,
          }).copyWith(progress: 0.5);
      final tapped = saved('a', 1, 1);
      expect(tapped.toMap()['episodeSeason'], 1);
      final queue = await downloadedSiblingQueue(
        showRecords: [saved('c', 1, 2), saved('b', 2, 1), tapped],
        record: tapped,
        filePresent: (_) async => true,
      );

      expect(queue.episodes.map((e) => e.id), ['a', 'b', 'c']);
      expect(queue.episodes.map((e) => e.season), [1, 1, 2]);
    });

    test(
      'saved season zero takes precedence over title and ID guesses',
      () async {
        final tapped = DownloadRecord.fromMap({
          ...rec('S9E1', 1, title: 'S8 E1').toMap(),
          'episodeSeason': 0,
        });
        final queue = await downloadedSiblingQueue(
          showRecords: [rec('S1E1', 1), tapped],
          record: tapped,
          filePresent: (_) async => true,
        );

        expect(queue.episodes.map((e) => e.id), ['S9E1', 'S1E1']);
        expect(queue.episodes.map((e) => e.season), [0, 1]);
      },
    );

    test('S0 IDs without a source season remain unseasoned', () async {
      final tapped = rec('S0E1', 1);
      final queue = await downloadedSiblingQueue(
        showRecords: [rec('S0E2', 2), tapped],
        record: tapped,
        filePresent: (_) async => true,
      );

      expect(queue.episodes.map((e) => e.id), ['S0E1', 'S0E2']);
      expect(queue.episodes.map((e) => e.season), [null, null]);
    });

    test(
      'mixed known and unknown seasons never guess a next episode',
      () async {
        final tapped = rec('S1E2', 2);
        final queue = await downloadedSiblingQueue(
          showRecords: [tapped, rec('opaque', 1)],
          record: tapped,
          filePresent: (_) async => true,
        );

        expect(queue.episodes.map((e) => e.id), ['S1E2']);
      },
    );

    test('an unnumbered episode does not create an arbitrary queue', () async {
      final queue = await downloadedSiblingQueue(
        showRecords: [rec('e1', 1), record],
        record: record,
        filePresent: (_) async => true,
      );

      expect(queue.episodes.map((e) => e.id), ['e2']);
    });

    test(
      'ambiguous legacy numbering keeps only the selected episode',
      () async {
        final tapped = rec('b', 1);
        final queue = await downloadedSiblingQueue(
          showRecords: [rec('a', 1), tapped, rec('c', 2)],
          record: tapped,
          filePresent: (_) async => true,
        );

        expect(queue.episodes.map((e) => e.id), ['b']);
        expect(queue.startIndex, 0);
      },
    );

    test('an excluded selected file never selects a sibling instead', () async {
      final tapped = rec('e2', 2);
      final queue = await downloadedSiblingQueue(
        showRecords: [rec('e1', 1), tapped],
        record: tapped,
        filePresent: (r) async => r.episodeId != tapped.episodeId,
      );

      expect(queue.episodes.map((e) => e.id), ['e2']);
      expect(queue.startIndex, 0);
    });
  });
}
