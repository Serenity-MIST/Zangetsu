import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:watch_app/core/download/folder_manifest.dart';

const _keyA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _keyB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

FolderManifest _manifest({String? id, List<ManifestEpisode>? episodes}) =>
    FolderManifest(
      folderId: id ?? FolderManifest.newFolderId(),
      title: 'Frieren',
      altTitles: const ['Sousou no Frieren'],
      ids: const ManifestIds(anilist: 154587, mal: 52991, tmdb: 209867),
      sourceId: 'src',
      showId: 'show-1',
      poster: 'art/poster.png',
      updatedAt: 1,
      episodes:
          episodes ??
          const [
            ManifestEpisode(
              key: _keyA,
              file: 'Frieren_S1E1_1080p_aaaa.mp4',
              title: 'Episode 1',
              number: 1,
              season: 1,
              thumbnail: 'art/e-a.png',
              quality: '1080p',
              category: 'sub',
              bytes: 100,
              subtitles: [
                ManifestSubtitle(
                  file: 'Frieren_S1E1.en.vtt',
                  lang: 'en',
                  isDefault: true,
                ),
              ],
            ),
          ],
    );

void main() {
  late Directory root;
  late FolderManifestStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('manifest_test');
    store = FolderManifestStore(hideOnWindows: false);
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  group('FolderManifest', () {
    test('round-trips through JSON without losing fields', () {
      final original = _manifest();
      final parsed = FolderManifest.tryParse(jsonEncode(original.toJson()))!;
      expect(parsed.folderId, original.folderId);
      expect(parsed.title, 'Frieren');
      expect(parsed.altTitles, ['Sousou no Frieren']);
      expect(parsed.ids.anilist, 154587);
      expect(parsed.ids.tmdb, 209867);
      expect(parsed.poster, 'art/poster.png');
      final e = parsed.episodes.single;
      expect(e.number, 1);
      expect(e.season, 1);
      expect(e.category, 'sub');
      expect(e.thumbnail, 'art/e-a.png');
      expect(e.subtitles.single.lang, 'en');
      expect(e.subtitles.single.isDefault, isTrue);
    });

    test('rejects anything that is not a Zangetsu manifest', () {
      final good = _manifest().toJson();
      expect(FolderManifest.tryParse('not json'), isNull);
      expect(FolderManifest.tryParse('[]'), isNull);
      expect(
        FolderManifest.tryParse(jsonEncode({...good, 'created_by': 'Other'})),
        isNull,
      );
      expect(
        FolderManifest.tryParse(jsonEncode({...good, 'schema_version': 0})),
        isNull,
      );
      expect(
        FolderManifest.tryParse(jsonEncode({...good, 'schema_version': '1'})),
        isNull,
      );
      // A folder id must look like one: no path tricks smuggled through it.
      expect(
        FolderManifest.tryParse(jsonEncode({...good, 'folder_id': '../x'})),
        isNull,
      );
      expect(
        FolderManifest.tryParse(jsonEncode({...good, 'title': 5})),
        isNull,
      );
    });

    test('skips malformed episodes but keeps the good ones', () {
      final json = _manifest().toJson();
      json['episodes'] = [
        ...(json['episodes'] as List),
        {'key': 5, 'file': 'x.mp4'},
        'garbage',
        {'file': 'no-key.mp4'},
      ];
      final parsed = FolderManifest.tryParse(jsonEncode(json))!;
      expect(parsed.episodes, hasLength(1));
    });

    test('keeps unknown keys from a newer app when saving again', () {
      final json = _manifest().toJson()..['future_field'] = {'a': 1};
      final parsed = FolderManifest.tryParse(jsonEncode(json))!;
      expect(parsed.toJson()['future_field'], {'a': 1});
    });

    test('a newer schema is readable but flagged so it is never rewritten', () {
      final json = _manifest().toJson()..['schema_version'] = 99;
      final parsed = FolderManifest.tryParse(jsonEncode(json))!;
      expect(parsed.isNewerThanApp, isTrue);
    });

    test('withEpisode replaces by key instead of duplicating', () {
      final m = _manifest();
      final changed = m.withEpisode(m.episodes.single.copyWith(bytes: 999));
      expect(changed.episodes, hasLength(1));
      expect(changed.episodes.single.bytes, 999);
      final added = m.withEpisode(
        const ManifestEpisode(key: _keyB, file: 'b.mp4', title: 'E2'),
      );
      expect(added.episodes, hasLength(2));
    });

    test('ManifestIds merge keeps known values and fills gaps', () {
      const a = ManifestIds(mal: 1);
      const b = ManifestIds(mal: 2, tmdb: 3, imdb: 'tt1');
      final merged = a.merge(b);
      expect(merged.mal, 1);
      expect(merged.tmdb, 3);
      expect(merged.imdb, 'tt1');
    });
  });

  group('resolveInside', () {
    test('accepts plain relative paths inside the folder', () {
      final base = p.join(root.path, 'Show');
      expect(
        FolderManifestStore.resolveInside(base, 'ep1.mp4'),
        p.join(base, 'ep1.mp4'),
      );
      expect(
        FolderManifestStore.resolveInside(base, 'Season 1/ep1.mp4'),
        p.normalize(p.join(base, 'Season 1', 'ep1.mp4')),
      );
    });

    test('rejects traversal, absolute paths and drive letters', () {
      final base = p.join(root.path, 'Show');
      for (final bad in [
        '',
        '../secret.txt',
        'a/../../secret.txt',
        '..\\secret.txt',
        '/etc/passwd',
        r'\Windows\system32',
        r'C:\Windows\system32\cmd.exe',
        'C:evil.txt',
        'a\u0000b',
      ]) {
        expect(
          FolderManifestStore.resolveInside(base, bad),
          isNull,
          reason: bad,
        );
      }
    });
  });

  group('FolderManifestStore', () {
    test('reads nothing from a folder without a manifest', () async {
      expect(await store.read(root), isNull);
    });

    test('writes atomically and reads back', () async {
      final manifest = _manifest();
      await store.write(root, manifest);
      final file = FolderManifestStore.manifestFile(root);
      expect(await file.exists(), isTrue);
      // No temp file is left behind.
      expect(await File('${file.path}.tmp').exists(), isFalse);
      final back = await store.read(root);
      expect(back?.folderId, manifest.folderId);
      expect(back?.episodes.single.file, 'Frieren_S1E1_1080p_aaaa.mp4');
    });

    test(
      'an older manifest.json is read, then renamed to metadata.json',
      () async {
        // A folder from an earlier build: only manifest.json.
        final manifest = _manifest();
        await FolderManifestStore.metaDir(root).create(recursive: true);
        final legacy = FolderManifestStore.legacyManifestFile(root);
        await legacy.writeAsString(jsonEncode(manifest.toJson()));
        expect(await FolderManifestStore.hasManifest(root), isTrue);
        expect((await store.read(root))?.folderId, manifest.folderId);

        // The next write lands in metadata.json and removes manifest.json.
        await store.update(root, (current) => current!.copyWith(title: 'New'));
        expect(await FolderManifestStore.manifestFile(root).exists(), isTrue);
        expect(await legacy.exists(), isFalse);
        expect((await store.read(root))?.title, 'New');
        expect((await store.read(root))?.folderId, manifest.folderId);
      },
    );

    test('a corrupt manifest reads as none instead of throwing', () async {
      await FolderManifestStore.metaDir(root).create(recursive: true);
      await FolderManifestStore.manifestFile(root).writeAsString('{oops');
      expect(await store.read(root), isNull);
    });

    test('concurrent updates never lose an episode', () async {
      await store.write(root, _manifest(episodes: const []));
      await Future.wait([
        for (var i = 0; i < 10; i++)
          store.update(
            root,
            (current) => current!.withEpisode(
              ManifestEpisode(
                key: i.toString().padLeft(32, '0'),
                file: 'ep$i.mp4',
                title: 'E$i',
              ),
            ),
          ),
      ]);
      expect((await store.read(root))!.episodes, hasLength(10));
    });

    test(
      'update can create the manifest and can decline to change it',
      () async {
        final made = await store.update(root, (current) {
          expect(current, isNull);
          return _manifest();
        });
        expect(made, isNotNull);
        final before = await FolderManifestStore.manifestFile(
          root,
        ).readAsString();
        await store.update(root, (_) => null);
        expect(
          await FolderManifestStore.manifestFile(root).readAsString(),
          before,
        );
      },
    );

    test('does not overwrite a manifest from a newer format', () async {
      final json = _manifest().toJson()..['schema_version'] = 99;
      await FolderManifestStore.metaDir(root).create(recursive: true);
      final file = FolderManifestStore.manifestFile(root);
      await file.writeAsString(jsonEncode(json));
      final before = await file.readAsString();
      await store.update(
        root,
        (current) => current!.copyWith(title: 'Changed by an older app'),
      );
      expect(await file.readAsString(), before);
    });

    test('moving the folder keeps the manifest and its id', () async {
      final folder = Directory(p.join(root.path, 'Original'))..createSync();
      final manifest = _manifest();
      await store.write(folder, manifest);
      final moved = await folder.rename(p.join(root.path, 'Renamed elsewhere'));
      expect((await store.read(moved))?.folderId, manifest.folderId);
    });
  });
}
