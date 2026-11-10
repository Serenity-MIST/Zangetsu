import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/ui/banner_style.dart';
import 'package:watch_app/core/ui/desktop_settings_surface.dart';
import 'package:watch_app/core/ui/splash_style.dart';
import 'package:watch_app/features/settings/app_face_screen.dart';

/// Desktop identity controls retain real style stores without native icon calls.
void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('desktop_app_face_');
    Hive.init(directory.path);
    await Hive.openBox(SplashStyle.boxName);
    BannerStyle.current.value = BannerStyle.selectedId;
    sl.registerSingleton<AppMode>(const AppMode(isTv: false));
  });
  tearDown(() async {
    await sl.reset();
    await Hive.close();
    await directory.delete(recursive: true);
  });

  testWidgets(
    'desktop styles persist and preview is not continuously animating',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: DesktopSettingsScope(child: AppFaceScreen())),
      );
      await tester.pumpAndSettle();
      expect(find.text('Windows app icon'), findsOneWidget);
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.ensureVisible(
        find.byKey(const ValueKey('desktop-splash-bankai')),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('desktop-splash-bankai')));
        await Hive.box(SplashStyle.boxName).flush();
      });
      await tester.pumpAndSettle();
      expect(SplashStyle.selectedId, 'bankai');
      expect(tester.binding.hasScheduledFrame, isFalse);
      final edge = find.byKey(const ValueKey('desktop-banner-edge'));
      await tester.ensureVisible(edge);
      await tester.runAsync(() async {
        await tester.tap(edge);
        await Hive.box(SplashStyle.boxName).flush();
      });
      await tester.pumpAndSettle();
      expect(BannerStyle.current.value, 'edge');
      await tester.runAsync(() async {
        await Hive.box(SplashStyle.boxName).close();
        await Hive.openBox(SplashStyle.boxName);
      });
      expect(SplashStyle.selectedId, 'bankai');
      expect(BannerStyle.selectedId, 'edge');
      final preview = find.byKey(const ValueKey('desktop-splash-preview'));
      await tester.ensureVisible(preview);
      await tester.tap(preview);
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.binding.hasScheduledFrame, isTrue);
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'desktop identity fits narrow text2 and respects reduced motion',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              textScaler: TextScaler.linear(2),
              disableAnimations: true,
            ),
            child: DesktopSettingsScope(child: AppFaceScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final preview = find.byKey(const ValueKey('desktop-splash-preview'));
      await tester.ensureVisible(preview);
      await tester.tap(preview);
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);
      final banner = find.byKey(const ValueKey('desktop-banner-panels'));
      await tester.ensureVisible(banner);
      await tester.pumpAndSettle();
      expect(banner.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
