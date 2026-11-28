// Windows downloaded show page (Downloads -> a show): the real show page in
// its downloaded mode. It lists the saved episodes, keeps only the Details
// tab (filled from the cached details), swaps Download for "Show online",
// has no trailer and no Auto Resolve row, and never fetches - so it works
// with the app offline. Harness follows detail_zmode_selector_placement_test.
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/boot_network.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/download/download_manager.dart';
import 'package:watch_app/core/download/download_record.dart';
import 'package:watch_app/core/download/downloaded_show_artwork.dart';
import 'package:watch_app/core/download/downloaded_show_details.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/hive/safe_box.dart';
import 'package:watch_app/core/metadata/episode_metadata_service.dart';
import 'package:watch_app/core/models/media_detail.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/playback/list_status_store.dart';
import 'package:watch_app/core/playback/my_list.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/playback/resume_store.dart';
import 'package:watch_app/core/playback/title_prefs.dart';
import 'package:watch_app/core/playback/watch_history.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/provider/base_provider.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/reading/read_store.dart';
import 'package:watch_app/core/repository/catalogue_repository.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/supabase/supabase_service.dart';
import 'package:watch_app/core/tracker/tracker_hub.dart';
import 'package:watch_app/core/trailer/trailer_service.dart';
import 'package:watch_app/core/ui/route_observer.dart';
import 'package:watch_app/core/zmode/match_store.dart';
import 'package:watch_app/core/zmode/metadata_repository.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/core/zmode/zmode_source_prefs.dart';
import 'package:watch_app/features/detail/detail_episodes_desktop.dart';
import 'package:watch_app/features/detail/detail_screen.dart';
import 'package:watch_app/features/detail/wrong_title_sheet.dart';
import 'package:watch_app/l10n/app_localizations.dart';

/// Fails the test if the page ever asks a source for anything.
class _NoNetworkRepository implements SourceRepository {
  int calls = 0;

  @override
  dynamic noSuchMethod(Invocation i) {
    calls++;
    throw StateError('downloaded page went online: ${i.memberName}');
  }

  @override
  bool hasSource(String id) => false;

  @override
  String displayName(String id) => id;

  @override
  List<({String id, String name})> get loadedSources => const [];
}

/// Catalogue label for the zm:// title.
class _MetadataLabel implements MetadataRepository {
  @override
  String nameForKind(ZKind kind) => 'AniList';
  @override
  String displayName(String sourceId) => 'AniList';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTitlePrefs extends TitlePrefsStore {
  @override
  String? category(String s, String u) => null;
  @override
  Future<void> setCategory(String s, String u, String c) async {}
}

class _FakeMyListStore implements MyListStore {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  bool contains(MediaItem m) => false;
  @override
  final ValueNotifier<int> revision = ValueNotifier<int>(0);
}

class _FakeListStatusStore implements ListStatusStore {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  WatchStatus? statusOf(MediaItem m) => null;
  @override
  final ValueNotifier<int> revision = ValueNotifier<int>(0);
}

class _FakeResumeStore implements ResumeStore {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  ResumeMark? get(String sourceId, String showId, String episodeId) => null;
}

class _FakeProviderRegistry implements ProviderRegistry {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  ProviderRegistryEntry? entryFor(String sourceId) => null;
  @override
  List<ProviderRegistryEntry> getAll() => const [];
}

class _FakeCloudStreamManager extends ChangeNotifier
    implements CloudStreamManager {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  BaseProvider? get(String sourceId) => null;
  @override
  String? repoNameForSourceId(String sourceId) => null;
  @override
  List<CloudStreamProvider> get enabled => const [];
}

/// Download manager holding the saved episodes of the test show.
class _FakeDownloadManager extends ChangeNotifier implements DownloadManager {
  _FakeDownloadManager(this.records);
  List<DownloadRecord> records;

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  List<DownloadRecord> get all => records;

