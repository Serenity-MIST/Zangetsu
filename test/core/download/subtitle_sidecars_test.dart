import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:watch_app/core/download/download_record.dart';
import 'package:watch_app/core/download/subtitle_sidecars.dart';

/// The real naming used by the download manager (see the Sage show folder).
const _e1 =
    'The_Strongest_Sage_with_the_Weakest_Crest_S1E1_HD_-_1_-_1080p_82a86f7e88f6cfcdffa52489eab3374c';
const _e10 =
    'The_Strongest_Sage_with_the_Weakest_Crest_S1E10_HD_-_1_-_1080p_4ecfd34db5ad08adc8452922e61749df';

void main() {
  late Directory show;
  late Directory subs;

  setUp(() async {
    final root = await Directory.systemTemp.createTemp('sidecars');
    show = await Directory(p.join(root.path, 'Show')).create();
    subs = await Directory(p.join(show.path, 'Subtitles')).create();
  });
  tearDown(() async {
    final root = show.parent;
    if (await root.exists()) await root.delete(recursive: true);
  });

  File video(String stem, [String ext = '.ts']) =>
      File(p.join(show.path, '$stem$ext'))..writeAsBytesSync([1, 2, 3]);
  File sub(
    String name, [
    String body = '1\n00:00:01,000 --> 00:00:02,000\nHi',
  ]) => File(p.join(subs.path, name))..writeAsStringSync(body);

  group('discoverSubtitleSidecars', () {
    test('finds the real-named files the download manager writes', () {
      final v = video(_e1);
      sub('${_e1}_English_1.vtt');
      final found = discoverSubtitleSidecars(v.path);
      expect(found, hasLength(1));
      expect(found.single.path, p.join(subs.path, '${_e1}_English_1.vtt'));
      expect(found.single.lang, 'English');
      expect(found.single.isDefault, isTrue);
    });

    test('turns the saved name back into a readable language', () {
      final v = video(_e10, '.mp4');
      sub('${_e10}_English__Original_Audio__1.srt');
      expect(
        discoverSubtitleSidecars(v.path).single.lang,
        'English Original Audio',
      );
    });

    test('never picks up another episode, even 10 for 1', () {
      final v1 = video(_e1);
      video(_e10, '.mp4');
      sub('${_e1}_English_1.vtt');
      sub('${_e10}_English__Original_Audio__1.srt');
      final found = discoverSubtitleSidecars(v1.path);
      expect(found, hasLength(1));
      expect(p.basename(found.single.path), startsWith(_e1));
    });

    test('orders several tracks by number and defaults the first', () {
      final v = video(_e1);
      sub('${_e1}_Spanish_2.srt');
      sub('${_e1}_English_1.srt');
      final found = discoverSubtitleSidecars(v.path);
      expect(found.map((s) => s.lang), ['English', 'Spanish']);
      expect(found.map((s) => s.isDefault), [true, false]);
    });

    test('accepts the number-only HLS rendition name', () {
      final v = video(_e1);
      sub('${_e1}_1.vtt');
      expect(discoverSubtitleSidecars(v.path).single.lang, 'Subtitles');
    });

    test('keeps subtitles whose language name became underscores', () {
      // "日本語" or a blank language is saved as underscores; still a subtitle.
      final v = video(_e1);
      sub('${_e1}____1.vtt');
      sub('${_e1}__2.srt');
      final found = discoverSubtitleSidecars(v.path);
      expect(found, hasLength(2));
      expect(found.every((s) => s.lang == kUnlabelledSubtitle), isTrue);
    });

    test('accepts .sub files too', () {
      final v = video(_e1);
      sub('${_e1}_English_1.sub');
      expect(discoverSubtitleSidecars(v.path), hasLength(1));
    });

    test('ignores empty files, other file types and foreign names', () {
      final v = video(_e1);
      sub('${_e1}_English_1.srt', '');
      sub('${_e1}_English_2.txt');
      sub('${_e1}English_3.srt'); // no separator after the name
      sub('${_e1}_English_x.srt'); // no track number
      sub('random_English_1.srt');
      File(p.join(subs.path, '${_e1}_English_4.vtt')).createSync(); // empty
      expect(discoverSubtitleSidecars(v.path), isEmpty);
    });

    test('works without a Subtitles folder and for odd inputs', () async {
      final v = video(_e1);
      await subs.delete(recursive: true);
      expect(discoverSubtitleSidecars(v.path), isEmpty);
      expect(discoverSubtitleSidecars(''), isEmpty);
    });

    test('only reads: nothing on disk changes', () {
      final v = video(_e1);
      final s = sub('${_e1}_English_1.vtt');
      final before = s.lastModifiedSync();
      discoverSubtitleSidecars(v.path);
      expect(s.lastModifiedSync(), before);
      expect(subs.listSync(), hasLength(1));
    });
  });

  group('playableSubtitlesFor', () {
    DownloadRecord record(String path, List<OfflineSubtitle> subs) =>
        DownloadRecord(
          id: 'r',
          sourceId: 's',
          showId: 'show',
          showTitle: 'Sage',
          showUrl: 'u',
          episodeId: 'e',
          episodeUrl: 'u',
          episodeTitle: 'E1',
          category: 'sub',
          quality: '1080p',
          status: DownloadStatus.done,
          filePath: path,
          subtitles: subs,
          createdAt: 1,
        );

    test('an empty record list falls back to the files on disk (the bug)', () {
      final v = video(_e1);
      sub('${_e1}_English_1.vtt');
      final subsFound = playableSubtitlesFor(record(v.path, const []));
      expect(subsFound, hasLength(1));
      expect(subsFound.single.lang, 'English');
    });

    test('a record whose own files exist keeps its own list', () {
      final v = video(_e1);
      final own = sub('${_e1}_Japanese_1.srt');
      sub('${_e1}_English_2.srt');
      final list = playableSubtitlesFor(
        record(v.path, [OfflineSubtitle(lang: 'ja', path: own.path)]),
      );
      expect(list.map((s) => s.lang), ['ja']);
    });

    test(
      'entries pointing at missing files are dropped, then disk is used',
      () {
        final v = video(_e1);
        sub('${_e1}_English_1.vtt');
        final list = playableSubtitlesFor(
          record(v.path, [
            OfflineSubtitle(lang: 'en', path: p.join(show.path, 'gone.srt')),
          ]),
        );
        expect(list.single.lang, 'English');
      },
    );
  });
}
