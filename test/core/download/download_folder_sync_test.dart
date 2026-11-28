import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:watch_app/core/download/download_folder_sync.dart';
import 'package:watch_app/core/download/download_record.dart';
import 'package:watch_app/core/download/folder_manifest.dart';

/// A small real JPEG, so the PNG conversion path is exercised for real.
Uint8List _jpeg({int width = 8, int height = 6}) => Uint8List.fromList(
  img.encodeJpg(img.Image(width: width, height: height), quality: 80),
);

bool _isPng(List<int> bytes) =>
    bytes.length > 8 &&
    bytes[0] == 0x89 &&
    bytes[1] == 0x50 &&
    bytes[2] == 0x4e &&
    bytes[3] == 0x47;

void main() {
  late Directory root;
  late Directory show;
  late FolderManifestStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('folder_sync_test');
    show = await Directory(
      p.join(root.path, 'Videos', 'Frieren'),
    ).create(recursive: true);
    store = FolderManifestStore(hideOnWindows: false);
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  /// A finished record whose video file really exists in [show].
  Future<DownloadRecord> record(
    int n, {
    List<OfflineSubtitle> subtitles = const [],
    String? thumbnail = 'https://img.test/ep.jpg',
    DownloadStatus status = DownloadStatus.done,
    bool createFile = true,
  }) async {
    final tag = n.toString().padLeft(32, '0');
    final file = File(p.join(show.path, 'Frieren_S1E${n}_1080p_$tag.mp4'));
    if (createFile) await file.writeAsBytes([1, 2, 3]);
    return DownloadRecord(
      id: 'rec-$n',
      sourceId: 'src',
      showId: 'show-1',
      showTitle: 'Frieren',
      cover: 'https://img.test/poster.jpg',
      coverHeaders: const {'Referer': 'https://img.test/'},
      showUrl: 'https://example.test/show',
      episodeId: 'ep-$n',
      episodeUrl: 'https://example.test/ep-$n',
      episodeNumber: n.toDouble(),
      season: 1,
      episodeThumbnail: thumbnail,
      episodeTitle: 'Episode $n',
      category: 'sub',
      quality: '1080p',
      status: status,
      filePath: file.path,
      bytesTotal: 3,
      subtitles: subtitles,
      malId: 52991,
      anilistId: 154587,
      tmdbId: 209867,
      tmdbIsTv: true,
      imdbId: 'tt22248376',
      createdAt: 1000 + n,
    );
  }

  /// Records what the fake network was asked for.
  late List<(Uri, Map<String, String>?)> requests;
  DownloadFolderSync build({
    Uint8List? Function(Uri)? serve,
    FrameExtractor? frames,
    int maxSide = 1280,
  }) {
    requests = [];
    return DownloadFolderSync(
      store: store,
      maxArtworkSide: maxSide,
      extractFrame: frames,
      fetchArtwork: (url, headers) async {
        requests.add((url, headers));
        return serve != null ? serve(url) : _jpeg();
      },
    );
  }

  test('writes a manifest with ids, episode and relative file names', () async {
    final sync = build();
    final r = await record(1);
    await sync.onDone(r);

    final m = (await store.read(show))!;
    expect(m.title, 'Frieren');
    expect(m.sourceId, 'src');
    expect(m.showId, 'show-1');
    expect(m.ids.mal, 52991);
    expect(m.ids.anilist, 154587);
    expect(m.ids.tmdb, 209867);
    expect(m.ids.imdb, 'tt22248376');
    final e = m.episodes.single;
    expect(e.file, p.basename(r.filePath!));
    expect(e.number, 1);
    expect(e.season, 1);
    expect(e.category, 'sub');
    // Paths are relative so the folder can be moved.
    expect(p.isAbsolute(e.file), isFalse);
  });

  test('saves poster and thumbnail as real PNG files in the folder', () async {
    final sync = build();
    await sync.onDone(await record(1));

    final m = (await store.read(show))!;
    final meta = FolderManifestStore.metaDir(show).path;
    expect(m.poster, DownloadFolderSync.posterPath);
    final poster = File(p.join(meta, 'art', 'poster.png'));
    expect(await poster.exists(), isTrue);
    expect(_isPng(await poster.readAsBytes()), isTrue);
    final thumb = File(p.join(meta, m.episodes.single.thumbnail!));
    expect(_isPng(await thumb.readAsBytes()), isTrue);
    // No half-written temp files are left behind.
    expect(
      Directory(
        meta,
      ).listSync(recursive: true).any((f) => f.path.endsWith('.tmp')),
      isFalse,
    );
  });

  test(
    'a second episode joins the same manifest and reuses the poster',
    () async {
      final sync = build();
      await sync.onDone(await record(1));
      final id = (await store.read(show))!.folderId;
      final posterFetches = requests
          .where((r) => r.$1.path.contains('poster'))
          .length;

      await sync.onDone(await record(2));
      final m = (await store.read(show))!;
      expect(m.folderId, id);
      expect(m.episodes.map((e) => e.number), containsAll([1, 2]));
      // The poster already exists, so it is not downloaded again.
      expect(
        requests.where((r) => r.$1.path.contains('poster')).length,
        posterFetches,
      );
    },
  );

  test('cover headers are only sent to the cover host', () async {
    final sync = build();
    await sync.onDone(
      await record(1, thumbnail: 'https://other-host.test/ep.jpg'),
    );
    final poster = requests.firstWhere((r) => r.$1.path.contains('poster'));
    expect(poster.$2, {'Referer': 'https://img.test/'});
    final thumb = requests.firstWhere((r) => r.$1.host == 'other-host.test');
    expect(thumb.$2, isNull);
  });

  test('a failed artwork download still leaves a valid manifest', () async {
    final sync = build(serve: (_) => null);
    await sync.onDone(await record(1));
    final m = (await store.read(show))!;
    expect(m.episodes, hasLength(1));
    expect(m.poster, isNull);
    expect(m.episodes.single.thumbnail, isNull);
  });

  test('non-image bytes are ignored instead of saved', () async {
    final sync = build(serve: (_) => Uint8List.fromList([1, 2, 3, 4]));
    await sync.onDone(await record(1));
    expect((await store.read(show))!.poster, isNull);
  });

  test('large artwork is scaled down', () async {
    final sync = build(
      serve: (_) => _jpeg(width: 400, height: 200),
      maxSide: 100,
    );
    await sync.onDone(await record(1));
    final png = File(
      p.join(FolderManifestStore.metaDir(show).path, 'art', 'poster.png'),
    );
    final decoded = img.decodePng(await png.readAsBytes())!;
    expect(decoded.width, 100);
    expect(decoded.height, 50);
  });

  test('takes a frame from the video when there is no thumbnail URL', () async {
    final frame = File(p.join(root.path, 'frame.jpg'))
      ..writeAsBytesSync(_jpeg());
    final asked = <String>[];
    final sync = build(
      frames: (path) async {
        asked.add(path);
        return frame.uri.toString();
      },
    );
    final r = await record(1, thumbnail: null);
    await sync.onDone(r);
    expect(asked, [r.filePath]);
    expect((await store.read(show))!.episodes.single.thumbnail, isNotNull);
  });

  test(
    'subtitles inside the folder are listed relatively, others skipped',
    () async {
      final subs = Directory(p.join(show.path, 'Subtitles'))..createSync();
      final inside = File(p.join(subs.path, 'e1.en.vtt'))
        ..writeAsStringSync('x');
      final outside = File(p.join(root.path, 'elsewhere.vtt'))
        ..writeAsStringSync('x');
      final sync = build();
      await sync.onDone(
        await record(
          1,
          subtitles: [
            OfflineSubtitle(
              path: inside.path,
              lang: 'en',
              label: 'English',
              isDefault: true,
            ),
            OfflineSubtitle(path: outside.path, lang: 'fr', label: 'French'),
          ],
        ),
      );
      final subsListed = (await store.read(show))!.episodes.single.subtitles;
      expect(subsListed, hasLength(1));
      expect(subsListed.single.file, 'Subtitles/e1.en.vtt');
      expect(subsListed.single.lang, 'en');
      expect(subsListed.single.isDefault, isTrue);
    },
  );

  test('ignores records that are not finished or have no file', () async {
    final sync = build();
    await sync.onDone(await record(1, status: DownloadStatus.downloading));
    await sync.onDone(await record(2, createFile: false));
    expect(await store.read(show), isNull);
    expect(await FolderManifestStore.metaDir(show).exists(), isFalse);
  });

  test(
    'upgradeExisting adds missing manifests and skips complete ones',
    () async {
      final sync = build();
      final a = await record(1);
      final b = await record(2);
      expect(await sync.upgradeExisting([a, b]), 2);
      // Everything is already described, so a second pass changes nothing.
      final before = await FolderManifestStore.manifestFile(
        show,
      ).readAsString();
      expect(await sync.upgradeExisting([a, b]), 0);
      expect(
        await FolderManifestStore.manifestFile(show).readAsString(),
        before,
      );
    },
  );

  test(
    'an episode already listed is not retried, even if its artwork failed',
    () async {
      final a = await record(1);
      await build(serve: (_) => null).onDone(a);
      // The network would work now, but a launch-time pass must not use it.
      final sync = build();
      expect(await sync.upgradeExisting([a]), 0);
      expect(requests, isEmpty);
    },
  );

  test(
    'deleting one episode keeps the manifest, deleting the last removes it',
    () async {
      final sync = build();
      final a = await record(1);
      final b = await record(2);
      await sync.onDone(a);
      await sync.onDone(b);
      final meta = FolderManifestStore.metaDir(show);

      await File(a.filePath!).delete();
      await sync.onFileDeleted(File(a.filePath!));
      final m = (await store.read(show))!;
      expect(m.episodes.map((e) => e.number), [2]);
      expect(await meta.exists(), isTrue);

      await File(b.filePath!).delete();
      await sync.onFileDeleted(File(b.filePath!));
      // No episode is left, so the metadata goes and the folder can be removed.
      expect(await meta.exists(), isFalse);
      expect(show.listSync(), isEmpty);
    },
  );

  test('never touches or deletes the media files themselves', () async {
    final sync = build();
    final r = await record(1);
    await sync.onDone(r);
    await sync.upgradeExisting([r]);
    expect(await File(r.filePath!).readAsBytes(), [1, 2, 3]);
    // Only .zangetsu was added next to the video.
    final names = show.listSync().map((e) => p.basename(e.path)).toSet();
    expect(names, {p.basename(r.filePath!), '.zangetsu'});
  });

  test('subtitle files next to the video are recorded even when the record '
      'lists none', () async {
    final r = await record(1);
    final stem = p.basenameWithoutExtension(r.filePath!);
    final subs = Directory(p.join(show.path, 'Subtitles'))..createSync();
    File(
      p.join(subs.path, '${stem}_English__Original_Audio__1.srt'),
    ).writeAsStringSync('1\n00:00:01,000 --> 00:00:02,000\nHi');
    await build().onDone(r);
    final listed = (await store.read(show))!.episodes.single.subtitles;
    expect(listed, hasLength(1));
    expect(
      listed.single.file,
      'Subtitles/${stem}_English__Original_Audio__1.srt',
    );
    expect(listed.single.lang, 'English Original Audio');
  });

  test(
    'an entry written without subtitles is repaired once, then left alone',
    () async {
      final r = await record(1);
      await build().onDone(r); // written before any subtitle file existed
      expect((await store.read(show))!.episodes.single.subtitles, isEmpty);

      final stem = p.basenameWithoutExtension(r.filePath!);
      final subs = Directory(p.join(show.path, 'Subtitles'))..createSync();
      File(p.join(subs.path, '${stem}_English_1.vtt')).writeAsStringSync('x');

      final sync = build();
      expect(await sync.upgradeExisting([r]), 1);
      expect((await store.read(show))!.episodes.single.subtitles, hasLength(1));
      // The repair rewrites the manifest only: no artwork download.
      expect(requests, isEmpty);
      // Fixed now, so later launches skip it.
      expect(await sync.upgradeExisting([r]), 0);
    },
  );

  test(
    'subtitles saved outside the show folder never trigger a repair loop',
    () async {
      final elsewhere = Directory(
        p.join(root.path, 'old-location', 'Subtitles'),
      )..createSync(recursive: true);
      final outside = File(p.join(elsewhere.path, 'old.srt'))
        ..writeAsStringSync('x');
      final r = (await record(1)).copyWith(
        subtitles: [OfflineSubtitle(lang: 'en', path: outside.path)],
      );
      await build().onDone(r);
      final sync = build();
      // Nothing in this folder to add, so it is left alone, every launch.
      expect(await sync.upgradeExisting([r]), 0);
      expect(await sync.upgradeExisting([r]), 0);
      expect(requests, isEmpty);
    },
  );

  test(
    'a later write that finds no subtitles never wipes listed ones',
    () async {
      final r = await record(1);
      final stem = p.basenameWithoutExtension(r.filePath!);
      final subs = Directory(p.join(show.path, 'Subtitles'))..createSync();
      final f = File(p.join(subs.path, '${stem}_English_1.vtt'))
        ..writeAsStringSync('x');
      await build().onDone(r);
      await f.delete(); // e.g. a stale snapshot with nothing found
      await build().onDone(r);
      expect((await store.read(show))!.episodes.single.subtitles, hasLength(1));
    },
  );

  test('episodeKey uses the download tag from the file name', () async {
    final r = await record(7);
    expect(DownloadFolderSync.episodeKey(r), '7'.padLeft(32, '0'));
  });
}
