import 'package:flutter/foundation.dart';

import '../../core/download/chapter_download.dart';
import '../../core/download/download_record.dart';
import '../downloads/desktop_download_library.dart';
import 'desktop_home_downloads.dart';
import 'desktop_home_page.dart';

/// Windows Home: the saved-shows shelf, and when Home has to redraw for it.
///
/// Download progress arrives up to once a second. Home used to rebuild every
/// shelf on each of those, although the saved-shows shelf is only drawn while
/// offline (or with an empty catalogue). This listens instead and only
/// notifies when the shelf is needed and what it shows really changed.
class DesktopHomeDownloadsFeed extends ChangeNotifier {
  DesktopHomeDownloadsFeed({
    required Listenable changes,
    required this.videos,
    required this.chapters,
  }) : _changes = changes {
    _changes.addListener(_onChange);
  }

  final Listenable _changes;

  /// Current records, read only while the shelf is needed.
  final List<DownloadRecord> Function() videos;
  final List<ChapterDownload> Function() chapters;

  final _cache = DesktopDownloadCollectionsCache();
  bool _needed = false, _reading = false;

  /// What the cards drawn last showed.
  List<Object?> _shown = const [];

  List<DesktopDownloadCollection> get _collections =>
      _cache.collections(videos: videos(), chapters: chapters());

  /// The cards to draw now; nothing (and no work) while not [needed].
  List<DesktopHomeDownload> cards({
    required bool needed,
    required bool reading,
    required void Function(DesktopDownloadCollection) open,
  }) {
    _needed = needed;
    _reading = reading;
    if (!needed) {
      _shown = const [];
      return const [];
    }
    final cards = desktopHomeDownloads(
      collections: _collections,
      reading: reading,
      // A change that does not show on the card (a queued episode, say) does
      // not redraw it, so the records are looked up fresh when it is opened.
      open: (collection) => open(_latest(collection)),
    );
    _shown = _signature(cards);
    return cards;
  }

  DesktopDownloadCollection _latest(DesktopDownloadCollection shown) {
    for (final collection in _collections) {
      if (collection.key == shown.key) return collection;
    }
    return shown;
  }

  void _onChange() {
    if (!_needed) return;
    final cards = desktopHomeDownloads(
      collections: _collections,
      reading: _reading,
      open: (_) {},
    );
    if (listEquals(_signature(cards), _shown)) return;
    notifyListeners();
  }

  static List<Object?> _signature(List<DesktopHomeDownload> cards) => [
    for (final card in cards) (card.title, card.subtitle, card.image),
  ];

  @override
  void dispose() {
    _changes.removeListener(_onChange);
    super.dispose();
  }
}
