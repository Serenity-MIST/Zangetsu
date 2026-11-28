import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/reading/reader_overrides.dart';

/// Windows per-series reader settings stored beside mode/fit: the long-strip
/// page width (reader-5) and the double-page spread shift (reader-8).
void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('reader_overrides_desktop');
    Hive.init(dir.path);
    await ReaderOverrideStore.init();
  });
  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('page width defaults, is clamped and clears back to default', () async {
    final store = ReaderOverrideStore();
    expect(store.pageWidthOverride('src', 'show'), isNull);
    expect(
      store.effectivePageWidth('src', 'show'),
      ReaderOverrideStore.defaultPageWidth,
    );

    await store.setPageWidthOverride('src', 'show', 1333.4);
    expect(store.effectivePageWidth('src', 'show'), 1333);

    await store.setPageWidthOverride('src', 'show', 99999);
    expect(
      store.effectivePageWidth('src', 'show'),
      ReaderOverrideStore.maxPageWidth,
    );
    await store.setPageWidthOverride('src', 'show', 10);
    expect(
      store.effectivePageWidth('src', 'show'),
      ReaderOverrideStore.minPageWidth,
    );

    await store.setPageWidthOverride('src', 'show', null);
    expect(store.pageWidthOverride('src', 'show'), isNull);
  });

  test('spread shift is per series and leaves no trace when off', () async {
    final store = ReaderOverrideStore();
    expect(store.shiftSpread('src', 'show'), isFalse);

    await store.setShiftSpread('src', 'show', true);
    expect(store.shiftSpread('src', 'show'), isTrue);
    expect(store.shiftSpread('src', 'other'), isFalse);

    await store.setShiftSpread('src', 'show', false);
    expect(store.shiftSpread('src', 'show'), isFalse);
    // Nothing else was set, so the series' entry is gone entirely.
    expect(Hive.box(ReaderOverrideStore.boxName).isEmpty, isTrue);
  });

  test(
    'new fields sit beside the mode override without clobbering it',
    () async {
      final store = ReaderOverrideStore();
      await store.setModeOverride('src', 'show', 'vertical');
      await store.setPageWidthOverride('src', 'show', 800);
      await store.setShiftSpread('src', 'show', true);

      expect(store.modeOverride('src', 'show'), 'vertical');
      expect(store.pageWidthOverride('src', 'show'), 800);
      expect(store.shiftSpread('src', 'show'), isTrue);
    },
  );
}
