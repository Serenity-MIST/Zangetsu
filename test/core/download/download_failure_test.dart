import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/download_failure.dart';

void main() {
  test('typed and legacy HTTP429 are classified without displaying HTML', () {
    expect(isDownloadRateLimit('busy', statusCode: 429), isTrue);
    const html = '<html><head><title>429 Too Many Requests</title></head>';
    expect(isDownloadRateLimit(html), isTrue);
    expect(downloadFailureMessage(html), contains('(429)'));
    expect(downloadFailureMessage(html), isNot(contains('<')));
  });
  test('ordinary HTML error pages and empty failures are readable', () {
    expect(downloadFailureMessage('<html>private response</html>', statusCode: 503),
        'Source returned an error (HTTP 503). Try again later.');
    expect(downloadFailureMessage(null, fallback: 'Failed'), 'Failed');
    expect(isDownloadRateLimit('Downloaded episode 429'), isFalse);
  });
  test('plain audio diagnostics survive and rows stay bounded', () {
    expect(downloadFailureMessage('English audio unavailable'), 'English audio unavailable');
    expect(downloadFailureMessage(List.filled(500, 'x').join()).length, 240);
  });
}
