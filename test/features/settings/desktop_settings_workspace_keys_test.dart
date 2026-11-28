import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/desktop_chrome_colors.dart';
import 'package:watch_app/core/theme/app_colors.dart';
import 'package:watch_app/core/ui/desktop_settings_row_target.dart';
import 'package:watch_app/core/ui/desktop_settings_surface.dart';
import 'package:watch_app/features/settings/desktop_settings_navigation.dart';
import 'package:watch_app/features/settings/desktop_settings_workspace.dart';
import 'package:watch_app/features/settings/settings_search_index.dart';

/// settings-workspace group: search matching (set-3), row reveal (set-2),
/// content width (set-4), hex colour input (set-5), sidebar keys (set-8),
/// frame-derived colours (set-9) and the shell-1 leave hook.
void main() {
  tearDown(() {
    DesktopSettingsRowTargets.debugReset();
    AppColors.bg = AppColors.defaultBg;
    DesktopSettingsNavigation.onLeave = null;
  });

  group('settingsQueryMatches (set-3)', () {
    test('Windows matches every word in any order', () {
      expect(
        settingsQueryMatches('Skip intro', 'intro skip', allWords: true),
        isTrue,
      );
      expect(
        settingsQueryMatches('Skip intro', 'intro  skip ', allWords: true),
        isTrue,
      );
      // Every word must appear somewhere.
      expect(
        settingsQueryMatches('Skip intro', 'intro outro', allWords: true),
        isFalse,
      );
    });

    test('phone keeps whole-phrase matching', () {
      expect(settingsQueryMatches('Skip intro', 'intro skip'), isFalse);
      expect(settingsQueryMatches('Skip intro', 'skip in'), isTrue);
    });
  });

  group('hex colours (set-5)', () {
    test('parses typed and pasted forms', () {
      const red = Color(0xFFE50914);
      expect(parseHexColor('#E50914'), red);
      expect(parseHexColor('e50914'), red);
      expect(parseHexColor(' #e5 09 14 '), red);
      expect(parseHexColor('0xFFE50914'), red);
      expect(parseHexColor('#FFF'), const Color(0xFFFFFFFF));
      expect(parseHexColor('#E5091'), isNull);
      expect(parseHexColor('red'), isNull);
      expect(formatHexColor(red), '#E50914');
    });

    testWidgets('typing a hex value reports the colour', (tester) async {
      Color? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(
                width: 320,
                child: GraphiteColorPickerBody(
                  initial: const Color(0xFF00FF00),
                  onChanged: (c) => picked = c,
                ),
              ),
            ),
          ),
        ),
      );
      final field = find.byKey(const ValueKey('graphite-hex-field'));
      // The field shows the current value.
      expect(find.text('#00FF00'), findsOneWidget);
      await tester.enterText(field, '#E50914');
      await tester.pump();
      expect(picked, const Color(0xFFE50914));
      // A bad value only errors on submit and changes nothing.
      await tester.enterText(field, 'zz');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.text('Enter a colour like #E50914'), findsOneWidget);
      expect(picked, const Color(0xFFE50914));
      expect(find.byTooltip('Paste colour'), findsOneWidget);
    });

    // Paste reads the clipboard: a valid colour is applied and reformatted,
    // anything else shows the error and keeps the last colour.
    testWidgets('Paste applies a clipboard colour', (tester) async {
      var clip = ' 3366ff ';
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => call.method == 'Clipboard.getData'
            ? <String, dynamic>{'text': clip}
            : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      Color? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(
                width: 320,
                child: GraphiteColorPickerBody(
                  initial: const Color(0xFF00FF00),
                  onChanged: (c) => picked = c,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Paste colour'));
      await tester.pump();
      expect(picked, const Color(0xFF3366FF));
      expect(find.text('#3366FF'), findsOneWidget);
      clip = 'not a colour at all';
      await tester.tap(find.byTooltip('Paste colour'));
      await tester.pump();
      expect(find.text('Enter a colour like #E50914'), findsOneWidget);
      expect(picked, const Color(0xFF3366FF));
    });
  });

  group('GraphiteSettingsColors (set-9)', () {
    test('stock background keeps the original greys', () {
      expect(GraphiteSettingsColors.panelGradient, const [
        Color(0xFF1B1C20),
        Color(0xFF141519),
      ]);
      expect(GraphiteSettingsColors.searchFill, const Color(0xFF14141C));
    });

    test('Pure black derives from the black frame, not fixed greys', () {
      AppColors.bg = const Color(0xFF000000);
      final frame = DesktopChrome.frame;
      final panel = GraphiteSettingsColors.panelGradient.first;
      expect(panel, isNot(const Color(0xFF1B1C20)));
      // A small lift of the frame: close to black.
      expect(panel, Color.lerp(frame, Colors.white, .05));
      expect((panel.r * 255).round(), lessThan(0x1B));
    });
  });

  testWidgets('panels cap at the content width inside settings (set-4)', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(2400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DesktopSettingsScope(
            child: GraphiteSettingsPanel(
              key: ValueKey('panel'),
              margin: EdgeInsets.zero,
              children: [SizedBox(height: 40)],
            ),
          ),
        ),
      ),
    );
    final width = tester
        .getSize(
          find
              .descendant(
                of: find.byKey(const ValueKey('panel')),
                matching: find.byType(Container),
              )
              .first,
        )
        .width;
    expect(width, kDesktopSettingsContentMaxWidth);
    // Left-aligned, like Windows Settings.
    expect(tester.getTopLeft(find.byType(Container).first).dx, 0);
  });

  testWidgets('a requested row scrolls into view and takes focus (set-2)', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    DesktopSettingsRowTargets.request(title: 'Row 30');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopSettingsScope(
            child: DesktopSettingsRowSeeker(
              child: ListView(
                children: [
                  for (var i = 0; i < 40; i++)
                    GraphiteSettingsControl(
                      icon: Icons.tune,
                      title: 'Row $i',
                      onTap: () {},
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    // Let the seeker step down and the row reveal itself.
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(seconds: 2));
    expect(DesktopSettingsRowTargets.hasPending, isFalse);
    final row = find.widgetWithText(GraphiteSettingsControl, 'Row 30');
    expect(row, findsOneWidget);
    // On screen...
    final top = tester.getTopLeft(row).dy;
    expect(top, inInclusiveRange(0, 600));
    // ...and focused (the row's own InkWell).
    final focused = FocusManager.instance.primaryFocus?.context;
    expect(focused, isNotNull);
    expect(
      find.descendant(of: row, matching: find.byWidget(focused!.widget)),
      findsOneWidget,
    );
  });

  test('a request expires once claimed', () {
    DesktopSettingsRowTargets.request(id: 'x', title: 'Autoplay');
    expect(DesktopSettingsRowTargets.claim(title: 'Other'), isFalse);
    expect(DesktopSettingsRowTargets.claim(title: '  autoplay '), isTrue);
    expect(DesktopSettingsRowTargets.claim(title: 'Autoplay'), isFalse);
  });

  group('sidebar keys (set-8 / set-3)', () {
    Future<List<String>> pumpWorkspace(
      WidgetTester tester, {
      required ValueNotifier<String> selected,
      VoidCallback? onSearch,
    }) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final opened = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<String>(
            valueListenable: selected,
            builder: (context, id, _) => DesktopSettingsWorkspace(
              title: 'Settings',
              selectedId: id,
              onExit: () {},
              onSearchShortcut: onSearch,
              search: const TextField(key: ValueKey('search')),
              destinations: [
                for (final s in const ['account', 'sources', 'playback'])
                  DesktopSettingsDestination(
                    id: s,
                    title: s,
                    icon: Icons.circle,
                    onOpen: () {
                      opened.add(s);
                      selected.value = s;
                    },
                  ),
              ],
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return opened;
    }

    testWidgets('Down / Up move through the sidebar', (tester) async {
      final selected = ValueNotifier('account');
      final opened = await pumpWorkspace(tester, selected: selected);
      await tester.tap(find.byKey(const ValueKey('desktop-nav-account')));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(opened, ['account', 'sources', 'playback', 'sources']);
      expect(selected.value, 'sources');
    });

    testWidgets('Ctrl+number jumps and Ctrl+F / Ctrl+K search', (tester) async {
      final selected = ValueNotifier('account');
      var searches = 0;
      final opened = await pumpWorkspace(
        tester,
        selected: selected,
        onSearch: () => searches++,
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(opened, ['playback']);
      expect(searches, 2);
      // The search box sits in the sidebar on a wide window.
      expect(find.byKey(const ValueKey('search')), findsOneWidget);
    });
  });

  test('leave() uses the shell handler when one is installed (shell-1)', () {
    expect(DesktopSettingsNavigation.leave(), isFalse);
    var left = 0;
    DesktopSettingsNavigation.onLeave = () => left++;
    expect(DesktopSettingsNavigation.leave(), isTrue);
    expect(left, 1);
  });
}
