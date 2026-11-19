import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/download_manager.dart';

void main() {
  // setParallel only mirrors the limit into the Android foreground download
  // service; Windows has none and uses its own desktop transfer slots.
  test('setParallel skips the background service on Windows hosts', () {
    expect(
      DownloadManager.forwardsParallelToBackgroundService,
      !Platform.isWindows,
    );
  });
}
