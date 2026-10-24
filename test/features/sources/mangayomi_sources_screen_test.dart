import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/mangayomi/mangayomi_manager.dart';
import 'package:watch_app/features/sources/mangayomi_sources_screen.dart';
import 'package:zangetsu_source_bridge/zangetsu_source_bridge.dart';

MangayomiSource source(Uri repository, int id, String name, int type) =>
    MangayomiSource(
      repository: repository,
      key: 'mg:${repository.host}:$id',
      id: id,
      name: name,
      baseUrl: Uri.parse('https://$name.example'),
      codeUrl: Uri.parse('https://cdn.example/$name.js'),
      version: '1.0.0',
      contentType: MangayomiContentType.values[type],
      codeLanguage: MangayomiCodeLanguage.javascript,
      language: 'en',
    );

class FakeMangayomiExtensionService extends MangayomiExtensionService {
  FakeMangayomiExtensionService(this.catalogues) : super(Directory('/unused'));

  final Map<Uri, List<MangayomiSource>> catalogues;
  final List<Uri> _repositories = [];

  @override
  Future<List<Uri>> repositories() async => List.unmodifiable(_repositories);

  @override
  Future<List<InstalledMangayomiSource>> installed() async => const [];

  @override
  Future<List<MangayomiSource>> addRepository(Uri url) async {
    _repositories.add(url);
    return catalogues[url]!;
  }

  @override
  Future<List<MangayomiSource>> refreshRepository(Uri url) async =>
      catalogues[url]!;
}

void main() {
  late MangayomiManager manager;

  setUp(() async {
    await sl.reset();
    final anime = Uri.parse('https://anime.example/anime_index.json');
    final mixed = Uri.parse('https://mixed.example/repository/');
    final newAnime = Uri.parse('https://new.example/anime_index.json');
    manager = MangayomiManager(
      FakeMangayomiExtensionService({
        anime: [source(anime, 1, 'StreamingOnly', 1)],
        newAnime: [source(newAnime, 4, 'NewStreaming', 1)],
        mixed: [
          source(mixed, 2, 'MangaSource', 0),
          source(mixed, 3, 'NovelSource', 2),
        ],
      }),
    );
    await manager.init();
    await manager.addRepository(anime);
    await manager.addRepository(mixed);
    sl.registerSingleton<MangayomiManager>(manager);
  });

  tearDown(() async {
    manager.dispose();
    await sl.reset(dispose: true);
  });

  testWidgets('typed tab hides repositories that hold no matching sources', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: MangayomiSourcesScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Repositories'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Manga'));
    await tester.pumpAndSettle();

    // A streaming-only repo must not leak into the Manga tab.
    expect(find.text('anime.example'), findsNothing);
    expect(find.text('mixed.example'), findsOneWidget);
    expect(find.text('MangaSource'), findsOneWidget);
    expect(find.text('Manga · en'), findsOneWidget);
    expect(find.text('NovelSource'), findsNothing);

    await tester.tap(find.text('Novel'));
    await tester.pumpAndSettle();

    expect(find.text('anime.example'), findsNothing);
    expect(find.text('MangaSource'), findsNothing);
    expect(find.text('mixed.example'), findsOneWidget);
    expect(find.text('NovelSource'), findsOneWidget);

    await tester.tap(find.text('Streaming'));
    await tester.pumpAndSettle();

    // Back to Streaming: the mixed repo has no streaming sources either.
    expect(find.text('anime.example'), findsOneWidget);
    expect(find.text('StreamingOnly'), findsOneWidget);
    expect(find.text('mixed.example'), findsNothing);
  });

  testWidgets('adding an anime repository reveals its streaming sources', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: MangayomiSourcesScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Repositories'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Novel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add repository'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).last,
      'https://new.example/anime_index.json',
    );
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(find.text('new.example'), findsOneWidget);
    expect(find.text('NewStreaming'), findsOneWidget);
  });
}
