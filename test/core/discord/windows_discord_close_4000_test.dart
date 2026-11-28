import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/discord/discord_gateway.dart';

/// A local stand-in for Discord's gateway: sends HELLO on connect and, once
/// the client IDENTIFYs, closes the socket with [code]. With [sendReady] it
/// first answers READY, so the "accepted, then closed at once" loop is
/// covered too. [connections] counts every socket the client opened.
class _FakeGateway {
  _FakeGateway(this.code, {this.sendReady = false});

  final int code;
  final bool sendReady;
  int connections = 0;
  late final HttpServer _server;

  String get url => 'ws://127.0.0.1:${_server.port}/';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      connections++;
      socket.add(
        jsonEncode({
          'op': 10,
          'd': {'heartbeat_interval': 41250},
        }),
      );
      socket.listen((raw) {
        final msg = jsonDecode(raw as String) as Map<String, dynamic>;
        if (msg['op'] != 2) return;
        if (sendReady) {
          socket.add(
            jsonEncode({
              'op': 0,
              's': 1,
              't': 'READY',
              'd': {
                'user': {'username': 'tester'},
              },
            }),
          );
        }
        socket.close(code, 'Unknown error');
      });
    });
  }

  Future<void> stop() => _server.close(force: true);
}

/// Waits (real time) until [done] is true or [limit] passes.
Future<void> _waitFor(bool Function() done, Duration limit) async {
  final end = DateTime.now().add(limit);
  while (!done() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// Tiny waits so six tries take well under a second in the test.
DiscordReconnectPolicy _fastPolicy() => DiscordReconnectPolicy(
  base: const Duration(milliseconds: 5),
  max: const Duration(milliseconds: 20),
);

void main() {
  // The tester's older build logged "socket closed code=4000 ready=false"
  // and "reconnect in 5s" forever. On Windows the gateway must stop after
  // six identical closes and open no further sockets.
  test('Windows: close 4000 before READY stops after six tries', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final server = _FakeGateway(4000);
    await server.start();
    final gateway = DiscordGateway(
      'Bearer x',
      gatewayUrl: server.url,
      policy: _fastPolicy(),
    );
    try {
      gateway.connect();
      await _waitFor(() => gateway.gaveUp, const Duration(seconds: 10));
      expect(gateway.gaveUp, isTrue);
      // Give it time to (wrongly) try again; nothing more may connect.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(server.connections, 6);
    } finally {
      await gateway.close();
      await server.stop();
      debugDefaultTargetPlatformOverride = null;
    }
  });

  // READY resets the failure count, so a session Discord accepts and then
  // closes with 4000 straight away used to loop every 5 s. Quick drops now
  // count towards the same stop.
  test('Windows: READY then close 4000 at once also stops after six', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final server = _FakeGateway(4000, sendReady: true);
    await server.start();
    final gateway = DiscordGateway(
      'Bearer x',
      gatewayUrl: server.url,
      policy: _fastPolicy(),
    );
    try {
      gateway.connect();
      await _waitFor(() => gateway.gaveUp, const Duration(seconds: 10));
      expect(gateway.gaveUp, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(server.connections, 6);
    } finally {
      await gateway.close();
      await server.stop();
      debugDefaultTargetPlatformOverride = null;
    }
  });

  // Phone keeps its old fixed 5 s retry: no back-off and no stop.
  test('Android: close 4000 keeps the fixed 5 s retry', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final server = _FakeGateway(4000);
    await server.start();
    final gateway = DiscordGateway(
      'Bearer x',
      gatewayUrl: server.url,
      policy: _fastPolicy(),
    );
    try {
      gateway.connect();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      // The fast test policy is ignored off Windows: still one socket,
      // waiting out the 5 s retry, and never given up.
      expect(server.connections, 1);
      expect(gateway.gaveUp, isFalse);
    } finally {
      await gateway.close();
      await server.stop();
      debugDefaultTargetPlatformOverride = null;
    }
  });

  group('DiscordReconnectPolicy.onDropAfterReady', () {
    test('six quick drops with the same code stop retrying', () {
      final policy = DiscordReconnectPolicy();
      for (var i = 0; i < 5; i++) {
        expect(policy.onDropAfterReady(4000, Duration.zero), isNotNull);
      }
      expect(policy.gaveUp, isFalse);
      expect(policy.onDropAfterReady(4000, Duration.zero), isNull);
      expect(policy.gaveUp, isTrue);
    });

    test('a session that stayed up starts a fresh count', () {
      final policy = DiscordReconnectPolicy();
      for (var i = 0; i < 5; i++) {
        policy.onDropAfterReady(4000, Duration.zero);
      }
      // Healthy for longer than stableAfter: the quick-drop count resets.
      expect(
        policy.onDropAfterReady(4000, const Duration(minutes: 5)),
        const Duration(seconds: 5),
      );
      expect(policy.quickDrops, 0);
      expect(policy.onDropAfterReady(4000, Duration.zero), isNotNull);
      expect(policy.gaveUp, isFalse);
    });

    test('a normal drop after a long session waits 5 s like before', () {
      final policy = DiscordReconnectPolicy();
      expect(
        policy.onDropAfterReady(1001, const Duration(minutes: 10)),
        const Duration(seconds: 5),
      );
      expect(policy.gaveUp, isFalse);
    });

    test('a quick drop without a close code never counts', () {
      final policy = DiscordReconnectPolicy();
      for (var i = 0; i < 10; i++) {
        expect(policy.onDropAfterReady(null, Duration.zero), isNotNull);
      }
    });
  });

  // The give-up log line reports sameCodeCount, so with mixed codes it must
  // count only the identical closes that caused the stop.
  test('sameCodeCount counts only the identical closes in a row', () {
    final policy = DiscordReconnectPolicy();
    expect(policy.onFailure(1006), isNotNull);
    for (var i = 0; i < 5; i++) {
      expect(policy.onFailure(4000), isNotNull);
    }
    expect(policy.onFailure(4000), isNull);
    expect(policy.failures, 7);
    expect(policy.sameCodeCount, 6);
  });
}
