import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/chapter_download.dart';
import 'package:watch_app/core/download/download_record.dart';
import 'package:watch_app/core/mode/content_mode.dart';

void main() {
  test('DownloadRecord keeps the per-episode thumbnail across a save/load', () {
    final rec = DownloadRecord(
      id: 'd1',
      sourceId: 'src',
      showId: 'show',
      showTitle: 'Show',
      showUrl: '/show/1',
      episodeId: 'ep1',
      episodeUrl: '/ep1',
      episodeNumber: 1,
      episodeTitle: 'Pilot',
      episodeThumbnail: 'https://img/ep1.jpg',
      category: 'sub',
      quality: '1080p',
      status: DownloadStatus.done,
      progress: 1,
      bytesTotal: 10,
      createdAt: 0,
    );

    final back = DownloadRecord.fromMap(rec.toMap());
    expect(back.episodeThumbnail, 'https://img/ep1.jpg');
    // copyWith() rebuilds every field by hand — it must not drop the still.
    expect(
      back.copyWith(progress: 0.5).episodeThumbnail,
      'https://img/ep1.jpg',
    );
  });

  test('DownloadRecord from an older map has a null thumbnail', () {
    final back = DownloadRecord.fromMap({
      'id': 'd1',
      'episodeTitle': 'Pilot',
      'category': 'sub',
      'quality': 'best',
      'status': 'done',
    });
    expect(back.episodeThumbnail, isNull);
  });

  test('ChapterDownload keeps the chapter thumbnail across a save/load', () {
    final rec = ChapterDownload(
      id: 'src|/ch1',
      sourceId: 'src',
      showId: 'show',
      showTitle: 'Show',
      chapterId: 'ch1',
      chapterUrl: '/ch1',
      chapterTitle: 'Chapter 1',
      mode: ContentMode.manga,
      status: ChapterDownloadStatus.done,
      thumbnail: 'https://img/ch1.jpg',
    );

    final back = ChapterDownload.fromJson(rec.toJson())!;
    expect(back.thumbnail, 'https://img/ch1.jpg');
  });
}
