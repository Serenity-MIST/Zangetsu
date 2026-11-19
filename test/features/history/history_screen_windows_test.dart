// Windows History: graphite header at every entry point (settings
// workspace, in-frame shell page, pushed route), and a
// desktop context menu (right-click / More button) instead of the phone
// info bottom sheet. Phone keeps its own AppBar and long-press sheet.
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/playback/my_list.dart';
import 'package:watch_app/core/playback/watch_history.dart';
import 'package:watch_app/core/reading/read_history.dart';
import 'package:watch_app/core/repository/catalogue_repository.dart';
import 'package:watch_app/core/ui/desktop_settings_surface.dart';
import 'package:watch_app/features/history/history_screen.dart';

class _WatchHistory implements WatchHistory {
  _WatchHistory(this.entries);
  final List<HistoryEntry> entries;
  final removed = <String>[];

  @override
  List<HistoryEntry> all() => [...entries];

  @override
  bool hasMoreCloudPages({String? forProfileId}) => false;

  @override
  Future<void> remove(String sourceId, String showId) async {
    removed.add(showId);
    entries.removeWhere((e) => e.showId == showId);
  }

  // Undo of a remove (track-9) puts the entry back.
  final restored = <String>[];
  @override
  Future<void> restore(HistoryEntry e) async {
    restored.add(e.showId);
    entries.insert(0, e);
  }

