import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/chapter_download.dart';
import 'package:watch_app/core/download/download_record.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/features/downloads/desktop_download_bulk_delete.dart';
import 'package:watch_app/features/downloads/desktop_download_library.dart';

DownloadRecord _video(
  String id, {
  String show = 'show',
  String title = 'Show',
  DownloadStatus status = DownloadStatus.done,
  int bytes = 0,
}) => DownloadRecord(
  id: id,
  sourceId: 'src',
  showId: show,
  showTitle: title,
  showUrl: '/s',
  episodeId: id,
  episodeUrl: '/e/$id',
  episodeTitle: 'Episode $id',
  category: 'sub',
  quality: 'best',
  status: status,
  bytesTotal: bytes,
  createdAt: 1,
);

ChapterDownload _chapter(
  String id, {
  ChapterDownloadStatus status = ChapterDownloadStatus.done,
}) => ChapterDownload(
  id: id,
  sourceId: 'src',
  showId: 'manga',
  showTitle: 'Manga',
  chapterId: id,
  chapterUrl: '/c',
  chapterTitle: 'Chapter $id',
  mode: ContentMode.manga,
  status: status,
);

void main() {
  group('planBulkDelete', () {
    test('counts what the library shows; failed ones still go along', () {
      final shows = desktopDownloadCollections(
        videos: [
          _video('a1', show: 'a', title: 'A', bytes: 100),
          _video('a2', show: 'a', title: 'A', status: DownloadStatus.failed),
          _video('b1', show: 'b', title: 'B', bytes: 50),
        ],
        chapters: [_chapter('m1'), _chapter('m2')],
      );
      final plan = planBulkDelete(shows);
      expect(plan.shows, 3);
      expect(plan.videos, hasLength(2));
      expect(plan.failedVideos.single.id, 'a2');
      expect(plan.chapters, hasLength(2));
      expect(plan.items, 4);
    });

    test('a failed entry that still owns a saved file is counted', () {
      final plan = planBulkDelete(desktopDownloadCollections(
        videos: [
          _video('a1'),
          _video('a2', status: DownloadStatus.failed),
          DownloadRecord.fromMap({
            ..._video('a3', status: DownloadStatus.unsupported).toMap(),
            'retainedMediaPaths': [r'D:\old.mp4'],
          }),
        ],
        chapters: const [],
      ));
      expect(plan.items, 2);
    });

    test('counts running downloads, which would be canceled', () {
      final shows = desktopDownloadCollections(
        videos: [
          _video('a1', status: DownloadStatus.downloading),
          _video('a2', status: DownloadStatus.queued),
          _video('a3'),
        ],
        chapters: [_chapter('m1', status: ChapterDownloadStatus.downloading)],
      );
      expect(planBulkDelete(shows).active, 3);
    });

    test('size only counts finished videos with a known size', () {
      final shows = desktopDownloadCollections(
        videos: [
          _video('a1', bytes: 1000),
          _video('a2', bytes: 500, status: DownloadStatus.downloading),
          _video('a3'),
        ],
        chapters: const [],
      );
      expect(planBulkDelete(shows).knownBytes, 1000);
    });

    test('nothing chosen is an empty plan', () {
      final plan = planBulkDelete(const []);
      expect(plan.shows, 0);
      expect(plan.items, 0);
      expect(plan.active, 0);
    });
  });

  group('describeBulkDelete', () {
    BulkDeletePlan plan(int shows, List<DownloadRecord> v, [List<ChapterDownload> c = const []]) =>
        BulkDeletePlan(shows: shows, videos: v, chapters: c);

    test('says what goes, that files are removed, and that it is permanent', () {
      final text = describeBulkDelete(plan(2, [_video('1'), _video('2')]));
      expect(text, contains('2 shows'));
      expect(text, contains('2 downloads'));
      expect(text, contains('saved files are removed'));
      expect(text, contains('cannot be undone'));
    });

    // Windows sends finished files to the Recycle Bin, so the text must not
    // claim the delete is permanent.
    test('mentions the Recycle Bin instead of "cannot be undone" when recycling', () {
      final text = describeBulkDelete(plan(1, [_video('1')]), recycle: true);
      expect(text, contains('Recycle Bin'));
      expect(text, isNot(contains('cannot be undone')));
    });

    test('uses singular wording for one show and one download', () {
      final text = describeBulkDelete(plan(1, [_video('1')]));
      expect(text, contains('1 show '));
      expect(text, contains('1 download'));
      expect(text, isNot(contains('1 shows')));
    });

    test('includes the size as a lower bound when known', () {
      final text = describeBulkDelete(
        plan(1, [_video('1', bytes: 3 * 1024 * 1024 * 1024)]),
      );
      expect(text, contains('at least 3.0 GB'));
    });

    test('warns about running downloads only when there are some', () {
      expect(describeBulkDelete(plan(1, [_video('1')])), isNot(contains('canceled')));
      final active = describeBulkDelete(
        plan(1, [_video('1', status: DownloadStatus.downloading)]),
      );
      expect(active, contains('1 still downloading will be canceled'));
    });
  });

  group('formatBytes', () {
    test('picks a readable unit', () {
      expect(formatBytes(512 * 1024), '512 KB');
      expect(formatBytes(320 * 1024 * 1024), '320 MB');
      expect(formatBytes(1536 * 1024 * 1024), '1.5 GB');
    });
  });

  group('executeBulkDelete', () {
    test('deletes videos together and chapters one by one', () async {
      final plan = BulkDeletePlan(
        shows: 2,
        videos: [_video('1'), _video('2')],
        chapters: [_chapter('m1'), _chapter('m2')],
      );
      final deletedVideos = <String>[];
      final deletedChapters = <String>[];
      final failed = await executeBulkDelete(
        plan,
        deleteVideos: (v) async => deletedVideos.addAll(v.map((r) => r.id)),
        deleteChapter: (c) async => deletedChapters.add(c.id),
      );
      expect(failed, 0);
      expect(deletedVideos, ['1', '2']);
      expect(deletedChapters, ['m1', 'm2']);
    });

    test('failed entries of the show are deleted with it', () async {
      final plan = BulkDeletePlan(
        shows: 1,
        videos: [_video('1')],
        chapters: [_chapter('m1')],
        failedVideos: [_video('bad', status: DownloadStatus.failed)],
        failedChapters: [_chapter('m2')],
      );
      final deleted = <String>[];
      await executeBulkDelete(
        plan,
        deleteVideos: (v) async => deleted.addAll(v.map((r) => r.id)),
        deleteChapter: (c) async => deleted.add(c.id),
      );
      expect(deleted, ['1', 'bad', 'm1', 'm2']);
    });

    test('one failing chapter never stops the rest', () async {
      final plan = BulkDeletePlan(
        shows: 1,
        videos: const [],
        chapters: [_chapter('m1'), _chapter('m2'), _chapter('m3')],
      );
      final done = <String>[];
      final failed = await executeBulkDelete(
        plan,
        deleteVideos: (_) async {},
        deleteChapter: (c) async {
          if (c.id == 'm2') throw StateError('locked');
          done.add(c.id);
        },
      );
      expect(failed, 1);
      expect(done, ['m1', 'm3']);
    });

    test('a failing video delete is reported and chapters still go', () async {
      final plan = BulkDeletePlan(
        shows: 2,
        videos: [_video('1'), _video('2')],
        chapters: [_chapter('m1')],
      );
      final chapters = <String>[];
      final failed = await executeBulkDelete(
        plan,
        deleteVideos: (_) async => throw StateError('disk'),
        deleteChapter: (c) async => chapters.add(c.id),
      );
      expect(failed, 2);
      expect(chapters, ['m1']);
    });
  });
}
