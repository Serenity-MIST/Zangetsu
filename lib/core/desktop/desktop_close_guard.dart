import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hive/hive.dart';

import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../ui/desktop_docked_panel.dart';
import '../ui/global_messenger.dart';
import 'desktop_background_work.dart';
import 'desktop_native.dart';
import 'desktop_window.dart';
import '../../l10n/l10n.dart';

/// What the close button should do, before any dialog is shown.
enum DesktopCloseAction { quit, hideToTray, confirm }

/// The user's answer in the "downloads in progress" dialog.
enum DesktopCloseChoice { quit, tray, cancel }

/// The side effects of closing, injectable so tests can use a fake.
class DesktopCloseActions {
  const DesktopCloseActions({
    required this.quit,
    required this.hideToTray,
    required this.confirm,
  });

  /// Quits the app without asking again.
  final Future<void> Function() quit;

  /// Hides the window to the notification area.
  final Future<void> Function() hideToTray;

  /// Asks the user; null means the dialog was dismissed (cancel).
  final Future<DesktopCloseChoice?> Function(int activeCount) confirm;
}

/// Decides what the window's close button (caption X, Alt+F4, taskbar
/// Close) does. The runner offers every close to Dart as 'closeRequested';
/// this applies the user's "Close button behaviour" setting:
///
/// * ask (default): quit, unless downloads are running, then ask
///   Quit / Keep running in tray / Cancel.
/// * trayWhileDownloading: hide to the tray while work is running, else quit.
/// * alwaysTray: always hide to the tray.
/// * quit: always quit.
abstract final class DesktopCloseGuard {
  /// Hive box and key written by the Window & system settings page. Read
  /// raw here so this file does not depend on the settings code.
  static const prefsBox = 'desktop_prefs';
  static const closeBehaviourKey = 'close_behaviour';

  /// Known stored values; anything else falls back to 'ask'.
  static const behaviours = {
    'ask',
    'trayWhileDownloading',
    'alwaysTray',
    'quit',
  };

  static bool _busy = false;
  static bool _trayHintShown = false;

  /// The stored close behaviour, 'ask' when unset or the box is closed.
  static String readCloseBehaviour() {
    if (!Hive.isBoxOpen(prefsBox)) return 'ask';
    try {
      final value = Hive.box<dynamic>(prefsBox).get(closeBehaviourKey);
      return value is String && behaviours.contains(value) ? value : 'ask';
    } catch (_) {
      // Opened as a different box type: behave as the default.
      return 'ask';
    }
  }

  /// Pure policy: what to do for [behaviour] with [activeCount] items of
  /// background work running.
  static DesktopCloseAction decide({
    required String behaviour,
    required int activeCount,
  }) {
    final busy = activeCount > 0;
    switch (behaviour) {
      case 'quit':
        return DesktopCloseAction.quit;
      case 'alwaysTray':
        return DesktopCloseAction.hideToTray;
      case 'trayWhileDownloading':
        return busy ? DesktopCloseAction.hideToTray : DesktopCloseAction.quit;
      default:
        return busy ? DesktopCloseAction.confirm : DesktopCloseAction.quit;
    }
  }

  /// Runs the guard for one close request. Repeated requests while a
  /// dialog is open are ignored. [actions] and [behaviour] replace the real
  /// side effects / stored setting in tests.
  static Future<void> handleCloseRequest({
    DesktopCloseActions? actions,
    String? behaviour,
    int? activeCount,
  }) async {
    if (_busy) return;
    _busy = true;
    try {
      final effects = actions ?? _realActions;
      final count = activeCount ?? DesktopBackgroundWork.activeCount;
      final action = decide(
        behaviour: behaviour ?? readCloseBehaviour(),
        activeCount: count,
      );
      switch (action) {
        case DesktopCloseAction.quit:
          await effects.quit();
        case DesktopCloseAction.hideToTray:
          await effects.hideToTray();
        case DesktopCloseAction.confirm:
          final choice = await effects.confirm(count);
          if (choice == DesktopCloseChoice.quit) await effects.quit();
          if (choice == DesktopCloseChoice.tray) await effects.hideToTray();
      }
    } finally {
      _busy = false;
    }
  }

  /// Allows a new request after a test left the guard mid-dialog.
  @visibleForTesting
  static void debugReset() {
    _busy = false;
    _trayHintShown = false;
  }

  static final _realActions = DesktopCloseActions(
    quit: DesktopWindow.forceClose,
    hideToTray: _hideToTray,
    confirm: _confirm,
  );

  // Hides to the tray and, the first time per session, explains where the
  // app went so it does not look like it quit.
  static Future<void> _hideToTray() async {
    await DesktopNative.hideToTray();
    if (_trayHintShown) return;
    _trayHintShown = true;
    // 'Always keep running in the tray' also hides with nothing running,
    // so only mention downloads when some are actually going.
    final busy = DesktopBackgroundWork.activeCount > 0;
    // No widget context here: appL10n follows the app language.
    final l10n = appL10n;
    await DesktopNative.showNotification(
      title: l10n.trayStillRunningTitle,
      body: busy
          ? l10n.trayStillRunningBusy
          : l10n.trayStillRunningIdle,
    );
  }

  // Shows the confirmation on the root navigator. Without one (very early
  // or very late in the app's life) there is nobody to ask: quit.
  static Future<DesktopCloseChoice?> _confirm(int activeCount) async {
    final context = rootNavigatorKey.currentContext;
    if (context == null || !context.mounted) return DesktopCloseChoice.quit;
    // A window in the tray or minimised must be visible to ask.
    await DesktopNative.restoreFromTray();
    if (!context.mounted) return DesktopCloseChoice.quit;
    return showDialog<DesktopCloseChoice>(
      context: context,
      builder: (_) => DesktopCloseDialog(activeCount: activeCount),
    );
  }
}

/// Centred graphite dialog shown when closing while downloads run.
class DesktopCloseDialog extends StatelessWidget {
  const DesktopCloseDialog({super.key, required this.activeCount});

  /// Number of running downloads shown in the title.
  final int activeCount;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final title = l10n.closeDownloadsInProgress(activeCount);
    void pick(DesktopCloseChoice choice) => Navigator.of(context).pop(choice);
    // Esc reaches the window-level binding, which pops this root dialog
    // (cancel); Enter picks the focused default button.
    return Dialog(
      backgroundColor: DesktopPanelColors.surface,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: DesktopPanelColors.edge),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: AppText.headline.copyWith(
                  fontSize: 20,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                l10n.closeQuitStopsDownloads,
                style: AppText.caption.copyWith(
                  color: AppColors.textSecondary,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 22),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton(
                    key: const ValueKey('close-guard-cancel'),
                    onPressed: () => pick(DesktopCloseChoice.cancel),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.textSecondary,
                    ),
                    child: Text(l10n.cancel),
                  ),
                  OutlinedButton(
                    key: const ValueKey('close-guard-quit'),
                    onPressed: () => pick(DesktopCloseChoice.quit),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.textPrimary,
                      side: BorderSide(color: DesktopPanelColors.edge),
                    ),
                    child: Text(l10n.quit),
                  ),
                  // Default: the safe choice that keeps downloads going.
                  FilledButton(
                    key: const ValueKey('close-guard-tray'),
                    autofocus: true,
                    onPressed: () => pick(DesktopCloseChoice.tray),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.white,
                    ),
                    child: Text(l10n.keepRunningInTray),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
