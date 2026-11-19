import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../hive/safe_box.dart';

/// One "new episodes/chapters" alert for a followed show.
class NewEpisodeEntry {
  const NewEpisodeEntry({
    required this.id,
    required this.showId,
    required this.sourceId,
    required this.title,
    required this.mode,
    required this.count,
    this.cover,
    required this.at,
    this.read = false,
  });

  final String id;
  final String showId;
  final String sourceId;
  final String title;

  /// anime | manga | novel | movie, used to pick the icon and the screen.
  final String mode;

  /// How many new episodes/chapters arrived.
  final int count;
  final String? cover;

  /// When the alert was raised.
  final DateTime at;
  final bool read;

  NewEpisodeEntry copyWith({bool? read}) => NewEpisodeEntry(
    id: id,
    showId: showId,
    sourceId: sourceId,
    title: title,
    mode: mode,
    count: count,
    cover: cover,
    at: at,
    read: read ?? this.read,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'showId': showId,
    'sourceId': sourceId,
    'title': title,
    'mode': mode,
    'count': count,
    'cover': cover,
    'at': at.millisecondsSinceEpoch,
    'read': read,
  };

  /// Tolerant of missing fields so an older/partial record still loads.
  factory NewEpisodeEntry.fromJson(Map<String, dynamic> json) =>
      NewEpisodeEntry(
        id: '${json['id'] ?? ''}',
        showId: '${json['showId'] ?? ''}',
        sourceId: '${json['sourceId'] ?? ''}',
        title: '${json['title'] ?? ''}',
        mode: '${json['mode'] ?? 'anime'}',
        count: (json['count'] as num?)?.toInt() ?? 1,
        cover: json['cover'] as String?,
        at: DateTime.fromMillisecondsSinceEpoch(
          (json['at'] as num?)?.toInt() ?? 0,
        ),
        read: json['read'] == true,
      );
}

/// Local inbox of new-episode alerts (the bell in the Windows shell).
///
/// Stored in the Hive box [boxName] as one JSON string per entry. Before
/// [init] (or in tests) it works purely in memory, so callers never need to
/// check whether it is ready.
abstract final class NewEpisodeInbox {
  static const boxName = 'new_episode_inbox';

  /// Oldest entries beyond this are dropped so the box stays small.
  static const int _maxEntries = 200;

  static Box<dynamic>? _box;
  static final Map<String, NewEpisodeEntry> _entries = {};
  static final ValueNotifier<int> _unread = ValueNotifier(0);
  static final _Changes _changes = _Changes();

  /// Opens the box and loads saved entries. Failures leave it in memory.
  static Future<void> init() async {
    try {
      _box = Hive.isBoxOpen(boxName)
          ? Hive.box<dynamic>(boxName)
          : await openBoxSafely<dynamic>(boxName);
      _entries.clear();
      for (final raw in _box!.values) {
        try {
          final e = NewEpisodeEntry.fromJson(
            Map<String, dynamic>.from(jsonDecode(raw as String) as Map),
          );
          if (e.id.isNotEmpty) _entries[e.id] = e;
        } catch (_) {
          // One bad record must not hide the rest.
        }
      }
    } catch (_) {
      _box = null;
    }
    _changed();
  }

  /// Number of unread entries (drives the bell badge).
  static ValueListenable<int> get unread => _unread;

  /// All entries, newest first.
  static List<NewEpisodeEntry> get entries =>
      _entries.values.toList()..sort((a, b) => b.at.compareTo(a.at));

  /// Fires after any change.
  static Listenable get changes => _changes;

  /// Adds [e], replacing any older entry for the same show and source.
  static Future<void> add(NewEpisodeEntry e) async {
    final stale = _entries.values
        .where((x) => x.showId == e.showId && x.sourceId == e.sourceId)
        .map((x) => x.id)
        .toList();
    for (final id in stale) {
      _entries.remove(id);
      await _box?.delete(id);
    }
    _entries[e.id] = e;
    await _box?.put(e.id, jsonEncode(e.toJson()));
    // Trim the oldest past the cap.
    final all = entries;
    for (final old in all.skip(_maxEntries)) {
      _entries.remove(old.id);
      await _box?.delete(old.id);
    }
    _changed();
  }

  static Future<void> markRead(String id) async {
    final e = _entries[id];
    if (e == null || e.read) return;
    await _put(e.copyWith(read: true));
    _changed();
  }

  static Future<void> markAllRead() async {
    final unreadEntries = _entries.values.where((e) => !e.read).toList();
    if (unreadEntries.isEmpty) return;
    for (final e in unreadEntries) {
      await _put(e.copyWith(read: true));
    }
    _changed();
  }

  static Future<void> remove(String id) async {
    if (_entries.remove(id) == null) return;
    await _box?.delete(id);
    _changed();
  }

  /// Clears memory and forgets the box (tests).
  @visibleForTesting
  static void debugReset() {
    _box = null;
    _entries.clear();
    _changed();
  }

  static Future<void> _put(NewEpisodeEntry e) async {
    _entries[e.id] = e;
    await _box?.put(e.id, jsonEncode(e.toJson()));
  }

  /// Recounts unread and notifies listeners.
  static void _changed() {
    _unread.value = _entries.values.where((e) => !e.read).length;
    _changes.ping();
  }
}

/// A Listenable whose notify is reachable from the static owner.
class _Changes extends ChangeNotifier {
  void ping() => notifyListeners();
}
