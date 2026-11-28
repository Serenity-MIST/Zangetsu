import 'dart:io';

import 'package:flutter/foundation.dart';

import '../desktop/desktop_recycle_bin.dart';

/// Whether a user's "Delete" of a saved episode or chapter should go to the
/// Windows Recycle Bin (dl-2) instead of being removed for good.
///
/// Gated on the Windows desktop UI so phone keeps permanent deletes, and on
/// a real Windows host. Under `flutter test` it stays off unless a test opts
/// in with [debugAllowRecycleInTests] (and fakes the shell with
/// `debugRecycleOverride`), so tests on a Windows machine never put temp
/// files in the user's Recycle Bin.
bool get recycleDownloadDeletes =>
    defaultTargetPlatform == TargetPlatform.windows &&
    Platform.isWindows &&
    (debugAllowRecycleInTests || !_runningUnderFlutterTest);

/// Lets a test exercise the Recycle Bin path (with a faked shell call).
@visibleForTesting
bool debugAllowRecycleInTests = false;

/// `flutter test` sets FLUTTER_TEST in the test process environment.
final bool _runningUnderFlutterTest = Platform.environment.containsKey(
  'FLUTTER_TEST',
);

/// Deletes one saved download file: Recycle Bin on Windows desktop (falling
/// back to a permanent delete when the shell refuses), plain delete elsewhere.
Future<void> deleteDownloadedFile(File file) async {
  if (recycleDownloadDeletes) {
    await deleteToRecycleBinOrPermanently(file);
    return;
  }
  if (await file.exists()) await file.delete();
}

/// Same as [deleteDownloadedFile] for a whole folder (a novel chapter's own
/// folder with its pictures).
Future<void> deleteDownloadedFolder(Directory dir) async {
  if (recycleDownloadDeletes) {
    await deleteToRecycleBinOrPermanently(dir);
    return;
  }
  if (await dir.exists()) await dir.delete(recursive: true);
}
