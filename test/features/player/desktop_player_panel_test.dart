import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:watch_app/core/desktop/desktop_reveal.dart';
import 'package:watch_app/features/player/player_screen.dart';

/// The phone grabber: a bare 36x4 box.
final Finder _grabber = find.byWidgetPredicate(
  (w) => w is SizedBox && w.width == 36 && w.height == 4,
);

/// Pumps a button that opens [open] from inside a Scaffold.
Future<void> _pumpOpener(
  WidgetTester tester,
  void Function(BuildContext) open,
) async {
  await tester.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => open(context),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  group('Windows in-player menus', () {
    test('menus dock on Windows only', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(playerMenusDocked, isTrue);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(playerMenusDocked, isFalse);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a list menu docks right over a light scrim, not a sheet', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      int? picked;
      await _pumpOpener(
        tester,
        (context) => showDesktopPlayerPanel<void>(
          context,
          builder: (ctx) => debugPlayerMenuList(
            'Video decoder',
            const ['Hardware+', 'Software'],
            active: 0,
            onSelect: (i) {
              picked = i;
              Navigator.pop(ctx);
            },
          ),
        ),
      );
      final panel = find.byKey(const ValueKey('player-desktop-panel'));
      expect(panel, findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(_grabber, findsNothing);
      expect(tester.widget<Dialog>(panel).alignment, Alignment.centerRight);
      // Docked against the right edge (24px inset), vertically centred.
      final rect = tester.getRect(
        find.descendant(of: panel, matching: find.byType(Material)).first,
      );
      expect(rect.right, 1280 - 24);
      expect(rect.width, 440);
      // Light scrim, so the video stays visible behind the menu.
      final barriers = tester.widgetList<ModalBarrier>(
        find.byType(ModalBarrier),
      );
      expect(barriers.last.color, Colors.black26);
      expect(find.byKey(const ValueKey('player-panel-close')), findsOneWidget);

      // Mouse click on a row picks it and closes the panel.
      await tester.tap(find.text('Software'));
      await tester.pumpAndSettle();
      expect(picked, 1);
      expect(panel, findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('Esc and the close button both close the panel', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await _pumpOpener(
        tester,
        (context) => showDesktopPlayerPanel<void>(
          context,
          builder: (_) => debugPlayerMenuChips('Playback speed', const [
            '0.5x',
            'Normal',
            '2.0x',
          ]),
        ),
      );
      final panel = find.byKey(const ValueKey('player-desktop-panel'));
      expect(panel, findsOneWidget);
      expect(_grabber, findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(panel, findsNothing);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(panel, findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('player-panel-close')));
      await tester.pumpAndSettle();
      expect(panel, findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });
  });

  testWidgets('Esc closes the panel ahead of the window-level Esc binding', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    var windowEsc = 0;
    await tester.pumpWidget(
      MaterialApp(
        // Stands in for DesktopWindow, whose Esc leaves fullscreen.
        builder: (context, child) => CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): () => windowEsc++,
          },
          child: Focus(autofocus: true, child: child!),
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDesktopPlayerPanel<void>(
                context,
                builder: (_) =>
                    debugPlayerMenuList('Sleep timer', const ['Off', '5 min']),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final panel = find.byKey(const ValueKey('player-desktop-panel'));
    expect(panel, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(panel, findsNothing);
    expect(windowEsc, 0);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('phone menu bodies keep the grabber and no close button', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: debugPlayerMenuList('Quality', const ['Auto', '1080p']),
        ),
      ),
    );
    expect(_grabber, findsOneWidget);
    expect(find.byKey(const ValueKey('player-panel-close')), findsNothing);
  });

  group('Windows snapshot', () {
    late Directory pictures;
    setUp(() async {
      pictures = await Directory.systemTemp.createTemp('zangetsu_pictures');
    });
    tearDown(() async {
      debugRevealOverride = null;
      if (await pictures.exists()) await pictures.delete(recursive: true);
    });

    test('name has no characters Windows forbids', () {
      final name = windowsSnapshotName(DateTime(2026, 11, 7, 4, 3, 2));
      expect(name, 'Zangetsu 2026-11-07 04.03.02.png');
      expect(name.contains(RegExp(r'[<>:"/\\|?*]')), isFalse);
    });

    test('saves under Pictures\\Zangetsu and never overwrites', () async {
      final at = DateTime(2026, 11, 17, 14, 3, 22);
      final first = await saveWindowsSnapshot(
        [1, 2, 3],
        picturesDir: pictures.path,
        now: at,
      );
      final second = await saveWindowsSnapshot(
        [4, 5],
        picturesDir: pictures.path,
        now: at,
      );
      expect(
        first.path,
        p.join(pictures.path, 'Zangetsu', 'Zangetsu 2026-11-17 14.03.22.png'),
      );
      expect(p.basename(second.path), 'Zangetsu 2026-11-17 14.03.22 (2).png');
      expect(await first.readAsBytes(), [1, 2, 3]);
      expect(await second.readAsBytes(), [4, 5]);
    });

    testWidgets('notice offers Show in folder, which selects the file', (
      tester,
    ) async {
      final file = (await tester.runAsync(
        () => saveWindowsSnapshot([9], picturesDir: pictures.path),
      ))!;
      String? revealed;
      bool? selected;
      debugRevealOverride = (path, {required select}) async {
        revealed = path;
        selected = select;
      };
      await _pumpOpener(
        tester,
        (context) => showSnapshotSavedNotice(context, file.path),
      );
      expect(find.byKey(const ValueKey('snapshot-saved')), findsOneWidget);
      expect(find.text(r'Screenshot saved to Pictures\Zangetsu'), findsOne);
      await tester.tap(find.text('Show in folder'));
      // revealInExplorer checks the file on disk before calling Explorer.
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
      }
      expect(revealed, p.windows.normalize(file.path));
      expect(selected, isTrue);
    });
  });
}
