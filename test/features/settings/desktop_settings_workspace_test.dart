import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/settings/desktop_settings_workspace.dart';

/// Verify the reference workspace's real hit areas and overflow behavior.
void main() {
  testWidgets(
    'wide sidebar back arrow precedes Settings and retains exit action',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var exits = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: DesktopSettingsWorkspace(
            title: 'Settings',
            selectedId: 'account',
            destinations: const [],
            onExit: () => exits++,
            child: const SizedBox.shrink(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final back = find.byTooltip('Back');
      expect(
        tester.getCenter(back).dx,
        lessThan(tester.getTopLeft(find.text('Settings')).dx),
      );
      await tester.tap(back);
      expect(exits, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('desktop form styling is scoped and preserves text input', (
    tester,
  ) async {
    final base = ThemeData.dark();
    final baseFilled = base.inputDecorationTheme.filled;
    var entered = '';
    await tester.pumpWidget(
      MaterialApp(
        theme: base,
        home: DesktopSettingsWorkspace(
          title: 'Settings',
          selectedId: 'account',
          destinations: const [],
          onExit: () {},
          child: Builder(
            builder: (context) {
              final input = Theme.of(context).inputDecorationTheme;
              expect(input.filled, isTrue);
              expect(
                (input.enabledBorder as OutlineInputBorder).borderRadius,
                BorderRadius.circular(12),
              );
              expect(
                (input.focusedBorder as OutlineInputBorder).borderSide.width,
                1.5,
              );
              return Padding(
                padding: const EdgeInsets.all(24),
                child: TextField(
                  decoration: const InputDecoration(labelText: 'Display name'),
                  onChanged: (value) => entered = value,
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'Desktop profile');
    await tester.pumpAndSettle();
    expect(entered, 'Desktop profile');
    expect(base.inputDecorationTheme.filled, baseFilled);
    expect(tester.takeException(), isNull);
  });

  for (final width in [320.0, 720.0, 1266.0, 2560.0]) {
    testWidgets('sidebar remains reachable at width $width and enlarged text', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var opens = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(2)),
            child: DesktopSettingsWorkspace(
              title: 'Settings',
              selectedId: 'account',
              onExit: () {},
              destinations: [
                for (final id in [
                  'account',
                  'sources',
                  'playback',
                  'reading',
                  'history',
                  'downloads',
                  'interface',
                  'advanced',
                  'about',
                ])
                  DesktopSettingsDestination(
                    id: id,
                    title: '$id with a longer translated label',
                    icon: Icons.settings_outlined,
                    onOpen: () => opens++,
                  ),
              ],
              child: const Center(child: Text('Content destination')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      const ids = [
        'account',
        'sources',
        'playback',
        'reading',
        'history',
        'downloads',
        'interface',
        'advanced',
        'about',
      ];
      for (var index = 0; index < ids.length; index++) {
        // Select category targets explicitly; Back is also an InkWell.
        final target = find.byKey(ValueKey('desktop-nav-${ids[index]}'));
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        final bounds = tester.getRect(target);
        expect(bounds.left, greaterThanOrEqualTo(0));
        expect(bounds.right, lessThanOrEqualTo(width));
        await tester.tap(target);
        await tester.pumpAndSettle();
        expect(opens, index + 1);
        expect(tester.takeException(), isNull);
      }
      expect(find.text('Content destination'), findsOneWidget);
    });
  }

  testWidgets('keyboard activates sidebar once without leaving workspace', (
    tester,
  ) async {
    var opens = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: DesktopSettingsWorkspace(
          title: 'Settings',
          selectedId: 'account',
          onExit: () {},
          destinations: [
            DesktopSettingsDestination(
              id: 'account',
              title: 'Account',
              icon: Icons.person_outline,
              onOpen: () => opens++,
            ),
          ],
          child: const Text('Content destination'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(opens, 1);
    expect(find.byType(DesktopSettingsWorkspace), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
