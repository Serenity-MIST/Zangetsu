import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../core/locale/locale_controller.dart';
import '../core/ui/global_messenger.dart' show rootNavigatorKey;
import 'app_localizations.dart';
import 'app_localizations_en.dart';

export 'app_localizations.dart';

/// English, built once, for contexts with no [Localizations] above them.
final _fallback = AppLocalizationsEn();

extension L10nX on BuildContext {
  /// The current translations, falling back to English rather than throwing.
  ///
  /// `l10n.yaml` sets `nullable-getter: false`, so the generated
  /// `AppLocalizations.of` ends in `!` and dies on any context without the
  /// delegates above it. That's every widget test that pumps a bare
  /// `MaterialApp`, and it would be a crash in the app too if a delegate ever
  /// went missing from a route. English is a far better answer than a
  /// `Null check operator used on a null value`.
  AppLocalizations get l10n =>
      Localizations.of<AppLocalizations>(this, AppLocalizations) ?? _fallback;
}

/// Translations for code that has no [BuildContext] of its own: tray menus,
/// background download/notification text and catalogues built outside a
/// widget. Reads the root navigator, which sits under the app's
/// [Localizations], so it follows the chosen app language. Before the app is
/// on screen it uses the saved language (or the device's), and English when
/// neither is supported.
AppLocalizations get appL10n {
  try {
    // Reading the key needs the widgets binding; plain Dart tests have none.
    final context = rootNavigatorKey.currentContext;
    if (context != null) return context.l10n;
    final locale =
        LocaleController.locale ?? ui.PlatformDispatcher.instance.locale;
    return lookupAppLocalizations(locale);
  } catch (_) {
    // No binding yet, or an unsupported locale (lookup throws): English.
    return _fallback;
  }
}
