import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/playback/library_repair.dart';
import 'package:watch_app/core/profiles/profile_scope.dart';

void main() {
  late Directory dir;
  late Box<Map> box;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('library-repair');
    Hive.init(dir.path);
    box = await Hive.openBox<Map>('my_list');
  });
  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });
  MediaItem item({
    String source = 'zm',
    String id = 'mal:5114',
    String url = 'zm://anime/mal:5114',
    ProviderType type = ProviderType.anime,
  }) => MediaItem(
    id: id,
    title: 'Fullmetal Alchemist',
    sourceId: source,
    url: url,
    type: type,
  );
  test(
    'migration merges proven duplicate metadata identities and preserves status, progress and backups',
    () async {
      final a = item();
      final b = item(source: 'anilist', id: '5114');
      await box.put('zm::mal:5114', a.toJson());
      await box.put('anilist::5114', b.toJson());
      final statuses = await Hive.openBox('list_status');
      await statuses.put('zm::mal:5114', 'completed');
      final progress = await Hive.openBox<Map>('resume_positions');
      await progress.put('zm::mal:5114::12', {'positionMs': 123456});
      final categories = await Hive.openBox('list_categories');
      await categories.put('anilist::5114', ['favourites']);
      final titlePrefs = await Hive.openBox<Map>('title_prefs');
      await titlePrefs.put('anilist::zm://anime/mal:5114', {'category': 'dub'});
      expect(await repairLibraryBox(box), 2);
      expect(categories.get('zm::anime:mal:5114'), ['favourites']);
      expect(titlePrefs.get('zm::zm://anime/mal:5114')?['category'], 'dub');
      expect(repairedLibraryKey('anilist', '5114'), 'zm::anime:mal:5114');
      expect(box.length, 1);
      expect(box.containsKey('zm::anime:mal:5114'), true);
      expect(statuses.get('zm::anime:mal:5114'), 'completed');
      expect(progress.get('zm::anime:mal:5114::12')?['positionMs'], 123456);
      expect(progress.get('zm::mal:5114::12')?['positionMs'], 123456);
      expect(Hive.box<Map>('my_list_repair_backup').length, 2);
      expect(await repairLibraryBox(box), 0);
    },
  );
  test('anime and manga with the same MAL number remain separate', () async {
    final a = item();
    final m = item(url: 'zm://manga/mal:5114', type: ProviderType.manga);
    expect(libraryStorageKey(a), isNot(libraryStorageKey(m)));
  });
  test(
    'legacy startup repair never moves another viewer into default',
    () async {
      final legacy = item();
      final viewerKey = profileScopedKey('kid', 'zm::mal:5114');
      await box.put(viewerKey, legacy.toJson());
      await box.put('zm::mal:5114', legacy.toJson());
      await repairLibraryBox(box);
      expect(box.get(viewerKey), legacy.toJson());
      expect(box.containsKey('zm::anime:mal:5114'), isTrue);
      expect(box.length, 2);
    },
  );
  test(
    'source ids recover their native namespace; unrelated titles are not deduplicated by name',
    () async {
      final a = item(
        source: '12345',
        id: 'one',
        url: '/manga/one',
        type: ProviderType.manga,
      );
      final b = item(
        source: '67890',
        id: 'two',
        url: '/manga/two',
        type: ProviderType.manga,
      );
      await box.put('12345::one', a.toJson());
      await box.put('67890::two', b.toJson());
      await repairLibraryBox(box);
      expect(box.length, 2);
      expect(box.containsKey('mihon:12345::one'), true);
    },
  );
}
