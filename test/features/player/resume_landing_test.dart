import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/player/playback_failover.dart';

void main() {
  bool landed(int positionS, int targetS) => resumeSeekLanded(
    position: Duration(seconds: positionS),
    target: Duration(seconds: targetS),
  );

  group('resumeSeekLanded', () {
    test('an exact landing counts', () {
      expect(landed(70, 70), isTrue);
    });

    test('landing on the keyframe a few seconds before the mark counts', () {
      // The looping bug: a .ts seek lands 4s early, and demanding an exact
      // landing made the player seek again forever.
      expect(landed(66, 70), isTrue);
      expect(landed(60, 70), isTrue);
    });

    test('a position past the target counts', () {
      expect(landed(95, 70), isTrue);
    });

    test('being far short of the mark does not count, so a failed seek is retried', () {
      expect(landed(0, 70), isFalse);
      expect(landed(30, 70), isFalse);
      // Just beyond the allowed slack.
      expect(landed(57, 70), isFalse);
    });

    test('the slack boundary is exactly twelve seconds', () {
      expect(kResumeLandingSlack, const Duration(seconds: 12));
      expect(landed(58, 70), isTrue);
      expect(landed(57, 70), isFalse);
    });

    test('a very early mark still gets a real seek instead of being ignored', () {
      // Half the target is the cap, so 8s resumes still verify.
      expect(landed(0, 8), isFalse);
      expect(landed(4, 8), isTrue);
      expect(landed(0, 2), isFalse);
    });

    test('no resume target (zero) never forces a seek', () {
      expect(landed(0, 0), isTrue);
    });
  });
}
