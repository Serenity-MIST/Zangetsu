import 'package:flutter/services.dart';

/// Resolves libmpv from Android's installed, ABI-specific native directory.
///
/// Loading by basename can fail on older TVs even when the APK contains the
/// library. The platform supplies its extracted path; loader errors then retain
/// the actual missing dependency rather than reporting that libmpv is absent.
Future<String> resolveAndroidMpvLibrary() async {
  const device = MethodChannel('com.spyou.watch_app/device');
  final path = await device.invokeMethod<String>('mpvLibraryPath');
  if (path == null || !path.startsWith('/') || !path.endsWith('/libmpv.so')) {
    throw StateError('Android returned an invalid libmpv library path: $path');
  }
  return path;
}
