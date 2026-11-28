import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/discord/discord_gateway.dart';

/// A local stand-in for Discord's gateway. [onConnect] plays the server side
/// of every socket the client opens.
class _FakeGateway {
  _FakeGateway(this.onConnect);

  final void Function(WebSocket socket, int connection) onConnect;
  int connections = 0;

  /// Login strings seen in IDENTIFY, in order.
  final logins = <String>[];
  late final HttpServer _server;

  String get url => 'ws://127.0.0.1:${_server.port}/';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      onConnect(socket, ++connections);
    });
  }

  /// Sends HELLO and answers IDENTIFY with [reply].
  void hello(WebSocket socket, void Function() reply) {
    socket.add(
      jsonEncode({
        'op': 10,
        'd': {'heartbeat_interval': 41250},
      }),
    );
    socket.listen((raw) {
      final msg = jsonDecode(raw as String) as Map<String, dynamic>;
      if (msg['op'] != 2) return;
      logins.add((msg['d'] as Map)['token'] as String);
      reply();
    });
  }

  Future<void> stop() => _server.close(force: true);
}

Future<void> _waitFor(bool Function() done) async {
  final end = DateTime.now().add(const Duration(seconds: 10));
  while (!done() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> _wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

DiscordReconnectPolicy _fastPolicy() => DiscordReconnectPolicy(
  base: const Duration(milliseconds: 5),
  max: const Duration(milliseconds: 20),
);

/// Windows faults of the raw gateway testers ran into: a rejected login was
/// retried without a refresh, a silent socket hung for ever, and a weak
/// network ended the retries.
void main() {
  late _FakeGateway server;
  DiscordGateway? gateway;
  late DebugPrintCallback originalPrint;
  final logs = <String>[];

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    logs.clear();
    originalPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');
  });

  tearDown(() async {
    await gateway?.close();
    gateway = null;
    await server.stop();
    debugPrint = originalPrint;
    debugDefaultTargetPlatformOverride = null;
  });

  test('close 4004 asks for a refresh and uses the new login', () async {
    server = _FakeGateway((socket, n) {
      server.hello(socket, () {
        if (n == 1) socket.close(4004, 'Authentication failed.');
      });
    });
    await server.start();
    var asked = 0;
    gateway = DiscordGateway(
      'Bearer one',
      gatewayUrl: server.url,
      policy: _fastPolicy(),
      onAuthFailure: () async {
        asked++;
        gateway!.updateToken('Bearer two');
      },
    )..connect();
    await _waitFor(() => server.logins.length == 2);
    await _wait(100);
    expect(asked, 1);
    expect(server.logins, ['Bearer one', 'Bearer two']);
  });

  test('close 4004 with no new login retries with waits, then stops', () async {
    server = _FakeGateway((socket, n) {
      server.hello(socket, () => socket.close(4004, 'Authentication failed.'));
    });
    await server.start();
    var asked = 0;
    gateway = DiscordGateway(
      'Bearer one',
      gatewayUrl: server.url,
      policy: _fastPolicy(),
      onAuthFailure: () async => asked++,
    )..connect();
    await _waitFor(() => gateway!.gaveUp);
    await _wait(200);
    expect(asked, 6);
    expect(server.connections, 6);
  });

  test('close 4004 stops when the owner closes the gateway', () async {
    server = _FakeGateway((socket, n) {
      server.hello(socket, () => socket.close(4004, 'Authentication failed.'));
    });
    await server.start();
    gateway = DiscordGateway(
      'Bearer one',
      gatewayUrl: server.url,
      policy: _fastPolicy(),
      // Signing out clears first and closes a moment later.
      onAuthFailure: () async {
        unawaitedClose(gateway!);
      },
    )..connect();
    await _waitFor(() => server.logins.isNotEmpty);
    await _wait(600);
    expect(server.connections, 1);
  });

  test('no READY within the limit reconnects', () async {
    server = _FakeGateway((socket, n) {
      // First socket stays silent, the second never answers IDENTIFY.
      if (n == 1) return;
      server.hello(socket, () {});
    });
    await server.start();
    gateway = DiscordGateway(
      'Bearer one',
      gatewayUrl: server.url,
      policy: _fastPolicy(),
      readyTimeout: const Duration(milliseconds: 300),
    )..connect();
    await _waitFor(() => server.connections >= 3);
    expect(server.connections, greaterThanOrEqualTo(3));
    expect(gateway!.gaveUp, isFalse);
  });

  test('a ready socket is left alone by the limit', () async {
    server = _FakeGateway((socket, n) {
      server.hello(
        socket,
        () => socket.add(
          jsonEncode({
            'op': 0,
            's': 1,
            't': 'READY',
            'd': {
              'user': {'username': 'tester'},
            },
          }),
        ),
      );
    });
    await server.start();
    gateway = DiscordGateway(
      'Bearer one',
      gatewayUrl: server.url,
      policy: _fastPolicy(),
      readyTimeout: const Duration(seconds: 1),
    )..connect();
    await _wait(1600);
    expect(server.connections, 1);
  });

  test('op 9 waits between tries instead of spinning', () async {
    server = _FakeGateway((socket, n) {
      server.hello(socket, () => socket.add(jsonEncode({'op': 9, 'd': false})));
    });
    await server.start();
    var asked = 0;
    gateway = DiscordGateway(
      'Bearer one',
      gatewayUrl: server.url,
      policy: DiscordReconnectPolicy(base: const Duration(seconds: 30)),
      onAuthFailure: () async => asked++,
    )..connect();
    await _waitFor(() => asked == 1);
    await _wait(300);
    expect(server.connections, 1);
    expect(asked, 1);
    // The network or the person coming back does not have to wait.
    gateway!.retryNow();
    await _waitFor(() => server.connections == 2);
    expect(server.connections, 2);
  });

  /// Answers IDENTIFY with READY, then rejects the session at once.
  Future<void> readyThen(void Function(WebSocket socket) reject) async {
    server = _FakeGateway((socket, n) {
      server.hello(socket, () {
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
        Future<void>.delayed(
          const Duration(milliseconds: 5),
          () => reject(socket),
        );
      });
    });
    await server.start();
  }

  test('close 4004 right after READY stops too', () async {
    await readyThen((socket) => socket.close(4004, 'Authentication failed.'));
    var asked = 0;
    gateway = DiscordGateway(
      'Bearer one',
      gatewayUrl: server.url,
      policy: _fastPolicy(),
      onAuthFailure: () async => asked++,
    )..connect();
    await _waitFor(() => gateway!.gaveUp);
    await _wait(200);
    expect(gateway!.gaveUp, isTrue);
    expect(server.connections, 6);
    expect(asked, 6);
  });

  test('op 9 right after READY waits longer each time', () async {
    await readyThen((socket) => socket.add(jsonEncode({'op': 9, 'd': false})));
    gateway = DiscordGateway(
      'Bearer one',
      gatewayUrl: server.url,
      policy: DiscordReconnectPolicy(base: const Duration(milliseconds: 100)),
      onAuthFailure: () async {},
    )..connect();
    // Waits of 100, 200, 400, 800 ms; without growth it would be about 15.
    await _wait(1700);
    expect(server.connections, inInclusiveRange(3, 5));
  });

  test('retryNow leaves a running connection alone', () async {
    server = _FakeGateway((socket, n) => server.hello(socket, () {}));
    await server.start();
    gateway = DiscordGateway(
      'Bearer one',
      gatewayUrl: server.url,
      policy: _fastPolicy(),
    )..connect();
    await _waitFor(() => server.logins.isNotEmpty);
    gateway!.retryNow();
    await _wait(150);
    expect(server.connections, 1);
  });

  test('a new close code during a quiet series is logged once', () async {
    server = _FakeGateway((socket, n) {
      server.hello(socket, () => socket.close(n < 3 ? 4000 : 4008, ''));
    });
    await server.start();
    gateway = DiscordGateway(
      'Bearer one',
      gatewayUrl: server.url,
      policy: _fastPolicy(),
    )..connect();
    await _waitFor(() => server.connections >= 6);
    expect(
      logs.where((l) => l.contains('now fails with code=4008')),
      hasLength(1),
    );
  });

  group('network close codes', () {
    setUp(() async {
      server = _FakeGateway((socket, n) {});
      await server.start();
    });

    test('1006 never ends the retries', () {
      final policy = DiscordReconnectPolicy();
      for (var i = 0; i < 20; i++) {
        expect(policy.onFailure(1006), isNotNull);
      }
      expect(policy.gaveUp, isFalse);
    });

    test('nor do sessions it drops right after READY, but waits grow', () {
      final policy = DiscordReconnectPolicy();
      final waits = [
        for (var i = 0; i < 8; i++)
          policy.onDropAfterReady(1006, Duration.zero)!.inSeconds,
      ];
      expect(waits, [5, 10, 20, 40, 80, 160, 300, 300]);
      expect(policy.gaveUp, isFalse);
      // A session that lasted starts over.
      expect(
        policy.onDropAfterReady(1006, const Duration(minutes: 5)),
        const Duration(seconds: 5),
      );
    });
  });
}

void unawaitedClose(DiscordGateway gateway) {
  gateway.clearThenClose().ignore();
}
