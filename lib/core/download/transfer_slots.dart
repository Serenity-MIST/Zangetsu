import 'dart:async';

/// A shared FIFO transfer limit. A lease spans the actual network transfer,
/// not merely enqueueing it in a platform downloader's private queue.
class TransferSlots {
  TransferSlots(int limit) : _limit = limit.clamp(1, 10);
  int _limit;
  bool _closed = false;
  final _active = <String, TransferLease>{};
  final _waiting = <String, Completer<TransferLease?>>{};

  /// Prevent duplicate scheduling from rewriting a running job as queued.
  bool contains(String id) =>
      _active.containsKey(id) || _waiting.containsKey(id);

  /// Surviving native transfers already own network capacity at startup, even
  /// if a newly lowered limit is below their count. Never interrupt them.
  void adopt(String id) {
    if (_closed || contains(id)) return;
    _active[id] = TransferLease._(this, id);
  }

  /// Existing transfers finish when the limit falls; raising it admits waiters.
  set limit(int value) {
    _limit = value.clamp(1, 10);
    _drain();
  }

  Future<TransferLease?> acquire(String id) {
    if (_closed || _active.containsKey(id) || _waiting.containsKey(id)) {
      return Future.value(null);
    }
    final completion = Completer<TransferLease?>();
    _waiting[id] = completion;
    _drain();
    return completion.future;
  }

  /// Removes only a pending job; active callers must stop their own transport.
  void cancelPending(String id) => _waiting.remove(id)?.complete(null);

  /// Capture current ownership before async finalization or a same-id retry.
  TransferLease? activeLease(String id) => _active[id];

  /// Native task callbacks report completion by id rather than a Dart lease.
  void release(String id) => _active[id]?.release();

  void _drain() {
    while (!_closed && _active.length < _limit && _waiting.isNotEmpty) {
      final id = _waiting.keys.first;
      final completion = _waiting.remove(id)!;
      final lease = TransferLease._(this, id);
      _active[id] = lease;
      completion.complete(lease);
    }
  }

  /// Old retry finalizers cannot release a newer attempt with the same id.
  void _release(TransferLease lease) {
    if (!identical(_active[lease.id], lease)) return;
    _active.remove(lease.id);
    _drain();
  }

  void close() {
    _closed = true;
    for (final completion in _waiting.values) {
      completion.complete(null);
    }
    _waiting.clear();
  }
}

/// Ownership token, safe to release from multiple completion/failure paths.
class TransferLease {
  TransferLease._(this._owner, this.id);
  final TransferSlots _owner;
  final String id;
  void release() => _owner._release(this);
}
