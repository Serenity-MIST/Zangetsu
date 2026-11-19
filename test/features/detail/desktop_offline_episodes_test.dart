import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/download_record.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/features/detail/desktop_offline_episodes.dart';

DownloadRecord _rec(
  String id, {
  String showUrl = 'zm://anime/mal/1',
  String title = 'The Strongest Sage',
  double? ep,
  int? malId,
  DownloadStatus status = DownloadStatus.done,
  int createdAt = 1,
  String category = 'sub',
}) =>
    DownloadRecord(
      id: id,
      sourceId: 'src',
      showId: 'show',
      showTitle: title,
      showUrl: showUrl,
      episodeId: 'e$ep',
      episodeUrl: 'u$ep',
      episodeNumber: ep,
      episodeTitle: 'Episode $ep',
      category: category,
      quality: 'best',
      status: status,
      filePath: 'C:/x/$id.mp4',
      malId: malId,
      createdAt: createdAt,
    );

void main() {
  test('matches by page, id or title; keeps finished ones in order', () {
    final got = downloadsForShow(
      [
        _rec('a', ep: 2),
        _rec('b', ep: 1, showUrl: 'https://source/sage', malId: 44),
        _rec('c', ep: 3, showUrl: 'other', title: 'the strongest sage '),
        _rec('d', ep: 4, status: DownloadStatus.downloading),
        _rec('e', ep: 5, showUrl: 'other', title: 'Another show'),
      ],
      showUrl: 'zm://anime/mal/1',
      malId: 44,
      title: 'The Strongest Sage',
    );
    expect(got.map((r) => r.id), ['b', 'a', 'c']);
  });

  test('one copy per episode, the newest', () {
    final got = downloadsForShow(
      [_rec('old', ep: 1, createdAt: 1), _rec('new', ep: 1, createdAt: 9)],
      showUrl: 'zm://anime/mal/1',
    );
    expect(got.single.id, 'new');
  });

  // The downloaded show page lists exactly these.
  test('saved episodes: finished files only, one per episode, in order', () {
    final got = savedDownloadEpisodes([
      _rec('b', ep: 2),
      _rec('a1', ep: 1, createdAt: 1),
      _rec('a2', ep: 1, createdAt: 5),
      _rec('c', ep: 3, status: DownloadStatus.failed),
    ]);
    expect(got.map((r) => r.id), ['a2', 'b']);
  });

  test('main category is the cut most files were saved in', () {
    expect(mainDownloadCategory(const []), isNull);
    expect(
      mainDownloadCategory([
        _rec('a', ep: 1, category: 'dub'),
        _rec('b', ep: 2, category: 'dub'),
        _rec('c', ep: 3),
      ]),
      'dub',
    );
  });

  test('the play queue follows the same order', () {
    final recs = [_rec('a', ep: 1), _rec('b', ep: 2)];
    expect(episodesFromDownloads(recs).map((e) => e.number), [1, 2]);
  });

  test('Play starts on the last episode, or the next once it is finished', () {
    final recs = [_rec('a', ep: 1), _rec('b', ep: 2), _rec('c', ep: 3)];
    expect(downloadStartIndex(recs), 0); // never watched
    expect(downloadStartIndex(recs, lastEpisode: 2), 1); // continue ep 2
    expect(downloadStartIndex(recs, lastEpisode: 2, lastFinished: true), 2);
    // Finished the last saved one: stay on it rather than run off the end.
    expect(downloadStartIndex(recs, lastEpisode: 3, lastFinished: true), 2);
    expect(downloadStartIndex(recs, lastEpisode: 9), 0); // not downloaded
  });

  test('saved rows take the saved episode metadata, keep their identity', () {
    // Rows of saved files: e1.0 matches by id, the other only by number.
    final saved = [
      const Episode(
        id: 'e1.0',
        title: 'Episode 1.0',
        number: 1,
        url: 'u1.0',
        thumbnail: 'https://img/rec1.jpg',
      ),
      const Episode(id: 'other', title: 'Ep two', number: 2, url: 'u2'),
      const Episode(id: 'none', title: 'Ep nine', number: 9, url: 'u9'),
    ];
    final meta = [
      const Episode(
        id: 'e1.0',
        title: 'The Strongest Sage Appears.',
        number: 1,
        url: 'meta-u1',
        thumbnail: 'file:///C:/show/.zangetsu/art/meta/a.jpg',
        description: 'He takes the exam.',
        date: '2022-01-08',
        rating: 6,
        runtimeMinutes: 24,
      ),
      const Episode(
        id: 'meta-2',
        title: 'Enters the Dungeon',
        number: 2,
        url: 'meta-u2',
        thumbnail: 'https://img/meta2.jpg',
        description: 'Into the dungeon.',
      ),
    ];
    final out = mergeSavedEpisodeMeta(saved, meta);
    expect(out, hasLength(3));
    // Identity stays the record's so playback and download lookups work.
    expect(out[0].id, 'e1.0');
    expect(out[0].url, 'u1.0');
    expect(out[0].title, 'Episode 1.0');
    // Metadata comes from the saved list; the local image wins.
    expect(out[0].description, 'He takes the exam.');
    expect(out[0].date, '2022-01-08');
    expect(out[0].rating, 6);
    expect(out[0].runtimeMinutes, 24);
    expect(out[0].thumbnail, startsWith('file:'));
    // Matched by number; a remote meta image does not replace none.
    expect(out[1].id, 'other');
    expect(out[1].description, 'Into the dungeon.');
    expect(out[1].thumbnail, 'https://img/meta2.jpg');
    // No match: unchanged.
    expect(out[2], saved[2]);
    // Nothing saved: rows as they are.
    expect(mergeSavedEpisodeMeta(saved, const []), same(saved));
  });
}
