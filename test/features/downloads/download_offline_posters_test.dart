// Downloads posters with no network: the poster each show folder keeps in
// `.zangetsu/art/poster.png` (and the episode stills beside it) shows when
// the web picture fails, and at once while the app is offline. Real files in
// a temporary folder; nothing touches the user's downloads or the network.
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:watch_app/core/boot_network.dart';
import 'package:watch_app/core/download/download_folder_sync.dart';
import 'package:watch_app/core/download/download_record.dart';
import 'package:watch_app/core/ui/progressive_artwork.dart';
import 'package:watch_app/features/downloads/desktop_download_library.dart';
import 'package:watch_app/features/downloads/download_thumbnail.dart';

late Directory dir;

/// A finished episode saved in [folder] with a web cover.
DownloadRecord saved(String id, Directory folder, {String? cover = 'https://example.test/poster.jpg',
    DownloadStatus status = DownloadStatus.done}) => DownloadRecord(id: id,
    sourceId: 'source', showId: 'show', showTitle: 'Saved series', showUrl: '/show',
    episodeId: id, episodeUrl: '/episode', episodeTitle: 'Episode 1', category: 'sub',
    quality: 'best', status: status, createdAt: 1, cover: cover,
    filePath: p.join(folder.path, 'Episode 1_0123456789abcdef0123456789abcdef.mp4'));

/// `<folder>/.zangetsu/art/<name>` holding a small real PNG.
File writeArt(Directory folder, String name) {
  final file = File(p.join(folder.path, '.zangetsu', 'art', name))
    ..createSync(recursive: true)
    ..writeAsBytesSync(img.encodePng(img.Image(width: 2, height: 3)));
  return file;
}

/// The picture file the outermost artwork opens, or null for a web picture.
String? outerFile(WidgetTester tester) {
  final art = tester.widget<ProgressiveArtwork>(find.byType(ProgressiveArtwork).first);
  final provider = art.preview is ResizeImage
      ? (art.preview as ResizeImage).imageProvider : art.preview;
  return provider is FileImage ? provider.file.path : null;
}

Widget library(List<DownloadRecord> videos) => MaterialApp(home: Scaffold(
  body: DesktopDownloadLibrary(
    collections: desktopDownloadCollections(videos: videos, chapters: []),
    onOpen: (_) {})));

