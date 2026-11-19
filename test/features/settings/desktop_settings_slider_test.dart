import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/settings/desktop_settings_slider.dart';

/// Covers the shared Windows settings slider row: value text with its unit
/// and default, the live preview while dragging, and one save per release.
void main() {
  /// Pumps one slider row on a wide surface, recording saves and live moves.
  Future<({List<double> saves, List<double> moves})> pumpRow(
    WidgetTester tester, {
    bool withPreview = true,
  }) async {
    final saves = <double>[];
    final moves = <double>[];
    tester.view.physicalSize = const Size(1200, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              DesktopSettingsSlider(
                sliderKey: const ValueKey('test-slider'),
                valueKey: const ValueKey('test-value'),
                icon: Icons.format_size_rounded,
                title: 'Font size',
                value: 16,
                min: 10,
                max: 40,
                divisions: 30,
                format: (v) => '${v.round()}',
                unit: (_) => 'px',
                defaultValue: 16,
                onChanged: moves.add,
                onChangeEnd: saves.add,
                preview: withPreview
                    ? (_, v) => DesktopSliderPreviews.fontSize(v)
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
    return (saves: saves, moves: moves);
  }

  testWidgets('shows the value, its unit and the default', (tester) async {
    await pumpRow(tester);
    expect(find.text('Font size'), findsOneWidget);
    // The bare number is its own text so it can be found and read aloud.
    expect(find.byKey(const ValueKey('test-value')), findsOneWidget);
    expect(find.text('16'), findsOneWidget);
    expect(find.text(' px'), findsOneWidget);
    expect(find.text('  ·  Default: 16 px'), findsOneWidget);
    // The preview stays closed until the slider is adjusted.
    expect(find.byKey(const ValueKey('preview-font-size')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('preview follows the drag and onChangeEnd fires once', (
    tester,
  ) async {
    final calls = await pumpRow(tester);
    final slider = find.byKey(const ValueKey('test-slider'));
    final gesture = await tester.startGesture(tester.getCenter(slider));
    await tester.pump();
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    // Mid-drag: the live sample is open and sized to the dragged value.
    final preview = find.byKey(const ValueKey('preview-font-size'));
    expect(preview, findsOneWidget);
    final value = double.parse(
      tester.widget<Text>(find.byKey(const ValueKey('test-value'))).data!,
    );
    expect(value, greaterThan(25));
    final sample = tester.widget<Text>(
      find.descendant(of: preview, matching: find.text('Aa')),
    );
    expect(sample.style!.fontSize, value);
    // Nothing saved while dragging.
    expect(calls.saves, isEmpty);
    expect(calls.moves, isNotEmpty);

    await gesture.up();
    await tester.pumpAndSettle();
    // One save on release, snapped onto a whole step.
    expect(calls.saves, hasLength(1));
    expect(calls.saves.single, calls.saves.single.roundToDouble());
    expect(calls.saves.single, value);
    // The preview closes once the drag ends.
    expect(find.byKey(const ValueKey('preview-font-size')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('margin and line-height samples keep a narrow page on a wide row', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // Stretched like the row's preview slot, so a tight width reaches them.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DesktopSliderPreviews.margin(40),
              DesktopSliderPreviews.lineHeight(2),
            ],
          ),
        ),
      ),
    );
    // The page outline stays 260 wide, so a 40px inset is clearly visible.
    expect(
      tester.getSize(find.byKey(const ValueKey('preview-margin'))).width,
      260,
    );
    // The sample wraps onto 3 lines (13px x 2.0 each), showing the spacing.
    expect(
      tester.getSize(find.byKey(const ValueKey('preview-line-height'))).height,
      closeTo(13 * 2 * 3, 1),
    );
  });

  testWidgets('a new stored value from the caller is shown', (tester) async {
    Widget row(double value) => MaterialApp(
      home: Scaffold(
        body: DesktopSettingsSlider(
          valueKey: const ValueKey('v'),
          icon: Icons.timer_outlined,
          title: 'Jump',
          value: value,
          min: 1,
          max: 10,
          divisions: 9,
          format: (v) => '${v.round()}',
          onChangeEnd: (_) {},
        ),
      ),
    );
    await tester.pumpWidget(row(3));
    expect(find.text('3'), findsOneWidget);
    await tester.pumpWidget(row(7));
    expect(find.text('7'), findsOneWidget);
    // No unit and no default given: neither is printed.
    expect(find.textContaining('Default'), findsNothing);
  });
}
