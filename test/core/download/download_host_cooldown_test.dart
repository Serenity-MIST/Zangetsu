import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/download_host_cooldown.dart';
void main() {
  test('Retry-After accepts seconds and HTTP dates', () {
    final now = DateTime.utc(2026);
    final later = now.add(const Duration(seconds: 120));
    expect(downloadRetryDeadline('120', now), later);
    expect(downloadRetryDeadline(HttpDate.format(later), now), later);
    expect(downloadRetryDeadline('0', now), now);
    expect(downloadRetryDeadline(HttpDate.format(now.subtract(const Duration(days: 1))), now), now);
  });
  test('invalid hints use fallback and huge delays cannot overflow', () {
    final now = DateTime.utc(2026);
    for (final hint in [null, '', '-1', 'invalid']) {
      expect(downloadRetryDeadline(hint, now), now.add(const Duration(minutes: 1)));
    }
    expect(downloadRetryDeadline('999999999999999999999', now).isAfter(now), isTrue);
  });
}
