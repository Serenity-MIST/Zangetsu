import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestClient;
import 'package:watch_app/core/profiles/profile_lock_remote.dart';
import 'package:watch_app/core/profiles/synced_profile_lock_store.dart';

/// In-memory stand-in for the OS credential store (Windows: DPAPI file).
class _Storage extends FlutterSecureStorage {
  final values = <String, String>{};
  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => Map.of(values);
  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => values[key];
  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => values.remove(key);
}

/// Fake VPS. [failure] is what a dead network looks like to the store:
/// PostgrestProfileLockRemote maps DNS failures, refused connections and
/// timeouts to `online_required`.
class _Remote implements ProfileLockRemote {
  bool locked = false;
  int version = 1;
  Object? failure;
  @override
  Future<Map<String, dynamic>> request(
    String action, {
    String? profileId,
    String? pin,
    String? newPin,
    String? secret,
  }) async {
    final error = failure;
    if (error != null) throw error;
    if (action == 'status') {
      return {'ok': true, 'locked': locked, 'version': version};
    }
    if (action == 'unlock' && pin != '1234') {
      throw const ProfileLockException('verification_failed');
    }
    if (action == 'set') {
      locked = true;
      version++;
    }
    return {
      'ok': true,
      'locked': locked,
      'version': version,
      'grant_token': 'a' * 64,
      'expires_at': DateTime.now()
          .toUtc()
          .add(const Duration(hours: 12))
          .toIso8601String(),
    };
  }
}

void main() {
  late _Remote remote;
  late _Storage storage;
  SyncedProfileLockStore create() => SyncedProfileLockStore(
    remote: remote,
    currentUserId: () => 'account-a',
    storage: storage,
    biometrics: LocalAuthentication(),
  );
  setUp(() {
    remote = _Remote();
    storage = _Storage();
  });

  test('setting the PIN on this PC caches it for offline unlock', () async {
    expect(await create().setPin('kid', '1234'), isTrue);
    remote.failure = const ProfileLockException('online_required');
    // A fresh store is a restart of the app with no network.
    final offline = create();
    expect(await offline.isLocked('kid'), isTrue);
    expect(await offline.verify('kid', '0000'), isFalse);
    expect(await offline.verify('kid', '1234'), isTrue);
    expect(offline.isUnlocked('kid'), isTrue);
    expect(offline.grantHeaders, isEmpty);
  });

  test('a PIN set on another device works offline once accepted here', () async {
    remote
      ..locked = true
      ..version = 3;
    expect(await create().verify('kid', '1234'), isTrue);
    remote.failure = const ProfileLockException('online_required');
    expect(await create().verify('kid', '1234'), isTrue);
  });

  test('any network exception falls back to offline verification', () async {
    await create().setPin('kid', '1234');
    remote.failure = const SocketException('Failed host lookup');
    expect(await create().verify('kid', '1234'), isTrue);
    remote.failure = Exception('timeout');
    expect(await create().verify('kid', '1234'), isTrue);
  });

  test('a device that never accepted the PIN cannot verify offline', () async {
    remote.locked = true;
    // Saw the lock online, but never unlocked it here.
    expect(await create().isLocked('kid'), isTrue);
    remote.failure = const ProfileLockException('online_required');
    await expectLater(
      create().verify('kid', '1234'),
      throwsA(
        isA<ProfileLockException>().having(
          (e) => e.code,
          'code',
          'offline_pin_unavailable',
        ),
      ),
    );
  });

  test('a refused connection maps to online_required', () async {
    // Bind and close a port so nothing listens there.
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    final client = PostgrestClient('http://127.0.0.1:$port');
    final real = PostgrestProfileLockRemote(client, () => 'token');
    await expectLater(
      real.request('status', profileId: 'kid'),
      throwsA(
        isA<ProfileLockException>().having(
          (e) => e.code,
          'code',
          'online_required',
        ),
      ),
    );
    await client.dispose();
  });

  test('cached lock state is read without the network', () async {
    final locks = create();
    expect(await locks.cachedLocked('kid'), isNull);
    var changes = 0;
    locks.statusChanges.addListener(() => changes++);
    await locks.setPin('kid', '1234');
    expect(await locks.cachedLocked('kid'), isTrue);
    expect(changes, greaterThan(0));
  });
}
