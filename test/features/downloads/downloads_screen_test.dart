import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cue/cue.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/download/chapter_download_store.dart';
import 'package:watch_app/core/download/chapter_download.dart';
import 'package:watch_app/core/download/chapter_downloader.dart';
import 'package:watch_app/core/download/download_manager.dart';
import 'package:watch_app/core/download/download_prefs.dart';
import 'package:watch_app/core/download/download_record.dart';
import 'package:watch_app/core/playback/resume_store.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/features/downloads/downloads_screen.dart';

class _Manager extends ChangeNotifier implements DownloadManager {
  final records = <DownloadRecord>[
    _record('a1', 'Show A', DownloadStatus.done),
    _record('a2', 'Show A', DownloadStatus.paused),
    _record('b1', 'Show B', DownloadStatus.failed),
  ];
  DownloadRecord? resumed;
  DownloadRecord? retried;
  DownloadRecord? deleted;
  List<DownloadRecord> deletedBatch = [];

  @override
  List<DownloadRecord> get all => records;

  @override
  Map<String, List<DownloadRecord>> get byShow {
    final groups = <String, List<DownloadRecord>>{};
    for (final r in records) {
      (groups[r.showId] ??= []).add(r);
    }
    return groups;
  }

  @override
  Future<void> pruneMissing() async {}

  @override
  Future<List<({String path, String label, bool removable})>>
  listDownloadVolumes() async => const [];

  @override
  Future<void> resume(DownloadRecord record) async => resumed = record;

  @override
  Future<void> retry(DownloadRecord record) async => retried = record;

  @override
  Future<void> delete(DownloadRecord record) async {
    deleted = record;
    records.remove(record);
    notifyListeners();
  }

