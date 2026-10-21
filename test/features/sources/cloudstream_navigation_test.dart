import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/features/sources/cloudstream_sources_screen.dart';

/// Keeps network/JVM operations controllable while exercising real screen rows.
class _Manager extends CloudStreamManager {
  bool installed = false;
  bool catalogVisible = true;
  int removals = 0;
  final installGate = Completer<void>();
  static const plugin = CsPluginMeta(internalName: 'test', name: 'Test Plugin',
    url: 'https://example.test/plugin.cs3', version: 1);
  @override
  List<CloudStreamProvider> get all => [];
  @override
  List<CsRepoGroup> get repoGroups => [CsRepoGroup(url: 'https://example.test/repo',
    name: 'Test Repo', owner: 'test', catalog: catalogVisible ? [plugin] : [], sources: [])];
  @override
  bool isPluginInstalled(String name, {String? repoUrl}) => installed;
  @override
  Future<void> installPlugin(CsPluginMeta plugin, {String repoUrl = ''}) async {
    await installGate.future;
    installed = true;
  }
  @override
  Future<void> uninstallPlugin(CsPluginMeta plugin, {String repoUrl = ''}) async {
    removals++;
    installed = false;
  }
  void hideCatalog() {
    catalogVisible = false;
    notifyListeners();
  }
}

void main() {
  late _Manager manager;
  late ActiveSourceCubit active;
  setUp(() {
    manager = _Manager();
    active = ActiveSourceCubit();
    sl.registerSingleton<AppMode>(const AppMode(isTv: false));
    sl.registerSingleton<CloudStreamManager>(manager);
  });
  tearDown(() async {
    await active.close();
    await sl.reset();
    manager.dispose();
  });
  Future<void> openCatalog(WidgetTester tester) async {
    await tester.pumpWidget(BlocProvider<ActiveSourceCubit>.value(value: active,
      child: const MaterialApp(home: CloudStreamSourcesScreen())));
    await tester.pumpAndSettle();
  }
  for (final fails in [false, true]) {
    testWidgets('CloudStream install completes after leaving (fails=$fails)', (tester) async {
      await openCatalog(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Install'));
      await tester.pump();
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      if (fails) {
        manager.installGate.completeError(StateError('Install failed'));
      } else {
        manager.installGate.complete();
      }
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(manager.installed, !fails);
    });
  }
  testWidgets('CloudStream confirmation cannot act on a removed catalog row', (tester) async {
    manager.installed = true;
    await openCatalog(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Installed'));
    await tester.pumpAndSettle();
    manager.hideCatalog();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Uninstall').last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(manager.removals, 0);
    expect(manager.installed, isTrue);
  });
}