  @override
  DownloadRecord? recordFor(
    String sourceId,
    String showId,
    String episodeId, {
    String? category,
  }) {
    for (final r in records) {
      if (r.sourceId == sourceId &&
          r.showId == showId &&
          r.episodeId == episodeId) {
        return r;
      }
    }
    return null;
  }

  /// Simulates deleting files outside the page.
  void replace(List<DownloadRecord> next) {
    records = next;
    notifyListeners();
  }
}

/// Counts trailer lookups; the downloaded page must not make any.
class _FakeTrailerService extends TrailerService {
  _FakeTrailerService() : super(Dio());
  int lookups = 0;
  @override
  Future<String?> youtubeId({
    required String title,
    String? englishTitle,
    required ProviderType type,
    String? year,
  }) async {
    lookups++;
    return 'trailer';
  }
}

class _FakePlaybackPrefs extends PlaybackPrefs {
  @override
  bool get autoplayTrailer => true;
  @override
  bool get autoAddToMyList => false;
  @override
  String get defaultCategory => 'sub';
}

class _FakeReadStore extends ReadStore {
  @override
  ({int pos, int total})? get(String s, String show, String c) => null;
  @override
  bool finished(String s, String show, String c) => false;
}

// A zm:// title, so the normal page would show the Auto Resolve row.
const _item = MediaItem(
  id: 'sage',
  title: 'The Strongest Sage',
  url: 'zm://anime/mal:5114',
  type: ProviderType.anime,
  sourceId: 'test',
);

DownloadRecord _rec(int n) => DownloadRecord(
  id: 'r$n',
  sourceId: 'test',
  showId: 'sage',
  showTitle: 'The Strongest Sage',
  showUrl: 'zm://anime/mal:5114',
  episodeId: 'e$n',
  episodeUrl: '/e$n',
  episodeNumber: n.toDouble(),
  episodeTitle: 'Sage episode $n',
  category: 'sub',
  quality: '1080p',
  status: DownloadStatus.done,
  filePath: 'C:/Downloads/sage/e$n.mp4',
  createdAt: n,
);

void main() {
  late Directory tempDir;
  late _NoNetworkRepository repo;
  late _FakeTrailerService trailer;
  late _FakeDownloadManager manager;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => '/tmp',
        );
    await sl.reset();
    tempDir = await Directory.systemTemp.createTemp('dl_show_page_test');
    Hive.init(tempDir.path);
    hiveBoxDir = tempDir.path;

    repo = _NoNetworkRepository();
    trailer = _FakeTrailerService();
    manager = _FakeDownloadManager([_rec(1), _rec(2)]);
    sl.registerSingleton<AppMode>(const AppMode(isTv: false));
    sl.registerSingleton<MyListStore>(_FakeMyListStore());
    sl.registerSingleton<ListStatusStore>(_FakeListStatusStore());
    sl.registerSingleton<ResumeStore>(_FakeResumeStore());
    sl.registerSingleton<ProviderRegistry>(_FakeProviderRegistry());
    sl.registerSingleton<CloudStreamManager>(_FakeCloudStreamManager());
    sl.registerSingleton<DownloadManager>(manager);
    sl.registerSingleton<TitlePrefsStore>(_FakeTitlePrefs());
    sl.registerSingleton<PlaybackPrefs>(_FakePlaybackPrefs());
    sl.registerSingleton<TrailerService>(trailer);
    sl.registerSingleton<EpisodeMetadataService>(EpisodeMetadataService(Dio()));
    sl.registerSingleton<MetadataRepository>(_MetadataLabel());
    sl.registerSingleton<TrackerHub>(TrackerHub(const []));
    sl.registerSingleton<SourceRepository>(repo);
    sl.registerSingleton<CatalogueRepository>(repo);
    sl.registerSingleton<ReadStore>(_FakeReadStore());
    sl.registerSingleton<WatchHistory>(
      WatchHistory(SupabaseService(), () => null),
    );
    sl.registerSingleton<MatchStore>(await MatchStore.open());
    sl.registerSingleton<ZSourcePrefs>(await ZSourcePrefs.open());

