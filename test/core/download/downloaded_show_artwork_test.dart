// The downloaded show's metadata copy inside its folder: details.json plus the
// cover, banner and every episode thumbnail as local images, re-runs that
// fetch nothing new, local file: URIs on load, and a hostile show.json that
// cannot point outside its .zangetsu folder.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:watch_app/core/download/download_folder_sync.dart';
import 'package:watch_app/core/download/download_record.dart';
import 'package:watch_app/core/download/downloaded_show_artwork.dart';
import 'package:watch_app/core/download/folder_manifest.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/media_detail.dart';
import 'package:watch_app/core/models/provider_info.dart';

/// Show with three episodes; only the first one is downloaded.
const _detail = MediaDetail(
  id: 'show-1',
  title: 'The Strongest Sage',
  cover: 'https://img.example/cover.jpg',
  banner: 'https://img.example/banner.jpg',
  url: 'zm://anime/mal/1',
  description: 'A sage is reborn.',
  genres: ['Action'],
  type: ProviderType.anime,
  sourceId: 'zm',
  episodes: [
    Episode(
      id: 'e1',
      title: 'Ep 1',
      url: 'u1',
      number: 1,
      thumbnail: 'https://img.example/e1.jpg',
      description: 'He takes the exam.',
    ),
    Episode(
      id: 'e2',
      title: 'Ep 2',
      url: 'u2',
      number: 2,
      thumbnail: 'https://img.example/e2.jpg',
    ),
    // Thumbnail that is just the cover: not saved twice.
    Episode(
      id: 'e3',
      title: 'Ep 3',
      url: 'u3',
      number: 3,
      thumbnail: 'https://img.example/cover.jpg',
    ),
  ],
);

/// A tiny valid PNG, as the fake fetcher returns it.
Uint8List _png() =>
    Uint8List.fromList(img.encodePng(img.Image(width: 8, height: 6)));