void main() {
  setUp(() {
    dir = Directory.systemTemp.createTempSync('zangetsu_offline_posters_');
    BootConnectivity.instance.offline.value = false;
  });
  tearDown(() {
    BootConnectivity.instance.offline.value = false;
    try { dir.deleteSync(recursive: true); } catch (_) {}
  });

  test('saved pictures are found next to the episode file', () {
    final folder = Directory(p.join(dir.path, 'Show'))..createSync();
    final r = saved('a', folder);
    final meta = p.join(folder.path, '.zangetsu', 'art');
    expect(downloadSavedArtPaths(r), [
      p.join(meta, 'ep-${DownloadFolderSync.episodeKey(r)}.png'),
      p.join(meta, 'poster.png'),
    ]);
    expect(downloadSavedArtPaths(r, still: false), [p.join(meta, 'poster.png')]);
    // No file yet, or a phone-style link: nothing to open.
    expect(downloadSavedArtPaths(DownloadRecord.fromMap(
        {...r.toMap(), 'filePath': null})), isEmpty);
    expect(downloadSavedArtPaths(DownloadRecord.fromMap(
        {...r.toMap(), 'filePath': 'content://tree/x.mp4'})), isEmpty);
  });

  test('one saved poster per folder, finished episodes first, capped', () {
    final s1 = Directory(p.join(dir.path, 'S1'))..createSync();
    final s2 = Directory(p.join(dir.path, 'S2'))..createSync();
    final queued = saved('q', s2, status: DownloadStatus.queued);
    final paths = downloadSavedPosterPaths([queued, saved('a', s1), saved('b', s1)]);
    expect(paths, [
      p.join(s1.path, '.zangetsu', 'art', 'poster.png'),
      p.join(s2.path, '.zangetsu', 'art', 'poster.png'),
    ]);
    expect(downloadSavedPosterPaths([saved('a', s1), queued], max: 1), hasLength(1));
  });

  testWidgets('online: the web cover loads, the saved poster waits behind it',
      (tester) async {
    final folder = Directory(p.join(dir.path, 'Show'))..createSync();
    final poster = writeArt(folder, 'poster.png');
    await tester.pumpWidget(library([saved('a', folder)]));
    final art = tester.widget<ProgressiveArtwork>(find.byType(ProgressiveArtwork).first);
    expect((art.preview as ResizeImage).imageProvider, isA<CachedNetworkImageProvider>());
    // What shows when the web cover fails: the saved poster.
    final behind = art.fallback;
    expect(behind, isA<SavedArtwork>());
    expect((behind as SavedArtwork).paths, [poster.path]);
  });

  testWidgets('offline: the saved poster opens at once and stays after the '
      'network returns', (tester) async {
    final folder = Directory(p.join(dir.path, 'Show'))..createSync();
    final poster = writeArt(folder, 'poster.png');
    BootConnectivity.instance.offline.value = true;
    await tester.pumpWidget(library([saved('a', folder)]));
    expect(outerFile(tester), poster.path);
    // The web cover is still tried after it (it may be in the image cache).
    final art = tester.widget<SavedArtwork>(find.byType(SavedArtwork).first);
    expect(art.fallback, isA<ProgressiveArtwork>());
    // Back online: no swap under the user.
    BootConnectivity.instance.offline.value = false;
    await tester.pump();
    expect(outerFile(tester), poster.path);
  });

  testWidgets('going offline switches an open card to the saved poster',
      (tester) async {
    final folder = Directory(p.join(dir.path, 'Show'))..createSync();
    final poster = writeArt(folder, 'poster.png');
    await tester.pumpWidget(library([saved('a', folder)]));
    expect(outerFile(tester), isNull);
    BootConnectivity.instance.offline.value = true;
    await tester.pump();
    expect(outerFile(tester), poster.path);
  });

  testWidgets('a show with no web cover still shows its saved poster',
      (tester) async {
    final folder = Directory(p.join(dir.path, 'Show'))..createSync();
    final poster = writeArt(folder, 'poster.png');
    await tester.pumpWidget(library([saved('a', folder, cover: null)]));
    expect(outerFile(tester), poster.path);
  });

  testWidgets('the saved poster file is really drawn from disk', (tester) async {
    final folder = Directory(p.join(dir.path, 'Show'))..createSync();
    writeArt(folder, 'poster.png');
    BootConnectivity.instance.offline.value = true;
    await tester.runAsync(() async {
      await tester.pumpWidget(library([saved('a', folder)]));
      for (var i = 0; i < 50; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
        final images = tester.widgetList<RawImage>(find.byType(RawImage));
        if (images.any((i) => i.image != null)) break;
      }
    });
    await tester.pump(const Duration(seconds: 1));
    final images = tester.widgetList<RawImage>(find.byType(RawImage));
    expect(images.any((i) => i.image != null), isTrue);
  });

  testWidgets('a missing saved poster falls through to the icon', (tester) async {
    final folder = Directory(p.join(dir.path, 'Show'))..createSync();
    BootConnectivity.instance.offline.value = true;
    await tester.runAsync(() async {
      await tester.pumpWidget(library([saved('a', folder, cover: null)]));
      for (var i = 0; i < 50; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
        if (find.byType(SvgPicture).evaluate().isNotEmpty) break;
      }
    });
    // The card's play icon, inside the picture that failed to open.
    expect(find.descendant(of: find.byType(ProgressiveArtwork),
        matching: find.byType(SvgPicture)), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('episode thumbnail', () {
    Widget row(DownloadRecord r) => MaterialApp(home: Center(child: SizedBox(
      width: 80, height: 48,
      child: DownloadThumbnail(thumbnail: 'https://example.test/ep1.jpg',
        cover: r.cover, saved: downloadSavedArtPaths(r),
        fallback: const Text('icon')))));

    testWidgets('online: the web still first, the saved pictures behind it',
        (tester) async {
      final folder = Directory(p.join(dir.path, 'Show'))..createSync();
      final r = saved('a', folder);
      await tester.pumpWidget(row(r));
      expect(outerFile(tester), isNull);
      expect(find.byType(SavedArtwork), findsNothing);
    });

    testWidgets('offline: the saved still opens first, then the poster',
        (tester) async {
      final folder = Directory(p.join(dir.path, 'Show'))..createSync();
      final r = saved('a', folder);
      final still = writeArt(folder, 'ep-${DownloadFolderSync.episodeKey(r)}.png');
      BootConnectivity.instance.offline.value = true;
      await tester.pumpWidget(row(r));
      expect(outerFile(tester), still.path);
      final art = tester.widget<SavedArtwork>(find.byType(SavedArtwork).first);
      expect(art.paths, downloadSavedArtPaths(r));
      BootConnectivity.instance.offline.value = false;
      await tester.pump();
      expect(outerFile(tester), still.path);
    });

    testWidgets('no saved pictures: unchanged', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox(width: 80, height: 48,
        child: DownloadThumbnail(fallback: Text('icon')))));
      expect(find.text('icon'), findsOneWidget);
    });
  });
}
