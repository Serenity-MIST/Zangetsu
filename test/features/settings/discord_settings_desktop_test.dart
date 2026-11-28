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
import 'package:watch_app/core/discord/discord_config.dart';
import 'package:watch_app/core/discord/discord_rpc.dart';
import 'package:watch_app/core/ui/desktop_settings_surface.dart';
import 'package:watch_app/features/settings/discord_settings_screen.dart';

/// Windows Discord page: the sign-in registers `discord-<appId>` and can be
/// cancelled from the same row; the status picker is the graphite dialog and
/// saves the choice.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const window = MethodChannel('com.spyou.zangetsu/window');
  const launcher = MethodChannel('plugins.flutter.io/url_launcher');
  const links = MethodChannel('com.llfbandit.app_links/messages');
  const events = MethodChannel('com.llfbandit.app_links/events');
  // DiscordRpc.start retires a legacy token from secure storage.
  const secure = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late Directory dir;
  late List<String> registered;

  setUp(() async {
    registered = [];
    dir = await Directory.systemTemp.createTemp('discord_desktop');
    Hive.init(dir.path);
    await Hive.openBox(DiscordRpc.boxName);
    sl.registerSingleton<AppMode>(const AppMode(isTv: false));
    sl.registerSingleton<DiscordRpc>(DiscordRpc(Dio()));
    DesktopOAuth.debugIsWindowsHost = true;
    for (final c in [links, events, secure]) {
      messenger.setMockMethodCallHandler(c, (_) async => null);
    }
    messenger.setMockMethodCallHandler(window, (call) async {
      registered.add('${call.arguments}');
      return null;
    });
    messenger.setMockMethodCallHandler(launcher, (_) async => true);
  });

  tearDown(() async {
    DesktopOAuth.debugIsWindowsHost = null;
    for (final c in [window, launcher, links, events, secure]) {
      messenger.setMockMethodCallHandler(c, null);
    }
    await sl.reset();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  Future<void> pumpPage(WidgetTester tester, Size size) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(
        home: DesktopSettingsScope(child: DiscordSettingsScreen()),
      ),
    );
    await tester.pump();
  }

  for (final size in const [Size(1280, 720), Size(1920, 1080)]) {
    testWidgets('sign-in registers and cancels at ${size.width.toInt()}', (
      tester,
    ) async {
      await pumpPage(tester, size);
      await tester.runAsync(() async {
        await tester.tap(find.text('Connect Discord'));
        await Future<void>.delayed(const Duration(milliseconds: 80));
      });
      await tester.pump();
      expect(registered, ['discord-${DiscordConfig.applicationId}']);
      final cancel = find.textContaining('Click here to cancel');
      expect(cancel, findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(cancel);
        await Future<void>.delayed(const Duration(milliseconds: 80));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Discord login cancelled.'), findsOneWidget);
      expect(find.text('Connect Discord'), findsOneWidget);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('status picker is the graphite dialog and saves', (tester) async {
    await tester.runAsync(() async {
      await Hive.box(DiscordRpc.boxName).putAll({
        'accessToken': 'fake',
        'expiresAt': DateTime.now()
            .add(const Duration(hours: 1))
            .millisecondsSinceEpoch,
        'username': 'tester',
      });
      await sl<DiscordRpc>().start();
    });
    await pumpPage(tester, const Size(1280, 720));
    // Real zone: the picker's follow-up Hive write must be able to finish.
    await tester.runAsync(() async {
      await tester.tap(find.text('Discord status'));
    });
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(GraphiteSettingsControl),
      ),
      findsNWidgets(4),
    );
    await tester.runAsync(() async {
      await tester.tap(find.text('Idle'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(sl<DiscordRpc>().presenceStatus, 'idle');
    expect(find.byType(Dialog), findsNothing);
    // Let the real Hive write finish so the page rebuilds with the choice.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    // The row now reports the saved status.
    expect(find.text('Idle'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}
