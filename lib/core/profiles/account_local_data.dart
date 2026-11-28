import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../hive/safe_box.dart';
import '../playback/my_list.dart';
import '../playback/watch_history.dart';
import '../reading/read_history.dart';

/// Keeps each signed-in account's local library on disk across sign-outs
/// (acct-1, Windows).
///
/// Signing out used to wipe My List, Continue Watching and reading history
/// from the PC, so anything not yet uploaded was lost and signing back in
/// had to wait for the cloud. Now, on sign-out, the live library boxes are
/// copied into per-account snapshot boxes before they are cleared; when the
/// same account signs in again the snapshot is copied back at once. Another
/// account never sees it, so a different account starts clean.
///
/// Works only with box names (the stores are not changed): the live boxes
/// are those of [MyListStore], [WatchHistory] and [ReadHistory] plus their
/// shared sync-metadata box (pull times, cursors, queued offline writes).
abstract final class AccountLocalData {
  /// Small box remembering who owns the live library and which snapshots
  /// exist.
  static const metaBoxName = 'account_local_data';

  /// Key in [metaBoxName]: id of the account the live boxes belong to.
  static const ownerKey = 'owner';

  /// The live boxes that make up "the library" of an account.
  static const List<String> libraryBoxes = [
    MyListStore.boxName,
    WatchHistory.boxName,
    ReadHistory.boxName,
    MyListStore.syncMetaBox,
  ];

  /// Boxes to snapshot; tests swap in their own names.
  @visibleForTesting
  static List<String> boxes = libraryBoxes;

  /// Meta key listing the boxes saved for one account.
  static String _snapshotKey(String userId) => 'snap:${_safe(userId)}';

  /// Hive box names are lower-case and limited in characters, so the user
  /// id is reduced to [a-z0-9_].
  static String _safe(String userId) =>
      userId.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '_');

  /// Box holding [userId]'s copy of the live box [box].
  @visibleForTesting
  static String snapshotBoxName(String userId, String box) =>
      'acct_${_safe(userId)}_$box';

  static Future<Box<dynamic>> _meta() async => Hive.isBoxOpen(metaBoxName)
      ? Hive.box<dynamic>(metaBoxName)
      : await openBoxSafely<dynamic>(metaBoxName);

  /// The account the live library currently belongs to (null = signed out
  /// or never recorded).
  static Future<String?> owner() async {
    final value = (await _meta()).get(ownerKey);
    return value is String && value.isNotEmpty ? value : null;
  }

  /// Whether a sign-out snapshot exists for [userId].
  static Future<bool> hasSnapshot(String userId) async =>
      (await _meta()).containsKey(_snapshotKey(userId));

  /// Call when the account is signed out, BEFORE the live boxes are
  /// cleared. Copies the live library into the owner's snapshot and forgets
  /// the owner. Returns false when nobody owned the live data (a guest
  /// library is not saved, as before).
  static Future<bool> onSignedOut() => _serial(_signedOut);

  static Future<bool> _signedOut() async {
    final meta = await _meta();
    final userId = await owner();
    if (userId == null) return false;
    await _snapshot(userId, meta);
    await meta.delete(ownerKey);
    return true;
  }

  /// Call when [userId] is signed in (also safe on every launch). Same owner
  /// as the live data: nothing happens. Another owner: its data is saved to
  /// its snapshot and [clearLive] wipes the live boxes first. Then any
  /// snapshot of [userId] is copied over the live boxes (anything made while
  /// signed out stays and is uploaded by the normal sync). Returns true when
  /// a snapshot was restored.
  static Future<bool> onSignedIn(
    String userId, {
    required Future<void> Function() clearLive,
  }) => _serial(() => _signedIn(userId, clearLive));

  static Future<bool> _signedIn(
    String userId,
    Future<void> Function() clearLive,
  ) async {
    final meta = await _meta();
    final current = await owner();
    if (current == userId) return false;
    if (current != null) {
      // Account switch without a sign-out in between: keep the old
      // account's library apart before this one takes over.
      await _snapshot(current, meta);
      await clearLive();
    }
    final restored = await _restore(userId, meta);
    await meta.put(ownerKey, userId);
    return restored;
  }

  /// Tail of the running sign-in/sign-out work. The boot restore and the
  /// auth listener can both call [onSignedIn] for the same account at once;
  /// running them one after the other stops two restores from reading and
  /// deleting the same snapshot box together.
  static Future<void> _tail = Future<void>.value();

  /// Runs [job] once every earlier job has finished (failed or not) and
  /// returns its result.
  static Future<T> _serial<T>(Future<T> Function() job) {
    final result = _tail.then((_) => job());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  /// An open live box whatever its value type. Hive refuses a box asked for
  /// with a different type than it was opened with, and the library boxes are
  /// opened as Box<Map> while the sync-metadata box is untyped.
  static Box<dynamic> _live(String name) {
    try {
      return Hive.box<Map>(name);
    } on HiveError {
      return Hive.box<dynamic>(name);
    }
  }

  /// Copies every open live box into [userId]'s snapshot boxes.
  static Future<void> _snapshot(String userId, Box<dynamic> meta) async {
    final saved = <String>[];
    for (final name in boxes) {
      if (!Hive.isBoxOpen(name)) continue;
      final live = _live(name);
      final snap = await Hive.openBox<dynamic>(snapshotBoxName(userId, name));
      await snap.clear();
      await snap.putAll(live.toMap());
      await snap.close();
      saved.add(name);
    }
    await meta.put(_snapshotKey(userId), saved);
  }

  /// Copies [userId]'s snapshot back into the live boxes, then deletes the
  /// snapshot (the live boxes are the account's data again). Returns false
  /// when there was none.
  static Future<bool> _restore(String userId, Box<dynamic> meta) async {
    final saved = meta.get(_snapshotKey(userId));
    if (saved is! List) return false;
    for (final name in saved.whereType<String>()) {
      final snapName = snapshotBoxName(userId, name);
      final snap = await Hive.openBox<dynamic>(snapName);
      if (Hive.isBoxOpen(name)) {
        final live = _live(name);
        final values = snap.toMap();
        if (live is Box<Map>) {
          // The library boxes are typed Box<Map>: hand them a Map-typed map
          // so putAll's runtime type check passes.
          await live.putAll({
            for (final e in values.entries)
              if (e.value is Map) e.key: e.value as Map,
          });
        } else {
          await live.putAll(values);
        }
      }
      await snap.deleteFromDisk();
    }
    await meta.delete(_snapshotKey(userId));
    return true;
  }
}
