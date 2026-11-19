import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/player/playback_failover.dart';

void main() {
  LocalFallbackAction decide({
    String mode = 'auto',
    bool alreadyLocal = false,
    bool alreadyTried = false,
    bool hasFinder = true,
  }) => localFallbackAction(
    mode: mode,
    alreadyLocal: alreadyLocal,
    alreadyTried: alreadyTried,
    hasFinder: hasFinder,
  );

  group('localFallbackAction', () {
    test('auto switches, ask asks, off does nothing', () {
      expect(decide(mode: 'auto'), LocalFallbackAction.switchNow);
      expect(decide(mode: 'ask'), LocalFallbackAction.ask);
      expect(decide(mode: 'off'), LocalFallbackAction.none);
    });

    test('an unknown saved value behaves like the default', () {
      expect(decide(mode: ''), LocalFallbackAction.switchNow);
      expect(decide(mode: 'something-new'), LocalFallbackAction.switchNow);
    });

    test('never applies when already playing a local file', () {
      // Otherwise a failing download could bounce back to the network.
      expect(decide(alreadyLocal: true), LocalFallbackAction.none);
      expect(decide(mode: 'ask', alreadyLocal: true), LocalFallbackAction.none);
    });

    test('is attempted only once per episode open', () {
      expect(decide(alreadyTried: true), LocalFallbackAction.none);
    });

    test('needs a way to look for the download', () {
      expect(decide(hasFinder: false), LocalFallbackAction.none);
    });
  });
}
