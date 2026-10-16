import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/platform/trusted_certificates.dart';

/// Supplies a local test CA without modifying the production certificate bundle.
class _TestCertificates extends CachingAssetBundle {
  /// Loads only the expected trust asset, using a test-only CA as its contents.
  @override
  Future<ByteData> load(String key) async {
    expect(key, 'android/app/src/main/res/raw/trusted_roots.pem');
    final bytes = await File('test/fixtures/tls/root.pem').readAsBytes();
    return ByteData.sublistView(bytes);
  }
}

/// Exercises real TLS handshakes, including rejection paths, against localhost.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Flutter's fake HTTP client would return 400 without exercising TLS at all.
  HttpOverrides.global = null;

  test(
    'the packaged Mozilla bundle parses in an isolated security context',
    () async {
      await installSupplementalTrustRoots(
        context: SecurityContext(withTrustedRoots: false),
      );
    },
  );

  for (final fixture in ['server', 'untrusted', 'wrong_host']) {
    test('TLS $fixture preserves chain and hostname validation', () async {
      final serverContext = SecurityContext()
        ..useCertificateChain('test/fixtures/tls/$fixture.pem')
        ..usePrivateKey('test/fixtures/tls/$fixture.key');
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        serverContext,
      );
      server.listen(
        (request) async {
          request.response.write('verified');
          await request.response.close();
        },
        onError: (Object _) {
          /* Expected when a client rejects the test certificate. */
        },
      );
      addTearDown(() => server.close(force: true));

      final context = SecurityContext(withTrustedRoots: false);
      await installSupplementalTrustRoots(
        context: context,
        bundle: _TestCertificates(),
      );
      final client = HttpClient(context: context)
        ..connectionTimeout = const Duration(seconds: 5);
      addTearDown(() => client.close(force: true));
      final request = client.getUrl(
        Uri.parse('https://127.0.0.1:${server.port}/'),
      );
      if (fixture == 'server') {
        final response = await (await request).close();
        expect(response.statusCode, HttpStatus.ok);
        await response.drain<void>();
      } else {
        await expectLater(request, throwsA(isA<HandshakeException>()));
      }
    });
  }
}
