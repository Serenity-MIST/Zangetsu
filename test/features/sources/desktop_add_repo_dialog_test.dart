// Windows 'Add repository' dialog: the auto-detect heuristics (pure) and the
// dialog flow (detect -> add through the ecosystem's path -> close).

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/desktop/extension_runtime.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/features/sources/desktop_add_repo_dialog.dart';
import 'package:watch_app/features/sources/desktop_sources_model.dart';

void main() {
  group('detectRepoEcosystemFromUrl', () {
    test('file names that belong to one ecosystem', () {
      expect(
        detectRepoEcosystemFromUrl('https://x.strem.io/abc/manifest.json'),
        DesktopEcosystem.stremio,
      );
      expect(
        detectRepoEcosystemFromUrl('stremio://addon.example/manifest.json'),
        DesktopEcosystem.stremio,
      );
      expect(
        detectRepoEcosystemFromUrl(
          'https://raw.githubusercontent.com/o/plugins/v3/.dist/plugins.min.json',
        ),
        DesktopEcosystem.lnreader,
      );
      expect(
        detectRepoEcosystemFromUrl('https://example.com/anime_index.json'),
        DesktopEcosystem.mangayomi,
      );
      expect(
        detectRepoEcosystemFromUrl('https://example.com/u/r/main/repo.json'),
        DesktopEcosystem.cloudstream,
      );
    });

    test('index.min.json needs a telling name, else unknown', () {
      expect(
        detectRepoEcosystemFromUrl(
          'https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.min.json',
        ),
        DesktopEcosystem.mihon,
      );
      expect(
        detectRepoEcosystemFromUrl(
          'https://raw.githubusercontent.com/x/aniyomi-extensions/repo/index.min.json',
        ),
        DesktopEcosystem.aniyomi,
      );
      expect(
        detectRepoEcosystemFromUrl('https://example.com/r/index.min.json'),
        isNull,
      );
      expect(detectRepoEcosystemFromUrl(''), isNull);
      expect(detectRepoEcosystemFromUrl('https://example.com/x.json'), isNull);
    });
  });

  group('detectRepoEcosystemFromJson', () {
    test('maps', () {
      expect(
        detectRepoEcosystemFromJson({'name': 'r', 'pluginLists': <String>[]}),
        DesktopEcosystem.cloudstream,
      );
      expect(
        detectRepoEcosystemFromJson({
          'id': 'a',
          'resources': ['stream'],
          'types': ['movie'],
        }),
        DesktopEcosystem.stremio,
      );
      expect(
        detectRepoEcosystemFromJson({
          'name': 'Z',
          'sources': [
            {'id': 's', 'file': 's.js', 'type': 'anime'},
          ],
        }),
        DesktopEcosystem.zangetsu,
      );
      expect(detectRepoEcosystemFromJson({'hello': 1}), isNull);
    });

    test('lists', () {
      expect(
        detectRepoEcosystemFromJson([
          {'pkg': 'eu.kanade.tachiyomi.animeextension.en.x', 'apk': 'x.apk'},
        ]),
        DesktopEcosystem.aniyomi,
      );
      expect(
        detectRepoEcosystemFromJson([
          {'pkg': 'eu.kanade.tachiyomi.extension.en.y', 'apk': 'y.apk'},
        ]),
        DesktopEcosystem.mihon,
      );
      expect(
        detectRepoEcosystemFromJson([
          {'internalName': 'P', 'url': 'p.cs3'},
        ]),
        DesktopEcosystem.cloudstream,
      );
      expect(
        detectRepoEcosystemFromJson([
          {'id': 'n', 'site': 'https://n', 'url': 'n.js', 'lang': 'English'},
        ]),
        DesktopEcosystem.lnreader,
      );
      expect(
        detectRepoEcosystemFromJson([
          {'name': 'M', 'itemType': 0, 'sourceCodeLanguage': 1},
        ]),
        DesktopEcosystem.mangayomi,
      );
      expect(detectRepoEcosystemFromJson(const []), isNull);
      expect(detectRepoEcosystemFromJson('nope'), isNull);
    });
  });

  group('dialog (Windows)', () {
    setUp(() {
      sl.registerSingleton<AppMode>(const AppMode(isTv: false));
      DesktopExtensionRuntime.debugAvailableOverride = true;
    });
    tearDown(() async {
      DesktopExtensionRuntime.debugAvailableOverride = null;
      await sl.reset();
    });

    /// Opens the dialog from a button and returns what it popped with.
    Future<List<String?>> pump(
      WidgetTester tester, {
      required Future<Object?> Function(String) fetch,
      required Future<String> Function(DesktopEcosystem, String) add,
    }) async {
      final popped = <String?>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  popped.add(
                    await showDialog<String>(
                      context: context,
                      builder: (_) =>
                          DesktopAddRepoDialog(fetchJson: fetch, addRepo: add),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return popped;
    }

    testWidgets('URL heuristic picks the ecosystem without a fetch', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      var fetched = 0;
      DesktopEcosystem? addedAs;
      final popped = await pump(
        tester,
        fetch: (_) async {
          fetched++;
          return null;
        },
        add: (eco, url) async {
          addedAs = eco;
          return 'Added';
        },
      );
      await tester.enterText(
        find.byKey(const ValueKey('desktop-add-repo-url')),
        'https://a.b/manifest.json',
      );
      await tester.pump();
      // The dropdown names the guess while on Auto-detect.
      expect(find.text('Auto-detect (looks like Stremio)'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('desktop-add-repo-submit')));
      await tester.pumpAndSettle();
      expect(fetched, 0);
      expect(addedAs, DesktopEcosystem.stremio);
      expect(popped, ['Added']);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('unknown URL falls back to the JSON peek', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      DesktopEcosystem? addedAs;
      await pump(
        tester,
        fetch: (_) async => {'pluginLists': <String>[]},
        add: (eco, url) async {
          addedAs = eco;
          return 'ok';
        },
      );
      await tester.enterText(
        find.byKey(const ValueKey('desktop-add-repo-url')),
        'https://example.com/whatever',
      );
      await tester.tap(find.byKey(const ValueKey('desktop-add-repo-submit')));
      await tester.pumpAndSettle();
      expect(addedAs, DesktopEcosystem.cloudstream);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('undetectable link asks the user to pick', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      var adds = 0;
      await pump(
        tester,
        fetch: (_) async => null,
        add: (eco, url) async {
          adds++;
          return 'ok';
        },
      );
      await tester.enterText(
        find.byKey(const ValueKey('desktop-add-repo-url')),
        'https://example.com/whatever',
      );
      await tester.tap(find.byKey(const ValueKey('desktop-add-repo-submit')));
      await tester.pumpAndSettle();
      expect(adds, 0);
      expect(
        find.byKey(const ValueKey('desktop-add-repo-error')),
        findsOneWidget,
      );
      // Dialog stays open.
      expect(find.byType(DesktopAddRepoDialog), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a failed add shows the reason inline', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await pump(
        tester,
        fetch: (_) async => null,
        add: (eco, url) async => throw StateError('boom'),
      );
      await tester.enterText(
        find.byKey(const ValueKey('desktop-add-repo-url')),
        'https://a.b/repo.json',
      );
      await tester.tap(find.byKey(const ValueKey('desktop-add-repo-submit')));
      await tester.pumpAndSettle();
      expect(
        find.text('Could not add the CloudStream repository: boom'),
        findsOneWidget,
      );
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
