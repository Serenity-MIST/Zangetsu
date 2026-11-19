// "Mark as unwatched" kept the tick: unmarking deleted the local row, so the
// row fell back to the tracker's high-water mark and stayed watched. On
// Windows the store now keeps an explicit unwatched override instead; phone
// keeps the old delete behaviour.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/playback/resume_store.dart';

void main() {
  late Directory dir;
  late ResumeStore store;

  const src = 'src', show = 'show', ep = 'ep-3';

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('resume_store');
    Hive.init(dir.path);
    await ResumeStore.init();
    store = ResumeStore();
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await Hive.close();
    await dir.delete(recursive: true);
  });

  group('Windows unwatched override', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.windows);

    test('unmarking keeps an override row that is not finished', () async {
      await store.setWatched(src, show, ep, watched: true);
      expect(store.get(src, show, ep)!.finished, isTrue);

      await store.setWatched(src, show, ep, watched: false);
      final mark = store.get(src, show, ep)!;
      expect(mark.markedUnwatched, isTrue);
      expect(mark.finished, isFalse);
      expect(mark.isUnwatchedOverride, isTrue);
      // No stale progress bar: zero position and duration.
      expect(mark.position, Duration.zero);
      expect(mark.duration, Duration.zero);
    });

    test('unmarking a half-watched episode drops its position', () async {
      await store.save(
        src,
        show,
        ep,
        const Duration(minutes: 5),
        const Duration(minutes: 24),
      );
      await store.setWatched(src, show, ep, watched: false);
      expect(store.get(src, show, ep)!.position, Duration.zero);
    });

    test('marking watched again clears the override', () async {
      await store.setWatched(src, show, ep, watched: false);
      await store.setWatched(src, show, ep, watched: true);
      final mark = store.get(src, show, ep)!;
      expect(mark.markedUnwatched, isFalse);
      expect(mark.finished, isTrue);
    });

    test('a partial replay keeps the override but is real progress', () async {
      await store.setWatched(src, show, ep, watched: false);
      await store.save(
        src,
        show,
        ep,
        const Duration(minutes: 5),
        const Duration(minutes: 24),
      );
      final mark = store.get(src, show, ep)!;
      expect(mark.markedUnwatched, isTrue);
      expect(mark.finished, isFalse);
      // Has a position now, so Continue may target it.
      expect(mark.isUnwatchedOverride, isFalse);
    });

    test('playing to the end clears the override', () async {
      await store.setWatched(src, show, ep, watched: false);
      await store.save(
        src,
        show,
        ep,
        const Duration(minutes: 23),
        const Duration(minutes: 24),
      );
      final mark = store.get(src, show, ep)!;
      expect(mark.markedUnwatched, isFalse);
      expect(mark.finished, isTrue);
    });
  });

  test('phone still deletes the row when unmarking', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await store.setWatched(src, show, ep, watched: true);
    await store.setWatched(src, show, ep, watched: false);
    expect(store.get(src, show, ep), isNull);
  });
}
