import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/ui/detail_prefs.dart';

void main() {
  group('reverse episode list default', () {
    test('defaults to off', () {
      expect(DetailPrefs.reverseEpisodesDefault, isFalse);
    });
  });
}
