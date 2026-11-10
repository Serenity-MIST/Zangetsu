import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../l10n/ui_strings.dart';

/// Licensed, bundled Lucide outlines for Windows settings navigation.
///
/// The surrounding category button owns the accessible label. SVGs remain
/// decorative and are rendered as vectors rather than scaled bitmap artwork.
class DesktopSettingsIcon extends StatelessWidget {
  const DesktopSettingsIcon({
    super.key,
    required this.section,
    required this.fallback,
    required this.color,
    this.size = 24,
  });

  final String section;
  final IconData fallback;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final asset = switch (section) {
      SettingsSection.account => 'user-round',
      SettingsSection.sources => 'blocks',
      SettingsSection.playback => 'circle-play',
      SettingsSection.reading => 'book-open',
      SettingsSection.history => 'history',
      SettingsSection.downloads => 'download',
      SettingsSection.interface => 'settings-2',
      SettingsSection.notifications => 'bell',
      SettingsSection.advanced => 'sliders-horizontal',
      SettingsSection.about => 'info',
      _ => null,
    };
    return ExcludeSemantics(
      child: asset == null
          ? Icon(fallback, color: color, size: size)
          : SvgPicture.asset(
              'assets/icons/lucide/$asset.svg',
              width: size,
              height: size,
              colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
            ),
    );
  }
}