  // "Mark as finished" (track-10 C) rewrites the entry.
  final saved = <HistoryEntry>[];
  @override
  Future<void> save(HistoryEntry e, {bool flush = false}) async {
    saved.add(e);
    entries
      ..removeWhere((x) => x.showId == e.showId)
      ..insert(0, e);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _ReadHistory implements ReadHistory {
  @override
  List<ReadEntry> all() => const [];

  @override
  bool hasMoreCloudPages(ProviderType type, {String? forProfileId}) =>
      false;

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Fake implements CatalogueRepository, MyListStore {
  // The Windows row menu names "Add to My List" vs "Change list status".
  @override
  bool contains(MediaItem item) => false;

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

HistoryEntry _entry(String id) => HistoryEntry(
  sourceId: 'src',
  showId: id,
  showTitle: 'Show $id',
  showUrl: '/$id',
  category: 'sub',
  episodeId: '$id-1',
  episodeNumber: 1,
  episodeUrl: '/$id/1',
  position: const Duration(minutes: 5),
  duration: const Duration(minutes: 20),
  updatedAt: DateTime.now().millisecondsSinceEpoch,
);

void main() {
  late _WatchHistory watch;

  setUp(() {
    watch = _WatchHistory([_entry('a'), _entry('b')]);
    final fake = _Fake();
    sl
      ..registerSingleton<WatchHistory>(watch)
      ..registerSingleton<ReadHistory>(_ReadHistory())
      ..registerSingleton<CatalogueRepository>(fake)
      ..registerSingleton<MyListStore>(fake);
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await sl.reset();
  });

  // [showBack] false mirrors the in-frame shell page (Profile / Ctrl+H).
  Future<void> pump(
    WidgetTester tester,
    Size size, {
    bool scope = true,
    bool showBack = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final screen = HistoryScreen(showBack: showBack);
    await tester.pumpWidget(
      MaterialApp(home: scope ? DesktopSettingsScope(child: screen) : screen),
    );
    await tester.pump();
  }

  for (final size in const [Size(1280, 720), Size(1920, 1080)]) {
    testWidgets('graphite header and tabs at ${size.width}', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await pump(tester, size);
      expect(find.byKey(const ValueKey('history-desktop-header')), findsOneWidget);
      expect(find.text('Show a'), findsOneWidget);
      expect(find.byTooltip('Clear all'), findsOneWidget);
      // Tabs stay compact (not stretched) and sit in the horizontal centre.
      final tabBar = tester.getRect(find.byType(TabBar));
      expect(tabBar.width, lessThan(size.width / 2));
      expect(tabBar.center.dx, closeTo(size.width / 2, 1));
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    });
  }

  // History opened outside Settings (Profile page, Ctrl+H, Home) looks the
  // same as the Settings one: graphite header, back button, search box and
  // centred compact tabs.
  for (final size in const [Size(1280, 720), Size(1920, 1080)]) {
    testWidgets('shell page matches the Settings look at ${size.width}', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await pump(tester, size, scope: false, showBack: false);
      expect(find.byKey(const ValueKey('history-desktop-header')), findsOneWidget);
      expect(find.byKey(const ValueKey('history-search')), findsOneWidget);
      expect(find.byTooltip('Clear all'), findsOneWidget);
      // The in-frame page still gets the rounded back button.
      expect(find.byTooltip('Back'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);
      // Compact tabs (not stretched) centred horizontally, the same as the
      // Settings-hosted History.
      final tabBar = tester.getRect(find.byType(TabBar));
      expect(tabBar.width, lessThan(size.width / 2));
      expect(tabBar.center.dx, closeTo(size.width / 2, 1));
      expect(tabBar.left, greaterThan(size.width / 4));
      // The three labels are in Streaming, Manga, Novel order around the
      // middle of the window.
      final streaming = tester.getCenter(find.text('Streaming'));
      final manga = tester.getCenter(find.text('Manga'));
      final novel = tester.getCenter(find.text('Novel'));
      expect(streaming.dx, lessThan(manga.dx));
      expect(manga.dx, lessThan(novel.dx));
      expect(manga.dx, closeTo(size.width / 2, size.width * 0.05));
      expect(find.text('Show a'), findsOneWidget);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('pushed History outside Settings uses the same header', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await pump(tester, const Size(1280, 720), scope: false);
    expect(find.byKey(const ValueKey('history-desktop-header')), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);
    expect(tester.getRect(find.byType(TabBar)).width, lessThan(640));
    // Centred in the 1280-wide window, like every other Windows entry point.
    expect(tester.getRect(find.byType(TabBar)).center.dx, closeTo(640, 1));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Back on the shell page pops through the host PopScope', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // Stand-in for RootShell: a root PopScope(canPop: false) whose handler
    // closes the in-frame page.
    var backs = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) backs++;
          },
          child: const HistoryScreen(showBack: false),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Back'));
    await tester.pump();
    expect(backs, 1);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('right-click opens the desktop menu; Remove works', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await pump(tester, const Size(1280, 720));
    await tester.tap(find.text('Show a'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('Resume'), findsOneWidget);
    expect(find.text('Details'), findsOneWidget);
    // track-10 C: the phone sheet's extra actions are on the menu too.
    expect(find.text('Add to My List…'), findsOneWidget);
    expect(find.text('Mark as finished'), findsOneWidget);
    await tester.tap(find.text('Remove').last);
    await tester.pumpAndSettle();
    expect(watch.removed, ['a']);
    expect(find.text('Show a'), findsNothing);
    // track-9: an Undo toast puts the entry back.
    expect(find.text('Undo'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(watch.restored, ['a']);
    expect(find.text('Show a'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('the X button also offers Undo (track-9)', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await pump(tester, const Size(1280, 720));
    await tester.tap(find.byTooltip('Remove').first);
    await tester.pumpAndSettle();
    expect(watch.removed, ['a']);
    expect(find.text('Undo'), findsOneWidget);
    // Let the toast expire: nothing is restored.
    await tester.pump(const Duration(seconds: 7));
    await tester.pumpAndSettle();
    expect(watch.restored, isEmpty);
    expect(find.text('Undo'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Mark as finished saves the episode at 100%', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await pump(tester, const Size(1280, 720));
    await tester.tap(find.text('Show b'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mark as finished'));
    await tester.pumpAndSettle();
    expect(watch.saved.single.showId, 'b');
    expect(watch.saved.single.finished, isTrue);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('search box filters the tab and Ctrl+F focuses it', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await pump(tester, const Size(1280, 720));
    expect(find.byKey(const ValueKey('history-search')), findsOneWidget);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    final field = tester.widget<TextField>(
      find.descendant(
        of: find.byKey(const ValueKey('history-search')),
        matching: find.byType(TextField),
      ),
    );
    expect(field.focusNode!.hasFocus, isTrue);
    await tester.enterText(find.byType(TextField), 'show b');
    await tester.pump();
    expect(find.text('Show a'), findsNothing);
    expect(find.text('Show b'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pump();
    expect(find.text('No matches'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('More button opens the same menu', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await pump(tester, const Size(1280, 720));
    expect(find.byKey(const ValueKey('history-row-more')), findsNWidgets(2));
    await tester.tap(find.byKey(const ValueKey('history-row-more')).first);
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('Details'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('phone keeps its AppBar and no More button', (tester) async {
    await pump(tester, const Size(400, 800), scope: false);
    expect(find.byKey(const ValueKey('history-desktop-header')), findsNothing);
    expect(find.byKey(const ValueKey('history-row-more')), findsNothing);
  });
}
