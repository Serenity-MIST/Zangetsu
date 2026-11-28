import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/desktop/desktop_oauth.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/tracker/simkl_service.dart';
import 'package:watch_app/core/ui/desktop_settings_surface.dart';
import 'package:watch_app/features/settings/tracker_settings_screen.dart';

/// Windows tracker page: graphite rows, a cancellable sign-in, a visible
/// failure reason, and a whole-row auto-sync toggle, at both desktop sizes.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const window = MethodChannel('com.spyou.zangetsu/window');
  const launcher = MethodChannel('plugins.flutter.io/url_launcher');
  const links = MethodChannel('com.llfbandit.app_links/messages');
  const events = MethodChannel('com.llfbandit.app_links/events');
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tracker_desktop');
    Hive.init(dir.path);
    await SimklService.init();
    sl.registerSingleton<AppMode>(const AppMode(isTv: false));
    DesktopOAuth.debugIsWindowsHost = true;
    for (final c in [window, links, events]) {
      messenger.setMockMethodCallHandler(c, (_) async => null);
    }
    // The browser opens but never returns.
    messenger.setMockMethodCallHandler(launcher, (_) async => true);
  });

  tearDown(() async {
    DesktopOAuth.debugIsWindowsHost = null;
    for (final c in [window, launcher, links, events]) {
      messenger.setMockMethodCallHandler(c, null);
    }
    await sl.reset();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  for (final size in const [Size(1280, 720), Size(1920, 1080)]) {
    testWidgets('desktop tracker page at ${size.width.toInt()}', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final service = SimklService(Dio());
      await tester.pumpWidget(
        MaterialApp(
          home: DesktopSettingsScope(
            child: TrackerSettingsScreen(tracker: service),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Graphite header and rows, no phone card.
      expect(find.byType(GraphiteSettingsPanel), findsNWidgets(2));
      expect(find.text('Not connected'), findsOneWidget);

      // Start, then cancel the waiting sign-in by clicking the same row.
      await tester.runAsync(() async {
        await tester.tap(find.text('Connect Simkl'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      expect(find.textContaining('Click here to cancel'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.textContaining('Click here to cancel'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      // Snackbar and the persistent inline reason both say what happened.
      expect(find.text('Sign-in cancelled.'), findsNWidgets(2));
      expect(find.text('Connect Simkl'), findsOneWidget);

      // Connected state: the whole auto-sync row toggles the preference.
      await tester.runAsync(() async {
        await Hive.box(
          SimklService.boxName,
        ).putAll({'accessToken': 't', 'viewerName': 'viewer'});
      });
      // Hive writes must run in the real zone (they would never finish in
      // the fake one and block teardown).
      await tester.runAsync(() async {
        service.autoSync = true; // notifies the page
        await Hive.box(SimklService.boxName).flush();
      });
      // Let the snackbar expire; the inline reason is gone once connected.
      await tester.pumpAndSettle(const Duration(seconds: 5));
      expect(find.text('Connected to Simkl'), findsOneWidget);
      expect(find.text('Sign-in cancelled.'), findsNothing);
      await tester.runAsync(() async {
        await tester.tap(find.text('Auto-sync'));
        await Hive.box(SimklService.boxName).flush();
      });
      await tester.pumpAndSettle();
      expect(service.autoSync, isFalse);
      await tester.runAsync(() async {
        await tester.tap(find.byType(Switch));
        await Hive.box(SimklService.boxName).flush();
      });
      await tester.pumpAndSettle();
      expect(service.autoSync, isTrue);
      expect(tester.takeException(), isNull);
      // Cards stand in the shared settings column, as on the Reader page:
      // from the left edge, no wider than the settings width.
      for (final card in tester.widgetList<GraphiteSettingsPanel>(
        find.byType(GraphiteSettingsPanel),
      )) {
        final drawn = tester.getRect(
          find
              .descendant(
                of: find.byWidget(card),
                matching: find.byType(DecoratedBox),
              )
              .first,
        );
        expect(drawn.left, 22);
        expect(drawn.width, kDesktopSettingsContentMaxWidth);
      }
      debugDefaultTargetPlatformOverride = null;
    });
  }
}
