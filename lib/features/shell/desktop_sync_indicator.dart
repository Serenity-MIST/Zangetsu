import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/sync/sync_status.dart';
import '../../core/ui/global_messenger.dart';
import '../../l10n/l10n.dart';

/// acct-3: Windows sync feedback. It used to be a status icon in the title
/// bar; the user found that cluttered, so it is now an invisible, zero-size
/// listener. It still sits in the title bar (always mounted on Windows) and
/// only speaks up when something goes wrong: a toast with a Retry or Sign in
/// action when a sync fails, or when a sync finds the session needs signing
/// in. Normal syncing stays silent. F5 still runs a manual sync.
///
/// The class keeps its old name so the shell's [signInHandler] hook keeps
/// working without changes.
class DesktopSyncIndicator extends StatefulWidget {
  const DesktopSyncIndicator({super.key, this.onSignIn});

  /// Opens the place to sign in; used by the toast's Sign in action.
  final VoidCallback? onSignIn;

  /// Fallback sign-in action, set by the Windows shell. The title bar cannot
  /// reach the shell directly, so the shell installs this hook.
  static VoidCallback? signInHandler;

  /// How long the failure toast stays up. Longer than the normal 2 s toast
  /// so there is time to reach the action button.
  static const Duration toastDuration = Duration(seconds: 6);

  /// The same error is not toasted again within this window, so a
  /// background sync that keeps failing does not nag every few minutes.
  static const Duration repeatQuietPeriod = Duration(minutes: 5);

  /// Plain-English text for [state], with the last sync time.
  static String tooltipFor(SyncState state, DateTime? last, String? error) {
    final when = last == null ? null : _time(last);
    // Static helper without context; appL10n follows the app language.
    final l10n = appL10n;
    return switch (state) {
      SyncState.syncing => l10n.syncingListProgress,
      SyncState.synced =>
        when == null ? l10n.synced : l10n.syncedAtClickToSync(when),
      SyncState.offline => l10n.syncOfflineTooltip,
      SyncState.needsSignIn => l10n.signInToSyncListProgress,
      SyncState.error =>
        error == null
            ? l10n.syncFailedClickRetry
            : l10n.syncFailedErrorClickRetry(error),
      SyncState.idle =>
        when == null ? l10n.syncNow : l10n.lastSyncedAtClickToSync(when),
    };
  }

  // 24-hour HH:mm, short enough for a hint.
  static String _time(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';

  @override
  State<DesktopSyncIndicator> createState() => _DesktopSyncIndicatorState();
}

class _DesktopSyncIndicatorState extends State<DesktopSyncIndicator> {
  // State seen on the previous change, to toast only on transitions.
  SyncState _previous = SyncStatus.state.value;

  // The toast on screen (if any) and its auto-dismiss timer.
  OverlayEntry? _toast;
  Timer? _toastTimer;

  // Last error toasted and when, for the quiet period.
  String? _lastToastedError;
  DateTime? _lastToastedAt;

  @override
  void initState() {
    super.initState();
    SyncStatus.state.addListener(_onState);
  }

  @override
  void dispose() {
    SyncStatus.state.removeListener(_onState);
    _hideToast();
    super.dispose();
  }

  // Decides whether this state change deserves a toast.
  void _onState() {
    final state = SyncStatus.state.value;
    final previous = _previous;
    _previous = state;
    if (state == previous) return;
    switch (state) {
      case SyncState.error:
        final error = SyncStatus.lastError;
        final now = DateTime.now();
        final at = _lastToastedAt;
        // Same error again shortly after: stay quiet.
        if (error == _lastToastedError &&
            at != null &&
            now.difference(at) < DesktopSyncIndicator.repeatQuietPeriod) {
          return;
        }
        _lastToastedError = error;
        _lastToastedAt = now;
        _showToast(
          DesktopSyncIndicator.tooltipFor(state, null, error),
          appL10n.retry,
          () => unawaited(SyncStatus.requestSync()),
        );
      case SyncState.needsSignIn:
        // Only when a sync attempt ran into it (expired session or F5 while
        // signed out). Startup while signed out and signing out on purpose
        // arrive from idle / synced and stay silent.
        if (previous != SyncState.syncing) return;
        final signIn = widget.onSignIn ?? DesktopSyncIndicator.signInHandler;
        _showToast(
          DesktopSyncIndicator.tooltipFor(state, null, null),
          signIn == null ? null : appL10n.signIn,
          signIn,
        );
      case SyncState.synced:
        // A good sync clears the quiet period and any stale failure toast.
        _lastToastedError = null;
        _lastToastedAt = null;
        _hideToast();
      case SyncState.idle || SyncState.syncing || SyncState.offline:
        // Offline already shows in the title bar's connection pill.
        break;
    }
  }

  // Shows one toast with an optional action, replacing any earlier one.
  void _showToast(String message, String? actionLabel, VoidCallback? action) {
    // The title bar sits outside the app Navigator, so use the root
    // navigator's overlay; fall back to one above this widget.
    final overlay =
        rootNavigatorKey.currentState?.overlay ?? Overlay.maybeOf(context);
    if (overlay == null) return;
    _hideToast();
    final entry = OverlayEntry(
      builder: (context) => Positioned(
        left: 24,
        right: 24,
        bottom: 32,
        child: Material(
          type: MaterialType.transparency,
          child: Center(
            child: _SyncToast(
              message: message,
              actionLabel: actionLabel,
              onAction: action == null
                  ? null
                  : () {
                      _hideToast();
                      action();
                    },
            ),
          ),
        ),
      ),
    );
    _toast = entry;
    overlay.insert(entry);
    _toastTimer = Timer(DesktopSyncIndicator.toastDuration, _hideToast);
  }

  // Removes the toast if it is still showing.
  void _hideToast() {
    _toastTimer?.cancel();
    _toastTimer = null;
    final entry = _toast;
    _toast = null;
    if (entry != null && entry.mounted) entry.remove();
  }

  // Takes no space and draws nothing: the title bar stays uncluttered.
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// The failure toast: the app's dark pill, plus one action button.
class _SyncToast extends StatelessWidget {
  const _SyncToast({
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('desktop-sync-toast'),
    constraints: const BoxConstraints(maxWidth: 520),
    padding: const EdgeInsets.fromLTRB(20, 6, 8, 6),
    decoration: BoxDecoration(
      // Same colour and shape as showAppToast's pill.
      color: const Color(0xF01C1C1E),
      borderRadius: BorderRadius.circular(24),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
        ),
        if (actionLabel != null && onAction != null) ...[
          const SizedBox(width: 8),
          TextButton(
            key: const ValueKey('desktop-sync-toast-action'),
            onPressed: onAction,
            child: Text(actionLabel!),
          ),
        ] else
          const SizedBox(width: 12),
      ],
    ),
  );
}
