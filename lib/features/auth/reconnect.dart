import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/boot_network.dart';
import '../../core/desktop/desktop_chrome_colors.dart';
import '../../core/desktop/desktop_dialogs.dart';
import '../../core/di/injector.dart';
import '../../core/playback/my_list.dart';
import '../../core/playback/watch_history.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/buttons.dart';
import '../../core/ui/desktop_docked_panel.dart';
import 'auth_cubit.dart';
import '../player/desktop_floating_player.dart';
import '../../l10n/l10n.dart';
import '../../l10n/ui_strings.dart';

/// Make sure the app has a LIVE Supabase session before a cloud write. When the
/// session has lapsed (the user is logged-in from cache only) this prompts for
/// the password and re-authenticates IN PLACE — no logout, so the local library
/// is never wiped. Returns true if we ended up with a live session.
Future<bool> ensureLiveSession(BuildContext context) async {
  final cubit = sl<AuthCubit>();
  if (cubit.state.user == null) return false; // genuinely signed out
  // Verify by actually refreshing the token — the only reliable check. A stored
  // session can look valid yet 401 every write; refreshSession() proves it and
  // revives it silently when the refresh token is alive (no password needed).
  if (await cubit.ensureFreshSession()) return true;
  if (!context.mounted) return false;
  // Windows: no connection is not a dead session. Asking for a password would
  // not help and would blame the account for a network problem. (The flag is
  // only ever set on Windows; phone and TV go straight to the dialog.)
  if (cubit.lastRefreshWasNetworkError ||
      (defaultTargetPlatform == TargetPlatform.windows &&
          BootConnectivity.instance.offline.value)) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text("You're offline. Try again once you're connected."),
      ),
    );
    return false;
  }
  final ok = await showReconnectDialog(context);
  return ok ?? false;
}

/// Password re-entry dialog that revives the session for the current account.
/// Returns true on success, null/false if dismissed or wrong password.
Future<bool?> showReconnectDialog(BuildContext context) => showDialog<bool>(
  context: context,
  builder: (_) => const _ReconnectDialog(),
);

Future<({int history, int list, int failed})> _pushLibrary() async {
  final (history, list) = await (
    sl<WatchHistory>().pushAllLocalToCloud(),
    sl<MyListStore>().pushAllLocalToCloud(),
  ).wait;
  return (
    history: history.pushed,
    list: list.pushed,
    failed: history.failed + list.failed,
  );
}

Future<bool> _backupForLogout(BuildContext context, String? userId) async {
  final auth = sl<AuthCubit>();
  if (!auth.hasLiveSession || auth.state.user?.id != userId) return false;
  final backup = await _pushLibrary();
  if (backup.failed == 0) return true;
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Library backup incomplete. Please try again.'),
      ),
    );
  }
  return false;
}

/// Log out WITHOUT losing an un-backed-up library. If there's local data and a
/// live session, push it to the cloud first; if there's local data and no live
/// session, warn (the logout-time [MyListStore.clearLocal] wipes local, and an
/// empty cloud means it can't be restored). Returns true if logout happened.
Future<bool> safeLogout(BuildContext context) async {
  final cubit = sl<AuthCubit>();
  final userId = cubit.state.user?.id;
  final hasLocal =
      sl<WatchHistory>().all().isNotEmpty || sl<MyListStore>().all().isNotEmpty;
  // Windows (acct-5): logging out is never a single click. The "back up
  // first?" warning below is already a confirmation, so only the other paths
  // ask here, keeping it to one question either way.
  final warnsAboutBackup = hasLocal && !cubit.hasLiveSession;
  if (desktopPanelsEnabled && !warnsAboutBackup) {
    if (!await confirmLogout(context)) return false;
    if (!context.mounted) return false;
  }
  if (hasLocal) {
    if (cubit.hasLiveSession) {
      // Back the library up before the logout wipes the local cache.
      if (!await _backupForLogout(context, userId)) return false;
    } else {
      // Windows: graphite three-button dialog; the phone keeps the
      // AlertDialog below unchanged. Both return 'cancel' / 'anyway' /
      // 'reconnect' (or null when dismissed).
      final choice = desktopPanelsEnabled
          ? await showBackupBeforeLogoutDesktop(context)
          : await showDialog<String>(
              context: context,
              builder: (_) => AlertDialog(
                backgroundColor: AppColors.surface,
                title: Text(
                  context.l10n.backUpBeforeLoggingOut,
                  style: AppText.title,
                ),
                content: Text(
                  "Your library isn't saved to the cloud yet, so logging out will "
                  'remove it from this device. Reconnect to back it up first?',
                  style: AppText.caption,
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, 'cancel'),
                    child: Text(context.l10n.cancel, style: AppText.button),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context, 'anyway'),
                    child: Text(
                      context.l10n.logOutAnyway,
                      style: AppText.button.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context, 'reconnect'),
                    child: Text(
                      context.l10n.reconnect,
                      style: AppText.button.copyWith(color: AppColors.accent),
                    ),
                  ),
                ],
              ),
            );
      if (choice == null || choice == 'cancel') return false;
      if (choice == 'reconnect') {
        if (!context.mounted) return false;
        final ok = await ensureLiveSession(context);
        if (!ok) return false; // couldn't reconnect → don't risk the wipe
        if (!context.mounted || !await _backupForLogout(context, userId)) {
          return false;
        }
      }
      // 'anyway' → fall through: the user accepted losing the local copy.
    }
  }
  if (!context.mounted || cubit.state.user?.id != userId) return false;
  // Windows: a video in the floating mini player is saved and stopped while
  // still signed in, so it does not go on playing over the sign-in page.
  if (DesktopFloatingPlayer.instance.isActive) {
    await closeFloatingPlayerBeforeProfileSwitch();
  }
  await cubit.logout();
  return true;
}

