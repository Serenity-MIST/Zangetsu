// B1 side bug: the Windows folder scan recorded a 0.75 MB stub (Frieren E9)
// as a finished download. A scanned file now has to look finished: not
// empty, and not less than half of the size its manifest recorded.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:watch_app/core/download/folder_manifest.dart';
import 'package:watch_app/core/download/folder_manifest_scanner.dart';

void main() {
  group('looksFinished', () {
    test('an empty file never counts', () {
      expect(
        FolderManifestScanner.looksFinished(actualBytes: 0, manifestBytes: 0),
        isFalse,
      );
    });

    test('without a recorded size any non-empty file counts (old rule)', () {
      expect(
        FolderManifestScanner.looksFinished(actualBytes: 4, manifestBytes: 0),
        isTrue,
      );
    });

    test('a stub far below the recorded size is rejected', () {
      // 788 KB on disk, ~350 MB recorded for the episode.
      expect(
        FolderManifestScanner.looksFinished(
          actualBytes: 788 * 1024,
          manifestBytes: 350 * 1024 * 1024,
        ),
        isFalse,
      );
    });

    test('a file near its recorded (possibly estimated) size counts', () {
      expect(
        FolderManifestScanner.looksFinished(
          actualBytes: 300,
          manifestBytes: 350,
        ),
        isTrue,
      );
      expect(
        FolderManifestScanner.looksFinished(
          actualBytes: 400,
          manifestBytes: 350,
        ),
        isTrue,
      );
    });
  });

  test('sizeCheck off keeps the old non-empty-only rule', () {
    expect(
      FolderManifestScanner.looksFinished(
        actualBytes: 10,
        manifestBytes: 100,
        sizeCheck: false,
      ),
      isTrue,
    );
  });

  test('recordsFor skips a stub and keeps the full episode on Windows',
      () async {
    // The half-size rule is Windows only.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    expect(await _scanEpisodes(), [8]);
  });

  test('recordsFor keeps the short file on the phone (old rule)', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    expect(await _scanEpisodes(), [8, 9]);
  });
}

/// Writes a Frieren folder with a full E8 and a short E9 (10 of 100 bytes),
/// scans it and returns the episode numbers that were recorded.
Future<List<int>> _scanEpisodes() async {
  {
    final root = await Directory.systemTemp.createTemp('windows_scan_sanity');
    addTearDown(() => root.delete(recursive: true));
    final store = FolderManifestStore(hideOnWindows: false);
    final show = await Directory(p.join(root.path, 'Frieren')).create();
    await File(p.join(show.path, 'ep8.mp4')).writeAsBytes(List.filled(100, 1));
    await File(p.join(show.path, 'ep9.mp4')).writeAsBytes(List.filled(10, 1));
    await store.write(
      show,
      FolderManifest(
        folderId: FolderManifest.newFolderId(),
        title: 'Frieren',
        sourceId: 'zm',
        showId: 'anime:mal:59978',
        ids: const ManifestIds(mal: 59978),
        episodes: const [
          ManifestEpisode(
            key: '88888888888888888888888888888888',
            file: 'ep8.mp4',
            title: 'E8',
            number: 8,
            bytes: 100,
          ),
          ManifestEpisode(
            key: '99999999999999999999999999999999',
            file: 'ep9.mp4',
            title: 'E9',
            number: 9,
            bytes: 100,
          ),
        ],
      ),
    );
    final found = await FolderManifestScanner(store: store).scan(root);
    expect(found, hasLength(1));
    final records = await FolderManifestScanner.recordsFor(
      found.single,
      downloadRoot: root.path,
    );
    final numbers = records.map((r) => (r.episodeNumber ?? -1).round()).toList()
      ..sort();
    return numbers;
  }
}