  @override
  Future<void> deleteAll(Iterable<DownloadRecord> group) async {
    deletedBatch = group.toList();
    final ids = deletedBatch.map((r) => r.id).toSet();
    records.removeWhere((r) => ids.contains(r.id));
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ChapterDownloader extends ChangeNotifier implements ChapterDownloader {
  @override
  Map<String, ChapterDownload> get inFlight => const {};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

DownloadRecord _record(String id, String title, DownloadStatus status) =>
    DownloadRecord(
      id: id,
      sourceId: 'source',
      showId: title,
      showTitle: title,
      showUrl: '/$title',
      episodeId: id,
      episodeUrl: '/$id',
      episodeNumber: id.endsWith('1') ? 1 : 2,
      episodeTitle: id == 'a2' ? 'Hidden treasure' : 'Pilot',
      category: 'sub',
      quality: '1080p',
      status: status,
      progress: status == DownloadStatus.done ? 1 : .5,
      bytesTotal: 1024 * 1024,
      createdAt: 1,
    );

void main() {
  late Directory directory;
  late _Manager manager;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('downloads_screen_');
    Hive.init(directory.path);
    await Hive.openBox(DownloadPrefs.boxName);
    await Hive.openBox<Map>(ChapterDownloadStore.boxName);
    await Hive.openBox<Map>(ResumeStore.boxName);
    manager = _Manager();
    final sl = GetIt.instance;
    sl.registerSingleton<AppMode>(const AppMode(isTv: false));
    sl.registerSingleton<DownloadManager>(manager);
    sl.registerSingleton<DownloadPrefs>(DownloadPrefs());
    sl.registerSingleton<ChapterDownloadStore>(ChapterDownloadStore());
    sl.registerSingleton<ChapterDownloader>(_ChapterDownloader());
    sl.registerSingleton<ResumeStore>(ResumeStore());
  });

  tearDown(() async {
    await GetIt.instance.reset();
    await Hive.close();
    await directory.delete(recursive: true);
  });

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(home: DownloadsScreen(showBack: false)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('poster grid opens existing episode controls and returns', (
    tester,
  ) async {
    await open(tester);
    expect(find.byType(SliverGrid), findsOneWidget);
    expect(find.byType(DownloadTile), findsNothing);
    await tester.tap(find.text('Show A'));
    await tester.pumpAndSettle();
    expect(find.byType(DownloadTile), findsNWidgets(2));
    await tester.tap(find.byType(PopupMenuButton<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Resume'));
    await tester.pumpAndSettle();
    expect(manager.resumed?.id, 'a2');
    await tester.tap(find.byKey(const ValueKey('downloads-back-to-grid')));
    await tester.pumpAndSettle();
    expect(find.byType(SliverGrid), findsOneWidget);
  });

  testWidgets('search matches an episode without hiding its show', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Hidden treasure');
    await tester.pumpAndSettle();
    expect(find.text('Show A'), findsOneWidget);
    expect(find.text('Show B'), findsNothing);
    await tester.tap(find.text('Show A'));
    await tester.pumpAndSettle();
    expect(find.byType(DownloadTile), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('downloads-back-to-grid')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'nothing matches');
    await tester.pumpAndSettle();
    expect(find.text('No downloads match your search'), findsOneWidget);
  });

  testWidgets('retry remains available without expand or collapse controls', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('Expand all'), findsNothing);
    expect(find.text('Collapse all'), findsNothing);
    await tester.tap(find.text('Show B'));
    await tester.pumpAndSettle();
    expect(find.byType(DownloadTile), findsOneWidget);
    await tester.tap(find.byType(PopupMenuButton<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(manager.retried?.id, 'b1');
    await tester.tap(find.byKey(const ValueKey('downloads-back-to-grid')));
    await tester.pumpAndSettle();
    expect(find.byType(DownloadTile), findsNothing);
    expect(find.byType(SliverGrid), findsOneWidget);
  });

  testWidgets('search opens inside the header above the Material tabs', (
    tester,
  ) async {
    await open(tester);
    expect(find.byType(TabBar), findsOneWidget);
    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    expect(
      tester.getCenter(find.byType(TextField)).dy,
      lessThan(tester.getTopLeft(find.byType(TabBar)).dy),
    );
    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Show A');
    await tester.pumpAndSettle();
    expect(find.text('Show B'), findsNothing);
    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Show B'), findsOneWidget);
  });

  testWidgets('deleting the open show returns to the remaining poster grid', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.text('Show A'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Delete all episodes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete all'));
    await tester.pumpAndSettle();
    expect(find.byType(SliverGrid), findsOneWidget);
    expect(find.text('Show A'), findsNothing);
    expect(find.text('Show B'), findsOneWidget);
  });

  testWidgets('download settings and location stay accessible', (tester) async {
    await open(tester);
    await tester.tap(find.byTooltip('Download settings'));
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsNWidgets(2));
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Change'));
    await tester.pumpAndSettle();
    expect(find.text('Choose folder…'), findsOneWidget);
  });

  testWidgets('grid fits a narrow phone with larger text', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.5)),
          child: child!,
        ),
        home: const DownloadsScreen(showBack: false),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SliverGrid), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('system back restores the poster grid at its scroll position', (
    tester,
  ) async {
    manager.records.clear();
    for (var i = 0; i < 30; i++) {
      manager.records.add(_record('s$i', 'Show $i', DownloadStatus.done));
    }
    await open(tester);
    await tester.scrollUntilVisible(
      find.text('Show 10'),
      250,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.ensureVisible(find.text('Show 10'));
    await tester.pumpAndSettle();
    final before = tester
        .state<ScrollableState>(find.byType(Scrollable).last)
        .position
        .pixels;
    expect(before, greaterThan(0));
    await tester.tap(find.text('Show 10'));
    await tester.pumpAndSettle();
    expect(find.byType(DownloadTile), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(SliverGrid), findsOneWidget);
    final after = tester
        .state<ScrollableState>(find.byType(Scrollable).last)
        .position
        .pixels;
    expect(after, closeTo(before, 1));
  });

  testWidgets('Manga and Novel switch inside Downloads without a new page', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.text('Manga'));
    await tester.pumpAndSettle();
    expect(find.text('Downloads'), findsOneWidget);
    expect(find.byType(AppBar), findsNothing);
    expect(
      find.text('Manga chapters you download appear here'),
      findsOneWidget,
    );
    await tester.tap(find.text('Novels'));
    await tester.pumpAndSettle();
    expect(find.text('Downloads'), findsOneWidget);
    expect(
      find.text('Novel chapters you download appear here'),
      findsOneWidget,
    );
    await tester.tap(find.text('Episodes'));
    await tester.pumpAndSettle();
    expect(find.byType(SliverGrid), findsOneWidget);
  });

  testWidgets('saved chapters use the inline grid and preserve reading order', (
    tester,
  ) async {
    final store = GetIt.instance<ChapterDownloadStore>();
    await tester.runAsync(() async {
      for (final mode in [ContentMode.manga, ContentMode.novel]) {
        for (final number in [2, 1]) {
          await store.put(
            ChapterDownload(
              id: '${mode.name}$number',
              sourceId: 'source',
              showId: 'book',
              showTitle: '${mode.name} book',
              chapterId: '$number',
              chapterUrl: '/${mode.name}/$number',
              chapterTitle: 'Chapter $number',
              mode: mode,
              status: ChapterDownloadStatus.done,
              number: number.toDouble(),
            ),
          );
        }
      }
    });
    await open(tester);
    await tester.tap(find.textContaining('Manga').first);
    await tester.pumpAndSettle();
    expect(find.byType(SliverGrid), findsOneWidget);
    expect(find.text('novel book'), findsNothing);
    final mangaHero = tester.widget<Hero>(find.byType(Hero).first).tag;
    await tester.tap(find.text('manga book'));
    await tester.pumpAndSettle();
    expect(tester.widget<Hero>(find.byType(Hero).first).tag, mangaHero);
    expect(
      tester.getTopLeft(find.text('Chapter 1')).dy,
      lessThan(tester.getTopLeft(find.text('Chapter 2')).dy),
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('manga book'), findsOneWidget);
    await tester.tap(find.textContaining('Novels').first);
    await tester.pumpAndSettle();
    expect(find.text('novel book'), findsOneWidget);
    expect(find.text('manga book'), findsNothing);
    expect(tester.widget<Hero>(find.byType(Hero).first).tag, isNot(mangaHero));
  });

  testWidgets('download progress updates do not restart the entrance motion', (
    tester,
  ) async {
    await open(tester);
    expect(find.byWidgetPredicate((widget) => widget is Cue), findsOneWidget);
    manager.notifyListeners();
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(find.byType(SliverGrid), findsOneWidget);
  });

  testWidgets('swiping content keeps all three tabs in sync', (tester) async {
    await open(tester);
    expect(find.byType(TabBarView), findsOneWidget);
    await tester.drag(find.byType(TabBarView), const Offset(-350, 0));
    await tester.pumpAndSettle();
    final tabs = tester.widget<TabBar>(find.byType(TabBar));
    expect(tabs.controller!.index, 1);
    expect(
      find.text('Manga chapters you download appear here'),
      findsOneWidget,
    );
    await tester.drag(find.byType(TabBarView), const Offset(-350, 0));
    await tester.pumpAndSettle();
    expect(tabs.controller!.index, 2);
    expect(
      find.text('Novel chapters you download appear here'),
      findsOneWidget,
    );
    await tester.tap(find.text('Episodes'));
    await tester.pumpAndSettle();
    expect(tabs.controller!.index, 0);
    expect(find.byType(SliverGrid), findsOneWidget);
    final labelBottom = tester.getBottomLeft(find.text('Episodes')).dy;
    final barBottom = tester.getBottomLeft(find.byType(TabBar)).dy;
    expect(barBottom - labelBottom, lessThanOrEqualTo(10));
  });

  testWidgets('reduced motion shows downloads without Cue animation', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: const DownloadsScreen(showBack: false),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byWidgetPredicate((widget) => widget is Cue), findsNothing);
    expect(find.byType(Hero), findsNothing);
    expect(find.byType(SliverGrid), findsOneWidget);
  });

  testWidgets('compact header and matching poster Hero on the title page', (
    tester,
  ) async {
    await open(tester);
    final header = find
        .ancestor(
          of: find.text('Downloads'),
          matching: find.byType(DecoratedBox),
        )
        .first;
    expect(tester.getSize(header).height, lessThanOrEqualTo(50));
    final tag = tester.widget<Hero>(find.byType(Hero).first).tag;
    await tester.tap(find.text('Show A'));
    await tester.pumpAndSettle();
    expect(tester.widget<Hero>(find.byType(Hero).first).tag, tag);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(SliverGrid), findsOneWidget);
  });

  testWidgets('selection deletes only chosen episodes after confirmation', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.text('Show A'));
    await tester.pumpAndSettle();
    await tester.longPress(find.byType(DownloadTile).last);
    await tester.pumpAndSettle();
    expect(find.byType(Checkbox), findsNWidgets(2));
    expect(tester.widget<Checkbox>(find.byType(Checkbox).first).value, isFalse);
    expect(tester.widget<Checkbox>(find.byType(Checkbox).last).value, isTrue);
    expect(find.byType(PopupMenuButton<String>), findsNothing);
    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(manager.records.length, 3);
    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    final index = manager.records.indexWhere((record) => record.id == 'a2');
    manager.records[index] = manager.records[index].copyWith(
      status: DownloadStatus.done,
      filePath: () => '/finished-while-confirming.mp4',
    );
    manager.notifyListeners();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    expect(manager.records.map((r) => r.id), ['a1', 'b1']);
    expect(
      manager.deletedBatch.single.filePath,
      '/finished-while-confirming.mp4',
    );
    expect(find.byType(DownloadTile), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);
  });

  testWidgets(
    'select all can clear selection and Back restores normal controls',
    (tester) async {
      await open(tester);
      await tester.tap(find.text('Show A'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Select episodes'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Select all'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<Checkbox>(find.byType(Checkbox))
            .every((checkbox) => checkbox.value == true),
        isTrue,
      );
      await tester.tap(find.byTooltip('Clear'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<Checkbox>(find.byType(Checkbox))
            .every((checkbox) => checkbox.value == false),
        isTrue,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(DownloadTile), findsNWidgets(2));
      expect(find.byType(Checkbox), findsNothing);
      expect(find.byType(PopupMenuButton<String>), findsNWidgets(2));
      expect(manager.records.length, 3);
    },
  );

  testWidgets('Select all respects the visible search results', (tester) async {
    await open(tester);
    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Hidden treasure');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show A'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Select episodes'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Select all'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    expect(manager.records.map((record) => record.id), ['a1', 'b1']);
    expect(find.text('No downloads match your search'), findsOneWidget);
  });
}
