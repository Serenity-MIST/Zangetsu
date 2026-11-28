import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/desktop_catalogue_switch.dart';
import 'package:watch_app/core/desktop/desktop_context_menu.dart';
import 'package:watch_app/core/desktop/desktop_dialogs.dart';
import 'package:watch_app/core/desktop/desktop_multi_select.dart';
import 'package:watch_app/core/desktop/desktop_recycle_bin.dart';
import 'package:watch_app/core/desktop/desktop_row_scroller.dart';
import 'package:watch_app/core/desktop/desktop_sheet.dart';
import 'package:watch_app/core/desktop/desktop_undo_toast.dart';
import 'package:watch_app/core/notify/new_episode_inbox.dart';
import 'package:watch_app/core/sync/sync_status.dart';

/// Hosts [onReady] with a context inside a plain Material app.
Widget _host(void Function(BuildContext context) onReady) => MaterialApp(
  home: Scaffold(
    body: Builder(
      builder: (context) {
        onReady(context);
        return const SizedBox.expand();
      },
    ),
  ),
);

void main() {
  group('DesktopSelection', () {
    final keys = ['a', 'b', 'c', 'd', 'e'];

    test('plain click is not consumed until selection mode starts', () {
      final s = DesktopSelection<String>();
      expect(s.handleClick('b', keys, ctrl: false, shift: false), isFalse);
      expect(s.isActive, isFalse);
      s.startSelecting();
      expect(s.handleClick('b', keys, ctrl: false, shift: false), isTrue);
      expect(s.selected, {'b'});
    });

    test('ctrl toggles and moves the anchor', () {
      final s = DesktopSelection<String>();
      expect(s.handleClick('b', keys, ctrl: true, shift: false), isTrue);
      expect(s.handleClick('d', keys, ctrl: true, shift: false), isTrue);
      expect(s.selected, {'b', 'd'});
      expect(s.anchor, 'd');
      s.handleClick('d', keys, ctrl: true, shift: false);
      expect(s.selected, {'b'});
    });

    test('shift selects the range from the anchor in either direction', () {
      final s = DesktopSelection<String>()..select('b');
      expect(s.handleClick('d', keys, ctrl: false, shift: true), isTrue);
      expect(s.selected, {'b', 'c', 'd'});
      // The anchor stays on b, so a second shift click re-ranges from it.
      s.handleClick('a', keys, ctrl: false, shift: true);
      expect(s.selected, {'a', 'b'});
      expect(s.anchor, 'b');
    });

    test('shift without an anchor just selects the key', () {
      final s = DesktopSelection<String>();
      s.selectRange('c', keys);
      expect(s.selected, {'c'});
      expect(s.anchor, 'c');
    });

    test('plain click toggles while active, clear leaves selection mode', () {
      final s = DesktopSelection<String>()..select('a');
      expect(s.handleClick('c', keys, ctrl: false, shift: false), isTrue);
      expect(s.selected, {'a', 'c'});
      s.selectAll(keys);
      expect(s.selected, keys.toSet());
      s.clear();
      expect(s.isActive, isFalse);
      expect(s.anchor, isNull);
    });

    _windowsTest('shortcuts: Esc consumed only while something is selected', (
      tester,
    ) async {
      final s = DesktopSelection<String>()..select('a');
      var deleted = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: DesktopSelectionShortcuts<String>(
            selection: s,
            orderedKeys: () => keys,
            onDelete: () => deleted++,
            child: const Focus(autofocus: true, child: SizedBox()),
          ),
        ),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      expect(deleted, 1);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(s.selected, {'a', 'b'});
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(s.isActive, isFalse);
    });
  });

  group('showDesktopContextMenu', () {
    _windowsTest('falls back to the last right-click position', (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      DesktopPointer.install();
      late BuildContext ctx;
      await tester.pumpWidget(_host((c) => ctx = c));
      await tester.tapAt(const Offset(120, 140), buttons: kSecondaryButton);
      await tester.pump();
      expect(DesktopPointer.lastSecondaryDown, const Offset(120, 140));

      final result = showDesktopContextMenu<int>(
        ctx,
        items: const [
          DesktopMenuItem(label: 'Copy', value: 1),
          DesktopMenuItem.divider(),
          DesktopMenuItem(label: 'Delete', value: 2, destructive: true),
        ],
      );
      await tester.pumpAndSettle();
      final copy = tester.getTopLeft(find.text('Copy'));
      // The panel's top-left sits at the click, so the first label is just
      // right of and below it.
      expect(copy.dx, inInclusiveRange(120, 180));
      expect(copy.dy, inInclusiveRange(140, 180));

      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(await result, 2);
    });

    _windowsTest('explicit position near the corner stays on screen, '
        'keyboard picks and runs onTap', (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late BuildContext ctx;
      await tester.pumpWidget(_host((c) => ctx = c));
      var tapped = false;
      final result = showDesktopContextMenu<String>(
        ctx,
        position: const Offset(795, 595),
        items: [
          const DesktopMenuItem(label: 'Disabled', value: 'x', enabled: false),
          DesktopMenuItem(
            label: 'Open',
            value: 'open',
            shortcut: 'Enter',
            onTap: () => tapped = true,
          ),
        ],
      );
      await tester.pumpAndSettle();
      final rect = tester.getRect(find.text('Open'));
      expect(rect.right, lessThanOrEqualTo(800));
      expect(rect.bottom, lessThanOrEqualTo(600));
      // Down skips the disabled row and lands on Open.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(await result, 'open');
      expect(tapped, isTrue);
    });

    _windowsTest('Esc closes with null', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(_host((c) => ctx = c));
      final result = showDesktopContextMenu<int>(
        ctx,
        position: const Offset(10, 10),
        items: const [DesktopMenuItem(label: 'One', value: 1)],
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('One'), findsNothing);
      expect(await result, isNull);
    });
  });

  group('adaptive dialogs and sheets', () {
    _windowsTest('choice dialog search filters and Enter picks', (
      tester,
    ) async {
      late BuildContext ctx;
      await tester.pumpWidget(_host((c) => ctx = c));
      final result = showDesktopChoiceDialog<int>(
        ctx,
        title: 'Pick',
        options: const [(1, 'Apple'), (2, 'Banana'), (3, 'Cherry')],
        current: 1,
        searchable: true,
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'ban');
      await tester.pump();
      expect(find.text('Apple'), findsNothing);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(await result, 2);
    });

    _windowsTest('sheet marks its body with DesktopSheetScope on Windows', (
      tester,
    ) async {
      late BuildContext ctx;
      bool? inScope;
      await tester.pumpWidget(_host((c) => ctx = c));
      showAdaptiveSheet<void>(
        ctx,
        title: 'Sheet',
        builder: (c) {
          inScope = DesktopSheetScope.of(c);
          return const Text('body');
        },
      );
      await tester.pumpAndSettle();
      expect(inScope, isTrue);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('Sheet'), findsOneWidget);
    });

    _windowsTest('sheet stays a bottom sheet off Windows', (tester) async {
      debugDefaultTargetPlatformOverride =
          TargetPlatform.android; // reset by _windowsTest
      late BuildContext ctx;
      await tester.pumpWidget(_host((c) => ctx = c));
      showAdaptiveSheet<void>(ctx, builder: (_) => const Text('body'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
    });
  });

  group('recycle bin', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('ui_kit_recycle'));
    tearDown(() {
      debugRecycleOverride = null;
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test(
      'uses the override and keeps the file when it reports success',
      () async {
        final file = File('${dir.path}/a.txt')..writeAsStringSync('x');
        final calls = <String>[];
        debugRecycleOverride = (path) async {
          calls.add(path);
          return true;
        };
        await deleteToRecycleBinOrPermanently(file);
        expect(calls, [file.path]);
        // The fake "recycled" it, so no permanent delete happened.
        expect(file.existsSync(), isTrue);
      },
    );

    test('falls back to a permanent delete when recycling fails', () async {
      final sub = Directory('${dir.path}/folder')..createSync();
      File('${sub.path}/b.txt').writeAsStringSync('y');
      debugRecycleOverride = (_) async => false;
      await deleteToRecycleBinOrPermanently(sub);
      expect(sub.existsSync(), isFalse);
    });

    test('missing paths are a no-op', () async {
      var called = false;
      debugRecycleOverride = (_) async => called = true;
      await deleteToRecycleBinOrPermanently(File('${dir.path}/missing'));
      expect(called, isFalse);
    });
  });

  group('shared state boards', () {
    test('inbox works in memory and replaces the same show+source', () async {
      NewEpisodeInbox.debugReset();
      NewEpisodeEntry entry(String id, int minute) => NewEpisodeEntry(
        id: id,
        showId: 's1',
        sourceId: 'src',
        title: 'Show',
        mode: 'anime',
        count: 1,
        at: DateTime(2026, 1, 1, 0, minute),
      );
      await NewEpisodeInbox.add(entry('1', 1));
      await NewEpisodeInbox.add(entry('2', 2));
      expect(NewEpisodeInbox.entries.map((e) => e.id), ['2']);
      expect(NewEpisodeInbox.unread.value, 1);
      await NewEpisodeInbox.markAllRead();
      expect(NewEpisodeInbox.unread.value, 0);
      final round = NewEpisodeEntry.fromJson(entry('3', 3).toJson());
      expect(round.at, DateTime(2026, 1, 1, 0, 3));
      NewEpisodeInbox.debugReset();
    });

    test('sync status reports synced after a requested sync', () async {
      SyncStatus.debugReset();
      SyncStatus.onSyncRequested = () async {};
      await SyncStatus.requestSync();
      expect(SyncStatus.state.value, SyncState.synced);
      expect(SyncStatus.lastSynced.value, isNotNull);
      SyncStatus.onSyncRequested = () async => throw StateError('boom');
      await SyncStatus.requestSync();
      expect(SyncStatus.state.value, SyncState.error);
      expect(SyncStatus.lastError, contains('boom'));
      SyncStatus.debugReset();
    });

    test('catalogue switch publish and clear', () {
      DesktopCatalogueSwitch.publish([
        DesktopCatalogueOption(
          id: 'al',
          label: 'AniList',
          group: 'Trackers',
          onSelect: () {},
        ),
      ], currentId: 'al');
      expect(DesktopCatalogueSwitch.options.value, hasLength(1));
      expect(DesktopCatalogueSwitch.currentId.value, 'al');
      DesktopCatalogueSwitch.clear();
      expect(DesktopCatalogueSwitch.options.value, isEmpty);
    });
  });

  // Reviewer additions: confirm keys, undo toast, row scroller and the
  // menu's double-close guard were not covered above.
  group('confirm dialog', () {
    _windowsTest('Enter confirms, Esc cancels', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(_host((c) => ctx = c));
      var result = showDesktopConfirm(ctx, title: 'Delete?', message: 'Sure');
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(await result, isTrue);

      result = showDesktopConfirm(ctx, title: 'Delete?', message: 'Sure');
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(await result, isFalse);
    });

    _windowsTest('Enter on a focused Cancel button cancels', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(_host((c) => ctx = c));
      final result = showDesktopConfirm(
        ctx,
        title: 'Delete?',
        message: 'Sure',
        cancelLabel: 'No',
        destructive: true,
      );
      await tester.pumpAndSettle();
      // Focus the Cancel button the way Tab would.
      final cancel = find.ancestor(
        of: find.text('No'),
        matching: find.byType(TextButton),
      );
      tester.widget<TextButton>(cancel).focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(await result, isFalse);
    });
  });

  group('undo toast', () {
    _windowsTest('Undo button, Ctrl+Z and replacement', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(_host((c) => ctx = c));
      var undone = 0;
      var expired = 0;
      showUndoToast(
        ctx,
        message: 'Removed',
        onUndo: () => undone++,
        onExpired: () => expired++,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect((undone, expired), (1, 0));
      expect(find.text('Removed'), findsNothing);

      // Ctrl+Z undoes the visible toast.
      showUndoToast(ctx, message: 'Again', onUndo: () => undone++);
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(undone, 2);

      // A new toast replaces the old one, which expires; the new one then
      // times out on its own.
      showUndoToast(
        ctx,
        message: 'First',
        onUndo: () => undone++,
        onExpired: () => expired++,
      );
      showUndoToast(
        ctx,
        message: 'Second',
        duration: const Duration(seconds: 1),
        onUndo: () => undone++,
        onExpired: () => expired++,
      );
      await tester.pump();
      expect(expired, 1);
      expect(find.text('First'), findsNothing);
      await tester.pump(const Duration(seconds: 2));
      expect(expired, 2);
      expect(find.text('Second'), findsNothing);
      expect(undone, 2);
    });
  });

  group('row scroller', () {
    Widget row(ScrollController c) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 100,
          width: 400,
          child: DesktopRowScroller(
            controller: c,
            child: ListView.builder(
              controller: c,
              scrollDirection: Axis.horizontal,
              itemCount: 30,
              itemBuilder: (_, i) => SizedBox(width: 100, child: Text('$i')),
            ),
          ),
        ),
      ),
    );

    testWidgets('off Windows the row is returned untouched', (tester) async {
      final c = ScrollController();
      addTearDown(c.dispose);
      await tester.pumpWidget(row(c));
      expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
    });

    _windowsTest('Shift+wheel scrolls and the forward arrow pages', (
      tester,
    ) async {
      final c = ScrollController();
      addTearDown(c.dispose);
      await tester.pumpWidget(row(c));
      await tester.pump();
      final centre = tester.getCenter(find.byType(ListView));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: centre);
      await mouse.moveTo(centre);
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: centre,
          scrollDelta: const Offset(0, 120),
        ),
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(c.offset, 120);
      await tester.tap(find.byIcon(Icons.chevron_right_rounded));
      await tester.pumpAndSettle();
      expect(c.offset, greaterThan(120));
    });
  });

  _windowsTest('a second click while the menu fades out does not pop the '
      'page underneath', (tester) async {
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: nav, home: const Text('home')),
    );
    nav.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('second page')),
      ),
    );
    await tester.pumpAndSettle();
    final ctx = tester.element(find.text('second page'));
    unawaited(
      showDesktopContextMenu<int>(
        ctx,
        position: const Offset(200, 200),
        items: const [DesktopMenuItem(label: 'One', value: 1)],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pump(const Duration(milliseconds: 10));
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('One'), findsNothing);
    expect(find.text('second page'), findsOneWidget);
  });
}

/// testWidgets with the target platform set to Windows (the host-OS-agnostic
/// gate the kit uses). The override is reset inside the body, because the
/// framework checks debug variables before tearDown runs.
void _windowsTest(String description, WidgetTesterCallback body) =>
    testWidgets(description, (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await body(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
