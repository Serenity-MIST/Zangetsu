// sources-runtime-hub: Windows behaviour of LnReaderSourcesScreen.
// src-16 update banner + Update all, src-13 Ctrl+F / Esc keys. Uses the same
// in-memory service and real `lnreader_repos` box pattern as
// lnreader_sources_screen_test.dart (see its header for the fake-async
// rules: bounded pumps, real Hive writes only through runAsync).
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/lnreader/lnreader_extension_service.dart';
import 'package:watch_app/core/lnreader/lnreader_manager.dart';
import 'package:watch_app/core/lnreader/novel_lang_prefs.dart';
import 'package:watch_app/features/sources/lnreader_sources_screen.dart';

const _repoUrl = 'https://repo.test/plugins.min.json';

/// Plugin meta used by both the installed copy and the repo catalog.
LnReaderPluginMeta _meta(String version) => LnReaderPluginMeta(
  id: 'plugin-a',
  name: 'Plugin A',
  site: 'https://a.test/',
  lang: 'en',
  version: version,
  url: 'https://cdn.test/a.js',
  iconUrl: '',
);

/// In-memory service: installs live in a map, catalogs are per URL.
class _FakeLnrService extends LnReaderExtensionService {
  _FakeLnrService() : super(httpGet: (_) async => '');
  final Map<String, LnReaderPluginMeta> store = {};
  final Map<String, List<LnReaderPluginMeta>> catalogs = {};

  @override
  Future<List<LnReaderPluginMeta>> fetchIndex(String indexUrl) async =>
      catalogs[indexUrl] ?? const [];

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
  _FakeNovelLangPrefs(this._langs);
  Set<String>? _langs;
  @override
  Set<String>? get enabled => _langs;
  @override
  Future<void> setEnabled(Set<String> langs) async {
    _langs = langs;
    notifyListeners();
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;
  late _FakeLnrService service;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('lnr_windows_test_');
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
    service = _FakeLnrService();
    sl.registerSingleton<LnReaderExtensionService>(service);
    sl.registerSingleton<LnReaderManager>(
      LnReaderManager(
        service: service,
        fetch: (url, init) async => throw StateError('no runtime'),
      ),
    );
    sl.registerSingleton<NovelLangPrefs>(_FakeNovelLangPrefs({'en'}));
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

  testWidgets('Windows: outdated plugin shows a badge and Update all', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    service.store['plugin-a'] = _meta('1.0.0');
    service.catalogs[_repoUrl] = [_meta('1.1.0')];
    await loadScreen(tester);

    expect(find.byKey(const ValueKey('lnreader-updates-banner')), findsOne);
    expect(find.byKey(const ValueKey('lnreader-update-plugin-a')), findsOne);

    await tester.tap(find.byKey(const ValueKey('lnreader-update-all')));
    await settle(tester);
    expect(service.store['plugin-a']!.version, '1.1.0');
    expect(find.byKey(const ValueKey('lnreader-updates-banner')), findsNothing);
    // Drain the SnackBar timer.
    await tester.pump(const Duration(seconds: 5));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('phone: no update banner (layout unchanged)', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    service.store['plugin-a'] = _meta('1.0.0');
    service.catalogs[_repoUrl] = [_meta('1.1.0')];
    await loadScreen(tester);
    expect(find.byKey(const ValueKey('lnreader-updates-banner')), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Windows: Ctrl+F focuses search and Esc clears it', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await loadScreen(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    final field = find.byType(EditableText);
    expect(tester.widget<EditableText>(field).focusNode.hasFocus, isTrue);

    await tester.enterText(find.byType(TextField), 'abc');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(tester.widget<EditableText>(field).controller.text, isEmpty);
    debugDefaultTargetPlatformOverride = null;
  });
}
