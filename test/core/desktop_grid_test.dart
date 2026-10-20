import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/ui/poster_card.dart';

void main() {
  for (final width in [1366.0, 800.0, 480.0]) {
    testWidgets('desktop posters keep sensible dimensions at $width', (tester) async {
      tester.view.physicalSize = Size(width, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: GridView.builder(
        padding: const EdgeInsets.all(24), gridDelegate: const DesktopPosterGridDelegate(), itemCount: 20,
        itemBuilder: (_, index) => ColoredBox(key: ValueKey(index), color: Colors.red),
      ))));
      final first = tester.getSize(find.byKey(const ValueKey(0)));
      expect(first.width, lessThanOrEqualTo(210));
      expect(first.height, lessThan(370));
      expect(tester.takeException(), isNull);
    });
  }
}
