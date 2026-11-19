// src-3 A: the Providers hub puts itself in the desktop settings look on
// Windows even when pushed without DesktopSettingsScope (Home's prompt);
// phone stays unscoped.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/desktop/extension_load_failures.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/mihon/mihon_manager.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/provider/provider_repo_registry.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/core/ui/desktop_settings_surface.dart';
import 'package:watch_app/features/sources/providers_hub_screen.dart';

/// Empty registry so the hub needs no account files or network.
class _Registry implements ProviderRegistry {
  @override
  List<ProviderRegistryEntry> getAll() => [];
  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Empty repo manifest (no fetch, no Hive).
class _Repos implements ProviderReposRegistry {
  @override
  List<ProviderRepo> getAll() => [];
  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() {
    sl.registerSingleton<AppMode>(const AppMode(isTv: false));
    sl.registerSingleton<ProviderRegistry>(_Registry());
    sl.registerSingleton<ProviderReposRegistry>(_Repos());
    sl.registerSingleton<CloudStreamManager>(CloudStreamManager());
    sl.registerSingleton<AniyomiManager>(AniyomiManager());
    sl.registerSingleton<MihonManager>(MihonManager());
    sl.registerSingleton<ActiveSourceCubit>(ActiveSourceCubit(fallback: ''));
    ExtensionLoadFailures.debugReset();
    ExtensionLoadFailures.noticeDelay = Duration.zero;
    ExtensionLoadFailures.debugShowNotice = (_) {};
  });
  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    ExtensionLoadFailures.debugReset();
    await sl<ActiveSourceCubit>().close();
    sl<CloudStreamManager>().dispose();
    sl<AniyomiManager>().dispose();
    sl<MihonManager>().dispose();
    await sl.reset();
  });

  /// Pumps the hub with no scope around it, like Home's push.
  Future<void> pumpUnscoped(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(home: ProvidersHubScreen()));
    await tester.pumpAndSettle();
  }

  testWidgets('Windows: unscoped push gets the settings scope once', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await pumpUnscoped(tester);
    expect(find.byType(DesktopSettingsScope), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('phone: hub stays unscoped', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await pumpUnscoped(tester);
    expect(find.byType(DesktopSettingsScope), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });
}
