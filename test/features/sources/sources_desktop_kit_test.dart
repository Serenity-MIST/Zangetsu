// Tests for the Windows provider-screen helpers (sources-screens group):
// readable install failures (src-2), the 'Update all' summary (src-5),
// the 'Installed' status + '...' menu (src-6), add-repo clipboard / link
// parsing (src-12), Ctrl+F / Esc / F5 on the screens (src-13), the shared
// toolbar in the Windows style and tooltip dismissal on route pushes.

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/aniyomi/aniyomi_repo.dart';
import 'package:watch_app/core/aniyomi/aniyomi_update.dart';
import 'package:watch_app/core/provider/extension_install_failure.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/core/theme/app_colors.dart';
import 'package:watch_app/core/ui/global_messenger.dart';
import 'package:watch_app/core/ui/route_observer.dart';
import 'package:watch_app/features/sources/aniyomi_repo_tab.dart';
import 'package:watch_app/features/sources/sources_search_field.dart';

AniyomiRepoEntry _entry(String pkg, int code) => AniyomiRepoEntry(
  name: pkg,
  pkg: pkg,
  apk: '$pkg.apk',
  lang: 'en',
  version: '0.0.$code',
  code: code,
  nsfw: false,
  sources: const [],
  repoBaseUrl: 'https://r/x',
);

AniyomiUpdate _update(String pkg) => AniyomiUpdate(
  pkg: pkg,
  name: pkg,
  installedCode: 20,
  availableCode: 21,
  availableVersion: '0.0.21',
  entry: _entry(pkg, 21),
);

/// Runs [body] with the UI pretending to be Windows, always resetting the
/// override before the test ends (the framework checks it).
Future<void> _onWindows(Future<void> Function() body) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

DioException _dio(DioExceptionType type, {int? status}) => DioException(
  requestOptions: RequestOptions(path: 'https://r/x/a.apk'),
  type: type,
  response: status == null
      ? null
      : Response<void>(
          requestOptions: RequestOptions(path: 'https://r/x/a.apk'),
          statusCode: status,
        ),
);

