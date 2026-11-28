import 'package:flutter/foundation.dart';

/// One registered source of background work (e.g. the download queue).
class _WorkSource {
  const _WorkSource({
    required this.label,
    required this.activeCount,
    this.pauseAll,
  });

  /// Human-readable name of the work, e.g. 'Downloads'.
  final String label;

  /// Reads how many items are running right now.
  final int Function() activeCount;

  /// Pauses every running item, when the source supports pausing.
  final Future<void> Function()? pauseAll;
}

/// Registry of work that keeps running when the window closes to the tray
/// (downloads today). The close guard asks it whether anything is active,
/// and the tray menu's "Pause all downloads" calls [pauseAll].
///
/// Sources register once (e.g. when the download service starts) and call
/// [notifyChanged] when their active count changes so listeners refresh.
abstract final class DesktopBackgroundWork {
  static final Map<String, _WorkSource> _sources = {};

  // Bumped on every change; exposed only as a Listenable.
  static final ValueNotifier<int> _revision = ValueNotifier<int>(0);

  /// Adds or replaces the source called [id].
  static void register(
    String id, {
    required String label,
    required int Function() activeCount,
    Future<void> Function()? pauseAll,
  }) {
    _sources[id] = _WorkSource(
      label: label,
      activeCount: activeCount,
      pauseAll: pauseAll,
    );
    notifyChanged();
  }

  /// Removes the source called [id]; unknown ids are ignored.
  static void unregister(String id) {
    if (_sources.remove(id) != null) notifyChanged();
  }

  /// Total running items over every source. A source that throws counts
  /// as idle so a broken source can never block quitting.
  static int get activeCount {
    var total = 0;
    for (final source in _sources.values) {
      try {
        final count = source.activeCount();
        if (count > 0) total += count;
      } catch (_) {
        // Treat as idle.
      }
    }
    return total;
  }

  /// Running items of the source called [id] alone (0 when unknown).
  static int activeCountOf(String id) {
    final source = _sources[id];
    return source == null ? 0 : _safeCount(source);
  }

  /// Labels of the sources that currently have running items.
  static List<String> get activeLabels => [
    for (final source in _sources.values)
      if (_safeCount(source) > 0) source.label,
  ];

  /// Pauses every source that supports it; one failure does not stop the
  /// others.
  static Future<void> pauseAll() async {
    for (final source in _sources.values.toList()) {
      final pause = source.pauseAll;
      if (pause == null) continue;
      try {
        await pause();
      } catch (_) {
        // Keep pausing the remaining sources.
      }
    }
    notifyChanged();
  }

  /// Fires whenever a source registers, unregisters or reports a change.
  static Listenable get changes => _revision;

  /// Called by sources when their active count changed.
  static void notifyChanged() => _revision.value++;

  /// Clears every source between tests.
  @visibleForTesting
  static void debugReset() {
    _sources.clear();
    notifyChanged();
  }

  static int _safeCount(_WorkSource source) {
    try {
      return source.activeCount();
    } catch (_) {
      return 0;
    }
  }
}
