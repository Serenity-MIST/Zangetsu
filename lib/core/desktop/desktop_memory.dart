import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

/// How much memory the Windows PC has, read once at boot.
///
/// Several Windows-only settings (image cache size, how many pages stay
/// open, the CloudStream engine's heap, the player buffer) are chosen from
/// this so an 8 GB laptop is not pushed into paging. Off Windows nothing here
/// is read and every answer is "unknown", so phone and TV keep their values.
class DesktopMemory {
  DesktopMemory._();

  /// Installed memory in megabytes; 0 until [load] has finished, or when the
  /// number could not be read.
  static int systemMemoryMb = 0;

  /// Machines with this much memory or less get the lighter settings.
  static const lowMemoryLimitMb = 8192;

  /// True on a Windows PC with 8 GB of memory or less. False while the size is
  /// still unknown, so nothing becomes lighter by mistake.
  static bool get isLowMemory =>
      systemMemoryMb > 0 && systemMemoryMb <= lowMemoryLimitMb;

  /// Reads the installed memory on Windows. Safe to call more than once and
  /// never throws: a failure just leaves the size unknown.
  static Future<int> load() async {
    if (systemMemoryMb > 0 || kIsWeb || !Platform.isWindows) {
      return systemMemoryMb;
    }
    // Testing aid: ZANGETSU_SIMULATE_RAM_MB=8192 makes a bigger PC behave
    // like an 8 GB one, so the lighter settings can be checked for real.
    final simulated = int.tryParse(
      Platform.environment['ZANGETSU_SIMULATE_RAM_MB'] ?? '',
    );
    if (simulated != null && simulated > 0) {
      return systemMemoryMb = simulated;
    }
    try {
      final info = await DeviceInfoPlugin().windowsInfo;
      systemMemoryMb = info.systemMemoryInMegabytes;
    } catch (_) {
      // Unknown size: callers keep their normal settings.
    }
    return systemMemoryMb;
  }
}
