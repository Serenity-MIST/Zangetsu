import 'package:flutter/foundation.dart';

/// Overall cloud sync state shown by the account indicator.
enum SyncState { idle, syncing, synced, offline, needsSignIn, error }

/// App-wide sync status board. Sync code reports into it; the UI listens to
/// [state] / [lastSynced] and calls [requestSync] for a manual "Sync now".
abstract final class SyncStatus {
  /// Current state; starts idle until something reports.
  static final ValueNotifier<SyncState> state = ValueNotifier(SyncState.idle);

  /// When the last successful sync finished (null = not this session).
  static final ValueNotifier<DateTime?> lastSynced = ValueNotifier(null);

  static String? _lastError;

  /// Message from the last report that carried an error, cleared on success.
  static String? get lastError => _lastError;

  /// Set by the sync owner to run a full sync when the user asks for one.
  static Future<void> Function()? onSyncRequested;

  /// The sync currently running from [requestSync], so double clicks share it.
  static Future<void>? _inFlight;

  /// Runs [onSyncRequested], reporting syncing -> synced (or error). Does
  /// nothing when no sync owner registered. Concurrent calls share one run.
  static Future<void> requestSync() {
    final callback = onSyncRequested;
    if (callback == null) return Future.value();
    return _inFlight ??= () async {
      report(SyncState.syncing);
      try {
        await callback();
        // The callback may already have reported (e.g. offline); only a run
        // that is still "syncing" is marked done here.
        if (state.value == SyncState.syncing) report(SyncState.synced);
      } catch (e) {
        report(SyncState.error, error: e.toString());
      } finally {
        _inFlight = null;
      }
    }();
  }

  /// Records a new [state]. synced also stamps [lastSynced] with now and
  /// clears the error; [error] is kept for the indicator's tooltip.
  static void report(SyncState state, {String? error}) {
    if (state == SyncState.synced) {
      lastSynced.value = DateTime.now();
      _lastError = null;
    } else if (error != null) {
      _lastError = error;
    }
    SyncStatus.state.value = state;
  }

  /// Resets everything (tests).
  @visibleForTesting
  static void debugReset() {
    state.value = SyncState.idle;
    lastSynced.value = null;
    _lastError = null;
    onSyncRequested = null;
    _inFlight = null;
  }
}
