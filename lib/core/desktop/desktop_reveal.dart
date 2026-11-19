import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Test hook: replaces the Explorer launch so widget tests can assert which
/// path a "Show in folder" / "Open folder" action targets.
@visibleForTesting
Future<void> Function(String path, {required bool select})? debugRevealOverride;

/// Opens Windows File Explorer at [path]. A file is shown selected inside its
/// folder (`explorer /select,`); a folder is opened directly. Returns false
/// when the target no longer exists, so callers can say so instead of letting
/// Explorer silently fall back to the user's Documents folder.
Future<bool> revealInExplorer(String path) async {
  final file = File(path);
  final isFile = await file.exists();
  if (!isFile && !await Directory(path).exists()) return false;
  // Explorer only understands backslash paths.
  final native = p.windows.normalize(path);
  final override = debugRevealOverride;
  if (override != null) {
    await override(native, select: isFile);
    return true;
  }
  if (!Platform.isWindows) return false;
  // Explorer returns exit code 1 even on success, so the result is ignored.
  await Process.run(
    'explorer.exe',
    isFile ? ['/select,', native] : [native],
  );
  return true;
}
