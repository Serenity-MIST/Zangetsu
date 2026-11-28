// The show details saved with a download (Windows downloaded show page):
// they round-trip through the lazy Hive box with every episode's metadata,
// drop only cast cards and relations, merge without losing richer fields,
// fall back to the folder's show.json, and to what the download records
// know when nothing was saved.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:image/image.dart' as img;
import 'package:watch_app/core/download/download_folder_sync.dart';
import 'package:watch_app/core/download/download_record.dart';
import 'package:watch_app/core/download/downloaded_show_artwork.dart';
import 'package:watch_app/core/download/downloaded_show_details.dart';
import 'package:watch_app/core/download/folder_manifest.dart';
import 'package:watch_app/core/hive/safe_box.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/media_detail.dart';
import 'package:watch_app/core/models/media_extras.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';

/// The title as the Downloads page opens it.
const _item = MediaItem(
  id: 'show-1',
  title: 'The Strongest Sage',
  cover: 'https://img/cover.jpg',
  url: 'zm://anime/mal/1',
  type: ProviderType.anime,
  sourceId: 'zm',
);

/// A fully loaded online detail, as the show page has it.
MediaDetail _online() => MediaDetail(
  id: 'show-1',
  title: 'The Strongest Sage',
  cover: 'https://img/cover.jpg',
  banner: 'https://img/banner.jpg',
  url: 'zm://anime/mal/1',
  description: 'A sage is reborn.',
  status: MediaStatus.completed,
  genres: const ['Action', 'Fantasy'],
  studios: const ['J.C.Staff'],
  year: '2022',
  type: ProviderType.anime,
  sourceId: 'zm',
  malId: 44,
  score: 72,
  popularity: 5000,
  favourites: 120,
  sourceMaterial: 'Light Novel',
  country: 'JP',
  nativeTitle: '失格紋の最強賢者',
  synonyms: const ['Shikkakumon no Saikyou Kenja'],
  startDate: DateTime(2022, 1, 8),
  endDate: DateTime(2022, 3, 26),
  tags: const [
    MediaTag(name: 'Magic', rank: 90),
    MediaTag(name: 'Twist', rank: 50, isSpoiler: true),
  ],
  episodes: const [
    Episode(
      id: 'e1',
      title: 'Ep 1',
      url: 'u1',
      number: 1,
      season: 1,
      description: 'He takes the exam.',
      metaTitle: 'The Strongest Sage Appears.',
      date: '2022-01-08',
      rating: 6.5,
      runtimeMinutes: 24,
      thumbnail: 'https://img/e1.jpg',
    ),
    Episode(id: 'e2', title: 'Ep 2', url: 'u2', number: 2),
  ],
  castMembers: const [CastMember(name: 'Yuuki Kaji')],
  relations: const [MediaRelation(relation: 'Sequel', title: 'Season 2')],
);

/// One finished download of the show (optionally with a file on disk).
DownloadRecord _rec({String? filePath}) => DownloadRecord(
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
  malId: 44,
  status: DownloadStatus.done,
  filePath: filePath,
  createdAt: 1,
);

