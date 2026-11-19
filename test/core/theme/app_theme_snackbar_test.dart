import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/theme/app_theme.dart';

/// Windows snackbars are bounded centred floating toasts; phone is unchanged.
void main() {
  final windows = TargetPlatformVariant.only(TargetPlatform.windows);

  /// The visible toast surface (the SnackBar's own box spans the strip).
  Finder toast() => find
      .descendant(of: find.byType(SnackBar), matching: find.byType(Material))
      .first;

  Future<void> showBar(
    WidgetTester tester, {
    double? width,
    VoidCallback? onCorner,
  }) async {
    tester.view.physicalSize = Size(width ?? 1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Stack(
              fit: StackFit.expand,
              children: [
                Align(
                  alignment: Alignment.topLeft,
                  child: TextButton(
                    onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Library synced')),
                    ),
                    child: const Text('Go'),
                  ),
                ),
                // A control in the bottom-left corner, beside the toast.
                Positioned(
                  left: 0,
                  bottom: 0,
                  width: 120,
                  height: 40,
                  child: TextButton(
                    onPressed: onCorner,
                    child: const Text('Corner'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
  }

  testWidgets('Windows: floating, 640 wide, centred, graphite', (tester) async {
    final theme = buildAppTheme().snackBarTheme;
    expect(theme.behavior, SnackBarBehavior.floating);
    expect(theme.width, kDesktopSnackBarWidth);
    expect(theme.backgroundColor, const Color(0xFF1F2026));
    expect(
      (theme.shape! as RoundedRectangleBorder).borderRadius,
      BorderRadius.circular(10),
    );

    await showBar(tester);
    final rect = tester.getRect(toast());
    expect(rect.width, kDesktopSnackBarWidth);
    expect(rect.center.dx, closeTo(800, 0.5));
    expect(rect.bottom, closeTo(900 - 18, 0.5));
    expect(tester.takeException(), isNull);
  }, variant: windows);

  testWidgets('Windows: controls beside the toast stay clickable', (
    tester,
  ) async {
    var taps = 0;
    await showBar(tester, onCorner: () => taps++);
    expect(find.byType(SnackBar), findsOneWidget);
    await tester.tapAt(const Offset(30, 900 - 20));
    await tester.pump();
    expect(taps, 1);
  }, variant: windows);

  testWidgets('Windows: a window narrower than 640 does not overflow', (
    tester,
  ) async {
    await showBar(tester, width: 500);
    expect(tester.takeException(), isNull);
    expect(tester.getRect(toast()).width, lessThanOrEqualTo(500));
  }, variant: windows);

  testWidgets('phone theme keeps the stock snackbar', (tester) async {
    expect(buildAppTheme().snackBarTheme, const SnackBarThemeData());
    await showBar(tester, width: 400);
    expect(tester.getRect(toast()).width, 400);
  });
}
