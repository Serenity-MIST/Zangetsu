// Windows Home (home-11 A): an extension catalogue's banner titles are not
// repeated as the first shelf.
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/features/home/desktop_source_catalogue_split.dart';

MediaItem _item(String id) => MediaItem(
  id: id,
  title: id,
  url: '/$id',
  type: ProviderType.anime,
  sourceId: 'ext',
);

HomeSection _section(String title, int count) => HomeSection(
  title: title,
  items: [for (var i = 0; i < count; i++) _item('$title$i')],
);

void main() {
  test('several sections: the first feeds the banner and is not a shelf', () {
    final popular = _section('Popular', 10);
    final latest = _section('Latest', 10);
    final split = desktopSourceCatalogueSplit([popular, latest]);
    expect(split.featured, popular.items);
    expect(split.shelves, [latest]);
    expect(split.trimmedFrom, isNull);
  });

  test('one section: the banner takes the first few, the shelf the rest', () {
    final only = _section('Popular', 12);
    final split = desktopSourceCatalogueSplit([only]);
    expect(split.featured, only.items.take(desktopSourceBannerCount));
    expect(split.shelves.single.items, only.items.skip(desktopSourceBannerCount));
    // See all still opens the whole section.
    expect(split.trimmedFrom, same(only));
  });

  test('a short lone section is only the banner', () {
    final split = desktopSourceCatalogueSplit([_section('Popular', 3)]);
    expect(split.featured, hasLength(3));
    expect(split.shelves, isEmpty);
  });

  test('nothing loaded yet', () {
    final split = desktopSourceCatalogueSplit(const []);
    expect(split.featured, isEmpty);
    expect(split.shelves, isEmpty);
  });
}