    // What the online page cached when the episodes were downloaded. Saved
    // here (outside the widget test's fake clock) so the box is open.
    await DownloadedShowDetails.save(
      const MediaDetail(
        id: 'sage',
        title: 'The Strongest Sage',
        url: 'zm://anime/mal:5114',
        type: ProviderType.anime,
        sourceId: 'test',
        description: 'A sage is reborn with a weak crest.',
        genres: ['Action', 'Fantasy'],
        studios: ['J.C.Staff'],
        year: '2022',
        status: MediaStatus.completed,
      ),
      sourceId: 'test',
      showId: 'sage',
    );
  });

  tearDown(() async {
    BootConnectivity.instance.offline.value = false;
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await sl.reset();
    await Hive.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  /// Pumps the downloaded show page on a wide Windows window.
  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        navigatorObservers: [appRouteObserver],
        home: DetailScreen(item: _item, downloads: () => manager.all),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // Loading the saved details checks the download folders on disk for
    // local images (real file IO): each step finishes on the real event loop
    // and continues on the next pump, so alternate the two a few times.
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('offline: saved episodes, Details only, Show online, '
      'no trailer and no Auto Resolve', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    BootConnectivity.instance.offline.value = true;
    try {
      await pumpPage(tester);

      // The saved episodes are the list.
      expect(find.textContaining('Sage episode 1'), findsWidgets);
      expect(find.textContaining('Sage episode 2'), findsWidgets);
      // Details (from the cache) stays; Cast and Relations are gone.
      expect(find.text('Details'), findsOneWidget);
      expect(find.text('Cast'), findsNothing);
      expect(find.text('Relations'), findsNothing);
      expect(find.textContaining('A sage is reborn'), findsWidgets);
      // "Show online" replaces Download.
      expect(find.text('Show online'), findsOneWidget);
      expect(find.widgetWithText(InkWell, 'Download'), findsNothing);
      // No trailer lookup and no Auto Resolve / Wrong title row.
      expect(trailer.lookups, 0);
      expect(find.byType(MatchLine), findsNothing);
      // Search box with the new wording and the Select button beside it.
      expect(find.text('Search episodes'), findsOneWidget);
      expect(find.byKey(EpisodeSelectButton.buttonKey), findsOneWidget);
      // Nothing went online.
      expect(repo.calls, 0);
      expect(tester.takeException(), isNull);

      // A file deleted elsewhere drops out of the list.
      manager.replace([_rec(2)]);
      await tester.pump();
      expect(find.textContaining('Sage episode 1'), findsNothing);
      expect(find.textContaining('Sage episode 2'), findsWidgets);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('offline: the full saved metadata renders like the online page', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    BootConnectivity.instance.offline.value = true;
    // Downloads in a real temp folder, with the episode thumbnail and cover
    // saved under .zangetsu/art like DownloadedShowArtwork writes them.
    final folder = Directory('${tempDir.path}/sage')..createSync();
    DownloadRecord inFolder(int n) => _rec(n).copyWith(
      filePath: () => '${folder.path}/e$n.mp4',
    );
    manager.records = [inFolder(1), inFolder(2)];
    const ep1 = Episode(
      id: 'e1',
      title: 'Sage episode 1',
      number: 1,
      url: '/e1',
      thumbnail: 'https://img/e1.jpg',
      description: 'Matthias heads for the capital.',
      date: '2022-01-08',
      rating: 6,
      runtimeMinutes: 24,
    );
    final art = Directory('${folder.path}/.zangetsu/art/meta')
      ..createSync(recursive: true);
    File(
      '${folder.path}/.zangetsu/${DownloadedShowArtwork.episodeArtPath(ep1)}',
    ).writeAsBytesSync(const [1, 2, 3]);
    File('${art.parent.path}/poster.png').writeAsBytesSync(const [1, 2, 3]);
    try {
      // The rich detail the online page saved (merged over setUp's entry).
      await tester.runAsync(
        () => DownloadedShowDetails.save(
          const MediaDetail(
            id: 'sage',
            title: 'The Strongest Sage',
            url: 'zm://anime/mal:5114',
            type: ProviderType.anime,
            sourceId: 'test',
            cover: 'https://img/cover.jpg',
            score: 72,
            popularity: 123456,
            favourites: 2345,
            sourceMaterial: 'Light Novel',
            country: 'JP',
            nativeTitle: '失格紋の最強賢者',
            synonyms: ['Shikkakumon no Saikyou Kenja'],
            tags: [
              MediaTag(name: 'Magic', rank: 90),
              MediaTag(name: 'Secret Twist', rank: 60, isSpoiler: true),
            ],
            episodes: [
              ep1,
              Episode(id: 'e2', title: 'Sage episode 2', url: '/e2', number: 2),
              Episode(id: 'e3', title: 'Sage episode 3', url: '/e3', number: 3),
            ],
          ),
          sourceId: 'test',
          showId: 'sage',
          castNames: const ['Yuuki Kaji'],
          // No manifest in the folder: nothing is mirrored or fetched.
          records: const [],
        ),
      );
      await pumpPage(tester);

      // Left panel: synopsis, Starring, Creators, the romaji line, and the
      // show's episode count (3), not just the saved files (2).
      expect(find.textContaining('A sage is reborn'), findsWidgets);
      expect(find.textContaining('Yuuki Kaji'), findsWidgets);
      expect(find.textContaining('J.C.Staff'), findsWidgets);
      expect(find.byKey(const ValueKey('downloaded-alt-title')), findsOneWidget);
      expect(find.textContaining('3 Episodes'), findsWidgets);
      // Episode row: description, runtime and air date from the saved
      // metadata, thumbnail from the local file.
      expect(find.textContaining('Matthias heads for the capital.'),
          findsOneWidget);
      expect(find.textContaining('24 min'), findsWidgets);
      expect(find.textContaining('2022-01-08'), findsWidgets);
      expect(
        find.byWidgetPredicate((w) {
          if (w is! Image) return false;
          // Image.file wraps its FileImage in a ResizeImage (cacheWidth).
          final image = w.image;
          final provider = image is ResizeImage ? image.imageProvider : image;
          return provider is FileImage && provider.file.path.endsWith('.jpg');
        }),
        findsOneWidget,
      );

      // Details tab: every provider row and the tags.
      await tester.tap(find.text('Details'));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Score'), findsOneWidget);
      expect(find.text('7.2 / 10'), findsOneWidget);
      expect(find.text('123,456'), findsOneWidget);
      expect(find.text('2,345'), findsOneWidget);
      expect(find.text('Light Novel'), findsOneWidget);
      expect(find.text('Japan'), findsOneWidget);
      expect(find.text('失格紋の最強賢者'), findsOneWidget);
      expect(find.text('Also known as'), findsOneWidget);
      expect(find.text('Tags'), findsOneWidget);
      expect(find.textContaining('Magic'), findsWidgets);
      // Episodes row: the show's total (3), like the header, not the 2 files.
      expect(find.text('3'), findsOneWidget);
      expect(repo.calls, 0);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Select starts selection; Delete replaces Download', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await pumpPage(tester);
      await tester.tap(find.byKey(EpisodeSelectButton.buttonKey));
      await tester.pump();
      expect(find.byKey(EpisodeSelectionBar.barKey), findsOneWidget);
      final bar = find.byKey(EpisodeSelectionBar.barKey);
      expect(
        find.descendant(of: bar, matching: find.text('Delete')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: bar, matching: find.text('Download')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