void main() {
  group('ExtensionInstallFailure.from (src-2 A)', () {
    test('maps download errors to readable reasons, keeps details', () {
      final timeout = ExtensionInstallFailure.from(
        _dio(DioExceptionType.receiveTimeout),
      );
      expect(timeout.reason, contains('timed out'));
      expect(timeout.details, contains('receiveTimeout'));

      expect(
        ExtensionInstallFailure.from(
          _dio(DioExceptionType.connectionError),
        ).reason,
        'Download blocked by network',
      );
      expect(
        ExtensionInstallFailure.from(
          _dio(DioExceptionType.badResponse, status: 404),
        ).reason,
        contains('404'),
      );
      final cancelled = ExtensionInstallFailure.from(
        _dio(DioExceptionType.cancel),
      );
      expect(cancelled.cancelled, isTrue);
    });

    test('maps engine / version / disk errors', () {
      expect(
        ExtensionInstallFailure.from(
          PlatformException(code: 'DESKTOP_RUNTIME', message: 'missing'),
        ).reason,
        'Extension engine not running',
      );
      expect(
        ExtensionInstallFailure.from(
          PlatformException(code: 'LOAD', message: 'lib version 16 too new'),
        ).reason,
        'Extension needs a newer app version',
      );
      expect(
        ExtensionInstallFailure.from(
          const FileSystemException('denied', 'C:/x.apk'),
        ).reason,
        contains('disk'),
      );
      // An unknown error keeps its text for 'Copy details'.
      final other = ExtensionInstallFailure.from(StateError('boom'));
      expect(other.details, contains('boom'));
    });
  });

  group('extractRepoLink (src-12 B)', () {
    test('finds links and normalises stremio://', () {
      expect(
        extractRepoLink('  https://example.com/index.min.json '),
        'https://example.com/index.min.json',
      );
      expect(
        extractRepoLink('stremio://addon.example.com/manifest.json'),
        'https://addon.example.com/manifest.json',
      );
      expect(extractRepoLink('no link here'), isNull);
    });

    test('whole: only a clipboard that is just the link', () {
      expect(
        extractRepoLink('see https://example.com/x for more', whole: true),
        isNull,
      );
      expect(
        extractRepoLink('https://example.com/x', whole: true),
        'https://example.com/x',
      );
    });
  });

  test('update-all summary text (src-5 A)', () {
    expect(updateAllSummaryText(done: 3, total: 5), 'Updated 3 of 5. 2 failed');
  });

  testWidgets('phone keeps rows untouched (no hover / menu wrapper)', (
    t,
  ) async {
    await t.pumpWidget(
      const MaterialApp(home: DesktopSourceRow(child: Text('row'))),
    );
    expect(find.text('row'), findsOneWidget);
    // Off Windows the wrapper adds no AnimatedContainer highlight.
    expect(find.byType(AnimatedContainer), findsNothing);
  });

  testWidgets('Installed is a status; actions live in the ... menu (src-6)', (
    t,
  ) async {
    await _onWindows(() async {
      var uninstalled = 0;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => DesktopInstalledActions(
                items: () => desktopSourceMenuItems(
                  context,
                  onUninstall: () => uninstalled++,
                ),
              ),
            ),
          ),
        ),
      );
      // Clicking the label does nothing.
      await t.tap(find.text('Installed'));
      await t.pumpAndSettle();
      expect(uninstalled, 0);
      // The '...' button opens the menu; Uninstall runs from there.
      await t.tap(find.byKey(const ValueKey('desktop-installed-more')));
      await t.pumpAndSettle();
      await t.tap(find.text('Uninstall'));
      await t.pumpAndSettle();
      expect(uninstalled, 1);
    });
  });

  testWidgets('Ctrl+F focuses search, Esc clears then goes back, F5 '
      'refreshes (src-13 A)', (t) async {
    await _onWindows(() async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      var refreshed = 0;
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => DesktopSourcesKeys(
                      onRefresh: () => refreshed++,
                      child: Scaffold(
                        body: Column(
                          children: [
                            const Text('provider page'),
                            SourcesSearchField(
                              controller: controller,
                              onChanged: (_) {},
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();

      EditableText field() => t.widget<EditableText>(find.byType(EditableText));
      expect(field().focusNode.hasFocus, isFalse);

      // Ctrl+F
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.keyF);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await t.pump();
      expect(field().focusNode.hasFocus, isTrue);

      // F5
      await t.sendKeyEvent(LogicalKeyboardKey.f5);
      await t.pump();
      expect(refreshed, 1);

      // Esc with text clears it and stays on the page.
      await t.enterText(find.byType(TextField), 'abc');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(controller.text, isEmpty);
      expect(find.text('provider page'), findsOneWidget);

      // Esc on an empty search goes back.
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.text('provider page'), findsNothing);
    });
  });

  testWidgets('add-repo dialog fills a link from the clipboard (src-12 B)', (
    t,
  ) async {
    await _onWindows(() async {
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => call.method == 'Clipboard.getData'
            ? <String, dynamic>{'text': 'https://example.com/repo'}
            : null,
      );
      addTearDown(
        () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await t.pumpWidget(
        const MaterialApp(home: Scaffold(body: AniyomiAddRepoDialog())),
      );
      await t.pumpAndSettle();
      final field = t.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, 'https://example.com/repo');
      expect(find.text('Filled in from your clipboard'), findsOneWidget);
    });
  });

  testWidgets('Update all ends with "Updated 1 of 2. 1 failed" + Details '
      '(src-5 A)', (t) async {
    await _onWindows(() async {
      final manager = AniyomiManager()
        ..checkerOverride = (url, codes) async => [_update('a'), _update('b')];
      await t.pumpWidget(
        MaterialApp(
          navigatorKey: rootNavigatorKey,
          home: Scaffold(
            body: debugAniyomiRepoSection(
              url: 'https://r/x',
              manager: manager,
              fetchIndexFn: (_) async => [_entry('a', 21), _entry('b', 21)],
              installedPkgsFn: (_) => true,
              installFn: (entry) async {
                if (entry.pkg == 'b') {
                  throw PlatformException(
                    code: 'LOAD',
                    message: 'lib version too new',
                  );
                }
              },
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await manager.checkRepoUpdates('https://r/x');
      await t.pump();

      // Installed rows show the status + '...' instead of a button.
      expect(
        find.byKey(const ValueKey('desktop-installed-more')),
        findsWidgets,
      );

      await t.tap(find.text('2 updates'));
      await t.pumpAndSettle();
      expect(find.text('Updated 1 of 2. 1 failed'), findsOneWidget);

      await t.tap(find.text('Details'));
      await t.pumpAndSettle();
      expect(find.text('Updates that failed'), findsOneWidget);
      expect(find.text('Extension needs a newer app version'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('update-failures-retry')),
        findsOneWidget,
      );
      // Close the dialog before the platform override is reset.
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
    });
  });

  // ---------------------------------------------------------------------
  // The shared toolbar in the app's Windows style (segmented switch,
  // graphite square icon buttons, secondary Add button).
  // ---------------------------------------------------------------------

  /// Pumps a two-tab provider-like page with the toolbar on Windows.
  Future<List<int>> pumpToolbar(
    WidgetTester t, {
    required VoidCallback onAdd,
    required VoidCallback onRefresh,
  }) async {
    final taps = <int>[];
    await t.pumpWidget(
      MaterialApp(
        home: DefaultTabController(
          length: 2,
          child: Scaffold(
            body: Column(
              children: [
                DesktopSourcesToolbar(
                  tabs: const ['Installed', 'Repositories'],
                  onTabTap: taps.add,
                  actions: [
                    IconButton(
                      key: const ValueKey('tb-refresh'),
                      tooltip: 'Refresh repositories (F5)',
                      icon: const Icon(Icons.refresh_rounded),
                      onPressed: onRefresh,
                    ),
                  ],
                  addLabel: 'Add Aniyomi repo',
                  addKey: const ValueKey('tb-add'),
                  onAdd: onAdd,
                  search: const TextField(),
                ),
                const Expanded(
                  child: TabBarView(
                    children: [Text('installed body'), Text('repos body')],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    return taps;
  }

  group('DesktopSourcesToolbar (Windows style)', () {
    testWidgets('segmented switch replaces the Material tab bar and '
        'switches tabs on tap and arrow keys', (t) async {
      await _onWindows(() async {
        final taps = await pumpToolbar(t, onAdd: () {}, onRefresh: () {});
        expect(find.byType(TabBar), findsNothing);
        expect(find.byKey(DesktopSourcesToolbar.tabsKey), findsOneWidget);
        final controller = DefaultTabController.of(
          t.element(find.byKey(DesktopSourcesToolbar.tabsKey)),
        );
        expect(controller.index, 0);

        await t.tap(find.text('Repositories'));
        await t.pumpAndSettle();
        expect(controller.index, 1);
        expect(taps, [1]);
        expect(find.text('repos body'), findsOneWidget);

        // A swipe / programmatic change keeps the pill in sync.
        controller.animateTo(0);
        await t.pumpAndSettle();
        // The segment's own Semantics (button + selected) follows the index.
        bool? selectedOf(String label) => t
            .widget<Semantics>(
              find
                  .ancestor(
                    of: find.text(label),
                    matching: find.byWidgetPredicate(
                      (w) => w is Semantics && w.properties.button == true,
                    ),
                  )
                  .first,
            )
            .properties
            .selected;
        expect(selectedOf('Installed'), isTrue);
        expect(selectedOf('Repositories'), isFalse);

        // Keyboard: Tab reaches the first segment, Right arrow moves the
        // selection and the focus with it, Enter selects the focused one.
        await t.sendKeyEvent(LogicalKeyboardKey.tab);
        await t.pumpAndSettle();
        await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await t.pumpAndSettle();
        expect(controller.index, 1);
        // Focus followed the selection onto the second segment.
        await t.sendKeyEvent(LogicalKeyboardKey.enter);
        await t.pumpAndSettle();
        expect(controller.index, 1);
        // Right past the last segment stays put; Left goes back.
        await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await t.pumpAndSettle();
        expect(controller.index, 1);
        await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await t.pumpAndSettle();
        expect(controller.index, 0);
        await t.sendKeyEvent(LogicalKeyboardKey.space);
        await t.pumpAndSettle();
        expect(controller.index, 0);
      });
    });

    testWidgets('icon actions are graphite square buttons with tooltips and '
        'every control shares the row height', (t) async {
      await _onWindows(() async {
        var refreshed = 0;
        await pumpToolbar(t, onAdd: () {}, onRefresh: () => refreshed++);
        final refresh = find.byKey(const ValueKey('tb-refresh'));
        expect(find.byTooltip('Refresh repositories (F5)'), findsOneWidget);
        expect(
          t.widget<IconButton>(refresh).tooltip,
          'Refresh repositories (F5)',
        );
        // Square, row-high graphite button from the toolbar's theme.
        expect(t.getSize(refresh), const Size.square(38));
        final theme = IconButtonTheme.of(t.element(refresh)).style!;
        expect(
          theme.backgroundColor!.resolve(<WidgetState>{}),
          AppColors.surface2,
        );
        expect(t.getSize(find.byKey(DesktopSourcesToolbar.tabsKey)).height, 38);
        expect(t.getSize(find.byKey(const ValueKey('tb-add'))).height, 38);
        await t.tap(refresh);
        await t.pump();
        expect(refreshed, 1);
      });
    });

    testWidgets('Add repo is the secondary graphite button and calls back', (
      t,
    ) async {
      await _onWindows(() async {
        var added = 0;
        await pumpToolbar(t, onAdd: () => added++, onRefresh: () {});
        final add = find.byKey(const ValueKey('tb-add'));
        // Secondary outlined graphite style, not the white primary pill.
        expect(
          find.ancestor(
            of: find.text('Add Aniyomi repo'),
            matching: find.byType(OutlinedButton),
          ),
          findsOneWidget,
        );
        expect(find.byType(FilledButton), findsNothing);
        final style = t.widget<OutlinedButton>(add).style!;
        expect(
          style.backgroundColor!.resolve(<WidgetState>{}),
          AppColors.surface2,
        );
        await t.tap(add);
        await t.pump();
        expect(added, 1);
      });
    });

    testWidgets('route pushes dismiss an open tooltip so it cannot freeze '
        'on the pushed page', (t) async {
      await _onWindows(() async {
        final navKey = GlobalKey<NavigatorState>();
        await t.pumpWidget(
          MaterialApp(
            navigatorKey: navKey,
            navigatorObservers: [appRouteObserver],
            home: Scaffold(
              body: Center(
                child: IconButton(
                  key: const ValueKey('tip-button'),
                  tooltip: 'Settings',
                  icon: const Icon(Icons.settings),
                  onPressed: () {},
                ),
              ),
            ),
          ),
        );
        // Long-press shows the tooltip label.
        await t.longPress(find.byKey(const ValueKey('tip-button')));
        await t.pump(const Duration(milliseconds: 300));
        expect(find.text('Settings'), findsOneWidget);
        unawaited(
          navKey.currentState!.push(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('pushed page')),
            ),
          ),
        );
        await t.pumpAndSettle();
        expect(find.text('pushed page'), findsOneWidget);
        // The label lives under the now offstage first page, so the default
        // finder would skip it even when frozen. Look offstage too: the
        // label must be gone (or fully faded), not stuck at full opacity
        // on the paused ticker of the covered page.
        final label = find.text('Settings', skipOffstage: false);
        final fades = find.ancestor(
          of: label,
          matching: find.byType(FadeTransition, skipOffstage: false),
        );
        final opacity = fades.evaluate().isEmpty
            ? 0.0
            : t.widget<FadeTransition>(fades.first).opacity.value;
        expect(opacity, 0.0);
        // Let the long-press dismiss timer run out before the test ends.
        await t.pump(const Duration(seconds: 2));
      });
    });
  });
}