void main() {
  late Directory root;
  late Directory folder;
  late DownloadRecord record;
  late List<Uri> fetched;
  late DownloadedShowArtwork artwork;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('dl_show_artwork_test');
    folder = Directory('${root.path}/The Strongest Sage')..createSync();
    File('${folder.path}/e1.mp4').writeAsBytesSync(const [0]);
    await FolderManifestStore(hideOnWindows: false).write(
      folder,
      FolderManifest(folderId: 'f1', title: 'The Strongest Sage'),
    );
    record = DownloadRecord(
      id: 'r1',
      sourceId: 'zm',
      showId: 'show-1',
      showTitle: 'The Strongest Sage',
      showUrl: 'zm://anime/mal/1',
      episodeId: 'e1',
      episodeUrl: 'u1',
      episodeTitle: 'Ep 1',
      category: 'sub',
      quality: 'best',
      status: DownloadStatus.done,
      filePath: '${folder.path}/e1.mp4',
      createdAt: 1,
    );
    fetched = [];
    artwork = DownloadedShowArtwork(
      sync: DownloadFolderSync(
        fetchArtwork: (url, _) async {
          fetched.add(url);
          return _png();
        },
      ),
    );
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  String meta(String relative) =>
      '${FolderManifestStore.metaDir(folder).path}/$relative';

  test(
    'writes details.json and every image, then re-runs fetch nothing',
    () async {
      await artwork.mirror(
        _detail,
        sourceId: 'zm',
        showId: 'show-1',
        records: [record],
      );
      expect(File(meta(DownloadedShowArtwork.coverPath)).existsSync(), isTrue);
      expect(File(meta(DownloadedShowArtwork.bannerPath)).existsSync(), isTrue);
      // Every episode of the show, not only the downloaded one.
      for (final e in _detail.episodes.take(2)) {
        expect(
          File(meta(DownloadedShowArtwork.episodeArtPath(e))).existsSync(),
          isTrue,
        );
      }
      // Cover, banner, e1, e2 (e3 reuses the cover).
      expect(fetched, hasLength(4));

      final json =
          jsonDecode(DownloadedShowArtwork.showFile(folder).readAsStringSync())
              as Map;
      expect(json['created_by'], 'Zangetsu');
      expect(json['source_id'], 'zm');
      expect(json['show_id'], 'show-1');
      expect((json['art'] as Map)['episodes'], hasLength(2));

      // Second run: images exist, nothing is fetched again.
      fetched.clear();
      await artwork.mirror(
        _detail,
        sourceId: 'zm',
        showId: 'show-1',
        records: [record],
      );
      expect(fetched, isEmpty);
    },
  );

  test(
    'an older show.json is still read, then renamed to details.json',
    () async {
      await artwork.mirror(
        _detail,
        sourceId: 'zm',
        showId: 'show-1',
        records: [record],
      );
      // Turn the folder into one an earlier build wrote: show.json only.
      final current = DownloadedShowArtwork.showFile(folder);
      final legacy = DownloadedShowArtwork.legacyShowFile(folder);
      current.renameSync(legacy.path);
      expect(current.existsSync(), isFalse);

      // Offline read still finds the details under the old name.
      final saved = await artwork.readSaved(
        [record],
        sourceId: 'zm',
        showId: 'show-1',
      );
      expect(saved?.title, _detail.title);

      // The next save writes details.json and removes show.json.
      await artwork.mirror(
        _detail,
        sourceId: 'zm',
        showId: 'show-1',
        records: [record],
      );
      expect(current.existsSync(), isTrue);
      expect(legacy.existsSync(), isFalse);
    },
  );

  test('round-trip: the saved detail reads back with local images', () async {
    await artwork.mirror(
      _detail,
      sourceId: 'zm',
      showId: 'show-1',
      records: [record],
    );
    final saved = await artwork.readSaved(
      [record],
      sourceId: 'zm',
      showId: 'show-1',
    );
    expect(saved, isNotNull);
    expect(saved!.description, 'A sage is reborn.');
    expect(saved.episodes, hasLength(3));
    expect(saved.episodes.first.description, 'He takes the exam.');
    // Another show's id does not read this folder's file.
    expect(
      await artwork.readSaved([record], sourceId: 'zm', showId: 'other'),
      isNull,
    );

    final local = await artwork.localize(
      saved,
      [record],
      sourceId: 'zm',
      showId: 'show-1',
    );
    expect(Uri.parse(local.cover!).scheme, 'file');
    expect(Uri.parse(local.banner!).scheme, 'file');
    for (final e in local.episodes) {
      expect(Uri.parse(e.thumbnail!).scheme, 'file');
      expect(File.fromUri(Uri.parse(e.thumbnail!)).existsSync(), isTrue);
    }
  });

  test('no manifest in the folder: nothing is written', () async {
    await FolderManifestStore.metaDir(folder).delete(recursive: true);
    await artwork.mirror(
      _detail,
      sourceId: 'zm',
      showId: 'show-1',
      records: [record],
    );
    expect(FolderManifestStore.metaDir(folder).existsSync(), isFalse);
    expect(fetched, isEmpty);
  });

  test('a hostile show.json cannot point outside .zangetsu', () async {
    // A file outside the folder that a crafted path would reach.
    final outside = File('${root.path}/secret.png')..writeAsBytesSync(_png());
    DownloadedShowArtwork.showFile(folder).writeAsStringSync(
      jsonEncode({
        'created_by': 'Zangetsu',
        'version': 1,
        'source_id': 'zm',
        'show_id': 'show-1',
        'detail': {'bad': true},
        'art': {
          'cover': '../../secret.png',
          'banner': outside.path,
          'episodes': {'0:e1': r'..\..\secret.png'},
        },
      }),
    );
    final local = await artwork.localize(
      _detail,
      [record],
      sourceId: 'zm',
      showId: 'show-1',
    );
    // Nothing saved inside the folder, and the crafted paths are ignored.
    expect(local.cover, _detail.cover);
    expect(local.banner, _detail.banner);
    expect(local.episodes.first.thumbnail, _detail.episodes.first.thumbnail);
    // The bad detail is not read as a show.
    expect(
      await artwork.readSaved([record], sourceId: 'zm', showId: 'show-1'),
      isNull,
    );
  });

  test('a folder holding another show is left alone', () async {
    DownloadedShowArtwork.showFile(folder).writeAsStringSync(
      jsonEncode({
        'created_by': 'Zangetsu',
        'version': 1,
        'source_id': 'zm',
        'show_id': 'someone-else',
        'detail': {},
        'art': {},
      }),
    );
    await artwork.mirror(
      _detail,
      sourceId: 'zm',
      showId: 'show-1',
      records: [record],
    );
    expect(fetched, isEmpty);
    final json =
        jsonDecode(DownloadedShowArtwork.showFile(folder).readAsStringSync())
            as Map;
    expect(json['show_id'], 'someone-else');
  });
}
