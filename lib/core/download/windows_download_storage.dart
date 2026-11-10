import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

/// Read-only capacity on the selected destination, including quota limits.
/// The Win32 call runs off the Flutter thread; unavailable drives remain null.
Future<int?> windowsDownloadFreeBytes(String? destination) async {
  if (!Platform.isWindows || destination == null || destination.isEmpty ||
      destination.contains(String.fromCharCode(0)) || !p.windows.isAbsolute(destination)) return null;
  try {
    return await Isolate.run(() => _readWindowsFreeBytes(destination))
        .timeout(const Duration(seconds: 3), onTimeout: () => null);
  } catch (_) { return null; }
}

/// Use the nearest existing directory without creating or moving user content.
int? _readWindowsFreeBytes(String path) {
  var directory = Directory(path);
  while (!directory.existsSync()) {
    final parent = directory.parent;
    if (parent.path == directory.path) return null;
    directory = parent;
  }
  final resolved = directory.resolveSymbolicLinksSync();
  final units = '${resolved.endsWith(r'\') ? resolved : '$resolved\\'}'.codeUnits;
  final ole = DynamicLibrary.open('ole32.dll');
  final allocate = ole.lookupFunction<Pointer<Void> Function(IntPtr),
      Pointer<Void> Function(int)>('CoTaskMemAlloc');
  final free = ole.lookupFunction<Void Function(Pointer<Void>),
      void Function(Pointer<Void>)>('CoTaskMemFree');
  final name = allocate((units.length + 1) * 2).cast<Uint16>();
  final available = allocate(sizeOf<Uint64>()).cast<Uint64>();
  try {
    if (name == nullptr || available == nullptr) return null;
    name.asTypedList(units.length + 1)..setAll(0, units)..[units.length] = 0;
    final query = DynamicLibrary.open('kernel32.dll').lookupFunction<
      Int32 Function(Pointer<Uint16>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>),
      int Function(Pointer<Uint16>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>)>(
        'GetDiskFreeSpaceExW');
    if (query(name, available, nullptr, nullptr) == 0) return null;
    final bytes = available.value;
    return bytes >= 0 ? bytes : null;
  } finally {
    if (name != nullptr) free(name.cast());
    if (available != nullptr) free(available.cast());
  }
}

/// Assumed bitrate and unknown capacity cannot justify a low-storage warning.
bool downloadEstimateExceedsSpace({required int? freeBytes,
    required int? estimatedBytes, required bool solid}) => solid &&
    freeBytes != null && freeBytes >= 0 && estimatedBytes != null &&
    estimatedBytes > 0 && estimatedBytes > freeBytes;
