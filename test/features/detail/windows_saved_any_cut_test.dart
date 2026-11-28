// B1: the Windows show page finds an episode saved in another cut (the
// Frieren case: files saved as Dub, page looks them up as Sub). Record values
// follow the real records in plans/inputs/frieren-downloads.md.
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/download_record.dart';
import 'package:watch_app/features/detail/desktop_existing_downloads.dart';
import 'package:watch_app/l10n/app_localizations.dart';

const _source = 'zm';
const _show = 'anime:mal:59978';

DownloadRecord _rec(
  String episodeId, {
  String category = 'dub',
  DownloadStatus status = DownloadStatus.done,
  double? number,
  int? season = 1,
  String? showId,
  String? sourceId,
  int? malId = 59978,
  int createdAt = 1,
  String? filePath = 'C:/Videos/Frieren/ep.mp4',
  int bytesTotal = 0,
}) => DownloadRecord(
  bytesTotal: bytesTotal,
  id: 'download_${episodeId}_$category',
  sourceId: sourceId ?? _source,
  showId: showId ?? _show,
  showTitle: 'Frieren',
  showUrl: 'zm://anime/mal:59978',
  episodeId: episodeId,
  episodeUrl: 'zm://anime/mal:59978/ep/$episodeId',
  episodeNumber: number ?? double.tryParse(episodeId),
  season: season,
  episodeTitle: 'Episode $episodeId',
  category: category,
  quality: 'best',
  status: status,
  progress: status == DownloadStatus.done ? 1 : 0,
  filePath: status == DownloadStatus.done ? filePath : null,
  malId: malId,
  createdAt: createdAt,
);

/// The real Frieren set: E1..E6 dub done, E8 dub unsupported, E9 a folder-
/// scan record with a `file:` episode id and an unknown cut, E7 nothing.
List<DownloadRecord> _frieren() => [
  for (var i = 1; i <= 6; i++) _rec('$i'),
  _rec('8', status: DownloadStatus.unsupported),
  _rec('file:307c', category: 'unknown', number: 9),
];

DownloadRecord? _find(
  List<DownloadRecord> records,
  String episodeId, {
  double? number,
  int? season = 1,
  int? malId = 59978,
  String preferred = 'sub',
}) => savedEpisodeAnyCut(
  records,
  sourceId: _source,
  showId: _show,
  episodeId: episodeId,
  episodeNumber: number ?? double.tryParse(episodeId),
  season: season,
  malId: malId,
  preferredCategory: preferred,
);