/// Windows logout confirmation (acct-5): names the signed-in account and says
/// the library is kept in the account. Enter confirms, Esc cancels.
@visibleForTesting
Future<bool> confirmLogout(BuildContext context) {
  final email = sl<AuthCubit>().state.user?.email ?? '';
  return showDesktopConfirm(
    context,
    title: context.l10n.logOut,
    message: email.isEmpty
        ? context.l10n.logOutLibraryStays
        : context.l10n.logOutOfEmailLibraryStays(email),
    confirmLabel: context.l10n.logOut,
    cancelLabel: context.l10n.cancel,
    destructive: true,
  );
}

/// Windows "Back up before logging out" dialog: the graphite frame of
/// [showDesktopConfirm] with three right-aligned buttons. Returns 'cancel',
/// 'anyway' or 'reconnect', or null when dismissed. Reconnect (the safe
/// choice) has focus, so Enter reconnects; Esc closes without logging out.
@visibleForTesting
Future<String?> showBackupBeforeLogoutDesktop(BuildContext context) =>
    showDialog<String>(
      context: context,
      // Same navigator as showDesktopConfirm, so it sits over the shell.
      useRootNavigator: false,
      builder: (dialogContext) => Dialog(
        backgroundColor: DesktopPanelColors.surface,
        surfaceTintColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(24),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: DesktopPanelColors.edge),
        ),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          // Wider than the two-button confirm so three labels fit on a row.
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.l10n.backUpBeforeLoggingOut,
                  style: AppText.headline.copyWith(
                    fontSize: 20,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  "Your library isn't saved to the cloud yet, so logging out "
                  'will remove it from this device. Reconnect to back it up '
                  'first?',
                  style: AppText.body.copyWith(
                    color: AppColors.textSecondary,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 20),
                // Wrap keeps the buttons right-aligned and lets them drop to
                // a second line in a narrow window instead of overflowing.
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      TextButton(
                        onPressed: () =>
                            Navigator.of(dialogContext).pop('cancel'),
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.textSecondary,
                        ),
                        child: Text(context.l10n.cancel),
                      ),
                      // Losing the local library is the risky path: an
                      // outlined red button, never the focused default.
                      OutlinedButton(
                        onPressed: () =>
                            Navigator.of(dialogContext).pop('anyway'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFFE06A6A),
                          side: BorderSide(color: DesktopPanelColors.edge),
                        ),
                        child: Text(context.l10n.logOutAnyway),
                      ),
                      FilledButton(
                        autofocus: true,
                        onPressed: () =>
                            Navigator.of(dialogContext).pop('reconnect'),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.accent,
                          foregroundColor: DesktopChrome.onAccent(
                            AppColors.accent,
                          ),
                        ),
                        child: Text(context.l10n.reconnect),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

class _ReconnectDialog extends StatefulWidget {
  const _ReconnectDialog();
  @override
  State<_ReconnectDialog> createState() => _ReconnectDialogState();
}

class _ReconnectDialogState extends State<_ReconnectDialog> {
  final _pw = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _pw.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || _pw.text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await sl<AuthCubit>().reconnect(_pw.text);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _busy = false;
        _error =
            localizeAuthError(context.l10n, sl<AuthCubit>().state.error) ??
            context.l10n.wrongPassword;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final email = sl<AuthCubit>().state.user?.email ?? '';
    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.l10n.reconnectToSync, style: AppText.title),
            const SizedBox(height: 6),
            Text(
              'Your session expired. Enter your password to reconnect '
              '${email.isEmpty ? context.l10n.yourAccount : email} and sync your library.',
              style: AppText.caption,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _pw,
              obscureText: true,
              autofocus: true,
              enabled: !_busy,
              onSubmitted: (_) => _submit(),
              style: AppText.body,
              decoration: InputDecoration(
                hintText: context.l10n.password,
                hintStyle: AppText.body.copyWith(color: AppColors.textTertiary),
                filled: true,
                fillColor: AppColors.surface2,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: AppText.caption.copyWith(color: AppColors.accent),
              ),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: PrimaryButton(
                label: _busy
                    ? context.l10n.reconnecting
                    : context.l10n.reconnect,
                onPressed: _busy ? null : _submit,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pushes the local library (history + My List) to the cloud with snackbar
/// feedback on the Account screen.
Future<void> syncLibraryNow(BuildContext context) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.of(context);
  final auth = sl<AuthCubit>();
  final userId = auth.state.user?.id;
  if (userId == null) {
    messenger.showSnackBar(SnackBar(content: Text(l10n.signInFirst)));
    return;
  }
  // The session may have lapsed (logged-in from cache only). Get a live one
  // first, otherwise every upsert silently no-ops ("Synced 0").
  final live = await ensureLiveSession(context);
  if (!context.mounted || auth.state.user?.id != userId) return;
  if (!live) {
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.reconnectToSyncLibrary)),
    );
    return;
  }
  messenger
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(l10n.syncingLibraryToCloud)));
  final result = await _pushLibrary();
  if (!context.mounted || auth.state.user?.id != userId) return;
  messenger
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Text(
          result.failed > 0
              ? 'Library sync incomplete. Please try again.'
              : result.history == 0 && result.list == 0
              ? l10n.syncLibraryAlreadySynced
              : l10n.syncLibraryPushed(result.history, result.list),
        ),
      ),
    );
}
