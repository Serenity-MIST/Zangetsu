// Failed manga/novel chapters can be retried (dl-10) and a saved chapter
// deleted on Windows goes to the Recycle Bin (dl-2).
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/desktop/desktop_recycle_bin.dart';
import 'package:watch_app/core/download/chapter_download.dart';
import 'package:watch_app/core/download/chapter_download_store.dart';
import 'package:watch_app/core/download/chapter_downloader.dart';
import 'package:watch_app/core/download/download_recycle.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/models/page_content.dart';
import 'package:watch_app/core/repository/source_repository.dart';

/// Page lookups hang until released, so a retried chapter stays in flight
/// where the test can see it.
class _HeldSource implements SourceRepository {
  final entered = Completer<void>();
  final _held = <Completer<List<PageImage>>>[];
  void release() {
    for (final c in _held) {
      if (!c.isCompleted) c.complete(const []);
    }
  }

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  Future<List<PageImage>> pages(String chapterUrl, {String? sourceId}) {
    if (!entered.isCompleted) entered.complete();
    final c = Completer<List<PageImage>>();
    _held.add(c);
    return c.future;
  }
}

ChapterDownload _failed(String id, {int createdAt = 0}) => ChapterDownload(
  id: id,
  sourceId: 'src',
  showId: 'show',
  showTitle: 'Show',
  chapterId: id,
  chapterUrl: 'https://x/$id',
  chapterTitle: 'Chapter $id',
  mode: ContentMode.manga,
  status: ChapterDownloadStatus.failed,
  error: 'Network error',
  createdAt: createdAt,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late ChapterDownloadStore store;
  late _HeldSource source;
  late ChapterDownloader downloader;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('chapter_retry');
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => dir.path,
        );
    Hive.init(dir.path);
    await ChapterDownloadStore.init();
    store = ChapterDownloadStore();
    source = _HeldSource();
    downloader = ChapterDownloader(source, store);
  });

  tearDown(() async {
    await downloader.cancelAll();
    source.release();
    // Let the parked chapter unwind before Hive closes.
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await Hive.deleteBoxFromDisk(ChapterDownloadStore.boxName);
    await Hive.close();
    for (var i = 0; i < 5; i++) {
      try {
        await dir.delete(recursive: true);
        break;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
  });

  test('retry re-queues a failed chapter and keeps its partial pages',
      () async {
    final rec = _failed('a');
    await store.put(rec);
    // A page fetched before the failure sits in the .part folder.
    final part = Directory(
      '${(await store.dirFor(rec)).path}${ChapterDownloadStore.partSuffix}',
    );
    await part.create(recursive: true);
    final page = File('${part.path}/001.jpg');
    await page.writeAsBytes([1, 2, 3]);

    expect(await downloader.retry('a'), isTrue);
    await source.entered.future.timeout(const Duration(seconds: 5));
    expect(downloader.isBusy('a'), isTrue);
    expect(downloader.inFlight['a']!.error, isNull);
    expect(await page.exists(), isTrue);
    // A second retry while it runs is a no-op.
    expect(await downloader.retry('a'), isFalse);
  });

  test('retryFailed queues every failed chapter, oldest first', () async {
    await store.putAll([
      _failed('old', createdAt: 1),
      _failed('new', createdAt: 2),
      _failed('done', createdAt: 3).copyWith(
        status: ChapterDownloadStatus.done,
      ),
    ]);
    expect(await downloader.retryFailed(), 2);
    expect(downloader.inFlight.keys.toSet(), {'old', 'new'});
    expect(downloader.activeCount, 2);
    // The oldest failure is the one fetched first.
    await source.entered.future.timeout(const Duration(seconds: 5));
    expect(downloader.inFlight['old']!.status,
        ChapterDownloadStatus.downloading);
  });

  group('Recycle Bin (dl-2)', () {
    final recycled = <String>[];
    setUp(() {
      recycled.clear();
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      debugAllowRecycleInTests = true;
      debugRecycleOverride = (path) async {
        recycled.add(path);
        await File(path).delete();
        return true;
      };
    });
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      debugAllowRecycleInTests = false;
      debugRecycleOverride = null;
    });

    test('a saved chapter archive goes to the Recycle Bin', () async {
      final archive = File('${dir.path}/Chapter 1.cbz');
      await archive.writeAsBytes([1]);
      await store.put(
        _failed('saved').copyWith(
          status: ChapterDownloadStatus.done,
          archivePath: archive.path,
        ),
      );
      await store.remove('saved');
      expect(recycled, [archive.path]);
      expect(store.get('saved'), isNull);
    }, skip: !Platform.isWindows);

    test('a failed chapter is cleared for good', () async {
      await store.put(_failed('dead'));
      await store.remove('dead');
      expect(recycled, isEmpty);
      expect(store.get('dead'), isNull);
    }, skip: !Platform.isWindows);
  });
}
