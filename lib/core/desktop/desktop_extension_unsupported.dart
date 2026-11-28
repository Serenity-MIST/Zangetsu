import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Windows only: remembers extension sources that failed because they use an
/// Android feature the Windows extension engine does not have yet.
///
/// Why: the Windows engine ships Android's classes partly as empty stand-ins
/// ("stubs"). An extension that calls one of them (XAnime uses
/// `android.util.LruCache`) fails every call with the bare message `Stub!`.
/// The app used to swallow that and, at play time, tell the viewer
/// "<Source> did not match this title." — which sends them hunting for a
/// different title when the real cause is the engine. This registry lets the
/// player say what actually happened instead.
///
/// Kept in memory for the session only: a later engine update that adds the
/// missing class should be believed after a restart.
class DesktopExtensionUnsupported {
  DesktopExtensionUnsupported._();

  static final Set<String> _ids = {};
  static final Set<String> _names = {};

  /// True when [error] is the engine's "this Android class is only a stub"
  /// failure. The engine reports it as the exception message `Stub!`.
  static bool isStubError(Object? error) {
    final message = error is PlatformException
        ? '${error.message ?? ''} ${error.details ?? ''}'
        : '$error';
    return message.contains('Stub!');
  }

  /// Remember that the source [sourceId] (for example `ani:123`) named [name]
  /// hit a stub. Ignored on platforms other than Windows.
  static void record({required String sourceId, required String name}) {
    if (defaultTargetPlatform != TargetPlatform.windows) return;
    if (sourceId.isNotEmpty) _ids.add(sourceId);
    final n = name.trim().toLowerCase();
    if (n.isNotEmpty) _names.add(n);
  }

  /// Whether the source with this id was recorded.
  static bool hasSourceId(String sourceId) => _ids.contains(sourceId);

  /// Whether a source with this display name was recorded (case and outer
  /// spaces ignored, because the player only knows the display name).
  static bool hasName(String name) =>
      _names.contains(name.trim().toLowerCase());

  /// The player's dead-end wording for a recorded source.
  static String messageFor(String name) =>
      '$name uses an Android feature the Windows engine does not support yet.';

  /// The dead-end text for [name]: the "Android feature" wording when that
  /// source was recorded on Windows, otherwise [fallback] unchanged.
  static String deadEndText(String name, String fallback) {
    if (defaultTargetPlatform != TargetPlatform.windows) return fallback;
    return hasName(name) ? messageFor(name) : fallback;
  }

  /// Forget everything (tests only).
  @visibleForTesting
  static void reset() {
    _ids.clear();
    _names.clear();
  }
}
