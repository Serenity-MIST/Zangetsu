import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/cloudstream_runtime.dart';
import 'package:watch_app/core/desktop/desktop_image_cache.dart';
import 'package:watch_app/core/desktop/desktop_memory.dart';

void main() {
  tearDown(() => DesktopMemory.systemMemoryMb = 0);

  test('low-memory flag needs a known size of 8 GB or less', () {
    DesktopMemory.systemMemoryMb = 0;
    expect(DesktopMemory.isLowMemory, isFalse);
    DesktopMemory.systemMemoryMb = 8192;
    expect(DesktopMemory.isLowMemory, isTrue);
    DesktopMemory.systemMemoryMb = 16384;
    expect(DesktopMemory.isLowMemory, isFalse);
  });

  test('CloudStream engine heap is capped only on low-memory PCs', () {
    final small = cloudStreamJvmArgs(8192);
    expect(small, contains('-Xmx512m'));
    expect(small, contains('-XX:+UseSerialGC'));
    expect(small, contains('-XX:MaxHeapFreeRatio=30'));
    // Larger PCs and an unknown size keep room for big plugin sets.
    for (final mb in [0, 12288, 16384, 65536]) {
      final args = cloudStreamJvmArgs(mb);
      expect(args, contains('-Xmx1024m'), reason: '$mb MB');
      expect(args, isNot(contains('-Xmx512m')), reason: '$mb MB');
    }
  });

  test('a CloudStream engine that runs out of heap exits so it restarts', () {
    for (final mb in [0, 8192, 32768]) {
      expect(
        cloudStreamJvmArgs(mb),
        contains('-XX:+ExitOnOutOfMemoryError'),
        reason: '$mb MB',
      );
    }
  });

  test('the Home banner decode cap is lower on low-memory Windows PCs', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    DesktopMemory.systemMemoryMb = 8192;
    expect(desktopBannerDecodeWidth(), 2560);
    DesktopMemory.systemMemoryMb = 0;
    expect(desktopBannerDecodeWidth(), 2560);
    DesktopMemory.systemMemoryMb = 32768;
    expect(desktopBannerDecodeWidth(), 3840);
    // Other platforms never change.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    DesktopMemory.systemMemoryMb = 8192;
    expect(desktopBannerDecodeWidth(), 3840);
  });
}
