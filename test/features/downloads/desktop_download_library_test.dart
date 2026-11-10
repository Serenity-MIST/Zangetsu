import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/download/chapter_download_store.dart';
import 'package:watch_app/core/download/chapter_downloader.dart';
import 'package:watch_app/features/downloads/chapter_downloads_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/chapter_download.dart';
import 'package:watch_app/core/download/download_record.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/features/downloads/desktop_download_library.dart';

/// Isolated presentation records; never read or mutate the user's downloads.
DownloadRecord video(String id, {String source = 'source', String show = 'show',
    DownloadStatus status = DownloadStatus.done, String title = 'Saved series',
    String episode = 'Episode 1'}) => DownloadRecord(id: id, sourceId: source,
    showId: show, showTitle: title, showUrl: '/show', episodeId: id,
    episodeUrl: '/episode', episodeTitle: episode, category: 'dub', quality: 'best',
    status: status, createdAt: 1);

ChapterDownload chapter(String id, ContentMode mode) => ChapterDownload(id: id,
    sourceId: 'source', showId: 'show', showTitle: 'Reading series', chapterId: id,
    chapterUrl: '/chapter', chapterTitle: 'Chapter 100', mode: mode,
    status: ChapterDownloadStatus.done);

/// The title workspace exercises real UI dispatch with disposable records.
class _Box extends Fake implements Box<Map> {}
class _ChapterStore extends ChapterDownloadStore {
  final records = <ChapterDownload>[];
  final removed = <String>[];
  final changes = ValueNotifier<Box<Map>>(_Box());
  @override List<ChapterDownload> all() => records.toList();
  @override ValueNotifier<Box<Map>> listenable() => changes;
  @override Future<void> remove(String id) async {
    removed.add(id); records.removeWhere((c) => c.id == id);
    changes.value = _Box();
  }
}
class _ChapterWorker extends ChangeNotifier implements ChapterDownloader {
  final live = <String, ChapterDownload>{};
  final canceled = <String>[];
  bool canceledAll = false;
  bool clearedAll = false;
  @override Map<String, ChapterDownload> get inFlight => live;
  @override bool isBusy(String id) => live.containsKey(id);
  @override Future<void> cancel(String id) async {
    canceled.add(id); live.remove(id); notifyListeners();
  }
  @override Future<void> cancelAll() async { canceledAll = true; }
  @override Future<int> clearFailed() async { clearedAll = true; return 0; }
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('source, show and reading mode identities remain distinct', () {
    final groups = desktopDownloadCollections(videos: [video('a'),
      video('b', source: 'another'), video('c', show: 'other')],
      chapters: [chapter('m', ContentMode.manga), chapter('n', ContentMode.novel)]);
    expect(groups, hasLength(5));
    expect(groups.map((c) => c.key).toSet(), hasLength(5));
    expect(groups.fold(0, (int n, c) => n + c.total), 5);
  });
  test('saved, failed, waiting and recovered entries remain searchable', () {
    final recovered = DownloadRecord.fromMap({...video('disk').toMap(),
      'recoveredFromDisk': true, 'sourceId': 'local-files'});
    final groups = desktopDownloadCollections(videos: [video('ok'),
      video('failed', status: DownloadStatus.failed, episode: 'Episode 56'),
      video('waiting', status: DownloadStatus.queued), recovered], chapters: []);
    final group = groups.firstWhere((c) => c.key.sourceId == 'source');
    expect(group.total, 4); expect(group.saved, 2); expect(group.failed, 1);
    expect(group.pending, 1); expect(group.matches('episode 56'), isTrue);
    expect(groups, hasLength(1));
  });

  test('recovered saved episode does not inflate missing or failed counters', () {
    final local=DownloadRecord.fromMap({...video('disk').toMap(),
      'sourceId':'local-files','recoveredFromDisk':true,'episodeNumber':27,'season':1,
      'category':'unknown'});
    final failed=DownloadRecord.fromMap({...video('failed',status:DownloadStatus.failed).toMap(),
      'episodeNumber':27,'season':1,'category':'dub'});
    final group=desktopDownloadCollections(videos:[failed,local],chapters:[]).single;
    expect(group.total,1); expect(group.saved,1); expect(group.failed,0);
    expect(group.videos,hasLength(2));
    expect(failed.status,DownloadStatus.failed); expect(local.category,'unknown');
    final active=DownloadRecord.fromMap({...failed.toMap(),'status':'queued'});
    final downloading=desktopDownloadCollections(videos:[active,local],chapters:[]).single;
    expect(downloading.total,1); expect(downloading.saved,1); expect(downloading.pending,1);
  });

