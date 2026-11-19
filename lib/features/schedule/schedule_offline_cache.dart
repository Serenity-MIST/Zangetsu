import 'package:hive/hive.dart';

import '../../core/hive/safe_box.dart';
import '../../core/schedule/schedule_models.dart';

/// One saved copy of a schedule list and when it was fetched.
class ScheduleSnapshot<T> {
  const ScheduleSnapshot(this.entries, this.savedAt);

  /// The rows as they were on the last successful load.
  final List<T> entries;

  /// When that load finished (local time).
  final DateTime savedAt;
}

/// Keeps the last successful week of the Schedule so the Windows page can
/// still show something offline or after a failed load (track-5 Option B).
///
/// An interface so tests can use [MemoryScheduleOfflineCache] instead of Hive.
abstract interface class ScheduleOfflineCache {
  /// Makes [readAiring] / [readSoon] usable (opens storage). Never throws.
  Future<void> ensureOpen();

  /// The saved anime airing week, or null when nothing was saved yet.
  ScheduleSnapshot<AiringEntry>? readAiring();

  /// The saved movies/TV releases, or null when nothing was saved yet.
  ScheduleSnapshot<ComingSoonEntry>? readSoon();

  /// Replaces the saved anime week with [entries] (a successful load).
  Future<void> writeAiring(List<AiringEntry> entries, DateTime at);

  /// Replaces the saved movies/TV releases with [entries].
  Future<void> writeSoon(List<ComingSoonEntry> entries, DateTime at);
}

/// Hive-backed [ScheduleOfflineCache] (box 'schedule_offline_cache').
///
/// Stores plain maps (no adapters) so the box never needs a schema
/// migration; a row that fails to decode is skipped instead of failing all.
class HiveScheduleOfflineCache implements ScheduleOfflineCache {
  HiveScheduleOfflineCache();

  static const String boxName = 'schedule_offline_cache';
  static const String _airingKey = 'airing';
  static const String _soonKey = 'soon';

  Box<dynamic>? get _box =>
      Hive.isBoxOpen(boxName) ? Hive.box<dynamic>(boxName) : null;

  @override
  Future<void> ensureOpen() async {
    if (Hive.isBoxOpen(boxName)) return;
    try {
      await openBoxSafely<dynamic>(boxName);
    } catch (_) {
      // No cache is fine: the page just has no offline copy.
    }
  }

  @override
  ScheduleSnapshot<AiringEntry>? readAiring() =>
      _read(_airingKey, airingEntryFromMap);

  @override
  ScheduleSnapshot<ComingSoonEntry>? readSoon() =>
      _read(_soonKey, comingSoonEntryFromMap);

  @override
  Future<void> writeAiring(List<AiringEntry> entries, DateTime at) =>
      _write(_airingKey, [for (final e in entries) airingEntryToMap(e)], at);

  @override
  Future<void> writeSoon(List<ComingSoonEntry> entries, DateTime at) =>
      _write(_soonKey, [for (final e in entries) comingSoonEntryToMap(e)], at);

  /// Decodes one saved list; null when missing or unreadable.
  ScheduleSnapshot<T>? _read<T>(
    String key,
    T? Function(Map<dynamic, dynamic>) decode,
  ) {
    try {
      final raw = _box?.get(key);
      if (raw is! Map) return null;
      final at = raw['at'];
      final rows = raw['rows'];
      if (at is! int || rows is! List) return null;
      final entries = <T>[
        for (final r in rows)
          if (r is Map) ?decode(r),
      ];
      return ScheduleSnapshot(entries, DateTime.fromMillisecondsSinceEpoch(at));
    } catch (_) {
      return null;
    }
  }

  /// Saves one list with its timestamp; failures are ignored (cache only).
  Future<void> _write(
    String key,
    List<Map<String, Object?>> rows,
    DateTime at,
  ) async {
    final box = _box;
    if (box == null) return;
    try {
      await box.put(key, {'at': at.millisecondsSinceEpoch, 'rows': rows});
    } catch (_) {
      // Best effort: a failed write only means an older offline copy.
    }
  }
}

/// In-memory [ScheduleOfflineCache] for tests.
class MemoryScheduleOfflineCache implements ScheduleOfflineCache {
  ScheduleSnapshot<AiringEntry>? airing;
  ScheduleSnapshot<ComingSoonEntry>? soon;

  @override
  Future<void> ensureOpen() async {}

  @override
  ScheduleSnapshot<AiringEntry>? readAiring() => airing;

  @override
  ScheduleSnapshot<ComingSoonEntry>? readSoon() => soon;

  @override
  Future<void> writeAiring(List<AiringEntry> entries, DateTime at) async =>
      airing = ScheduleSnapshot(List.of(entries), at);

  @override
  Future<void> writeSoon(List<ComingSoonEntry> entries, DateTime at) async =>
      soon = ScheduleSnapshot(List.of(entries), at);
}

// ── plain-map codecs (the models have no JSON of their own) ─────────────────

/// [AiringEntry] as a Hive-safe map.
Map<String, Object?> airingEntryToMap(AiringEntry e) => {
  'malId': e.malId,
  'title': e.title,
  'altTitle': e.altTitle,
  'cover': e.coverUrl,
  'episode': e.episode,
  'airs': e.airsAtLocal.millisecondsSinceEpoch,
  'format': e.format,
  'banner': e.bannerUrl,
  'synopsis': e.synopsis,
};

/// Reverse of [airingEntryToMap]; null when a required field is missing.
AiringEntry? airingEntryFromMap(Map<dynamic, dynamic> m) {
  final title = m['title'];
  final episode = m['episode'];
  final airs = m['airs'];
  if (title is! String || episode is! int || airs is! int) return null;
  return AiringEntry(
    malId: m['malId'] as int?,
    title: title,
    altTitle: m['altTitle'] as String?,
    coverUrl: m['cover'] as String?,
    episode: episode,
    airsAtLocal: DateTime.fromMillisecondsSinceEpoch(airs),
    format: (m['format'] as String?) ?? '',
    bannerUrl: m['banner'] as String?,
    synopsis: m['synopsis'] as String?,
  );
}

/// [ComingSoonEntry] as a Hive-safe map.
Map<String, Object?> comingSoonEntryToMap(ComingSoonEntry e) => {
  'tmdbId': e.tmdbId,
  'isTv': e.isTv,
  'title': e.title,
  'poster': e.posterUrl,
  'release': e.releaseDate?.millisecondsSinceEpoch,
  'backdrop': e.backdropUrl,
  'synopsis': e.synopsis,
  'episode': e.episodeLabel,
  'rank': e.rank,
};

/// Reverse of [comingSoonEntryToMap]; null when a required field is missing.
ComingSoonEntry? comingSoonEntryFromMap(Map<dynamic, dynamic> m) {
  final id = m['tmdbId'];
  final title = m['title'];
  if (id is! int || title is! String) return null;
  final release = m['release'];
  return ComingSoonEntry(
    tmdbId: id,
    isTv: m['isTv'] == true,
    title: title,
    posterUrl: m['poster'] as String?,
    releaseDate: release is int
        ? DateTime.fromMillisecondsSinceEpoch(release)
        : null,
    backdropUrl: m['backdrop'] as String?,
    synopsis: m['synopsis'] as String?,
    episodeLabel: m['episode'] as String?,
    rank: m['rank'] as int?,
  );
}
