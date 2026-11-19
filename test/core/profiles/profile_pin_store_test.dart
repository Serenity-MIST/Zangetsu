import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/profiles/profile_pin_store.dart';

class _MemoryStorage implements PinSecretStorage {
  final Map<String, String> data = {};
  int reads = 0, writes = 0;
  @override
  Future<String?> read(String key) async {
    reads++;
    return data[key];
  }

  @override
  Future<void> write(String key, String value) async {
    writes++;
    data[key] = value;
  }
  @override
  Future<void> delete(String key) async => data.remove(key);
}

void main() {
  late _MemoryStorage storage;
  late DateTime clock;
  var owner = 'local';

  ProfilePinStore build() => ProfilePinStore(
    storage: storage,
    owner: () => owner,
    // Small work factor keeps the suite fast; the algorithm is identical.
    iterations: 1000,
    now: () => clock,
  );

  setUp(() {
    storage = _MemoryStorage();
    clock = DateTime(2026, 11, 11, 12);
    owner = 'local';
  });

  test('a profile has no lock until a PIN is set', () async {
    final store = build();
    expect(store.isLocked('kid'), isFalse);
    // No PIN means nothing to check: opening must always succeed.
    expect((await store.verify('kid', '0000')).ok, isTrue);
  });

  test('accepts only four digits', () async {
    final store = build();
    for (final bad in ['', '123', '12345', 'abcd', '12 4', '１２３４']) {
      expect(() => store.setPin('kid', bad), throwsArgumentError, reason: bad);
    }
    expect(store.isLocked('kid'), isFalse);
  });

  test('stores a hash, never the PIN itself', () async {
    final store = build();
    await store.setPin('kid', '4821');
    expect(store.isLocked('kid'), isTrue);
    final raw = storage.data.values.single;
    expect(raw.contains('"pin"'), isFalse);
    expect(raw.contains('4821'), isFalse);
    expect(raw.contains('"hash"'), isTrue);
    expect(raw.contains('"salt"'), isTrue);
  });

  test('the right PIN opens, a wrong one counts down attempts', () async {
    final store = build();
    await store.setPin('kid', '4821');
    expect((await store.verify('kid', '4821')).ok, isTrue);
    final wrong = await store.verify('kid', '0000');
    expect(wrong.result, PinResult.wrong);
    expect(wrong.attemptsLeft, 4);
    expect((await store.verify('kid', '0000')).attemptsLeft, 3);
  });

  test('a correct PIN resets the wrong-attempt counter', () async {
    final store = build();
    await store.setPin('kid', '4821');
    await store.verify('kid', '0000');
    await store.verify('kid', '0000');
    expect((await store.verify('kid', '4821')).ok, isTrue);
    expect((await store.verify('kid', '0000')).attemptsLeft, 4);
  });

  test('five wrong attempts lock for five minutes, then it recovers', () async {
    final store = build();
    await store.setPin('kid', '4821');
    for (var i = 0; i < 4; i++) {
      await store.verify('kid', '0000');
    }
    final fifth = await store.verify('kid', '0000');
    expect(fifth.result, PinResult.lockedOut);
    expect(fifth.retryAfter, ProfilePinStore.lockoutDuration);

    // Even the correct PIN is refused while locked out.
    clock = clock.add(const Duration(minutes: 2));
    final during = await store.verify('kid', '4821');
    expect(during.result, PinResult.lockedOut);
    expect(during.retryAfter, const Duration(minutes: 3));

    clock = clock.add(const Duration(minutes: 3, seconds: 1));
    expect((await store.verify('kid', '4821')).ok, isTrue);
  });

  test('the lockout survives restarting the app', () async {
    final first = build();
    await first.setPin('kid', '4821');
    for (var i = 0; i < 5; i++) {
      await first.verify('kid', '0000');
    }
    final restarted = build();
    expect(
      (await restarted.verify('kid', '4821')).result,
      PinResult.lockedOut,
    );
  });

  test('rapid parallel guesses cannot skip the attempt limit', () async {
    final store = build();
    await store.setPin('kid', '4821');
    final results = await Future.wait([
      for (var i = 0; i < 8; i++) store.verify('kid', '0000'),
    ]);
    expect(results.where((r) => r.result == PinResult.wrong), hasLength(4));
    expect(results.where((r) => r.result == PinResult.lockedOut), hasLength(4));
  });

  test('removing needs the current PIN', () async {
    final store = build();
    await store.setPin('kid', '4821');
    expect((await store.removePin('kid', '0000')).ok, isFalse);
    expect(store.isLocked('kid'), isTrue);
    expect((await store.removePin('kid', '4821')).ok, isTrue);
    expect(store.isLocked('kid'), isFalse);
    expect(storage.data, isEmpty);
  });

  test('changing a PIN replaces the old one', () async {
    final store = build();
    await store.setPin('kid', '4821');
    await store.setPin('kid', '9999');
    expect((await store.verify('kid', '4821')).ok, isFalse);
    expect((await store.verify('kid', '9999')).ok, isTrue);
  });

  test('PINs are kept per account and per profile', () async {
    final store = build();
    await store.setPin('kid', '4821');
    expect(store.isLocked('other'), isFalse);

    owner = 'user-2';
    await store.load(['kid']);
    expect(store.isLocked('kid'), isFalse);
    owner = 'local';
    await store.load(['kid']);
    expect(store.isLocked('kid'), isTrue);
  });

  test('load finds existing locks and notifies listeners', () async {
    await build().setPin('kid', '4821');
    final fresh = build();
    var notified = 0;
    fresh.addListener(() => notified++);
    await fresh.load(['kid', 'other']);
    expect(fresh.isLocked('kid'), isTrue);
    expect(fresh.isLocked('other'), isFalse);
    expect(notified, 1);
    // Reloading the same state does not cause pointless rebuilds.
    await fresh.load(['kid', 'other']);
    expect(notified, 1);
  });

  test('forgetting a deleted profile clears its lock', () async {
    final store = build();
    await store.setPin('kid', '4821');
    await store.forget('kid');
    expect(store.isLocked('kid'), isFalse);
    expect(storage.data, isEmpty);
  });

  test('a damaged record is cleared instead of locking the profile forever',
      () async {
    await build().setPin('kid', '4821');
    storage.data[storage.data.keys.single] = '{"salt":"nope"}';
    // A new store reads from storage (the first one would use its cache).
    final store = build();
    expect((await store.verify('kid', '1111')).ok, isTrue);
    expect(store.isLocked('kid'), isFalse);
    expect(storage.data, isEmpty);
  });

  test('a correct PIN with no earlier mistakes reads and writes nothing', () async {
    final store = build();
    await store.setPin('kid', '4821');
    storage.reads = 0;
    storage.writes = 0;
    expect((await store.verify('kid', '4821')).ok, isTrue);
    expect((await store.verify('kid', '4821')).ok, isTrue);
    // Fast path: the record is already in memory and nothing needs resetting.
    expect(storage.reads, 0);
    expect(storage.writes, 0);
  });

  test('after load, checks use memory instead of the credential store', () async {
    await build().setPin('kid', '4821');
    final store = build();
    await store.load(['kid']);
    storage.reads = 0;
    expect((await store.verify('kid', '4821')).ok, isTrue);
    expect(storage.reads, 0);
  });

  test('a wrong guess is saved before the check returns', () async {
    final store = build();
    await store.setPin('kid', '4821');
    storage.writes = 0;
    await store.verify('kid', '0000');
    expect(storage.writes, 1);
    // A correct PIN after a mistake resets the counter, so it must save.
    await store.verify('kid', '4821');
    expect(storage.writes, 2);
  });
}
