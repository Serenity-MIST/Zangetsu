// search-6 Option B: on Windows each Sources row shows a pin button on hover
// (with a tooltip), so pinning no longer needs a long press. Phone keeps the
// display-only pin icon and long-press.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/playback/pinned_sources.dart';
import 'package:watch_app/features/search/browse_sources_list.dart';

import '../../support/picker_deps.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('browse_pin_hover');
    Hive.init(dir.path);
    await registerPickerDeps(aniyomi: [aniSource(id: 1, name: 'HiAnime')]);
    PinnedSources.notifier.value = const [];
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    PinnedSources.notifier.value = const [];
    await disposePickerDeps();
    await sl.reset();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  Widget harness() => MaterialApp(
    home: Scaffold(body: BrowseSourcesList(onBrowse: (_, _) {})),
  );

  double opacityOfPin(WidgetTester t) => t
      .widget<AnimatedOpacity>(
        find.ancestor(
          of: find.byKey(const ValueKey('browse-source-pin')),
          matching: find.byType(AnimatedOpacity),
        ),
      )
      .opacity;

  testWidgets('pin button appears on hover and pins the source', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await t.pumpWidget(harness());
    await t.pumpAndSettle();

    // Hidden until hovered: the row stays calm.
    expect(opacityOfPin(t), 0);

    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(t.getCenter(find.textContaining('HiAnime')));
    await t.pumpAndSettle();
    expect(opacityOfPin(t), 1);
    expect(find.byTooltip('Pin source'), findsOneWidget);

    await t.runAsync(() async {
      await t.tap(find.byKey(const ValueKey('browse-source-pin')));
    });
    await t.pumpAndSettle();
    expect(PinnedSources.isPinned('ani:1'), isTrue);
    expect(find.byTooltip('Unpin source'), findsOneWidget);
    // Let the pin's Hive write finish and release the box file before the
    // temp folder is deleted in tearDown.
    await t.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await Hive.close();
    });
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('pin button shows itself when it gets keyboard focus', (
    t,
  ) async {
    // Tab can reach the button; it must not take focus while invisible.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await t.pumpWidget(harness());
    await t.pumpAndSettle();
    expect(opacityOfPin(t), 0);
    final icon = find.descendant(
      of: find.byKey(const ValueKey('browse-source-pin')),
      matching: find.byType(Icon),
    );
    Focus.of(t.element(icon)).requestFocus();
    await t.pumpAndSettle();
    expect(opacityOfPin(t), 1);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('phone keeps the display-only pin (no button)', (t) async {
    await t.pumpWidget(harness());
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('browse-source-pin')), findsNothing);
  });
}
