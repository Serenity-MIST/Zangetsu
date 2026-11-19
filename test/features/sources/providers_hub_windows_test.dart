import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/desktop/extension_load_failures.dart';
import 'package:watch_app/core/desktop/extension_runtime.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/mihon/mihon_manager.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/provider/provider_repo_registry.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/core/ui/desktop_settings_surface.dart';
import 'package:watch_app/features/sources/providers_hub_screen.dart';

// Windows-only Providers hub behaviour (src-10): rows stay visible when the
// extension engine is missing, and load failures show a banner.

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

const _missing = 'Extension engine not found. Re-extract the app folder.';

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
    // Collect the notice through the hook (no app shell in tests).
    ExtensionLoadFailures.noticeDelay = Duration.zero;
    ExtensionLoadFailures.debugShowNotice = (_) {};
  });
  tearDown(() async {
    DesktopExtensionRuntime.debugAvailableOverride = null;
    ExtensionLoadFailures.debugReset();
    await sl<ActiveSourceCubit>().close();
    sl<CloudStreamManager>().dispose();
    sl<AniyomiManager>().dispose();
    sl<MihonManager>().dispose();
    await sl.reset();
  });

  Future<void> pumpHub(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(
        home: DesktopSettingsScope(child: ProvidersHubScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Windows: missing engine keeps Aniyomi/Mihon visible, disabled', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    DesktopExtensionRuntime.debugAvailableOverride = false;
    await pumpHub(tester);
    // Both rows explain the problem and offer the app folder.
    expect(find.textContaining(_missing), findsNWidgets(2));
    expect(find.text('Open folder'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('phone: missing engine still hides the rows (unchanged)', (
    tester,
  ) async {
    DesktopExtensionRuntime.debugAvailableOverride = false;
    await pumpHub(tester);
    expect(find.textContaining(_missing), findsNothing);
  });

  testWidgets('Windows: load failures show a banner with Details and Retry', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    DesktopExtensionRuntime.debugAvailableOverride = true;
    await pumpHub(tester);
    expect(find.byKey(const ValueKey('hub-load-failures')), findsNothing);
    // A plugin fails after the hub is open: the banner appears.
    ExtensionLoadFailures.report(
      const ExtensionLoadFailure(
        ecosystem: 'CloudStream',
        name: 'p1',
        message: 'boom',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('hub-load-failures')), findsOneWidget);
    expect(find.text('1 extension or plugin failed to load'), findsOneWidget);
    // Retry runs the registered handler, which clears the failure.
    var retried = 0;
    ExtensionLoadFailures.registerRetry('CloudStream', () async {
      retried++;
      ExtensionLoadFailures.clear('CloudStream');
    });
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(retried, 1);
    expect(find.byKey(const ValueKey('hub-load-failures')), findsNothing);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}
