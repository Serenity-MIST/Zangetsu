import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/zmode/zmode_prefs.dart';
import 'package:watch_app/features/home/library_filter.dart';
import 'package:watch_app/features/home/cubit/my_list_cubit.dart';

void main() {
  test('dock selection separates anime, movie/TV, manga and novels', () {
    final entries = [
      for (final type in ProviderType.values)
        MyListEntry(
          MediaItem(
            id: type.name,
            title: type.name,
            url: type.name,
            sourceId: 'test',
            type: type,
          ),
          null,
        ),
    ];
    for (final pair in [
      (ContentMode.anime, StreamKind.anime, ProviderType.anime),
      (ContentMode.anime, StreamKind.movie, ProviderType.movie),
      (ContentMode.manga, StreamKind.anime, ProviderType.manga),
      (ContentMode.novel, StreamKind.anime, ProviderType.novel),
    ]) {
      expect(
        libraryEntriesForDock(
          entries,
          pair.$1,
          pair.$2,
        ).map((e) => e.item.type),
        [pair.$3],
      );
    }
  });
}
