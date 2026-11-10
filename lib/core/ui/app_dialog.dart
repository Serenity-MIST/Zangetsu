import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../tv/tv_alert_dialog.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import 'desktop_settings_surface.dart';

export '../tv/tv_alert_dialog.dart' show TvAlertAction, TvAlertDialog;

/// App-wide OK / yes-no / custom-action popups.
///
/// Settings on Windows use scoped desktop chrome; other destinations keep
/// [TvAlertDialog], including its TV focus behavior. Action ownership stays
/// with callers and dialogs remain on the root navigator in both cases.
abstract final class AppDialog {
  /// Lowest-level entry: title, body, actions. Prefer [alert] / [confirm]
  /// unless the buttons are not a plain OK or Cancel/Confirm pair.
  static Future<T?> show<T>(
    BuildContext context, {
    required String title,
    required Widget body,
    required List<TvAlertAction> actions,
    bool barrierDismissible = true,
  }) {
    if (DesktopSettingsScope.contains(context)) {
      return showDialog<T>(
        context: context,
        barrierDismissible: barrierDismissible,
        builder: (_) =>
            _DesktopSettingsAlert(title: title, body: body, actions: actions),
      );
    }
    return showTvAlertDialog<T>(
      context,
      title: title,
      body: body,
      actions: actions,
      barrierDismissible: barrierDismissible,
    );
  }

  /// Single-button notice. Dismisses with OK (or [okLabel]).
  static Future<void> alert(
    BuildContext context, {
    required String title,
    String? message,
    Widget? body,
    String? okLabel,
    bool barrierDismissible = true,
  }) {
    assert(
      message != null || body != null,
      'AppDialog.alert needs message or body',
    );
    return show<void>(
      context,
      title: title,
      body: body ?? Text(message!),
      barrierDismissible: barrierDismissible,
      actions: [
        TvAlertAction(
          label: okLabel ?? context.l10n.ok,
          primary: true,
          autofocus: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(),
        ),
      ],
    );
  }

  /// Cancel + confirm. Returns `true` only when the user confirms.
  ///
  /// [destructive] lands D-pad on Cancel so a stray OK cannot delete / reset.
  static Future<bool> confirm(
    BuildContext context, {
    required String title,
    required String message,
    String? confirmLabel,
    String? cancelLabel,
    bool destructive = false,
    bool barrierDismissible = true,
  }) async {
    final result = await show<bool>(
      context,
      title: title,
      body: Text(message),
      barrierDismissible: barrierDismissible,
      actions: [
        TvAlertAction(
          label: cancelLabel ?? context.l10n.cancel,
          autofocus: destructive,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(false),
        ),
        TvAlertAction(
          label: confirmLabel ?? context.l10n.ok,
          primary: true,
          autofocus: !destructive,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(true),
        ),
      ],
    );
    return result == true;
  }
}

/// Bounded desktop alerts use standard keyboard/mouse buttons. Overflowing
/// copy scrolls and actions wrap; destructive callers retain Cancel autofocus.
class _DesktopSettingsAlert extends StatelessWidget {
  const _DesktopSettingsAlert({
    required this.title,
    required this.body,
    required this.actions,
  });

  final String title;
  final Widget body;
  final List<TvAlertAction> actions;

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: const Color(0xFF1A1B20),
    surfaceTintColor: Colors.transparent,
    constraints: const BoxConstraints(maxWidth: 560),
    insetPadding: const EdgeInsets.all(24),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      side: const BorderSide(color: Color(0xFF36373E)),
    ),
    scrollable: true,
    title: Text(title, style: AppText.headline.copyWith(fontSize: 23)),
    content: DefaultTextStyle(
      style: AppText.body.copyWith(color: AppColors.textSecondary, height: 1.5),
      child: body,
    ),
    actions: [
      for (final action in actions)
        if (action.primary)
          FilledButton(
            autofocus: action.autofocus,
            onPressed: action.onTap,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: Text(action.label),
          )
        else
          TextButton(
            autofocus: action.autofocus,
            onPressed: action.onTap,
            style: TextButton.styleFrom(
              foregroundColor: AppColors.textPrimary,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: Text(action.label),
          ),
    ],
  );
}
