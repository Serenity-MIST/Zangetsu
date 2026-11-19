// show-4: the Windows header trailer pauses under popups and when the window
// is minimised / unfocused. _HeroTrailer is private to detail_screen.dart and
// needs media_kit, so this checks the two signals it relies on with the same
// wiring: ModalRoute.isCurrentOf re-running didChangeDependencies when any
// popup route (dialog, docked panel) covers the page, and AppLifecycleListener
// reporting focus loss / minimise.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Mirrors _HeroTrailerState's hold bookkeeping.
class _Probe extends StatefulWidget {
  const _Probe({required this.log});
  final List<String> log;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  bool covered = false;
  bool inactive = false;
  late final AppLifecycleListener _listener = AppLifecycleListener(
    onStateChange: (s) => _set(inactive: s != AppLifecycleState.resumed),
  );

  bool get held => covered || inactive;

  @override
  void initState() {
    super.initState();
    _listener; // create the listener now
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _set(covered: !(ModalRoute.isCurrentOf(context) ?? true));
  }

  void _set({bool? covered, bool? inactive}) {
    final was = held;
    this.covered = covered ?? this.covered;
    this.inactive = inactive ?? this.inactive;
    if (held != was) widget.log.add(held ? 'pause' : 'play');
  }

  @override
  void dispose() {
    _listener.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

void main() {
  testWidgets('a dialog or docked panel over the page pauses, closing resumes', (
    tester,
  ) async {
    final log = <String>[];
    late BuildContext pageContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            pageContext = context;
            return Scaffold(body: _Probe(log: log));
          },
        ),
      ),
    );
    expect(log, isEmpty);

    showDialog<void>(
      context: pageContext,
      builder: (_) => const AlertDialog(content: Text('Popup')),
    );
    await tester.pumpAndSettle();
    expect(log, ['pause']);
    Navigator.of(pageContext).pop();
    await tester.pumpAndSettle();
    expect(log, ['pause', 'play']);

    // Same route shape as showDesktopDockedPanel (a non-root showDialog).
    showDialog<void>(
      context: pageContext,
      useRootNavigator: false,
      barrierColor: Colors.black26,
      builder: (_) => const Align(
        alignment: Alignment.centerRight,
        child: Text('Panel'),
      ),
    );
    await tester.pumpAndSettle();
    expect(log, ['pause', 'play', 'pause']);
    Navigator.of(pageContext).pop();
    await tester.pumpAndSettle();
    expect(log, ['pause', 'play', 'pause', 'play']);
  });

  testWidgets('focus loss / minimise pauses and returning resumes', (
    tester,
  ) async {
    final log = <String>[];
    await tester.pumpWidget(MaterialApp(home: _Probe(log: log)));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(log, ['pause']);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    expect(log, ['pause']);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(log, ['pause', 'play']);
  });
}
