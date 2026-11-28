// Windows My List (home-3): category tabs answer a right-click with the
// pointer position so the screen can open a menu at the cursor, and the
// status picker body drops its phone drag handle inside a desktop dialog.
// Phone keeps the long-press and the bottom-sheet look.
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/desktop_sheet.dart';
import 'package:watch_app/core/ui/list_status_sheet.dart';
import 'package:watch_app/features/home/library_tabs.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  /// Pumps a two-tab row; the second tab records right-clicks.
  Future<List<Offset>> pumpTabs(WidgetTester tester) async {
    final clicks = <Offset>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LibraryTabs(
            tabs: [
              LibraryTab(id: 'all', label: 'All', count: 2, test: (_) => true),
              LibraryTab(
                id: 'cat:1',
                label: 'Gym',
                count: 1,
                test: (_) => true,
                onLongPress: () {},
                onContextMenu: clicks.add,
              ),
            ],
            selectedId: 'all',
            onSelected: (_) {},
            bodyFor: (t) => Text('body:${t.id}'),
          ),
        ),
      ),
    );
    return clicks;
  }

  testWidgets('Windows: right-click on a category tab reports the cursor', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final clicks = await pumpTabs(tester);
    final at = tester.getCenter(find.text('Gym'));
    await tester.tapAt(at, buttons: kSecondaryButton);
    await tester.pump();
    expect(clicks, [at]);
    // Reset inside the test: the binding checks it before tearDown runs.
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('phone: right-click does nothing on a tab', (tester) async {
    final clicks = await pumpTabs(tester);
    await tester.tap(find.text('Gym'), buttons: kSecondaryButton);
    await tester.pump();
    expect(clicks, isEmpty);
  });

  testWidgets('status picker hides the drag handle in a desktop dialog', (
    tester,
  ) async {
    Widget sheet({required bool desktop}) {
      const body = ListStatusSheet(current: null, inList: false, reading: false);
      return MaterialApp(
        home: Material(
          child: desktop ? const DesktopSheetScope(child: body) : body,
        ),
      );
    }

    await tester.pumpWidget(sheet(desktop: false));
    expect(find.text('Add to your list'), findsOneWidget);
    await tester.pumpWidget(sheet(desktop: true));
    // The dialog's title bar names it instead.
    expect(find.text('Add to your list'), findsNothing);
    expect(find.text('Watching'), findsOneWidget);
  });
}
