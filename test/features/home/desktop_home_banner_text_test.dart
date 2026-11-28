import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/ui/desktop_media_card.dart';
import 'package:watch_app/features/home/desktop_home_page.dart';

const _long =
    'A very long description that keeps going for many words so that it '
    'needs far more than three lines in a narrow banner text box, and then '
    'keeps going even further past that point to be sure it overflows.';

void main() {
  // The banner description shows whole lines only: as many as the height
  // allows (up to three), never half a line cut off at the bottom.
  for (final height in [10.0, 20.0, 40.0, 54.0, 80.0]) {
    testWidgets(
      'banner description fits whole lines in $height px',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 160,
                height: height,
                child: const Align(
                  alignment: Alignment.topLeft,
                  child: DesktopWholeLineText(
                    _long,
                    maxLines: 3,
                    style: TextStyle(fontSize: 12, height: 1.5),
                  ),
                ),
              ),
            ),
          ),
        );
        final text = find.byType(Text);
        if (height < 18) {
          // Not even one line fits: nothing is drawn.
          expect(text, findsNothing);
        } else {
          final lines = tester.widget<Text>(text).maxLines!;
          expect(lines, (height / 18).floor().clamp(1, 3));
          expect(tester.widget<Text>(text).overflow, TextOverflow.ellipsis);
          // The laid-out text never runs past the box.
          expect(tester.getSize(text).height, lessThanOrEqualTo(height));
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  test('portrait desktop cards are poster shaped (2:3)', () {
    expect(DesktopMediaCard.height(100, 1, titleInside: true), 150);
    expect(DesktopMediaCard.height(160, 1, wide: true, titleInside: true), 90);
  });
}
