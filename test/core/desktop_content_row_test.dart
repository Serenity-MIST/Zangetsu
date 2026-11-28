import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/ui/animation_prefs.dart';
import 'package:watch_app/core/ui/content_row.dart';

void main() {
  testWidgets(
    'wheel over a home rail scrolls the page; mouse drag still browses the rail',
    (tester) async {
      sl.registerSingleton(const AppMode(isTv: false));
      final animations = AnimationPrefs.listAnimations;
      AnimationPrefs.listAnimations = false;
      final page = ScrollController();
      addTearDown(() {
        page.dispose();
        AnimationPrefs.listAnimations = animations;
        sl.unregister<AppMode>();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              controller: page,
              child: Column(
                children: [
                  ContentRow(
                    title: 'Continue Reading',
                    itemWidth: 236,
                    itemHeight: 76,
                    itemCount: 10,
                    itemBuilder: (_, index) =>
                        ColoredBox(key: ValueKey(index), color: Colors.red),
                  ),
                  const SizedBox(height: 1600),
                ],
              ),
            ),
          ),
        ),
      );
      final before = tester.getTopLeft(find.byKey(const ValueKey(0)));
      final size = tester.getSize(find.byKey(const ValueKey(0)));
      expect(size.width / size.height, closeTo(236 / 76, 0.01));
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: before + const Offset(50, 40),
          scrollDelta: const Offset(0, 60),
        ),
      );
      await tester.pumpAndSettle();
      expect(page.offset, greaterThan(0));
      expect(tester.getTopLeft(find.byKey(const ValueKey(0))).dx, before.dx);
      page.jumpTo(0);
      await tester.pump();
      await tester.dragFrom(
        before + const Offset(200, 40),
        const Offset(-150, 0),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.byKey(const ValueKey(0))).dx,
        lessThan(before.dx),
      );
      expect(page.offset, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
