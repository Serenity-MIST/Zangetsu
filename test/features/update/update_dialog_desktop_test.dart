import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/update/update_service.dart';
import 'package:watch_app/features/update/update_dialog.dart';
import 'package:watch_app/l10n/app_localizations.dart';

/// Records APK calls so the test can prove Windows never touches them.
class _RecordingService extends UpdateService {
  int downloads = 0;
  int installs = 0;

  @override
  Future<File> downloadApk(
    String url, {
    int expectedSize = 0,
    void Function(double progress)? onProgress,
  }) async {
    downloads++;
    throw Exception('no network in tests');
  }

  @override
  Future<bool> installApk(File apk) async {
    installs++;
    return false;
  }
}

const _info = UpdateInfo(
  version: '9.9.9',
  notes: '## New\n- Faster search',
  apkUrl: 'https://example.com/app.apk',
  assetName: 'app.apk',
  apkSize: 10,
);

void main() {
  late List<Uri> launched;
  late bool launchResult;
  setUp(() {
    launched = [];
    launchResult = true;
    updatePageLauncher = (uri) async {
      launched.add(uri);
      return launchResult;
    };
  });

  Future<_RecordingService> open(WidgetTester tester) async {
    final service = _RecordingService();
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () =>
                  showUpdateDialog(context, info: _info, service: service),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    return service;
  }

  group('Windows', () {
    testWidgets('opens the updates page instead of downloading an APK', (
      tester,
    ) async {
      final service = await open(tester);
      expect(tester.getRect(_card()).width, lessThanOrEqualTo(520));
      expect(find.text('Version 9.9.9'), findsOneWidget);
      expect(find.text('Open updates page'), findsOneWidget);
      // No Android "Update" / installer wording on Windows.
      expect(find.text('Update'), findsNothing);
      await tester.tap(find.text('Open updates page'));
      await tester.pumpAndSettle();
      expect(launched, [Uri.parse(kWindowsUpdatesUrl)]);
      expect(service.downloads, 0);
      expect(service.installs, 0);
      expect(find.byType(Dialog), findsNothing);
    }, variant: _windows);

    testWidgets('browser failure keeps the dialog with an error', (
      tester,
    ) async {
      launchResult = false;
      final service = await open(tester);
      await tester.tap(find.text('Open updates page'));
      await tester.pumpAndSettle();
      expect(find.text("Couldn't open the browser."), findsOneWidget);
      expect(service.downloads, 0);
    }, variant: _windows);

    testWidgets('Esc and X close', (tester) async {
      await open(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
    }, variant: _windows);

    testWidgets('manual check opens the updates page, no snackbar', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => maybeShowUpdateDialog(context, manual: true),
                child: const Text('Check'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Check'));
      await tester.pumpAndSettle();
      expect(launched, [Uri.parse(kWindowsUpdatesUrl)]);
      expect(find.byType(SnackBar), findsNothing);
    }, variant: _windows);
  });

  testWidgets('phone keeps the APK update flow', (tester) async {
    final service = await open(tester);
    expect(find.text('Open updates page'), findsNothing);
    expect(find.byTooltip('Close'), findsNothing);
    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();
    expect(service.downloads, 1);
    expect(launched, isEmpty);
  });
}

/// Runs a test as the Windows target (resets the override afterwards).
final _windows = TargetPlatformVariant.only(TargetPlatform.windows);

/// The visible dialog card (the Dialog widget itself spans the window).
Finder _card() => find
    .descendant(of: find.byType(Dialog), matching: find.byType(Material))
    .first;
