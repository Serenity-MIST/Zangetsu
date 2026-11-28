import 'package:flutter/material.dart';

/// One catalogue the Windows shell's switcher can jump to (a tracker such as
/// AniList, or an extension source).
class DesktopCatalogueOption {
  const DesktopCatalogueOption({
    required this.id,
    required this.label,
    this.shortLabel,
    required this.group,
    this.icon,
    this.iconUrl,
    required this.onSelect,
  });

  /// Stable id; compared with [DesktopCatalogueSwitch.currentId].
  final String id;

  /// Full name shown in the switcher's menu, e.g. 'AniList catalogue'.
  final String label;

  /// Compact name shown on the pill itself, e.g. 'AniList'; falls back to
  /// [label] when null.
  final String? shortLabel;

  /// Heading the option is listed under, e.g. 'Trackers' / 'Extensions'.
  final String group;
  final IconData? icon;

  /// Remote icon (extension logo); used when [icon] is null.
  final String? iconUrl;

  /// Switches the app to this catalogue.
  final VoidCallback onSelect;
}

/// Shared board between the screen that knows the catalogues (Home) and the
/// shell control that shows the switcher. Home publishes; the shell listens.
abstract final class DesktopCatalogueSwitch {
  /// Options in display order; empty hides the switcher.
  static final ValueNotifier<List<DesktopCatalogueOption>> options =
      ValueNotifier(const []);

  /// Id of the catalogue currently shown, if known.
  static final ValueNotifier<String?> currentId = ValueNotifier(null);

  /// Replaces the option list (and the current id when given).
  static void publish(
    List<DesktopCatalogueOption> options, {
    String? currentId,
  }) {
    DesktopCatalogueSwitch.options.value = List.unmodifiable(options);
    if (currentId != null) DesktopCatalogueSwitch.currentId.value = currentId;
  }

  /// Hides the switcher (e.g. when Home is disposed).
  static void clear() {
    options.value = const [];
    currentId.value = null;
  }
}
