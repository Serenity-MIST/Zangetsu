import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/announce/announcement.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/features/announce/announcement_sheet.dart';
import 'package:watch_app/features/community/community_sheet.dart';
import 'package:watch_app/l10n/app_localizations.dart';

/// Launch dialogs: Windows shows centred graphite dialogs (Esc / outside / X
/// close), phone keeps its rounded-top bottom sheet.
void main() {
  setUp(() {
    if (!sl.isRegistered<AppMode>()) {
      sl.registerSingleton<AppMode>(const AppMode(isTv: false));
    }
  });
  tearDown(() async {
    await sl.reset();
  });

  Future<void> pumpHost(
    WidgetTester tester,
    void Function(BuildContext) open,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => open(context),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  const announcement = Announcement(
    id: 'a1',
    title: 'Server move',
    body: 'We moved servers.',
    actionLabel: 'Read more',
    actionUrl: 'https://example.com',
    date: '2026-11-01',
  );

  group('Windows', () {
    testWidgets('community: bounded centred dialog, no bottom sheet', (
      tester,
    ) async {
      await pumpHost(tester, showCommunitySheet);
      expect(find.byType(BottomSheet), findsNothing);
      final dialog = find.byType(Dialog);
      expect(dialog, findsOneWidget);
      final rect = tester.getRect(_card());
      expect(rect.width, lessThanOrEqualTo(560));
      expect(rect.center.dx, closeTo(800, 1));
      // Same content and actions.
      expect(find.text('Join the Zangetsu community'), findsOneWidget);
      expect(find.text('Telegram  ·  @ZangetsuStream'), findsOneWidget);
      expect(find.text('Discord'), findsOneWidget);
      expect(find.text('Maybe later'), findsOneWidget);
      // X closes.
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
    }, variant: _windows);

    testWidgets('community: Esc and click outside close', (tester) async {
      await pumpHost(tester, showCommunitySheet);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
    }, variant: _windows);

    testWidgets('announcement: bounded dialog with the same actions', (
      tester,
    ) async {
      await pumpHost(tester, (c) => showAnnouncementSheet(c, announcement));
      expect(find.byType(BottomSheet), findsNothing);
      final dialog = find.byType(Dialog);
      expect(dialog, findsOneWidget);
      expect(tester.getRect(_card()).width, lessThanOrEqualTo(560));
      expect(find.text('Server move'), findsOneWidget);
      expect(find.text('2026-11-01'), findsOneWidget);
      expect(find.text('We moved servers.'), findsOneWidget);
      expect(find.text('Read more'), findsOneWidget);
      expect(find.text('Got it'), findsOneWidget);
      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
    }, variant: _windows);

    testWidgets('announcement: Esc, X and click outside close', (tester) async {
      await pumpHost(tester, (c) => showAnnouncementSheet(c, announcement));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
    }, variant: _windows);

    testWidgets('announcement: Enter presses the focused "Got it"', (
      tester,
    ) async {
      await pumpHost(tester, (c) => showAnnouncementSheet(c, announcement));
      expect(find.byType(Dialog), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
    }, variant: _windows);

    testWidgets('announcement: long body scrolls inside a short window', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(900, 500);
      await pumpHost(
        tester,
        (c) => showAnnouncementSheet(
          c,
          Announcement(
            id: 'long',
            title: 'Long',
            body: List.filled(120, 'Line of text.').join('\n'),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Got it'), findsOneWidget);
    }, variant: _windows);
  });

  group('phone (unchanged)', () {
    testWidgets('community stays a bottom sheet', (tester) async {
      await pumpHost(tester, showCommunitySheet);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      expect(find.byTooltip('Close'), findsNothing);
    });

    testWidgets('announcement stays a bottom sheet', (tester) async {
      await pumpHost(tester, (c) => showAnnouncementSheet(c, announcement));
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      expect(find.byTooltip('Close'), findsNothing);
    });
  });
}

/// Runs a test as the Windows target (resets the override afterwards).
final _windows = TargetPlatformVariant.only(TargetPlatform.windows);

/// The visible dialog card (the Dialog widget itself spans the window).
Finder _card() => find
    .descendant(of: find.byType(Dialog), matching: find.byType(Material))
    .first;
