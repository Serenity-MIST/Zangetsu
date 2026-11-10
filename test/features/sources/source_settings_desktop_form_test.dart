import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/core/repository/provider_settings_repository.dart';
import 'package:watch_app/core/ui/desktop_settings_surface.dart';
import 'package:watch_app/features/sources/source_settings_screen.dart';

/// Offline schema covers every supported presentation without a native engine.
class _Provider implements JsProvider {
  @override
  Future<List<dynamic>?> getSettingsSchema() async => [
    {'key': 'enabled', 'label': 'Include extras', 'type': 'bool', 'default': false},
    {'key': 'quality', 'label': 'Quality', 'type': 'enum', 'default': 'hd',
      'options': [{'value': 'hd', 'label': 'HD'}, {'value': 'sd', 'label': 'SD'}]},
    {'key': 'languages', 'label': 'Languages', 'type': 'multiEnum', 'default': ['en'],
      'options': [{'value': 'en', 'label': 'English'}, {'value': 'jp', 'label': 'Japanese'}]},
    {'key': 'domain', 'label': 'Domain', 'type': 'text', 'default': 'original'},
  ];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Immediate dispatch fixture; real Hive persistence has a separate IO suite.
class _Repository extends ProviderSettingsRepository {
  final values = <String, Map<String, dynamic>>{};
  @override
  Map<String, dynamic> getFor(String key) => Map.of(values[key] ?? {});
  @override
  Future<void> setFor(String key, Map<String, dynamic> settings) async {
    values[key] = Map.of(settings);
  }
  @override
  Future<void> clearFor(String key) async { values.remove(key); }
}

/// Observes the runtime settings consumer independently of the form labels.
class _Manager implements ProviderManager {
  final provider = _Provider();
  Map<String, dynamic>? applied;
  @override
  JsProvider? get(String id) => provider;
  @override
  void setSettings(String id, Map<String, dynamic> settings) { applied = Map.of(settings); }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Repository repository;
  late _Manager manager;
  setUp(() {
    repository = _Repository(); manager = _Manager();
    GetIt.instance.registerSingleton<ProviderSettingsRepository>(repository);
    GetIt.instance.registerSingleton<ProviderManager>(manager);
  });
  tearDown(() => GetIt.instance.reset());

  Future<void> pump(WidgetTester tester, {double width = 1000, double scale = 1}) async {
    await tester.binding.setSurfaceSize(Size(width, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: MediaQuery(
      data: MediaQueryData(size: Size(width, 1000), textScaler: TextScaler.linear(scale)),
      child: const DesktopSettingsScope(child: SourceSettingsScreen(sourceId: 'test', repoUrl: 'repo')),
    )));
    await tester.pumpAndSettle();
  }

  testWidgets('desktop schema updates storage and runtime, cancel is inert', (tester) async {
    await pump(tester);
    expect(find.byType(GraphiteSettingsPanel), findsOneWidget);
    await tester.tap(find.byType(Switch)); await tester.pumpAndSettle();
    expect(repository.getFor('repo::test')['enabled'], true);
    expect(manager.applied?['enabled'], true);
    await tester.tap(find.text('Quality')); await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    await tester.tap(find.byTooltip('Close')); await tester.pumpAndSettle();
    expect(repository.getFor('repo::test')['quality'], 'hd');
    await tester.tap(find.text('Quality')); await tester.pumpAndSettle();
    await tester.tap(find.text('SD')); await tester.pumpAndSettle();
    expect(repository.getFor('repo::test')['quality'], 'sd');
    expect(manager.applied?['quality'], 'sd');
    await tester.tap(find.text('Japanese')); await tester.pumpAndSettle();
    expect(manager.applied?['languages'], containsAll(['en', 'jp']));
    await tester.enterText(find.byType(TextFormField), 'changed');
    await tester.pump(const Duration(milliseconds: 301));
    expect(repository.getFor('repo::test')['domain'], 'changed');
    await tester.ensureVisible(find.text('Reset to defaults')); await tester.pumpAndSettle();
    await tester.tap(find.text('Reset to defaults')); await tester.pumpAndSettle();
    expect(repository.getFor('repo::test'), isEmpty);
    expect(manager.applied?['domain'], 'original');
    expect(manager.applied?['quality'], 'hd');
    expect(find.text('original'), findsOneWidget);
  });

  testWidgets('desktop schema fits narrow scaled window and saves on leave', (tester) async {
    await pump(tester, width: 420, scale: 2);
    await tester.ensureVisible(find.byType(TextFormField)); await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'final-edit');
    await tester.pumpWidget(const SizedBox()); await tester.pump();
    expect(repository.getFor('repo::test')['domain'], 'final-edit');
    expect(manager.applied?['domain'], 'final-edit');
    expect(tester.takeException(), isNull);
  });
}
