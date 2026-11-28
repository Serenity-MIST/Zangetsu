import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/player/playback_failover.dart';

void main() {
  const saved = [(label: 'English', lang: 'English')];

  group('isSavedSubCopy', () {
    test('the player\'s own copy of a saved subtitle is recognised', () {
      expect(
        isSavedSubCopy(title: 'English', language: 'English', saved: saved),
        isTrue,
      );
    });

    test('a genuine embedded track keeps its own language code and stays', () {
      expect(
        isSavedSubCopy(title: 'English', language: 'eng', saved: saved),
        isFalse,
      );
      expect(
        isSavedSubCopy(title: 'Signs & Songs', language: 'English', saved: saved),
        isFalse,
      );
    });

    test('needs both a title and a language', () {
      expect(isSavedSubCopy(title: null, language: 'English', saved: saved), isFalse);
      expect(isSavedSubCopy(title: 'English', language: '', saved: saved), isFalse);
    });

    test('nothing saved means nothing is a copy', () {
      expect(
        isSavedSubCopy(title: 'English', language: 'English', saved: const []),
        isFalse,
      );
    });

    test('ignores surrounding whitespace', () {
      expect(
        isSavedSubCopy(title: ' English ', language: 'English ', saved: saved),
        isTrue,
      );
    });
  });
}
