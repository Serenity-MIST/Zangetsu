import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:ui' show PointerDeviceKind, SemanticsFlag;
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/settings/desktop_settings_category_grid.dart';
import 'package:watch_app/features/settings/desktop_settings_header.dart';
import 'package:watch_app/features/settings/desktop_settings_profile.dart';

/// Exercise rendered geometry and input, rather than mirroring column math.
void main() {
  for (final width in [320.0, 720.0]) {
    testWidgets('header and profile remain usable at width $width', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var opens = 0;
      var backs = 0;
      const title = 'Profiles and account with a longer translated label';
      const detail =
          'Watching as a profile with a long display name · '
          'a-long-account-name@example.invalid';
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Scaffold(
              appBar: DesktopSettingsHeader(
                'A longer settings destination title',
                showBack: true,
                onBack: () => backs++,
              ),
              body: SingleChildScrollView(
                child: DesktopSettingsProfile(
                  avatar: const CircleAvatar(radius: 22),
                  title: title,
                  subtitle: detail,
                  onOpen: () => opens++,
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final profile = find.byType(DesktopSettingsProfile);
      await tester.ensureVisible(find.text(detail));
      await tester.pumpAndSettle();
      final bounds = tester.getRect(profile);
      expect(bounds.left, greaterThanOrEqualTo(0));
      expect(bounds.right, lessThanOrEqualTo(width));
      // Revealing the long subtitle can scroll the title behind the toolbar.
      // Bring the intended hit target back into view before clicking it.
      await tester.ensureVisible(find.text(title));
      await tester.pumpAndSettle();
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      expect(opens, 1);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(backs, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('hover enlarges only its card and respects reduced motion', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final reduced = ValueNotifier(false);
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<bool>(
            valueListenable: reduced,
            builder: (context, value, _) => MediaQuery(
              data: MediaQueryData(disableAnimations: value),
              child: Scaffold(
                body: DesktopSettingsCategoryGrid(
                  categories: [
                    for (final id in ['first', 'second'])
                      DesktopSettingsCategory(
                        id: id,
                        title: id,
                        summary: 'Settings',
                        icon: Icons.settings_outlined,
                        onOpen: () {},
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      final first = find.byKey(const ValueKey('desktop-settings-first'));
      final second = find.byKey(const ValueKey('desktop-settings-second'));
      final initial = tester.getRect(first);
      final neighbor = tester.getRect(second);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(initial.center);
      await tester.pumpAndSettle();
      expect(tester.getRect(first).width, greaterThan(initial.width));
      expect(tester.getRect(first).top, lessThan(initial.top));
      expect(tester.getRect(second), neighbor);
      reduced.value = true;
      await tester.pumpAndSettle();
      expect(tester.getRect(first), initial);
      await mouse.removePointer();
      expect(tester.takeException(), isNull);
    } finally {
      reduced.dispose();
    }
  });

  for (final width in [320.0, 720.0, 1366.0, 2560.0]) {
    testWidgets('cards remain reachable at width $width with enlarged text', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var opens = 0;
      final categories = List.generate(
        9,
        (index) => DesktopSettingsCategory(
          id: '$index',
          title: 'Settings category $index with a longer title',
          summary: 'A readable description that wraps when space is limited.',
          icon: Icons.settings_outlined,
          onOpen: () => opens++,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(width, 900),
              textScaler: TextScaler.linear(2),
            ),
            child: Scaffold(
              body: SingleChildScrollView(
                child: DesktopSettingsCategoryGrid(categories: categories),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      for (var index = 0; index < categories.length; index++) {
        final card = find.byKey(ValueKey('desktop-settings-$index'));
        await tester.ensureVisible(card);
        await tester.pumpAndSettle();
        final bounds = tester.getRect(card);
        expect(bounds.left, greaterThanOrEqualTo(0));
        expect(bounds.right, lessThanOrEqualTo(width));
        // Empty padding is part of the button, not just its text/icon.
        await tester.tapAt(bounds.topLeft + const Offset(10, 10));
        await tester.pump();
        expect(opens, index + 1);
        expect(tester.takeException(), isNull);
      }
    });
  }

  testWidgets('Tab and Enter activate a category once', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      var opens = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DesktopSettingsCategoryGrid(
              categories: [
                DesktopSettingsCategory(
                  id: 'playback',
                  title: 'Playback',
                  summary: 'Quality, audio and subtitles',
                  icon: Icons.play_circle_outline,
                  onOpen: () => opens++,
                ),
              ],
            ),
          ),
        ),
      );
      expect(
        tester
            .getSemantics(
              find.byKey(const ValueKey('desktop-settings-playback')),
            )
            .hasFlag(SemanticsFlag.isButton),
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(opens, 1);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });
}
