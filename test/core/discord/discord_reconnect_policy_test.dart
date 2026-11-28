import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/discord/discord_gateway.dart';

void main() {
  test('waits grow 5s, 10s, 20s ... and stop growing at 5 minutes', () {
    final policy = DiscordReconnectPolicy(giveUpAfter: 1000);
    final waits = [
      // Different codes so the series never gives up here.
      for (var i = 0; i < 9; i++) policy.onFailure(4000 + i)!.inSeconds,
    ];
    expect(waits, [5, 10, 20, 40, 80, 160, 300, 300, 300]);
  });

  test('the same close code six times in a row stops retrying', () {
    final policy = DiscordReconnectPolicy();
    for (var i = 0; i < 5; i++) {
      expect(policy.onFailure(4000), isNotNull);
    }
    expect(policy.gaveUp, isFalse);
    expect(policy.onFailure(4000), isNull);
    expect(policy.gaveUp, isTrue);
  });

  test('a different code in between restarts the identical-failure count', () {
    final policy = DiscordReconnectPolicy();
    for (var i = 0; i < 5; i++) {
      policy.onFailure(4000);
    }
    expect(policy.onFailure(1006), isNotNull);
    expect(policy.onFailure(4000), isNotNull);
    expect(policy.gaveUp, isFalse);
  });

  test('a socket closed without a code never counts as identical', () {
    final policy = DiscordReconnectPolicy();
    for (var i = 0; i < 10; i++) {
      expect(policy.onFailure(null), isNotNull);
    }
  });

  test('READY starts a fresh series', () {
    final policy = DiscordReconnectPolicy();
    policy.onFailure(4000);
    policy.onFailure(4000);
    policy.onReady();
    expect(policy.failures, 0);
    expect(policy.onFailure(4000), const Duration(seconds: 5));
  });

  testWidgets(
    'a fresh Windows gateway has not given up',
    (tester) async => expect(DiscordGateway('Bearer x').gaveUp, isFalse),
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
