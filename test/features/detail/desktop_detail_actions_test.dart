import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/detail/desktop_detail_actions.dart';

void main() {
  for (final width in [360.0, 900.0]) {
    testWidgets('title controls remain usable at width $width', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var played = false;
      var downloaded = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DesktopDetailActions(
              play: SizedBox(
                height: 40,
                child: TextButton(
                  onPressed: () => played = true,
                  child: const Text('Continue E1'),
                ),
              ),
              download: SizedBox(
                height: 40,
                child: TextButton(
                  onPressed: () => downloaded = true,
                  child: const Text('Download E1'),
                ),
              ),
              source: const SizedBox(height: 40, child: Text('Auto Resolve')),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final play = tester.getTopLeft(find.text('Continue E1'));
      final source = tester.getTopLeft(find.text('Auto Resolve'));
      if (width < 680) {
        expect(source.dy, greaterThan(play.dy));
      } else {
        expect(source.dx, greaterThan(play.dx));
      }
      await tester.tap(find.text('Continue E1'));
      await tester.tap(find.text('Download E1'));
      expect(played, isTrue);
      expect(downloaded, isTrue);
    });
  }
}
