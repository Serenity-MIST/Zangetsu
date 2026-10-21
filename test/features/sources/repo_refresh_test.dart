import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/sources/aniyomi_repo_tab.dart';
import 'package:watch_app/features/sources/mihon_repo_tab.dart';

/// The refresh handler must replace the repo state that owns its fetch future.
void main() {
  for (final mihon in [false, true]) {
    testWidgets(
      '${mihon ? 'Mihon' : 'Aniyomi'} refresh fetches the catalog again',
      (tester) async {
        var fetches = 0;
        Future<List<Never>> fetch(String _) async {
          fetches++;
          return [];
        }

        final screen = mihon
            ? MihonRepoTab(
                repoUrls: const ['https://example.com'],
                onRemoveRepo: (_) {},
                fetchIndexFn: fetch,
                installedPkgsFn: (_) => false,
              )
            : AniyomiRepoTab(
                repoUrls: const ['https://example.com'],
                onRemoveRepo: (_) {},
                fetchIndexFn: fetch,
                installedPkgsFn: (_) => false,
              );
        await tester.pumpWidget(MaterialApp(home: Scaffold(body: screen)));
        await tester.pumpAndSettle();
        expect(fetches, 1);
        final refresh = tester
            .widget<RefreshIndicator>(find.byType(RefreshIndicator))
            .onRefresh();
        await tester.pumpAndSettle();
        await refresh;
        expect(fetches, 2);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
