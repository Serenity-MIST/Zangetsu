import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/core/repository/provider_settings_repository.dart';
import 'package:watch_app/features/sources/source_settings_screen.dart';

/// Tests the real provider schema form without starting the native JS runtime.
class _Provider implements JsProvider {
  @override
  Future<List<dynamic>?> getSettingsSchema() async => [
    {'key': 'domain', 'label': 'Domain', 'type': 'text', 'default': 'original'},
  ];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Manager implements ProviderManager {
  final provider = _Provider();
  Map<String, dynamic>? applied;
  @override
  JsProvider? get(String id) => provider;
  @override
  void setSettings(String sourceId, Map<String, dynamic> settings) {
    applied = Map.of(settings);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Holds the real disk operation until the test can run IO outside a frame.
/// Starting runAsync from dispose re-enters pump's guarded fake-async zone.
class _Repository extends ProviderSettingsRepository {
  final writes = <String>[];
  Future<void> Function()? pending;
  Completer<void>? completed;

  @override
  Future<void> setFor(String key, Map<String, dynamic> settings) {
    writes.add(key);
    final snapshot = Map<String, dynamic>.of(settings);
    pending = () => super.setFor(key, snapshot);
    completed = Completer<void>();
    return completed!.future;
  }

  @override
  Future<void> clearFor(String key) {
    pending = () => super.clearFor(key);
    completed = Completer<void>();
    return completed!.future;
  }

  /// Commit through Hive, then release the awaiting screen continuation.
  Future<void> commit() async {
    final operation = pending;
    final result = completed;
    if (operation == null || result == null) throw StateError('No pending IO');
    await operation();
    pending = null;
    result.complete();
  }
}
void main() {
  late Directory dir;
  late _Manager manager;
  late _Repository repository;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('source-text');
    Hive.init(dir.path);
    await ProviderSettingsRepository.init();
    manager = _Manager();
    GetIt.instance.registerSingleton<ProviderManager>(manager);
    repository = _Repository();
    GetIt.instance.registerSingleton<ProviderSettingsRepository>(repository);
  });
  tearDown(() async {
    await GetIt.instance.reset();
    // tearDown already runs outside the widget body; close the backend here
    // rather than reopening the test binding's fake-async runner after return.
    await Hive.close();
    await dir.delete(recursive: true);
  });
  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SourceSettingsScreen(sourceId: 'test', repoUrl: 'repo'),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('leaving before the debounce saves the final typed value', (
    tester,
  ) async {
    await pump(tester);
    await tester.enterText(find.byType(TextFormField), 'changed');
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(
      repository.writes,
      contains('repo::test'),
      reason: 'disposing the form must start a pending save',
    );
    // The spy executes the real Hive write in the IO zone; await that
    // observable durable result without blocking fake-zone microtasks.
    await tester.runAsync(repository.commit);
    await tester.pump();
    expect(
      GetIt.instance<ProviderSettingsRepository>().getFor(
        'repo::test',
      )['domain'],
      'changed',
    );
    expect(manager.applied?['domain'], 'changed');
  });

  testWidgets('reset replaces displayed text and cancels pending edits', (
    tester,
  ) async {
    await pump(tester);
    await tester.enterText(find.byType(TextFormField), 'changed');
    await tester.tap(find.text('Reset to defaults'));
    await tester.runAsync(repository.commit);
    await tester.pumpAndSettle();
    expect(find.text('original'), findsOneWidget);
    expect(manager.applied?['domain'], 'original');
    expect(
      GetIt.instance<ProviderSettingsRepository>().getFor('repo::test'),
      isEmpty,
    );
  });
}
