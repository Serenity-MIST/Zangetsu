import 'package:hive/hive.dart';

import '../hive/safe_box.dart';
import 'zmode_ids.dart';

/// An explicit, GLOBAL per-kind override of which source plays Z Mode titles.
///
/// On Windows this is the "Preferred source" on Settings > Source Priority
/// and means "try first, then fall back to Auto Resolve" (see
/// `SourceMatcher.preferredIsTryFirst`); elsewhere it is a fixed choice.
///
/// This is deliberately rare: the true default is Auto Resolve (every
/// installed source is swept, per title, in the user's priority order — see
/// `SourceOrderPrefs` and `SourceMatcher`). This override only exists for the
/// "source went quiet" recovery picker (`SourceMatcher.chooseSource`), and a
/// per-title pin (`MatchStore.pin`) always wins over it.
///
/// The reason this exists as a stored preference rather than something
/// derived: a remembered id is a synchronous read, so a Detail screen knows
/// its source on the first frame, with no sweep to wait for.
class ZSourcePrefs {
  ZSourcePrefs._(this._box);
  final Box<String> _box;

  static const String boxName = 'zmode_source';

  static Future<ZSourcePrefs> open() async =>
      ZSourcePrefs._(await openBoxSafely<String>(boxName));

  /// Buckets mirror `candidatesForKind`: anime and movie/TV are served by one
  /// streaming pool, so they share one remembered source. Manga and novel have
  /// their own pools and their own.
  static String bucketOf(ZKind kind) => switch (kind) {
    ZKind.manga => 'manga',
    ZKind.novel => 'novel',
    _ => 'video',
  };

  /// The explicit kind default, or null when none has ever been set — in
  /// which case Auto Resolve is what actually plays every title of this kind.
  String? get(ZKind kind) {
    // Anime has its own pick (see [_animeKey]); until one is made, the old
    // shared streaming pick keeps applying to it, exactly as before.
    final key = kind == ZKind.anime && !_box.containsKey(_animeKey)
        ? bucketOf(kind)
        : _choiceKey(kind);
    final v = _box.get(key)?.trim();
    if (v == null || v.isEmpty) return null;
    if (RegExp(r'^-?\d+$').hasMatch(v)) {
      return '${kind == ZKind.manga ? 'mihon' : 'ani'}:$v';
    }
    return v;
  }

  // Every write below is STARTED synchronously, with no await before it: Hive
  // updates its in-memory keystore inside put(), so [get] sees the new pick
  // the moment set()/clear() is called, even by a caller that does not await
  // (a resolve fired right after a Settings change must not read Auto).
  Future<void> set(ZKind kind, String sourceId) => _box.putAll({
    ..._animeSeparation(),
    // Last, so an anime pick overrides the seeded copy in the same write.
    _choiceKey(kind): sourceId,
  });

  Future<void> clear(ZKind kind) {
    // An empty anime pick means "Auto Resolve" explicitly, so it no longer
    // falls back to the Movies/TV pick.
    if (kind == ZKind.anime) return _box.put(_animeKey, '');
    final seed = _animeSeparation();
    return Future.wait([
      if (seed.isNotEmpty) _box.putAll(seed),
      _box.delete(_choiceKey(kind)),
    ]);
  }

  /// Anime gets its own preferred source: people often keep one source for
  /// anime and another that carries movies and TV (and some anime too), and
  /// a single shared pick sent anime through the movie source. Movies and TV
  /// still share one pick. A distinct key, so values left by very old builds
  /// under 'anime' are never mistaken for a choice.
  static const String _animeKey = 'pick:anime';

  static String _choiceKey(ZKind kind) =>
      kind == ZKind.anime ? _animeKey : bucketOf(kind);

  /// Before the first separate choice, the write that copies the old shared
  /// pick to anime, so changing the Movies/TV source afterwards does not
  /// change anime as well. Empty once anime has its own key.
  Map<String, String> _animeSeparation() => _box.containsKey(_animeKey)
      ? const {}
      : {_animeKey: _box.get(bucketOf(ZKind.anime)) ?? ''};

  // ── The soft one ────────────────────────────────────────────────────────
  // Separate key, and deliberately NOT [get]: this is a hint, not a choice.
  // The explicit default above is honoured as-is, misses included, on phone
  // and TV; on Windows it is "try first, then Auto Resolve" too (see
  // SourceMatcher.preferredIsTryFirst). This one is only "start here", and a
  // miss falls through to the sweep.

  String _lastGoodKey(ZKind kind) => 'lastGood:${bucketOf(kind)}';

  /// The source that last produced a real match for this kind.
  ///
  /// Reading leans on this because a sweep there is expensive AND risky: the
  /// matched source owns the chapter list outright, where video re-resolves
  /// per episode at play time. Someone reading manga is almost always reading
  /// from the same source as last time, so trying it first turns 22 searches
  /// into one.
  String? lastGood(ZKind kind) {
    final v = _box.get(_lastGoodKey(kind))?.trim();
    if (v == null || v.isEmpty) return null;
    if (RegExp(r'^-?\d+$').hasMatch(v)) {
      return '${kind == ZKind.manga ? 'mihon' : 'ani'}:$v';
    }
    return v;
  }

  Future<void> rememberLastGood(ZKind kind, String sourceId) =>
      _box.put(_lastGoodKey(kind), sourceId);

  Future<void> clearLastGood(ZKind kind) => _box.delete(_lastGoodKey(kind));
}
