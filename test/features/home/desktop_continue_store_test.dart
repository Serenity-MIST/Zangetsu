// Windows Home Continue store (home-10): notifies only when Continue entries
// are added, removed, finished, change episode or move, never on a plain
// position save; lookups by show replace the per-poster linear search.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/playback/watch_history.dart';
import 'package:watch_app/core/reading/read_history.dart';
import 'package:watch_app/features/home/desktop_continue_store.dart';

/// A stored watch row, as WatchHistory writes it to Hive.
Map<String, dynamic> _row(
  String show, {
  String episode = 'e1',
  int positionMs = 60000,
  int durationMs = 1200000,
  int updatedAt = 100,
}) => {
  'sourceId': 'src',
  'showId': show,
  'showTitle': 'Show $show',
  'showUrl': '/$show',
  'category': 'sub',
  'episodeId': episode,
  'episodeNumber': 1,
  'episodeUrl': '/$show/$episode',
  'positionMs': positionMs,
  'durationMs': durationMs,
  'updatedAt': updatedAt,
};

/// Fake history: rows by show id, read newest first like recent().
class _Rows {
  final rows = <String, Map<String, dynamic>>{};
  int loads = 0;
  List<HistoryEntry> recent() {
    loads++;
    final list =
        rows.values
            .map(WatchHistory.entryFromMap)
            .where((e) => !e.finished)
            .toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }
}

void main() {
  late _Rows rows;
  late StreamController<BoxEvent> events;
  late DesktopContinueStore store;
  late int notified;

  /// Writes a row and emits the Hive event for it.
  Future<void> put(Map<String, dynamic> row) async {
    rows.rows[row['showId'] as String] = row;
    events.add(BoxEvent(row['showId'], row, false));
    // Stream delivery, then the store's coalescing microtask.
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  setUp(() {
    rows = _Rows()
      ..rows['a'] = _row('a', updatedAt: 300)
      ..rows['b'] = _row('b', updatedAt: 200);
    events = StreamController<BoxEvent>();
    store = DesktopContinueStore(
      loadWatched: rows.recent,
      loadReading: (_) => const <ReadEntry>[],
      watchEvents: events.stream,
    );
    notified = 0;
    store.addListener(() => notified++);
  });

  tearDown(() async {
    store.dispose();
    await events.close();
  });

  test('a position save of the same entry does not notify', () async {
    final loadsBefore = rows.loads;
    await put(_row('a', positionMs: 90000, updatedAt: 301));
    expect(notified, 0);
    // No full re-read for a progress-only save.
    expect(rows.loads, loadsBefore);
    // The new progress is held and shows on the next refresh.
    expect(store.watched.first.position, const Duration(milliseconds: 90000));
    store.refresh();
    expect(notified, 1);
  });

  test('a new entry, a new episode or a reorder notifies', () async {
    await put(_row('c', updatedAt: 400));
    expect(notified, 1);
    expect(store.watched.map((e) => e.showId), ['c', 'a', 'b']);

    await put(_row('c', episode: 'e2', updatedAt: 401));
    expect(notified, 2);

    // b jumps above the others.
    await put(_row('b', updatedAt: 500));
    expect(notified, 3);
    expect(store.watched.first.showId, 'b');
  });

  test('finishing or deleting an entry notifies', () async {
    await put(_row('a', positionMs: 1200000, updatedAt: 300));
    expect(notified, 1);
    expect(store.watched.map((e) => e.showId), ['b']);

    rows.rows.remove('b');
    events.add(BoxEvent('b', null, true));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(notified, 2);
    expect(store.watched, isEmpty);
  });

  test('refresh without changes does not notify', () {
    store.refresh();
    expect(notified, 0);
  });

  test('lookups match by show id or by URL', () {
    const byId = MediaItem(
      id: 'a',
      title: 'x',
      url: '/other',
      type: ProviderType.anime,
      sourceId: 'src',
    );
    const byUrl = MediaItem(
      id: 'zz',
      title: 'x',
      url: '/b',
      type: ProviderType.anime,
      sourceId: 'elsewhere',
    );
    const none = MediaItem(
      id: 'q',
      title: 'x',
      url: '/q',
      type: ProviderType.anime,
      sourceId: 'src',
    );
    expect(store.historyFor(byId)?.showId, 'a');
    expect(store.historyFor(byUrl)?.showId, 'b');
    expect(store.historyFor(none), isNull);
  });

  test('readEntryMarkedRead makes manga and novel entries finished', () {
    ReadEntry entry(int pos, int total) => ReadEntry(
      sourceId: 's',
      showId: 'm',
      title: 'M',
      chapterId: 'c',
      chapterUrl: '/c',
      pos: pos,
      total: total,
      updatedMs: 5,
      type: ProviderType.manga,
    );
    expect(entry(3, 20).finished, isFalse);
    expect(readEntryMarkedRead(entry(3, 20)).finished, isTrue);
    expect(readEntryMarkedRead(entry(100, 1000)).finished, isTrue);
    expect(readEntryMarkedRead(entry(0, 0)).finished, isTrue);
    // The time is kept, so History does not reorder.
    expect(readEntryMarkedRead(entry(3, 20)).updatedMs, 5);
  });
}
