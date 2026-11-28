import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/ui/animation_prefs.dart';
import 'package:watch_app/core/ui/reveal_item.dart';

/// Keeps a tap count so a test can see the card was moved, not rebuilt.
class _Card extends StatefulWidget {
  const _Card();
  @override
  State<_Card> createState() => _CardState();
}

class _CardState extends State<_Card> {
  int taps = 0;
  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () => setState(() => taps++),
    child: Text('taps:$taps'),
  );
}

void main() {
  late bool animations;
  setUp(() async {
    animations = AnimationPrefs.listAnimations;
    AnimationPrefs.listAnimations = true;
    await sl.reset();
    sl.registerSingleton<AppMode>(const AppMode(isTv: false));
  });
  tearDown(() async {
    AnimationPrefs.listAnimations = animations;
    await sl.reset();
  });

  Widget view() => const MaterialApp(
    home: Center(child: RevealItem(index: 0, child: _Card())),
  );

  testWidgets(
    'Windows drops the detector and wrappers after the reveal',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      await tester.pumpWidget(view());
      expect(find.byType(VisibilityDetector), findsOneWidget);
      final before = tester.state(find.byType(_Card));
      await tester.pumpAndSettle();
      expect(find.byType(VisibilityDetector), findsNothing);
      expect(find.byType(Opacity), findsNothing);
      // The card kept its own state object through the change.
      expect(identical(tester.state(find.byType(_Card)), before), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'phone keeps the reveal wrappers as before',
    variant: TargetPlatformVariant.only(TargetPlatform.android),
    (tester) async {
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      expect(find.byType(VisibilityDetector), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
