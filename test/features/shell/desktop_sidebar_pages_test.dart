import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/shell/desktop_sidebar_pages.dart';

/// Visible state makes retained page behavior observable without real accounts.
class _Counter extends StatefulWidget {
  const _Counter();
  @override State<_Counter> createState() => _CounterState();
}
class _CounterState extends State<_Counter> {
  int count = 0;
  @override Widget build(BuildContext context) => TextButton(
    onPressed: () => setState(() => count++), child: Text('count:$count'));
}
void main() {
  testWidgets('sidebar swaps retain state without pushing another route', (tester) async {
    String? selected;
    late StateSetter update;
    await tester.pumpWidget(MaterialApp(home: StatefulBuilder(builder:(context,set) {
      update=set;
      return Scaffold(body:DesktopSidebarPages(selected:selected,
        builders:{'streaming':(_)=>const _Counter(),'genres':(_)=>const Text('Genres')},
        fallback:const Text('Home')));
    })));
    expect(find.text('Home'),findsOneWidget);
    expect(find.byType(_Counter),findsNothing);
    update(()=>selected='streaming'); await tester.pumpAndSettle();
    await tester.tap(find.text('count:0')); await tester.pump();
    update(()=>selected='genres'); await tester.pumpAndSettle();
    expect(find.text('Genres'),findsOneWidget);
    expect(find.text('count:1'),findsNothing);
    update(()=>selected='streaming'); await tester.pumpAndSettle();
    expect(find.text('count:1'),findsOneWidget);
    expect(Navigator.of(tester.element(find.text('count:1'))).canPop(),isFalse);
    update(()=>selected=null); await tester.pumpAndSettle();
    expect(find.text('Home'),findsOneWidget);
    expect(tester.takeException(),isNull);
  });
  testWidgets('profile key discards retained page state', (tester) async {
    Future<void> show(String profile) => tester.pumpWidget(MaterialApp(home:
      DesktopSidebarPages(key:ValueKey(profile),selected:'schedule',
        builders:{'schedule':(_)=>const _Counter()},fallback:const SizedBox())));
    await show('first'); await tester.tap(find.text('count:0')); await tester.pump();
    expect(find.text('count:1'),findsOneWidget);
    await show('second'); await tester.pumpAndSettle();
    expect(find.text('count:0'),findsOneWidget);
  });
}
