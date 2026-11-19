import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/tracker/tracker.dart';
import 'package:watch_app/core/tracker/tracker_hub.dart';

/// A connected tracker that only implements the list writes; everything else
/// falls through to noSuchMethod because the hub never touches it here.
class _WriteTracker extends ChangeNotifier implements Tracker {
  _WriteTracker({this.fail = false});

  // When true every write throws, to prove a failed write still notifies.
  final bool fail;

  @override
  String get displayName => 'Stub';
  @override
  bool get isConnected => true;

  Future<void> _write() async {
    if (fail) throw StateError('boom');
  }

  @override
  Future<void> setStatus({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    required WatchStatus status,
    MediaKind kind = MediaKind.anime,
  }) => _write();

  @override
  Future<void> removeFromList({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    String? pinnedId,
    MediaKind kind = MediaKind.anime,
  }) => _write();

  @override
  Future<void> updateEntry({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    String? pinnedId,
    WatchStatus? status,
    double? score,
    int? progress,
    bool? isPrivate,
    MediaKind kind = MediaKind.anime,
  }) => _write();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('TrackerHub.listWrites', () {
    test('starts at zero', () {
      expect(TrackerHub([_WriteTracker()]).listWrites.value, 0);
    });

    test('bumps once after each list write finishes', () async {
      final hub = TrackerHub([_WriteTracker()]);
      await hub.setStatus(malId: 1, status: WatchStatus.watching);
      expect(hub.listWrites.value, 1);
      await hub.removeFromList(malId: 1);
      expect(hub.listWrites.value, 2);
      await hub.updateEntry(malId: 1, progress: 3);
      expect(hub.listWrites.value, 3);
    });

    test('still bumps when a tracker write fails', () async {
      final hub = TrackerHub([_WriteTracker(fail: true)]);
      await hub.setStatus(malId: 1, status: WatchStatus.completed);
      expect(hub.listWrites.value, 1);
    });

    // Direct per-tracker writes report themselves through noteListWrite.
    test('noteListWrite bumps it', () {
      final hub = TrackerHub([_WriteTracker()]);
      hub.noteListWrite();
      expect(hub.listWrites.value, 1);
    });

    test('auto-tracking writes do not bump it', () async {
      final hub = TrackerHub([_WriteTracker()]);
      // markWatching falls through to noSuchMethod and throws, which the
      // hub swallows; either way it is not a list edit.
      await hub.markWatching(malId: 1);
      expect(hub.listWrites.value, 0);
    });
  });
}
