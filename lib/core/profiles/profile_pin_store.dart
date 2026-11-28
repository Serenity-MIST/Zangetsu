import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/export.dart';

/// Where PIN records are kept. The app uses the OS credential store; tests use
/// an in-memory map. Records never leave this device.
abstract interface class PinSecretStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Windows Credential Locker / platform keystore through flutter_secure_storage.
class SecurePinStorage implements PinSecretStorage {
  SecurePinStorage([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

enum PinResult { ok, wrong, lockedOut }

/// Outcome of a PIN attempt. [attemptsLeft] is meaningful for [PinResult.wrong];
/// [retryAfter] for [PinResult.lockedOut].
class PinCheck {
  const PinCheck(this.result, {this.attemptsLeft = 0, this.retryAfter});
  final PinResult result;
  final int attemptsLeft;
  final Duration? retryAfter;
  bool get ok => result == PinResult.ok;
}

/// Device-only profile PINs from older Windows builds.
///
/// No longer an active lock: the synced account lock (SyncedProfileLockStore)
/// is the only profile lock on every platform. This store remains only so a
/// PIN set by an older build can be verified once and moved into the synced
/// lock (see profile_unlock.dart); offline, the old PIN keeps being honoured
/// until it can be moved.
///
/// Only a salted, slow hash (PBKDF2-HMAC-SHA256) is stored, never the PIN.
/// Five wrong attempts lock the profile for five minutes, and the counter is
/// persisted so quitting and reopening the app does not reset it. Verification
/// calls are serialised so rapid input cannot race the attempt counter.
class ProfilePinStore extends ChangeNotifier {
  ProfilePinStore({
    required PinSecretStorage storage,
    required String Function() owner,
    this.iterations = defaultIterations,
    DateTime Function()? now,
    @visibleForTesting
    Future<Uint8List> Function(String pin, Uint8List salt, int rounds)? derive,
  }) : _storage = storage,
       _owner = owner,
       _now = now ?? DateTime.now,
       _derive = derive ?? _pbkdf2;

  /// A PIN is exactly this many digits, so the dialog can submit on the last one.
  static const pinLength = 4;
  static const maxAttempts = 5;
  static const lockoutDuration = Duration(minutes: 5);

  /// PBKDF2 rounds for newly saved PINs; each record stores its own count, so
  /// earlier PINs keep verifying. A 4-digit PIN has only 10,000 possibilities,
  /// so extra rounds buy little against someone who has copied the record. The
  /// real protections are the lockout and the OS-protected storage, and a PIN
  /// check must feel instant, so this is kept modest.
  static const defaultIterations = 20000;

  /// Work factor for new PINs. Lowered further only by tests.
  final int iterations;

  /// Parsed records by storage key, so a check does not re-read the credential
  /// store every time. Rebuilt by [load]; updated on every write.
  final Map<String, Map<String, dynamic>> _cache = {};
  final PinSecretStorage _storage;
  final String Function() _owner;
  final DateTime Function() _now;
  final Future<Uint8List> Function(String pin, Uint8List salt, int rounds)
  _derive;

  final Set<String> _locked = {};
  Future<void> _tail = Future<void>.value();

  static bool isValidPin(String pin) =>
      pin.length == pinLength && RegExp(r'^\d+$').hasMatch(pin);

  String _key(String profileId) =>
      'zangetsu.profile_pin.${_owner()}.$profileId';

  /// Whether [profileId] currently has a PIN.
  bool isLocked(String profileId) => _locked.contains(profileId);

  /// Reads the stored record instead of trusting [load], which may not have
  /// finished at launch. Used by the move to the synced account lock.
  Future<bool> hasPin(String profileId) async {
    if (isLocked(profileId)) return true;
    try {
      return await _serial(() async => await _readRecord(profileId) != null);
    } catch (_) {
      // Same rule as [load]: an unreadable keystore never locks anyone out.
      return false;
    }
  }

  /// Rebuilds the "has a PIN" set for the current account. Call on boot and
  /// whenever the active account or profile list changes.
  Future<void> load(Iterable<String> profileIds) async {
    final next = <String>{};
    _cache.clear();
    for (final id in profileIds) {
      try {
        // Reads and validates once here, so later checks are memory-only.
        if (await _readRecord(id) != null) next.add(id);
      } catch (_) {
        // An unreadable keystore must not lock people out of every profile.
      }
    }
    if (setEquals(next, _locked)) return;
    _locked
      ..clear()
      ..addAll(next);
    notifyListeners();
  }

  /// Sets or replaces the PIN. Callers verify the old PIN first when changing.
  Future<void> setPin(String profileId, String pin) {
    if (!isValidPin(pin)) {
      throw ArgumentError('A PIN is exactly $pinLength digits.');
    }
    return _serial(() async {
      final salt = _randomSalt();
      final hash = await _derive(pin, salt, iterations);
      await _writeRecord(profileId, {
        'v': 1,
        'salt': base64Encode(salt),
        'hash': base64Encode(hash),
        'iter': iterations,
        'attempts': 0,
        'retry_at': 0,
      });
      if (_locked.add(profileId)) notifyListeners();
    });
  }

  /// Checks [pin]. Honours and updates the persisted attempt counter.
  Future<PinCheck> verify(String profileId, String pin) =>
      _serial(() => _verify(profileId, pin));

  /// Removes the PIN after confirming [currentPin]. Returns the check result;
  /// the PIN is only removed on [PinResult.ok].
  Future<PinCheck> removePin(String profileId, String currentPin) =>
      _serial(() async {
        final check = await _verify(profileId, currentPin);
        if (check.ok) {
          _cache.remove(_key(profileId));
          await _storage.delete(_key(profileId));
          if (_locked.remove(profileId)) notifyListeners();
        }
        return check;
      });

  /// Drops a deleted profile's PIN so a later profile reusing the id is not
  /// locked by a stranger's PIN.
  Future<void> forget(String profileId) => _serial(() async {
    _cache.remove(_key(profileId));
    await _storage.delete(_key(profileId));
    if (_locked.remove(profileId)) notifyListeners();
  });

  Future<PinCheck> _verify(String profileId, String pin) async {
    final record = await _readRecord(profileId);
    if (record == null) return const PinCheck(PinResult.ok);
    final nowMs = _now().millisecondsSinceEpoch;
    final retryAt = record['retry_at'] as int;
    if (retryAt > nowMs) {
      return PinCheck(
        PinResult.lockedOut,
        retryAfter: Duration(milliseconds: retryAt - nowMs),
      );
    }
    final expected = base64Decode(record['hash'] as String);
    final actual = await _derive(
      pin,
      base64Decode(record['salt'] as String),
      record['iter'] as int,
    );
    // Compare every byte so timing does not reveal how many matched.
    var different = actual.length ^ expected.length;
    for (var i = 0; i < min(actual.length, expected.length); i++) {
      different |= actual[i] ^ expected[i];
    }
    if (different == 0) {
      // Only touch storage when there is something to reset. The common case,
      // a correct PIN with no earlier mistakes, writes nothing and returns fast.
      if ((record['attempts'] as int) != 0 || retryAt != 0) {
        await _writeRecord(profileId, {
          ...record,
          'attempts': 0,
          'retry_at': 0,
        });
      }
      return const PinCheck(PinResult.ok);
    }
    final attempts = (record['attempts'] as int) + 1;
    final lock = attempts >= maxAttempts;
    await _writeRecord(profileId, {
      ...record,
      // After a lockout the counter restarts, so the next window is a fresh five.
      'attempts': lock ? 0 : attempts,
      'retry_at': lock ? nowMs + lockoutDuration.inMilliseconds : 0,
    });
    return lock
        ? const PinCheck(PinResult.lockedOut, retryAfter: lockoutDuration)
        : PinCheck(PinResult.wrong, attemptsLeft: maxAttempts - attempts);
  }

  /// Returns a validated record, or null when none exists. A damaged record is
  /// deleted and treated as "no PIN": keeping it would lock the profile forever
  /// with no way to open the removal screen.
  Future<Map<String, dynamic>?> _readRecord(String profileId) async {
    final key = _key(profileId);
    final cached = _cache[key];
    if (cached != null) return cached;
    final raw = await _storage.read(key);
    if (raw == null) return null;
    try {
      final value = jsonDecode(raw);
      if (value is Map &&
          value['salt'] is String &&
          value['hash'] is String &&
          value['iter'] is int &&
          value['attempts'] is int &&
          value['retry_at'] is int &&
          base64Decode(value['salt'] as String).length == 16 &&
          base64Decode(value['hash'] as String).length == 32) {
        return _cache[key] = Map<String, dynamic>.from(value);
      }
    } on FormatException {
      // fall through to cleanup
    }
    await _storage.delete(key);
    if (_locked.remove(profileId)) notifyListeners();
    return null;
  }

  /// Updates memory first so the next check already sees the new counters, then
  /// persists. Callers await this, so a wrong guess is saved before it returns.
  Future<void> _writeRecord(String profileId, Map<String, dynamic> record) {
    final key = _key(profileId);
    _cache[key] = record;
    return _storage.write(key, jsonEncode(record));
  }

  Future<T> _serial<T>(Future<T> Function() job) {
    final result = _tail.then((_) => job());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  static Uint8List _randomSalt() {
    final random = Random.secure();
    return Uint8List.fromList(List.generate(16, (_) => random.nextInt(256)));
  }

  /// PBKDF2 off the UI isolate so the dialog stays responsive while it runs.
  static Future<Uint8List> _pbkdf2(String pin, Uint8List salt, int rounds) =>
      Isolate.run(() {
        final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
          ..init(Pbkdf2Parameters(salt, rounds, 32));
        return derivator.process(Uint8List.fromList(utf8.encode(pin)));
      });
}
