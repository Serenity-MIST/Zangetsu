// Windows-only See all behaviour (search-browse group): search-2 (keep paging
// until the window can scroll, plus a 'Load more' fallback), search-8 (a
// failed search shows an error with Retry instead of "No results"),
// search-12 (no per-card height pass on Windows) and search-1 / shell-7
// (Esc clears, then closes the in-page search; Ctrl+F opens it).

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/desktop/desktop_shortcut_catalog.dart';
import 'package:watch_app/core/desktop/desktop_shortcuts.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/zmode/metadata_filters.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/features/home/see_all_screen.dart';

MediaItem _item(String id) => MediaItem(
  id: id,
  title: id,
  cover: null,
  url: 'https://x.test/$id',
  type: ProviderType.anime,
  sourceId: 'ani:1',
);

List<MediaItem> _page(int start, int count) => [
  for (var i = start; i < start + count; i++) _item('m$i'),
];

Widget _wrap(Widget child) => MaterialApp(home: child);

void main() {
  setUp(() {
    if (sl.isRegistered<AppMode>()) sl.unregister<AppMode>();
    sl.registerSingleton<AppMode>(const AppMode(isTv: false));
    DesktopShortcuts.debugReset();
    registerDefaultDesktopShortcuts();
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    if (sl.isRegistered<AppMode>()) sl.unregister<AppMode>();
  });

  testWidgets('a short first page keeps loading until the end (Windows)', (
    t,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final requested = <int>[];
    await t.pumpWidget(
      _wrap(
        SeeAllScreen(
          title: 'Rows',
          items: _page(0, 2),
          onTap: (_) {},
          onLoadMore: (page) async {
            requested.add(page);
            return page <= 3 ? _page(page * 10, 2) : const [];
          },
        ),
      ),
    );
    await t.pumpAndSettle();
    // Pages 2 and 3 fill the window; page 4 is empty and ends paging.
    expect(requested, [2, 3, 4]);
    expect(find.byKey(const ValueKey('see-all-load-more')), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a long list shows the Load more fallback (Windows)', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final requested = <int>[];
    await t.pumpWidget(
      _wrap(
        SeeAllScreen(
          title: 'Rows',
          items: _page(0, 80),
          onTap: (_) {},
          onLoadMore: (page) async {
            requested.add(page);
            return _page(page * 100, 5);
          },
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(requested, isEmpty, reason: 'the first page already scrolls');
    await t.tap(find.byKey(const ValueKey('see-all-load-more')));
    await t.pumpAndSettle();
    expect(requested, [2]);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a failed search shows Retry, not No results (Windows)', (
    t,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    var fail = true;
    final queries = <String>[];
    await t.pumpWidget(
      _wrap(
        SeeAllScreen(
          title: 'Rows',
          items: _page(0, 3),
          onTap: (_) {},
          filterKind: ZKind.anime,
          onSearch: (q, f, page) async {
            queries.add(q);
            if (fail) throw StateError('offline');
            return MediaItemPage(items: _page(50, 2), hasMore: false);
          },
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('see-all-search')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('see-all-search-field')), 'x');
    await t.testTextInput.receiveAction(TextInputAction.search);
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('see-all-error')), findsOneWidget);
    expect(find.text('No results'), findsNothing);
    fail = false;
    await t.tap(find.text('Retry'));
    await t.pumpAndSettle();
    // (An earlier '' call is the auto-fill asking for page 2 of the initial
    // rows before any search was typed.)
    expect(queries.where((q) => q == 'x'), hasLength(2));
    expect(find.byKey(const ValueKey('see-all-error')), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Esc clears, then closes the search; Ctrl+F reopens it', (
    t,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await t.pumpWidget(
      _wrap(
        SeeAllScreen(
          title: 'Rows',
          items: _page(0, 3),
          onTap: (_) {},
          onSearch: (q, f, page) async =>
              const MediaItemPage(items: <MediaItem>[], hasMore: false),
          initialFilters: const MetaFilters(),
        ),
      ),
    );
    await t.pumpAndSettle();
    final field = find.byKey(const ValueKey('see-all-search-field'));
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyF);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pumpAndSettle();
    expect(field, findsOneWidget);
    await t.enterText(field, 'abc');
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(t.widget<TextField>(field).controller!.text, '');
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(field, findsNothing);
    expect(find.byType(SeeAllScreen), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('opening the search puts the cursor in the field (Windows)', (
    t,
  ) async {
    // The page-level key Focus holds focus on Windows, which can stop the
    // field's autofocus from taking the cursor after Ctrl+F / the search icon.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await t.pumpWidget(
      _wrap(
        SeeAllScreen(
          title: 'Rows',
          items: _page(0, 3),
          onTap: (_) {},
          onSearch: (q, f, page) async =>
              const MediaItemPage(items: <MediaItem>[], hasMore: false),
          initialFilters: const MetaFilters(),
        ),
      ),
    );
    await t.pumpAndSettle();
    final editable = find.descendant(
      of: find.byKey(const ValueKey('see-all-search-field')),
      matching: find.byType(EditableText),
    );
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyF);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pumpAndSettle();
    expect(t.widget<EditableText>(editable).focusNode.hasFocus, isTrue);
    // Close, then reopen with the app bar's search icon.
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    await t.tap(find.byIcon(Icons.search_rounded).first);
    await t.pumpAndSettle();
    expect(t.widget<EditableText>(editable).focusNode.hasFocus, isTrue);
    // Close once more: the page keys must still hear Ctrl+F afterwards.
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(editable, findsNothing);
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyF);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pumpAndSettle();
    expect(editable, findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('phone: a failed search still reads No results', (t) async {
    await t.pumpWidget(
      _wrap(
        SeeAllScreen(
          title: 'Rows',
          items: _page(0, 3),
          onTap: (_) {},
          onSearch: (q, f, page) async => throw StateError('offline'),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('see-all-search')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('see-all-search-field')), 'x');
    await t.testTextInput.receiveAction(TextInputAction.search);
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('see-all-error')), findsNothing);
    expect(find.text('No results'), findsOneWidget);
  });
}
