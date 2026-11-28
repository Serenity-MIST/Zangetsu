import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride, TargetPlatform;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_detail.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/page_content.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/privacy/incognito_mode.dart';
import 'package:watch_app/core/provider/base_provider.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/core/provider/reading_provider.dart';
import 'package:watch_app/core/reading/read_history.dart';
import 'package:watch_app/core/reading/read_store.dart';
import 'package:watch_app/core/reading/reader_prefs.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/core/supabase/supabase_service.dart';
import 'package:watch_app/features/reader/novel_chapter_list_panel.dart';
import 'package:watch_app/features/reader/novel_desktop_fonts.dart';
import 'package:watch_app/features/reader/novel_desktop_selection.dart';
import 'package:watch_app/features/reader/novel_reader_screen.dart';

/// Windows novel reader work: reader-3/4/6/7/10/11/13 (novel side).

/// Canned chapter text per URL, like novel_reader_test.dart's fake.
class _FakeReadingProvider implements BaseProvider, ReadingProvider {
  _FakeReadingProvider(this.sourceId, this.textByUrl);

  @override
  final String sourceId;
  final Map<String, String> textByUrl;

  @override
  String get displayName => sourceId;
  @override
  Future<ProviderInfo> getInfo() => throw UnimplementedError();
  @override
  Future<List<HomeSection>?> getHome({String category = 'sub'}) =>
      throw UnimplementedError();
  @override
  Future<List<MediaItem>> popular({
    String category = 'sub',
    int dateRange = 7,
    int page = 1,
  }) => throw UnimplementedError();
  @override
  Future<List<MediaItem>> search(
    String query,
    int page, {
    String category = '',
  }) => throw UnimplementedError();
  @override
  Future<MediaDetail> getDetail(String url, {String category = 'sub'}) =>
      throw UnimplementedError();
  @override
  Future<List<Episode>> getEpisodes(String url, {String category = 'sub'}) =>
      throw UnimplementedError();
  @override
  Future<List<VideoSource>> getVideoSources(
    String episodeUrl, {
    bool fast = false,
  }) => throw UnimplementedError();
  @override
  Future<List<PageImage>> getPages(String chapterUrl) =>
      throw UnimplementedError();
  @override
  Future<ChapterText> getText(String chapterUrl) async =>
      ChapterText(html: '<p>${textByUrl[chapterUrl] ?? 'missing'}</p>');
}

Episode _chapter(String id, String url) => Episode(id: id, title: id, url: url);

