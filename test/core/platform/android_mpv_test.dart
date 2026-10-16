import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/platform/android_mpv.dart';

/// Verifies that Android's extracted ABI path reaches MediaKit unchanged.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.spyou.watch_app/device');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'uses the Android installation path instead of a library basename',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'mpvLibraryPath');
        return '/data/app/installed/lib/arm/libmpv.so';
      });
      expect(
        await resolveAndroidMpvLibrary(),
        '/data/app/installed/lib/arm/libmpv.so',
      );
    },
  );

  test(
    'retains Android loader diagnostics for missing ABI libraries',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(
          code: 'native_library_missing',
          message: 'ABIs=armeabi-v7a',
        );
      });
      await expectLater(
        resolveAndroidMpvLibrary(),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.message,
            'ABI diagnostic',
            contains('armeabi-v7a'),
          ),
        ),
      );
    },
  );

  test('rejects missing or basename-only platform replies', () async {
    for (final path in <String?>[
      null,
      '',
      'libmpv.so',
      '/data/app/lib/other.so',
    ]) {
      messenger.setMockMethodCallHandler(channel, (_) async => path);
      await expectLater(resolveAndroidMpvLibrary(), throwsStateError);
    }
  });
}
