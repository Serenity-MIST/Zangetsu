import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/download_record.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/features/detail/desktop_existing_downloads.dart';

/// Disposable index snapshots; no user files or running queue are accessed.
DownloadRecord recovered(int n, {String? id, int? season = 1}) =>
    DownloadRecord.fromMap({'id': id ?? 'disk$n', 'sourceId': 'local-files',
      'recoveredFromDisk': true, 'showTitle': 'The_Four_of_Us',
      'episodeNumber': n, 'season': season, 'status': 'done', 'category': 'unknown'});
Episode episode(int n, {int? season = 1}) => Episode(id: 'e$n',
    title: 'Episode $n', url: '/$n', number: n.toDouble(), season: season);

void main() {
  test('requested49 minus ten approved existing files leaves39 in original order', () async {
    final episodes = [for (var n = 8; n <= 56; n++) episode(n)];
    final records = [for (final n in [8,9,10,11,13,18,21,24,29,37]) recovered(n)];
    final matches = recoveredDownloadSuggestions(title: 'The Four of Us',
        episodes: episodes, records: records);
    expect(matches, hasLength(10));
    final pending = await omitReusableDownloads(episodes, matches, (_) async => true);
    expect(pending, hasLength(39));
    expect(pending.first.number, 12); expect(pending.last.number, 56);
    expect(records.every((r) => r.category == 'unknown'), isTrue);
  });
  test('ambiguity, missing season and different titles never suggest reuse', () {
    final matches = recoveredDownloadSuggestions(title: 'The Four of Us',
      episodes: [episode(12),episode(13, season:null),episode(14, season:2)],
      records: [recovered(12), recovered(12,id:'duplicate'),recovered(13),recovered(14)]);
    expect(matches,isEmpty);
    expect(recoveredDownloadSuggestions(title:'Another show', episodes:[episode(12)],
      records:[recovered(12)]),isEmpty);
  });
  test('file removed while confirmation open stays queued for download', () async {
    final episodes=[episode(12),episode(13)];
    final matches=recoveredDownloadSuggestions(title:'The Four of Us',episodes:episodes,
      records:[recovered(12),recovered(13)]);
    final pending=await omitReusableDownloads(episodes,matches,
      (r) async => r.episodeNumber == 13);
    expect(pending.single.number,12);
  });

  group('broken saved copies (delete-broken)', () {
    // A finished record of episode 9 of show s1; nothing here touches disk.
    DownloadRecord saved(String id, {int bytesTotal = 0, String? episodeId,
        String category = 'sub'}) => DownloadRecord.fromMap({'id': id,
      'sourceId': 'src', 'showId': 's1', 'episodeId': episodeId ?? 'file:$id',
      'episodeNumber': 9, 'season': 1, 'status': 'done', 'category': category,
      'filePath': 'C:/fake/$id.mp4', 'bytesTotal': bytesTotal});
    Future<bool> present(DownloadRecord _) async => true;

    test('the normal lookup skips a stub, the broken lookup keeps it', () {
      final stub = saved('stub', bytesTotal: 788 * 1024);
      List<DownloadRecord> find({bool keepStubs = false}) =>
          savedEpisodeAnyCutCandidates([stub], sourceId: 'src', showId: 's1',
              episodeId: 'e9', episodeNumber: 9, season: 1,
              keepStubs: keepStubs);
      expect(find(), isEmpty);
      expect(find(keepStubs: true).single.id, 'stub');
    });

    test('a tiny file on disk is broken, a whole one is not', () async {
      final rec = saved('disk');
      expect(await savedCopyIsBroken(rec, filePresent: present,
          sizeOnDisk: (_) async => 788 * 1024), isTrue);
      expect(await savedCopyIsBroken(rec, filePresent: present,
          sizeOnDisk: (_) async => 300 * 1024 * 1024), isFalse);
      // An unreadable size (content URI) is not called broken on its own.
      expect(await savedCopyIsBroken(rec, filePresent: present,
          sizeOnDisk: (_) async => null), isFalse);
    });

    test('a finished record whose file is gone is broken', () async {
      expect(await savedCopyIsBroken(saved('gone'),
          filePresent: (_) async => false,
          sizeOnDisk: (_) async => null), isTrue);
    });

    test('a record that wrote down a stub size is broken', () async {
      expect(await savedCopyIsBroken(saved('small', bytesTotal: 1000),
          filePresent: present, sizeOnDisk: (_) async => null), isTrue);
    });

    test('firstBrokenSavedCopy skips real copies and finds the stub', () async {
      final real = saved('real', episodeId: 'e9');
      final stub = saved('stub', category: 'dub');
      final sizes = {'real': 400 * 1024 * 1024, 'stub': 788 * 1024};
      final found = await firstBrokenSavedCopy([real, stub],
          filePresent: present, sizeOnDisk: (r) async => sizes[r.id]);
      expect(found?.id, 'stub');
      expect(await firstBrokenSavedCopy([real], filePresent: present,
          sizeOnDisk: (r) async => sizes[r.id]), isNull);
    });
    // The episode tick agrees with the menu and Play: a stub is not shown
    // as downloaded, whether its record or its file on disk says so.
    group('tickCopyIsStub', () {
      setUp(SavedStubCheck.debugReset);

      test('a recorded stub size is a stub at once, with no disk look', () {
        var looked = 0;
        expect(tickCopyIsStub(saved('small', bytesTotal: 788 * 1024),
            (_) async { looked++; return null; }), isTrue);
        expect(looked, 0);
      });

      test('a small file on disk is a stub once it was looked at', () async {
        final rec = saved('disk');
        var looked = 0;
        var redraws = 0;
        void redraw() => redraws++;
        SavedStubCheck.changes.addListener(redraw);
        addTearDown(() => SavedStubCheck.changes.removeListener(redraw));
        Future<int?> size(DownloadRecord _) async {
          looked++;
          return 788 * 1024;
        }
        // Not known yet: shows as before while the look runs.
        expect(tickCopyIsStub(rec, size), isFalse);
        expect(tickCopyIsStub(rec, size), isFalse);
        await Future<void>.delayed(Duration.zero);
        expect(redraws, 1);
        expect(tickCopyIsStub(rec, size), isTrue);
        // The disk is read once, not on every redraw.
        expect(looked, 1);
      });

      test('a whole file, an unreadable size or no record is no stub',
          () async {
        final whole = saved('whole');
        final unknown = saved('unknown');
        expect(tickCopyIsStub(whole, (_) async => 400 * 1024 * 1024), isFalse);
        expect(tickCopyIsStub(unknown, (_) async => null), isFalse);
        await Future<void>.delayed(Duration.zero);
        expect(tickCopyIsStub(whole, (_) async => 400 * 1024 * 1024), isFalse);
        expect(tickCopyIsStub(unknown, (_) async => null), isFalse);
        expect(tickCopyIsStub(null, (_) async => 1), isFalse);
      });

      test('an unfinished record is never a stub', () {
        final rec = DownloadRecord.fromMap({'id': 'q', 'sourceId': 'src',
          'showId': 's1', 'episodeId': 'e1', 'status': 'queued',
          'category': 'sub', 'bytesTotal': 10});
        expect(tickCopyIsStub(rec, (_) async => 1), isFalse);
      });
    });

  });
}
