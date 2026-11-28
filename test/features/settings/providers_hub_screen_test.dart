import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/mihon/mihon_manager.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/provider/provider_repo_registry.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/core/ui/desktop_settings_surface.dart';
import 'package:watch_app/features/sources/providers_hub_screen.dart';

/// Read-only registries keep presentation tests away from account files/network.
class _Registry implements ProviderRegistry {
  @override
  List<ProviderRegistryEntry> getAll() => [];
  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// An empty manifest does not require a repository fetch or Hive initialization.
class _Repos implements ProviderReposRegistry {
  @override
  List<ProviderRepo> getAll() => [];
  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Simulates a completed update check without downloading repository metadata.
class _CloudStream extends CloudStreamManager {
  int pending = 0;
  @override
  int get updateCount => pending;

  void finishUpdateCheck(int count) {
    pending = count;
    notifyListeners();
  }
}

void main() {
  setUp(() {
    sl.registerSingleton<AppMode>(const AppMode(isTv: false));
    sl.registerSingleton<ProviderRegistry>(_Registry());
    sl.registerSingleton<ProviderReposRegistry>(_Repos());
    sl.registerSingleton<CloudStreamManager>(_CloudStream());
    sl.registerSingleton<AniyomiManager>(AniyomiManager());
    sl.registerSingleton<MihonManager>(MihonManager());
    sl.registerSingleton<ActiveSourceCubit>(ActiveSourceCubit(fallback: ''));
  });
  tearDown(() async {
    await sl<ActiveSourceCubit>().close();
    sl<CloudStreamManager>().dispose();
    sl<AniyomiManager>().dispose();
    sl<MihonManager>().dispose();
    await sl.reset();
  });

  testWidgets('desktop summary counts actual visible ecosystems', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: DesktopSettingsScope(child: ProvidersHubScreen()),
      ),
    );
    await tester.pumpAndSettle();
    final rows = find.byType(GraphiteSettingsControl);
    expect(rows, findsWidgets);
    expect(find.text('${rows.evaluate().length} ecosystems'), findsOneWidget);
    expect(find.text('0 installed sources'), findsOneWidget);
    // Align the summary with the row labels rather than centering its contents.
    expect(tester.getTopLeft(find.text('Source library')).dx, lessThan(80));
    expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('completed update checks refresh the open desktop summary', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: DesktopSettingsScope(child: ProvidersHubScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('3 updates available'), findsNothing);
    (sl<CloudStreamManager>() as _CloudStream).finishUpdateCheck(3);
    await tester.pumpAndSettle();
    expect(find.text('3 updates available'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop provider summary and rows fit enlarged narrow windows', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: const DesktopSettingsScope(child: ProvidersHubScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
