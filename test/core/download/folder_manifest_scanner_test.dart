import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:watch_app/core/download/download_record.dart';
import 'package:watch_app/core/download/folder_manifest.dart';
import 'package:watch_app/core/download/folder_manifest_scanner.dart';

const _tag1 = '11111111111111111111111111111111';
const _tag2 = '22222222222222222222222222222222';

void main() {
  late Directory root;
  late FolderManifestStore store;
  late FolderManifestScanner scanner;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('scanner_test');
    store = FolderManifestStore(hideOnWindows: false);
    scanner = FolderManifestScanner(store: store);
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  /// Creates a show folder at [path] with real video files and a manifest.
  Future<Directory> makeShow(
    String path, {
    List<ManifestEpisode>? episodes,
    String title = 'Frieren',
    String? sourceId = 'src',
    String? showId = 'show-1',
    List<String> files = const ['ep1.mp4', 'ep2.mp4'],
  }) async {
    final dir = await Directory(path).create(recursive: true);
    for (final f in files) {
      await File(p.join(dir.path, f)).writeAsBytes([1, 2, 3, 4]);
    }
    await store.write(
      dir,
      FolderManifest(
        folderId: FolderManifest.newFolderId(),
        title: title,
        sourceId: sourceId,
        showId: showId,
        ids: const ManifestIds(mal: 52991, tmdb: 209867, imdb: 'tt22248376'),
        poster: 'art/poster.png',
        episodes:
            episodes ??
            const [
              ManifestEpisode(
                key: _tag1,
                file: 'ep1.mp4',
                title: 'The Journey',
                number: 1,
                season: 1,
                category: 'dub',
                quality: '1080p',
                savedAt: 5,
                thumbnail: 'art/ep-1.png',
                subtitles: [
                  ManifestSubtitle(
                    file: 'subs/en.vtt',
                    lang: 'en',
                    isDefault: true,
                  ),
                ],
              ),
              ManifestEpisode(
                key: _tag2,
                file: 'ep2.mp4',
                title: 'E2',
                number: 2,
              ),
            ],
      ),
    );
    return dir;
  }

  group('scan', () {
    test('finds show folders at any depth up to the limit', () async {
      await makeShow(p.join(root.path, 'Videos', 'Frieren'));
      await makeShow(
        p.join(root.path, 'Elsewhere', 'Deeper', 'Other'),
        title: 'Other',
      );
      final found = await scanner.scan(root);
      expect(
        found.map((s) => s.manifest.title),
        unorderedEquals(['Frieren', 'Other']),
      );
    });

    test('respects maxDepth', () async {
      await makeShow(p.join(root.path, 'a', 'b', 'c', 'Deep'));
      expect(await scanner.scan(root, maxDepth: 2), isEmpty);
      expect(await scanner.scan(root, maxDepth: 4), hasLength(1));
    });

    test('scans a folder that is itself a show', () async {
      final show = await makeShow(p.join(root.path, 'Solo'));
      expect((await scanner.scan(show)).single.folder.path, show.path);
    });

    test('does not search inside a folder that has a manifest', () async {
      final show = await makeShow(p.join(root.path, 'Show'));
      await makeShow(p.join(show.path, 'Nested'), title: 'Nested');
      expect(await scanner.scan(root), hasLength(1));
    });

    test('skips hidden and system folders and non-manifest folders', () async {
      await makeShow(p.join(root.path, r'$RECYCLE.BIN', 'Hidden'));
      await makeShow(p.join(root.path, '.git', 'Hidden2'));
      await Directory(p.join(root.path, 'Plain')).create();
      await File(p.join(root.path, 'Plain', 'movie.mp4')).writeAsBytes([1]);
      expect(await scanner.scan(root), isEmpty);
    });

    test('ignores a folder whose manifest is invalid or foreign', () async {
      final dir = await Directory(p.join(root.path, 'Bad')).create();
      await FolderManifestStore.metaDir(dir).create();
      await FolderManifestStore.manifestFile(dir).writeAsString(
        jsonEncode({'created_by': 'SomethingElse', 'schema_version': 1}),
      );
      expect(await scanner.scan(root), isEmpty);
    });

    test('can be cancelled and tolerates a missing root', () async {
      await makeShow(p.join(root.path, 'Show'));
      expect(await scanner.scan(root, canceled: () => true), isEmpty);
      expect(await scanner.scan(Directory(p.join(root.path, 'nope'))), isEmpty);
    });

    test('stops at the folder limit', () async {
      for (var i = 0; i < 5; i++) {
        await Directory(p.join(root.path, 'd$i')).create();
      }
      await makeShow(p.join(root.path, 'z', 'Show'));
      expect(await scanner.scan(root, maxFolders: 3), isEmpty);
    });

    test('finds a show after its folder was moved and renamed', () async {
      final show = await makeShow(p.join(root.path, 'Videos', 'Frieren'));
      final id = (await store.read(show))!.folderId;
      await Directory(p.join(root.path, 'HDD')).create();
      await show.rename(p.join(root.path, 'HDD', 'Sousou no Frieren'));
      final found = await scanner.scan(root);
      expect(found.single.manifest.folderId, id);
      expect(p.basename(found.single.folder.path), 'Sousou no Frieren');
    });
  });

  group('recordsFor', () {
    test(
      'builds full records from the manifest, using paths where it now lives',
      () async {
        final show = await makeShow(p.join(root.path, 'New place'));
        final meta = FolderManifestStore.metaDir(show).path;
        await Directory(p.join(meta, 'art')).create(recursive: true);
        await File(p.join(meta, 'art', 'poster.png')).writeAsBytes([1]);
        await File(p.join(meta, 'art', 'ep-1.png')).writeAsBytes([1]);
        await Directory(p.join(show.path, 'subs')).create();
        await File(p.join(show.path, 'subs', 'en.vtt')).writeAsString('x');

        final scanned = (await scanner.scan(root)).single;
        final records = await FolderManifestScanner.recordsFor(
          scanned,
          downloadRoot: root.path,
        );
        final r = records.firstWhere((r) => r.episodeNumber == 1);
        expect(r.showTitle, 'Frieren');
        expect(r.sourceId, 'src');
        expect(r.showId, 'show-1');
        expect(r.category, 'dub');
        expect(r.quality, '1080p');
        expect(r.status, DownloadStatus.done);
        expect(r.filePath, p.join(show.path, 'ep1.mp4'));
        expect(r.malId, 52991);
        expect(r.tmdbId, 209867);
        expect(r.imdbId, 'tt22248376');
        expect(Uri.parse(r.cover!).scheme, 'file');
        expect(Uri.parse(r.episodeThumbnail!).scheme, 'file');
        expect(r.subtitles.single.lang, 'en');
        expect(r.subtitles.single.path, p.join(show.path, 'subs', 'en.vtt'));
        expect(r.subtitles.single.isDefault, isTrue);
        // A known provider means it is not "recovered without identity".
        expect(r.recoveredFromDisk, isFalse);
      },
    );

    test(
      'a manifest without a provider is marked as recovered local media',
      () async {
        await makeShow(
          p.join(root.path, 'Local'),
          sourceId: null,
          showId: null,
        );
        final records = await FolderManifestScanner.recordsFor(
          (await scanner.scan(root)).single,
          downloadRoot: root.path,
        );
        expect(records.first.sourceId, 'local-files');
        expect(records.first.showId, startsWith('local:'));
        expect(records.first.recoveredFromDisk, isTrue);
      },
    );

    test('skips episodes whose file is missing or empty', () async {
      final show = await makeShow(p.join(root.path, 'Show'));
      await File(p.join(show.path, 'ep2.mp4')).delete();
      await File(p.join(show.path, 'ep1.mp4')).writeAsBytes([]);
      final records = await FolderManifestScanner.recordsFor(
        (await scanner.scan(root)).single,
        downloadRoot: root.path,
      );
      expect(records, isEmpty);
    });

    test(
      'a hostile manifest cannot point at files outside its folder',
      () async {
        final secret = File(p.join(root.path, 'secret.mp4'))
          ..writeAsBytesSync([1, 2]);
        final show = await makeShow(
          p.join(root.path, 'Evil'),
          files: const [],
          episodes: [
            const ManifestEpisode(
              key: _tag1,
              file: '../secret.mp4',
              title: 'x',
            ),
            ManifestEpisode(key: _tag2, file: secret.path, title: 'y'),
            const ManifestEpisode(
              key: 'k3',
              file: r'C:\Windows\notepad.exe',
              title: 'z',
            ),
          ],
        );
        final records = await FolderManifestScanner.recordsFor(
          ScannedShow(show, (await store.read(show))!),
          downloadRoot: root.path,
        );
        expect(records, isEmpty);
      },
    );

    test(
      'hostile artwork and subtitle paths are dropped, not followed',
      () async {
        final outside = File(p.join(root.path, 'outside.png'))
          ..writeAsBytesSync([1]);
        final show = await makeShow(
          p.join(root.path, 'Evil2'),
          files: const ['ep1.mp4'],
          episodes: [
            ManifestEpisode(
              key: _tag1,
              file: 'ep1.mp4',
              title: 'E1',
              thumbnail: '../../outside.png',
              subtitles: [ManifestSubtitle(file: outside.path, lang: 'en')],
            ),
          ],
        );
        final r = (await FolderManifestScanner.recordsFor(
          ScannedShow(show, (await store.read(show))!),
          downloadRoot: root.path,
        )).single;
        expect(r.episodeThumbnail, isNull);
        expect(r.subtitles, isEmpty);
      },
    );

    test('record ids are stable so a rescan never duplicates', () async {
      await makeShow(p.join(root.path, 'Show'));
      final scanned = (await scanner.scan(root)).single;
      final a = await FolderManifestScanner.recordsFor(
        scanned,
        downloadRoot: root.path,
      );
      final b = await FolderManifestScanner.recordsFor(
        scanned,
        downloadRoot: root.path,
      );
      expect(a.map((r) => r.id), b.map((r) => r.id));
      expect(a.map((r) => r.id).toSet(), hasLength(a.length));
      // For files named by the app, the key is the tag inside the file name.
      final tagged = a.first.copyWith(
        filePath: () => p.join(root.path, 'Frieren_S1E1_1080p_$_tag1.mp4'),
      );
      expect(FolderManifestScanner.keyOf(tagged), _tag1);
    });
  });

  test('FolderScanResult reports whether the library changed', () {
    expect(const FolderScanResult(skipped: 3).changedLibrary, isFalse);
    expect(const FolderScanResult(added: 1).changedLibrary, isTrue);
    expect(const FolderScanResult(relinked: 1).changedLibrary, isTrue);
  });
}
