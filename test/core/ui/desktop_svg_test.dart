import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
// The strategy type lives in vector_graphics, which flutter_svg uses.
// ignore: depend_on_referenced_packages
import 'package:vector_graphics/vector_graphics_compat.dart'
    show RenderingStrategy;
import 'package:watch_app/core/ui/desktop_svg.dart';
import 'package:watch_app/features/home/desktop_home_page.dart'
    show DesktopHomeIcon;

/// The Home icon is a tinted SVG, the same kind the sidebar, caption buttons
/// and top bar use.
Widget _icon() => const MaterialApp(
  home: Scaffold(
    body: Center(child: DesktopHomeIcon('play', color: Colors.red)),
  ),
);

void main() {
  testWidgets('Windows draws tinted SVG icons from a ready-made picture', (
    tester,
  ) async {
    expect(desktopSvgStrategy, RenderingStrategy.raster);
    await tester.pumpWidget(_icon());
    await tester.pumpAndSettle();
    final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
    expect(svg.renderingStrategy, RenderingStrategy.raster);
    // The colour is still applied (while drawing, not as a layer).
    expect(
      svg.colorFilter,
      const ColorFilter.mode(Colors.red, BlendMode.srcIn),
    );
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('Android keeps the normal vector drawing', (tester) async {
    expect(desktopSvgStrategy, RenderingStrategy.picture);
    await tester.pumpWidget(_icon());
    await tester.pumpAndSettle();
    final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
    expect(svg.renderingStrategy, RenderingStrategy.picture);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
