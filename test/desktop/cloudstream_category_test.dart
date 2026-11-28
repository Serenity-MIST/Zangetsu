import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';

/// Category navigation must carry source-owned names and URLs without loss.
void main() {
  test('names with spaces and opaque URLs round-trip together', () {
    const name = 'Top Sci-Fi Movies';
    const data = 'https://source.example/catalog?q=a b&genre=科幻';
    expect(decodeCloudStreamCategory(encodeCloudStreamCategory(name, data)),
        (name: name, data: data));
  });
  test('older links continue to decode without a migration', () {
    expect(decodeCloudStreamCategory('Trending /catalog/top'),
        (name: 'Trending', data: '/catalog/top'));
    expect(decodeCloudStreamCategory('Trending'),
        (name: 'Trending', data: ''));
  });
}
