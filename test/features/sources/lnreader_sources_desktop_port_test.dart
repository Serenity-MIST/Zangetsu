// src-3 / src-13: the LNReader sources screen on Windows uses the shared
// provider desktop kit (settings look, toolbar with Add repository, no
// floating button, F5 refresh, hover rows with a right-click menu). Phone
// keeps the floating Add button.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/lnreader/lnreader_extension_service.dart';
import 'package:watch_app/core/lnreader/lnreader_manager.dart';
import 'package:watch_app/core/lnreader/novel_lang_prefs.dart';
import 'package:watch_app/core/ui/desktop_settings_surface.dart';
import 'package:watch_app/features/sources/lnreader_sources_screen.dart';
import 'package:watch_app/features/sources/sources_desktop_kit.dart';

const _repoUrl = 'https://repo.test/plugins.min.json';

/// One installed plugin, also listed in the repo catalog.
LnReaderPluginMeta _meta() => LnReaderPluginMeta(
  id: 'plugin-a',
  name: 'Plugin A',
  site: 'https://a.test/',
  lang: 'en',
  version: '1.0.0',
  url: 'https://cdn.test/a.js',
  iconUrl: '',
);

/// In-memory service that counts catalog fetches (F5 re-fetches them).
class _FakeLnrService extends LnReaderExtensionService {
  _FakeLnrService() : super(httpGet: (_) async => '');
  final Map<String, LnReaderPluginMeta> store = {};
  int fetches = 0;

  @override
  Future<List<LnReaderPluginMeta>> fetchIndex(String indexUrl) async {
    fetches++;
    return [_meta()];
  }

  @override
  Future<void> install(LnReaderPluginMeta meta) async => store[meta.id] = meta;

  @override
  List<LnReaderPluginMeta> installed() => store.values.toList();

  @override
  Future<void> uninstall(String id) async => store.remove(id);

  @override
  String? jsFor(String id) => store.containsKey(id) ? '/*js*/' : null;
}

/// In-memory language prefs (no Hive).
class _FakeNovelLangPrefs extends NovelLangPrefs {
  @override
  Set<String>? get enabled => {'en'};
  @override
  Future<void> setEnabled(Set<String> langs) async => notifyListeners();
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;
  late _FakeLnrService service;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('lnr_port_test_');
    Hive.init(tempDir.path);
    await Hive.openBox<String>(kLnReaderReposBoxName);
  });

  tearDownAll(() async {
    await binding.runAsync(() async {
      await Hive.close();
      await tempDir.delete(recursive: true);
    });
  });

  setUp(() async {
    await Hive.box<String>(kLnReaderReposBoxName).clear();
    service = _FakeLnrService()..store['plugin-a'] = _meta();
    sl.registerSingleton<LnReaderExtensionService>(service);
    sl.registerSingleton<LnReaderManager>(
      LnReaderManager(
        service: service,
        fetch: (url, init) async => throw StateError('no runtime'),
      ),
    );
    sl.registerSingleton<NovelLangPrefs>(_FakeNovelLangPrefs());
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await sl.reset();
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> loadScreen(WidgetTester tester) async {
    await tester.runAsync(
      () => Hive.box<String>(kLnReaderReposBoxName).add(_repoUrl),
    );
    await tester.pumpWidget(const MaterialApp(home: LnReaderSourcesScreen()));
    await settle(tester);
  }

  testWidgets('Windows: settings look, toolbar Add, no floating button', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await loadScreen(tester);
    expect(find.byType(DesktopSettingsScope), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(
      find.byKey(const ValueKey('desktop-add-lnreader-repo')),
      findsOneWidget,
    );
    expect(find.byType(DesktopSourceRow), findsWidgets);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Windows: F5 re-fetches the repositories', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await loadScreen(tester);
    final before = service.fetches;
    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    await settle(tester);
    expect(service.fetches, greaterThan(before));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Windows: right-click on a plugin row opens its menu', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await loadScreen(tester);
    final row = find.byType(DesktopSourceRow).first;
    await tester.tap(row, buttons: kSecondaryMouseButton);
    await settle(tester);
    // The installed plugin offers Uninstall (shared provider menu).
    expect(find.text('Uninstall'), findsWidgets);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('phone: floating Add button kept, no settings scope', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await loadScreen(tester);
    expect(find.byType(FloatingActionButton), findsOneWidget);
    expect(find.byType(DesktopSettingsScope), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });
}
