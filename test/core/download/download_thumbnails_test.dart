import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/chapter_download.dart';
import 'package:watch_app/core/download/download_record.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/features/downloads/download_thumbnail.dart';

void main() {
  test(
    'legacy video/chapter records have nullable artwork without changing IDs',
    () {
      final video = DownloadRecord.fromMap({'id': 'legacy'});
      expect(video.episodeThumbnail, isNull);
      final chapter = ChapterDownload.fromJson({'id': 'legacy'})!;
      expect(chapter.thumbnail, isNull);
      expect(chapter.coverHeaders, isNull);
      expect(video.id, 'legacy');
      expect(chapter.id, 'legacy');
    },
  );
  test('video and chapter artwork survive persistence and status updates', () {
    final video = DownloadRecord.fromMap({
      'id': 'video',
      'episodeThumbnail': 'https://image/episode',
      'coverHeaders': {'Referer': 'https://source'},
    });
    final copy = DownloadRecord.fromMap(
      video.copyWith(status: DownloadStatus.done).toMap(),
    );
    expect(copy.episodeThumbnail, 'https://image/episode');
    expect(copy.coverHeaders, {'Referer': 'https://source'});
    final chapter = ChapterDownload.fromJson({
      'id': 'chapter',
      'thumbnail': 'https://image/chapter',
      'coverHeaders': {'Referer': 'https://source'},
    })!;
    final saved = ChapterDownload.fromJson(
      chapter.copyWith(status: ChapterDownloadStatus.done).toJson(),
    )!;
    expect(saved.thumbnail, 'https://image/chapter');
    expect(saved.coverHeaders, {'Referer': 'https://source'});
  });
  test('image headers never disclose credentials to a different origin', () {
    const headers = {
      'Cookie': 'fixture',
      'AUTHORIZATION': 'fixture',
      'Proxy-Authorization': 'fixture',
      'Referer': 'https://source',
      'User-Agent': 'fixture',
    };
    expect(
      downloadArtworkHeaders(
        'https://a.test/thumb',
        'https://a.test/cover',
        headers,
      ),
      headers,
    );
    for (final url in [
      'https://b.test/thumb',
      'http://a.test/thumb',
      'https://a.test:444/thumb',
    ]) {
      final scoped = downloadArtworkHeaders(
        url,
        'https://a.test/cover',
        headers,
      )!;
      expect(scoped.keys, ['Referer', 'User-Agent']);
    }
    expect(headers, contains('Cookie'));
  });
  testWidgets('missing artwork leaves a visible offline fallback', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SizedBox(
          width: 80,
          height: 48,
          child: DownloadThumbnail(fallback: Text('Offline fallback')),
        ),
      ),
    );
    expect(find.text('Offline fallback'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('season saved by either app version loads into both season fields', () {
    final windows = DownloadRecord.fromMap({'id': 'w', 'season': 2});
    final upstream = DownloadRecord.fromMap({'id': 'u', 'episodeSeason': 3});
    expect((windows.season, windows.episodeSeason), (2, 2));
    expect((upstream.season, upstream.episodeSeason), (3, 3));
    final saved = windows.toMap();
    expect((saved['season'], saved['episodeSeason']), (2, 2));
  });

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
