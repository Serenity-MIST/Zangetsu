import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hive/hive.dart';

import '../logging/app_logger.dart';
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
    this.dismiss,
  });

  /// Quits the app without asking again.
  final Future<void> Function() quit;

  /// Hides the window to the notification area.
  final Future<void> Function() hideToTray;

  /// Asks the user; null means the dialog was dismissed (cancel).
  final Future<DesktopCloseChoice?> Function(int activeCount) confirm;

  /// Takes the open question off the screen once a second close has
  /// decided to quit, so its buttons no longer look like they still work.
  final void Function()? dismiss;
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

  /// A second close while the question is open quits only when it comes at
  /// least this long after the first, so a double-click on the X by accident
  /// does not quit. It is longer than Windows' longest key-repeat delay (1 s),
  /// so holding Alt+F4 down does not quit either.
  static const secondRequestGap = Duration(milliseconds: 1100);

  /// ... and at least this long after the request before it. Holding Alt+F4
  /// sends a close for every key repeat, at most 400 ms apart (Windows'
  /// slowest repeat rate), so a held key never counts as a new click.
  static const repeatGap = Duration(milliseconds: 500);

  // While the question is being asked: when it was asked and how to quit.
  // Null when no question is open (quitting or hiding already runs).
  static DateTime? _askedAt;
  static DesktopCloseActions? _askEffects;
  static bool _forcedQuit = false;
  static Future<void>? _forcedQuitDone;
  // When the last close request came, the first one included.
  static DateTime? _lastRequestAt;
  // The open question's own context, so a forced quit can close it.
  static BuildContext? _dialogContext;

  /// The clock for the double-click check; tests replace it.
  @visibleForTesting
  static DateTime Function() debugNow = DateTime.now;

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

  /// Runs the guard for one close request. A second request while the
  /// question is open (or while it could not be shown, for example with a
  /// frozen picture) quits, unless it came within [secondRequestGap] of the
  /// first, which is taken as a double-click by accident. Other repeated
  /// requests are ignored. [actions] and [behaviour] replace the real side
  /// effects / stored setting in tests.
  static Future<void> handleCloseRequest({
    DesktopCloseActions? actions,
    String? behaviour,
    int? activeCount,
  }) async {
    if (_busy) {
      await _handleRepeatedRequest();
      return;
    }
    _busy = true;
    _forcedQuit = false;
    _forcedQuitDone = null;
    _lastRequestAt = debugNow();
    try {
      final effects = actions ?? _realActions;
      final count = activeCount ?? DesktopBackgroundWork.activeCount;
      final setting = behaviour ?? readCloseBehaviour();
      final action = decide(behaviour: setting, activeCount: count);
      // So the log shows whether the app was asked to close, and by which rule.
      AppLogger.instance.log(
        '[close] requested setting=$setting running=$count -> ${action.name}',
      );
      switch (action) {
        case DesktopCloseAction.quit:
          await effects.quit();
        case DesktopCloseAction.hideToTray:
          await effects.hideToTray();
        case DesktopCloseAction.confirm:
          _askedAt = debugNow();
          _askEffects = effects;
          final DesktopCloseChoice? choice;
          try {
            choice = await effects.confirm(count);
          } finally {
            _askedAt = null;
            _askEffects = null;
          }
          // A second close already quit: the late answer changes nothing.
          // Stay busy until that quit is done, so more closes are ignored.
          if (_forcedQuit) {
            if (choice != null) {
              AppLogger.instance.log(
                '[close] answer=${choice.name} ignored, already quitting',
              );
            }
            await _forcedQuitDone;
            return;
          }
          AppLogger.instance.log(
            '[close] answer=${choice?.name ?? 'dismissed'}',
          );
          if (choice == DesktopCloseChoice.quit) await effects.quit();
          if (choice == DesktopCloseChoice.tray) await effects.hideToTray();
      }
    } finally {
      _busy = false;
    }
  }

  // A close request that came while another one is still being handled.
  static Future<void> _handleRepeatedRequest() async {
    final askedAt = _askedAt;
    final effects = _askEffects;
    if (_forcedQuit) {
      AppLogger.instance.log('[close] ignored, already quitting');
      return;
    }
    if (askedAt == null || effects == null) {
      // Quitting or hiding to the tray is already under way.
      AppLogger.instance.log('[close] ignored, close already running');
      return;
    }
    final now = debugNow();
    final gap = now.difference(askedAt);
    final previous = _lastRequestAt;
    _lastRequestAt = now;
    if (gap < secondRequestGap) {
      AppLogger.instance.log(
        '[close] ignored, second request ${gap.inMilliseconds} ms after '
        'the question (double-click or held key)',
      );
      return;
    }
    if (previous != null && now.difference(previous) < repeatGap) {
      AppLogger.instance.log(
        '[close] ignored, ${now.difference(previous).inMilliseconds} ms after '
        'the last request (held key)',
      );
      return;
    }
    // Asked again with the question open, or the question never appeared:
    // the user means it, so quit without waiting for the answer.
    AppLogger.instance.log(
      '[close] second request ${gap.inMilliseconds} ms after the question '
      '-> quit',
    );
    await _forceQuit(effects);
  }

  /// The app's own X button. The timing checks above exist for Alt+F4 held
  /// down, which sends a close for every key repeat. A click on the X is
  /// always on purpose, so with the question already open it quits at once
  /// (reported: a quick second click on X was ignored as a double-click and
  /// the app looked stuck). Otherwise it is a normal close request.
  static Future<void> closeButtonPressed({
    Future<void> Function()? requestClose,
  }) async {
    final effects = _askEffects;
    if (_busy && _askedAt != null && effects != null && !_forcedQuit) {
      AppLogger.instance.log(
        '[close] X clicked with the question open -> quit',
      );
      await _forceQuit(effects);
      return;
    }
    await (requestClose ?? DesktopWindow.close)();
  }

  // Quits without waiting for the open question's answer.
  static Future<void> _forceQuit(DesktopCloseActions effects) async {
    _forcedQuit = true;
    // The question goes away first: its buttons would do nothing now.
    effects.dismiss?.call();
    final done = effects.quit();
    _forcedQuitDone = done;
    await done;
  }

  /// Allows a new request after a test left the guard mid-dialog.
  @visibleForTesting
  static void debugReset() {
    _busy = false;
    _trayHintShown = false;
    _askedAt = null;
    _askEffects = null;
    _forcedQuit = false;
    _forcedQuitDone = null;
    _lastRequestAt = null;
    _dialogContext = null;
    debugNow = DateTime.now;
  }

  static final _realActions = DesktopCloseActions(
    quit: DesktopWindow.forceClose,
    hideToTray: _hideToTray,
    confirm: _confirm,
    dismiss: _dismissQuestion,
  );

  // Closes the open question without an answer (the guard ignores it).
  static void _dismissQuestion() {
    final context = _dialogContext;
    _dialogContext = null;
    if (context == null || !context.mounted) return;
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    Navigator.of(context).removeRoute(route);
  }

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
      body: busy ? l10n.trayStillRunningBusy : l10n.trayStillRunningIdle,
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
    try {
      return await showDialog<DesktopCloseChoice>(
        context: context,
        // A click beside the question must not quietly cancel it: the
        // user then thinks X did nothing. Cancel and Esc still cancel.
        barrierDismissible: false,
        builder: (dialogContext) {
          _dialogContext = dialogContext;
          return DesktopCloseDialog(activeCount: activeCount);
        },
      );
    } finally {
      _dialogContext = null;
    }
  }
}

/// Centred graphite dialog shown when closing while downloads run.
class DesktopCloseDialog extends StatelessWidget {
  /// Creates the dialog for [activeCount] running downloads.
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
