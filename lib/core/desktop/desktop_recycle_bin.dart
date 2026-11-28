import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

/// Test hook: when set, [moveToRecycleBin] calls this instead of Windows.
@visibleForTesting
Future<bool> Function(String path)? debugRecycleOverride;

/// Moves a file or folder to the Windows Recycle Bin so the user can
/// restore it. Returns false when it could not (not Windows, missing path,
/// path too long, shell error); nothing is deleted in that case.
///
/// The shell call runs on a background isolate, like the free-space check in
/// windows_download_storage.dart, so a large folder never blocks the UI.
Future<bool> moveToRecycleBin(String path) async {
  final override = debugRecycleOverride;
  if (override != null) return override(path);
  if (!Platform.isWindows || path.isEmpty || path.contains('\u0000')) {
    return false;
  }
  // The Recycle Bin needs a full path with backslashes.
  final full = File(path).absolute.path.replaceAll('/', r'\');
  try {
    return await Isolate.run(() => _shellRecycle(full));
  } catch (_) {
    return false;
  }
}

/// Deletes [entity] the gentle way: Recycle Bin on Windows, falling back to
/// a permanent recursive delete when recycling fails or off Windows.
Future<void> deleteToRecycleBinOrPermanently(FileSystemEntity entity) async {
  if (!await entity.exists()) return;
  if (debugRecycleOverride != null || Platform.isWindows) {
    if (await moveToRecycleBin(entity.path)) return;
  }
  // Recycling failed or is unavailable; delete for good (it may have
  // vanished meanwhile, which is fine).
  if (await entity.exists()) await entity.delete(recursive: true);
}

/// SHFILEOPSTRUCTW with the natural (8-byte) packing used on 64-bit Windows.
final class _ShFileOpStructW extends Struct {
  external Pointer<Void> hwnd;
  @Uint32()
  external int wFunc;
  external Pointer<Uint16> pFrom;
  external Pointer<Uint16> pTo;
  @Uint16()
  external int fFlags;
  @Int32()
  external int fAnyOperationsAborted;
  external Pointer<Void> hNameMappings;
  external Pointer<Uint16> lpszProgressTitle;
}

/// FO_DELETE operation code.
const int _foDelete = 0x0003;

/// FOF_SILENT | FOF_NOCONFIRMATION | FOF_ALLOWUNDO | FOF_NOERRORUI:
/// recycle without any shell dialog.
const int _recycleFlags = 0x0004 | 0x0010 | 0x0040 | 0x0400;

/// Runs SHFileOperationW(FO_DELETE + FOF_ALLOWUNDO) on [path] (isolate side).
bool _shellRecycle(String path) {
  if (FileSystemEntity.typeSync(path, followLinks: false) ==
      FileSystemEntityType.notFound) {
    return false;
  }
  final ole = DynamicLibrary.open('ole32.dll');
  final allocate = ole
      .lookupFunction<
        Pointer<Void> Function(IntPtr),
        Pointer<Void> Function(int)
      >('CoTaskMemAlloc');
  final free = ole
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('CoTaskMemFree');
  final units = path.codeUnits;
  // pFrom is a list of NUL-terminated strings ending with an extra NUL.
  final from = allocate((units.length + 2) * 2).cast<Uint16>();
  final op = allocate(sizeOf<_ShFileOpStructW>()).cast<_ShFileOpStructW>();
  try {
    if (from == nullptr || op == nullptr) return false;
    from.asTypedList(units.length + 2)
      ..setAll(0, units)
      ..[units.length] = 0
      ..[units.length + 1] = 0;
    // CoTaskMemAlloc does not zero memory, so every field is set.
    op.ref
      ..hwnd = nullptr
      ..wFunc = _foDelete
      ..pFrom = from
      ..pTo = nullptr
      ..fFlags = _recycleFlags
      ..fAnyOperationsAborted = 0
      ..hNameMappings = nullptr
      ..lpszProgressTitle = nullptr;
    final shFileOperation = DynamicLibrary.open('shell32.dll')
        .lookupFunction<
          Int32 Function(Pointer<_ShFileOpStructW>),
          int Function(Pointer<_ShFileOpStructW>)
        >('SHFileOperationW');
    final result = shFileOperation(op);
    if (result != 0 || op.ref.fAnyOperationsAborted != 0) return false;
    // Trust but verify: the shell can report success for a skipped item.
    return FileSystemEntity.typeSync(path, followLinks: false) ==
        FileSystemEntityType.notFound;
  } finally {
    if (from != nullptr) free(from.cast());
    if (op != nullptr) free(op.cast());
  }
}
