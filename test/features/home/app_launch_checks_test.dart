import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/home/home_screen.dart';

/// Minimal host whose State is handed to [AppLaunchChecks.runOnce].
class _Host extends StatefulWidget {
  const _Host();

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

void main() {
  tearDown(AppLaunchChecks.debugReset);

  testWidgets('launch checks run once whichever host asks first', (
    tester,
  ) async {
    final hosts = <State>[];
    AppLaunchChecks.debugRunOverride = hosts.add;
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Column(children: [_Host(), _Host()]),
      ),
    );
    final states = tester.stateList<_HostState>(find.byType(_Host)).toList();

    // RootShell (Windows) asks first at launch …
    expect(AppLaunchChecks.started, isFalse);
    expect(AppLaunchChecks.runOnce(states[0]), isTrue);
    expect(AppLaunchChecks.started, isTrue);
    // … then Home mounts later and must not run them again.
    expect(AppLaunchChecks.runOnce(states[1]), isFalse);
    expect(AppLaunchChecks.runOnce(states[0]), isFalse);
    expect(hosts, [states[0]]);
  });

  testWidgets('Windows shows the extension update count as a toast', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: _Host())));
      final context = tester.element(find.byType(_Host));

      // Nothing updated: no toast.
      await AppLaunchChecks.announceExtensionUpdates(context, 0);
      await tester.pump();
      expect(find.byType(SnackBar), findsNothing);

      await AppLaunchChecks.announceExtensionUpdates(context, 3);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('extensions-updated-toast')),
        findsOneWidget,
      );
      expect(
        find.text('3 extensions updated to the latest version.'),
        findsOneWidget,
      );
      final bar = tester.widget<SnackBar>(find.byType(SnackBar));
      expect(bar.behavior, SnackBarBehavior.floating);

      // Let the toast time out so no timers outlive the test.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('one updated extension reads in the singular', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: _Host())));
      await AppLaunchChecks.announceExtensionUpdates(
        tester.element(find.byType(_Host)),
        1,
      );
      await tester.pump();
      expect(
        find.text('1 extension updated to the latest version.'),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
