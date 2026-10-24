import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/mangayomi/mangayomi_manager.dart';
import 'package:watch_app/core/mangayomi/mangayomi_provider.dart';
import 'package:zangetsu_source_bridge/zangetsu_source_bridge.dart';

class _FakeManager extends MangayomiManager {
  _FakeManager(this.worker)
    : super(MangayomiExtensionService(Directory.systemTemp));

  final _FakeWorker worker;

  @override
  Future<T> run<T>(
    String sourceId,
    Future<T> Function(MangayomiRuntimeWorker worker) operation,
  ) => operation(worker);
}

class _FakeWorker extends MangayomiRuntimeWorker {
  _FakeWorker({required this.latest})
    : super(MSource(), '', MangayomiCodeLanguage.javascript);

  final MPages latest;

  @override
  Future<MPages> getPopular(int page) async => throw StateError('unavailable');

  @override
  Future<MPages> getLatestUpdates(int page) async => latest;
}

void main() {
  test(
    'Manga Home falls back to latest updates if popular is unavailable',
    () async {
      final source = MangayomiSource(
        repository: Uri.parse('https://repo.example.com/index.json'),
        key: 'mg:repo:0:0:1',
        id: 1,
        name: 'Manga source',
        baseUrl: Uri.parse('https://manga.example.com'),
        codeUrl: Uri.parse('https://repo.example.com/source.js'),
        version: '1',
        contentType: MangayomiContentType.manga,
        codeLanguage: MangayomiCodeLanguage.javascript,
        language: 'en',
      );
      final worker = _FakeWorker(
        latest: MPages(
          list: [MManga(name: 'Latest manga', link: '/latest')],
        ),
      );
      final manager = _FakeManager(worker);
      final provider = MangayomiProvider(
        manager: manager,
        installed: InstalledMangayomiSource(source, File('unused.js')),
      );

      final sections = await provider.getHome();

      expect(sections, hasLength(1));
      expect(sections!.single.title, 'Latest');
      expect(sections.single.items.single.title, 'Latest manga');
      expect(sections.single.more?.kind, 'mg_latest');
      manager.dispose();
    },
  );
}
