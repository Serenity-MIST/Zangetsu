import '../../core/models/home_section.dart';
import '../../core/models/media_item.dart';

/// How many titles of a one-section source catalogue go to the banner.
const desktopSourceBannerCount = 5;

/// Windows Home (home-11 A): splits an extension's catalogue into the banner
/// titles and the shelves below it, so the banner's titles are not repeated
/// as the first shelf.
///
/// With several sections the first one feeds the banner and is left out of
/// the shelves (as the phone does). A lone section lends only its first
/// [desktopSourceBannerCount] titles to the banner and its shelf keeps the
/// rest; [trimmedFrom] then names the original section so See all can still
/// open all of it (with its paging).
({
  List<MediaItem> featured,
  List<HomeSection> shelves,
  HomeSection? trimmedFrom,
})
desktopSourceCatalogueSplit(List<HomeSection> sections) {
  if (sections.isEmpty) {
    return (featured: const [], shelves: const [], trimmedFrom: null);
  }
  if (sections.length > 1) {
    return (
      featured: sections.first.items,
      shelves: sections.sublist(1),
      trimmedFrom: null,
    );
  }
  final only = sections.first;
  final rest = only.items.skip(desktopSourceBannerCount).toList();
  return (
    featured: only.items.take(desktopSourceBannerCount).toList(),
    shelves: rest.isEmpty
        ? const []
        : [HomeSection(title: only.title, items: rest, more: only.more)],
    trimmedFrom: rest.isEmpty ? null : only,
  );
}
