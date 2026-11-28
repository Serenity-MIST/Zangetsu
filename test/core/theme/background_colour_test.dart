import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/desktop/desktop_chrome_colors.dart';
import 'package:watch_app/core/theme/app_colors.dart';
import 'package:watch_app/core/theme/theme_controller.dart';

void main() {
  test('light picks are clamped dark but keep their hue', () {
    final bg = ThemeController.darkened(const Color(0xFFFF0000));
    final hsv = HSVColor.fromColor(bg);
    expect(hsv.value, lessThan(0.43));
    expect(hsv.hue, closeTo(0, 0.5));
  });

  test('already-dark picks pass through untouched', () {
    const dark = Color(0xFF101018);
    expect(ThemeController.darkened(dark), dark);
  });

  test('the stock background is already safe', () {
    expect(ThemeController.darkened(AppColors.defaultBg), AppColors.defaultBg);
  });

  test('only real colour numbers are read back', () {
    expect(ThemeController.storedColour(0xFF101018), const Color(0xFF101018));
    expect(ThemeController.storedColour(null), isNull);
    expect(ThemeController.storedColour('0xFFFFFFFF'), isNull);
    expect(ThemeController.storedColour(4294967295.0), isNull);
    expect(ThemeController.storedColour(-1), isNull);
    expect(ThemeController.storedColour(0x1FFFFFFFF), isNull);
  });

  // The opaque background and defensive colour reads are Windows behaviour.
  group('on Windows', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.windows);
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('white, even see-through white, becomes a solid dark grey', () {
      for (final white in const [Color(0xFFFFFFFF), Color(0x00FFFFFF)]) {
        final bg = ThemeController.darkened(white);
        expect(bg.a, 1.0);
        expect(HSVColor.fromColor(bg).value, lessThan(0.43));
        expect(bg.computeLuminance(), lessThan(0.2));
      }
    });

    test('a see-through dark pick is made solid', () {
      expect(
        ThemeController.darkened(const Color(0x40101018)),
        const Color(0xFF101018),
      );
    });

    group('saved values', () {
      late Directory dir;

      setUp(() async {
        dir = await Directory.systemTemp.createTemp('theme_bg_test');
        Hive.init(dir.path);
        await Hive.openBox(ThemeController.boxName);
      });

      tearDown(() async {
        AppColors.bg = AppColors.defaultBg;
        AppColors.accent = AppColors.defaultAccent;
        await Hive.deleteFromDisk();
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });

      Future<void> apply(Map<String, Object?> values) async {
        final box = Hive.box(ThemeController.boxName);
        for (final e in values.entries) {
          await box.put(e.key, e.value);
        }
        await ThemeController.init();
      }

      test('a saved white background never makes the app light', () async {
        await apply({'backgroundColour': 0xFFFFFFFF});
        expect(AppColors.bg.a, 1.0);
        expect(AppColors.bg.computeLuminance(), lessThan(0.2));
        expect(DesktopChrome.canvas.computeLuminance(), lessThan(0.2));
        expect(DesktopChrome.frame.computeLuminance(), lessThan(0.2));
      });

      test('a see-through saved background is drawn solid', () async {
        await apply({'backgroundColour': 0x00FFFFFF});
        expect(AppColors.bg.a, 1.0);
        expect(DesktopChrome.canvas.a, 1.0);
        expect(AppColors.bg.computeLuminance(), lessThan(0.2));
      });

      test('a broken saved background falls back to the stock look', () async {
        await apply({'backgroundColour': 'white', 'accent': 1.5});
        expect(AppColors.bg, AppColors.defaultBg);
        expect(DesktopChrome.canvas, DesktopChrome.stockCanvas);
        expect(AppColors.accent, AppColors.defaultAccent);
      });

      test('a valid saved background still applies', () async {
        await apply({'backgroundColour': 0xFF101018});
        expect(AppColors.bg, const Color(0xFF101018));
      });
    });
  });
}
