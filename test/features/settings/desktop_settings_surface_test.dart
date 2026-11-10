import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/ui/desktop_settings_surface.dart';
import 'package:watch_app/core/ui/settings_widgets.dart';

/// Nested presentation must not change preference ownership or cancel behavior.
void main() {
  testWidgets('multi-choice toggles in place and keeps edits on close', (
    tester,
  ) async {
    final selected = <String>{'a'};
    var closed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: TextButton(
                onPressed: () async {
                  await showGraphiteSettingsMultiChoice<String>(
                    context,
                    title: 'Player info',
                    description: 'Choose overlay fields',
                    options: const [('a', 'Title'), ('b', 'Quality')],
                    selected: selected,
                  );
                  closed = true;
                },
                child: const Text('Open'),
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Title'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Quality'));
    await tester.pumpAndSettle();
    expect(selected, {'b'});
    expect(find.byType(Dialog), findsOneWidget);
    expect(closed, isFalse);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(selected, {'b'});
  });

  testWidgets('font choices retain loaded previews and download hints', (
    tester,
  ) async {
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: TextButton(
                onPressed: () async {
                  selected = await showGraphiteSettingsChoice<String>(
                    context,
                    title: 'App font',
                    current: 'Bundled',
                    options: const [
                      ('Bundled', 'Bundled face'),
                      ('Remote', 'Remote face'),
                    ],
                    optionDescriptions: const {
                      'Remote': 'Downloads on first use',
                    },
                    previewFontFamilies: const {'Bundled': 'Bundled'},
                    downloadableOptions: const {'Remote'},
                  );
                },
                child: const Text('Choose font'),
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('Choose font'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.text('Bundled face')).style?.fontFamily,
      'Bundled',
    );
    expect(
      tester.widget<Text>(find.text('Remote face')).style?.fontFamily,
      isNot('Remote'),
    );
    expect(find.text('Downloads on first use'), findsOneWidget);
    expect(find.byIcon(Icons.download_outlined), findsOneWidget);
    await tester.tap(find.text('Remote face'));
    await tester.pumpAndSettle();
    expect(selected, 'Remote');
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop surfaces are opt-in and leave unscoped rows alone', (
    tester,
  ) async {
    const row = SettingsCard(
      children: [
        SettingsTile(icon: Icons.settings_outlined, title: 'A preference'),
      ],
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: DesktopSettingsScope(child: row)),
      ),
    );
    expect(find.byType(GraphiteSettingsPanel), findsOneWidget);
    expect(find.byType(GraphiteSettingsControl), findsOneWidget);
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: row)));
    expect(find.byType(GraphiteSettingsPanel), findsNothing);
    expect(find.byType(GraphiteSettingsControl), findsNothing);
  });

  testWidgets('nested values and long labels wrap at enlarged text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: SingleChildScrollView(
              child: DesktopSettingsScope(
                child: SettingsCard(
                  children: [
                    SettingsTile(
                      icon: Icons.settings_outlined,
                      title: 'A longer translated preference title',
                      subtitle:
                          'The explanation stays readable instead of being truncated.',
                      trailing: const Text('A longer selected value'),
                      onTap: () => taps++,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('A longer translated preference title'));
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(tester.takeException(), isNull);
  });

  for (final cancel in [false, true]) {
    testWidgets(
      'choice dialog ${cancel ? 'cancels safely' : 'selects from a long list'}',
      (tester) async {
        var selected = -1;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    final result = await showGraphiteSettingsChoice<int>(
                      context,
                      title: 'Choose a preference',
                      current: 0,
                      options: List.generate(
                        40,
                        (index) => (index, 'Option $index'),
                      ),
                    );
                    if (result != null) selected = result;
                  },
                  child: const Text('Open choice'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open choice'));
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsNothing);
        if (cancel) {
          await tester.tap(find.byTooltip('Close'));
        } else {
          await tester.scrollUntilVisible(
            find.text('Option 39'),
            250,
            scrollable: find.byType(Scrollable).last,
          );
          await tester.tap(find.text('Option 39'));
        }
        await tester.pumpAndSettle();
        expect(selected, cancel ? -1 : 39);
        expect(find.byType(Dialog), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('Escape dismisses a choice without selecting a value', (
    tester,
  ) async {
    int? result = 99;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async =>
                  result = await showGraphiteSettingsChoice<int>(
                    context,
                    title: 'Choose',
                    current: 0,
                    options: [(0, 'Option zero')],
                  ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(find.byType(Dialog), findsNothing);
  });
}