void main() {
  group('savedEpisodeAnyCut (Frieren records)', () {
    test('E1 saved as Dub is found from a Sub page', () {
      final r = _find(_frieren(), '1');
      expect(r, isNotNull);
      expect(r!.category, 'dub');
      expect(r.episodeId, '1');
    });

    test('E7 has no record, so nothing is found', () {
      expect(_find(_frieren(), '7'), isNull);
    });

    test('E8 is only an unsupported record, so nothing is found', () {
      expect(_find(_frieren(), '8'), isNull);
    });

    // Size not recorded here (0): only the number matching is under test.
    test('E9 folder-scan record is found by its episode number', () {
      final r = _find(_frieren(), '9');
      expect(r, isNotNull);
      expect(r!.episodeId, 'file:307c');
      expect(r.category, 'unknown');
    });

    test('the real E9 stub (788 KB marked done) is not offered', () {
      // The tester's E9 record: folder-scan id, unknown cut, done, but only
      // 788 KB. The tick must stay off and Play must stream instead.
      final records = [
        for (var i = 1; i <= 6; i++) _rec('$i', bytesTotal: 350 * 1024 * 1024),
        _rec('file:307c', category: 'unknown', number: 9, bytesTotal: 788 * 1024),
      ];
      expect(_find(records, '9'), isNull);
      expect(_find(records, '2'), isNotNull);
    });

    test('with both cuts saved, the page cut wins', () {
      final records = [
        _rec('3', category: 'dub', createdAt: 5),
        _rec('3', category: 'sub', createdAt: 1),
      ];
      expect(_find(records, '3')!.category, 'sub');
      expect(_find(records, '3', preferred: 'dub')!.category, 'dub');
    });

    test('without the preferred cut, the newest download wins', () {
      final records = [
        _rec('4', category: 'dub', createdAt: 1),
        _rec('4', category: 'unknown', createdAt: 9),
      ];
      expect(_find(records, '4')!.category, 'unknown');
    });

    test('a same-id record beats a number-only match', () {
      final records = [
        _rec('file:aaaa', category: 'sub', number: 2, createdAt: 9),
        _rec('2', category: 'dub', createdAt: 1),
      ];
      expect(_find(records, '2')!.episodeId, '2');
    });

    test('another season with the same number is not this episode', () {
      final records = [_rec('file:s2', category: 'dub', number: 9, season: 2)];
      expect(_find(records, '9', season: 1), isNull);
    });

    test('a different show with the same number is not matched', () {
      final records = [
        _rec('5', showId: 'anime:mal:1', sourceId: 'zm', malId: 1),
      ];
      expect(_find(records, '5'), isNull);
    });

    test('the MAL id matches a record saved from another page', () {
      final records = [
        _rec('src-ep-5', showId: 'other-show', sourceId: 'anikoto', number: 5),
      ];
      expect(_find(records, '5')!.episodeId, 'src-ep-5');
      expect(_find(records, '5', malId: null), isNull);
    });

    test('a finished record without a file path does not count', () {
      final records = [_rec('6', filePath: null)];
      expect(_find(records, '6'), isNull);
    });
  });

  group('size sanity for the any-cut fallback', () {
    const mb = 1024 * 1024;

    test('savedEpisodeSizeLooksReal', () {
      // The E9 stub on disk.
      expect(
        savedEpisodeSizeLooksReal(bytesOnDisk: 788 * 1024, bytesTotal: 788 * 1024),
        isFalse,
      );
      expect(savedEpisodeSizeLooksReal(bytesOnDisk: 0, bytesTotal: 0), isFalse);
      // A real episode, size unknown or matching.
      expect(savedEpisodeSizeLooksReal(bytesOnDisk: 300 * mb, bytesTotal: 0), isTrue);
      expect(
        savedEpisodeSizeLooksReal(bytesOnDisk: 300 * mb, bytesTotal: 310 * mb),
        isTrue,
      );
      // Big enough, but under half of what the record says: cut short.
      expect(
        savedEpisodeSizeLooksReal(bytesOnDisk: 100 * mb, bytesTotal: 300 * mb),
        isFalse,
      );
    });

    test('savedRecordSizeLooksReal: unknown passes, a small size does not', () {
      expect(savedRecordSizeLooksReal(_rec('1')), isTrue);
      expect(savedRecordSizeLooksReal(_rec('1', bytesTotal: 788 * 1024)), isFalse);
      expect(savedRecordSizeLooksReal(_rec('1', bytesTotal: 200 * mb)), isTrue);
    });

    test('firstRealSavedCopy skips missing files and stubs on disk', () async {
      final missing = _rec('1', createdAt: 3);
      final stub = _rec('file:307c', category: 'unknown', number: 1, createdAt: 2);
      final real = _rec('1', category: 'sub', createdAt: 1);
      final sizes = {stub: 788 * 1024, real: 300 * mb};
      final found = await firstRealSavedCopy(
        [missing, stub, real],
        filePresent: (r) async => !identical(r, missing),
        sizeOnDisk: (r) async => sizes[r],
      );
      expect(identical(found, real), isTrue);
    });

    test('firstRealSavedCopy accepts a file whose size cannot be read', () async {
      final r = _rec('1');
      final found = await firstRealSavedCopy(
        [r],
        filePresent: (_) async => true,
        sizeOnDisk: (_) async => null,
      );
      expect(identical(found, r), isTrue);
    });

    test('firstRealSavedCopy returns null when only a stub is left', () async {
      final stub = _rec('file:307c', category: 'unknown', number: 9);
      final found = await firstRealSavedCopy(
        [stub],
        filePresent: (_) async => true,
        sizeOnDisk: (_) async => 788 * 1024,
      );
      expect(found, isNull);
    });
  });

  group('savedCutName', () {
    final l10n = lookupAppLocalizations(const Locale('en'));

    test('names Sub and Dub, leaves unknown cuts unnamed', () {
      expect(savedCutName('dub', l10n), 'Dub');
      expect(savedCutName('SUB', l10n), 'Sub');
      expect(savedCutName('unknown', l10n), isNull);
    });

    test('the tick label and the play notice read as decided', () {
      expect(l10n.desktopDownloadedCut('Dub'), 'Downloaded · Dub');
      expect(
        l10n.desktopPlayingDownloadedCut('Dub'),
        'Playing your downloaded Dub copy',
      );
    });
  });
}
