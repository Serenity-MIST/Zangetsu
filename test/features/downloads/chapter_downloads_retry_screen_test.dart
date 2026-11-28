// dl-10: the chapter downloads screen offers Retry on failed chapters on the
// Windows desktop UI (per row and 'Retry failed (N)'), and phone keeps its
// single X per row with no retry controls.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/download/chapter_download.dart';
import 'package:watch_app/core/download/chapter_download_store.dart';
import 'package:watch_app/core/download/chapter_downloader.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/features/downloads/chapter_downloads_screen.dart';

// In-memory store: the screen only lists records and listens for changes.
class _Box extends Fake implements Box<Map> {}

class _Store extends ChapterDownloadStore {
  final records = <ChapterDownload>[];
  final changes = ValueNotifier<Box<Map>>(_Box());
  @override
  List<ChapterDownload> all() => records.toList();
  @override
  ChapterDownload? get(String id) =>
      records.where((c) => c.id == id).firstOrNull;
  @override
  ValueNotifier<Box<Map>> listenable() => changes;
}

// Records which chapters the screen asked to retry.
class _Worker extends ChangeNotifier implements ChapterDownloader {
  final retried = <String>[];
  int retryFailedCalls = 0;
  @override
  Map<String, ChapterDownload> get inFlight => const {};
  @override
  bool isBusy(String id) => false;
  @override
  Future<bool> retry(String id) async {
    retried.add(id);
    return true;
  }

  @override
  Future<int> retryFailed() async {
    retryFailedCalls++;
    return 0;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

ChapterDownload _failed(String id, String source) => ChapterDownload(
  id: id,
  sourceId: source,
  showId: 'show',
  showTitle: 'Title',
  chapterId: id,
  chapterUrl: '/$id',
  chapterTitle: id,
  mode: ContentMode.manga,
  status: ChapterDownloadStatus.failed,
  error: 'Network error',
);

void main() {
  late _Store store;
  late _Worker worker;

  setUp(() {
    store = _Store()
      ..records.addAll([
        _failed('own-failed', 'source'),
        _failed('other-failed', 'another'),
      ]);
    worker = _Worker();
    sl.registerSingleton<ChapterDownloadStore>(store);
    sl.registerSingleton<ChapterDownloader>(worker);
  });

  tearDown(() async {
    await sl.unregister<ChapterDownloadStore>();
    await sl.unregister<ChapterDownloader>();
    store.changes.dispose();
    worker.dispose();
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ChapterDownloadsScreen(
          mode: ContentMode.manga,
          sourceId: 'source',
          showId: 'show',
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  testWidgets('Windows: row Retry and scoped Retry failed', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await open(tester);
      // Only this title's failure is listed and counted.
      expect(find.text('Retry failed (1)'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.refresh_rounded).first);
      await tester.pump();
      expect(worker.retried, ['own-failed']);
      await tester.tap(find.text('Retry failed (1)'));
      await tester.pump();
      // The scoped view retries its own title only, never the global list.
      expect(worker.retried, ['own-failed', 'own-failed']);
      expect(worker.retryFailedCalls, 0);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('phone keeps the single X and no retry', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await open(tester);
      expect(find.textContaining('Retry failed'), findsNothing);
      expect(find.byIcon(Icons.refresh_rounded), findsNothing);
      expect(find.byIcon(Icons.close_rounded), findsWidgets);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
