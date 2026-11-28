// home-8: Undo of a removed reading entry uses ReadHistory.restore, which
// writes even while incognito (save() records nothing then).
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/privacy/incognito_mode.dart';
import 'package:watch_app/core/reading/read_history.dart';
import 'package:watch_app/core/supabase/supabase_service.dart';

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('read_history_restore');
    Hive.init(dir.path);
    await ReadHistory.init();
  });
  tearDown(() async {
    // Flip the in-memory flag back so other tests are not left incognito.
    IncognitoMode.notifier.value = false;
    await Hive.deleteFromDisk();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  ReadEntry entry(String show) => ReadEntry(
    sourceId: 'js:m',
    showId: show,
    title: show,
    cover: null,
    chapterId: 'ch1',
    chapterNumber: 1,
    chapterUrl: 'u',
    pos: 3,
    total: 20,
    updatedMs: 1,
    type: ProviderType.manga,
  );

  test('restore writes while incognito; save does not', () async {
    final h = ReadHistory(SupabaseService(), () => null);
    // Set only the in-memory flag: no prefs box needed for the guard.
    IncognitoMode.notifier.value = true;
    await h.save(entry('a'));
    expect(h.recent(), isEmpty);
    await h.restore(entry('a'));
    expect(h.recent(), hasLength(1));
    expect(h.recent().single.pos, 3);
  });
}