  test('multiple recovered groups join the one provider regardless input order', () {
    final locals = [for (final id in ['disk-a', 'disk-b'])
      DownloadRecord.fromMap({...video(id, show:id).toMap(),
        'recoveredFromDisk':true, 'sourceId':'local-files'})];
    for (final records in [[video('provider'), ...locals], [...locals.reversed, video('provider')]]) {
      final groups=desktopDownloadCollections(videos:records,chapters:[]);
      expect(groups,hasLength(1));
      expect(groups.single.total,3);
      expect(groups.single.key.sourceId,'source');
    }
  });

  test('ambiguous recovered title is never assigned to a provider', () {
    final local = DownloadRecord.fromMap({...video('disk').toMap(),
      'recoveredFromDisk': true, 'sourceId': 'local-files'});
    final groups = desktopDownloadCollections(videos: [video('a'),
      video('b', source: 'other-provider'), local], chapters: []);
    expect(groups, hasLength(3));
    expect(groups.singleWhere((c) => c.key.sourceId == 'local-files').videos.single.id, 'disk');
  });

  Future<void> open(WidgetTester tester, Size size, double scale,
      ValueChanged<DesktopDownloadCollection> onOpen) async {
    tester.view.reset();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final groups = desktopDownloadCollections(videos: [video('a')],
      chapters: [chapter('m', ContentMode.manga), chapter('n', ContentMode.novel)]);
    await tester.pumpWidget(MaterialApp(home: MediaQuery(
      data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
      child: Scaffold(body: DesktopDownloadLibrary(collections: groups, onOpen: onOpen)))));
    await tester.pumpAndSettle();
  }

  for (final scenario in [(const Size(1200, 800), 1.0),
      (const Size(420, 800), 1.0), (const Size(700, 1000), 2.0)]) {
    testWidgets('responsive posters avoid overflow at $scenario', (tester) async {
      await open(tester, scenario.$1, scenario.$2, (_) {});
      expect(tester.takeException(), isNull);
      expect(find.byType(GridView), findsOneWidget);
      expect(find.text('Saved series'), findsOneWidget);
    });
  }
  testWidgets('filter, search and title activation dispatch exact collection', (tester) async {
    DesktopDownloadCollection? opened;
    await open(tester, const Size(1200, 800), 1, (c) => opened = c);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Manga'));
    await tester.pumpAndSettle();
    expect(find.text('Saved series'), findsNothing);
    await tester.tap(find.text('Reading series'));
    expect(opened?.key.kind, ContentMode.manga.name);
    await tester.enterText(find.byType(TextField), 'no such title');
    await tester.pumpAndSettle();
    expect(find.text('Reading series'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('scoped chapter bulk actions leave other sources untouched', (tester) async {
    final store = _ChapterStore();
    final worker = _ChapterWorker();
    ChapterDownload entry(String id, String source, ChapterDownloadStatus status) =>
      ChapterDownload(id: id, sourceId: source, showId: 'show', showTitle: 'Title',
        chapterId: id, chapterUrl: '/$id', chapterTitle: id, mode: ContentMode.manga,
        status: status);
    final own = entry('own-queued', 'source', ChapterDownloadStatus.queued);
    final other = entry('other-queued', 'another', ChapterDownloadStatus.queued);
    worker.live.addAll({own.id: own, other.id: other});
    store.records.addAll([own, other,
      entry('own-failed', 'source', ChapterDownloadStatus.failed),
      entry('other-failed', 'another', ChapterDownloadStatus.failed)]);
    sl.registerSingleton<ChapterDownloadStore>(store);
    sl.registerSingleton<ChapterDownloader>(worker);
    addTearDown(() async {
      await sl.unregister<ChapterDownloadStore>();
      await sl.unregister<ChapterDownloader>();
      store.changes.dispose(); worker.dispose();
    });
    await tester.pumpWidget(const MaterialApp(home: ChapterDownloadsScreen(
      mode: ContentMode.manga, sourceId: 'source', showId: 'show')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('other-queued'), findsNothing);
    await tester.tap(find.text('Clear failed (1)'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(store.removed, ['own-failed']);
    expect(worker.clearedAll, isFalse);
    await tester.tap(find.text('Stop all (1)'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.text('Stop all'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(worker.canceled, ['own-queued']);
    expect(worker.canceledAll, isFalse);
    expect(worker.live.keys, ['other-queued']);
    expect(store.records.any((c) => c.id == 'other-failed'), isTrue);
  });

  testWidgets('focused poster activates with keyboard', (tester) async {
    DesktopDownloadCollection? opened;
    await open(tester, const Size(1200, 800), 1, (c) => opened = c);
    final element = tester.element(find.text('Saved series'));
    Focus.of(element).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(opened?.key.kind, 'video');
  });
}
