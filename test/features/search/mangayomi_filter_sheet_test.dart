import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/search/mangayomi_filter_sheet.dart';

void main() {
  testWidgets('applies a source filter without changing its defaults', (
    tester,
  ) async {
    final defaults = <Map<String, dynamic>>[
      {
        'type_name': 'SelectFilter',
        'name': 'Genre',
        'state': 0,
        'values': [
          {'name': 'All', 'value': ''},
          {'name': 'Action', 'value': 'action'},
        ],
      },
    ];
    List<Map<String, dynamic>>? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async =>
                  selected = await showMangayomiFilterSheet(context, defaults),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Action').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(selected?.single['state'], 1);
    expect(defaults.single['state'], 0);
  });
}
