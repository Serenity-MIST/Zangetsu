import 'dart:async';

/// Device-local timers for persisted download deadlines; holds no transfer slot.
class DesktopDownloadRetry {
  DesktopDownloadRetry({DateTime Function()? now,
    Timer Function(Duration, void Function())? timerFactory})
      : now = now ?? DateTime.now, _timerFactory = timerFactory ?? Timer.new;
  final DateTime Function() now;
  final Timer Function(Duration, void Function()) _timerFactory;
  final Map<String, _PendingRetry> _pending = {};
  bool _disposed = false;

  /// Replaces one job's timer identity; obsolete callbacks cannot start work.
  void schedule(String id, String generation, DateTime deadline, void Function() action) {
    cancel(id);
    if (_disposed) return;
    final entry = _PendingRetry(generation, deadline, action);
    _pending[id] = entry;
    _arm(id, entry);
  }

  /// Bound long waits without shortening the server's original deadline.
  void _arm(String id, _PendingRetry entry) {
    final remaining = entry.deadline.difference(now());
    final delay = remaining <= Duration.zero ? Duration.zero
        : remaining > const Duration(days: 1) ? const Duration(days: 1) : remaining;
    entry.timer = _timerFactory(delay, () {
      if (_disposed || !identical(_pending[id], entry) ||
          _pending[id]?.generation != entry.generation) return;
      if (entry.deadline.isAfter(now())) { _arm(id, entry); return; }
      _pending.remove(id);
      entry.action();
    });
  }

  /// Invalidates even a callback whose canceled timer was already delivered.
  void cancel(String id) { _pending.remove(id)?.timer?.cancel(); }

  /// Retire all callbacks when their manager is disposed.
  void dispose() {
    _disposed = true;
    for (final entry in _pending.values) { entry.timer?.cancel(); }
    _pending.clear();
  }
}

/// In-memory callback identity; durable fields live in DownloadRecord.
class _PendingRetry {
  _PendingRetry(this.generation, this.deadline, this.action);
  final String generation;
  final DateTime deadline;
  final void Function() action;
  Timer? timer;
}
