import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/extension_runtime.dart';

void main() {
  test('desktop replies preserve JSON strings and 64-bit source IDs', () {
    const payload = '[{"id":4697393375201558791}]';
    expect(
      DesktopExtensionRuntime.decodeResponse('listSources', {
        'result': payload,
      }),
      payload,
    );
  });
  test('image replies decode to channel bytes', () {
    expect(
      DesktopExtensionRuntime.decodeResponse('getImage', {
        'result': 'AAEC/w==',
      }),
      [0, 1, 2, 255],
    );
  });
  test('source failures retain Cloudflare code and URL for the caller', () {
    expect(
      () => DesktopExtensionRuntime.decodeResponse('getPopular', {
        'error': {
          'code': 'CLOUDFLARE',
          'message': 'Challenge',
          'details': 'https://example.org',
        },
      }),
      throwsA(
        isA<PlatformException>()
            .having((e) => e.code, 'code', 'CLOUDFLARE')
            .having((e) => e.details, 'details', 'https://example.org'),
      ),
    );
  });
}
