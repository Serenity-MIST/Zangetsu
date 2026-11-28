// Windows player input pieces shared by both layouts: instant click /
// double-click on the video, the right-click hook, wheel-to-volume over the
// video only, the keyboard / wheel feedback controller and the tiny frame
// the ambient glow samples. No app wiring, so these run on their own.
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/player/desktop_ambient_frame.dart';
import 'package:watch_app/features/player/desktop_player_hud.dart';
import 'package:watch_app/features/player/desktop_video_click.dart';

/// A mouse click (down + up) at [at].
Future<void> _click(
  WidgetTester tester,
  Offset at, {
  int buttons = kPrimaryMouseButton,
}) async {
  final g = await tester.startGesture(
    at,
    kind: PointerDeviceKind.mouse,
    buttons: buttons,
  );
  await g.up();
}

void main() {
  group('DesktopVideoClick', () {
    test('first click toggles at once; a quick second undoes it', () {
      var now = DateTime(2026);
      final click = DesktopVideoClick(clock: () => now);
      var toggles = 0, doubles = 0;
      void tap() =>
          click.click(onSingle: () => toggles++, onDouble: () => doubles++);
      tap();
      expect(toggles, 1, reason: 'no 300ms wait for a possible double');
      now = now.add(const Duration(milliseconds: 150));
      tap();
      // Toggled back to how it was, then the double-click action.
      expect(toggles, 2);
      expect(doubles, 1);
      // A slow third click is a fresh single click.
      now = now.add(const Duration(seconds: 1));
      tap();
      expect(toggles, 3);
      expect(doubles, 1);
    });

    test('a click while loading does not toggle but still pairs', () {
      var now = DateTime(2026);
      final click = DesktopVideoClick(clock: () => now);
      var toggles = 0, doubles = 0;
      click.click(
        onSingle: () => toggles++,
        onDouble: () => doubles++,
        canToggle: false,
      );
      now = now.add(const Duration(milliseconds: 100));
      click.click(onSingle: () => toggles++, onDouble: () => doubles++);
      expect(toggles, 0, reason: 'nothing to undo');
      expect(doubles, 1);
    });
  });

  group('DesktopVideoPointer', () {
    testWidgets('click toggles, right-click asks for the menu, drag is no '
        'click', (tester) async {
      var toggles = 0, doubles = 0;
      Offset? menuAt;
      Offset? dragFrom;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: DesktopVideoPointer(
            onToggle: () => toggles++,
            onDoubleClick: () => doubles++,
            onContextMenu: (p) => menuAt = p,
            onDragStart: (p) => dragFrom = p,
          ),
        ),
      );
      await _click(tester, const Offset(100, 100));
      expect(toggles, 1);

      await _click(
        tester,
        const Offset(200, 120),
        buttons: kSecondaryMouseButton,
      );
      expect(menuAt, const Offset(200, 120));
      expect(toggles, 1, reason: 'right-click never toggles playback');

      // Wait out the double-click window, then drag.
      await tester.pump(const Duration(seconds: 1));
      final g = await tester.startGesture(
        const Offset(50, 50),
        kind: PointerDeviceKind.mouse,
      );
      await g.moveBy(const Offset(40, 0));
      await g.up();
      expect(dragFrom, const Offset(50, 50));
      expect(toggles, 1);
      expect(doubles, 0);
    });
  });

  group('DesktopVideoWheel', () {
    testWidgets('wheel over the video steps volume; the list stays put', (
      tester,
    ) async {
      final steps = <int>[];
      final list = ScrollController();
      addTearDown(list.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ListView(
            controller: list,
            children: [
              DesktopVideoWheel(
                onStep: steps.add,
                child: const SizedBox(key: ValueKey('video'), height: 300),
              ),
              const SizedBox(height: 2000),
            ],
          ),
        ),
      );
      final video = tester.getCenter(find.byKey(const ValueKey('video')));
      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(video));
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, -40)));
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 40)));
      await tester.pump();
      expect(steps, [1, -1]);
      expect(list.offset, 0, reason: 'the video claimed the wheel');

      // Below the video the wheel scrolls the page again.
      await tester.sendEventToBinding(mouse.hover(const Offset(400, 500)));
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 60)));
      await tester.pump();
      expect(steps, [1, -1]);
      expect(list.offset, greaterThan(0));
    });
  });

  group('DesktopHudController', () {
    test('seeks in one direction add up; volume carries its level', () {
      final hud = DesktopHudController();
      addTearDown(hud.dispose);
      hud.showSeek(10);
      hud.showSeek(10);
      expect(hud.value!.kind, DesktopHudKind.seek);
      expect(hud.value!.seekSeconds, 20);
      hud.showSeek(-10);
      expect(hud.value!.seekSeconds, -10, reason: 'direction flip restarts');
      hud.showVolume(35);
      expect(hud.value!.kind, DesktopHudKind.volume);
      expect(hud.value!.volume, 35);
    });
  });

  group('ambient glow frame', () {
    test('a raw BGRA frame shrinks to a tiny BMP of its average colour', () {
      // 64x36 solid frame: B=10, G=20, R=200, padding byte 0.
      const w = 64, h = 36;
      final raw = Uint8List(w * h * 4);
      for (var i = 0; i < raw.length; i += 4) {
        raw[i] = 10;
        raw[i + 1] = 20;
        raw[i + 2] = 200;
      }
      final bmp = downscaleBgraToBmp(raw, w, h)!;
      expect(bmp[0], 0x42); // 'B'
      expect(bmp[1], 0x4D); // 'M'
      final d = ByteData.sublistView(bmp);
      expect(d.getInt32(18, Endian.little), 32); // 32px wide
      expect(d.getInt32(22, Endian.little), -18); // top-down, 16:9 kept
      // First pixel keeps the colour and is forced opaque.
      expect(bmp.sublist(122, 126), [10, 20, 200, 255]);
      // Under 3KB instead of a full-resolution JPEG.
      expect(bmp.length, lessThan(3000));
    });

    test('a padded stride is handled; a wrong size is refused', () {
      // 10px rows padded to 48 bytes (mpv aligns some sizes).
      expect(bgraStride(48 * 4, 10, 4), 48);
      expect(bgraStride(10 * 4 * 4, 10, 4), 40);
      expect(bgraStride(7, 10, 4), isNull);
      expect(downscaleBgraToBmp(Uint8List(100), 1920, 1080), isNull);
    });
  });
}
