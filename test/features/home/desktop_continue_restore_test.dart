import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/playback/watch_history.dart';
import 'package:watch_app/core/privacy/incognito_mode.dart';
import 'package:watch_app/core/supabase/supabase_service.dart';

// Logged out (null user id), so nothing here touches the network.
WatchHistory _store() => WatchHistory(SupabaseService(), () => null);

/// home-8 / track-9: the Undo of a removed history row goes through
/// WatchHistory.restore, which must bring back the exact entry, even while
/// incognito is on (save() records nothing in incognito).
void main() {
  late Directory dir;
  setUp(() async {
    dir = Directory.systemTemp.createTempSync('wh_restore_test');
    Hive.init(dir.path);
    await Hive.deleteBoxFromDisk(WatchHistory.boxName);
    await WatchHistory.init();
  });
  tearDown(() async {
    IncognitoMode.notifier.value = false;
    await Hive.box<Map>(WatchHistory.boxName).clear();
    await Hive.close();
    dir.deleteSync(recursive: true);
  });

  final entry = HistoryEntry(
    sourceId: 'allanime',
    showId: 'a',
    showTitle: 'Show a',
    showUrl: 'a',
    category: 'sub',
    episodeId: 'sub:5',
    episodeNumber: 5,
    episodeUrl: 'allanime://a/sub/5',
    position: const Duration(minutes: 7),
    duration: const Duration(minutes: 24),
    updatedAt: 1234,
  );

  test('restore brings back the removed entry unchanged', () async {
    final wh = _store();
    await wh.save(entry);
    await wh.remove(entry.sourceId, entry.showId);
    expect(wh.recent(), isEmpty);

    await wh.restore(entry);
    final back = wh.recent().single;
    expect(back.episodeId, 'sub:5');
    expect(back.position, const Duration(minutes: 7));
    expect(back.updatedAt, 1234);
  });

  test('restore also works in incognito, unlike save', () async {
    final wh = _store();
    await wh.save(entry);
    await wh.remove(entry.sourceId, entry.showId);

    IncognitoMode.notifier.value = true;
    await wh.save(entry);
    expect(wh.recent(), isEmpty, reason: 'save records nothing in incognito');
    await wh.restore(entry);
    expect(wh.recent().single.showId, 'a');
  });
}