/// Enough text for several book pages.
final String _longText = List.generate(
  120,
  (i) => 'Paragraph $i contains enough words for a paginated novel.',
).join('</p><p>');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ReaderPrefs (Windows reader additions)', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('reader_prefs_desktop');
      Hive.init(dir.path);
      await ReaderPrefs.init();
    });
    tearDown(() async {
      debugDefaultTargetPlatformOverride = null;
      await Hive.close();
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('reader fullscreen defaults off on Windows only (reader-4 C)', () {
      final prefs = ReaderPrefs();
      expect(prefs.fullscreen, isTrue);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(prefs.fullscreen, isFalse);
    });

    test('click to turn defaults on (reader-7)', () async {
      final prefs = ReaderPrefs();
      expect(prefs.clickToTurn, isTrue);
      await prefs.setClickToTurn(false);
      expect(prefs.clickToTurn, isFalse);
    });

    test(
      'font size steps stay in the wider Windows range (reader-11)',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        final prefs = ReaderPrefs();
        expect(ReaderPrefs.maxFontSize, 40);
        await prefs.setFontSize(39);
        expect(await prefs.stepFontSize(1), 40);
        expect(await prefs.stepFontSize(1), 40);
        await prefs.setFontSize(10);
        expect(await prefs.stepFontSize(-1), 10);
        debugDefaultTargetPlatformOverride = null;
        // Phones keep their old range.
        expect(ReaderPrefs.maxFontSize, 28);
        expect(ReaderPrefs.maxParagraphSpacing, 24);
      },
    );

    test('installed font keys round-trip', () {
      final key = ReaderPrefs.installedFontKey('Palatino Linotype');
      expect(ReaderPrefs.installedFontName(key), 'Palatino Linotype');
      expect(ReaderPrefs.installedFontName('serif'), isNull);
      expect(novelFontFamily(key), 'Palatino Linotype');
    });
  });

  group('Windows font list', () {
    test('reg query output becomes clean family names', () {
      const output =
          'HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows NT\\'
          'CurrentVersion\\Fonts\r\n'
          '    Arial (TrueType)    REG_SZ    arial.ttf\r\n'
          '    Arial Bold Italic (TrueType)    REG_SZ    arialbi.ttf\r\n'
          '    Cambria & Cambria Math (TrueType)    REG_SZ    cambria.ttc\r\n'
          '    Segoe UI Semibold (TrueType)    REG_SZ    seguisb.ttf\r\n'
          '    Wingdings (TrueType)    REG_SZ    wingding.ttf\r\n';
      final names = parseRegQueryValueNames(output);
      expect(names, hasLength(5));
      expect(parseWindowsFontNames(names), [
        'Arial',
        'Cambria',
        'Cambria Math',
        'Segoe UI',
      ]);
    });

    test('labels name installed and built-in fonts', () {
      expect(novelFontLabel('font:Calibri'), 'Calibri');
      expect(novelFontLabel('inter'), 'Inter');
    });
  });

  group('NovelSelectionArea links', () {
    test('search and translate addresses carry the selected text', () {
      final search = NovelSelectionArea.searchUri(' hello world ');
      expect(search.host, 'www.google.com');
      expect(search.queryParameters['q'], 'hello world');
      final translate = NovelSelectionArea.translateUri('bonjour', 'en');
      expect(translate.queryParameters['tl'], 'en');
      expect(translate.queryParameters['text'], 'bonjour');
      final long = NovelSelectionArea.searchUri('x' * 5000);
      expect(
        long.queryParameters['q']!.length,
        NovelSelectionArea.maxWebTextLength,
      );
    });
  });

  group('NovelReaderScreen on Windows', () {
    late Directory dir;
    late AniyomiManager ani;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('novel_desktop_test');
      Hive.init(dir.path);
      IncognitoMode.notifier.value = false;
      await ReadStore.init();
      await ReadHistory.init();
      await ReaderPrefs.init();
      sl.registerSingleton<ReadStore>(ReadStore());
      sl.registerSingleton<ReadHistory>(
        ReadHistory(SupabaseService(), () => null),
      );
      sl.registerSingleton<ReaderPrefs>(ReaderPrefs());
      ani = AniyomiManager();
      ani.register(
        _FakeReadingProvider('ani:n', {
          'u1': _longText,
          'u2': 'chapter two text',
        }),
      );
      sl.registerSingleton<SourceRepository>(
        SourceRepository(
          manager: ProviderManager(dio: Dio()),
          csManager: CloudStreamManager(),
          aniManager: ani,
          activeSource: ActiveSourceCubit(),
          prefs: PlaybackPrefs(),
        ),
      );
    });

    tearDown(() async {
      debugDefaultTargetPlatformOverride = null; // safety net
      await sl.reset();
      await Hive.close();
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    /// testWidgets with the Windows target set for the body only (the
    /// framework checks the override is back to null when a test ends).
    void windowsTest(String name, Future<void> Function(WidgetTester) body) =>
        testWidgets(name, (tester) async {
          debugDefaultTargetPlatformOverride = TargetPlatform.windows;
          try {
            await body(tester);
          } finally {
            debugDefaultTargetPlatformOverride = null;
          }
        });

    Widget harness() => MaterialApp(
      home: NovelReaderScreen(
        sourceId: 'ani:n',
        showId: 'b1',
        showTitle: 'Book',
        cover: null,
        chapters: [_chapter('c1', 'u1'), _chapter('c2', 'u2')],
        startIndex: 0,
      ),
    );

    /// Unmounts under runAsync so the reader's flushed history write lands.
    Future<void> close(WidgetTester tester) => tester.runAsync(() async {
      await tester.pumpWidget(const SizedBox());
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });

    Future<void> key(WidgetTester tester, LogicalKeyboardKey k) =>
        tester.runAsync(() async {
          await tester.sendKeyEvent(k);
          await Future<void>.delayed(const Duration(milliseconds: 30));
        });

    windowsTest('scroll mode text is selectable (reader-11 A)', (tester) async {
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();
      expect(find.byType(NovelSelectionArea), findsOneWidget);
      expect(find.byType(SelectionArea), findsOneWidget);
      await close(tester);
    });

    windowsTest('Ctrl+= and Ctrl+0 change the text size (reader-11 B)', (
      tester,
    ) async {
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();
      final prefs = sl<ReaderPrefs>();
      expect(prefs.fontSize, ReaderPrefs.defaultFontSize);
      await tester.runAsync(() async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.equal);
        await tester.sendKeyEvent(LogicalKeyboardKey.equal);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      expect(prefs.fontSize, ReaderPrefs.defaultFontSize + 2);
      await tester.runAsync(() async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      expect(prefs.fontSize, ReaderPrefs.defaultFontSize);
      await close(tester);
    });

    windowsTest(
      'paged mode ends on a focused end page; next continues (reader-6)',
      (tester) async {
        await tester.runAsync(() => sl<ReaderPrefs>().setNovelPaginated(true));
        await tester.pumpWidget(harness());
        await tester.pumpAndSettle();
        final pages = tester.widget<PageView>(find.byType(PageView));
        // End: last text page; Right: the end page, its button focused.
        await key(tester, LogicalKeyboardKey.end);
        await tester.pumpAndSettle();
        await key(tester, LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('novel-end-page')), findsOneWidget);
        expect(pages.controller!.page!.round(), greaterThan(1));
        final button = find.byKey(const ValueKey('novel-end-page-next'));
        expect(button, findsOneWidget);
        expect(tester.widget<InkWell>(button).focusNode!.hasFocus, isTrue);
        // Enter on the focused button opens the next chapter.
        await key(tester, LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(
          find.textContaining('chapter two text', findRichText: true),
          findsOneWidget,
        );
        await close(tester);
      },
    );

    // Phones keep their pages exactly as before: no end page, no selection
    // area (reader-6 / reader-11 are Windows only).
    testWidgets('phone paged mode has no end page or selection area', (
      tester,
    ) async {
      await tester.runAsync(() => sl<ReaderPrefs>().setNovelPaginated(true));
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();
      expect(find.byType(NovelSelectionArea), findsNothing);
      final pages = tester.widget<PageView>(find.byType(PageView));
      pages.controller!.jumpToPage(999);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('novel-end-page')), findsNothing);
      await close(tester);
    });

    windowsTest('a click on the right of a page turns it (reader-7)', (
      tester,
    ) async {
      await tester.runAsync(() => sl<ReaderPrefs>().setNovelPaginated(true));
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();
      final pages = tester.widget<PageView>(find.byType(PageView));
      expect(pages.controller!.page, 0);
      await tester.tapAt(const Offset(760, 300), kind: PointerDeviceKind.mouse);
      // Clicks wait out the double-click time (text can be selected).
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(pages.controller!.page, 1);
      // Off: clicks do nothing.
      await tester.runAsync(() => sl<ReaderPrefs>().setClickToTurn(false));
      await tester.tapAt(const Offset(760, 300), kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(pages.controller!.page, 1);
      await close(tester);
    });

    windowsTest('chapter list filters and marks read up to here (reader-10)', (
      tester,
    ) async {
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();
      await key(tester, LogicalKeyboardKey.keyC);
      await tester.pumpAndSettle();
      expect(find.byType(NovelChapterListPanel), findsOneWidget);
      expect(
        find.byKey(const ValueKey('reader-chapter-row-1')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey('reader-chapter-filter')),
        'c2',
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('reader-chapter-row-0')), findsNothing);
      expect(
        find.byKey(const ValueKey('reader-chapter-row-1')),
        findsOneWidget,
      );
      // Right-click the row, then Mark read up to here.
      await tester.tap(
        find.byKey(const ValueKey('reader-chapter-row-1')),
        buttons: kSecondaryMouseButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mark read up to here'));
      // The menu closes, then its action writes to Hive (real I/O).
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      final store = sl<ReadStore>();
      expect(store.finished('ani:n', 'b1', 'c1'), isTrue);
      expect(store.finished('ani:n', 'b1', 'c2'), isTrue);
      await close(tester);
    });
  });
}
