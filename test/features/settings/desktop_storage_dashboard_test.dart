import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/settings/desktop_storage_dashboard.dart';

// set-6: Windows Storage dashboard: one row per bucket with a size and a
// Clear button; risky buckets ask first and show what they will free.
void main() {
  testWidgets('sizes each bucket, clears safe ones straight away and confirms '
      'risky ones with their size', (tester) async {
    // Act as Windows for the graphite confirm; reset before the test ends.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    var posters = 2048;
    var scripts = 3 * 1024 * 1024;
    var scriptsCleared = 0;
    var opened = 0;
    final buckets = [
      StorageBucket(
        id: 'posters',
        icon: Icons.image_outlined,
        title: 'Posters and artwork',
        description: 'Cover images.',
        measure: () async => posters,
        clear: () async => posters = 0,
      ),
      StorageBucket(
        id: 'sources',
        icon: Icons.code_rounded,
        title: 'Source scripts',
        description: 'Provider scripts.',
        measure: () async => scripts,
        clear: () async {
          scriptsCleared++;
          scripts = 0;
        },
        confirmTitle: 'Clear source scripts?',
        confirmMessage: (size) => 'This frees $size.',
        destructive: true,
      ),
      StorageBucket(
        id: 'downloads',
        icon: Icons.download_rounded,
        title: 'Downloads',
        description: 'Downloaded episodes.',
        measure: () async => 10,
        open: () => opened++,
        openLabel: 'Manage',
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(children: [DesktopStorageDashboard(buckets: buckets)]),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Every bucket shows its size; the total leaves downloads out.
    expect(find.textContaining('2 KB'), findsWidgets);
    expect(find.textContaining('3.0 MB'), findsWidgets);
    expect(find.byKey(const ValueKey('storage-total')), findsOneWidget);
    // Downloads has no Clear, only Manage.
    expect(find.byKey(const ValueKey('storage-clear-downloads')), findsNothing);
    await tester.tap(find.text('Manage'));
    expect(opened, 1);

    // Posters: no question asked.
    await tester.tap(find.byKey(const ValueKey('storage-clear-posters')));
    await tester.pumpAndSettle();
    expect(posters, 0);
    expect(find.textContaining('freed'), findsOneWidget);

    // Source scripts: confirmation naming the size; Cancel keeps them.
    await tester.tap(find.byKey(const ValueKey('storage-clear-sources')));
    await tester.pumpAndSettle();
    expect(find.text('Clear source scripts?'), findsOneWidget);
    expect(find.text('This frees 3.0 MB.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(scriptsCleared, 0);

    await tester.tap(find.byKey(const ValueKey('storage-clear-sources')));
    await tester.pumpAndSettle();
    // Enter confirms the graphite dialog.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(scriptsCleared, 1);
    debugDefaultTargetPlatformOverride = null;
  });

  test('folder helpers measure and empty a folder but keep it', () async {
    final dir = await Directory.systemTemp.createTemp('storage_dash');
    try {
      await File('${dir.path}/a.bin').writeAsBytes(List.filled(100, 1));
      await Directory('${dir.path}/sub').create();
      await File('${dir.path}/sub/b.bin').writeAsBytes(List.filled(50, 1));
      expect(await storageFolderBytes(dir.path), 150);
      await emptyStorageFolder(dir.path);
      expect(await dir.exists(), isTrue);
      expect(await storageFolderBytes(dir.path), 0);
      expect(await storageFolderBytes(null), 0);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
