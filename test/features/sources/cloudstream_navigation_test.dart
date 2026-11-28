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
  /// Replaced inside each test body so its completion runs on the fake clock.
  Completer<void> installGate = Completer<void>();
  static const plugin = CsPluginMeta(internalName: 'test', name: 'Test Plugin',
    url: 'https://example.test/plugin.cs3', version: 1);
  @override
  List<CloudStreamProvider> get all => [];
  @override
  List<CsRepoGroup> get repoGroups => [CsRepoGroup(url: 'https://example.test/repo',
    name: 'Test Repo', owner: 'test', catalog: [plugin], sources: [])];
  @override
  bool isPluginInstalled(String name, {String? repoUrl}) => installed;
  @override
  Future<void> installPlugin(CsPluginMeta plugin, {String repoUrl = ''}) async {
    await installGate.future;
    installed = true;
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
  /// Opens the catalog the way the app does: pushed over a page that stays
  /// behind it, so leaving pops back to a live Scaffold and messenger.
  Future<void> openCatalog(WidgetTester tester) async {
    await tester.pumpWidget(BlocProvider<ActiveSourceCubit>.value(value: active,
      child: MaterialApp(home: Scaffold(body: Builder(builder: (context) =>
        TextButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => const CloudStreamSourcesScreen())),
          child: const Text('Open catalog'),
        ))))));
    await tester.tap(find.text('Open catalog'));
    await tester.pumpAndSettle();
  }
  for (final fails in [false, true]) {
    testWidgets('CloudStream install completes after leaving (fails=$fails)', (tester) async {
      // A gate made in setUp completes on the real clock, after the asserts.
      manager.installGate = Completer<void>();
      await openCatalog(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Install'));
      await tester.pump();
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(CloudStreamSourcesScreen), findsNothing);
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
}
