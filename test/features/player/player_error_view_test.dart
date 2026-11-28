import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/desktop_back_navigation.dart';
import 'package:watch_app/features/player/player_error_view.dart';
import 'package:watch_app/l10n/app_localizations.dart';

/// Wraps [child] in a MaterialApp with the app's localizations (the back
/// button's tooltip reads context.l10n.back).
Widget _host(Widget child) => MaterialApp(
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(backgroundColor: Colors.black, body: child),
);

void main() {
  const msg = "Episode 1 isn't available on any source yet";

  testWidgets('Try again calls onRetry', (tester) async {
    var retries = 0;
    await tester.pumpWidget(
      _host(PlayerErrorView(message: msg, onRetry: () => retries++)),
    );
    await tester.tap(find.text('Try again'));
    expect(retries, 1);
  });

  testWidgets('no onBack: no back arrow (phone layout unchanged)', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(PlayerErrorView(message: msg, onRetry: () {})),
    );
    expect(find.byKey(const ValueKey('player-state-back')), findsNothing);
    expect(find.byType(PlayerBackScope), findsNothing);
  });

  testWidgets('headline and detail lines are split', (tester) async {
    await tester.pumpWidget(
      _host(
        PlayerErrorView(message: '$msg\nNo source answered', onRetry: () {}),
      ),
    );
    expect(find.text(msg), findsOneWidget);
    expect(find.text('No source answered'), findsOneWidget);
  });

  testWidgets('back arrow calls onBack', (tester) async {
    var backs = 0;
    await tester.pumpWidget(
      _host(
        PlayerErrorView(message: msg, onRetry: () {}, onBack: () => backs++),
      ),
    );
    final back = find.byKey(const ValueKey('player-state-back'));
    expect(back, findsOneWidget);
    // Same glyph as the controls overlay's back arrow.
    expect(
      find.descendant(
        of: back,
        matching: find.byIcon(Icons.arrow_back_rounded),
      ),
      findsOneWidget,
    );
    await tester.tap(back);
    expect(backs, 1);
  });

  testWidgets('Esc calls onBack', (tester) async {
    var backs = 0;
    await tester.pumpWidget(
      _host(
        PlayerErrorView(message: msg, onRetry: () {}, onBack: () => backs++),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(backs, 1);
  });

  testWidgets('Esc runs onEscape instead of onBack when given', (
    tester,
  ) async {
    var backs = 0, escapes = 0;
    await tester.pumpWidget(
      _host(
        PlayerErrorView(
          message: msg,
          onRetry: () {},
          onBack: () => backs++,
          onEscape: () => escapes++,
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(escapes, 1);
    expect(backs, 0);
  });

  testWidgets('mouse back marks the subtree so the app-wide handler skips', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(PlayerErrorView(message: msg, onRetry: () {}, onBack: () {})),
    );
    expect(find.byType(DesktopMouseBackOwner), findsOneWidget);
    // Inside DesktopPlayerInput (handleMouseBack false) the player owns it.
    await tester.pumpWidget(
      _host(
        PlayerErrorView(
          message: msg,
          onRetry: () {},
          onBack: () {},
          handleMouseBack: false,
        ),
      ),
    );
    expect(find.byType(DesktopMouseBackOwner), findsNothing);
  });

  testWidgets('mouse back button calls onBack once', (tester) async {
    var backs = 0;
    await tester.pumpWidget(
      _host(
        PlayerErrorView(message: msg, onRetry: () {}, onBack: () => backs++),
      ),
    );
    final g = await tester.startGesture(
      const Offset(400, 500),
      kind: PointerDeviceKind.mouse,
      buttons: kBackMouseButton,
    );
    await g.up();
    expect(backs, 1);
  });

  testWidgets('handleMouseBack false leaves the mouse back to the ancestor', (
    tester,
  ) async {
    var backs = 0;
    await tester.pumpWidget(
      _host(
        PlayerErrorView(
          message: msg,
          onRetry: () {},
          onBack: () => backs++,
          handleMouseBack: false,
        ),
      ),
    );
    final g = await tester.startGesture(
      const Offset(400, 500),
      kind: PointerDeviceKind.mouse,
      buttons: kBackMouseButton,
    );
    await g.up();
    expect(backs, 0);
  });
}
