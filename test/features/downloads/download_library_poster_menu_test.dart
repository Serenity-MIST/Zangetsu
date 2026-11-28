// DownloadLibraryPoster overflow: Windows opens the graphite desktop menu
// (button and right-click give the same items); phone keeps PopupMenuButton.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/downloads/download_library_widgets.dart';

void main() {
  late int opened, deleted;

  /// Pumps one poster in a fixed-size box and resets the counters.
  Future<void> pump(WidgetTester tester) async {
    opened = 0;
    deleted = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 160,
            height: 320,
            child: DownloadLibraryPoster(
              title: 'Alpha',
              heroTag: 'poster-alpha',
              countLabel: '2/2',
              sizeLabel: '1 GB',
              deleteTooltip: 'Delete all episodes',
              onOpen: () => opened++,
              onDelete: () => deleted++,
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('Windows: overflow opens the desktop menu, not a popup',
      (tester) async {
    await pump(tester);
    expect(find.byType(PopupMenuButton<String>), findsNothing);
    await tester.tap(find.byKey(const ValueKey('download-poster-overflow')));
    await tester.pumpAndSettle();
    expect(find.text('Open'), findsOneWidget);
    await tester.tap(find.text('Delete all'));
    await tester.pumpAndSettle();
    expect(deleted, 1);
    expect(opened, 0);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('Windows: right-click gives the same items', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Alpha'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('Delete all'), findsOneWidget);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(opened, 1);
    expect(deleted, 0);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('phone keeps the Material popup menu', (tester) async {
    await pump(tester);
    expect(find.byKey(const ValueKey('download-poster-overflow')), findsNothing);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete all'));
    await tester.pumpAndSettle();
    expect(deleted, 1);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