/// A tiny valid PNG, as the fake image fetcher returns it.
Uint8List _png() =>
    Uint8List.fromList(img.encodePng(img.Image(width: 4, height: 3)));

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('dl_show_details_test');
    Hive.init(dir.path);
    hiveBoxDir = dir.path;
  });

  tearDown(() async {
    DownloadedShowDetails.artwork = DownloadedShowArtwork();
    await Hive.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test(
    'saved details round-trip with episodes, without cast/relations',
    () async {
      await DownloadedShowDetails.save(
        _online(),
        sourceId: 'zm',
        showId: 'show-1',
        castNames: const ['Yuuki Kaji', 'Ai Kakuma'],
      );
      // Re-open from disk, like the next app start.
      await Hive.close();
      Hive.init(dir.path);

      final got = await DownloadedShowDetails.read('zm', 'show-1');
      expect(got, isNotNull);
      expect(got!.description, 'A sage is reborn.');
      expect(got.genres, ['Action', 'Fantasy']);
      expect(got.studios, ['J.C.Staff']);
      expect(got.status, MediaStatus.completed);
      expect(got.year, '2022');
      expect(got.score, 72);
      expect(got.popularity, 5000);
      expect(got.favourites, 120);
      expect(got.sourceMaterial, 'Light Novel');
      expect(got.country, 'JP');
      expect(got.nativeTitle, '失格紋の最強賢者');
      expect(got.synonyms, ['Shikkakumon no Saikyou Kenja']);
      expect(got.startDate, DateTime(2022, 1, 8));
      expect(got.tags.map((t) => (t.name, t.isSpoiler)), [
        ('Magic', false),
        ('Twist', true),
      ]);
      expect(got.malId, 44);
      expect(got.banner, 'https://img/banner.jpg');
      // Starring: the page's cast names fill the empty provider cast.
      expect(got.cast, ['Yuuki Kaji', 'Ai Kakuma']);
      // Every episode, with the fields Episode.toJson leaves out.
      expect(got.episodes, hasLength(2));
      final e1 = got.episodes.first;
      expect(e1.description, 'He takes the exam.');
      expect(e1.metaTitle, 'The Strongest Sage Appears.');
      expect(e1.date, '2022-01-08');
      expect(e1.rating, 6.5);
      expect(e1.runtimeMinutes, 24);
      expect(e1.season, 1);
      expect(e1.thumbnail, 'https://img/e1.jpg');
      // Cast cards and relations are not kept (those tabs hide offline).
      expect(got.castMembers, isEmpty);
      expect(got.relations, isEmpty);
      // Another show has nothing saved.
      expect(await DownloadedShowDetails.read('zm', 'other'), isNull);
    },
  );

  test('a poorer save never wipes richer saved fields', () async {
    await DownloadedShowDetails.save(
      _online(),
      sourceId: 'zm',
      showId: 'show-1',
    );
    // Saved again before the enrichment finished: no tags, score, synopsis
    // or episode descriptions.
    await DownloadedShowDetails.save(
      const MediaDetail(
        id: 'show-1',
        title: 'The Strongest Sage',
        url: 'zm://anime/mal/1',
        type: ProviderType.anime,
        sourceId: 'zm',
        episodes: [
          Episode(id: 'e1', title: 'Ep 1', url: 'u1', number: 1, season: 1),
          Episode(id: 'e2', title: 'Ep 2', url: 'u2', number: 2),
          Episode(id: 'e3', title: 'Ep 3', url: 'u3', number: 3),
        ],
      ),
      sourceId: 'zm',
      showId: 'show-1',
    );
    final got = (await DownloadedShowDetails.read('zm', 'show-1'))!;
    expect(got.description, 'A sage is reborn.');
    expect(got.score, 72);
    expect(got.tags, hasLength(2));
    expect(got.status, MediaStatus.completed);
    expect(got.genres, ['Action', 'Fantasy']);
    // The newer list wins, with the old metadata kept per episode.
    expect(got.episodes, hasLength(3));
    expect(got.episodes.first.description, 'He takes the exam.');
    expect(got.episodes.first.thumbnail, 'https://img/e1.jpg');
  });

  test('an older entry without episodes still reads', () async {
    final box = await openBoxSafely<String>(DownloadedShowDetails.boxName);
    await box.put(
      DownloadedShowDetails.keyFor('zm', 'show-1'),
      '{"id":"show-1","title":"Old","url":"u","description":"Old synopsis",'
      '"type":"anime","sourceId":"zm","status":"completed"}',
    );
    final got = (await DownloadedShowDetails.read('zm', 'show-1'))!;
    expect(got.title, 'Old');
    expect(got.description, 'Old synopsis');
    expect(got.episodes, isEmpty);
  });

  test('page detail uses the cache and keeps the record identity', () async {
    await DownloadedShowDetails.save(
      _online(),
      sourceId: 'zm',
      showId: 'show-1',
    );
    final detail = await loadDownloadedShowDetail(_item);
    expect(detail.description, 'A sage is reborn.');
    expect(detail.id, 'show-1');
    expect(detail.sourceId, 'zm');
    expect(detail.url, 'zm://anime/mal/1');
    // The saved episode metadata is there for the rows.
    expect(detail.episodes.first.description, 'He takes the exam.');
  });

  test('without Hive the folder show.json is read, images are local', () async {
    final folder = Directory('${dir.path}/show')..createSync();
    File('${folder.path}/e1.mp4').writeAsBytesSync(const [0]);
    // The folder manifest exists (written when the download finished).
    await FolderManifestStore(hideOnWindows: false).write(
      folder,
      FolderManifest(folderId: 'f1', title: 'The Strongest Sage'),
    );
    final record = _rec(filePath: '${folder.path}/e1.mp4');
    DownloadedShowDetails.artwork = DownloadedShowArtwork(
      sync: DownloadFolderSync(fetchArtwork: (_, _) async => _png()),
    );
    await DownloadedShowDetails.save(
      _online(),
      sourceId: 'zm',
      showId: 'show-1',
      records: [record],
    );
    expect(DownloadedShowArtwork.showFile(folder).existsSync(), isTrue);
    // Hive cleared (new PC, wiped AppData): the folder still knows.
    await DownloadedShowDetails.remove('zm', 'show-1');
    expect(await DownloadedShowDetails.read('zm', 'show-1'), isNull);

    final detail = await loadDownloadedShowDetail(_item, records: [record]);
    expect(detail.description, 'A sage is reborn.');
    expect(detail.tags, hasLength(2));
    expect(detail.cover, startsWith('file:'));
    expect(detail.banner, startsWith('file:'));
    expect(detail.episodes.first.thumbnail, startsWith('file:'));
    expect(File.fromUri(Uri.parse(detail.cover!)).existsSync(), isTrue);
  });

  test('offline, a banner with no saved copy shows the saved poster', () async {
    final folder = Directory('${dir.path}/show-nobanner')..createSync();
    File('${folder.path}/e1.mp4').writeAsBytesSync(const [0]);
    await FolderManifestStore(hideOnWindows: false).write(
      folder,
      FolderManifest(folderId: 'f2', title: 'The Strongest Sage'),
    );
    final record = _rec(filePath: '${folder.path}/e1.mp4');
    // The banner could not be fetched when the details were saved.
    DownloadedShowDetails.artwork = DownloadedShowArtwork(
      sync: DownloadFolderSync(
        fetchArtwork: (url, _) async => url.toString().contains('banner') ? null : _png(),
      ),
    );
    await DownloadedShowDetails.save(
      _online(),
      sourceId: 'zm',
      showId: 'show-1',
      records: [record],
    );
    final offline = await loadDownloadedShowDetail(
      _item,
      records: [record],
      offline: () => true,
    );
    expect(offline.cover, startsWith('file:'));
    expect(offline.banner, offline.cover);
    // Online the web banner still loads, so it is kept.
    final online = await loadDownloadedShowDetail(
      _item,
      records: [record],
      offline: () => false,
    );
    expect(online.cover, startsWith('file:'));
    expect(online.banner, 'https://img/banner.jpg');
  });

  test('without a cache the records fill the basics', () async {
    final detail = await loadDownloadedShowDetail(_item, records: [_rec()]);
    expect(detail.title, 'The Strongest Sage');
    expect(detail.cover, 'https://img/cover.jpg');
    expect(detail.malId, 44);
    expect(detail.description, isNull);
  });

  test('remove forgets the entry', () async {
    await DownloadedShowDetails.save(
      _online(),
      sourceId: 'zm',
      showId: 'show-1',
    );
    await DownloadedShowDetails.remove('zm', 'show-1');
    expect(await DownloadedShowDetails.read('zm', 'show-1'), isNull);
  });
}
