// Plan item B2 (app side): an extension call that fails with "Stub!" marks
// its source as "uses an Android feature the Windows engine does not support
// yet", and the player's dead-end text uses that wording for it.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/desktop_extension_unsupported.dart';

void main() {
  tearDown(() {
    DesktopExtensionUnsupported.reset();
    debugDefaultTargetPlatformOverride = null;
  });

  test('recognises the engine "Stub!" failure', () {
    expect(
      DesktopExtensionUnsupported.isStubError(
        PlatformException(code: 'EXTENSION', message: 'Stub!'),
      ),
      isTrue,
    );
    expect(
      DesktopExtensionUnsupported.isStubError(
        PlatformException(
          code: 'EXTENSION',
          message: 'failed',
          details: 'java.lang.RuntimeException: Stub!',
        ),
      ),
      isTrue,
    );
    expect(
      DesktopExtensionUnsupported.isStubError(
        PlatformException(code: 'CLOUDFLARE', message: 'https://x'),
      ),
      isFalse,
    );
    expect(DesktopExtensionUnsupported.isStubError('timeout'), isFalse);
    expect(DesktopExtensionUnsupported.isStubError(null), isFalse);
  });

  test('Windows: a recorded source gets the Android-feature wording', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    DesktopExtensionUnsupported.record(sourceId: 'ani:42', name: 'XAnime');
    expect(DesktopExtensionUnsupported.hasSourceId('ani:42'), isTrue);
    expect(DesktopExtensionUnsupported.hasName(' xanime '), isTrue);
    expect(
      DesktopExtensionUnsupported.deadEndText(
        'XAnime',
        'XAnime did not match this title.',
      ),
      'XAnime uses an Android feature the Windows engine does not support yet.',
    );
    // Another source keeps the old wording.
    expect(
      DesktopExtensionUnsupported.deadEndText(
        'AniKoto',
        'AniKoto did not match this title.',
      ),
      'AniKoto did not match this title.',
    );
  });

  test('phone: nothing is recorded and the wording never changes', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    DesktopExtensionUnsupported.record(sourceId: 'ani:42', name: 'XAnime');
    expect(DesktopExtensionUnsupported.hasSourceId('ani:42'), isFalse);
    expect(
      DesktopExtensionUnsupported.deadEndText(
        'XAnime',
        'XAnime did not match this title.',
      ),
      'XAnime did not match this title.',
    );
  });
}
